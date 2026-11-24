import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/main.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_bridge.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';

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

  testWidgets('copy share link writes tf uri to clipboard', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );
    await store.upsertProfile(
      const Profile(
        id: 'profile-1',
        displayName: 'Office',
        server: 'vpn.example.com',
        user: 'alice',
        dnsAutomatic: false,
        dns1Host: '1.1.1.1',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
      ),
      password: 'pw',
      psk: 'psk',
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
    await tester.tap(find.byTooltip('Profile actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy share link').last);
    await tester.pumpAndSettle();

    expect(clipboardText, startsWith('tf://vpn.example.com?'));
    expect(clipboardText, contains('displayName=Office'));
    expect(clipboardText, contains('user=alice'));
    expect(clipboardText, contains('password=pw'));
    expect(clipboardText, contains('psk=psk'));
    expect(clipboardText, contains('dns=1.1.1.1'));
    expect(clipboardText, isNot(contains('mtu=')));
    expect(find.text('Share link copied'), findsOneWidget);
  });

  testWidgets('host transfer imports and selects profile', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
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

    const envelope = ProfileTransferEnvelope(
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      password: 'pw',
      psk: 'psk',
      dnsAutomatic: false,
      dns1Host: '1.1.1.1',
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

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    final imported = profiles.single;
    final importedRow = await store.loadProfileWithSecrets(imported.id);
    expect(importedRow, isNotNull);
    expect(importedRow!.password, 'pw');
    expect(
      find.text('Imported profile "Office" from a .tfp file'),
      findsOneWidget,
    );
    expect(find.text('Office'), findsWidgets);
  });

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

  testWidgets('clipboard import accepts TunnelForge share links', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );

    const envelope = ProfileTransferEnvelope(
      displayName: 'Clipboard Link',
      server: 'clipboard-link.example.com',
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

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': envelope.toTfUri()};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpApp(tester, store);

    await tester.tap(find.byKey(const Key('profile_picker_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from clipboard').last);
    await tester.pumpAndSettle();

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.single.displayName, 'Clipboard Link');
    expect(
      find.text(
        'Imported profile "Clipboard Link" from a clipboard share link',
      ),
      findsOneWidget,
    );
  });

  testWidgets('clipboard import accepts raw profile json', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );

    const envelope = ProfileTransferEnvelope(
      displayName: 'Clipboard Json',
      server: 'clipboard-json.example.com',
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

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') {
            return <String, Object?>{'text': envelope.toFileJson()};
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpApp(tester, store);

    await tester.tap(find.byKey(const Key('profile_picker_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import from clipboard').last);
    await tester.pumpAndSettle();

    final profiles = await store.loadProfiles();
    expect(profiles, hasLength(1));
    expect(profiles.single.displayName, 'Clipboard Json');
    expect(
      find.text('Imported profile "Clipboard Json" from the clipboard'),
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
    'host transfer while connecting does not replace active profile',
    (tester) async {
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
      final bridge = TestProfileTransferBridge();

      await pumpApp(tester, store, profileTransferBridge: bridge);

      await tester.tap(find.byKey(const Key('vpn_connect')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      bridge.emit(
        IncomingProfileTransfer(
          type: ProfileTransferContract.typeTfpJson,
          data: ProfileTransferEnvelope(
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
          ).toFileJson(),
          source: 'imported.tfp',
        ),
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(
        find.text('Imported profile "Imported" from a .tfp file'),
        findsOneWidget,
      );
      expect(find.text('Primary'), findsOneWidget);
      expect(find.text('primary.example.com'), findsOneWidget);
    },
  );

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

      // Holding for less than 1 second does not trigger multi-select.
      final alphaFinder = find.text('Alpha');
      var gesture = await tester.startGesture(tester.getCenter(alphaFinder));
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byKey(const Key('multi_select_delete')), findsNothing);
      await gesture.moveBy(const Offset(0, 40));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('multi_select_delete')), findsNothing);

      // Holding for 1 full second triggers multi-select.
      gesture = await tester.startGesture(tester.getCenter(alphaFinder));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byKey(const Key('multi_select_delete')), findsOneWidget);

      // Select all then clear all stays in multi-select mode until X is tapped.
      await tester.tap(find.byKey(const Key('multi_select_toggle_all')));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('multi_select_toggle_all')));
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      expect(find.byKey(const Key('multi_select_delete')), findsOneWidget);

      await tester.tap(find.byKey(const Key('multi_select_close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('multi_select_delete')), findsNothing);

      // Re-enter via 1s hold; deselecting last item manually exits multi-select.
      gesture = await tester.startGesture(tester.getCenter(alphaFinder));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(alphaFinder);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('multi_select_delete')), findsNothing);

      gesture = await tester.startGesture(tester.getCenter(alphaFinder));
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // Multi-export prompts between combined tf_export_2.tfp and separate files.
      await tester.tap(find.byKey(const Key('multi_select_export')));
      await tester.pumpAndSettle();
      expect(find.text('Combined file (tf_export_2.tfp)'), findsOneWidget);
      expect(find.text('Separate .tfp files (2)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

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
      expect(find.text('2 share links copied'), findsOneWidget);

      // Batch delete via trashcan icon removes selected profiles.
      await tester.tap(find.byKey(const Key('multi_select_delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 profiles?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect((await store.loadProfiles()).map((p) => p.displayName), ['Gamma']);
      expect(find.byKey(const Key('multi_select_delete')), findsNothing);

      // Import from clipboard restores both profiles from multi-line links.
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from clipboard').last);
      await tester.pumpAndSettle();

      final restored = await store.loadProfiles();
      expect(restored.map((p) => p.displayName), ['Gamma', 'Alpha', 'Beta']);
      expect(
        find.text('Imported 2 profiles from the clipboard'),
        findsOneWidget,
      );
    },
  );

  testWidgets('combined .tfp bundle imports all profiles via host transfer', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
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

    final bundleJson = ProfileTransferEnvelope.toBundleFileJson(const [
      ProfileTransferEnvelope(
        displayName: 'Alpha',
        server: 'alpha.example.com',
        user: 'alice',
        password: 'pw1',
        psk: 'psk1',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: 1400,
      ),
      ProfileTransferEnvelope(
        displayName: 'Beta',
        server: 'beta.example.com',
        user: 'bob',
        password: 'pw2',
        psk: 'psk2',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: 1400,
      ),
    ]);
    await sendHostTransfer(
      tester,
      type: ProfileTransferContract.typeTfpJson,
      data: bundleJson,
    );
    await tester.pumpAndSettle();

    final profiles = await store.loadProfiles();
    expect(profiles.map((p) => p.displayName), ['Alpha', 'Beta']);
    expect(find.text('Imported 2 profiles from a .tfp file'), findsOneWidget);
  });

  testWidgets(
    'clipboard import accepts minimal server-only tf link with Profile #1 fallback',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return const <String, Object?>{'text': 'tf://vpn.example.com'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from clipboard').last);
      await tester.pumpAndSettle();

      final profiles = await store.loadProfiles();
      expect(profiles, hasLength(1));
      final imported = profiles.single;
      expect(imported.displayName, 'Profile #1');
      expect(imported.server, 'vpn.example.com');
      expect(imported.user, isEmpty);
      expect(imported.dnsAutomatic, isTrue);
      expect(imported.mtu, isNull);
      final secretsRow = await store.loadProfileWithSecrets(imported.id);
      expect(secretsRow!.password, isEmpty);
      expect(secretsRow.psk, isEmpty);
      expect(
        find.text('Imported profile "Profile #1" from a clipboard share link'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'clipboard import assigns sequential Profile #N names for multi-line unnamed links',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return const <String, Object?>{
                'text': 'TF://one.example.com\ntf://two.example.com',
              };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from clipboard').last);
      await tester.pumpAndSettle();

      final profiles = await store.loadProfiles();
      expect(profiles.map((p) => p.displayName), ['Profile #1', 'Profile #2']);
      expect(
        find.text('Imported 2 profiles from the clipboard'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'invalid clipboard import displays error toast at top away from bottom system prompt',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.getData') {
              return const <String, Object?>{'text': 'tf://p/legacy'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from clipboard').last);
      await tester.pumpAndSettle();

      final toastFinder = find.byKey(const Key('app_toast'));
      expect(toastFinder, findsOneWidget);
      expect(find.text('Invalid TunnelForge share link'), findsOneWidget);

      final screenHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final toastRect = tester.getRect(toastFinder);
      expect(toastRect.bottom, lessThan(screenHeight / 2));
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
