import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/presentation/profile_editor_sheet.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';

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
    await tester.pumpWidget(
      MaterialApp(
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

  testWidgets('shows dns section when automatic dns is disabled', (
    tester,
  ) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-1',
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      dnsAutomatic: false,
      dns1Host: '1.1.1.1',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: 'dns.example.com',
      dns2Protocol: DnsProtocol.dnsOverTls,
    );
    await store.upsertProfile(profile, password: 'pw', psk: '');

    await pumpHost(tester, store: store, profileId: profile.id);

    expect(find.byKey(const Key('dns_servers_section')), findsOneWidget);
    expect(find.text('Automatic'), findsOneWidget);
    expect(find.text('DNS servers'), findsNWidgets(3));
    expect(find.text('DNS 1 is primary. DNS 2 is fallback.'), findsOneWidget);
    expect(find.text('DNS 1'), findsOneWidget);
    expect(find.text('DNS 2'), findsOneWidget);
    expect(find.text('UDP'), findsOneWidget);
    expect(find.text('TLS'), findsOneWidget);
  });

  testWidgets('dns dropdown height matches dns text field', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-dns-size',
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      dnsAutomatic: false,
      dns1Host: '1.1.1.1',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: '8.8.8.8',
      dns2Protocol: DnsProtocol.dnsOverTls,
    );
    await store.upsertProfile(profile, password: 'pw', psk: '');

    await pumpHost(tester, store: store, profileId: profile.id);

    final dnsFieldSize = tester.getSize(
      find.byKey(const ValueKey('dns_input_DNS 1')),
    );
    final dnsDropdownSize = tester.getSize(
      find.byKey(const ValueKey('dns_protocol_DNS 1')),
    );

    expect(dnsDropdownSize.height, dnsFieldSize.height);
  });

  testWidgets('shows clearer mtu hint and helper copy', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-mtu',
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

    final mtuField = tester.widgetList<TextField>(find.byType(TextField)).last;
    expect(mtuField.decoration?.labelText, 'MTU');
    expect(mtuField.decoration?.hintText, '${Profile.defaultVpnMtu}');
    expect(mtuField.decoration?.helperMaxLines, 2);
    expect(
      mtuField.decoration?.helperText,
      'Range ${Profile.minVpnMtu}-${Profile.maxVpnMtu}. Use ${Profile.defaultVpnMtu} unless you need a smaller MTU.',
    );
  });

  testWidgets('password and psk visibility toggles are independent', (
    tester,
  ) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-secrets',
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

    await pumpHost(tester, store: store, profileId: profile.id);

    TextField fieldByLabel(String label) => tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      ),
    );

    expect(fieldByLabel('Password').obscureText, isTrue);
    expect(fieldByLabel('IPsec PSK').obscureText, isTrue);
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byTooltip('Show IPsec PSK'), findsOneWidget);

    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();

    expect(fieldByLabel('Password').obscureText, isFalse);
    expect(fieldByLabel('IPsec PSK').obscureText, isTrue);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.byTooltip('Show IPsec PSK'), findsOneWidget);

    await tester.tap(find.byTooltip('Show IPsec PSK'));
    await tester.pump();

    expect(fieldByLabel('Password').obscureText, isFalse);
    expect(fieldByLabel('IPsec PSK').obscureText, isFalse);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    expect(find.byTooltip('Hide IPsec PSK'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();

    expect(fieldByLabel('Password').obscureText, isTrue);
    expect(fieldByLabel('IPsec PSK').obscureText, isFalse);
    expect(find.byTooltip('Show password'), findsOneWidget);
    expect(find.byTooltip('Hide IPsec PSK'), findsOneWidget);
  });

  testWidgets('shows inline error when mtu is invalid', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-invalid-mtu',
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

    await tester.enterText(find.byKey(const Key('mtu_field')), '');
    await tester.pump();

    expect(find.text('Enter an MTU value'), findsOneWidget);
  });

  testWidgets('shows inline error when mtu is out of range', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-invalid-mtu-range',
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
      '${Profile.maxVpnMtu + 1}',
    );
    await tester.pump();

    expect(
      find.text(
        'MTU must be between ${Profile.minVpnMtu} and ${Profile.maxVpnMtu}',
      ),
      findsOneWidget,
    );
  });

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

  testWidgets('invalid dns entry blocks save with a toast', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-2',
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      dnsAutomatic: false,
      dns1Host: '1.1.1.1',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: '',
      dns2Protocol: DnsProtocol.dnsOverUdp,
    );
    await store.upsertProfile(profile, password: 'pw', psk: '');

    await pumpHost(tester, store: store, profileId: profile.id);

    await tester.enterText(find.byType(TextField).at(6), 'bad/path');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(find.byKey(const Key('app_toast')), findsOneWidget);
    expect(find.text('DNS 2: use hostname or IPv4'), findsWidgets);
  });

  testWidgets('automatic dns hides manual dns section', (tester) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-3',
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

    expect(find.byKey(const Key('dns_servers_section')), findsNothing);
    expect(find.text('DNS 1 is primary. DNS 2 is fallback.'), findsNothing);
    expect(find.text('DNS 1'), findsNothing);
    expect(find.text('DNS 2'), findsNothing);
  });

  testWidgets('automatic dns toggle hides and shows dns section', (
    tester,
  ) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-4',
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      dnsAutomatic: false,
      dns1Host: '1.1.1.1',
      dns1Protocol: DnsProtocol.dnsOverUdp,
      dns2Host: '8.8.8.8',
      dns2Protocol: DnsProtocol.dnsOverTls,
    );
    await store.upsertProfile(profile, password: 'pw', psk: '');

    await pumpHost(tester, store: store, profileId: profile.id);

    expect(find.byKey(const Key('dns_servers_section')), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dns_servers_section')), findsNothing);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dns_servers_section')), findsOneWidget);
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

  testWidgets('validates PPP RFC limits for username and password', (
    tester,
  ) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-ppp-limits',
      displayName: 'Office',
      server: 'vpn.example.com',
      user: 'alice',
      protocol: TunnelProtocol.pptp,
    );
    await store.upsertProfile(profile, password: 'valid', psk: '');

    await pumpHost(tester, store: store, profileId: profile.id);

    final userField = find.byKey(const Key('username_field'));
    final passwordField = find.byKey(const Key('password_field'));

    // Password > 256 UTF-16 code units triggers RFC 2759 error and blocks Save.
    await tester.enterText(passwordField, 'a' * 257);
    await tester.pumpAndSettle();
    expect(find.textContaining('256 characters (RFC 2759'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final unchanged = await store.loadProfileWithSecrets(profile.id);
    expect(unchanged!.password, 'valid');

    // Username > 255 UTF-8 bytes triggers RFC 1334/1994 error and blocks Save.
    await tester.enterText(passwordField, 'okpw');
    await tester.enterText(userField, 'u' * 256);
    await tester.pumpAndSettle();
    expect(find.textContaining('255 UTF-8 bytes (RFC 1334'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final unchangedUser = await store.loadProfileWithSecrets(profile.id);
    expect(unchangedUser!.profile.user, 'alice');

    // 256-char ASCII password (> 255 bytes PAP limit, <= 256 chars MS-CHAPv2) warns but saves.
    await tester.enterText(userField, 'alice');
    await tester.enterText(passwordField, 'p' * 256);
    await tester.pumpAndSettle();
    expect(find.textContaining('255-byte PAP limit (RFC 1334)'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final updated = await store.loadProfileWithSecrets(profile.id);
    expect(updated!.password, 'p' * 256);
  });

  testWidgets('ppp auth shows for L2TP and PPTP; MPPE shows for PPTP only', (
    tester,
  ) async {
    final store = await buildStore();
    const profile = Profile(
      id: 'profile-auth-mppe-visibility',
      displayName: 'Branch',
      server: 'vpn.example.com',
      user: 'alice',
      protocol: TunnelProtocol.l2tp,
    );
    await store.upsertProfile(profile, password: 'pw', psk: 'psk');

    await pumpHost(tester, store: store, profileId: profile.id);

    final authFinder = find.byKey(const Key('ppp_auth_dropdown'));
    final mppeFinder = find.byKey(const Key('mppe_dropdown'));
    expect(authFinder, findsOneWidget);
    expect(mppeFinder, findsNothing);
    expect(
      find.text('Accept the authentication method offered by the server.'),
      findsOneWidget,
    );

    // Switch to PPTP: MPPE dropdown appears below PPP authentication with Auto default.
    await tester.tap(find.byKey(const Key('protocol_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PPTP (root)').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(mppeFinder);
    expect(mppeFinder, findsOneWidget);
    final mtuBottom = tester.getBottomLeft(find.byKey(const Key('mtu_field'))).dy;
    final authTop = tester.getTopLeft(authFinder).dy;
    final mppeTop = tester.getTopLeft(mppeFinder).dy;
    expect(authTop, greaterThan(mtuBottom));
    expect(mppeTop, greaterThan(authTop));
    expect(
      find.text('Receive MPPE status from the server during handshake.'),
      findsOneWidget,
    );

    // Selecting MPPE On + PAP shows inline error and blocks Save.
    await tester.ensureVisible(authFinder);
    await tester.tap(authFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('PAP').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(mppeFinder);
    await tester.tap(mppeFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('On').last);
    await tester.pumpAndSettle();

    expect(
      find.text('MPPE On requires Auto or MS-CHAPv2 authentication'),
      findsOneWidget,
    );
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.byKey(const Key('app_toast')), findsOneWidget);
    expect((await store.loadProfiles()).single.mppeMode, MppeMode.auto);

    // Switching back to L2TP keeps in-memory MPPE On if toggled back, and saving L2TP resets persisted MPPE to Auto.
    await tester.ensureVisible(find.byKey(const Key('protocol_dropdown')));
    await tester.tap(find.byKey(const Key('protocol_dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('L2TP').last);
    await tester.pumpAndSettle();
    expect(mppeFinder, findsNothing);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final savedL2tp = (await store.loadProfiles()).single;
    expect(savedL2tp.protocol, TunnelProtocol.l2tp);
    expect(savedL2tp.pppAuth, PppAuthMethod.pap);
    expect(savedL2tp.mppeMode, MppeMode.auto);
  });
}
