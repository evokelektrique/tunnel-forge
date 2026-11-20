package io.github.evokelektrique.tunnelforge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Foreground service for proxy-only mode.
 *
 * This reuses the real native negotiation path without VpnService socket protection. TCP proxy
 * sessions are carried by a gVisor netstack connected to the native packet bridge so this mode can
 * coexist with another app's Android VPN/TUN.
 */
class ProxyTunnelService : Service() {
    private val sessionLock = Any()
    private var worker: Thread? = null
    private var proxyRuntime: LocalProxyRuntime? = null
    private var proxyTransport: ProxyTransport? = null
    private var proxyLoopThread: Thread? = null
    private var activeProxyConfig: ProxyRuntimeConfig? = null
    private var activeAttemptId: String = ""
    private val supervisorLock = ReentrantLock()
    private val supervisorSignal = supervisorLock.newCondition()
    @Volatile
    private var connectedEmitted = false
    @Volatile
    private var stopRequested = false
    @Volatile
    private var networkInterruptEvent: NetworkTransitionEvent? = null
    @Volatile
    private var networkMonitor: ActiveNetworkMonitor? = null
    @Volatile
    private var currentTunnelState: String = VpnContract.TUNNEL_CONNECTING
    @Volatile
    private var currentTunnelDetail: String = ""
    @Volatile
    private var activeServer: String = ""
    @Volatile
    private var activeProfileName: String? = null
    @Volatile
    private var sessionHasConnected = false
    @Volatile
    private var reconnectingAlertShown = false
    private val terminalEventEmitted = AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        val wasStopRequested = stopRequested
        val attemptId = currentAttemptId()
        val profileLabel = currentProfileLabel()
        val wasConnected = sessionHasConnected
        val hadActiveSession = shutdownActiveSession(reason = "service destroy")
        if (hadActiveSession && !wasStopRequested) {
            val failure = VpnAndroidFailure.map(VpnAndroidFailure.CODE_SYSTEM_DESTROYED)
            val detail = "Disconnected: stopped by Android system"
            postDisconnectAlertIfEligible(
                detail = detail,
                failure = failure,
                profileLabel = profileLabel,
                wasConnected = wasConnected,
                userStopRequested = false,
            )
            emitTerminalState(VpnContract.TUNNEL_FAILED, detail, attemptId, failure)
        }
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                VpnTunnelEvents.emitEngineLog(Log.INFO, TAG, "ACTION_STOP: tearing down proxy service")
                val requestedAttemptId = intent.getStringExtra(EXTRA_ATTEMPT_ID) ?: ""
                val stoppedAttemptId = currentAttemptId()
                if (VpnStopAttemptPolicy.shouldIgnoreStopRequest(requestedAttemptId, stoppedAttemptId)) {
                    VpnTunnelEvents.emitEngineLog(
                        Log.DEBUG,
                        TAG,
                        "${prefixAttempt(requestedAttemptId)}Ignoring stale proxy stop activeAttempt=$stoppedAttemptId",
                    )
                    return START_NOT_STICKY
                }
                val hadActiveSession = shutdownActiveSession(reason = "app stop")
                TunnelDisconnectNotification.cancelAll(this)
                if (ProxyTunnelServiceStopPolicy.shouldEmitStoppedOnActionStop(hadActiveSession)) {
                    emitTerminalState(VpnContract.TUNNEL_STOPPED, "Stopped by app", stoppedAttemptId)
                }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_START -> {
                startForegroundWithType(buildNotification(AppLocaleSupport.getString(this, R.string.proxy_notification_starting)))
                TunnelDisconnectNotification.cancelAll(this)
                val attemptId = intent.getStringExtra(EXTRA_ATTEMPT_ID) ?: ""
                val server = intent.getStringExtra(EXTRA_SERVER)
                val user = intent.getStringExtra(EXTRA_USER) ?: ""
                val password = intent.getStringExtra(EXTRA_PASSWORD) ?: ""
                val psk = intent.getStringExtra(EXTRA_PSK) ?: ""
                val protocol =
                    if (intent.getStringExtra(EXTRA_PROTOCOL) == VpnContract.PROTOCOL_PPTP) {
                        VpnContract.PROTOCOL_PPTP
                    } else {
                        VpnContract.PROTOCOL_L2TP
                    }
                val dnsAutomatic = intent.getBooleanExtra(EXTRA_DNS_AUTOMATIC, true)
                val dnsServers = TunnelVpnService.manualDnsServersFromIntent(intent)
                val profileName = intent.getStringExtra(EXTRA_PROFILE_NAME)?.trim().orEmpty()
                val httpPort = sanitizePort(intent.getIntExtra(EXTRA_PROXY_HTTP_PORT, DEFAULT_HTTP_PORT), DEFAULT_HTTP_PORT)
                val socksPort = sanitizePort(intent.getIntExtra(EXTRA_PROXY_SOCKS_PORT, DEFAULT_SOCKS_PORT), DEFAULT_SOCKS_PORT)
                val allowLanConnections = intent.getBooleanExtra(EXTRA_PROXY_ALLOW_LAN, false)
                val proxyMtu = sanitizeMtu(intent.getIntExtra(EXTRA_MTU, DEFAULT_LINK_MTU))
                VpnTunnelEvents.emitEngineLog(
                    Log.DEBUG,
                    TAG,
                    "${prefixAttempt(attemptId)}ACTION_START accepted protocol=$protocol server=${server?.trim().orEmpty()} userPresent=${user.isNotEmpty()} pskPresent=${psk.isNotEmpty()} dnsMode=${if (dnsAutomatic) "automatic" else "manual"} dns=${dnsServers.joinToString(",") { "${it.host}[${it.protocol.shortLabel}]" }} mtu=$proxyMtu http=$httpPort socks=$socksPort lan=${if (allowLanConnections) "on" else "off"}",
                )
                if (server.isNullOrBlank()) {
                    VpnTunnelEvents.emit(VpnContract.TUNNEL_FAILED, "Invalid proxy arguments from the app.", attemptId)
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (httpPort == socksPort) {
                    VpnTunnelEvents.emit(VpnContract.TUNNEL_FAILED, "HTTP and SOCKS5 ports must differ.", attemptId)
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return START_NOT_STICKY
                }
                val proxyConfig =
                    ProxyRuntimeConfig(
                        httpEnabled = true,
                        httpPort = httpPort,
                        socksEnabled = true,
                        socksPort = socksPort,
                        allowLanConnections = allowLanConnections,
                    )
                shutdownActiveSession(reason = "restart")
                connectedEmitted = false
                stopRequested = false
                sessionHasConnected = false
                reconnectingAlertShown = false
                activeServer = server.trim()
                activeProfileName = profileName.ifEmpty { null }
                terminalEventEmitted.set(false)
                activeProxyConfig = proxyConfig
                RuntimeEnvironmentInfo.emit(this, TAG, prefixAttempt(attemptId), mode = VpnContract.MODE_PROXY_ONLY)
                val startupThread = Thread(
                    {
                        runProxyNegotiation(
                            attemptId = attemptId,
                            server = server.trim(),
                            user = user,
                            password = password,
                            psk = psk,
                            protocol = protocol,
                            dnsAutomatic = dnsAutomatic,
                            dnsServers = dnsServers,
                            profileName = profileName,
                            proxyConfig = proxyConfig,
                            proxyMtu = proxyMtu,
                        )
                    },
                    "proxy-negotiation",
                )
                synchronized(sessionLock) {
                    activeAttemptId = attemptId
                    worker = startupThread
                }
                startupThread.start()
                return START_STICKY
            }

            else -> return START_NOT_STICKY
        }
    }

    private enum class ProxyAttemptOutcomeKind {
        CLEAN_STOP,
        RECOVERABLE_DISCONNECT,
        FATAL_FAILURE,
    }

    private data class ProxyAttemptOutcome(
        val kind: ProxyAttemptOutcomeKind,
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
        userStopRequested: Boolean = stopRequested,
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

    private fun handleNetworkTransition(
        attemptId: String,
        nativeOwner: NativeTunnelOwner,
        event: NetworkTransitionEvent,
    ) {
        if (stopRequested || !shouldHandleAttempt(attemptId, "proxy-network:$event")) return
        when (event) {
            NetworkTransitionEvent.GAINED_USABLE_NETWORK -> {
                VpnTunnelEvents.emitEngineLog(
                    Log.INFO,
                    TAG,
                    "${prefixAttempt(attemptId)}Physical network available; waking proxy reconnect loop",
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
                    "${prefixAttempt(attemptId)}Proxy network transition=$event; interrupting active tunnel",
                )
                networkInterruptEvent = event
                NativeTunnelSessions.shared.stopOwner(nativeOwner, reason = "proxy network transition $event")
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
            while (!stopRequested && shouldHandleAttempt(attemptId, "proxy-wait-recovery")) {
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

    private fun runProxyNegotiation(
        attemptId: String,
        server: String,
        user: String,
        password: String,
        psk: String,
        protocol: String,
        dnsAutomatic: Boolean,
        dnsServers: List<DnsServerConfig>,
        profileName: String,
        proxyConfig: ProxyRuntimeConfig,
        proxyMtu: Int,
    ) {
        val label = profileName.ifEmpty { server }
        val currentWorker = Thread.currentThread()
        val nativeOwner = NativeTunnelOwner(VpnContract.MODE_PROXY_ONLY, attemptId)
        var nativeOwnerAcquired = false
        var monitor: ActiveNetworkMonitor? = null
        currentTunnelState = VpnContract.TUNNEL_CONNECTING
        currentTunnelDetail = "Negotiating tunnel for local proxy (${label.ifEmpty { "profile" }})..."
        emitAttemptState(attemptId, VpnContract.TUNNEL_CONNECTING, currentTunnelDetail)
        VpnTunnelEvents.emitEngineLog(Log.INFO, TAG, "${prefixAttempt(attemptId)}Starting proxy negotiation")
        var hasEverConnected = false
        try {
            nativeOwnerAcquired =
                NativeTunnelSessions.shared.acquire(
                    nativeOwner,
                    reason = "proxy negotiation start",
                )
            if (!nativeOwnerAcquired) {
                val detail = "Tunnel engine is still stopping; try again."
                postDisconnectAlertIfEligible(detail = detail, profileLabel = label, wasConnected = false)
                emitAttemptTerminalState(attemptId, VpnContract.TUNNEL_FAILED, detail)
                return
            }

            monitor =
                ActiveNetworkMonitor(this) { event ->
                    handleNetworkTransition(attemptId, nativeOwner, event)
                }.also {
                    networkMonitor = it
                    it.start()
                }

            var reconnectAttempt = 0
            var immediateSwitchReconnect = false

            while (!stopRequested && shouldHandleAttempt(attemptId, "proxy-supervisor")) {
                monitor.resetTunnelConnected()
                connectedEmitted = false

                if (!monitor.hasUsableNetwork()) {
                    currentTunnelState = VpnContract.TUNNEL_WAITING_FOR_NETWORK
                    // Protocol state detail stays strictly English for logs/events; only the notification is localized.
                    currentTunnelDetail = "Waiting for network"
                    emitAttemptState(attemptId, VpnContract.TUNNEL_WAITING_FOR_NETWORK, currentTunnelDetail)
                    updateForegroundNotification(AppLocaleSupport.getString(this, R.string.proxy_notification_waiting_network))
                    waitForRecoveryCondition(
                        attemptId = attemptId,
                        timeoutMs = null,
                        waitForNetwork = true,
                        monitor = monitor,
                    )
                    immediateSwitchReconnect = true
                    reconnectAttempt = 0
                    continue
                }

                if (hasEverConnected) {
                    currentTunnelState = VpnContract.TUNNEL_RECONNECTING
                    currentTunnelDetail = "Reconnecting..."
                    emitAttemptState(attemptId, VpnContract.TUNNEL_RECONNECTING, currentTunnelDetail)
                    updateForegroundNotification(AppLocaleSupport.getString(this, R.string.vpn_notification_reconnecting))
                    val delayMs =
                        if (immediateSwitchReconnect) {
                            0L
                        } else {
                            TunnelReconnectPolicy.backoffMsForAttempt(reconnectAttempt)
                        }
                    immediateSwitchReconnect = false
                    if (delayMs > 0L) {
                        VpnTunnelEvents.emitEngineLog(
                            Log.INFO,
                            TAG,
                            "${prefixAttempt(attemptId)}Reconnecting local proxy in ${delayMs}ms (attempt=${reconnectAttempt + 1})",
                        )
                        waitForRecoveryCondition(
                            attemptId = attemptId,
                            timeoutMs = delayMs,
                            waitForNetwork = false,
                            monitor = monitor,
                        )
                    }
                    if (stopRequested || !shouldHandleAttempt(attemptId, "proxy-post-backoff")) {
                        break
                    }
                    if (!monitor.hasUsableNetwork()) {
                        continue
                    }
                } else {
                    immediateSwitchReconnect = false
                }

                networkInterruptEvent = null
                val outcome =
                    runSingleProxyAttempt(
                        attemptId = attemptId,
                        currentWorker = currentWorker,
                        nativeOwner = nativeOwner,
                        server = server,
                        user = user,
                        password = password,
                        psk = psk,
                        protocol = protocol,
                        dnsAutomatic = dnsAutomatic,
                        dnsServers = dnsServers,
                        proxyConfig = proxyConfig,
                        proxyMtu = proxyMtu,
                        hasEverConnected = hasEverConnected,
                        monitor = monitor,
                        onReady = {
                            hasEverConnected = true
                            sessionHasConnected = true
                            reconnectAttempt = 0
                            reconnectingAlertShown = false
                            TunnelDisconnectNotification.cancelReconnectAlert(this)
                        },
                    )
                when (outcome.kind) {
                    ProxyAttemptOutcomeKind.CLEAN_STOP -> {
                        if (!stopRequested) {
                            val failure = outcome.failure ?: VpnAndroidFailure.map(VpnAndroidFailure.CODE_UNEXPECTED_STOP)
                            val detail = outcome.detail.ifBlank { "Local proxy disconnected unexpectedly." }
                            postDisconnectAlertIfEligible(
                                exitCode = outcome.exitCode,
                                detail = detail,
                                failure = failure,
                                profileLabel = label,
                                wasConnected = hasEverConnected,
                            )
                            emitAttemptTerminalState(attemptId, VpnContract.TUNNEL_FAILED, detail, failure)
                        }
                        break
                    }
                    ProxyAttemptOutcomeKind.FATAL_FAILURE -> {
                        TunnelDisconnectNotification.cancelReconnectAlert(this)
                        postDisconnectAlertIfEligible(
                            exitCode = outcome.exitCode,
                            detail = outcome.detail,
                            failure = outcome.failure,
                            profileLabel = label,
                            wasConnected = hasEverConnected,
                        )
                        emitAttemptTerminalState(attemptId, VpnContract.TUNNEL_FAILED, outcome.detail, outcome.failure)
                        break
                    }
                    ProxyAttemptOutcomeKind.RECOVERABLE_DISCONNECT -> {
                        hasEverConnected = true
                        sessionHasConnected = true
                        immediateSwitchReconnect =
                            networkInterruptEvent == NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED
                        if (!immediateSwitchReconnect && monitor.hasUsableNetwork()) {
                            reconnectAttempt++
                        } else if (!monitor.hasUsableNetwork()) {
                            reconnectAttempt = 0
                        }
                        if (TunnelReconnectPolicy.shouldPostStalledReconnectAlert(
                                onlineFailureCount = reconnectAttempt,
                                alreadyNotified = reconnectingAlertShown,
                            )
                        ) {
                            reconnectingAlertShown = true
                            TunnelDisconnectNotification.showStalledReconnect(
                                context = this,
                                profileLabel = label,
                            )
                        }
                    }
                }
            }
        } catch (t: Throwable) {
            if (!stopRequested && shouldHandleAttempt(attemptId, "proxy-exception")) {
                AppLog.e(TAG, "${prefixAttempt(attemptId)}runProxyNegotiation failed", t)
                val detail = t.message ?: "proxy negotiation failed"
                TunnelDisconnectNotification.cancelReconnectAlert(this)
                postDisconnectAlertIfEligible(
                    detail = detail,
                    profileLabel = label,
                    wasConnected = hasEverConnected,
                )
                emitAttemptTerminalState(attemptId, VpnContract.TUNNEL_FAILED, detail)
            }
        } finally {
            monitor?.stop()
            if (networkMonitor === monitor) {
                networkMonitor = null
            }
            activeServer = ""
            activeProfileName = null
            sessionHasConnected = false
            reconnectingAlertShown = false
            VpnTunnelEvents.emitProxyExposureChanged(
                ProxyExposureInfo.inactive(
                    httpPort = proxyConfig.httpPort,
                    socksPort = proxyConfig.socksPort,
                    lanRequested = proxyConfig.allowLanConnections,
                ),
            )
            VpnTunnelEvents.emitEngineLog(Log.DEBUG, TAG, "${prefixAttempt(attemptId)}proxy worker finalizing")
            var shouldStopService = false
            synchronized(sessionLock) {
                if (worker === currentWorker) {
                    worker = null
                    proxyRuntime = null
                    proxyTransport = null
                    proxyLoopThread = null
                    activeProxyConfig = null
                    if (activeAttemptId == attemptId) {
                        activeAttemptId = ""
                    }
                    shouldStopService = true
                }
            }
            if (shouldStopService) {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
            if (nativeOwnerAcquired) {
                NativeTunnelSessions.shared.release(nativeOwner, reason = "proxy worker finalizing")
            }
        }
    }

    private fun runSingleProxyAttempt(
        attemptId: String,
        currentWorker: Thread,
        nativeOwner: NativeTunnelOwner,
        server: String,
        user: String,
        password: String,
        psk: String,
        protocol: String,
        dnsAutomatic: Boolean,
        dnsServers: List<DnsServerConfig>,
        proxyConfig: ProxyRuntimeConfig,
        proxyMtu: Int,
        hasEverConnected: Boolean,
        monitor: ActiveNetworkMonitor,
        onReady: () -> Unit,
    ): ProxyAttemptOutcome {
        var localRuntime: LocalProxyRuntime? = null
        var localLoopThread: Thread? = null
        var localGvisorOutboundThread: Thread? = null
        var localGvisorInboundThread: Thread? = null
        var localPacketBridge: ProxyPacketBridge? = null
        var localGvisorStarted = false
        var effectiveProxyConfig = proxyConfig
        val loopExitCode = AtomicInteger(0)
        var loopFailure: Map<String, Any>? = null
        var loopTerminalDetail: String? = null
        var loopCrashed = false

        try {
            VpnBridge.nativeSetSocketProtectionEnabled(false)
            if (protocol == VpnContract.PROTOCOL_PPTP) {
                val helperPath = File(applicationInfo.nativeLibraryDir, TunnelVpnService.PPTP_GRE_HELPER_LIB_NAME).absolutePath
                VpnBridge.nativeSetPptpRuntimeConfig(helperPath, "")
            }
            val negotiatedClientIp = IntArray(4)
            val negotiatedPrimaryDns = IntArray(4)
            val negotiatedSecondaryDns = IntArray(4)
            val negResult =
                VpnBridge.nativeNegotiate(
                    server,
                    user,
                    password,
                    psk,
                    proxyMtu,
                    VpnBridge.protocolCode(protocol),
                    negotiatedClientIp,
                    negotiatedPrimaryDns,
                    negotiatedSecondaryDns,
                )
            VpnTunnelEvents.emitEngineLog(Log.DEBUG, TAG, "${prefixAttempt(attemptId)}nativeNegotiate finished with exit code=$negResult")
            if (stopRequested) {
                return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
            }
            val negInterrupt = networkInterruptEvent
            if (negResult == TunnelVpnService.DEFAULT_NATIVE_EXIT_STOPPED && negInterrupt == null) {
                return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
            }
            if (negResult != 0 || negInterrupt != null) {
                val code = if (negResult != 0) negResult else VpnBridge.EXIT_NETWORK_LOST
                val failure = VpnBridge.failure(code)
                val detail = tunnelExitDetail(code)
                if (negInterrupt == null &&
                    TunnelReconnectPolicy.shouldFailOnInitialAttempt(
                        hasEverConnected = hasEverConnected,
                        hasUsableNetwork = monitor.hasUsableNetwork(),
                        exitCode = code,
                        failure = failure,
                    )
                ) {
                    return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.FATAL_FAILURE, detail, failure, exitCode = code)
                }
                return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.RECOVERABLE_DISCONNECT, detail, failure, exitCode = code)
            }

            val effectiveDnsServers =
                if (dnsAutomatic) {
                    DnsConfigSupport.negotiatedServers(negotiatedPrimaryDns, negotiatedSecondaryDns)
                } else {
                    DnsConfigSupport.resolveUpstreamServers(dnsServers)
                }
            if (effectiveDnsServers.isEmpty()) {
                val msg =
                    if (dnsAutomatic) {
                        "PPP negotiation did not provide any DNS servers."
                    } else {
                        "Manual DNS requires at least one DNS server."
                    }
                return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.FATAL_FAILURE, msg)
            }

            VpnTunnelEvents.emitEngineLog(
                Log.DEBUG,
                TAG,
                "${prefixAttempt(attemptId)}Negotiated tunnel clientIpv4=${negotiatedClientIp.joinToString(".")}; awaiting native packet bridge",
            )
            if (!hasEverConnected) {
                currentTunnelState = VpnContract.TUNNEL_CONNECTING
                currentTunnelDetail = "Tunnel negotiated. Starting gVisor local-proxy TCP stack..."
                emitAttemptState(attemptId, VpnContract.TUNNEL_CONNECTING, currentTunnelDetail)
            }

            val loopThread = Thread(
                {
                    ProxyTunnelLoopRunner.run(
                        attemptId = attemptId,
                        emitEngineLog = { level, message ->
                            VpnTunnelEvents.emitEngineLog(level, TAG, message)
                        },
                        startLoop = {
                            VpnBridge.nativeStartProxyLoop().also { code -> loopExitCode.set(code) }
                        },
                        detailForCode = { code ->
                            loopFailure = VpnBridge.failure(code)
                            tunnelExitDetail(code)
                        },
                        isStopRequested = { stopRequested || networkInterruptEvent != null },
                        isConnected = { connectedEmitted },
                        emitTerminal = { _, _, detail ->
                            loopTerminalDetail = detail
                        },
                        onLoopCrash = { throwable ->
                            loopCrashed = true
                            AppLog.e(TAG, "${prefixAttempt(attemptId)}nativeStartProxyLoop failed", throwable)
                        },
                    )
                },
                "proxy-loop",
            )
            localLoopThread = loopThread
            synchronized(sessionLock) {
                if (worker === currentWorker) {
                    proxyLoopThread = loopThread
                }
            }
            loopThread.start()
            VpnTunnelEvents.emitEngineLog(Log.DEBUG, TAG, "${prefixAttempt(attemptId)}waiting for native packet bridge readiness")
            if (!waitUntilProxyPacketBridgeActive()) {
                return if (!ProxyTunnelServiceStopPolicy.shouldFailBridgeReadiness(stopRequested)) {
                    ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
                } else if (networkInterruptEvent != null || !monitor.hasUsableNetwork()) {
                    ProxyAttemptOutcome(ProxyAttemptOutcomeKind.RECOVERABLE_DISCONNECT, "Network changed during proxy startup")
                } else {
                    ProxyAttemptOutcome(ProxyAttemptOutcomeKind.FATAL_FAILURE, "Native proxy packet bridge did not become ready")
                }
            }

            val gvisorStartResult = VpnBridge.nativeGvisorStart(negotiatedClientIp, proxyMtu)
            if (gvisorStartResult != 0) {
                return ProxyAttemptOutcome(
                    ProxyAttemptOutcomeKind.FATAL_FAILURE,
                    "gVisor local proxy TCP stack did not start: code $gvisorStartResult",
                )
            }
            localGvisorStarted = true
            VpnTunnelEvents.emitEngineLog(Log.INFO, TAG, "${prefixAttempt(attemptId)}gVisor proxy dataplane ready")
            val packetBridge = ProxyPacketBridge()
            if (!packetBridge.waitUntilActive(timeoutMs = 1000, pollIntervalMs = 25)) {
                return ProxyAttemptOutcome(
                    ProxyAttemptOutcomeKind.FATAL_FAILURE,
                    "Native proxy packet bridge became unavailable before gVisor startup completed",
                )
            }
            localPacketBridge = packetBridge
            val udpDnsServers = effectiveDnsServers.filter { it.protocol == DnsProtocol.dnsOverUdp }
            val dnsResolver =
                if (udpDnsServers.isNotEmpty()) {
                    TunneledDnsResolver(
                        bridge = packetBridge,
                        clientIpv4 = negotiatedClientIp.joinToString("."),
                        dnsServers = udpDnsServers,
                        openTunneledSocket = {
                            throw java.io.IOException("Only DNS-over-UDP is supported in proxy-only gVisor resolver.")
                        },
                        logger = { level, message ->
                            VpnTunnelEvents.emitEngineLog(level, TAG, "${prefixAttempt(attemptId)}$message")
                        },
                    )
                } else {
                    VpnTunnelEvents.emitEngineLog(
                        Log.WARN,
                        TAG,
                        "${prefixAttempt(attemptId)}No UDP DNS server available for tunneled proxy hostname resolution; hostname targets will fail closed instead of using Android DNS",
                    )
                    null
                }
            localGvisorOutboundThread = startGvisorOutboundPump(attemptId, loopThread, packetBridge)
            localGvisorInboundThread = startGvisorInboundPump(attemptId, loopThread, dnsResolver)
            val transport =
                GvisorProxyTransport(
                    tunneledResolver = dnsResolver?.let { resolver -> { host -> resolver.resolve(host) } },
                    requireTunneledDns = true,
                    logger = { level, message ->
                        VpnTunnelEvents.emitEngineLog(level, TAG, "${prefixAttempt(attemptId)}$message")
                    },
                )
            val exposure =
                LanProxyAddressResolver(this).resolve(
                    httpPort = proxyConfig.httpPort,
                    socksPort = proxyConfig.socksPort,
                    lanRequested = proxyConfig.allowLanConnections,
                )
            val portSelection =
                ProxyPortAllocator.choosePreferredThenRandom(
                    requestedHttpPort = proxyConfig.httpPort,
                    requestedSocksPort = proxyConfig.socksPort,
                    bindHosts = exposure.listenerBindAddresses(),
                )
                ?: return ProxyAttemptOutcome(
                    ProxyAttemptOutcomeKind.FATAL_FAILURE,
                    "Couldn't start proxy listeners: no available HTTP/SOCKS5 ports after ${ProxyPortAllocator.RANDOM_CHECKS} random checks.",
                )
            effectiveProxyConfig =
                proxyConfig.copy(
                    httpPort = portSelection.httpPort,
                    socksPort = portSelection.socksPort,
                )
            val effectiveExposure =
                exposure.copy(
                    httpPort = portSelection.httpPort,
                    socksPort = portSelection.socksPort,
                )
            val runtime = NettyProxyServerRuntime(
                config =
                    effectiveProxyConfig.copy(
                        exposure = effectiveExposure,
                        maxConcurrentClients = PROXY_ONLY_MAX_CONCURRENT_CLIENTS,
                        suppressUpstreamHttpErrors = true,
                    ),
                levelLogger = { level, message ->
                    VpnTunnelEvents.emitEngineLog(level, TAG, "${prefixAttempt(attemptId)}$message")
                },
                transport = transport,
                connectTimeoutMs = PROXY_ONLY_CONNECT_TIMEOUT_MS,
                connectResponseTimeoutMs = PROXY_ONLY_CONNECT_RESPONSE_TIMEOUT_MS,
            )
            localRuntime = runtime
            var workerReplaced = false
            synchronized(sessionLock) {
                if (worker !== currentWorker) {
                    workerReplaced = true
                } else {
                    proxyTransport = transport
                    proxyRuntime = runtime
                    proxyLoopThread = loopThread
                    activeProxyConfig = effectiveProxyConfig
                }
            }
            if (workerReplaced) {
                if (ProxyTunnelServiceStopPolicy.shouldSuppressStartupFailure(
                        stopRequested = stopRequested,
                        throwable = IllegalStateException(ProxyTunnelServiceStopPolicy.WORKER_REPLACED_MESSAGE),
                    )
                ) {
                    return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
                }
                throw IllegalStateException(ProxyTunnelServiceStopPolicy.WORKER_REPLACED_MESSAGE)
            }
            runtime.start()
            VpnTunnelEvents.emitProxyExposureChanged(effectiveExposure)
            effectiveExposure.warning?.let { warning ->
                VpnTunnelEvents.emitEngineLog(Log.WARN, TAG, "${prefixAttempt(attemptId)}$warning")
            }
            VpnTunnelEvents.emitEngineLog(
                Log.INFO,
                TAG,
                "${prefixAttempt(attemptId)}Proxy ready ${runtime.endpointSummary()}",
            )
            connectedEmitted = true
            onReady()
            monitor.markTunnelConnected()
            currentTunnelState = VpnContract.TUNNEL_CONNECTED
            val connectedDetail =
                if (portSelection.differsFrom(proxyConfig.httpPort, proxyConfig.socksPort)) {
                    "Proxy ports changed: ${runtime.endpointSummary()}"
                } else {
                    "gVisor TCP stack active. ${runtime.endpointSummary()}. Hostnames resolve before tunneled connect; IPv6 destinations are still unsupported."
                }
            currentTunnelDetail = connectedDetail
            updateForegroundNotification(runtime.endpointSummary())
            emitAttemptState(attemptId, VpnContract.TUNNEL_CONNECTED, connectedDetail)
            loopThread.join()

            if (stopRequested) {
                return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
            }
            val exitCode = loopExitCode.get()
            val interrupt = networkInterruptEvent
            if (exitCode != VpnBridge.EXIT_PEER_CLOSED &&
                (interrupt != null ||
                    exitCode == VpnBridge.EXIT_NETWORK_LOST ||
                    exitCode == VpnBridge.EXIT_PEER_UNREACHABLE)
            ) {
                val code =
                    if (exitCode == VpnBridge.EXIT_NETWORK_LOST || exitCode == VpnBridge.EXIT_PEER_UNREACHABLE) {
                        exitCode
                    } else {
                        VpnBridge.EXIT_NETWORK_LOST
                    }
                return ProxyAttemptOutcome(
                    kind = ProxyAttemptOutcomeKind.RECOVERABLE_DISCONNECT,
                    detail = tunnelExitDetail(code),
                    failure = VpnBridge.failure(code),
                    exitCode = code,
                )
            }
            if (loopCrashed) {
                return ProxyAttemptOutcome(
                    ProxyAttemptOutcomeKind.FATAL_FAILURE,
                    loopTerminalDetail ?: "nativeStartProxyLoop crashed",
                )
            }
            if (exitCode != 0 && !TunnelReconnectPolicy.isTerminalFailure(exitCode, loopFailure)) {
                return ProxyAttemptOutcome(
                    ProxyAttemptOutcomeKind.RECOVERABLE_DISCONNECT,
                    loopTerminalDetail ?: tunnelExitDetail(exitCode),
                    loopFailure,
                    exitCode = exitCode,
                )
            }
            val terminalDetail = loopTerminalDetail
            if (terminalDetail != null) {
                return ProxyAttemptOutcome(
                    ProxyAttemptOutcomeKind.FATAL_FAILURE,
                    terminalDetail,
                    loopFailure,
                    exitCode = exitCode,
                )
            }
            return ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            return if (ProxyTunnelServiceStopPolicy.shouldSuppressStartupFailure(stopRequested, e)) {
                ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
            } else {
                AppLog.e(TAG, "${prefixAttempt(attemptId)}runProxyNegotiation failed", e)
                ProxyAttemptOutcome(ProxyAttemptOutcomeKind.FATAL_FAILURE, e.message ?: "proxy startup interrupted")
            }
        } catch (t: Throwable) {
            return if (ProxyTunnelServiceStopPolicy.shouldSuppressStartupFailure(stopRequested, t)) {
                ProxyAttemptOutcome(ProxyAttemptOutcomeKind.CLEAN_STOP)
            } else {
                AppLog.e(TAG, "${prefixAttempt(attemptId)}runProxyNegotiation failed", t)
                ProxyAttemptOutcome(ProxyAttemptOutcomeKind.FATAL_FAILURE, t.message ?: "proxy startup failed")
            }
        } finally {
            localRuntime?.stop()
            synchronized(sessionLock) {
                if (proxyRuntime === localRuntime) proxyRuntime = null
                proxyTransport = null
                if (proxyLoopThread === localLoopThread) proxyLoopThread = null
            }
            localGvisorOutboundThread?.interrupt()
            localGvisorInboundThread?.interrupt()
            localPacketBridge?.stop()
            if (localGvisorStarted) {
                VpnBridge.nativeGvisorStop()
            }
            joinQuietly(localGvisorOutboundThread, 1000)
            joinQuietly(localGvisorInboundThread, 1000)
            NativeTunnelSessions.shared.stopOwner(nativeOwner, reason = "proxy attempt cleanup")
            localLoopThread?.let { loop ->
                if (loop !== Thread.currentThread() && loop.isAlive) {
                    try {
                        loop.join(ProxyTunnelServiceStopper.LOOP_JOIN_TIMEOUT_MS)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }
            }
        }
    }

    private fun shutdownActiveSession(reason: String): Boolean {
        networkMonitor?.stop()
        networkMonitor = null
        val active =
            synchronized(sessionLock) {
                stopRequested = true
                ActiveProxySession(
                    attemptId = activeAttemptId,
                    worker = worker,
                    runtime = proxyRuntime,
                    loopThread = proxyLoopThread,
                    hasTransport = proxyTransport != null,
                ).also {
                    worker = null
                    proxyRuntime = null
                    proxyTransport = null
                    proxyLoopThread = null
                    activeAttemptId = ""
                }
            }
        supervisorLock.withLock {
            supervisorSignal.signalAll()
        }
        val config = activeProxyConfig
        activeProxyConfig = null
        if (!active.hasState()) {
            if (config != null) {
                VpnTunnelEvents.emitProxyExposureChanged(
                    ProxyExposureInfo.inactive(
                        httpPort = config.httpPort,
                        socksPort = config.socksPort,
                        lanRequested = config.allowLanConnections,
                    ),
                )
            }
            return false
        }
        VpnTunnelEvents.emitEngineLog(Log.DEBUG, TAG, "Stopping previous proxy session reason=$reason")
        active.runtime?.stop()
        if (config != null) {
            VpnTunnelEvents.emitProxyExposureChanged(
                ProxyExposureInfo.inactive(
                    httpPort = config.httpPort,
                    socksPort = config.socksPort,
                    lanRequested = config.allowLanConnections,
                ),
            )
        }
        ProxyTunnelServiceStopper.stopPreviousWorker(
            worker = active.worker,
            loopThread = active.loopThread,
            onStopNativeTunnel = {
                NativeTunnelSessions.shared.stopOwner(active.nativeOwner(), reason = "proxy service stop")
            },
            logger = { level, message ->
                VpnTunnelEvents.emitEngineLog(level, TAG, message)
            },
            joinTimeoutMs = WORKER_JOIN_TIMEOUT_MS,
        )
        if (active.worker == null) {
            active.nativeOwner()?.let {
                NativeTunnelSessions.shared.release(it, reason = "proxy service stopped")
            }
        }
        return true
    }

    private fun currentAttemptId(): String =
        synchronized(sessionLock) { activeAttemptId }

    private fun waitUntilProxyPacketBridgeActive(timeoutMs: Long = 4000, pollIntervalMs: Long = 100): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (VpnBridge.nativeIsProxyPacketBridgeActive()) return true
            try {
                Thread.sleep(pollIntervalMs)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return false
            }
        }
        return VpnBridge.nativeIsProxyPacketBridgeActive()
    }

    private fun startGvisorOutboundPump(
        attemptId: String,
        loopThread: Thread,
        packetBridge: ProxyPacketBridge,
    ): Thread =
        /*
         * Outbound means "from gVisor toward the negotiated PPP tunnel". These packets are read
         * from the native gVisor queue and handed to the native packet bridge for encapsulation.
         */
        Thread(
            {
                while (!stopRequested && loopThread.isAlive && !Thread.currentThread().isInterrupted) {
                    try {
                        val packet = VpnBridge.nativeGvisorReadOutbound(PROXY_PACKET_MAX_BYTES, 50)
                        if (packet == null || packet.isEmpty()) continue
                        logGvisorPacketEvent(attemptId, "out", packet)
                        if (!packetBridge.queueOutboundPacket(packet)) {
                            VpnTunnelEvents.emitEngineLog(
                                Log.WARN,
                                TAG,
                                "${prefixAttempt(attemptId)}gVisor outbound packet enqueue failed len=${packet.size}",
                            )
                        }
                    } catch (t: Throwable) {
                        if (stopRequested || Thread.currentThread().isInterrupted) break
                        VpnTunnelEvents.emitEngineLog(
                            Log.WARN,
                            TAG,
                            "${prefixAttempt(attemptId)}gVisor outbound pump error: ${t.message ?: t.javaClass.simpleName}",
                        )
                    }
                }
            },
            "gvisor-outbound-pump",
        ).also {
            it.isDaemon = true
            it.start()
        }

    private fun startGvisorInboundPump(
        attemptId: String,
        loopThread: Thread,
        dnsResolver: TunneledDnsResolver?,
    ): Thread =
        /*
         * Inbound means "from PPP toward gVisor". DNS replies are offered to the tunneled resolver
         * before TCP packets are injected into gVisor.
         */
        Thread(
            {
                while (!stopRequested && loopThread.isAlive && !Thread.currentThread().isInterrupted) {
                    try {
                        val packet = VpnBridge.nativeReadProxyInboundPacket(PROXY_PACKET_MAX_BYTES)
                        if (packet == null || packet.isEmpty()) continue
                        if (dnsResolver != null && handleDnsInboundPacket(dnsResolver, packet)) {
                            continue
                        }
                        logGvisorPacketEvent(attemptId, "in", packet)
                        val rc = VpnBridge.nativeGvisorInjectInbound(packet)
                        if (rc != 0) {
                            VpnTunnelEvents.emitEngineLog(
                                Log.WARN,
                                TAG,
                                "${prefixAttempt(attemptId)}gVisor inbound packet inject failed rc=$rc len=${packet.size}",
                            )
                        }
                    } catch (t: Throwable) {
                        if (stopRequested || Thread.currentThread().isInterrupted) break
                        VpnTunnelEvents.emitEngineLog(
                            Log.WARN,
                            TAG,
                            "${prefixAttempt(attemptId)}gVisor inbound pump error: ${t.message ?: t.javaClass.simpleName}",
                        )
                    }
                }
            },
            "gvisor-inbound-pump",
        ).also {
            it.isDaemon = true
            it.start()
        }

    private fun handleDnsInboundPacket(dnsResolver: TunneledDnsResolver, packet: ByteArray): Boolean {
        val ipv4 = IpPacketParser.parseIpv4(packet) ?: return false
        if (ipv4.protocol != IpPacketParser.IP_PROTOCOL_UDP) return false
        val udp = IpPacketParser.parseUdp(packet, ipv4) ?: return false
        return dnsResolver.handleInboundPacket(ipv4, udp, packet)
    }

    private fun logGvisorPacketEvent(attemptId: String, direction: String, packet: ByteArray) {
        val ipv4 = IpPacketParser.parseIpv4(packet)
        if (ipv4 == null) {
            if (packet.isNotEmpty() && ((packet[0].toInt() ushr 4) and 0x0f) == 4) {
                VpnTunnelEvents.emitEngineLog(
                    Log.WARN,
                    TAG,
                    "${prefixAttempt(attemptId)}gVisor packet $direction malformed-ipv4 len=${packet.size} first=${packet.first().toInt() and 0xff}",
                )
            }
            return
        }
        if (ipv4.protocol != IpPacketParser.IP_PROTOCOL_TCP) return
        val tcp = IpPacketParser.parseTcp(packet, ipv4)
        if (tcp == null) {
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                TAG,
                "${prefixAttempt(attemptId)}gVisor packet $direction malformed-tcp ipTotal=${ipv4.totalLength} packetLen=${packet.size}",
            )
        }
    }

    private fun joinQuietly(thread: Thread?, timeoutMs: Long) {
        if (thread == null || thread === Thread.currentThread() || !thread.isAlive) return
        try {
            thread.join(timeoutMs)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    private fun shouldHandleAttempt(attemptId: String, stage: String): Boolean {
        val currentAttemptId = currentAttemptId()
        val matches = attemptId.isEmpty() || attemptId == currentAttemptId
        if (!matches) {
            VpnTunnelEvents.emitEngineLog(
                Log.DEBUG,
                TAG,
                "${prefixAttempt(attemptId)}Ignoring stale proxy attempt stage=$stage activeAttempt=$currentAttemptId",
            )
        }
        return matches
    }

    private fun emitAttemptState(attemptId: String, state: String, detail: String): Boolean {
        if (!shouldHandleAttempt(attemptId, "state:$state")) return false
        VpnTunnelEvents.emit(state, detail, attemptId)
        return true
    }

    private fun emitAttemptTerminalState(attemptId: String, state: String, detail: String, failure: Map<String, Any>? = null): Boolean {
        if (!shouldHandleAttempt(attemptId, "state:$state")) return false
        emitTerminalState(state, detail, attemptId, failure)
        return true
    }

    private fun emitTerminalState(state: String, detail: String, attemptId: String, failure: Map<String, Any>? = null) {
        if (!terminalEventEmitted.compareAndSet(false, true)) return
        VpnTunnelEvents.emit(state, detail, attemptId, failure)
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
            .setContentTitle(AppLocaleSupport.getString(this, R.string.proxy_notification_title))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setContentIntent(pending)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun startForegroundWithType(notification: Notification) {
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
    }

    private fun updateForegroundNotification(text: String) {
        startForegroundWithType(buildNotification(text))
    }

    private fun createChannelIfNeeded() {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                AppLocaleSupport.getString(this, R.string.proxy_notification_title),
                NotificationManager.IMPORTANCE_LOW,
            ),
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
            10 -> "Invalid proxy arguments from the app."
            11 -> "Proxy transport is not implemented yet."
            13 -> "Network connection lost."
            14 -> "VPN server stopped responding."
            15 -> "VPN server closed the connection."
            else -> "Tunnel engine exited with code $code"
        }

    companion object {
        private const val TAG = "ProxyTunnelService"
        const val ACTION_START = "io.github.evokelektrique.tunnelforge.action.PROXY_START"
        const val ACTION_STOP = "io.github.evokelektrique.tunnelforge.action.PROXY_STOP"
        const val EXTRA_ATTEMPT_ID = "attemptId"
        const val EXTRA_SERVER = "server"
        const val EXTRA_USER = "user"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_PSK = "psk"
        const val EXTRA_PROTOCOL = "protocol"
        const val EXTRA_DNS_AUTOMATIC = "dnsAutomatic"
        const val EXTRA_DNS_SERVER_1_HOST = TunnelVpnService.EXTRA_DNS_SERVER_1_HOST
        const val EXTRA_DNS_SERVER_1_PROTOCOL = TunnelVpnService.EXTRA_DNS_SERVER_1_PROTOCOL
        const val EXTRA_DNS_SERVER_2_HOST = TunnelVpnService.EXTRA_DNS_SERVER_2_HOST
        const val EXTRA_DNS_SERVER_2_PROTOCOL = TunnelVpnService.EXTRA_DNS_SERVER_2_PROTOCOL
        const val EXTRA_MTU = "mtu"
        const val EXTRA_PROFILE_NAME = "profileName"
        const val EXTRA_PROXY_HTTP_PORT = "proxyHttpPort"
        const val EXTRA_PROXY_SOCKS_PORT = "proxySocksPort"
        const val EXTRA_PROXY_ALLOW_LAN = "proxyAllowLan"
        const val DEFAULT_HTTP_PORT = 8080
        const val DEFAULT_SOCKS_PORT = 1080
        const val DEFAULT_LINK_MTU = TunnelVpnService.DEFAULT_TUN_MTU
        internal const val WORKER_JOIN_TIMEOUT_MS = 5_000L
        internal val PROXY_ONLY_MAX_CONCURRENT_CLIENTS: Int? = null
        internal val PROXY_ONLY_MAX_TCP_SESSIONS: Int? = null
        internal val PROXY_ONLY_MAX_PENDING_TCP_CONNECTS: Int? = null
        internal const val PROXY_ONLY_CONNECT_TIMEOUT_MS = 60_000L
        internal const val PROXY_ONLY_CONNECT_RESPONSE_TIMEOUT_MS = 30_000L
        internal const val PROXY_PACKET_MAX_BYTES = 65_535
        internal val PROXY_ONLY_SYN_RETRANSMIT_DELAYS_MS = listOf(1_000L, 2_000L, 4_000L, 8_000L)
        internal const val PROXY_ONLY_SYN_PACING_INTERVAL_MS = 0L
        internal const val PROXY_ONLY_TCP_FIN_DRAIN_TIMEOUT_MS = 5_000L

        private const val CHANNEL_ID = "tunnel_forge_proxy"
        private const val NOTIFICATION_ID = 7111

        internal fun sanitizePort(value: Int, fallback: Int): Int = ProxyPortAllocator.sanitizePort(value, fallback)
        private fun sanitizeMtu(value: Int): Int = TunnelVpnService.sanitizeMtu(value)

        private fun prefixAttempt(attemptId: String): String = if (attemptId.isEmpty()) "" else "attempt=$attemptId "

        @Volatile
        private var instance: ProxyTunnelService? = null

        @JvmStatic
        fun stopActiveSessionForModeSwitch(reason: String): Boolean {
            val svc = instance ?: return false
            val hadActiveSession = svc.shutdownActiveSession(reason = "mode switch: $reason")
            if (!hadActiveSession) return false
            VpnTunnelEvents.emitEngineLog(
                Log.DEBUG,
                TAG,
                "Stopped proxy service before mode switch reason=$reason",
            )
            try {
                svc.stopForeground(STOP_FOREGROUND_REMOVE)
                svc.stopSelf()
            } catch (e: Exception) {
                AppLog.w(TAG, "stopActiveSessionForModeSwitch", e)
            }
            return true
        }

        @JvmStatic
        fun runtimeSnapshot(): Map<String, Any?>? {
            val svc = instance ?: return null
            val active =
                synchronized(svc.sessionLock) {
                    svc.worker != null ||
                        svc.proxyRuntime != null ||
                        svc.proxyTransport != null ||
                        svc.proxyLoopThread != null
                }
            if (!active) return null
            val attemptId = svc.currentAttemptId()
            val state = svc.currentTunnelState
            val connected = state == VpnContract.TUNNEL_CONNECTED
            val detail =
                when (state) {
                    VpnContract.TUNNEL_CONNECTED -> "Local proxy listeners are active."
                    VpnContract.TUNNEL_WAITING_FOR_NETWORK,
                    VpnContract.TUNNEL_RECONNECTING,
                    -> svc.currentTunnelDetail
                    else -> "Restoring active local proxy session..."
                }
            val exposure =
                svc.proxyRuntime?.exposureInfo()
                    ?: svc.activeProxyConfig?.let {
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
                connectionMode = VpnContract.MODE_PROXY_ONLY,
                proxyExposure = exposure,
            )
        }
    }
}

private data class ActiveProxySession(
    val attemptId: String,
    val worker: Thread?,
    val runtime: LocalProxyRuntime?,
    val loopThread: Thread?,
    val hasTransport: Boolean,
) {
    fun hasState(): Boolean = worker != null || runtime != null || loopThread != null || hasTransport

    fun nativeOwner(): NativeTunnelOwner? =
        attemptId.takeIf { it.isNotEmpty() }?.let {
            NativeTunnelOwner(VpnContract.MODE_PROXY_ONLY, it)
        }
}

internal object ProxyTunnelServiceStopper {
    internal const val LOOP_JOIN_TIMEOUT_MS = 5_000L

    fun stopPreviousWorker(
        worker: Thread?,
        loopThread: Thread? = null,
        onStopNativeTunnel: () -> Unit,
        logger: (Int, String) -> Unit,
        joinTimeoutMs: Long,
    ) {
        onStopNativeTunnel()
        joinThread(
            thread = loopThread,
            threadLabel = "proxy loop",
            logger = logger,
            joinTimeoutMs = LOOP_JOIN_TIMEOUT_MS,
        )
        if (worker == null) return
        worker.interrupt()
        joinThread(
            thread = worker,
            threadLabel = "proxy worker",
            logger = logger,
            joinTimeoutMs = joinTimeoutMs,
        )
    }

    private fun joinThread(
        thread: Thread?,
        threadLabel: String,
        logger: (Int, String) -> Unit,
        joinTimeoutMs: Long,
    ) {
        if (thread == null || thread === Thread.currentThread()) return
        try {
            thread.join(joinTimeoutMs)
            if (thread.isAlive) {
                logger(Log.WARN, "Previous $threadLabel did not exit within ${joinTimeoutMs}ms")
            } else {
                logger(Log.DEBUG, "Previous $threadLabel joined")
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            logger(Log.WARN, "Interrupted while waiting for previous $threadLabel to stop")
        }
    }
}

internal object ProxyTunnelServiceStopPolicy {
    const val WORKER_REPLACED_MESSAGE = "Proxy worker was replaced before listeners became ready."

    fun shouldEmitStoppedOnActionStop(hadActiveSession: Boolean): Boolean = hadActiveSession

    fun shouldFailBridgeReadiness(stopRequested: Boolean): Boolean = !stopRequested

    fun shouldSuppressStartupFailure(stopRequested: Boolean, throwable: Throwable): Boolean {
        if (!stopRequested) return false
        return throwable is InterruptedException ||
            (throwable is IllegalStateException && throwable.message == WORKER_REPLACED_MESSAGE)
    }
}

internal object ProxyTunnelLoopRunner {
    fun run(
        attemptId: String,
        emitEngineLog: (Int, String) -> Unit,
        startLoop: () -> Int,
        detailForCode: (Int) -> String,
        isStopRequested: () -> Boolean,
        isConnected: () -> Boolean,
        emitTerminal: (String, String, String) -> Unit,
        onLoopCrash: (Throwable) -> Unit,
    ) {
        try {
            emitEngineLog(Log.DEBUG, "${prefixAttempt(attemptId)}nativeStartProxyLoop thread running")
            val code = startLoop()
            emitEngineLog(Log.DEBUG, "${prefixAttempt(attemptId)}nativeStartProxyLoop exited with code=$code")
            if (code != 0) {
                emitTerminal(attemptId, VpnContract.TUNNEL_FAILED, detailForCode(code))
            } else if (isStopRequested()) {
                // ACTION_STOP already emitted the terminal state for user-initiated disconnects.
            } else if (isConnected()) {
                emitTerminal(attemptId, VpnContract.TUNNEL_FAILED, "Local proxy connection was lost.")
            } else {
                emitTerminal(attemptId, VpnContract.TUNNEL_FAILED, "Native local proxy TCP stack stopped before becoming ready")
            }
        } catch (t: Throwable) {
            onLoopCrash(t)
            emitTerminal(attemptId, VpnContract.TUNNEL_FAILED, t.message ?: "nativeStartProxyLoop crashed")
        }
    }

    private fun prefixAttempt(attemptId: String): String = if (attemptId.isEmpty()) "" else "attempt=$attemptId "
}
