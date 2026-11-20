package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Shared registry pointing to the active foreground [MainActivity] subscription channel, if any. */
internal object SubscriptionLiveBridge {
    @Volatile
    private var liveChannel: MethodChannel? = null

    fun attach(channel: MethodChannel) {
        liveChannel = channel
    }

    fun detach(channel: MethodChannel) {
        if (liveChannel === channel) {
            liveChannel = null
        }
    }

    fun activeChannel(): MethodChannel? = liveChannel
}

/** Handles subscription platform channel calls for both live UI and headless background engines. */
internal class SubscriptionChannelHandler(
    private val context: Context,
    private val onRequestNotificationPermission: ((MethodChannel.Result) -> Unit)? = null,
    private val onBackgroundRunnerReady: (() -> Unit)? = null,
) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            SubscriptionContract.METHOD_SYNC_SCHEDULES -> {
                val args = call.arguments as? Map<*, *>
                val list = args?.get(SubscriptionContract.ARG_SUBSCRIPTIONS) as? List<*> ?: emptyList<Any>()
                SubscriptionWorkScheduler.syncSchedules(context, list)
                result.success(null)
            }
            SubscriptionContract.METHOD_GET_ACTIVE_NETWORK_ROUTE -> {
                result.success(SubscriptionRouteResolver.resolveCurrent())
            }
            SubscriptionContract.METHOD_REQUEST_NOTIFICATION_PERMISSION -> {
                val requester = onRequestNotificationPermission
                if (requester != null) {
                    requester(result)
                } else {
                    result.success(false)
                }
            }
            SubscriptionContract.METHOD_SHOW_PROGRESS_NOTIFICATION -> {
                val args = call.arguments as? Map<*, *>
                val name = args?.get(SubscriptionContract.ARG_SUBSCRIPTION_NAME)?.toString().orEmpty()
                val stage = args?.get(SubscriptionContract.ARG_STAGE)?.toString()
                    ?: SubscriptionContract.STAGE_FETCHING
                val processed = (args?.get(SubscriptionContract.ARG_PROCESSED) as? Number)?.toInt() ?: 0
                val total = (args?.get(SubscriptionContract.ARG_TOTAL) as? Number)?.toInt() ?: 0
                SubscriptionNotification.showProgress(
                    context = context,
                    subscriptionName = name,
                    stage = stage,
                    processed = processed,
                    total = total,
                )
                result.success(null)
            }
            SubscriptionContract.METHOD_CANCEL_PROGRESS_NOTIFICATION -> {
                SubscriptionNotification.cancelProgress(context)
                result.success(null)
            }
            SubscriptionContract.METHOD_SHOW_RESULT_NOTIFICATION -> {
                val args = call.arguments as? Map<*, *>
                val id = args?.get(SubscriptionContract.ARG_SUBSCRIPTION_ID)?.toString().orEmpty()
                val name = args?.get(SubscriptionContract.ARG_SUBSCRIPTION_NAME)?.toString().orEmpty()
                val imported = (args?.get(SubscriptionContract.ARG_IMPORTED) as? Number)?.toInt() ?: 0
                val updated = (args?.get(SubscriptionContract.ARG_UPDATED) as? Number)?.toInt() ?: 0
                val removed = (args?.get(SubscriptionContract.ARG_REMOVED) as? Number)?.toInt() ?: 0
                SubscriptionNotification.showResult(
                    context = context,
                    subscriptionId = id,
                    subscriptionName = name,
                    importedCount = imported,
                    updatedCount = updated,
                    removedCount = removed,
                )
                result.success(null)
            }
            SubscriptionContract.METHOD_BACKGROUND_RUNNER_READY -> {
                result.success(null)
                onBackgroundRunnerReady?.invoke()
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        fun attachDiagnosticsForHeadless(messenger: BinaryMessenger) {
            MethodChannel(messenger, DiagnosticsContract.METHOD_CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    DiagnosticsContract.APPEND_LOGS -> {
                        val entries = call.arguments as? List<*>
                        if (entries != null) {
                            for (raw in entries) {
                                val item = raw as? Map<*, *> ?: continue
                                val ts = (item[DiagnosticsContract.ARG_TS] as? Number)?.toLong()
                                    ?: System.currentTimeMillis()
                                val priority =
                                    when (item[DiagnosticsContract.ARG_LEVEL]?.toString()?.trim()?.lowercase()) {
                                        "debug" -> Log.DEBUG
                                        "warning", "warn" -> Log.WARN
                                        "error" -> Log.ERROR
                                        else -> Log.INFO
                                    }
                                val source =
                                    item[DiagnosticsContract.ARG_SOURCE]?.toString()?.takeIf { it.isNotBlank() }
                                        ?: VpnContract.LOG_SOURCE_DART
                                val tag = item[DiagnosticsContract.ARG_TAG]?.toString().orEmpty()
                                val message = item[DiagnosticsContract.ARG_MESSAGE]?.toString().orEmpty()
                                DiagnosticLog.write(priority, source, tag, message, ts)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
