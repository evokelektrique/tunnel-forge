import 'package:equatable/equatable.dart';
import 'package:flutter/services.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_contract.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

enum SubscriptionRouteKind { direct, localHttpProxy, defer }

class SubscriptionFetchRoute extends Equatable {
  const SubscriptionFetchRoute._({
    required this.kind,
    this.proxyHost,
    this.proxyPort,
    this.proxyUsername,
    this.proxyPassword,
    this.reason,
  });

  const SubscriptionFetchRoute.direct()
    : this._(kind: SubscriptionRouteKind.direct);

  const SubscriptionFetchRoute.localHttpProxy({
    String host = '127.0.0.1',
    required int port,
    String? proxyUsername,
    String? proxyPassword,
  }) : this._(
         kind: SubscriptionRouteKind.localHttpProxy,
         proxyHost: host,
         proxyPort: port,
         proxyUsername: proxyUsername,
         proxyPassword: proxyPassword,
       );

  const SubscriptionFetchRoute.defer({String? reason})
    : this._(kind: SubscriptionRouteKind.defer, reason: reason);

  final SubscriptionRouteKind kind;
  final String? proxyHost;
  final int? proxyPort;
  final String? proxyUsername;
  final String? proxyPassword;
  final String? reason;

  SubscriptionFetchRoute withProxyCredentials({
    required String? username,
    required String? password,
  }) {
    if (kind != SubscriptionRouteKind.localHttpProxy) return this;
    return SubscriptionFetchRoute.localHttpProxy(
      host: proxyHost ?? '127.0.0.1',
      port: proxyPort ?? ProxySettings.defaultHttpPort,
      proxyUsername: username,
      proxyPassword: password,
    );
  }

  static SubscriptionFetchRoute fromMap(Object? raw) {
    if (raw is! Map) return const SubscriptionFetchRoute.direct();
    final route = raw[SubscriptionContract.argRoute]?.toString();
    switch (route) {
      case SubscriptionContract.routeLocalHttpProxy:
        final host =
            raw[SubscriptionContract.argProxyHost]?.toString().trim() ??
            '127.0.0.1';
        final rawPort = raw[SubscriptionContract.argProxyPort];
        final port = switch (rawPort) {
          int v => v,
          num v => v.toInt(),
          _ => int.tryParse(rawPort?.toString() ?? ''),
        };
        if (port != null && ProxySettings.isAllowedPort(port)) {
          return SubscriptionFetchRoute.localHttpProxy(
            host: host.isEmpty ? '127.0.0.1' : host,
            port: port,
          );
        }
        return const SubscriptionFetchRoute.direct();
      case SubscriptionContract.routeDefer:
        return SubscriptionFetchRoute.defer(
          reason: raw[SubscriptionContract.argReason]?.toString(),
        );
      default:
        return const SubscriptionFetchRoute.direct();
    }
  }

  @override
  List<Object?> get props => [
    kind,
    proxyHost,
    proxyPort,
    proxyUsername,
    proxyPassword,
    reason,
  ];
}

typedef ScheduledSubscriptionUpdateHandler =
    Future<String> Function(
      String subscriptionId, {
      required bool isBackground,
    });

/// Platform bridge for WorkManager schedules, VPN route detection, and Android notifications.
class SubscriptionBridge {
  SubscriptionBridge({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel(SubscriptionContract.methodChannel);

  final MethodChannel _channel;
  ScheduledSubscriptionUpdateHandler? _scheduledHandler;

  void setScheduledUpdateHandler(ScheduledSubscriptionUpdateHandler? handler) {
    _scheduledHandler = handler;
    if (handler == null) {
      _channel.setMethodCallHandler(null);
      return;
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == SubscriptionContract.methodRunScheduledUpdate) {
        final args = call.arguments as Map<Object?, Object?>?;
        final subId =
            args?[SubscriptionContract.argSubscriptionId]?.toString() ?? '';
        final isBackground =
            args?[SubscriptionContract.argIsBackground] == true;
        if (subId.isEmpty) {
          return SubscriptionContract.outcomeFailure;
        }
        final current = _scheduledHandler;
        if (current == null) {
          return SubscriptionContract.outcomeRetry;
        }
        return current(subId, isBackground: isBackground);
      }
      return null;
    });
  }

  Future<void> syncSchedules(List<Subscription> subscriptions) async {
    try {
      await _channel.invokeMethod<void>(
        SubscriptionContract.methodSyncSchedules,
        <String, Object?>{
          SubscriptionContract.argSubscriptions: subscriptions
              .map(
                (s) => <String, Object?>{
                  SubscriptionContract.argId: s.id,
                  SubscriptionContract.argAutoUpdate: s.autoUpdate,
                  SubscriptionContract.argIntervalMinutes:
                      Subscription.normalizeIntervalMinutes(
                        s.updateIntervalMinutes,
                      ),
                },
              )
              .toList(growable: false),
        },
      );
    } on MissingPluginException {
      // Non-Android / unit test environment without native channel.
    }
  }

  Future<SubscriptionFetchRoute> getActiveNetworkRoute() async {
    try {
      final raw = await _channel.invokeMethod<Object?>(
        SubscriptionContract.methodGetActiveNetworkRoute,
      );
      return SubscriptionFetchRoute.fromMap(raw);
    } on MissingPluginException {
      return const SubscriptionFetchRoute.direct();
    }
  }

  Future<bool> requestNotificationPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>(
        SubscriptionContract.methodRequestNotificationPermission,
      );
      return granted ?? true;
    } on MissingPluginException {
      return true;
    }
  }

  Future<void> showProgressNotification({
    required String subscriptionId,
    required String subscriptionName,
    required String stage,
    int processed = 0,
    int total = 0,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        SubscriptionContract.methodShowProgressNotification,
        <String, Object?>{
          SubscriptionContract.argSubscriptionId: subscriptionId,
          SubscriptionContract.argSubscriptionName: subscriptionName,
          SubscriptionContract.argStage: stage,
          SubscriptionContract.argProcessed: processed,
          SubscriptionContract.argTotal: total,
        },
      );
    } on MissingPluginException {
      // Ignore outside Android runtime.
    }
  }

  Future<void> cancelProgressNotification(String subscriptionId) async {
    try {
      await _channel.invokeMethod<void>(
        SubscriptionContract.methodCancelProgressNotification,
        <String, Object?>{
          SubscriptionContract.argSubscriptionId: subscriptionId,
        },
      );
    } on MissingPluginException {
      // Ignore outside Android runtime.
    }
  }

  Future<void> showResultNotification({
    required String subscriptionId,
    required String subscriptionName,
    required int importedCount,
    required int updatedCount,
    required int removedCount,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        SubscriptionContract.methodShowResultNotification,
        <String, Object?>{
          SubscriptionContract.argSubscriptionId: subscriptionId,
          SubscriptionContract.argSubscriptionName: subscriptionName,
          SubscriptionContract.argImported: importedCount,
          SubscriptionContract.argUpdated: updatedCount,
          SubscriptionContract.argRemoved: removedCount,
        },
      );
    } on MissingPluginException {
      // Ignore outside Android runtime.
    }
  }

  Future<void> notifyBackgroundRunnerReady() async {
    try {
      await _channel.invokeMethod<void>(
        SubscriptionContract.methodBackgroundRunnerReady,
      );
    } on MissingPluginException {
      // Ignore outside Android runtime.
    }
  }

  void dispose() {
    setScheduledUpdateHandler(null);
  }
}
