package io.github.evokelektrique.tunnelforge

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

/** Posts and clears user-facing alerts when a tunnel disconnects, fails, or stalls reconnecting. */
internal object TunnelDisconnectNotification {
    private const val CHANNEL_ID = "tunnel_forge_alerts"
    private const val NOTIFICATION_ID = 7103
    private const val RECONNECT_ALERT_NOTIFICATION_ID = 7104
    private val PEER_TEARDOWN_NAMESPACES = setOf("l2tp-stopccn", "l2tp-cdn", "pptp-cdn")
    private val stateLock = Any()
    private var lastDisconnectAlert: DisconnectAlertSnapshot? = null
    private var lastStalledReconnect: StalledReconnectSnapshot? = null

    private data class DisconnectAlertSnapshot(
        val detail: String,
        val failure: Map<String, Any>?,
        val profileLabel: String?,
        val exitCode: Int,
        val wasConnected: Boolean,
    )

    private data class StalledReconnectSnapshot(
        val profileLabel: String?,
    )

    internal data class LocalizedReasonSpec(
        val resId: Int,
        val formatArg: Int? = null,
        val generalErrorResId: Int? = null,
    )

    fun shouldPostDisconnectAlert(
        userStopRequested: Boolean,
        hasEverConnected: Boolean,
        isAppForeground: Boolean,
    ): Boolean = !userStopRequested && (hasEverConnected || !isAppForeground)

    fun isPeerTeardownFailure(
        exitCode: Int,
        failure: Map<String, Any>?,
    ): Boolean {
        if (exitCode == VpnBridge.EXIT_PEER_CLOSED) return true
        val namespace = failure?.get("namespace") as? String ?: return false
        if (namespace in PEER_TEARDOWN_NAMESPACES) return true
        val code = (failure["code"] as? Number)?.toInt()
        return namespace == "engine" && code == VpnBridge.EXIT_PEER_CLOSED
    }

    fun formatStalledReconnectMessage(
        profileLabel: String? = null,
        baseText: String = "Connection lost. Reconnecting in background...",
    ): String {
        val cleanLabel = profileLabel?.trim().orEmpty()
        return if (cleanLabel.isEmpty()) baseText else "$cleanLabel: $baseText"
    }

    internal fun resolveReasonSpec(
        failure: Map<String, Any>?,
        exitCode: Int,
    ): LocalizedReasonSpec? {
        val namespace = failure?.get("namespace") as? String
        val code = (failure?.get("code") as? Number)?.toInt()
        val generalError = (failure?.get("generalError") as? Number)?.toInt() ?: 0
        if (namespace != null && code != null) {
            when (namespace) {
                "mschap" -> {
                    val resId =
                        when (code) {
                            646 -> R.string.tunnel_reason_mschap_646
                            647 -> R.string.tunnel_reason_mschap_647
                            648 -> R.string.tunnel_reason_mschap_648
                            649 -> R.string.tunnel_reason_mschap_649
                            691 -> R.string.tunnel_reason_auth_failed
                            709 -> R.string.tunnel_reason_mschap_709
                            else -> return LocalizedReasonSpec(R.string.tunnel_reason_mschap_unknown, formatArg = code)
                        }
                    return LocalizedReasonSpec(resId)
                }
                "chap" -> {
                    return if (code == 4) {
                        LocalizedReasonSpec(R.string.tunnel_reason_auth_failed)
                    } else {
                        LocalizedReasonSpec(R.string.tunnel_reason_chap_unknown, formatArg = code)
                    }
                }
                "pap" -> {
                    return if (code == 3) {
                        LocalizedReasonSpec(R.string.tunnel_reason_auth_failed)
                    } else {
                        LocalizedReasonSpec(R.string.tunnel_reason_pap_unknown, formatArg = code)
                    }
                }
                "l2tp-stopccn" -> {
                    val baseResId =
                        when (code) {
                            1 -> R.string.tunnel_reason_stopccn_1
                            2 -> R.string.tunnel_reason_stopccn_2
                            3 -> R.string.tunnel_reason_stopccn_3
                            4 -> R.string.tunnel_reason_stopccn_4
                            5 -> R.string.tunnel_reason_stopccn_5
                            6 -> R.string.tunnel_reason_stopccn_6
                            7 -> R.string.tunnel_reason_stopccn_7
                            8 -> R.string.tunnel_reason_stopccn_8
                            else -> R.string.vpn_notification_disconnected_server
                        }
                    return LocalizedReasonSpec(baseResId, generalErrorResId = generalErrorResId(code, generalError))
                }
                "l2tp-cdn" -> {
                    val baseResId =
                        when (code) {
                            1 -> R.string.tunnel_reason_cdn_1
                            2 -> R.string.tunnel_reason_cdn_2
                            3 -> R.string.tunnel_reason_cdn_3
                            4 -> R.string.tunnel_reason_cdn_4
                            5 -> R.string.tunnel_reason_cdn_5
                            6 -> R.string.tunnel_reason_cdn_6
                            7 -> R.string.tunnel_reason_cdn_7
                            8 -> R.string.tunnel_reason_cdn_8
                            9 -> R.string.tunnel_reason_cdn_9
                            10 -> R.string.tunnel_reason_cdn_10
                            11 -> R.string.tunnel_reason_cdn_11
                            12 -> R.string.tunnel_reason_cdn_12
                            else -> R.string.vpn_notification_disconnected_server
                        }
                    return LocalizedReasonSpec(baseResId, generalErrorResId = generalErrorResId(code, generalError))
                }
                "pptp-ctrl" -> return LocalizedReasonSpec(R.string.tunnel_reason_pptp_ctrl, formatArg = code)
                "pptp-call" -> return LocalizedReasonSpec(R.string.tunnel_reason_pptp_call, formatArg = code)
                "pptp-cdn" -> return LocalizedReasonSpec(R.string.vpn_notification_disconnected_server)
                "engine" -> return engineReasonResId(code)?.let { LocalizedReasonSpec(it) }
                VpnAndroidFailure.NAMESPACE -> {
                    val resId =
                        when (code) {
                            VpnAndroidFailure.CODE_VPN_REVOKED -> R.string.tunnel_reason_android_1
                            VpnAndroidFailure.CODE_SYSTEM_DESTROYED -> R.string.tunnel_reason_android_2
                            VpnAndroidFailure.CODE_TASK_REMOVED -> R.string.tunnel_reason_android_3
                            VpnAndroidFailure.CODE_VPN_PERMISSION_REVOKED -> R.string.tunnel_reason_android_4
                            VpnAndroidFailure.CODE_LOCAL_PROXY_FAILED -> R.string.tunnel_reason_android_5
                            VpnAndroidFailure.CODE_UNEXPECTED_STOP -> R.string.tunnel_reason_android_6
                            else -> null
                        }
                    return resId?.let { LocalizedReasonSpec(it) }
                }
            }
        }
        if (exitCode != 0) {
            return engineReasonResId(exitCode)?.let { LocalizedReasonSpec(it) }
        }
        return null
    }

