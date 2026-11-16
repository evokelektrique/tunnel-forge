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
    private val PEER_TEARDOWN_NAMESPACES = setOf("l2tp-stopccn", "l2tp-cdn")

    private val MSCHAP_REASONS = mapOf(
        646 to "Restricted logon hours.",
        647 to "Account disabled.",
        648 to "Password expired.",
        649 to "Account not permitted.",
        691 to "Authentication failed.",
        709 to "Password change failed.",
    )

    private val STOPCCN_REASONS = mapOf(
        1 to "Server closed the control connection.",
        2 to "Server reported a general error.",
        3 to "Control connection already exists.",
        4 to "Control connection not authorized.",
        5 to "Unsupported protocol version.",
        6 to "VPN server is shutting down.",
        7 to "L2TP protocol state error.",
        8 to "Mismatching CCDS value.",
    )

    private val CDN_REASONS = mapOf(
        1 to "Carrier lost.",
        2 to "L2TP session error.",
        3 to "Session administratively disconnected.",
        4 to "Server resources temporarily unavailable.",
        5 to "Required server facilities unavailable.",
        6 to "Invalid destination.",
        7 to "No carrier detected.",
        8 to "Destination busy.",
        9 to "No dial tone.",
        10 to "Session establishment timed out.",
        11 to "No appropriate framing detected.",
        12 to "Mismatching SDS value.",
    )

    private val GENERAL_ERRORS = mapOf(
        1 to "No control connection exists",
        2 to "Invalid message length",
        3 to "Invalid field value",
        4 to "Insufficient server resources",
        5 to "Invalid session ID",
        6 to "Vendor-specific error",
        7 to "Try another server",
        8 to "Unsupported mandatory attribute",
        9 to "Try another directed server",
        10 to "Next hop unreachable",
        11 to "Next hop busy",
        12 to "Tunnel switching aggregator busy",
    )

    private val ENGINE_REASONS = mapOf(
        1 to "IPsec negotiation failed. Check the PSK and server settings.",
        2 to "L2TP handshake failed.",
        3 to "PPP negotiation failed.",
        4 to "Tunnel poll I/O error.",
        10 to "Invalid tunnel arguments from the app.",
        11 to "Proxy transport is not implemented yet.",
        13 to "Network connection lost.",
        14 to "VPN server stopped responding.",
        15 to "VPN server closed the connection.",
    )

    private val ANDROID_REASONS = mapOf(
        VpnAndroidFailure.CODE_VPN_REVOKED to "VPN was revoked by Android.",
        VpnAndroidFailure.CODE_SYSTEM_DESTROYED to "Tunnel was stopped by Android system.",
        VpnAndroidFailure.CODE_TASK_REMOVED to "Tunnel stopped after app was removed from recents.",
        VpnAndroidFailure.CODE_VPN_PERMISSION_REVOKED to "VPN permission is no longer granted.",
        VpnAndroidFailure.CODE_LOCAL_PROXY_FAILED to "Local proxy startup failed.",
        VpnAndroidFailure.CODE_UNEXPECTED_STOP to "Tunnel disconnected unexpectedly.",
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

    fun formatDisconnectMessage(
        detail: String,
        failure: Map<String, Any>? = null,
        profileLabel: String? = null,
        serverClosedText: String = "VPN server closed the connection.",
        exitCode: Int = 0,
    ): String {
        val specificReason = specificReasonForFailure(failure, exitCode, serverClosedText)
        val core =
            when {
                specificReason != null -> specificReason
                detail.isNotBlank() -> detail.trim()
                else -> "Tunnel disconnected unexpectedly."
            }
        val cleanLabel = profileLabel?.trim().orEmpty()
        return if (cleanLabel.isEmpty()) core else "$cleanLabel: $core"
    }

    fun formatStalledReconnectMessage(
        profileLabel: String? = null,
        baseText: String = "Connection lost. Reconnecting in background...",
    ): String {
        val cleanLabel = profileLabel?.trim().orEmpty()
        return if (cleanLabel.isEmpty()) baseText else "$cleanLabel: $baseText"
    }

    private fun specificReasonForFailure(
        failure: Map<String, Any>?,
        exitCode: Int,
        serverClosedText: String,
    ): String? {
        val namespace = failure?.get("namespace") as? String
        val code = (failure?.get("code") as? Number)?.toInt()
        val generalError = (failure?.get("generalError") as? Number)?.toInt() ?: 0
        if (namespace != null && code != null) {
            when (namespace) {
                "mschap" -> return MSCHAP_REASONS[code] ?: "Authentication failed (MS-CHAP $code)."
                "chap" -> return if (code == 4) "Authentication failed." else "CHAP authentication failed ($code)."
                "pap" -> return if (code == 3) "Authentication failed." else "PAP authentication failed ($code)."
                "l2tp-stopccn" -> return formatL2tpReason(STOPCCN_REASONS[code] ?: serverClosedText, code, generalError)
                "l2tp-cdn" -> return formatL2tpReason(CDN_REASONS[code] ?: serverClosedText, code, generalError)
                "engine" -> return ENGINE_REASONS[code]
                VpnAndroidFailure.NAMESPACE -> return ANDROID_REASONS[code]
            }
        }
        if (exitCode != 0) {
            return ENGINE_REASONS[exitCode]
        }
        return null
    }

    private fun formatL2tpReason(base: String, code: Int, generalError: Int): String {
        if (code == 2 && generalError != 0) {
            val suffix = GENERAL_ERRORS[generalError]
            if (suffix != null) {
                return "${base.removeSuffix(".")}: $suffix."
            }
        }
        return base
    }

    fun show(
        context: Context,
        detail: String,
        failure: Map<String, Any>? = null,
        profileLabel: String? = null,
        exitCode: Int = 0,
        wasConnected: Boolean = true,
    ) {
        val nm = notificationManagerIfPermitted(context) ?: return
        nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
        val pending = launchPendingIntent(context, NOTIFICATION_ID) ?: return
        val titleRes =
            if (wasConnected) {
                R.string.vpn_notification_disconnected_title
            } else {
                R.string.vpn_notification_connect_failed_title
            }
        val body =
            formatDisconnectMessage(
                detail = detail,
                failure = failure,
                profileLabel = profileLabel,
                serverClosedText = context.getString(R.string.vpn_notification_disconnected_server),
                exitCode = exitCode,
            )
        postNotification(
            context = context,
            nm = nm,
            notificationId = NOTIFICATION_ID,
            title = context.getString(titleRes),
            body = body,
            pending = pending,
            category = NotificationCompat.CATEGORY_ERROR,
        )
    }

    fun showStalledReconnect(
        context: Context,
        profileLabel: String? = null,
    ) {
        val nm = notificationManagerIfPermitted(context) ?: return
        val pending = launchPendingIntent(context, RECONNECT_ALERT_NOTIFICATION_ID) ?: return
        val body =
            formatStalledReconnectMessage(
                profileLabel = profileLabel,
                baseText = context.getString(R.string.vpn_notification_reconnecting_alert_body),
            )
        postNotification(
            context = context,
            nm = nm,
            notificationId = RECONNECT_ALERT_NOTIFICATION_ID,
            title = context.getString(R.string.vpn_notification_reconnecting_alert_title),
            body = body,
            pending = pending,
            category = NotificationCompat.CATEGORY_STATUS,
        )
    }

    fun cancel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(NOTIFICATION_ID)
    }

    fun cancelReconnectAlert(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
    }

    fun cancelAll(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(NOTIFICATION_ID)
        nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
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
    ) {
        val notification =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setCategory(category)
                .build()
        try {
            nm.notify(notificationId, notification)
        } catch (_: SecurityException) {
            // Permission may be revoked concurrently on Android 13+.
        }
    }

    private fun createChannelIfNeeded(context: Context, nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel =
            NotificationChannel(
                CHANNEL_ID,
                context.getString(R.string.vpn_notification_alert_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        nm.createNotificationChannel(channel)
    }
}
