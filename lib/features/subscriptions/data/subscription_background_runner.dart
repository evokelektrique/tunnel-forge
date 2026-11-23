import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_contract.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_sync_service.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

/// Entrypoint body executed inside Android WorkManager's headless [FlutterEngine].
Future<void> runSubscriptionBackgroundMain({
  ProfileStore? profileStore,
  SubscriptionHttpClient? httpClient,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = SubscriptionBridge();

  void writeLog(LogLevel level, String message) {
    unawaited(
      DiagnosticsBridge.instance
          .appendLogs(<Map<String, Object?>>[
            <String, Object?>{
              DiagnosticsContract.argTs: DateTime.now().millisecondsSinceEpoch,
              DiagnosticsContract.argLevel: level.name,
              DiagnosticsContract.argSource: 'dart',
              DiagnosticsContract.argTag: 'SubscriptionBg',
              DiagnosticsContract.argMessage: message,
            },
          ])
          .catchError((_) {}),
    );
  }

  final store = profileStore ?? ProfileStore(onLog: writeLog);
  final syncService = SubscriptionSyncService(
    profileStore: store,
    bridge: bridge,
    httpClient: httpClient,
    onLog: writeLog,
  );

  bridge.setScheduledUpdateHandler((
    String subscriptionId, {
    required bool isBackground,
  }) async {
    try {
      await store.reloadPreferences();
      await syncService.syncSubscriptionById(
        subscriptionId,
        trigger: isBackground
            ? SubscriptionSyncTrigger.backgroundAuto
            : SubscriptionSyncTrigger.foregroundAuto,
      );
      return SubscriptionContract.outcomeSuccess;
    } on SubscriptionException catch (error) {
      return error.isRetryable
          ? SubscriptionContract.outcomeRetry
          : SubscriptionContract.outcomeFailure;
    } catch (_) {
      return SubscriptionContract.outcomeRetry;
    }
  });

  await bridge.notifyBackgroundRunnerReady();
}