    internal fun specificLocalizedReason(
        resContext: Context,
        failure: Map<String, Any>?,
        exitCode: Int,
    ): String? {
        val spec = resolveReasonSpec(failure, exitCode) ?: return null
        val base =
            if (spec.formatArg != null) {
                resContext.getString(spec.resId, spec.formatArg)
            } else {
                resContext.getString(spec.resId)
            }
        val suffixResId = spec.generalErrorResId ?: return base
        return "${base.removeSuffix(".")}: ${resContext.getString(suffixResId)}."
    }

    private fun engineReasonResId(code: Int): Int? =
        when (code) {
            1 -> R.string.tunnel_reason_engine_1
            2 -> R.string.tunnel_reason_engine_2
            3 -> R.string.tunnel_reason_engine_3
            4 -> R.string.tunnel_reason_engine_4
            5 -> R.string.tunnel_reason_engine_5
            6 -> R.string.tunnel_reason_engine_6
            7 -> R.string.tunnel_reason_engine_7
            8 -> R.string.tunnel_reason_engine_8
            9 -> R.string.tunnel_reason_engine_9
            10 -> R.string.tunnel_reason_engine_10
            11 -> R.string.tunnel_reason_engine_11
            13 -> R.string.tunnel_reason_engine_13
            14 -> R.string.tunnel_reason_engine_14
            15 -> R.string.tunnel_reason_engine_15
            16 -> R.string.tunnel_reason_engine_16
            17 -> R.string.tunnel_reason_engine_17
            else -> null
        }

    private fun generalErrorResId(
        code: Int,
        generalError: Int,
    ): Int? {
        if (code != 2 || generalError == 0) return null
        return when (generalError) {
            1 -> R.string.tunnel_reason_general_1
            2 -> R.string.tunnel_reason_general_2
            3 -> R.string.tunnel_reason_general_3
            4 -> R.string.tunnel_reason_general_4
            5 -> R.string.tunnel_reason_general_5
            6 -> R.string.tunnel_reason_general_6
            7 -> R.string.tunnel_reason_general_7
            8 -> R.string.tunnel_reason_general_8
            9 -> R.string.tunnel_reason_general_9
            10 -> R.string.tunnel_reason_general_10
            11 -> R.string.tunnel_reason_general_11
            12 -> R.string.tunnel_reason_general_12
            else -> null
        }
    }

    fun show(
        context: Context,
        detail: String,
        failure: Map<String, Any>? = null,
        profileLabel: String? = null,
        exitCode: Int = 0,
        wasConnected: Boolean = true,
    ) {
        val snapshot =
            DisconnectAlertSnapshot(
                detail = detail,
                failure = failure,
                profileLabel = profileLabel,
                exitCode = exitCode,
                wasConnected = wasConnected,
            )
        synchronized(stateLock) {
            lastDisconnectAlert = snapshot
            lastStalledReconnect = null
        }
        postDisconnectAlert(context, snapshot, silent = false)
    }

