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

/** Posts and clears user-facing alerts when an active tunnel is unexpectedly closed. */
internal object TunnelDisconnectNotification {
    private const val CHANNEL_ID = "tunnel_forge_alerts"
    private const val NOTIFICATION_ID = 7103
    private val PEER_TEARDOWN_NAMESPACES = setOf("l2tp-stopccn", "l2tp-cdn")

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
    ): String {
        val core =
            if (isPeerTeardownFailure(0, failure) || detail.isBlank()) {
                serverClosedText.takeIf { isPeerTeardownFailure(0, failure) }
                    ?: "Tunnel disconnected unexpectedly."
            } else {
                detail.trim()
            }
        val cleanLabel = profileLabel?.trim().orEmpty()
        return if (cleanLabel.isEmpty()) core else "$cleanLabel: $core"
    }

    fun show(
        context: Context,
        detail: String,
        failure: Map<String, Any>? = null,
        profileLabel: String? = null,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        createChannelIfNeeded(context, nm)
        val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName) ?: return
        val pending =
            PendingIntent.getActivity(
                context,
                NOTIFICATION_ID,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val body =
            formatDisconnectMessage(
                detail = detail,
                failure = failure,
                profileLabel = profileLabel,
                serverClosedText = context.getString(R.string.vpn_notification_disconnected_server),
            )
        val notification =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle(context.getString(R.string.vpn_notification_disconnected_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(android.R.drawable.stat_sys_warning)
                .setContentIntent(pending)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_ERROR)
                .build()
        try {
            nm.notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // Permission may be revoked concurrently on Android 13+.
        }
    }

    fun cancel(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(NOTIFICATION_ID)
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
