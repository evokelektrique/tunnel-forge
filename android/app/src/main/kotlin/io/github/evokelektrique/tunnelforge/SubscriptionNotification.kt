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

/** Posts progress and change-summary notifications for background/automatic subscription syncs. */
internal object SubscriptionNotification {
    private const val PROGRESS_CHANNEL_ID = "tunnel_forge_subscription_progress"
    private const val RESULT_CHANNEL_ID = "tunnel_forge_subscription_results"
    private const val PROGRESS_NOTIFICATION_ID = 7201
    private const val RESULT_NOTIFICATION_BASE_ID = 7300

    fun showProgress(
        context: Context,
        subscriptionName: String,
        stage: String,
        processed: Int,
        total: Int,
    ) {
        val resContext = AppLocaleSupport.localizedContext(context)
        val nm = notificationManagerIfPermitted(resContext, isResult = false) ?: return
        val label = subscriptionName.trim().ifEmpty { resContext.getString(R.string.app_name) }
        val title = resContext.getString(R.string.subscription_notification_updating_title, label)
        val determinate = stage == SubscriptionContract.STAGE_APPLYING && total > 0
        val body =
            if (determinate) {
                resContext.getString(
                    R.string.subscription_notification_applying,
                    processed.coerceIn(0, total),
                    total,
                )
            } else {
                resContext.getString(R.string.subscription_notification_fetching)
            }

        val builder =
            NotificationCompat.Builder(resContext, PROGRESS_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSilent(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setProgress(
                    if (determinate) total else 0,
                    if (determinate) processed.coerceIn(0, total) else 0,
                    !determinate,
                )
        launchPendingIntent(context, PROGRESS_NOTIFICATION_ID)?.let(builder::setContentIntent)

        try {
            nm.notify(PROGRESS_NOTIFICATION_ID, builder.build())
        } catch (_: SecurityException) {
            // Permission may be revoked concurrently on Android 13+.
        }
    }

    fun cancelProgress(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        nm.cancel(PROGRESS_NOTIFICATION_ID)
    }

    fun showResult(
        context: Context,
        subscriptionId: String,
        subscriptionName: String,
        importedCount: Int,
        updatedCount: Int,
        removedCount: Int,
    ) {
        if (importedCount <= 0 && updatedCount <= 0 && removedCount <= 0) {
            return
        }
        val resContext = AppLocaleSupport.localizedContext(context)
        val nm = notificationManagerIfPermitted(resContext, isResult = true) ?: return
        val notificationId = resultNotificationId(subscriptionId)
        val label = subscriptionName.trim().ifEmpty { resContext.getString(R.string.app_name) }
        val title = resContext.getString(R.string.subscription_notification_updated_title, label)
        val body =
            resContext.getString(
                R.string.subscription_notification_summary,
                importedCount,
                updatedCount,
                removedCount,
            )

        val builder =
            NotificationCompat.Builder(resContext, RESULT_CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setSmallIcon(R.drawable.ic_qs_tunnel)
                .setAutoCancel(true)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
        launchPendingIntent(context, notificationId)?.let(builder::setContentIntent)

        try {
            nm.notify(notificationId, builder.build())
        } catch (_: SecurityException) {
            // Permission may be revoked concurrently on Android 13+.
        }
    }

    internal fun resultNotificationId(subscriptionId: String): Int =
        RESULT_NOTIFICATION_BASE_ID + (subscriptionId.hashCode() and 0xFF)

    private fun notificationManagerIfPermitted(
        context: Context,
        isResult: Boolean,
    ): NotificationManager? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return null
        createChannelsIfNeeded(context, nm, isResult)
        return nm
    }

    private fun createChannelsIfNeeded(
        context: Context,
        nm: NotificationManager,
        isResult: Boolean,
    ) {
        if (isResult) {
            nm.createNotificationChannel(
                NotificationChannel(
                    RESULT_CHANNEL_ID,
                    context.getString(R.string.subscription_notification_result_channel_name),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        } else {
            nm.createNotificationChannel(
                NotificationChannel(
                    PROGRESS_CHANNEL_ID,
                    context.getString(R.string.subscription_notification_progress_channel_name),
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
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
}
