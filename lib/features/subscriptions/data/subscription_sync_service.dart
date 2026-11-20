import 'dart:async';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_contract.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_parser.dart';

typedef SubscriptionSyncLog = void Function(LogLevel level, String message);

/// End-to-end subscription fetch, parse, diff/persist, and notification coordinator.
class SubscriptionSyncService {
  SubscriptionSyncService({
    required ProfileStore profileStore,
    required SubscriptionBridge bridge,
    SubscriptionHttpClient? httpClient,
    DateTime Function()? clock,
    SubscriptionSyncLog? onLog,
  }) : _store = profileStore,
       _bridge = bridge,
       _httpClient = httpClient ?? DartSubscriptionHttpClient(),
       _clock = clock ?? DateTime.now,
       _onLog = onLog;

  static const Duration _progressNotifyThrottle = Duration(milliseconds: 200);

  final ProfileStore _store;
  final SubscriptionBridge _bridge;
  final SubscriptionHttpClient _httpClient;
  final DateTime Function() _clock;
  final SubscriptionSyncLog? _onLog;
  final Map<String, Future<SubscriptionSyncSummary>> _inFlight =
      <String, Future<SubscriptionSyncSummary>>{};

  /// Fetches and imports a brand-new subscription; persists only if fetch & parse succeed.
  Future<SubscriptionSyncSummary> addAndSyncSubscription({
    required String name,
    required String url,
    required bool autoUpdate,
    required int updateIntervalMinutes,
    required SubscriptionIntervalUnit intervalUnit,
  }) {
    final subscription = Subscription(
      id: ProfileStore.newProfileId(),
      name: name.trim(),
      url: url.trim(),
      autoUpdate: autoUpdate,
      updateIntervalMinutes: Subscription.normalizeIntervalMinutes(
        updateIntervalMinutes,
      ),
      intervalUnit: intervalUnit,
    );
    return syncSubscription(
      subscription,
      trigger: SubscriptionSyncTrigger.initialAdd,
      persistErrorOnFailure: false,
    );
  }

  /// Looks up [subscriptionId] from [ProfileStore] and syncs it (returns null if deleted).
  Future<SubscriptionSyncSummary?> syncSubscriptionById(
    String subscriptionId, {
    required SubscriptionSyncTrigger trigger,
  }) async {
    final subscriptions = await _store.loadSubscriptions();
    Subscription? target;
    for (final sub in subscriptions) {
      if (sub.id == subscriptionId) {
        target = sub;
        break;
      }
    }
    if (target == null) return null;
    return syncSubscription(target, trigger: trigger);
  }

  Future<SubscriptionSyncSummary> syncSubscription(
    Subscription subscription, {
    required SubscriptionSyncTrigger trigger,
    bool persistErrorOnFailure = true,
  }) {
    final existing = _inFlight[subscription.id];
    if (existing != null) return existing;

    final future = _runSync(
      subscription,
      trigger: trigger,
      persistErrorOnFailure: persistErrorOnFailure,
    );
    _inFlight[subscription.id] = future;
    return future.whenComplete(() {
      if (identical(_inFlight[subscription.id], future)) {
        _inFlight.remove(subscription.id);
      }
    });
  }

  Future<SubscriptionSyncSummary> _runSync(
    Subscription subscription, {
    required SubscriptionSyncTrigger trigger,
    required bool persistErrorOnFailure,
  }) async {
    final uri = Uri.tryParse(subscription.url.trim());
    if (uri == null) {
      throw const SubscriptionException(
        'Invalid subscription URL',
        code: SubscriptionErrorCode.unexpected,
      );
    }

    final showProgress = trigger.isAuto;
    final route = await _bridge.getActiveNetworkRoute();
    _onLog?.call(
      LogLevel.debug,
      'Subscription sync start id=${subscription.id} trigger=${trigger.jsonValue} route=${route.kind.name}',
    );
    if (route.kind == SubscriptionRouteKind.defer) {
      const error = SubscriptionException(
        'TunnelForge VPN tunnel is recovering',
        code: SubscriptionErrorCode.tunnelRecovering,
      );
      _onLog?.call(
        LogLevel.info,
        'Subscription sync deferred id=${subscription.id} reason=${route.reason ?? 'tunnel_recovering'}',
      );
      if (persistErrorOnFailure) {
        await _store.recordSubscriptionError(
          subscription.id,
          error.code.wireValue,
        );
      }
      throw error;
    }

    if (showProgress) {
      await _bridge.showProgressNotification(
        subscriptionId: subscription.id,
        subscriptionName: subscription.name,
        stage: SubscriptionContract.stageFetching,
      );
    }

    try {
      final body = await _httpClient.fetchBody(uri, route: route);
      final parsed = SubscriptionParser.parse(body);

      var lastNotifiedAt = DateTime.fromMillisecondsSinceEpoch(0);
      final summary = await _store.applySubscriptionSync(
        subscription: subscription,
        envelopes: parsed.envelopes,
        skippedInvalidLines: parsed.skippedInvalidLines,
        trigger: trigger,
        syncedAt: _clock(),
        onProgress: showProgress
            ? (processed, total) {
                final now = DateTime.now();
                if (processed == total ||
                    now.difference(lastNotifiedAt) >= _progressNotifyThrottle) {
                  lastNotifiedAt = now;
                  unawaited(
                    _bridge.showProgressNotification(
                      subscriptionId: subscription.id,
                      subscriptionName: subscription.name,
                      stage: SubscriptionContract.stageApplying,
                      processed: processed,
                      total: total,
                    ),
                  );
                }
              }
            : null,
      );

      _onLog?.call(
        LogLevel.info,
        'Subscription sync complete id=${subscription.id} trigger=${trigger.jsonValue} '
        'imported=${summary.importedCount} updated=${summary.updatedCount} '
        'removed=${summary.removedCount} skipped=${summary.skippedInvalidLines}',
      );

      if (trigger == SubscriptionSyncTrigger.backgroundAuto &&
          summary.hasChanges) {
        await _store.enqueuePendingSubscriptionSummary(summary);
        await _bridge.showResultNotification(
          subscriptionId: summary.subscriptionId,
          subscriptionName: summary.subscriptionName,
          importedCount: summary.importedCount,
          updatedCount: summary.updatedCount,
          removedCount: summary.removedCount,
        );
      }
      return summary;
    } on SubscriptionException catch (error) {
      _onLog?.call(
        LogLevel.warning,
        'Subscription sync failed id=${subscription.id} trigger=${trigger.jsonValue} '
        'code=${error.code.wireValue} status=${error.statusCode ?? 0}',
      );
      if (persistErrorOnFailure) {
        await _store.recordSubscriptionError(
          subscription.id,
          error.statusCode != null
              ? '${error.code.wireValue}:${error.statusCode}'
              : error.code.wireValue,
        );
      }
      rethrow;
    } catch (error) {
      _onLog?.call(
        LogLevel.warning,
        'Subscription sync failed id=${subscription.id} trigger=${trigger.jsonValue} '
        'error=${error.runtimeType}',
      );
      if (persistErrorOnFailure) {
        await _store.recordSubscriptionError(
          subscription.id,
          SubscriptionErrorCode.unexpected.wireValue,
        );
      }
      throw SubscriptionException(
        'Unexpected sync error: ${error.runtimeType}',
        code: SubscriptionErrorCode.unexpected,
      );
    } finally {
      if (showProgress) {
        await _bridge.cancelProgressNotification(subscription.id);
      }
    }
  }
}
