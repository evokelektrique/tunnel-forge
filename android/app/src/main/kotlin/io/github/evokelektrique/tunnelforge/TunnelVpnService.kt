package io.github.evokelektrique.tunnelforge

import androidx.annotation.Keep
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.OsConstants
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File
import java.io.IOException
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/** Foreground [VpnService]: TUN, notification, native tunnel thread. */
@Keep
class TunnelVpnService : VpnService() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val sessionLock = Any()
    private val notificationLock = Any()
    @Volatile
    private var foregroundNotificationActive = false
    private val stopLifecycleExecutor =
        Executors.newSingleThreadExecutor { task ->
            Thread(task, "vpn-stop-lifecycle").apply { isDaemon = true }
        }
    private val pendingStopSelfRunnable =
        Runnable {
            try {
                stopSelf()
            } catch (e: Exception) {
                AppLog.e(TAG, "stopSelf after tunnel", e)
            }
        }

    private val running = AtomicBoolean(false)
    private val connectedEmitted = AtomicBoolean(false)
    private val supervisorLock = ReentrantLock()
    private val supervisorSignal = supervisorLock.newCondition()
    @Volatile
    private var sessionStopRequested = false
    @Volatile
    private var networkInterruptEvent: NetworkTransitionEvent? = null
    @Volatile
    private var networkMonitor: ActiveNetworkMonitor? = null
    @Volatile
    private var currentTunnelState: String = VpnContract.TUNNEL_CONNECTING
    @Volatile
    private var currentTunnelDetail: String = ""
    @Volatile
    private var sessionHasConnected = false
    @Volatile
    private var sessionReconnectAttempt = 0
    @Volatile
    private var reconnectingAlertShown = false
    private var tunInterface: ParcelFileDescriptor? = null
    private var blockingTunInterface: ParcelFileDescriptor? = null
    private var setupThread: Thread? = null
    private var engineThread: Thread? = null
    private var vpnDnsPacketBridge: VpnDnsPacketBridge? = null
    private var localProxyRuntime: ProxyServerRuntime? = null
    private var activeAttemptId: String = ""
    private var lastSessionAttemptId: String = ""
    private var recordedDisconnectReason: String? = null
    private var taskRemovedDuringSession: Boolean = false
    private var activeProxyConfig: ProxyRuntimeConfig? = null
    private var activeServer: String = ""
    private var activeProfileName: String? = null

    private fun cancelPendingStopSelf() {
        mainHandler.removeCallbacks(pendingStopSelfRunnable)
    }

    private fun schedulePendingStopSelf() {
        mainHandler.removeCallbacks(pendingStopSelfRunnable)
        mainHandler.postDelayed(pendingStopSelfRunnable, 300L)
    }

    /**
     * Keep IKE/L2TP traffic to the VPN gateway off the TUN default route (API 33+).
     * [protect] alone is unreliable on some OEMs when the peer is on the LAN.
     */
    private fun applyExcludeRouteForVpnServer(builder: Builder, server: String) {
        try {
            val resolved = InetAddress.getByName(server)
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && resolved is Inet4Address -> {
                    builder.excludeRoute(IpPrefix(resolved, 32))
                    AppLog.d(TAG, "excludeRoute IPv4/32 for VPN server ${resolved.hostAddress}")
                }
                resolved is Inet4Address ->
                    AppLog.d(
                        TAG,
                        "excludeRoute requires API 33+; using socket protect() only (device API ${Build.VERSION.SDK_INT})",
                    )
                else -> AppLog.w(TAG, "VPN server is not IPv4; excludeRoute not applied")
            }
        } catch (e: Exception) {
            AppLog.w(TAG, "Could not resolve VPN server for excludeRoute: ${e.message}")
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        cancelPendingStopSelf()
        val attemptId = currentAttemptId()
        val batteryAttemptId = attemptId.ifEmpty { lastSessionAttemptId }
        val wasStopRequested = sessionStopRequested
        if (VpnDisconnectReasonPolicy.shouldReportSystemDestroy(hasActiveSession(), wasStopRequested)) {
            val (reason, uiDetail) = VpnDisconnectReasonPolicy.systemDestroyReason(taskRemovedDuringSession)
            val failureCode =
                if (taskRemovedDuringSession) {
                    VpnAndroidFailure.CODE_TASK_REMOVED
                } else {
                    VpnAndroidFailure.CODE_SYSTEM_DESTROYED
                }
            val failure = VpnAndroidFailure.map(failureCode)
            val profileLabel = currentProfileLabel()
            val wasConnected = sessionHasConnected
            recordDisconnectReason(
                attemptId = attemptId,
                reason = reason,
                level = Log.WARN,
                detail = "service destroyed without app stop request",
            )
            BatteryOptimizationDiagnostics.emitForVpnEvent(
                context = this,
                tag = TAG,
                attemptPrefix = prefixAttempt(batteryAttemptId),
                stage = "vpn_destroy",
            )
            postDisconnectAlertIfEligible(
                detail = uiDetail,
                failure = failure,
                profileLabel = profileLabel,
                wasConnected = wasConnected,
                userStopRequested = wasStopRequested,
            )
            stopTunnelInternal(stopReason = reason)
            VpnTunnelEvents.emit(VpnContract.TUNNEL_FAILED, uiDetail, attemptId, failure)
        } else if (batteryAttemptId.isNotEmpty()) {
            BatteryOptimizationDiagnostics.emitForVpnEvent(
                context = this,
                tag = TAG,
                attemptPrefix = prefixAttempt(batteryAttemptId),
                stage = "vpn_destroy",
            )
        }
        synchronized(sessionLock) {
            lastSessionAttemptId = ""
        }
        synchronized(notificationLock) {
            foregroundNotificationActive = false
        }
        instance = null
        super.onDestroy()
    }

    override fun onRevoke() {
        cancelPendingStopSelf()
        val attemptId = currentAttemptId()
        val wasStopRequested = sessionStopRequested
        if (VpnDisconnectReasonPolicy.shouldReportSystemDestroy(hasActiveSession(), wasStopRequested)) {
            val failure = VpnAndroidFailure.map(VpnAndroidFailure.CODE_VPN_REVOKED)
            val uiDetail = "Disconnected: VPN revoked by Android"
            val profileLabel = currentProfileLabel()
            val wasConnected = sessionHasConnected
            recordDisconnectReason(
                attemptId = attemptId,
                reason = "revoked_by_android",
                level = Log.WARN,
                detail = "another VPN started, system VPN turned off, or Always-on VPN revoked",
            )
            postDisconnectAlertIfEligible(
                detail = uiDetail,
                failure = failure,
                profileLabel = profileLabel,
                wasConnected = wasConnected,
                userStopRequested = wasStopRequested,
            )
            stopTunnelInternal(stopReason = "revoked by Android")
            VpnTunnelEvents.emit(
                VpnContract.TUNNEL_FAILED,
                uiDetail,
                attemptId,
                failure,
            )
            stopForegroundNotification()
        } else {
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                TAG,
                "${prefixAttempt(attemptId)}VPN disconnect reason=revoked_by_android (no active session)",
            )
        }
        super.onRevoke()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (hasActiveSession()) {
            synchronized(sessionLock) {
                taskRemovedDuringSession = true
            }
            VpnTunnelEvents.emitEngineLog(
                Log.INFO,
                TAG,
                "${prefixAttempt(currentAttemptId())}App task removed from recents while VPN active",
            )
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                cancelPendingStopSelf()
                val attemptId = intent.getStringExtra(EXTRA_ATTEMPT_ID) ?: ""
                VpnTunnelEvents.emitEngineLog(Log.INFO, TAG, "${prefixAttempt(attemptId)}ACTION_STOP: tearing down tunnel")
                val hadActiveSession = hasActiveSession()
                val stoppedAttemptId = synchronized(sessionLock) { activeAttemptId }
                if (VpnStopAttemptPolicy.shouldIgnoreStopRequest(attemptId, stoppedAttemptId)) {
                    VpnTunnelEvents.emitEngineLog(
                        Log.DEBUG,
                        TAG,
                        "${prefixAttempt(attemptId)}Ignoring stale tunnel stop activeAttempt=$stoppedAttemptId",
                    )
                    return START_NOT_STICKY
                }
                if (hadActiveSession) {
                    recordDisconnectReason(stoppedAttemptId, "stopped_by_app", Log.INFO)
                    stopTunnelInternal(stopReason = "stopped by app")
                    VpnTunnelEvents.emit(VpnContract.TUNNEL_STOPPED, "Stopped by app", stoppedAttemptId)
                }
                TunnelDisconnectNotification.cancelAll(this)
                stopForegroundNotification()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                // Required immediately after Context.startForegroundService(); must run before any early return.
                startForegroundWithType(buildNotification(AppLocaleSupport.getString(this, R.string.vpn_notification_connecting)))
                TunnelDisconnectNotification.cancelAll(this)
                val attemptId = intent.getStringExtra(EXTRA_ATTEMPT_ID) ?: ""
                val server = intent.getStringExtra(EXTRA_SERVER)
                if (server.isNullOrEmpty()) {
                    AppLog.e(TAG, "${prefixAttempt(attemptId)}ACTION_START missing server")
                    VpnTunnelEvents.emitEngineLog(Log.ERROR, TAG, "${prefixAttempt(attemptId)}ACTION_START rejected: missing server")
                    VpnTunnelEvents.emit(VpnContract.TUNNEL_FAILED, "Invalid tunnel arguments from the app.", attemptId)
                    stopForegroundNotification()
                    stopSelf()
                    return START_NOT_STICKY
                }
                val user = intent.getStringExtra(EXTRA_USER) ?: ""
                val password = intent.getStringExtra(EXTRA_PASSWORD) ?: ""
                val psk = intent.getStringExtra(EXTRA_PSK) ?: ""
                val protocol =
                    if (intent.getStringExtra(EXTRA_PROTOCOL) == VpnContract.PROTOCOL_PPTP) {
                        VpnContract.PROTOCOL_PPTP
                    } else {
                        VpnContract.PROTOCOL_L2TP
                    }
                val pppAuth = TunnelLaunchConfig.normalizePppAuth(intent.getStringExtra(EXTRA_PPP_AUTH))
                val mppe =
                    if (protocol == VpnContract.PROTOCOL_PPTP) {
                        TunnelLaunchConfig.normalizeMppe(intent.getStringExtra(EXTRA_MPPE))
                    } else {
                        VpnContract.MPPE_AUTO
                    }
                val dnsAutomatic = intent.getBooleanExtra(EXTRA_DNS_AUTOMATIC, true)
                val dnsServers = manualDnsServersFromIntent(intent)
                val requestedMtu = sanitizeOptionalMtu(intent.getIntExtra(EXTRA_MTU, AUTO_TUN_MTU))
                val profileName = intent.getStringExtra(EXTRA_PROFILE_NAME)?.trim().orEmpty()
                val splitTunnelEnabled = intent.getBooleanExtra(EXTRA_SPLIT_TUNNEL_ENABLED, false)
                val splitTunnelMode =
                    intent.getStringExtra(EXTRA_SPLIT_TUNNEL_MODE)
                        ?: VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE
                val inclusivePackages =
                    intent.getStringArrayListExtra(EXTRA_SPLIT_TUNNEL_INCLUSIVE_PACKAGES)
                val exclusivePackages =
                    intent.getStringArrayListExtra(EXTRA_SPLIT_TUNNEL_EXCLUSIVE_PACKAGES)
                val proxyHttpPort =
                    ProxyTunnelService.sanitizePort(
                        intent.getIntExtra(EXTRA_PROXY_HTTP_PORT, ProxyTunnelService.DEFAULT_HTTP_PORT),
                        ProxyTunnelService.DEFAULT_HTTP_PORT,
                    )
                val proxySocksPort =
                    ProxyTunnelService.sanitizePort(
                        intent.getIntExtra(EXTRA_PROXY_SOCKS_PORT, ProxyTunnelService.DEFAULT_SOCKS_PORT),
                        ProxyTunnelService.DEFAULT_SOCKS_PORT,
                    )
                val proxyAllowLan = intent.getBooleanExtra(EXTRA_PROXY_ALLOW_LAN, false)
                val proxyAuthEnabled = intent.getBooleanExtra(EXTRA_PROXY_AUTH_ENABLED, false)
                val proxyAuthUsername = intent.getStringExtra(EXTRA_PROXY_AUTH_USERNAME).orEmpty()
                val proxyAuthPassword = intent.getStringExtra(EXTRA_PROXY_AUTH_PASSWORD).orEmpty()
                val proxyConfig =
                    ProxyRuntimeConfig(
                        httpEnabled = true,
                        httpPort = proxyHttpPort,
                        socksEnabled = true,
                        socksPort = proxySocksPort,
                        allowLanConnections = proxyAllowLan,
                        authEnabled = proxyAuthEnabled,
                        authUsername = proxyAuthUsername,
                        authPassword = proxyAuthPassword,
                    )
                if (proxyConfig.httpPort == proxyConfig.socksPort) {
                    AppLog.e(TAG, "${prefixAttempt(attemptId)}ACTION_START invalid proxy ports http=${proxyConfig.httpPort} socks=${proxyConfig.socksPort}")
                    VpnTunnelEvents.emitEngineLog(Log.ERROR, TAG, "${prefixAttempt(attemptId)}ACTION_START rejected: duplicate proxy ports")
                    VpnTunnelEvents.emit(VpnContract.TUNNEL_FAILED, "HTTP and SOCKS5 ports must differ.", attemptId)
                    stopForegroundNotification()
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
                        running = running.get(),
                        hasSetupThread = setupThread != null,
                        hasEngineThread = engineThread != null,
                        hasTunInterface = tunInterface != null,
                        hasDnsServer = vpnDnsPacketBridge != null,
                        hasLocalProxyRuntime = localProxyRuntime != null,
                    )
                ) {
                    val previousAttemptId = currentAttemptId()
                    VpnTunnelEvents.emitEngineLog(
                        Log.DEBUG,
                        TAG,
                        "${prefixAttempt(previousAttemptId)}Stopping previous tunnel session reason=restart",
                    )
                    recordDisconnectReason(previousAttemptId, "restarted_by_app", Log.INFO)
                    stopTunnelInternal(stopReason = "restarted by app")
                }
                synchronized(sessionLock) {
                    activeAttemptId = attemptId
                    lastSessionAttemptId = attemptId
                    recordedDisconnectReason = null
                    taskRemovedDuringSession = false
                    sessionStopRequested = false
                }
                activeProxyConfig = proxyConfig
                activeServer = server
                activeProfileName = profileName.ifEmpty { null }
                RuntimeEnvironmentInfo.emit(this, TAG, prefixAttempt(attemptId), mode = VpnContract.MODE_VPN_TUNNEL)
                BatteryOptimizationDiagnostics.emitForVpnEvent(
                    context = this,
                    tag = TAG,
                    attemptPrefix = prefixAttempt(attemptId),
                    stage = "vpn_start",
                )
                VpnTunnelEvents.emitEngineLog(
                    Log.DEBUG,
                    TAG,
                    "${prefixAttempt(attemptId)}ACTION_START accepted protocol=$protocol pppAuth=$pppAuth mppe=$mppe server=$server userPresent=${user.isNotEmpty()} pskPresent=${psk.isNotEmpty()} dnsMode=${if (dnsAutomatic) "automatic" else "manual"} dns=${dnsServers.joinToString(",") { "${it.host}[${it.protocol.shortLabel}]" }} mtu=${requestedMtu?.toString() ?: "auto"} splitTunnelEnabled=$splitTunnelEnabled splitTunnelMode=$splitTunnelMode inclusiveApps=${inclusivePackages?.size ?: 0} exclusiveApps=${exclusivePackages?.size ?: 0} http=${proxyConfig.httpPort} socks=${proxyConfig.socksPort} lan=${if (proxyAllowLan) "on" else "off"}",
                )
                // TUN establish() can block; do not hold up onStartCommand after startForeground.
                val startupThread =
                    Thread(
                        {
                            startTunnel(
                                attemptId,
                                server,
                                user,
                                password,
                                psk,
                                protocol,
                                pppAuth,
                                mppe,
                                dnsAutomatic,
                                dnsServers,
                                requestedMtu,
                                splitTunnelEnabled,
                                splitTunnelMode,
                                inclusivePackages,
                                exclusivePackages,
                                proxyConfig,
                            )
                        },
                        "tun-setup",
                    )
                synchronized(sessionLock) {
                    setupThread = startupThread
                }
                startupThread.start()
                return START_STICKY
            }
            else -> {
                if (intent?.action != null) {
                    AppLog.w(TAG, "Unknown action: ${intent.action}")
                }
                if (!running.get()) {
                    stopSelf()
                }
                return START_NOT_STICKY
            }
        }
    }

    private fun hasActiveSession(): Boolean =
        TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
            running = running.get(),
            hasSetupThread = setupThread != null,
            hasEngineThread = engineThread != null,
            hasTunInterface = tunInterface != null,
            hasDnsServer = vpnDnsPacketBridge != null,
            hasLocalProxyRuntime = localProxyRuntime != null,
            hasBlockingTunInterface = blockingTunInterface != null,
        )

    private fun currentAttemptId(): String =
        synchronized(sessionLock) { activeAttemptId }

    private fun shouldHandleAttempt(attemptId: String, stage: String): Boolean {
        val currentAttemptId = currentAttemptId()
        val matches = attemptId.isEmpty() || attemptId == currentAttemptId
        if (!matches) {
            VpnTunnelEvents.emitEngineLog(
                Log.DEBUG,
                TAG,
                "${prefixAttempt(attemptId)}Ignoring stale attempt stage=$stage activeAttempt=$currentAttemptId",
            )
        }
        return matches
    }

    private fun emitAttemptState(attemptId: String, state: String, detail: String, failure: Map<String, Any>? = null): Boolean {
        if (!shouldHandleAttempt(attemptId, "state:$state")) return false
        VpnTunnelEvents.emit(state, detail, attemptId, failure)
        return true
    }

    private fun stopServiceForAttempt(attemptId: String) {
        if (!shouldHandleAttempt(attemptId, "stop-service")) return
        synchronized(sessionLock) {
            if (setupThread === Thread.currentThread()) {
                setupThread = null
            }
            if (activeAttemptId == attemptId) {
                activeAttemptId = ""
            }
        }
        running.set(false)
        sessionStopRequested = true
        networkMonitor?.stop()
        networkMonitor = null
        supervisorLock.withLock {
            supervisorSignal.signalAll()
        }
        try {
            blockingTunInterface?.close()
        } catch (_: Exception) {
        }
        blockingTunInterface = null
        activeProxyConfig = null
        activeServer = ""
        activeProfileName = null
        connectedEmitted.set(false)
        stopForegroundNotification()
        stopSelf()
    }

    private fun clearSetupThreadIfCurrent(thread: Thread) {
        synchronized(sessionLock) {
            if (setupThread === thread) {
                setupThread = null
            }
        }
    }

    private fun clearEngineThreadIfCurrent(thread: Thread) {
        synchronized(sessionLock) {
            if (engineThread === thread) {
                engineThread = null
            }
        }
    }

    private enum class AttemptResultKind {
        CLEAN_STOP,
        RECOVERABLE_DISCONNECT,
        FATAL_FAILURE,
    }

    private data class AttemptResult(
        val kind: AttemptResultKind,
        val detail: String = "",
        val failure: Map<String, Any>? = null,
        val exitCode: Int = 0,
    )

    private fun currentProfileLabel(): String =
        activeProfileName?.takeIf { it.isNotEmpty() } ?: activeServer

    private fun postDisconnectAlertIfEligible(
        exitCode: Int = 0,
        detail: String,
        failure: Map<String, Any>? = null,
        profileLabel: String = currentProfileLabel(),
        wasConnected: Boolean = sessionHasConnected,
        userStopRequested: Boolean = sessionStopRequested,
    ) {
        if (!TunnelDisconnectNotification.shouldPostDisconnectAlert(
                userStopRequested = userStopRequested,
                hasEverConnected = wasConnected,
                isAppForeground = AppForegroundTracker.isForeground(),
            )
        ) {
            return
        }
        TunnelDisconnectNotification.show(
            context = this,
            detail = detail,
            failure = failure,
            profileLabel = profileLabel,
            exitCode = exitCode,
            wasConnected = wasConnected,
        )
    }

    private fun closePfdQuietly(pfd: ParcelFileDescriptor?) {
        if (pfd == null) return
        try {
            pfd.close()
        } catch (_: Exception) {
        }
    }

    private fun activateBlockingTun(attemptId: String) {
        if (blockingTunInterface != null) return
        if (VpnService.prepare(this) != null) return
        try {
            val pfd = Builder()
                .setSession(getString(R.string.vpn_session_name))
                .setMtu(DEFAULT_TUN_MTU)
                .addAddress(TUN_LOCAL_IPV4, 32)
                .addRoute("0.0.0.0", 0)
                .addAddress(BLOCKING_TUN_IPV6, 128)
                .addRoute("::", 0)
                .addDisallowedApplication(packageName)
                .establish()
            blockingTunInterface = pfd
            if (pfd != null) {
                VpnTunnelEvents.emitEngineLog(
                    Log.INFO,
                    TAG,
                    "${prefixAttempt(attemptId)}Blocking kill-switch TUN active",
                )
            }
        } catch (e: Exception) {
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                TAG,
                "${prefixAttempt(attemptId)}Could not establish blocking TUN: ${e.message ?: e.javaClass.simpleName}",
            )
        }
    }

    private fun closeLiveDataplane() {
        try {
            vpnDnsPacketBridge?.close()
        } catch (_: Exception) {
        }
        vpnDnsPacketBridge = null
        VpnBridge.nativeSetVpnDnsInterceptIpv4(null)
        stopLocalProxyRuntime()
        val oldTun = tunInterface
        tunInterface = null
        closePfdQuietly(oldTun)
    }

    private fun handleNetworkTransition(
        attemptId: String,
        nativeOwner: NativeTunnelOwner,
        event: NetworkTransitionEvent,
    ) {
        if (sessionStopRequested || !shouldHandleAttempt(attemptId, "network:$event")) return
        when (event) {
            NetworkTransitionEvent.GAINED_USABLE_NETWORK -> {
                VpnTunnelEvents.emitEngineLog(
                    Log.INFO,
                    TAG,
                    "${prefixAttempt(attemptId)}Physical network available; waking reconnect loop",
                )
                supervisorLock.withLock {
                    supervisorSignal.signalAll()
                }
            }
            NetworkTransitionEvent.ALL_NETWORKS_LOST,
            NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED,
            -> {
                VpnTunnelEvents.emitEngineLog(
                    Log.INFO,
                    TAG,
                    "${prefixAttempt(attemptId)}Network transition=$event; interrupting active tunnel engine",
                )
                networkInterruptEvent = event
                NativeTunnelSessions.shared.stopOwner(nativeOwner, reason = "network transition $event")
                supervisorLock.withLock {
                    supervisorSignal.signalAll()
                }
            }
            NetworkTransitionEvent.NONE -> Unit
        }
    }

    private fun waitForRecoveryCondition(
        attemptId: String,
        timeoutMs: Long?,
        waitForNetwork: Boolean,
        monitor: ActiveNetworkMonitor,
    ) {
        val deadlineMs = timeoutMs?.let { android.os.SystemClock.elapsedRealtime() + it }
        supervisorLock.withLock {
            while (!sessionStopRequested && shouldHandleAttempt(attemptId, "wait-recovery")) {
                if (waitForNetwork) {
                    if (monitor.hasUsableNetwork()) return
                    supervisorSignal.await(2_000L, TimeUnit.MILLISECONDS)
                } else {
                    if (!monitor.hasUsableNetwork()) return
                    val remaining = (deadlineMs ?: return) - android.os.SystemClock.elapsedRealtime()
                    if (remaining <= 0L) return
                    supervisorSignal.await(remaining.coerceAtMost(2_000L), TimeUnit.MILLISECONDS)
                }
            }
        }
    }

    private fun startTunnel(
        attemptId: String,
        server: String,
        user: String,
        password: String,
        psk: String,
        protocol: String,
        pppAuth: String,
        mppe: String,
        dnsAutomatic: Boolean,
        dnsServers: List<DnsServerConfig>,
        requestedMtu: Int?,
        splitTunnelEnabled: Boolean,
        splitTunnelMode: String,
        inclusivePackages: ArrayList<String>?,
        exclusivePackages: ArrayList<String>?,
        proxyConfig: ProxyRuntimeConfig,
    ) {
        val currentSetupThread = Thread.currentThread()
        val nativeOwner = nativeOwner(attemptId)
        var nativeOwnerAcquired = false
        var monitor: ActiveNetworkMonitor? = null
        try {
            cancelPendingStopSelf()
            if (running.getAndSet(true)) {
                AppLog.w(TAG, "${prefixAttempt(attemptId)}Tunnel already running")
                return
            }
            sessionStopRequested = false
            networkInterruptEvent = null
            sessionHasConnected = false
            sessionReconnectAttempt = 0
            reconnectingAlertShown = false
            connectedEmitted.set(false)
            activeProxyConfig = proxyConfig
            currentTunnelState = VpnContract.TUNNEL_CONNECTING
            currentTunnelDetail =
                if (protocol == VpnContract.PROTOCOL_PPTP) {
                    "Negotiating PPTP/GRE/PPP..."
                } else {
                    "Negotiating IKE/L2TP/PPP..."
                }

            val requestedInclusivePkgs =
                requestedInclusivePackages(
                    splitTunnelEnabled = splitTunnelEnabled,
                    splitTunnelMode = splitTunnelMode,
                    inclusivePackages = inclusivePackages,
                )
            if (splitTunnelEnabled &&
                splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE &&
                requestedInclusivePkgs.isEmpty()
            ) {
                emitAttemptState(
                    attemptId,
                    VpnContract.TUNNEL_FAILED,
                    "Inclusive split tunneling needs at least one selected app.",
                )
                VpnTunnelEvents.emitEngineLog(
                    Log.ERROR,
                    TAG,
                    "${prefixAttempt(attemptId)}Rejected start: inclusive split-tunnel list is empty",
                )
                running.set(false)
                stopServiceForAttempt(attemptId)
                return
            }
            val effectiveInclusivePkgs =
                effectiveInclusivePackages(
                    splitTunnelEnabled = splitTunnelEnabled,
                    splitTunnelMode = splitTunnelMode,
                    inclusivePackages = inclusivePackages,
                    selfPackageName = packageName,
                )
            val effectiveExclusivePkgs =
                effectiveExclusivePackages(
                    splitTunnelEnabled = splitTunnelEnabled,
                    splitTunnelMode = splitTunnelMode,
                    exclusivePackages = exclusivePackages,
                    selfPackageName = packageName,
                )

            emitAttemptState(attemptId, VpnContract.TUNNEL_CONNECTING, currentTunnelDetail)
            VpnTunnelEvents.emitEngineLog(
                Log.INFO,
                TAG,
                "${prefixAttempt(attemptId)}Starting native negotiation (${if (protocol == VpnContract.PROTOCOL_PPTP) "PPTP/GRE/PPP" else "IKE/L2TP/PPP"})",
            )
            nativeOwnerAcquired =
                NativeTunnelSessions.shared.acquire(
                    nativeOwner,
                    reason = "vpn negotiation start",
                )
            if (!nativeOwnerAcquired) {
                emitAttemptState(attemptId, VpnContract.TUNNEL_FAILED, "Tunnel engine is still stopping; try again.")
                running.set(false)
                stopServiceForAttempt(attemptId)
                return
            }

            monitor =
                ActiveNetworkMonitor(this) { event ->
                    handleNetworkTransition(attemptId, nativeOwner, event)
                }.also {
                    networkMonitor = it
                    it.start()
                }

            var immediateSwitchReconnect = false
            while (!sessionStopRequested && shouldHandleAttempt(attemptId, "supervisor")) {
                monitor.resetTunnelConnected()
                connectedEmitted.set(false)

                if (!monitor.hasUsableNetwork()) {
                    activateBlockingTun(attemptId)
                    closeLiveDataplane()
                    currentTunnelState = VpnContract.TUNNEL_WAITING_FOR_NETWORK
                    // Protocol state detail stays strictly English for logs/events; only the notification is localized.
                    currentTunnelDetail = "Waiting for network (blocking internet)"
                    emitAttemptState(attemptId, VpnContract.TUNNEL_WAITING_FOR_NETWORK, currentTunnelDetail)
                    updateForegroundNotification(AppLocaleSupport.getString(this, R.string.vpn_notification_waiting_network))
                    waitForRecoveryCondition(
                        attemptId = attemptId,
                        timeoutMs = null,
                        waitForNetwork = true,
                        monitor = monitor,
                    )
                    immediateSwitchReconnect = true
                    sessionReconnectAttempt = 0
                    continue
                }

                if (sessionHasConnected) {
                    activateBlockingTun(attemptId)
                    closeLiveDataplane()
                    currentTunnelState = VpnContract.TUNNEL_RECONNECTING
                    currentTunnelDetail = "Reconnecting..."
                    emitAttemptState(attemptId, VpnContract.TUNNEL_RECONNECTING, currentTunnelDetail)
                    updateForegroundNotification(AppLocaleSupport.getString(this, R.string.vpn_notification_reconnecting))
                    val delayMs =
                        if (immediateSwitchReconnect) {
                            0L
                        } else {
                            TunnelReconnectPolicy.backoffMsForAttempt(sessionReconnectAttempt)
                        }
                    immediateSwitchReconnect = false
                    if (delayMs > 0L) {
                        VpnTunnelEvents.emitEngineLog(
                            Log.INFO,
                            TAG,
                            "${prefixAttempt(attemptId)}Reconnecting in ${delayMs}ms (attempt=${sessionReconnectAttempt + 1})",
                        )
                        waitForRecoveryCondition(
                            attemptId = attemptId,
                            timeoutMs = delayMs,
                            waitForNetwork = false,
                            monitor = monitor,
                        )
                    }
                    if (sessionStopRequested || !shouldHandleAttempt(attemptId, "post-backoff")) {
                        break
                    }
                    if (!monitor.hasUsableNetwork()) {
                        continue
                    }
                } else {
                    immediateSwitchReconnect = false
                }

                if (VpnService.prepare(this) != null) {
                    val failure = VpnAndroidFailure.map(VpnAndroidFailure.CODE_VPN_PERMISSION_REVOKED)
                    val detail = "VPN permission is no longer granted."
                    recordDisconnectReason(attemptId, "vpn_permission_revoked", Log.WARN)
                    TunnelDisconnectNotification.cancelReconnectAlert(this)
                    postDisconnectAlertIfEligible(detail = detail, failure = failure)
                    emitAttemptState(attemptId, VpnContract.TUNNEL_FAILED, detail, failure)
                    break
                }

                networkInterruptEvent = null
                val result =
                    runTunnelAttempt(
                        attemptId = attemptId,
                        worker = currentSetupThread,
                        server = server,
                        user = user,
                        password = password,
                        psk = psk,
                        protocol = protocol,
                        pppAuth = pppAuth,
                        mppe = mppe,
                        dnsAutomatic = dnsAutomatic,
                        dnsServers = dnsServers,
                        requestedMtu = requestedMtu,
                        splitTunnelEnabled = splitTunnelEnabled,
                        splitTunnelMode = splitTunnelMode,
                        effectiveInclusivePkgs = effectiveInclusivePkgs,
                        effectiveExclusivePkgs = effectiveExclusivePkgs,
                        monitor = monitor,
                    )
                when (result.kind) {
                    AttemptResultKind.CLEAN_STOP -> {
                        if (!sessionStopRequested && !hasRecordedDisconnectReason()) {
                            val failure = result.failure ?: VpnAndroidFailure.map(VpnAndroidFailure.CODE_UNEXPECTED_STOP)
                            postDisconnectAlertIfEligible(
                                exitCode = result.exitCode,
                                detail = result.detail,
                                failure = failure,
                            )
                            recordDisconnectReason(
                                attemptId = attemptId,
                                reason = "peer_or_native_closed",
                                level = Log.WARN,
                                detail = result.detail,
                            )
                            emitAttemptState(attemptId, VpnContract.TUNNEL_FAILED, result.detail, failure)
                        }
                        break
                    }
                    AttemptResultKind.FATAL_FAILURE -> {
                        TunnelDisconnectNotification.cancelReconnectAlert(this)
                        postDisconnectAlertIfEligible(
                            exitCode = result.exitCode,
                            detail = result.detail,
                            failure = result.failure,
                        )
                        val reason =
                            if (TunnelDisconnectNotification.isPeerTeardownFailure(result.exitCode, result.failure)) {
                                "peer_closed"
                            } else {
                                "native_exit_error"
                            }
                        recordDisconnectReason(attemptId, reason, Log.ERROR, result.detail)
                        emitAttemptState(attemptId, VpnContract.TUNNEL_FAILED, result.detail, result.failure)
                        break
                    }
                    AttemptResultKind.RECOVERABLE_DISCONNECT -> {
                        immediateSwitchReconnect =
                            networkInterruptEvent == NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED
                        if (!immediateSwitchReconnect && monitor.hasUsableNetwork()) {
                            sessionReconnectAttempt++
                        } else if (!monitor.hasUsableNetwork()) {
                            sessionReconnectAttempt = 0
                        }
                        if (TunnelReconnectPolicy.shouldPostStalledReconnectAlert(
                                onlineFailureCount = sessionReconnectAttempt,
                                alreadyNotified = reconnectingAlertShown,
                            )
                        ) {
                            reconnectingAlertShown = true
                            TunnelDisconnectNotification.showStalledReconnect(
                                context = this,
                                profileLabel = currentProfileLabel(),
                            )
                        }
                        if (sessionHasConnected) {
                            activateBlockingTun(attemptId)
                        }
                        closeLiveDataplane()
                    }
                }
            }
        } catch (e: Throwable) {
            if (shouldHandleAttempt(attemptId, "startTunnel-exception")) {
                AppLog.e(TAG, "${prefixAttempt(attemptId)}startTunnel", e)
                VpnTunnelEvents.emitEngineLog(
                    Log.ERROR,
                    TAG,
                    "${prefixAttempt(attemptId)}startTunnel exception=${e.javaClass.simpleName}:${e.message}",
                )
                val detail = e.message ?: "startTunnel failed"
                TunnelDisconnectNotification.cancelReconnectAlert(this)
                postDisconnectAlertIfEligible(detail = detail)
                emitAttemptState(attemptId, VpnContract.TUNNEL_FAILED, detail)
            } else {
                VpnTunnelEvents.emitEngineLog(
                    Log.DEBUG,
                    TAG,
                    "${prefixAttempt(attemptId)}Suppressing stale startTunnel exception ${e.javaClass.simpleName}",
                )
            }
        } finally {
            monitor?.stop()
            if (networkMonitor === monitor) {
                networkMonitor = null
            }
            if (nativeOwnerAcquired) {
                NativeTunnelSessions.shared.stopOwner(nativeOwner, reason = "vpn supervisor exit")
                NativeTunnelSessions.shared.release(nativeOwner, reason = "vpn supervisor exit")
            }
            clearSetupThreadIfCurrent(currentSetupThread)
            mainHandler.post {
                finishTunnelUiOnMain(attemptId, currentSetupThread)
            }
        }
    }

    private fun runTunnelAttempt(
        attemptId: String,
        worker: Thread,
        server: String,
        user: String,
        password: String,
        psk: String,
        protocol: String,
        pppAuth: String,
        mppe: String,
        dnsAutomatic: Boolean,
        dnsServers: List<DnsServerConfig>,
        requestedMtu: Int?,
        splitTunnelEnabled: Boolean,
        splitTunnelMode: String,
        effectiveInclusivePkgs: List<String>,
        effectiveExclusivePkgs: List<String>,
        monitor: ActiveNetworkMonitor,
    ): AttemptResult {
        VpnBridge.nativeSetSocketProtectionEnabled(true)
        if (protocol == VpnContract.PROTOCOL_PPTP) {
            val helperPath = File(applicationInfo.nativeLibraryDir, PPTP_GRE_HELPER_LIB_NAME).absolutePath
            VpnBridge.nativeSetPptpRuntimeConfig(helperPath, monitor.activeInterfaceName().orEmpty())
        }
        val negotiatedClientIp = IntArray(4)
        val negotiatedPrimaryDns = IntArray(4)
        val negotiatedSecondaryDns = IntArray(4)
        val negotiatedMtu = IntArray(1)
        val negResult =
            VpnBridge.nativeNegotiate(
                server,
                user,
                password,
                psk,
                requestedMtu ?: AUTO_TUN_MTU,
                VpnBridge.protocolCode(protocol),
                VpnBridge.pppAuthCode(pppAuth),
                VpnBridge.mppeModeCode(mppe),
                negotiatedClientIp,
                negotiatedPrimaryDns,
                negotiatedSecondaryDns,
                negotiatedMtu,
            )
        VpnTunnelEvents.emitEngineLog(Log.DEBUG, TAG, "${prefixAttempt(attemptId)}nativeNegotiate finished with exit code=$negResult")
        if (sessionStopRequested || !shouldHandleAttempt(attemptId, "post-negotiate")) {
            return AttemptResult(AttemptResultKind.CLEAN_STOP, "Stopped by app")
        }
        val negInterrupt = networkInterruptEvent
        if (negResult == VpnBridge.EXIT_STOPPED && negInterrupt == null) {
            return AttemptResult(AttemptResultKind.CLEAN_STOP, "Canceled before tunnel establishment")
        }
        if (negResult != 0 || negInterrupt != null) {
            val code = if (negResult != 0) negResult else VpnBridge.EXIT_NETWORK_LOST
            val failure = VpnBridge.failure(code)
            val detail = tunnelExitDetail(code)
            val usableNow = monitor.hasUsableNetwork()
            if (negInterrupt == null &&
                TunnelReconnectPolicy.shouldFailOnInitialAttempt(
                    hasEverConnected = sessionHasConnected,
                    hasUsableNetwork = usableNow,
                    exitCode = code,
                    failure = failure,
                )
            ) {
                return AttemptResult(AttemptResultKind.FATAL_FAILURE, detail, failure, exitCode = code)
            }
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                TAG,
                "${prefixAttempt(attemptId)}Recoverable negotiation exit code=$code interrupt=$negInterrupt",
            )
            return AttemptResult(AttemptResultKind.RECOVERABLE_DISCONNECT, detail, failure, exitCode = code)
        }

        val effectiveMtu = sanitizeMtu(negotiatedMtu[0].takeIf { it > 0 } ?: (requestedMtu ?: DEFAULT_TUN_MTU))
        val tunIpv4 =
            "${negotiatedClientIp[0]}.${negotiatedClientIp[1]}.${negotiatedClientIp[2]}.${negotiatedClientIp[3]}"
        val useIpcpAddress =
            negotiatedClientIp.all { it in 0..255 } &&
                negotiatedClientIp.any { it != 0 }
        val addressForTun = if (useIpcpAddress) tunIpv4 else TUN_LOCAL_IPV4
        VpnTunnelEvents.emitEngineLog(
            Log.DEBUG,
            TAG,
            "${prefixAttempt(attemptId)}TUN addAddress=$addressForTun (IPCP=$tunIpv4 useIpcp=$useIpcpAddress) negotiatedMtu=$effectiveMtu",
        )
        val automaticDnsServers = DnsConfigSupport.negotiatedServers(negotiatedPrimaryDns, negotiatedSecondaryDns)
        val manualDnsServers =
            if (dnsAutomatic) {
                emptyList()
            } else {
                DnsConfigSupport.resolveUpstreamServers(dnsServers)
            }
        if ((dnsAutomatic && automaticDnsServers.isEmpty()) ||
            (!dnsAutomatic && manualDnsServers.isEmpty())
        ) {
            val msg =
                if (dnsAutomatic) {
                    "PPP negotiation did not provide any DNS servers."
                } else {
                    "Manual DNS requires at least one DNS server."
                }
            return AttemptResult(AttemptResultKind.FATAL_FAILURE, msg)
        }
        if (!dnsAutomatic) {
            val dnsLogger = { level: Int, message: String ->
                VpnTunnelEvents.emitEngineLog(level, TAG, "${prefixAttempt(attemptId)}$message")
            }
            vpnDnsPacketBridge =
                VpnDnsPacketBridge(
                    virtualDnsIpv4 = MANUAL_DNS_VIRTUAL_IPV4,
                    exchangeClient =
                        DirectDnsExchangeClient(
                            servers = manualDnsServers,
                            logger = dnsLogger,
                            socketProtector = serviceDnsSocketProtector(),
                        ),
                    logger = dnsLogger,
                ).also { it.start() }
            val interceptRc = VpnBridge.nativeSetVpnDnsInterceptIpv4(MANUAL_DNS_VIRTUAL_IPV4)
            if (interceptRc != 0) {
                closeLiveDataplane()
                return AttemptResult(AttemptResultKind.FATAL_FAILURE, "Manual DNS intercept setup failed.")
            }
        } else {
            VpnBridge.nativeSetVpnDnsInterceptIpv4(null)
        }

        val builder = Builder()
            .setSession(getString(R.string.vpn_session_name))
            .setMtu(effectiveMtu)
            .addAddress(addressForTun, 32)
            .addRoute("0.0.0.0", 0)
        for (dnsServer in tunDnsServersForBuilder(dnsAutomatic, automaticDnsServers)) {
            builder.addDnsServer(dnsServer)
        }
        builder.allowFamily(OsConstants.AF_INET)
        applyExcludeRouteForVpnServer(builder, server)
        if (splitTunnelEnabled && splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE) {
            for (pkg in effectiveInclusivePkgs) {
                try {
                    builder.addAllowedApplication(pkg)
                } catch (_: PackageManager.NameNotFoundException) {
                    throw IllegalArgumentException("Package not installed: $pkg")
                }
            }
        } else if (splitTunnelEnabled && splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE) {
            for (pkg in effectiveExclusivePkgs) {
                try {
                    builder.addDisallowedApplication(pkg)
                } catch (_: PackageManager.NameNotFoundException) {
                    throw IllegalArgumentException("Package not installed: $pkg")
                }
            }
        }
        val livePfd = builder.establish() ?: throw IllegalStateException("TUN establish() returned null")
        val oldLive = tunInterface
        val oldBlocking = blockingTunInterface
        tunInterface = livePfd
        blockingTunInterface = null
        closePfdQuietly(oldBlocking)
        closePfdQuietly(oldLive)

        if (sessionStopRequested || !shouldHandleAttempt(attemptId, "post-tun-establish")) {
            return AttemptResult(AttemptResultKind.CLEAN_STOP, "Stopped by app")
        }

        val tunFd = livePfd.fd
        VpnTunnelEvents.emitEngineLog(Log.INFO, TAG, "${prefixAttempt(attemptId)}TUN established; waiting for tunnel loop readiness")
        synchronized(sessionLock) {
            engineThread = worker
        }
        val code =
            try {
                VpnBridge.nativeStartLoop(tunFd)
            } finally {
                clearEngineThreadIfCurrent(worker)
            }
        VpnTunnelEvents.emitEngineLog(Log.DEBUG, TAG, "${prefixAttempt(attemptId)}nativeStartLoop exited with code=$code")

        if (sessionStopRequested || hasRecordedDisconnectReason()) {
            return AttemptResult(AttemptResultKind.CLEAN_STOP, "Stopped by app")
        }

        val interrupt = networkInterruptEvent
        if (code != VpnBridge.EXIT_PEER_CLOSED &&
            (interrupt != null ||
                code == VpnBridge.EXIT_NETWORK_LOST ||
                code == VpnBridge.EXIT_PEER_UNREACHABLE)
        ) {
            val effectiveCode =
                if (code == VpnBridge.EXIT_NETWORK_LOST || code == VpnBridge.EXIT_PEER_UNREACHABLE) {
                    code
                } else {
                    VpnBridge.EXIT_NETWORK_LOST
                }
            return AttemptResult(
                kind = AttemptResultKind.RECOVERABLE_DISCONNECT,
                detail = tunnelExitDetail(effectiveCode),
                failure = VpnBridge.failure(effectiveCode),
            )
        }

        if (code != 0) {
            val failure = VpnBridge.failure(code)
            val detail = tunnelExitDetail(code)
            if (!TunnelReconnectPolicy.isTerminalFailure(code, failure)) {
                return AttemptResult(AttemptResultKind.RECOVERABLE_DISCONNECT, detail, failure, exitCode = code)
            }
            return AttemptResult(AttemptResultKind.FATAL_FAILURE, detail, failure, exitCode = code)
        }

        return AttemptResult(AttemptResultKind.CLEAN_STOP, "Disconnected by peer or tunnel closed")
    }

    private fun hasRecordedDisconnectReason(): Boolean =
        synchronized(sessionLock) { recordedDisconnectReason != null }

    private fun recordDisconnectReason(
        attemptId: String,
        reason: String,
        level: Int = Log.INFO,
        detail: String? = null,
    ) {
        val shouldLog =
            synchronized(sessionLock) {
                if (recordedDisconnectReason != null) {
                    false
                } else {
                    recordedDisconnectReason = reason
                    true
                }
            }
        if (!shouldLog) return
        val suffix = if (detail.isNullOrBlank()) "" else " ($detail)"
        val message = "${prefixAttempt(attemptId)}VPN disconnect reason=$reason$suffix"
        if (level >= Log.WARN) {
            AppLog.w(TAG, message)
        } else {
            AppLog.i(TAG, message)
        }
    }

    /**
     * Always release TUN + worker state. Safe when the engine thread already cleared [running]
     * (otherwise [onDestroy] would return early and leak the VPN fd).
     */
    private fun stopTunnelInternal(stopReason: String = "vpn service stop") {
        sessionStopRequested = true
        networkMonitor?.stop()
        networkMonitor = null
        supervisorLock.withLock {
            supervisorSignal.signalAll()
        }
        val capturedSetupThread = setupThread
        val capturedEngineThread = engineThread
        val capturedAttemptId = synchronized(sessionLock) { activeAttemptId }
        val owner = capturedAttemptId.takeIf { it.isNotEmpty() }?.let(::nativeOwner)
        NativeTunnelSessions.shared.stopOwner(owner, reason = stopReason)
        closeLiveDataplane()
        val oldBlocking = blockingTunInterface
        blockingTunInterface = null
        closePfdQuietly(oldBlocking)
        synchronized(sessionLock) {
            activeAttemptId = ""
        }
        activeProxyConfig = null
        activeServer = ""
        activeProfileName = null
        connectedEmitted.set(false)
        running.set(false)
        val finishThreadTeardown =
            Runnable {
                try {
                    if (capturedSetupThread != null && capturedSetupThread !== Thread.currentThread()) {
                        capturedSetupThread.join(8_000)
                    }
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                try {
                    if (capturedEngineThread != null && capturedEngineThread !== Thread.currentThread()) {
                        capturedEngineThread.join(8_000)
                    }
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                synchronized(sessionLock) {
                    if (setupThread === capturedSetupThread) {
                        setupThread = null
                    }
                    if (engineThread === capturedEngineThread) {
                        engineThread = null
                    }
                }
                owner?.let {
                    NativeTunnelSessions.shared.release(it, reason = "vpn service stopped")
                }
            }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            stopLifecycleExecutor.execute(finishThreadTeardown)
        } else {
            finishThreadTeardown.run()
        }
    }

    /** Main-thread cleanup after the native worker exits (or from [finally] on the worker). */
    private fun finishTunnelUiOnMain(attemptId: String, worker: Thread) {
        if (!shouldHandleAttempt(attemptId, "finish-ui")) {
            clearEngineThreadIfCurrent(worker)
            return
        }
        clearEngineThreadIfCurrent(worker)
        running.set(false)
        sessionStopRequested = true
        networkMonitor?.stop()
        networkMonitor = null
        closeLiveDataplane()
        val oldBlocking = blockingTunInterface
        blockingTunInterface = null
        closePfdQuietly(oldBlocking)
        try {
            stopForegroundNotification()
        } catch (e: Exception) {
            AppLog.e(TAG, "stopForeground after tunnel", e)
        }
        synchronized(sessionLock) {
            if (activeAttemptId == attemptId) {
                activeAttemptId = ""
            }
        }
        activeProxyConfig = null
        activeServer = ""
        activeProfileName = null
        connectedEmitted.set(false)
        NativeTunnelSessions.shared.release(nativeOwner(attemptId), reason = "vpn loop finished")
        schedulePendingStopSelf()
    }

    private fun handleNativeTunnelReady(detail: String, worker: Thread) {
        if (engineThread !== worker) {
            AppLog.w(TAG, "Ignoring native tunnel ready from stale worker")
            return
        }
        if (!running.get() || sessionStopRequested) {
            AppLog.w(TAG, "Ignoring native tunnel ready after shutdown")
            return
        }
        val attemptId = currentAttemptId()
        try {
            startLocalProxyRuntime()
        } catch (e: Exception) {
            AppLog.e(TAG, "${prefixAttempt(attemptId)}local proxy startup failed", e)
            VpnTunnelEvents.emitEngineLog(
                Log.ERROR,
                TAG,
                "${prefixAttempt(attemptId)}Local proxy startup failed error=${e.message ?: e.javaClass.simpleName}",
            )
            val failure = VpnAndroidFailure.map(VpnAndroidFailure.CODE_LOCAL_PROXY_FAILED)
            val failDetail = e.message ?: "Local proxy startup failed"
            recordDisconnectReason(attemptId, "local_proxy_startup_failed", Log.ERROR, failDetail)
            TunnelDisconnectNotification.cancelReconnectAlert(this)
            postDisconnectAlertIfEligible(detail = failDetail, failure = failure)
            emitAttemptState(attemptId, VpnContract.TUNNEL_FAILED, failDetail, failure)
            stopTunnelInternal(stopReason = "local proxy startup failed")
            stopServiceForAttempt(attemptId)
            return
        }
        if (!connectedEmitted.compareAndSet(false, true)) {
            return
        }
        sessionHasConnected = true
        sessionReconnectAttempt = 0
        reconnectingAlertShown = false
        TunnelDisconnectNotification.cancelReconnectAlert(this)
        currentTunnelState = VpnContract.TUNNEL_CONNECTED
        currentTunnelDetail = detail
        networkMonitor?.markTunnelConnected()
        emitAttemptState(attemptId, VpnContract.TUNNEL_CONNECTED, detail)
        updateForegroundNotification(connectedNotificationText())
    }

    private fun startLocalProxyRuntime() {
        if (localProxyRuntime != null) return
        val config = activeProxyConfig ?: throw IllegalStateException("Local proxy settings are missing.")
        val exposure =
            LanProxyAddressResolver(this).resolve(
                httpPort = config.httpPort,
                socksPort = config.socksPort,
                lanRequested = config.allowLanConnections,
            )
        val portSelection =
            ProxyPortAllocator.choosePreferredThenRandom(
                requestedHttpPort = config.httpPort,
                requestedSocksPort = config.socksPort,
                bindHosts = exposure.listenerBindAddresses(),
            ) ?: throw IllegalStateException(
                "Couldn't start local proxy listeners: no available HTTP/SOCKS5 ports after ${ProxyPortAllocator.RANDOM_CHECKS} random checks.",
            )
        val effectiveConfig =
            config.copy(
                httpPort = portSelection.httpPort,
                socksPort = portSelection.socksPort,
            )
        val effectiveExposure =
            exposure.copy(
                httpPort = portSelection.httpPort,
                socksPort = portSelection.socksPort,
            )
        if (portSelection.randomFallbackUsed) {
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                TAG,
                "${prefixAttempt(activeAttemptId)}Default proxy ports unavailable; selected random fallback ports requestedHttp=${config.httpPort} requestedSocks=${config.socksPort} http=${portSelection.httpPort} socks=${portSelection.socksPort}",
            )
        } else if (portSelection.differsFrom(config.httpPort, config.socksPort)) {
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                TAG,
                "${prefixAttempt(activeAttemptId)}Proxy listener ports changed requestedHttp=${config.httpPort} requestedSocks=${config.socksPort} http=${portSelection.httpPort} socks=${portSelection.socksPort}",
            )
        }
        activeProxyConfig = effectiveConfig
        val logger = { level: Int, message: String ->
            VpnTunnelEvents.emitEngineLog(level, TAG, "${prefixAttempt(activeAttemptId)}$message")
        }
        val runtime =
            ProxyServerRuntime(
                config = localProxyRuntimeConfig(effectiveConfig, effectiveExposure),
                transport = DirectSocketProxyTransport(logger = logger),
                levelLogger = logger,
            )
        try {
            runtime.start()
            localProxyRuntime = runtime
            VpnTunnelEvents.emitProxyExposureChanged(effectiveExposure)
            effectiveExposure.warning?.let { warning ->
                VpnTunnelEvents.emitEngineLog(
                    Log.WARN,
                    TAG,
                    "${prefixAttempt(activeAttemptId)}$warning",
                )
            }
            VpnTunnelEvents.emitEngineLog(
                Log.INFO,
                TAG,
                "${prefixAttempt(activeAttemptId)}Local proxy ready ${runtime.endpointSummary()}",
            )
        } catch (e: Exception) {
            try {
                runtime.stop()
            } catch (_: Exception) {
            }
            throw IllegalStateException(
                "Couldn't start local proxy listeners: ${e.message ?: e.javaClass.simpleName}",
                e,
            )
        }
    }

    private fun serviceDnsSocketProtector(): DnsSocketProtector =
        object : DnsSocketProtector {
            override fun protect(socket: Socket): Boolean =
                this@TunnelVpnService.protect(socket)

            override fun protect(socket: DatagramSocket): Boolean =
                this@TunnelVpnService.protect(socket)
        }

    private fun stopLocalProxyRuntime() {
        val config = activeProxyConfig
        try {
            localProxyRuntime?.stop()
        } catch (e: Exception) {
            AppLog.w(TAG, "localProxyRuntime.stop", e)
        }
        localProxyRuntime = null
        VpnTunnelEvents.emitProxyExposureChanged(
            ProxyExposureInfo.inactive(
                httpPort = config?.httpPort ?: 0,
                socksPort = config?.socksPort ?: 0,
                lanRequested = config?.allowLanConnections ?: false,
            ),
        )
    }

    private fun buildNotification(text: String): Notification {
        createChannelIfNeeded()
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(AppLocaleSupport.getString(this, R.string.vpn_notification_title))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pending)
            .addAction(
                0,
                AppLocaleSupport.getString(this, R.string.vpn_notification_action_disconnect),
                disconnectPendingIntent(),
            )
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun startForegroundWithType(notification: Notification) {
        synchronized(notificationLock) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(NOTIFICATION_ID, notification)
            }
            foregroundNotificationActive = true
        }
    }

    private fun stopForegroundNotification() {
        synchronized(notificationLock) {
            foregroundNotificationActive = false
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
    }

    private fun updateForegroundNotification(text: String) {
        startForegroundWithType(buildNotification(text))
    }

    private fun currentNotificationText(): String =
        when (currentTunnelState) {
            VpnContract.TUNNEL_CONNECTED -> connectedNotificationText()
            VpnContract.TUNNEL_WAITING_FOR_NETWORK ->
                AppLocaleSupport.getString(this, R.string.vpn_notification_waiting_network)
            VpnContract.TUNNEL_RECONNECTING ->
                AppLocaleSupport.getString(this, R.string.vpn_notification_reconnecting)
            else -> AppLocaleSupport.getString(this, R.string.vpn_notification_connecting)
        }

    private fun refreshForegroundNotificationIfActive() {
        synchronized(notificationLock) {
            if (!foregroundNotificationActive) return
            val nm = getSystemService(NOTIFICATION_SERVICE) as? NotificationManager ?: return
            try {
                nm.notify(NOTIFICATION_ID, buildNotification(currentNotificationText()))
            } catch (_: SecurityException) {
                // Permission may be revoked concurrently on Android 13+.
            }
        }
    }

    private fun connectedNotificationText(): String {
        val label = activeProfileName?.takeIf { it.isNotEmpty() } ?: activeServer
        return if (label.isEmpty()) {
            AppLocaleSupport.getString(this, R.string.vpn_notification_connected)
        } else {
            AppLocaleSupport.getString(this, R.string.vpn_notification_connected_profile, label)
        }
    }

    private fun disconnectPendingIntent(): PendingIntent {
        val stopIntent = Intent(this, TunnelVpnService::class.java).apply {
            action = ACTION_STOP
        }
        return PendingIntent.getService(
            this,
            REQUEST_CODE_DISCONNECT,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun tunnelExitDetail(code: Int): String =
        when (code) {
            1 -> "IPsec negotiation failed. Check the PSK and server settings."
            2 -> "L2TP handshake failed."
            3 -> "PPP negotiation failed."
            4 -> "Tunnel poll I/O error."
            5 -> "PPTP control handshake failed."
            6 -> "Root (su) is not available on this device. PPTP requires superuser access."
            7 -> "Superuser (root) permission was denied. Grant root access to TunnelForge to use PPTP."
            8 -> "Failed to open raw GRE socket for PPTP."
            9 -> "PPTP MPPE encryption negotiation failed."
            10 -> "Invalid tunnel arguments from the app."
            11 -> "Proxy transport is not implemented yet."
            12 -> "Tunnel stopped"
            13 -> "Network connection lost."
            14 -> "VPN server stopped responding."
            15 -> "VPN server closed the connection."
            16 -> "PPTP server requires MPPE encryption, but MPPE is turned off in this profile."
            17 -> "The VPN server did not accept the selected PPP authentication method."
            else -> "Tunnel engine exited with code $code"
        }

    private fun createChannelIfNeeded() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val ch = NotificationChannel(
            CHANNEL_ID,
            AppLocaleSupport.getString(this, R.string.vpn_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        nm.createNotificationChannel(ch)
    }

    companion object {
        private const val TAG = "TunnelVpnService"
        const val ACTION_START = "io.github.evokelektrique.tunnelforge.action.START"
        const val ACTION_STOP = "io.github.evokelektrique.tunnelforge.action.STOP"
        const val EXTRA_ATTEMPT_ID = "attemptId"
        const val EXTRA_SERVER = "server"
        const val EXTRA_USER = "user"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_PSK = "psk"
        const val EXTRA_PROTOCOL = "protocol"
        const val EXTRA_PPP_AUTH = "pppAuth"
        const val EXTRA_MPPE = "mppe"
        const val EXTRA_DNS_AUTOMATIC = "dnsAutomatic"
        const val EXTRA_DNS_SERVER_1_HOST = "dnsServer1Host"
        const val EXTRA_DNS_SERVER_1_PROTOCOL = "dnsServer1Protocol"
        const val EXTRA_DNS_SERVER_2_HOST = "dnsServer2Host"
        const val EXTRA_DNS_SERVER_2_PROTOCOL = "dnsServer2Protocol"
        const val EXTRA_MTU = "mtu"
        const val EXTRA_PROFILE_NAME = "profileName"
        const val EXTRA_SPLIT_TUNNEL_ENABLED = "splitTunnelEnabled"
        const val EXTRA_SPLIT_TUNNEL_MODE = "splitTunnelMode"
        const val EXTRA_SPLIT_TUNNEL_INCLUSIVE_PACKAGES = "splitTunnelInclusivePackages"
        const val EXTRA_SPLIT_TUNNEL_EXCLUSIVE_PACKAGES = "splitTunnelExclusivePackages"
        const val EXTRA_PROXY_HTTP_PORT = "proxyHttpPort"
        const val EXTRA_PROXY_SOCKS_PORT = "proxySocksPort"
        const val EXTRA_PROXY_ALLOW_LAN = "proxyAllowLan"
        const val EXTRA_PROXY_AUTH_ENABLED = "proxyAuthEnabled"
        const val EXTRA_PROXY_AUTH_USERNAME = "proxyAuthUsername"
        const val EXTRA_PROXY_AUTH_PASSWORD = "proxyAuthPassword"

        private const val CHANNEL_ID = "tunnel_forge_vpn"
        private const val NOTIFICATION_ID = 7101
        private const val REQUEST_CODE_DISCONNECT = 7102

        /** When [EXTRA_MTU] requests automatic LCP MTU negotiation. */
        const val AUTO_TUN_MTU = 0
        /** Fallback MTU when [EXTRA_MTU] is absent or invalid. */
        const val DEFAULT_TUN_MTU = 1450
        private const val MIN_TUN_MTU = 576
        private const val MAX_TUN_MTU = 1500

        private const val TUN_LOCAL_IPV4 = "10.0.0.2"
        private const val BLOCKING_TUN_IPV6 = "fd00:7466::2"
        internal const val MANUAL_DNS_VIRTUAL_IPV4 = "198.18.0.1"
        internal const val DEFAULT_NATIVE_EXIT_STOPPED = 12
        internal const val PPTP_GRE_HELPER_LIB_NAME = "libpptp_gre_helper.so"

        fun sanitizeMtu(value: Int): Int = value.coerceIn(MIN_TUN_MTU, MAX_TUN_MTU)

        fun sanitizeOptionalMtu(value: Int?): Int? = value?.takeIf { it > 0 }?.let(::sanitizeMtu)

        private fun normalizedPackages(packages: List<String>?): List<String> =
            packages
                ?.map { it.trim() }
                ?.filter { it.isNotEmpty() }
                ?.distinct()
                .orEmpty()

        internal fun requestedInclusivePackages(
            splitTunnelEnabled: Boolean,
            splitTunnelMode: String,
            inclusivePackages: List<String>?,
        ): List<String> =
            if (splitTunnelEnabled &&
                splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE
            ) {
                normalizedPackages(inclusivePackages)
            } else {
                emptyList()
            }

        internal fun effectiveInclusivePackages(
            splitTunnelEnabled: Boolean,
            splitTunnelMode: String,
            inclusivePackages: List<String>?,
            selfPackageName: String,
        ): List<String> =
            if (splitTunnelEnabled &&
                splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE
            ) {
                (requestedInclusivePackages(splitTunnelEnabled, splitTunnelMode, inclusivePackages) + selfPackageName)
                    .distinct()
            } else {
                emptyList()
            }

        internal fun requestedExclusivePackages(
            splitTunnelEnabled: Boolean,
            splitTunnelMode: String,
            exclusivePackages: List<String>?,
            selfPackageName: String,
        ): List<String> =
            if (splitTunnelEnabled &&
                splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE
            ) {
                normalizedPackages(exclusivePackages)
                    .filterNot { it == selfPackageName }
            } else {
                emptyList()
            }

        internal fun effectiveExclusivePackages(
            splitTunnelEnabled: Boolean,
            splitTunnelMode: String,
            exclusivePackages: List<String>?,
            selfPackageName: String,
        ): List<String> =
            if (splitTunnelEnabled &&
                splitTunnelMode == VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE
            ) {
                requestedExclusivePackages(
                    splitTunnelEnabled = splitTunnelEnabled,
                    splitTunnelMode = splitTunnelMode,
                    exclusivePackages = exclusivePackages,
                    selfPackageName = selfPackageName,
                )
            } else {
                emptyList()
            }

        internal fun tunDnsServersForBuilder(
            dnsAutomatic: Boolean,
            automaticDnsServers: List<ResolvedDnsServerConfig>,
        ): List<String> =
            if (dnsAutomatic) {
                automaticDnsServers.map { it.resolvedIpv4 }
            } else {
                listOf(MANUAL_DNS_VIRTUAL_IPV4)
            }

        internal fun manualDnsServersFromIntent(intent: Intent): List<DnsServerConfig> {
            val servers =
                listOf(
                    DnsServerConfig(
                        host = intent.getStringExtra(EXTRA_DNS_SERVER_1_HOST)?.trim().orEmpty(),
                        protocol = DnsProtocol.fromWireValue(intent.getStringExtra(EXTRA_DNS_SERVER_1_PROTOCOL)),
                    ),
                    DnsServerConfig(
                        host = intent.getStringExtra(EXTRA_DNS_SERVER_2_HOST)?.trim().orEmpty(),
                        protocol = DnsProtocol.fromWireValue(intent.getStringExtra(EXTRA_DNS_SERVER_2_PROTOCOL)),
                    ),
                )
            return DnsConfigSupport.sanitize(servers)
        }

        internal fun localProxyRuntimeConfig(
            config: ProxyRuntimeConfig,
            exposure: ProxyExposureInfo,
        ): ProxyRuntimeConfig =
            config.copy(
                exposure = exposure,
                maxConcurrentClients = null,
            )

        @Volatile
        private var instance: TunnelVpnService? = null

        @JvmStatic
        fun stopActiveSessionForModeSwitch(reason: String): Boolean {
            val svc = instance ?: return false
            if (!svc.hasActiveSession()) return false
            val attemptId = svc.currentAttemptId()
            VpnTunnelEvents.emitEngineLog(
                Log.DEBUG,
                TAG,
                "${svc.prefixAttempt(attemptId)}Stopping VPN tunnel before mode switch reason=$reason",
            )
            svc.recordDisconnectReason(attemptId, "mode_switch", Log.INFO, reason)
            svc.cancelPendingStopSelf()
            svc.stopTunnelInternal(stopReason = "mode switch: $reason")
            try {
                svc.stopForegroundNotification()
                svc.stopSelf()
            } catch (e: Exception) {
                AppLog.w(TAG, "stopActiveSessionForModeSwitch", e)
            }
            return true
        }

        internal fun refreshNotificationLanguage(context: Context) {
            val nm = context.getSystemService(NOTIFICATION_SERVICE) as? NotificationManager
            if (nm != null && nm.getNotificationChannel(CHANNEL_ID) != null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        AppLocaleSupport.getString(context, R.string.vpn_notification_channel_name),
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
            instance?.refreshForegroundNotificationIfActive()
        }

        @JvmStatic
        fun protectSocketFd(fd: Int): Boolean {
            val svc = instance ?: return false
            return try {
                svc.protect(fd)
            } catch (e: Exception) {
                AppLog.e(TAG, "protect failed for fd=$fd", e)
                false
            }
        }

        @JvmStatic
        fun onNativeTunnelReady(detail: String?) {
            val svc = instance ?: return
            val readyDetail =
                detail
                    ?.takeIf { it.isNotBlank() }
                    ?: "TUN interface ready; tunnel loop active"
            val worker = Thread.currentThread()
            svc.mainHandler.post { svc.handleNativeTunnelReady(readyDetail, worker) }
        }

        @JvmStatic
        fun runtimeSnapshot(): Map<String, Any?>? {
            val svc = instance ?: return null
            if (!svc.hasActiveSession()) return null
            val attemptId =
                synchronized(svc.sessionLock) {
                    svc.activeAttemptId
                }
            val state = svc.currentTunnelState
            val connected = state == VpnContract.TUNNEL_CONNECTED
            val detail =
                when (state) {
                    VpnContract.TUNNEL_CONNECTED -> svc.connectedNotificationText()
                    VpnContract.TUNNEL_WAITING_FOR_NETWORK,
                    VpnContract.TUNNEL_RECONNECTING,
                    -> svc.currentTunnelDetail
                    else -> "Restoring active VPN tunnel session..."
                }
            val proxyConfig = svc.activeProxyConfig
            val proxyExposure =
                svc.localProxyRuntime?.exposureInfo()
                    ?: proxyConfig?.let {
                        ProxyExposureInfo.loopback(
                            httpPort = it.httpPort,
                            socksPort = it.socksPort,
                            lanRequested = it.allowLanConnections,
                            active = connected,
                        )
                    }
            return RuntimeStateSnapshot.tunnel(
                state = state,
                detail = detail,
                attemptId = attemptId,
                connectionMode = VpnContract.MODE_VPN_TUNNEL,
                proxyExposure = proxyExposure,
            )
        }
    }

    private fun nativeOwner(attemptId: String): NativeTunnelOwner =
        NativeTunnelOwner(VpnContract.MODE_VPN_TUNNEL, attemptId)

    private fun prefixAttempt(attemptId: String): String =
        if (attemptId.isEmpty()) "" else "attempt=$attemptId "
}

internal object TunnelVpnServiceStopPolicy {
    fun shouldEmitStoppedOnActionStop(
        running: Boolean,
        hasSetupThread: Boolean,
        hasEngineThread: Boolean,
        hasTunInterface: Boolean,
        hasDnsServer: Boolean,
        hasLocalProxyRuntime: Boolean,
        hasBlockingTunInterface: Boolean = false,
    ): Boolean =
        running ||
            hasSetupThread ||
            hasEngineThread ||
            hasTunInterface ||
            hasDnsServer ||
            hasLocalProxyRuntime ||
            hasBlockingTunInterface
}

internal object VpnStopAttemptPolicy {
    fun shouldIgnoreStopRequest(requestedAttemptId: String, activeAttemptId: String): Boolean =
        requestedAttemptId.isNotEmpty() && activeAttemptId.isNotEmpty() && requestedAttemptId != activeAttemptId
}

internal object VpnDisconnectReasonPolicy {
    fun shouldReportSystemDestroy(hasActiveSession: Boolean, stopRequested: Boolean): Boolean =
        hasActiveSession && !stopRequested

    fun systemDestroyReason(taskRemoved: Boolean): Pair<String, String> =
        if (taskRemoved) {
            "destroyed_by_system_after_task_removed" to "Disconnected: service stopped after app removed from recents"
        } else {
            "destroyed_by_android_system" to "Disconnected: stopped by Android system"
        }
}
