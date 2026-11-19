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
        5 to "PPTP control handshake failed.",
        6 to "Root (su) is not available on this device. PPTP requires superuser access.",
        7 to "Superuser (root) permission was denied. Grant root access to TunnelForge to use PPTP.",
        8 to "Failed to open raw GRE socket for PPTP.",
        9 to "PPTP MPPE encryption negotiation failed.",
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
                "pptp-ctrl" -> return "PPTP control connection rejected (code $code)."
                "pptp-call" -> return "PPTP outgoing call rejected (code $code)."
                "pptp-cdn" -> return serverClosedText
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

    private fun specificLocalizedReason(
        resContext: Context,
        failure: Map<String, Any>?,
        exitCode: Int,
    ): String? {
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
                            else -> null
                        }
                    return if (resId != null) {
                        resContext.getString(resId)
                    } else {
                        resContext.getString(R.string.tunnel_reason_mschap_unknown, code)
                    }
                }
                "chap" -> {
                    return if (code == 4) {
                        resContext.getString(R.string.tunnel_reason_auth_failed)
                    } else {
                        resContext.getString(R.string.tunnel_reason_chap_unknown, code)
                    }
                }
                "pap" -> {
                    return if (code == 3) {
                        resContext.getString(R.string.tunnel_reason_auth_failed)
                    } else {
                        resContext.getString(R.string.tunnel_reason_pap_unknown, code)
                    }
                }
                "l2tp-stopccn" -> {
                    val base =
                        when (code) {
                            1 -> resContext.getString(R.string.tunnel_reason_stopccn_1)
                            2 -> resContext.getString(R.string.tunnel_reason_stopccn_2)
                            3 -> resContext.getString(R.string.tunnel_reason_stopccn_3)
                            4 -> resContext.getString(R.string.tunnel_reason_stopccn_4)
                            5 -> resContext.getString(R.string.tunnel_reason_stopccn_5)
                            6 -> resContext.getString(R.string.tunnel_reason_stopccn_6)
                            7 -> resContext.getString(R.string.tunnel_reason_stopccn_7)
                            8 -> resContext.getString(R.string.tunnel_reason_stopccn_8)
                            else -> resContext.getString(R.string.vpn_notification_disconnected_server)
                        }
                    return formatLocalizedL2tpReason(resContext, base, code, generalError)
                }
                "l2tp-cdn" -> {
                    val base =
                        when (code) {
                            1 -> resContext.getString(R.string.tunnel_reason_cdn_1)
                            2 -> resContext.getString(R.string.tunnel_reason_cdn_2)
                            3 -> resContext.getString(R.string.tunnel_reason_cdn_3)
                            4 -> resContext.getString(R.string.tunnel_reason_cdn_4)
                            5 -> resContext.getString(R.string.tunnel_reason_cdn_5)
                            6 -> resContext.getString(R.string.tunnel_reason_cdn_6)
                            7 -> resContext.getString(R.string.tunnel_reason_cdn_7)
                            8 -> resContext.getString(R.string.tunnel_reason_cdn_8)
                            9 -> resContext.getString(R.string.tunnel_reason_cdn_9)
                            10 -> resContext.getString(R.string.tunnel_reason_cdn_10)
                            11 -> resContext.getString(R.string.tunnel_reason_cdn_11)
                            12 -> resContext.getString(R.string.tunnel_reason_cdn_12)
                            else -> resContext.getString(R.string.vpn_notification_disconnected_server)
                        }
                    return formatLocalizedL2tpReason(resContext, base, code, generalError)
                }
                "pptp-ctrl" -> return resContext.getString(R.string.tunnel_reason_pptp_ctrl, code)
                "pptp-call" -> return resContext.getString(R.string.tunnel_reason_pptp_call, code)
                "pptp-cdn" -> return resContext.getString(R.string.vpn_notification_disconnected_server)
                "engine" -> return localizedEngineReason(resContext, code)
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
                    return resId?.let { resContext.getString(it) }
                }
            }
        }
        if (exitCode != 0) {
            return localizedEngineReason(resContext, exitCode)
        }
        return null
    }

    private fun localizedEngineReason(resContext: Context, code: Int): String? {
        val resId =
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
                else -> null
            }
        return resId?.let { resContext.getString(it) }
    }

    private fun formatLocalizedL2tpReason(
        resContext: Context,
        base: String,
        code: Int,
        generalError: Int,
    ): String {
        if (code == 2 && generalError != 0) {
            val suffixResId =
                when (generalError) {
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
            if (suffixResId != null) {
                return "${base.removeSuffix(".")}: ${resContext.getString(suffixResId)}."
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
        val resContext = AppLocaleSupport.localizedContext(context)
        val nm = notificationManagerIfPermitted(resContext) ?: return
        nm.cancel(RECONNECT_ALERT_NOTIFICATION_ID)
        val pending = launchPendingIntent(context, NOTIFICATION_ID) ?: return
        val titleRes =
            if (wasConnected) {
                R.string.vpn_notification_disconnected_title
            } else {
                R.string.vpn_notification_connect_failed_title
            }
        val specificReason = specificLocalizedReason(resContext, failure, exitCode)
        val core =
            when {
                specificReason != null -> specificReason
                detail.isNotBlank() -> detail.trim()
                else -> resContext.getString(R.string.tunnel_reason_android_6)
            }
        val cleanLabel = profileLabel?.trim().orEmpty()
        val body = if (cleanLabel.isEmpty()) core else "$cleanLabel: $core"
        postNotification(
            context = resContext,
            nm = nm,
            notificationId = NOTIFICATION_ID,
            title = resContext.getString(titleRes),
            body = body,
            pending = pending,
            category = NotificationCompat.CATEGORY_ERROR,
        )
    }

    fun showStalledReconnect(
        context: Context,
        profileLabel: String? = null,
    ) {
        val resContext = AppLocaleSupport.localizedContext(context)
        val nm = notificationManagerIfPermitted(resContext) ?: return
        val pending = launchPendingIntent(context, RECONNECT_ALERT_NOTIFICATION_ID) ?: return
        val body =
            formatStalledReconnectMessage(
                profileLabel = profileLabel,
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
