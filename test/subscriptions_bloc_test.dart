import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/profiles_bloc.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_sync_service.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

class _EmptyTransferRepo implements ProfileTransferRepository {
  final StreamController<IncomingProfileTransfer> _controller =
      StreamController<IncomingProfileTransfer>.broadcast();

  @override
  Stream<IncomingProfileTransfer> get incomingTransfers => _controller.stream;

  @override
  Future<List<IncomingProfileTransfer>> start() async => const [];

  @override
  Future<void> dispose() => _controller.close();
}

class _RecordingBridge extends SubscriptionBridge {
  final List<List<Subscription>> syncedSchedules = [];
  int notificationPermissionRequests = 0;

  @override
  Future<void> syncSchedules(List<Subscription> subscriptions) async {
    syncedSchedules.add(List<Subscription>.of(subscriptions));
  }

  @override
  Future<bool> requestNotificationPermission() async {
    notificationPermissionRequests += 1;
    return true;
  }

  @override
  Future<SubscriptionFetchRoute> getActiveNetworkRoute() async =>
      const SubscriptionFetchRoute.direct();

  @override
  Future<void> showProgressNotification({
    required String subscriptionId,
    required String subscriptionName,
    required String stage,
    int processed = 0,
    int total = 0,
  }) async {}

  @override
  Future<void> cancelProgressNotification(String subscriptionId) async {}

  @override
  Future<void> showResultNotification({
    required String subscriptionId,
    required String subscriptionName,
    required int importedCount,
    required int updatedCount,
    required int removedCount,
  }) async {}
}

class _StubHttpClient implements SubscriptionHttpClient {
  String body = 'tf://a.example.com?displayName=Node+A&user=u&password=p&psk=k';

  @override
  Future<String> fetchBody(
    Uri uri, {
    required SubscriptionFetchRoute route,
  }) async => body;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ProfilesBloc handles subscription add, manual no-change vs auto no-change, overdue check, and delete',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );
      final bridge = _RecordingBridge();
      final http = _StubHttpClient();
      var now = DateTime.utc(2026, 11, 20, 10, 0);
      final syncService = SubscriptionSyncService(
        profileStore: store,
        bridge: bridge,
        httpClient: http,
        clock: () => now,
      );
      final subsRepo = SubscriptionsRepositoryImpl(
        profileStore: store,
        syncService: syncService,
        bridge: bridge,
      );
      final transferRepo = _EmptyTransferRepo();
      final bloc = ProfilesBloc(
        ProfilesRepositoryImpl(store),
        transferRepo,
        subscriptionsRepository: subsRepo,
        clock: () => now,
      );
      addTearDown(() async {
        await bloc.close();
        await transferRepo.dispose();
      });

      bloc.add(const ProfilesStarted());
      await bloc.stream.firstWhere((s) => !s.loading);

      // Add a subscription with auto-update enabled (15 min).
      bloc.add(
        const ProfilesSubscriptionAddRequested(
          name: 'Alpha',
          url: 'https://example.com/alpha',
          autoUpdate: true,
          updateIntervalMinutes: 15,
          intervalUnit: SubscriptionIntervalUnit.minutes,
        ),
      );
      final addedState = await bloc.stream.firstWhere(
        (s) => s.subscriptionSubmissionId == 1,
      );
      expect(addedState.subscriptionSubmissionError, isNull);
      expect(addedState.subscriptions, hasLength(1));
      expect(addedState.profiles, hasLength(1));
      expect(addedState.pendingSummaryEvent?.summaries.single.importedCount, 1);
      expect(bridge.notificationPermissionRequests, 1);
      expect(bridge.syncedSchedules.last, hasLength(1));

      final subId = addedState.subscriptions.single.id;
      final eventIdAfterAdd = addedState.pendingSummaryEvent!.id;

      // Manual update with NO changes -> emits pendingSummaryEvent with hasChanges == false.
      bloc.add(
        ProfilesSubscriptionSyncRequested(
          subId,
          trigger: SubscriptionSyncTrigger.manual,
        ),
      );
      final manualNoChange = await bloc.stream.firstWhere(
        (s) => (s.pendingSummaryEvent?.id ?? 0) > eventIdAfterAdd,
      );
      expect(
        manualNoChange.pendingSummaryEvent!.summaries.single.hasChanges,
        isFalse,
      );
      final eventIdAfterManual = manualNoChange.pendingSummaryEvent!.id;

      // Advance time 20 minutes and run overdue check with NO changes -> NO dialog event emitted!
      now = now.add(const Duration(minutes: 20));
      bloc.add(const ProfilesDueSubscriptionsCheckRequested());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(bloc.state.pendingSummaryEvent!.id, eventIdAfterManual);

      // Advance another 20 minutes with a NEW profile on the server -> emits dialog event!
      now = now.add(const Duration(minutes: 20));
      http.body =
          'tf://a.example.com?displayName=Node+A&user=u&password=p&psk=k\n'
          'tf://b.example.com?displayName=Node+B&user=u&password=p&psk=k';
      bloc.add(const ProfilesDueSubscriptionsCheckRequested());
      final autoChanged = await bloc.stream.firstWhere(
        (s) => (s.pendingSummaryEvent?.id ?? 0) > eventIdAfterManual,
      );
      expect(
        autoChanged.pendingSummaryEvent!.summaries.single.importedCount,
        1,
      );
      expect(autoChanged.profiles, hasLength(2));

      // Delete subscription -> profiles and schedules cleaned up.
      bloc.add(ProfilesSubscriptionDeleteRequested(subId));
      final afterDelete = await bloc.stream.firstWhere(
        (s) => s.subscriptions.isEmpty && !s.loading,
      );
      expect(afterDelete.profiles, isEmpty);
      expect(bridge.syncedSchedules.last, isEmpty);
    },
  );
}
