package io.github.evokelektrique.tunnelforge

/** Wire contract shared with Dart `subscription_contract.dart`. */
internal object SubscriptionContract {
    const val METHOD_CHANNEL = "io.github.evokelektrique.tunnelforge/subscriptions"

    const val METHOD_SYNC_SCHEDULES = "syncSchedules"
    const val METHOD_GET_ACTIVE_NETWORK_ROUTE = "getActiveNetworkRoute"
    const val METHOD_REQUEST_NOTIFICATION_PERMISSION = "requestNotificationPermission"
    const val METHOD_SHOW_PROGRESS_NOTIFICATION = "showProgressNotification"
    const val METHOD_CANCEL_PROGRESS_NOTIFICATION = "cancelProgressNotification"
    const val METHOD_SHOW_RESULT_NOTIFICATION = "showResultNotification"
    const val METHOD_BACKGROUND_RUNNER_READY = "backgroundRunnerReady"

    const val METHOD_RUN_SCHEDULED_UPDATE = "runScheduledUpdate"

    const val ARG_SUBSCRIPTIONS = "subscriptions"
    const val ARG_ID = "id"
    const val ARG_SUBSCRIPTION_ID = "subscriptionId"
    const val ARG_SUBSCRIPTION_NAME = "subscriptionName"
    const val ARG_AUTO_UPDATE = "autoUpdate"
    const val ARG_INTERVAL_MINUTES = "intervalMinutes"
    const val ARG_IS_BACKGROUND = "isBackground"

    const val ARG_ROUTE = "route"
    const val ARG_PROXY_HOST = "proxyHost"
    const val ARG_PROXY_PORT = "proxyPort"
    const val ARG_REASON = "reason"

    const val ROUTE_DIRECT = "direct"
    const val ROUTE_LOCAL_HTTP_PROXY = "localHttpProxy"
    const val ROUTE_DEFER = "defer"

    const val ARG_STAGE = "stage"
    const val ARG_PROCESSED = "processed"
    const val ARG_TOTAL = "total"
    const val STAGE_FETCHING = "fetching"
    const val STAGE_APPLYING = "applying"

    const val ARG_IMPORTED = "imported"
    const val ARG_UPDATED = "updated"
    const val ARG_REMOVED = "removed"

    const val OUTCOME_SUCCESS = "success"
    const val OUTCOME_RETRY = "retry"
    const val OUTCOME_FAILURE = "failure"
}
