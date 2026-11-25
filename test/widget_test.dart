import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';
import 'package:tunnel_forge/main.dart' as app;
import 'package:tunnel_forge/main.dart' show TunnelForgeApp;

import 'support/fake_diagnostics_bridge.dart';
import 'support/host_to_dart_channel.dart';
import 'support/vpn_channel_mock.dart';

class _AcceptedOnboardingRepository implements OnboardingRepository {
  const _AcceptedOnboardingRepository();

  @override
  Future<int?> loadAcknowledgedVersion() async => kCurrentL2tpDisclosureVersion;

  @override
  Future<void> saveAcknowledgedVersion(int version) async {}
}

MemorySecretStore _seededSecrets(String profileId) {
  return MemorySecretStore({
    ProfileStore.passwordKey(profileId): '',
    ProfileStore.pskKey(profileId): '',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('main mounts the production app', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final previousFlutterError = FlutterError.onError;
    final dispatcher = tester.binding.platformDispatcher;
    final previousPlatformError = dispatcher.onError;
    try {
      app.main();
      await tester.pump();
      expect(find.byType(TunnelForgeApp), findsOneWidget);
    } finally {
      FlutterError.onError = previousFlutterError;
      dispatcher.onError = previousPlatformError;
    }
  });

  setUp(() {
    DiagnosticsBridge.instance = FakeDiagnosticsBridge();
  });

  tearDown(() {
    DiagnosticsBridge.instance = MethodChannelDiagnosticsBridge();
  });

  String statusText(WidgetTester tester) {
    return tester.widget<Text>(find.byKey(const Key('vpn_status'))).data ?? '';
  }

  List<String> userInitiatedVpnMethods(List<String> methods) {
    return methods
        .where(
          (method) =>
              method != VpnContract.getRuntimeState &&
              method != VpnContract.getBatteryOptimizationStatus,
        )
        .toList(growable: false);
  }

  testWidgets('cold start with empty prefs shows no saved profile state', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final methods = <String>[];
    installVpnChannelMock(methods);
    addTearDown(uninstallVpnChannelMock);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(480, 1200));

    await tester.pumpWidget(
      TunnelForgeApp(
        onboardingRepository: const _AcceptedOnboardingRepository(),
        profileStore: ProfileStore(secretsOverride: MemorySecretStore()),
      ),
    );

    await tester.pump();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('No saved profile'), findsOneWidget);
    expect(find.text('Create your first profile'), findsOneWidget);
    expect(statusText(tester), 'Select profile');
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('vpn_connect')),
    );
    expect(button.onPressed, isNull);
    expect(
      find.byKey(const Key('vpn_connect_disabled_tap_target')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('vpn_connect_disabled_tap_target')));
    await tester.pump();

    expect(
      find.text(
        'Create a profile first. You will need a server, username, and tunnel settings before connecting.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Connect runs prepare then connect; awaits TUN status', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ProfileStore.prefsKeyProfilesJson: jsonEncode([
        {
          'id': 'widget_test_p1',
          'displayName': 'Test',
          'server': 'vpn.test.example',
          'user': '',
          'dnsAutomatic': true,
          'dns1Host': '',
          'dns1Protocol': 'dnsOverUdp',
          'dns2Host': '',
          'dns2Protocol': 'dnsOverUdp',
        },
      ]),
      ProfileStore.prefsKeyLastProfileId: 'widget_test_p1',
    });
    final methods = <String>[];
    installVpnChannelMock(methods);
    addTearDown(uninstallVpnChannelMock);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(480, 1200));

    await tester.pumpWidget(
      TunnelForgeApp(
        onboardingRepository: const _AcceptedOnboardingRepository(),
        profileStore: ProfileStore(
          secretsOverride: _seededSecrets('widget_test_p1'),
        ),
      ),
    );

    await tester.pump();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byKey(const Key('vpn_status')), findsOneWidget);
    expect(find.textContaining('vpn.test.example'), findsWidgets);

    await tester.tap(find.byKey(const Key('vpn_connect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(userInitiatedVpnMethods(methods), [
      VpnContract.setLogLevel,
      VpnContract.prepareVpn,
      VpnContract.connect,
    ]);
    expect(statusText(tester), contains('Connecting'));

    // Mock never delivers TUN; the await timeout logs a reminder and keeps waiting.
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();

    expect(statusText(tester), contains('Connecting'));
  });

  testWidgets('connecting state lets the user cancel before TUN comes up', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ProfileStore.prefsKeyProfilesJson: jsonEncode([
        {
          'id': 'widget_test_cancel_connect',
          'displayName': 'Test',
          'server': 'vpn.test.example',
          'user': '',
          'dnsAutomatic': true,
          'dns1Host': '',
          'dns1Protocol': 'dnsOverUdp',
          'dns2Host': '',
          'dns2Protocol': 'dnsOverUdp',
        },
      ]),
      ProfileStore.prefsKeyLastProfileId: 'widget_test_cancel_connect',
    });
    final methods = <String>[];
    installVpnChannelMock(methods);
    addTearDown(uninstallVpnChannelMock);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(480, 1200));

    await tester.pumpWidget(
      TunnelForgeApp(
        onboardingRepository: const _AcceptedOnboardingRepository(),
        profileStore: ProfileStore(
          secretsOverride: _seededSecrets('widget_test_cancel_connect'),
        ),
      ),
    );

    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.byKey(const Key('vpn_connect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(statusText(tester), contains('Connecting'));

    await tester.tap(find.byKey(const Key('vpn_connect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(userInitiatedVpnMethods(methods), [
      VpnContract.setLogLevel,
      VpnContract.prepareVpn,
      VpnContract.connect,
      VpnContract.disconnect,
    ]);
    expect(statusText(tester), 'Canceling...');

    await simulateHostTunnelState(tester, VpnTunnelState.stopped, 'Canceled');
    await tester.pump();

    expect(statusText(tester), 'Ready');
  });

  testWidgets('missing secrets block connect and open profile editor', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ProfileStore.prefsKeyProfilesJson: jsonEncode([
        {
          'id': 'widget_test_missing_secrets',
          'displayName': 'Office Missing',
          'server': 'vpn.test.example',
          'user': 'alice',
          'dnsAutomatic': true,
          'dns1Host': '',
          'dns1Protocol': 'dnsOverUdp',
          'dns2Host': '',
          'dns2Protocol': 'dnsOverUdp',
        },
      ]),
      ProfileStore.prefsKeyLastProfileId: 'widget_test_missing_secrets',
    });
    final methods = <String>[];
    installVpnChannelMock(methods);
    addTearDown(uninstallVpnChannelMock);
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
    });
    await tester.binding.setSurfaceSize(const Size(480, 1200));

    await tester.pumpWidget(
      TunnelForgeApp(
        onboardingRepository: const _AcceptedOnboardingRepository(),
        profileStore: ProfileStore(secretsOverride: MemorySecretStore()),
      ),
    );

    await tester.pump();
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.byKey(const Key('vpn_connect')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(userInitiatedVpnMethods(methods), [VpnContract.setLogLevel]);
    expect(
      find.text(
        'Saved password/PSK for "Office Missing" could not be read. Re-enter them.',
      ),
      findsOneWidget,
    );
    expect(find.text('Profile details'), findsOneWidget);
  });

  testWidgets(
    'share debug logs uses DiagnosticsBridge and prompts on tombstone',
    (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final previousBridge = DiagnosticsBridge.instance;
      final fakeBridge = FakeDiagnosticsBridge()
        ..tombstoneAvailable = true
        ..exportPaths = <String>['/tmp/tunnel_forge_logs_1.txt'];
      DiagnosticsBridge.instance = fakeBridge;
      addTearDown(() => DiagnosticsBridge.instance = previousBridge);

      final shareCalls = <MethodCall>[];
      const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            shareCalls.add(call);
            return 'dev.fluttercommunity.plus/share/success';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(shareChannel, null);
      });

      installVpnChannelMock(<String>[]);
      addTearDown(uninstallVpnChannelMock);
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
      });
      await tester.binding.setSurfaceSize(const Size(480, 1200));

      await tester.pumpWidget(
        TunnelForgeApp(
          onboardingRepository: const _AcceptedOnboardingRepository(),
          profileStore: ProfileStore(secretsOverride: MemorySecretStore()),
        ),
      );

      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await simulateHostEngineLog(
        tester,
        priority: 4,
        source: 'kotlin',
        tag: 'MainActivity',
        message: 'ready',
      );

      await tester.tap(find.text('Logs'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.byTooltip('Share debug logs'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Include native crash dump? It may contain memory contents from the crashed process.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('No'));
      await tester.pumpAndSettle();

      expect(fakeBridge.lastExportIncludeTombstone, isFalse);
      expect(shareCalls, hasLength(1));
    },
  );
}
