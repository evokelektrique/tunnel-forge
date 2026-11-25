import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/presentation/profile_editor_sheet.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

class _FailOnceWriteSecretStore extends MemorySecretStore {
  bool failWrite = true;
  bool deleteAllCalled = false;

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) {
      throw PlatformException(code: 'keystore_error', message: 'write failed');
    }
    await super.write(key, value);
  }

  @override
  Future<void> deleteAll() async {
    deleteAllCalled = true;
    failWrite = false;
    await super.deleteAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ProfileStore> buildStore() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    return ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );
  }

  Future<void> pumpHost(
    WidgetTester tester, {
    required ProfileStore store,
    required String profileId,
  }) async {
    AppL10n.syncLocale(const Locale('en'));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  ProfileEditorSheet.show(
                    context,
                    profileId: profileId,
                    store: store,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('invalid mtu blocks save with a clear toast', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-invalid-mtu-save',
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      dnsAutomatic: true,
      dns1Host: '',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: '',
      dns2Protocol: DnsProtocol.dnsOverUdp,
    );
    await store.upsertProfile(profile, password: 'pw', psk: '');

    await pumpHost(tester, store: store, profileId: profile.id);

    await tester.enterText(
      find.byKey(const Key('mtu_field')),
      '${Profile.minVpnMtu - 1}',
    );
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.byKey(const Key('app_toast')), findsOneWidget);
    expect(
      find.text(
        'MTU must be between ${Profile.minVpnMtu} and ${Profile.maxVpnMtu}',
      ),
      findsWidgets,
    );
  });

  testWidgets(
    'secret write failure prompts reset and retries save on confirm',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      final secrets = _FailOnceWriteSecretStore()..failWrite = false;
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: secrets,
      );
      const profile = Profile(
        id: 'profile-reset-test',
        displayName: 'Office',
        server: 'vpn.example.com',
        user: 'alice',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
      );
      await store.upsertProfile(profile, password: 'pw', psk: 'psk');
      secrets.failWrite = true;

      await pumpHost(tester, store: store, profileId: profile.id);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Reset secure storage?'), findsOneWidget);
      expect(
        find.textContaining(
          'deletes the saved passwords and PSKs for all profiles',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Reset and save'));
      await tester.pumpAndSettle();

      expect(secrets.deleteAllCalled, isTrue);
      expect(find.text('Reset secure storage?'), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    },
  );

  testWidgets('protocol dropdown switches L2TP and PPTP (root) and hides PSK', (
    tester,
  ) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-protocol-toggle',
      displayName: 'Branch',
      server: 'vpn.example.com',
      user: 'alice',
      protocol: TunnelProtocol.l2tp,
    );
    await store.upsertProfile(profile, password: 'pw', psk: 'keep-me');

    await pumpHost(tester, store: store, profileId: profile.id);

    expect(find.byKey(const Key('protocol_dropdown')), findsOneWidget);
    expect(find.text('L2TP'), findsOneWidget);
    expect(find.text('IPsec PSK'), findsOneWidget);

    await tester.tap(find.byKey(const Key('protocol_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PPTP (root)').last);
    await tester.pumpAndSettle();

    expect(find.text('IPsec PSK'), findsNothing);

    // Toggling back to L2TP before saving restores the in-memory PSK value.
    await tester.tap(find.byKey(const Key('protocol_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('L2TP').last);
    await tester.pumpAndSettle();

    expect(find.text('IPsec PSK'), findsOneWidget);
    final pskField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'IPsec PSK',
      ),
    );
    expect(pskField.controller?.text, 'keep-me');

    // Switch back to PPTP (root) and save: protocol persists as PPTP with empty PSK.
    await tester.tap(find.byKey(const Key('protocol_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PPTP (root)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final savedRow = await store.loadProfileWithSecrets(profile.id);
    expect(savedRow, isNotNull);
    expect(savedRow!.profile.protocol, TunnelProtocol.pptp);
    expect(savedRow.psk, isEmpty);
    expect(savedRow.secretsMissing, isFalse);
  });
}