    fun showStalledReconnect(
        context: Context,
        profileLabel: String? = null,
    ) {
        val snapshot = StalledReconnectSnapshot(profileLabel = profileLabel)
        synchronized(stateLock) {
            lastStalledReconnect = snapshot
        }
        postStalledReconnect(context, snapshot, silent = false)
    }

    fun cancelReconnectAlert(context: Context) {
        synchronized(stateLock) {
            lastStalledReconnect = null
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
    }

    fun cancelAll(context: Context) {
        synchronized(stateLock) {
            lastDisconnectAlert = null
            lastStalledReconnect = null
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(NOTIFICATION_ID)
        nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
    }

    fun refreshActiveNotifications(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) {
            createChannelIfNeeded(AppLocaleSupport.localizedContext(context), nm)
        }
        val activeIds = runCatching { nm.activeNotifications.map { it.id }.toSet() }.getOrElse { emptySet() }
        val disconnectToRefresh: DisconnectAlertSnapshot?
        val reconnectToRefresh: StalledReconnectSnapshot?
        synchronized(stateLock) {
            disconnectToRefresh =
                lastDisconnectAlert?.takeIf { NOTIFICATION_ID in activeIds }
                    ?: run {
                        lastDisconnectAlert = null
                        null
                    }
            reconnectToRefresh =
                lastStalledReconnect?.takeIf { RECONNECT_ALERT_NOTIFICATION_ID in activeIds }
                    ?: run {
                        lastStalledReconnect = null
                        null
                    }
        }
        disconnectToRefresh?.let { postDisconnectAlert(context, it, silent = true) }
        reconnectToRefresh?.let { postStalledReconnect(context, it, silent = true) }
    }

    private fun postDisconnectAlert(
        context: Context,
        snapshot: DisconnectAlertSnapshot,
        silent: Boolean,
    ) {
        val resContext = AppLocaleSupport.localizedContext(context)
        val nm = notificationManagerIfPermitted(resContext) ?: return
        if (!silent) {
            nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
        }
        val pending = launchPendingIntent(context, NOTIFICATION_ID) ?: return
        val titleRes =
            if (snapshot.wasConnected) {
                R.string.vpn_notification_disconnected_title
            } else {
                R.string.vpn_notification_connect_failed_title
            }
        val specificReason = specificLocalizedReason(resContext, snapshot.failure, snapshot.exitCode)
        val core =
            when {
                specificReason != null -> specificReason
                snapshot.detail.isNotBlank() -> snapshot.detail.trim()
                else -> resContext.getString(R.string.tunnel_reason_android_6)
            }
        val cleanLabel = snapshot.profileLabel?.trim().orEmpty()
        val body = if (cleanLabel.isEmpty()) core else "$cleanLabel: $core"
        postNotification(
            context = resContext,
            nm = nm,
            notificationId = NOTIFICATION_ID,
            title = resContext.getString(titleRes),
            body = body,
            pending = pending,
            category = NotificationCompat.CATEGORY_ERROR,
            silent = silent,
        )
    }

    private fun postStalledReconnect(
        context: Context,
        snapshot: StalledReconnectSnapshot,
        silent: Boolean,
    ) {
        val resContext = AppLocaleSupport.localizedContext(context)
        val nm = notificationManagerIfPermitted(resContext) ?: return
        val pending = launchPendingIntent(context, RECONNECT_ALERT_NOTIFICATION_ID) ?: return
        val body =
            formatStalledReconnectMessage(
                profileLabel = snapshot.profileLabel,
                baseText = resContext.getString(R.string.vpn_notification_reconnecting_alert_body),
            )
        postNotification(
            context = resContext,
            nm = nm,
            notificationId = RECONNECT_ALERT_NOTIFICATION_ID,
            title = resContext.getString(R.string.vpn_notification_reconnecting_alert_title),
            body = body,
            pending = pending,
            category = NotificationCompat.CATEGORY_STATUS,
            silent = silent,
        )
    }

    private fun notificationManagerIfPermitted(context: Context): NotificationManager? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return null
        createChannelIfNeeded(context, nm)
        return nm
    }

    private fun launchPendingIntent(context: Context, requestCode: Int): PendingIntent? {
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return null
        return PendingIntent.getActivity(
            context,
            requestCode,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun postNotification(
        context: Context,
        nm: NotificationManager,
        notificationId: Int,
        title: String,
        body: String,
        pending: PendingIntent,
        category: String,
        silent: Boolean = false,
    ) {
        val builder =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setCategory(category)
        if (silent) {
            builder.setSilent(true).setOnlyAlertOnce(true)
        }
        val notification = builder.build()
        try {
            nm.notify(notificationId, notification)
        } catch (_: SecurityException) {
            // Permission may be revoked concurrently on Android 13+.
        }
    }

    private fun createChannelIfNeeded(context: Context, nm: NotificationManager) {
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.vpn_notification_alert_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        nm.createNotificationChannel(channel)
    }
}
