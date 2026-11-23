import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProfileTransferEnvelope', () {
    test('round-trips through .tfp json', () {
      final envelope = ProfileTransferEnvelope(
        displayName: 'Office',
        server: 'vpn.example.com',
        user: 'alice',
        password: 'pw',
        psk: 'psk',
        dnsAutomatic: false,
        dns1Host: '1.1.1.1',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: 'dns.example.com',
        dns2Protocol: DnsProtocol.dnsOverTls,
        mtu: 1400,
      );

      final decoded = ProfileTransferEnvelope.fromFileJson(
        envelope.toFileJson(),
      );

      expect(decoded.displayName, 'Office');
      expect(decoded.server, 'vpn.example.com');
      expect(decoded.password, 'pw');
      expect(decoded.psk, 'psk');
      expect(decoded.dnsAutomatic, isFalse);
      expect(decoded.dns1Host, '1.1.1.1');
      expect(decoded.dns1Protocol, DnsProtocol.dnsOverUdp);
      expect(decoded.dns2Host, 'dns.example.com');
      expect(decoded.dns2Protocol, DnsProtocol.dnsOverTls);
      expect(decoded.mtu, 1400);
    });

    test('emits minimal server-only tf uri when defaults are used', () {
      const envelope = ProfileTransferEnvelope(
        displayName: '',
        server: ' vpn.example.com ',
        user: '',
        password: '',
        psk: '',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: Profile.defaultVpnMtu,
      );

      final uri = envelope.toTfUri();
      expect(uri, 'tf://vpn.example.com?protocol=l2tp');

      final decoded = ProfileTransferEnvelope.fromTfUri(uri);
      expect(decoded.protocol, TunnelProtocol.l2tp);
      expect(decoded.displayName, isEmpty);
      expect(decoded.server, 'vpn.example.com');
      expect(decoded.user, isEmpty);
      expect(decoded.password, isEmpty);
      expect(decoded.psk, isEmpty);
      expect(decoded.dnsAutomatic, isTrue);
      expect(decoded.dns1Host, isEmpty);
      expect(decoded.dns2Host, isEmpty);
      expect(decoded.mtu, Profile.defaultVpnMtu);
    });

    test('emits readable plaintext tf uri with non-default fields', () {
      const envelope = ProfileTransferEnvelope(
        displayName: 'Office VPN',
        server: 'vpn.example.com',
        user: 'alice',
        password: 'pw',
        psk: 'psk',
        dnsAutomatic: false,
        dns1Host: '1.1.1.1',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: 'dns.quad9.net',
        dns2Protocol: DnsProtocol.dnsOverTls,
        mtu: 1400,
      );

      final uri = envelope.toTfUri();
      expect(uri, isNot(contains('tf://p/')));
      expect(
        uri,
        'tf://vpn.example.com?protocol=l2tp&displayName=Office%20VPN&user=alice&password=pw&psk=psk&dns=1.1.1.1&dns=tls://dns.quad9.net&mtu=1400',
      );

      final decoded = ProfileTransferEnvelope.fromTfUri(uri);
      expect(decoded.displayName, 'Office VPN');
      expect(decoded.server, 'vpn.example.com');
      expect(decoded.user, 'alice');
      expect(decoded.password, 'pw');
      expect(decoded.psk, 'psk');
      expect(decoded.dnsAutomatic, isFalse);
      expect(decoded.dns1Host, '1.1.1.1');
      expect(decoded.dns1Protocol, DnsProtocol.dnsOverUdp);
      expect(decoded.dns2Host, 'dns.quad9.net');
      expect(decoded.dns2Protocol, DnsProtocol.dnsOverTls);
      expect(decoded.mtu, 1400);
    });

    test('round-trips all DNS protocols and DoH URL forms via tf uri', () {
      const tcpAndTls = ProfileTransferEnvelope(
        displayName: 'TCP TLS',
        server: 'vpn.example.com',
        user: '',
        password: '',
        psk: '',
        dnsAutomatic: false,
        dns1Host: '9.9.9.9',
        dns1Protocol: DnsProtocol.dnsOverTcp,
        dns2Host: 'dns.quad9.net',
        dns2Protocol: DnsProtocol.dnsOverTls,
        mtu: Profile.defaultVpnMtu,
      );
      final tcpTlsUri = tcpAndTls.toTfUri();
      expect(tcpTlsUri, contains('dns=tcp://9.9.9.9&dns=tls://dns.quad9.net'));
      final decodedTcpTls = ProfileTransferEnvelope.fromTfUri(tcpTlsUri);
      expect(decodedTcpTls.dns1Protocol, DnsProtocol.dnsOverTcp);
      expect(decodedTcpTls.dns1Host, '9.9.9.9');
      expect(decodedTcpTls.dns2Protocol, DnsProtocol.dnsOverTls);
      expect(decodedTcpTls.dns2Host, 'dns.quad9.net');

      // Bare DoH hostname preserves bare form so /dns-query default stays intact.
      const bareDoh = ProfileTransferEnvelope(
        displayName: 'Bare DoH',
        server: 'vpn.example.com',
        user: '',
        password: '',
        psk: '',
        dnsAutomatic: false,
        dns1Host: 'dns.google',
        dns1Protocol: DnsProtocol.dnsOverHttps,
        dns2Host: 'wikimedia-dns.org/dns-query',
        dns2Protocol: DnsProtocol.dnsOverHttps,
        mtu: Profile.defaultVpnMtu,
      );
      final bareDohUri = bareDoh.toTfUri();
      expect(
        bareDohUri,
        contains(
          'dns=https://dns.google&dns=https://wikimedia-dns.org/dns-query',
        ),
      );
      final decodedBareDoh = ProfileTransferEnvelope.fromTfUri(bareDohUri);
      expect(decodedBareDoh.dns1Protocol, DnsProtocol.dnsOverHttps);
      expect(decodedBareDoh.dns1Host, 'dns.google');
      expect(decodedBareDoh.dns2Protocol, DnsProtocol.dnsOverHttps);
      expect(decodedBareDoh.dns2Host, 'https://wikimedia-dns.org/dns-query');

      // Explicit root path, port, and query remain intact.
      const explicitDoh = ProfileTransferEnvelope(
        displayName: 'Explicit DoH',
        server: 'vpn.example.com',
        user: '',
        password: '',
        psk: '',
        dnsAutomatic: false,
        dns1Host: 'https://dns.google/',
        dns1Protocol: DnsProtocol.dnsOverHttps,
        dns2Host: 'https://dns.example.com:8443/doh?k=v&x=1',
        dns2Protocol: DnsProtocol.dnsOverHttps,
        mtu: Profile.defaultVpnMtu,
      );
      final explicitDohUri = explicitDoh.toTfUri();
      final decodedExplicit = ProfileTransferEnvelope.fromTfUri(explicitDohUri);
      expect(decodedExplicit.dns1Host, 'https://dns.google/');
      expect(
        decodedExplicit.dns2Host,
        'https://dns.example.com:8443/doh?k=v&x=1',
      );
    });

    test('preserves special characters and UTF-8 across tf uri', () {
      const envelope = ProfileTransferEnvelope(
        displayName: 'دفتر مرکزی & Branch #1',
        server: 'vpn.example.com',
        user: ' alice+vpn@corp ',
        password: ' p@ss=&?#%+word ',
        psk: ' abc+123== ',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: Profile.defaultVpnMtu,
      );

      final uri = envelope.toTfUri();
      expect(uri, isNot(contains('دفتر')));
      expect(uri, contains('%20'));
      expect(uri, contains('%26'));
      expect(uri, contains('%3D'));
      expect(uri, contains('%23'));
      expect(uri, contains('%3F'));
      expect(uri, contains('%25'));
      expect(uri, contains('%2B'));

      final decoded = ProfileTransferEnvelope.fromTfUri(uri);
      expect(decoded.displayName, 'دفتر مرکزی & Branch #1');
      expect(decoded.user, ' alice+vpn@corp ');
      expect(decoded.password, ' p@ss=&?#%+word ');
      expect(decoded.psk, ' abc+123== ');

      // Raw hand-typed UTF-8 and literal +/= in query values are accepted verbatim.
      final handTyped = ProfileTransferEnvelope.fromTfUri(
        'tf://vpn.example.com?displayName=دفتر&psk=abc+123==',
      );
      expect(handTyped.displayName, 'دفتر');
      expect(handTyped.psk, 'abc+123==');
    });

    test(
      'applies defaults, ignores unknown keys, clamps mtu, and dedupes dns',
      () {
        final decoded = ProfileTransferEnvelope.fromTfUri(
          'TF://vpn.example.com/?futureFlag=1&displayName=&dns=&dns=UDP://1.1.1.1&dns=1.1.1.1&dns=TLS://dns.quad9.net&mtu=9999',
        );

        expect(decoded.displayName, isEmpty);
        expect(decoded.server, 'vpn.example.com');
        expect(decoded.user, isEmpty);
        expect(decoded.password, isEmpty);
        expect(decoded.psk, isEmpty);
        expect(decoded.dnsAutomatic, isFalse);
        expect(decoded.dns1Host, '1.1.1.1');
        expect(decoded.dns1Protocol, DnsProtocol.dnsOverUdp);
        expect(decoded.dns2Host, 'dns.quad9.net');
        expect(decoded.dns2Protocol, DnsProtocol.dnsOverTls);
        expect(decoded.mtu, Profile.maxVpnMtu);

        final minClamped = ProfileTransferEnvelope.fromTfUri(
          'tf://vpn.example.com?mtu=100',
        );
        expect(minClamped.mtu, Profile.minVpnMtu);
      },
    );

    test('rejects invalid tf uris and legacy tf://p/ links', () {
      void expectErrorCode(String uri, ProfileTransferErrorCode expected) {
        expect(
          () => ProfileTransferEnvelope.fromTfUri(uri),
          throwsA(
            isA<ProfileTransferFormatException>().having(
              (e) => e.code,
              'code',
              expected,
            ),
          ),
        );
      }

      expectErrorCode(
        'tf://p/H4sIAAAAAAAAA6vmUlBQKi1OLcpMUVBKSixSqgUAg3xX1hIAAAA',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode(
        'https://vpn.example.com',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode(
        'tf://user@vpn.example.com',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode(
        'tf://vpn.example.com:8443',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode(
        'tf://vpn.example.com/extra/path',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode(
        'tf://vpn.example.com#frag',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode(
        'tf://vpn.example.com?user=%ZZ',
        ProfileTransferErrorCode.invalidShareLink,
      );
      expectErrorCode('tf://', ProfileTransferErrorCode.serverRequired);
      expectErrorCode(
        'tf://?user=alice',
        ProfileTransferErrorCode.serverRequired,
      );
      expectErrorCode(
        'tf://vpn.example.com?mtu=abc',
        ProfileTransferErrorCode.invalidIntField,
      );
      expectErrorCode(
        'tf://vpn.example.com?dns=http://1.1.1.1',
        ProfileTransferErrorCode.invalidDns,
      );
      expectErrorCode(
        'tf://vpn.example.com?dns=tls://',
        ProfileTransferErrorCode.invalidDns,
      );
      expectErrorCode(
        'tf://vpn.example.com?dns=tls://1.1.1.1',
        ProfileTransferErrorCode.invalidDns,
      );
      expectErrorCode(
        'tf://vpn.example.com?dns=bad host',
        ProfileTransferErrorCode.invalidDns,
      );
      expectErrorCode(
        'tf://vpn.example.com?dns=1.1.1.1&dns=8.8.8.8&dns=9.9.9.9',
        ProfileTransferErrorCode.tooManyDnsServers,
      );
    });

    test('rejects unsupported version', () {
      expect(
        () => ProfileTransferEnvelope.fromJsonMap({
          'v': 99,
          'displayName': 'Office',
          'server': 'vpn.example.com',
          'user': 'alice',
          'password': 'pw',
          'psk': 'psk',
          'dnsAutomatic': false,
          'dns1Host': '1.1.1.1',
          'dns1Protocol': 'dnsOverUdp',
          'dns2Host': '',
          'dns2Protocol': 'dnsOverUdp',
          'mtu': 1400,
        }),
        throwsFormatException,
      );
    });

    test('preserves dns-over-https endpoint path on import', () {
      final decoded = ProfileTransferEnvelope.fromJsonMap({
        'v': ProfileTransferEnvelope.currentVersion,
        'protocol': 'l2tp',
        'displayName': 'Office',
        'server': 'vpn.example.com',
        'user': 'alice',
        'password': 'pw',
        'psk': 'psk',
        'dnsAutomatic': false,
        'dns1Host': 'wikimedia-dns.org/dns-query',
        'dns1Protocol': 'dnsOverHttps',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
        'mtu': 1400,
      });

      expect(decoded.dns1Host, 'wikimedia-dns.org/dns-query');
      expect(decoded.dns1Protocol, DnsProtocol.dnsOverHttps);
    });

    test('round-trips PPTP profiles through .tfp v4 and tf:// links', () {
      const pptpEnvelope = ProfileTransferEnvelope(
        protocol: TunnelProtocol.pptp,
        displayName: 'Legacy PPTP',
        server: 'pptp.example.com',
        user: 'alice',
        password: 'pw',
        psk: 'ignored-secret',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: 1400,
      );

      final jsonMap = pptpEnvelope.toJson();
      expect(jsonMap['v'], 4);
      expect(jsonMap['protocol'], 'pptp');
      expect(jsonMap.containsKey('psk'), isFalse);

      final decodedJson = ProfileTransferEnvelope.fromFileJson(
        pptpEnvelope.toFileJson(),
      );
      expect(decodedJson.protocol, TunnelProtocol.pptp);
      expect(decodedJson.psk, isEmpty);
      expect(decodedJson.toProfile('p-pptp').protocol, TunnelProtocol.pptp);

      final uri = pptpEnvelope.toTfUri();
      expect(
        uri,
        'tf://pptp.example.com?protocol=pptp&displayName=Legacy%20PPTP&user=alice&password=pw&mtu=1400',
      );
      expect(uri, isNot(contains('psk=')));

      final decodedUri = ProfileTransferEnvelope.fromTfUri(uri);
      expect(decodedUri.protocol, TunnelProtocol.pptp);
      expect(decodedUri.psk, isEmpty);
      expect(decodedUri.displayName, 'Legacy PPTP');
      expect(decodedUri.mtu, 1400);

      // PPTP link with an extraneous psk param still normalizes psk to empty.
      final withExtraPsk = ProfileTransferEnvelope.fromTfUri(
        'tf://pptp.example.com?protocol=PPTP&user=alice&psk=stale',
      );
      expect(withExtraPsk.protocol, TunnelProtocol.pptp);
      expect(withExtraPsk.psk, isEmpty);
    });

    test('imports legacy v3 .tfp single and bundle files as L2TP', () {
      final legacySingle = ProfileTransferEnvelope.fromJsonMap({
        'v': 3,
        'displayName': 'Old L2TP',
        'server': 'old.example.com',
        'user': 'bob',
        'password': 'pw',
        'psk': 'shared',
        'dnsAutomatic': true,
        'dns1Host': '',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
        'mtu': 1400,
      });
      expect(legacySingle.protocol, TunnelProtocol.l2tp);
      expect(legacySingle.psk, 'shared');

      final legacyBundle = ProfileTransferEnvelope.fromFileJsonList('''
{
  "v": 3,
  "profiles": [
    {
      "v": 3,
      "displayName": "Legacy One",
      "server": "one.example.com",
      "user": "u",
      "password": "p",
      "psk": "k",
      "dnsAutomatic": true,
      "dns1Host": "",
      "dns1Protocol": "dnsOverUdp",
      "dns2Host": "",
      "dns2Protocol": "dnsOverUdp",
      "mtu": 1400
    }
  ]
}
''');
      expect(legacyBundle, hasLength(1));
      expect(legacyBundle.single.protocol, TunnelProtocol.l2tp);
      expect(legacyBundle.single.displayName, 'Legacy One');

      // Legacy tf:// without protocol query parameter defaults to L2TP.
      final legacyUri = ProfileTransferEnvelope.fromTfUri(
        'tf://old.example.com?user=bob&psk=shared',
      );
      expect(legacyUri.protocol, TunnelProtocol.l2tp);
      expect(legacyUri.psk, 'shared');
    });

    test('rejects unrecognized protocol in tf:// and .tfp v4', () {
      expect(
        () => ProfileTransferEnvelope.fromTfUri(
          'tf://vpn.example.com?protocol=wireguard',
        ),
        throwsA(
          isA<ProfileTransferFormatException>()
              .having(
                (e) => e.code,
                'code',
                ProfileTransferErrorCode.unsupportedProtocol,
              )
              .having((e) => e.protocol, 'protocol', 'wireguard'),
        ),
      );

      expect(
        () => ProfileTransferEnvelope.fromJsonMap({
          'v': 4,
          'protocol': 'sstp',
          'displayName': 'Bad',
          'server': 'vpn.example.com',
          'user': 'u',
          'password': 'p',
          'dnsAutomatic': true,
          'dns1Host': '',
          'dns1Protocol': 'dnsOverUdp',
          'dns2Host': '',
          'dns2Protocol': 'dnsOverUdp',
          'mtu': 1400,
        }),
        throwsA(
          isA<ProfileTransferFormatException>()
              .having(
                (e) => e.code,
                'code',
                ProfileTransferErrorCode.unsupportedProtocol,
              )
              .having((e) => e.protocol, 'protocol', 'sstp'),
        ),
      );
    });

    test('round-trips mixed L2TP and PPTP combined v4 bundle', () {
      const l2tp = ProfileTransferEnvelope(
        protocol: TunnelProtocol.l2tp,
        displayName: 'L2TP Site',
        server: 'l2tp.example.com',
        user: 'alice',
        password: 'pw1',
        psk: 'psk1',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: 1400,
      );
      const pptp = ProfileTransferEnvelope(
        protocol: TunnelProtocol.pptp,
        displayName: 'PPTP Site',
        server: 'pptp.example.com',
        user: 'bob',
        password: 'pw2',
        psk: '',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: 1400,
      );
      final decoded = ProfileTransferEnvelope.fromFileJsonList(
        ProfileTransferEnvelope.toBundleFileJson([l2tp, pptp]),
      );
      expect(decoded, hasLength(2));
      expect(decoded[0].protocol, TunnelProtocol.l2tp);
      expect(decoded[0].psk, 'psk1');
      expect(decoded[1].protocol, TunnelProtocol.pptp);
      expect(decoded[1].psk, isEmpty);
    });

    test('exportFileNamesFor deduplicates colliding names', () {
      const profiles = [
        Profile(
          id: '1',
          displayName: 'Office',
          server: 'a.example.com',
          user: 'u',
        ),
        Profile(
          id: '2',
          displayName: 'Office',
          server: 'b.example.com',
          user: 'u',
        ),
        Profile(
          id: '3',
          displayName: 'Home',
          server: 'c.example.com',
          user: 'u',
        ),
        Profile(
          id: '4',
          displayName: 'Office',
          server: 'd.example.com',
          user: 'u',
        ),
      ];

      expect(ProfileTransferEnvelope.exportFileNamesFor(profiles), [
        'office.tfp',
        'office-2.tfp',
        'home.tfp',
        'office-3.tfp',
      ]);
    });

    test(
      'round-trips combined bundle through .tfp json and names tf_export_x.tfp',
      () {
        const first = ProfileTransferEnvelope(
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
        );
        const second = ProfileTransferEnvelope(
          displayName: 'Beta',
          server: 'beta.example.com',
          user: 'bob',
          password: 'pw2',
          psk: 'psk2',
          dnsAutomatic: false,
          dns1Host: '1.1.1.1',
          dns1Protocol: DnsProtocol.dnsOverUdp,
          dns2Host: '',
          dns2Protocol: DnsProtocol.dnsOverUdp,
          mtu: 1380,
        );

        expect(
          ProfileTransferEnvelope.combinedExportFileNameFor(2),
          'tf_export_2.tfp',
        );

        final bundleJson = ProfileTransferEnvelope.toBundleFileJson([
          first,
          second,
        ]);
        final decoded = ProfileTransferEnvelope.fromFileJsonList(bundleJson);

        expect(decoded, hasLength(2));
        expect(decoded[0].displayName, 'Alpha');
        expect(decoded[0].password, 'pw1');
        expect(decoded[1].displayName, 'Beta');
        expect(decoded[1].dns1Host, '1.1.1.1');
        expect(
          () => ProfileTransferEnvelope.fromFileJson(bundleJson),
          throwsFormatException,
        );
        expect(
          () => ProfileTransferEnvelope.fromFileJsonList(
            '{"v": 3, "profiles": []}',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('ProfileStore imported profiles', () {
    late SharedPreferences prefs;
    late MemorySecretStore secrets;
    late ProfileStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await prefs.clear();
      secrets = MemorySecretStore();
      store = ProfileStore(prefsOverride: prefs, secretsOverride: secrets);
    });

    tearDown(() {
      AppL10n.syncLocale(const Locale('en'));
    });

    test('saveImportedProfile creates a new row and secrets', () async {
      const existing = Profile(
        id: 'existing',
        displayName: 'Office',
        server: 'vpn.example.com',
        user: 'alice',
        dnsAutomatic: false,
        dns1Host: '1.1.1.1',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
      );
      await store.upsertProfile(existing, password: 'old', psk: 'old-psk');

      final imported = await store.saveImportedProfile(
        const ProfileTransferEnvelope(
          displayName: 'Office',
          server: 'vpn.example.com',
          user: 'alice',
          password: 'new',
          psk: 'new-psk',
          dnsAutomatic: false,
          dns1Host: '1.1.1.1',
          dns1Protocol: DnsProtocol.dnsOverUdp,
          dns2Host: '',
          dns2Protocol: DnsProtocol.dnsOverUdp,
          mtu: 1400,
        ),
      );

      final profiles = await store.loadProfiles();
      expect(profiles, hasLength(2));
      expect(imported.id, isNot('existing'));
      final importedRow = await store.loadProfileWithSecrets(imported.id);
      expect(importedRow, isNotNull);
      expect(importedRow!.password, 'new');
      expect(importedRow.psk, 'new-psk');
    });

    test('saveImportedProfiles and deleteProfiles handle batches', () async {
      final imported = await store.saveImportedProfiles(const [
        ProfileTransferEnvelope(
          displayName: 'One',
          server: 'one.example.com',
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
          displayName: 'Two',
          server: 'two.example.com',
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

      expect(imported, hasLength(2));
      expect(await store.loadLastProfileId(), imported.last.id);

      await store.deleteProfiles([imported.first.id, imported.last.id]);

      expect(await store.loadProfiles(), isEmpty);
      expect(await store.loadLastProfileId(), isNull);
      expect(
        await secrets.read(ProfileStore.passwordKey(imported.first.id)),
        isNull,
      );
      expect(await secrets.read(ProfileStore.pskKey(imported.last.id)), isNull);
    });

    test('assigns lowest unused Profile #N fallback names on import', () async {
      ProfileTransferEnvelope unnamed(String server) => ProfileTransferEnvelope(
        displayName: '',
        server: server,
        user: '',
        password: '',
        psk: '',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: Profile.defaultVpnMtu,
      );

      // Non-matching existing name leaves Profile #1 available.
      await store.upsertProfile(
        const Profile(
          id: 'office',
          displayName: 'Office',
          server: 'office.example.com',
          user: '',
        ),
        password: '',
        psk: '',
      );

      final first = await store.saveImportedProfile(unnamed('a.example.com'));
      expect(first.displayName, 'Profile #1');

      // Gap filling: with #1 and #3 present, next unnamed gets #2.
      await store.upsertProfile(
        const Profile(
          id: 'p3',
          displayName: 'Profile #3',
          server: 'c.example.com',
          user: '',
        ),
        password: '',
        psk: '',
      );
      final batch = await store.saveImportedProfiles([
        unnamed('b.example.com'),
        unnamed('d.example.com'),
        unnamed('e.example.com'),
      ]);
      expect(batch.map((p) => p.displayName), [
        'Profile #2',
        'Profile #4',
        'Profile #5',
      ]);

      // Localized Persian fallback naming.
      AppL10n.syncLocale(const Locale('fa'));
      final persian = await store.saveImportedProfile(
        unnamed('fa.example.com'),
      );
      expect(persian.displayName, 'پروفایل #1');
    });

    test('round-trips pppAuth and mppe in .tfp and tf:// and validates conflicts', () {
      const pptpOn = ProfileTransferEnvelope(
        protocol: TunnelProtocol.pptp,
        pppAuth: PppAuthMethod.mschapV2,
        mppeMode: MppeMode.on,
        displayName: 'Secure PPTP',
        server: 'pptp.example.com',
        user: 'alice',
        password: 'pw',
        psk: '',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: Profile.defaultVpnMtu,
      );

      final uri = pptpOn.toTfUri();
      expect(uri, contains('pppAuth=mschapv2'));
      expect(uri, contains('mppe=on'));
      final decodedUri = ProfileTransferEnvelope.fromTfUri(uri);
      expect(decodedUri.pppAuth, PppAuthMethod.mschapV2);
      expect(decodedUri.mppeMode, MppeMode.on);

      final decodedJson = ProfileTransferEnvelope.fromFileJson(
        pptpOn.toFileJson(),
      );
      expect(decodedJson.pppAuth, PppAuthMethod.mschapV2);
      expect(decodedJson.mppeMode, MppeMode.on);
      expect(decodedJson.toProfile('p1').mppeMode, MppeMode.on);

      // L2TP ignores/normalizes mppe to auto while keeping pppAuth.
      final l2tpFromUri = ProfileTransferEnvelope.fromTfUri(
        'tf://l2tp.example.com?protocol=l2tp&pppAuth=pap&mppe=on',
      );
      expect(l2tpFromUri.pppAuth, PppAuthMethod.pap);
      expect(l2tpFromUri.mppeMode, MppeMode.auto);

      // Rejects invalid wire values and incompatible PPTP MPPE On + PAP/CHAP-MD5.
      expect(
        () => ProfileTransferEnvelope.fromTfUri(
          'tf://pptp.example.com?protocol=pptp&pppAuth=eap',
        ),
        throwsA(
          isA<ProfileTransferFormatException>().having(
            (e) => e.code,
            'code',
            ProfileTransferErrorCode.unsupportedPppAuth,
          ),
        ),
      );
      expect(
        () => ProfileTransferEnvelope.fromTfUri(
          'tf://pptp.example.com?protocol=pptp&mppe=force',
        ),
        throwsA(
          isA<ProfileTransferFormatException>().having(
            (e) => e.code,
            'code',
            ProfileTransferErrorCode.unsupportedMppe,
          ),
        ),
      );
      expect(
        () => ProfileTransferEnvelope.fromTfUri(
          'tf://pptp.example.com?protocol=pptp&pppAuth=pap&mppe=on',
        ),
        throwsA(
          isA<ProfileTransferFormatException>().having(
            (e) => e.code,
            'code',
            ProfileTransferErrorCode.incompatibleAuthAndMppe,
          ),
        ),
      );
    });
  });
}
