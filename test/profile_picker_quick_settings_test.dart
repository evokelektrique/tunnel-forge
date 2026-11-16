import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';
import 'package:tunnel_forge/main.dart';

import 'support/fake_diagnostics_bridge.dart';
import 'support/host_to_dart_channel.dart';

class _FakeConnectivityChecker implements ConnectivityChecker {
  @override
  Future<ConnectivityPingResult> ping(
    ConnectivityPingRequest request, {
    Future<void>? cancelSignal,
  }) async {
    return ConnectivityPingResult.success(latencyMs: 42, statusCode: 204);
  }
}

class _AcceptedOnboardingRepository implements OnboardingRepository {
  const _AcceptedOnboardingRepository();

  @override
  Future<int?> loadAcknowledgedVersion() async => kCurrentL2tpDisclosureVersion;

  @override
  Future<void> saveAcknowledgedVersion(int version) async {}
}

class _FakeAppVersionRepository implements AppVersionRepository {
  const _FakeAppVersionRepository();

  @override
  Future<AppVersionInfo> loadInstalledVersion() async {
    return const AppVersionInfo(
      displayVersion: '0.8.0+213',
      semanticVersion: SemanticVersion(major: 0, minor: 8, patch: 0),
    );
  }
}

class _FakeAppUpdateRepository implements AppUpdateRepository {
  const _FakeAppUpdateRepository();

  @override
  Future<AppReleaseInfo> fetchLatestRelease() async {
    return AppReleaseInfo(
      version: const SemanticVersion(major: 0, minor: 8, patch: 0),
      htmlUrl: 'https://github.com/evokelektrique/tunnel-forge/releases',
      publishedAt: DateTime.utc(2026, 4, 19),
      prerelease: false,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const vpnChannel = MethodChannel(VpnContract.channel);
  const qsChannel = MethodChannel(QuickSettingsContract.channel);
  late List<MethodCall> vpnCalls;
  late List<MethodCall> qsCalls;
  late bool pendingQuickSettingsConnect;

  Future<ProfileStore> createTwoProfileStore() async {
    final profiles = [
      const Profile(
        id: 'p1',
        displayName: 'Alpha',
        server: 'alpha.example',
        user: 'alice',
      ),
      const Profile(
        id: 'p2',
        displayName: 'Beta',
        server: 'beta.example',
        user: 'bob',
      ),
    ];
    SharedPreferences.setMockInitialValues({
      ProfileStore.prefsKeyProfilesJson: jsonEncode(
        profiles.map((p) => p.toJson()).toList(),
      ),
      ProfileStore.prefsKeyLastProfileId: 'p1',
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore({
      ProfileStore.passwordKey('p1'): 'pw1',
      ProfileStore.pskKey('p1'): 'psk1',
      ProfileStore.passwordKey('p2'): 'pw2',
      ProfileStore.pskKey('p2'): 'psk2',
    });
    return ProfileStore(prefsOverride: prefs, secretsOverride: secrets);
  }

  Future<void> pumpStartup(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    DiagnosticsBridge.instance = FakeDiagnosticsBridge();
    vpnCalls = <MethodCall>[];
    qsCalls = <MethodCall>[];
    pendingQuickSettingsConnect = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(vpnChannel, (call) async {
      vpnCalls.add(call);
      if (call.method == VpnContract.prepareVpn) {
        return true;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(qsChannel, (call) async {
      qsCalls.add(call);
      if (call.method == QuickSettingsContract.consumePendingConnect) {
        final next = pendingQuickSettingsConnect;
        pendingQuickSettingsConnect = false;
        return next;
      }
      return null;
    });
  });

  tearDown(() {
    DiagnosticsBridge.instance = MethodChannelDiagnosticsBridge();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(vpnChannel, null);
    messenger.setMockMethodCallHandler(qsChannel, null);
  });

  testWidgets(
    'clicking a profile updates current profile in store, syncs Quick Settings, and reconnects when active',
    (tester) async {
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      final store = await createTwoProfileStore();

      await tester.pumpWidget(
        TunnelForgeApp(
          profileStore: store,
          connectivityChecker: _FakeConnectivityChecker(),
          appVersionRepository: const _FakeAppVersionRepository(),
          appUpdateRepository: const _FakeAppUpdateRepository(),
          onboardingRepository: const _AcceptedOnboardingRepository(),
          skipOnboardingDisclosure: true,
        ),
      );
      await pumpStartup(tester);

      final initialSyncs = qsCalls
          .where((c) => c.method == QuickSettingsContract.syncProfile)
          .toList();
      expect(initialSyncs, isNotEmpty);
      expect(
        (initialSyncs.last.arguments as Map)[VpnContract.argProfileId],
        'p1',
      );

      // Start tunnel on Alpha (p1).
      await tester.tap(find.byKey(const Key('vpn_connect')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      final firstConnect = vpnCalls
          .where((c) => c.method == VpnContract.connect)
          .single;
      final firstArgs = firstConnect.arguments as Map;
      expect(firstArgs[VpnContract.argServer], 'alpha.example');
      final firstAttemptId = firstArgs[VpnContract.argAttemptId] as String;

      await simulateHostTunnelState(
        tester,
        VpnTunnelState.connected,
        'VPN connected',
      );
      await tester.pump(const Duration(milliseconds: 500));

      // Open profile picker and tap Beta (p2).
      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Beta'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // Persisted as current profile in ProfileStore and synced to Quick Settings.
      expect(await store.loadLastProfileId(), 'p2');
      final syncCalls = qsCalls
          .where((c) => c.method == QuickSettingsContract.syncProfile)
          .toList();
      expect(
        (syncCalls.last.arguments as Map)[VpnContract.argProfileId],
        'p2',
      );
      expect(
        (syncCalls.last.arguments as Map)[VpnContract.argServer],
        'beta.example',
      );

      // Immediately triggered reconnect with Beta (p2).
      final connectCalls = vpnCalls
          .where((c) => c.method == VpnContract.connect)
          .toList();
      expect(connectCalls.length, 2);
      final secondArgs = connectCalls.last.arguments as Map;
      expect(secondArgs[VpnContract.argServer], 'beta.example');
      expect(secondArgs[VpnContract.argProfileName], 'Beta');
      expect(secondArgs[VpnContract.argAttemptId], isNot(firstAttemptId));
    },
  );

  testWidgets(
    'pending Quick Settings connect triggers connect for current profile on startup',
    (tester) async {
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      pendingQuickSettingsConnect = true;
      final store = await createTwoProfileStore();

      await tester.pumpWidget(
        TunnelForgeApp(
          profileStore: store,
          connectivityChecker: _FakeConnectivityChecker(),
          appVersionRepository: const _FakeAppVersionRepository(),
          appUpdateRepository: const _FakeAppUpdateRepository(),
          onboardingRepository: const _AcceptedOnboardingRepository(),
          skipOnboardingDisclosure: true,
        ),
      );
      await pumpStartup(tester);

      final connectCalls = vpnCalls
          .where((c) => c.method == VpnContract.connect)
          .toList();
      expect(connectCalls.length, 1);
      final args = connectCalls.single.arguments as Map;
      expect(args[VpnContract.argServer], 'alpha.example');
      expect(args[VpnContract.argProfileName], 'Alpha');
    },
  );
}
