import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_bridge.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';
import 'package:tunnel_forge/main.dart';

import 'support/host_to_dart_channel.dart';
import 'support/vpn_channel_mock.dart';

class _AcceptedOnboardingRepository implements OnboardingRepository {
  const _AcceptedOnboardingRepository();

  @override
  Future<int?> loadAcknowledgedVersion() async => kCurrentL2tpDisclosureVersion;

  @override
  Future<void> saveAcknowledgedVersion(int version) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(
    WidgetTester tester,
    ProfileStore store, {
    ProfileTransferBridge? profileTransferBridge,
  }) async {
    await tester.pumpWidget(
      TunnelForgeApp(
        onboardingRepository: const _AcceptedOnboardingRepository(),
        profileStore: store,
        profileTransferBridge: profileTransferBridge,
      ),
    );
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> sendHostTransfer(
    WidgetTester tester, {
    required String type,
    required String data,
  }) async {
    const codec = StandardMethodCodec();
    final payload = codec.encodeMethodCall(
      MethodCall(ProfileTransferContract.onIncomingTransfer, {
        ProfileTransferContract.argType: type,
        ProfileTransferContract.argData: data,
      }),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      ProfileTransferContract.channel,
      payload,
      (ByteData? _) {},
    );
    await tester.pump();
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installVpnChannelMock(<String>[]);
  });

  tearDown(uninstallVpnChannelMock);

  testWidgets('transfer emitted during bridge startup is not dropped', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );
    const envelope = ProfileTransferEnvelope(
      displayName: 'Startup Import',
      server: 'startup.example.com',
      user: 'alice',
      password: 'pw',
      psk: '',
      dnsAutomatic: true,
      dns1Host: '',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: '',
      dns2Protocol: DnsProtocol.dnsOverUdp,
      mtu: 1400,
    );
    final bridge = TestProfileTransferBridge(
      onStart: (bridge) async {
        bridge.emit(
          IncomingProfileTransfer(
            type: ProfileTransferContract.typeTfpJson,
            data: envelope.toFileJson(),
            source: 'startup.tfp',
          ),
        );
        return const <IncomingProfileTransfer>[];
      },
    );

    await pumpApp(tester, store, profileTransferBridge: bridge);

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.single.displayName, 'Startup Import');
    expect(
      find.text('Imported profile "Startup Import" from a .tfp file'),
      findsOneWidget,
    );
  });

  testWidgets('host transfer while connected does not replace active profile', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );
    await store.upsertProfile(
      const Profile(
        id: 'active-profile',
        displayName: 'Primary',
        server: 'primary.example.com',
        user: 'alice',
      ),
      password: 'pw',
      psk: '',
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(ProfileTransferContract.channel),
          (call) async => <Object?>[],
        );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(ProfileTransferContract.channel),
            null,
          );
    });

    await pumpApp(tester, store);
    await simulateHostTunnelState(tester, VpnTunnelState.connected, 'tun0');
    await tester.pumpAndSettle();

    const envelope = ProfileTransferEnvelope(
      displayName: 'Imported',
      server: 'imported.example.com',
      user: 'bob',
      password: 'pw',
      psk: '',
      dnsAutomatic: true,
      dns1Host: '',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: '',
      dns2Protocol: DnsProtocol.dnsOverUdp,
      mtu: 1400,
    );
    await sendHostTransfer(
      tester,
      type: ProfileTransferContract.typeTfpJson,
      data: envelope.toFileJson(),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Imported profile "Imported" from a .tfp file'),
      findsOneWidget,
    );
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('primary.example.com'), findsOneWidget);
  });

  testWidgets(
    '1-second hold enters multi-select to copy one link per line and batch delete',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );
      await store.upsertProfile(
        const Profile(
          id: 'p1',
          displayName: 'Alpha',
          server: 'alpha.example.com',
          user: 'alice',
        ),
        password: 'pw1',
        psk: 'psk1',
      );
      await store.upsertProfile(
        const Profile(
          id: 'p2',
          displayName: 'Beta',
          server: 'beta.example.com',
          user: 'bob',
        ),
        password: 'pw2',
        psk: 'psk2',
      );
      await store.upsertProfile(
        const Profile(
          id: 'p3',
          displayName: 'Gamma',
          server: 'gamma.example.com',
          user: 'carol',
        ),
        password: 'pw3',
        psk: 'psk3',
      );

      String? clipboardText;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(ProfileTransferContract.channel),
            (call) async => <Object?>[],
          );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              final args = Map<String, dynamic>.from(call.arguments as Map);
              clipboardText = args['text'] as String?;
            }
            if (call.method == 'Clipboard.getData') {
              return <String, Object?>{'text': clipboardText};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel(ProfileTransferContract.channel),
              null,
            );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpApp(tester, store);
      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();

      // Holding for 1 full second triggers multi-select.
      final alphaFinder = find.text('Alpha');
      final gesture = await tester.startGesture(tester.getCenter(alphaFinder));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // Copy share links writes one tf:// link per line.
      await tester.tap(find.byKey(const Key('multi_select_copy')));
      await tester.pumpAndSettle();
      expect(clipboardText, isNotNull);
      final copiedLines = clipboardText!.split('\n');
      expect(copiedLines, hasLength(2));
      expect(
        ProfileTransferEnvelope.fromTfUri(copiedLines[0]).displayName,
        'Alpha',
      );
      expect(
        ProfileTransferEnvelope.fromTfUri(copiedLines[1]).displayName,
        'Beta',
      );

      // Batch delete removes selected profiles.
      await tester.tap(find.byKey(const Key('multi_select_delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect((await store.loadProfiles()).map((p) => p.displayName), ['Gamma']);

      // Import from clipboard restores both profiles from multi-line links.
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from clipboard').last);
      await tester.pumpAndSettle();

      final restored = await store.loadProfiles();
      expect(restored.map((p) => p.displayName), ['Gamma', 'Alpha', 'Beta']);
    },
  );
}

class TestProfileTransferBridge extends ProfileTransferBridge {
  TestProfileTransferBridge({this.onStart});

  final StreamController<IncomingProfileTransfer> _incoming =
      StreamController<IncomingProfileTransfer>.broadcast();
  final Future<List<IncomingProfileTransfer>> Function(
    TestProfileTransferBridge bridge,
  )?
  onStart;

  @override
  Stream<IncomingProfileTransfer> get incomingTransfers => _incoming.stream;

  void emit(IncomingProfileTransfer transfer) {
    if (_incoming.isClosed) return;
    _incoming.add(transfer);
  }

  @override
  Future<List<IncomingProfileTransfer>> start() async {
    return onStart?.call(this) ?? const <IncomingProfileTransfer>[];
  }

  @override
  Future<void> dispose() => _incoming.close();
}
