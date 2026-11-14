import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';

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

    test('round-trips through tf uri payload', () {
      final envelope = ProfileTransferEnvelope(
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

      final decoded = ProfileTransferEnvelope.fromTfUri(envelope.toTfUri());

      expect(decoded.displayName, 'Office');
      expect(decoded.server, 'vpn.example.com');
      expect(decoded.password, 'pw');
      expect(decoded.psk, 'psk');
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
  });
}
