/// Wire contract shared with Android `SubscriptionContract.kt`.
class SubscriptionContract {
  SubscriptionContract._();

  static const String methodChannel =
      'io.github.evokelektrique.tunnelforge/subscriptions';

  // Dart -> Android
  static const String methodSyncSchedules = 'syncSchedules';
  static const String methodGetActiveNetworkRoute = 'getActiveNetworkRoute';
  static const String methodRequestNotificationPermission =
      'requestNotificationPermission';
  static const String methodShowProgressNotification =
      'showProgressNotification';
  static const String methodCancelProgressNotification =
      'cancelProgressNotification';
  static const String methodShowResultNotification = 'showResultNotification';
  static const String methodBackgroundRunnerReady = 'backgroundRunnerReady';

  // Android -> Dart
  static const String methodRunScheduledUpdate = 'runScheduledUpdate';

  // Arguments
  static const String argSubscriptions = 'subscriptions';
  static const String argId = 'id';
  static const String argSubscriptionId = 'subscriptionId';
  static const String argSubscriptionName = 'subscriptionName';
  static const String argAutoUpdate = 'autoUpdate';
  static const String argIntervalMinutes = 'intervalMinutes';
  static const String argIsBackground = 'isBackground';

  static const String argRoute = 'route';
  static const String argProxyHost = 'proxyHost';
  static const String argProxyPort = 'proxyPort';
  static const String argReason = 'reason';

  static const String routeDirect = 'direct';
  static const String routeLocalHttpProxy = 'localHttpProxy';
  static const String routeDefer = 'defer';

  static const String argStage = 'stage';
  static const String argProcessed = 'processed';
  static const String argTotal = 'total';
  static const String stageFetching = 'fetching';
  static const String stageApplying = 'applying';

  static const String argImported = 'imported';
  static const String argUpdated = 'updated';
  static const String argRemoved = 'removed';

  static const String outcomeSuccess = 'success';
  static const String outcomeRetry = 'retry';
  static const String outcomeFailure = 'failure';
}
