import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';

class _ThrowingReadSecretStore extends MemorySecretStore {
  @override
  Future<String?> read(String key) async {
    throw PlatformException(code: 'keystore_error', message: 'decrypt failed');
  }
}

class _ThrowingWriteSecretStore extends MemorySecretStore {
  @override
  Future<void> write(String key, String value) async {
    throw PlatformException(code: 'keystore_error', message: 'write failed');
  }
}

class _FakeUpgradeSecretStore extends MemorySecretStore {
  _FakeUpgradeSecretStore(this.status);

  final SecureStorageUpgradeStatus status;
  int calls = 0;

  @override
  Future<SecureStorageUpgradeStatus> checkUpgradeStatus() async {
    calls += 1;
    return status;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Profile.tryFromJson', () {
    test('parses valid map', () {
      final p = Profile.tryFromJson({
        'id': 'a1',
        'displayName': 'Office',
        'server': 'vpn.company.net',
        'user': 'u',
        'dnsAutomatic': false,
        'dns1Host': '1.1.1.1',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
      });
      expect(p, isNotNull);
      expect(p!.id, 'a1');
      expect(p.displayName, 'Office');
      expect(p.server, 'vpn.company.net');
      expect(p.protocol, TunnelProtocol.l2tp);
      expect(p.mtu, isNull);
      expect(p.toJson().containsKey('mtu'), isFalse);
      expect(p.toJson().containsKey('routingMode'), isFalse);
    });

    test('parses and serializes pptp protocol cleanly', () {
      final p = Profile.tryFromJson({
        'id': 'p-pptp',
        'displayName': 'Legacy PPTP',
        'server': 'pptp.company.net',
        'user': 'u',
        'protocol': 'pptp',
        'pppAuth': 'chap-md5',
        'mppe': 'off',
        'dnsAutomatic': true,
        'dns1Host': '',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
      });
      expect(p, isNotNull);
      expect(p!.protocol, TunnelProtocol.pptp);
      expect(p.pppAuth, PppAuthMethod.chapMd5);
      expect(p.mppeMode, MppeMode.off);
      expect(p.toJson()['protocol'], 'pptp');
      expect(p.toJson()['pppAuth'], 'chap-md5');
      expect(p.toJson()['mppe'], 'off');
    });

    test('parses mtu and clamps', () {
      final hi = Profile.tryFromJson({
        'id': 'm1',
        'displayName': 'M',
        'server': 's',
        'user': 'u',
        'dnsAutomatic': true,
        'dns1Host': '',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
        'mtu': 9000,
      });
      expect(hi, isNotNull);
      expect(hi!.mtu, Profile.maxVpnMtu);
      final lo = Profile.tryFromJson({
        'id': 'm2',
        'displayName': 'M',
        'server': 's',
        'user': 'u',
        'dnsAutomatic': true,
        'dns1Host': '',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
        'mtu': 100,
      });
      expect(lo, isNotNull);
      expect(lo!.mtu, Profile.minVpnMtu);

      final explicitDefault = Profile.tryFromJson({
        'id': 'm3',
        'displayName': 'M',
        'server': 's',
        'user': 'u',
        'dnsAutomatic': true,
        'dns1Host': '',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
        'mtu': Profile.defaultVpnMtu,
      });
      expect(explicitDefault, isNotNull);
      expect(explicitDefault!.mtu, Profile.defaultVpnMtu);
      expect(explicitDefault.toJson()['mtu'], Profile.defaultVpnMtu);
    });

    test('ignores legacy routing keys in stored json', () {
      final p = Profile.tryFromJson({
        'id': 'a2',
        'displayName': 'Per',
        'server': 'vpn.example',
        'user': 'u',
        'dnsAutomatic': true,
        'dns1Host': '',
        'dns1Protocol': 'dnsOverUdp',
        'dns2Host': '',
        'dns2Protocol': 'dnsOverUdp',
        'routingMode': 'perAppAllowList',
        'allowedAppPackages': ['com.foo.app', 'com.bar.app'],
      });
      expect(p, isNotNull);
      expect(p!.id, 'a2');
      expect(p.toJson().containsKey('routingMode'), isFalse);
      expect(p.toJson().containsKey('allowedAppPackages'), isFalse);
    });

    test('orders manual dns with dns1 priority and dns2 fallback', () {
      final ordered = Profile.orderedDnsServers(
        dns1Host: ' 1.1.1.1 ',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: 'resolver.example',
        dns2Protocol: DnsProtocol.dnsOverTls,
      );
      expect(ordered, hasLength(2));
      expect(ordered[0].host, '1.1.1.1');
      expect(ordered[0].protocol, DnsProtocol.dnsOverUdp);
      expect(ordered[1].host, 'resolver.example');
      expect(ordered[1].protocol, DnsProtocol.dnsOverTls);
    });

    test('normalizes individual dns inputs', () {
      expect(Profile.normalizeDnsServer(' 1.1.1.1 '), '1.1.1.1');
      expect(Profile.normalizeDnsServer(''), '');
    });

    test('reports invalid dns entries per field', () {
      expect(
        Profile.invalidDnsServer('1.1.1.1', DnsProtocol.dnsOverTls),
        '1.1.1.1',
      );
      expect(
        Profile.invalidDnsServer('example.com', DnsProtocol.dnsOverUdp),
        isNull,
      );
      expect(
        Profile.invalidDnsServer(
          'wikimedia-dns.org/dns-query',
          DnsProtocol.dnsOverHttps,
        ),
        isNull,
      );
      expect(
        Profile.invalidDnsServer(
          'wikimedia-dns.org/custom-path',
          DnsProtocol.dnsOverHttps,
        ),
        isNull,
      );
      expect(
        Profile.invalidDnsServer(
          'https://wikimedia-dns.org/dns-query',
          DnsProtocol.dnsOverHttps,
        ),
        isNull,
      );
    });

    test('normalizes dns-over-https host and url inputs', () {
      expect(
        Profile.normalizeDnsServerForProtocol(
          ' wikimedia-dns.org/dns-query ',
          DnsProtocol.dnsOverHttps,
        ),
        'wikimedia-dns.org/dns-query',
      );
      expect(
        Profile.normalizeDnsServerForProtocol(
          'wikimedia-dns.org',
          DnsProtocol.dnsOverHttps,
        ),
        'wikimedia-dns.org',
      );
      expect(
        Profile.normalizeDnsServerForProtocol(
          ' https://wikimedia-dns.org/custom-path?dns=1 ',
          DnsProtocol.dnsOverHttps,
        ),
        'https://wikimedia-dns.org/custom-path?dns=1',
      );
      expect(
        Profile.validationMessageForDnsServer(
          'DNS 1',
          'ftp://bad.example/dns-query',
          DnsProtocol.dnsOverHttps,
        ),
        'DNS 1: use hostname or HTTPS URL',
      );
    });
  });

  group('ProfileStore', () {
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

    test('upsert and load with secrets', () async {
      const profile = Profile(
        id: 'id-1',
        displayName: 'One',
        server: 's.example',
        user: 'alice',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
      );
      await store.upsertProfile(profile, password: 'pw1', psk: 'psk1');

      final list = await store.loadProfiles();
      expect(list, hasLength(1));
      expect(list.single.server, 's.example');

      final row = await store.loadProfileWithSecrets('id-1');
      expect(row, isNotNull);
      expect(row!.profile.user, 'alice');
      expect(row.password, 'pw1');
      expect(row.psk, 'psk1');
    });

    test('starts empty without seeding a default profile', () async {
      expect(await store.loadProfiles(), isEmpty);
      expect(await store.loadLastProfileId(), isNull);
    });

    test('persists connection mode and proxy settings', () async {
      await store.saveConnectionMode(ConnectionMode.proxyOnly);
      await store.saveProxySettings(
        const ProxySettings(
          httpPort: 18080,
          socksPort: 11080,
          allowLanConnections: true,
        ),
      );

      expect(await store.loadConnectionMode(), ConnectionMode.proxyOnly);
      final proxy = await store.loadProxySettings();
      expect(proxy.httpPort, 18080);
      expect(proxy.socksPort, 11080);
      expect(proxy.allowLanConnections, isTrue);
    });

    test(
      'normalizes privileged and Android-reserved proxy ports to defaults',
      () {
        expect(ProxySettings.isAllowedPort(0), isFalse);
        expect(ProxySettings.isAllowedPort(80), isFalse);
        expect(ProxySettings.isAllowedPort(1023), isFalse);
        expect(ProxySettings.isAllowedPort(1024), isTrue);
        expect(ProxySettings.isAllowedPort(1701), isFalse);
        expect(ProxySettings.isAllowedPort(1723), isFalse);
        expect(ProxySettings.isAllowedPort(4500), isFalse);
        expect(ProxySettings.isAllowedPort(5037), isFalse);
        expect(ProxySettings.isAllowedPort(5353), isFalse);
        expect(ProxySettings.isAllowedPort(5554), isFalse);
        expect(ProxySettings.isAllowedPort(5555), isFalse);
        expect(ProxySettings.isAllowedPort(65536), isFalse);
        expect(
          ProxySettings.normalizePort(
            80,
            fallback: ProxySettings.defaultHttpPort,
          ),
          ProxySettings.defaultHttpPort,
        );
        expect(
          ProxySettings.normalizePort(
            5353,
            fallback: ProxySettings.defaultSocksPort,
          ),
          ProxySettings.defaultSocksPort,
        );
        expect(ProxySettings.validatePortText('80'), contains('1–1023'));
        expect(ProxySettings.validatePortText('1723'), contains('1723'));
        expect(ProxySettings.validatePortText('5353'), contains('5353'));
        expect(ProxySettings.validatePortText('5555'), contains('5555'));
        expect(ProxySettings.validatePortText('18080'), isNull);
      },
    );

    test('persists split-tunnel settings', () async {
      await store.saveSplitTunnelSettings(
        const SplitTunnelSettings(
          enabled: true,
          mode: SplitTunnelMode.exclusive,
          inclusivePackages: ['com.example.alpha'],
          exclusivePackages: [' com.example.beta ', 'com.example.beta'],
        ),
      );

      final settings = await store.loadSplitTunnelSettings();
      expect(settings.enabled, isTrue);
      expect(settings.mode, SplitTunnelMode.exclusive);
      expect(settings.inclusivePackages, ['com.example.alpha']);
      expect(settings.exclusivePackages, ['com.example.beta']);
    });

    test('persists global connectivity check settings', () async {
      final initial = await store.loadConnectivityCheckSettings();
      expect(initial.url, ConnectivityCheckSettings.defaultUrl);
      expect(initial.timeoutMs, ConnectivityCheckSettings.defaultTimeoutMs);

      await store.saveConnectivityCheckSettings(
        const ConnectivityCheckSettings(
          url: 'https://example.com/health',
          timeoutMs: 3200,
        ),
      );

      final saved = await store.loadConnectivityCheckSettings();
      expect(saved.url, 'https://example.com/health');
      expect(saved.timeoutMs, 3200);
    });

    test('defaults connection haptics on and persists updates', () async {
      expect(await store.loadConnectionHapticsEnabled(), isTrue);

      await store.saveConnectionHapticsEnabled(false);

      expect(await store.loadConnectionHapticsEnabled(), isFalse);
    });

    test('defaults log display level to info and persists updates', () async {
      expect(await store.loadLogDisplayLevel(), LogDisplayLevel.info);

      await store.saveLogDisplayLevel(LogDisplayLevel.warning);
      expect(await store.loadLogDisplayLevel(), LogDisplayLevel.warning);

      await store.saveLogDisplayLevel(LogDisplayLevel.error);
      expect(await store.loadLogDisplayLevel(), LogDisplayLevel.error);
    });

    test('persists battery optimization connect prompt flag', () async {
      expect(await store.loadBatteryOptimizationConnectPromptShown(), isFalse);

      await store.saveBatteryOptimizationConnectPromptShown(true);

      expect(await store.loadBatteryOptimizationConnectPromptShown(), isTrue);
    });

    test('persists update check consent flag', () async {
      expect(await store.loadUpdateCheckConsentGranted(), isFalse);

      await store.saveUpdateCheckConsentGranted(true);

      expect(await store.loadUpdateCheckConsentGranted(), isTrue);
    });

    test('loads v0.7.4 profile JSON fixture with equal fields', () async {
      await prefs.setString(
        ProfileStore.prefsKeyProfilesJson,
        jsonEncode([
          {
            'id': 'v074-1',
            'displayName': 'Legacy VPN',
            'server': 'legacy.example.com',
            'user': 'bob',
            'dnsAutomatic': false,
            'dns1Host': '1.1.1.1',
            'dns1Protocol': 'dnsOverUdp',
            'dns2Host': 'dns.example',
            'dns2Protocol': 'dnsOverTls',
            'mtu': 1380,
          },
        ]),
      );

      final loaded = await store.loadProfiles();
      expect(loaded, hasLength(1));
      final p = loaded.single;
      expect(p.id, 'v074-1');
      expect(p.displayName, 'Legacy VPN');
      expect(p.server, 'legacy.example.com');
      expect(p.user, 'bob');
      expect(p.dnsAutomatic, isFalse);
      expect(p.dns1Host, '1.1.1.1');
      expect(p.dns1Protocol, DnsProtocol.dnsOverUdp);
      expect(p.dns2Host, 'dns.example');
      expect(p.dns2Protocol, DnsProtocol.dnsOverTls);
      expect(p.mtu, 1380);
      expect(p.favorite, isFalse);
    });

    test(
      'null secret sets secretsMissing and logs warning without value',
      () async {
        final logs = <(LogLevel, String)>[];
        final loggedStore = ProfileStore(
          prefsOverride: prefs,
          secretsOverride: secrets,
          onLog: (level, message) => logs.add((level, message)),
        );
        const profile = Profile(
          id: 'id-missing',
          displayName: 'Missing',
          server: 's.example',
          user: 'alice',
          dnsAutomatic: true,
          dns1Host: '',
          dns1Protocol: DnsProtocol.dnsOverUdp,
          dns2Host: '',
          dns2Protocol: DnsProtocol.dnsOverUdp,
        );
        await loggedStore.upsertProfile(
          profile,
          password: 'super-secret-password',
          psk: 'psk1',
        );
        await secrets.delete(ProfileStore.passwordKey('id-missing'));

        final row = await loggedStore.loadProfileWithSecrets('id-missing');
        expect(row, isNotNull);
        expect(row!.secretsMissing, isTrue);
        expect(row.password, '');
        expect(row.psk, 'psk1');
        expect(
          logs.any(
            (l) =>
                l.$1 == LogLevel.warning &&
                l.$2.contains('id-missing') &&
                l.$2.contains('password') &&
                !l.$2.contains('super-secret-password'),
          ),
          isTrue,
        );
      },
    );

    test('throwing SecretStore sets secretsMissing without throwing', () async {
      final logs = <(LogLevel, String)>[];
      final throwingStore = _ThrowingReadSecretStore();
      final loggedStore = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: throwingStore,
        onLog: (level, message) => logs.add((level, message)),
      );
      await prefs.setString(
        ProfileStore.prefsKeyProfilesJson,
        jsonEncode([
          const Profile(
            id: 'id-throw',
            displayName: 'Throw',
            server: 's.example',
            user: 'alice',
            dnsAutomatic: true,
            dns1Host: '',
            dns1Protocol: DnsProtocol.dnsOverUdp,
            dns2Host: '',
            dns2Protocol: DnsProtocol.dnsOverUdp,
          ).toJson(),
        ]),
      );

      final row = await loggedStore.loadProfileWithSecrets('id-throw');
      expect(row, isNotNull);
      expect(row!.secretsMissing, isTrue);
      expect(
        logs.where(
          (l) => l.$1 == LogLevel.error && l.$2.contains('PlatformException'),
        ),
        hasLength(2),
      );
    });

    test('empty string PSK round-trips with secretsMissing false', () async {
      const profile = Profile(
        id: 'id-empty-psk',
        displayName: 'NoPSK',
        server: 's.example',
        user: 'alice',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
      );
      await store.upsertProfile(profile, password: 'pw1', psk: '');

      final row = await store.loadProfileWithSecrets('id-empty-psk');
      expect(row, isNotNull);
      expect(row!.secretsMissing, isFalse);
      expect(row.password, 'pw1');
      expect(row.psk, '');
    });

    test('corrupt JSON backs up once and logs error', () async {
      final logs = <(LogLevel, String)>[];
      final loggedStore = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: secrets,
        onLog: (level, message) => logs.add((level, message)),
      );
      await prefs.setString(ProfileStore.prefsKeyProfilesJson, '{not-json');

      expect(await loggedStore.loadProfiles(), isEmpty);
      expect(
        prefs.getString(ProfileStore.prefsKeyProfilesJsonBackup),
        '{not-json',
      );
      expect(
        logs.any(
          (l) => l.$1 == LogLevel.error && l.$2.contains('FormatException'),
        ),
        isTrue,
      );

      await prefs.setString(ProfileStore.prefsKeyProfilesJson, '{corrupt-2');
      expect(await loggedStore.loadProfiles(), isEmpty);
      expect(
        prefs.getString(ProfileStore.prefsKeyProfilesJsonBackup),
        '{not-json',
      );
    });

    test('dropped row backs up and logs keys only without values', () async {
      final logs = <(LogLevel, String)>[];
      final loggedStore = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: secrets,
        onLog: (level, message) => logs.add((level, message)),
      );
      final raw = jsonEncode([
        const Profile(
          id: 'valid-1',
          displayName: 'Valid',
          server: 'ok.example',
          user: 'alice',
          dnsAutomatic: true,
          dns1Host: '',
          dns1Protocol: DnsProtocol.dnsOverUdp,
          dns2Host: '',
          dns2Protocol: DnsProtocol.dnsOverUdp,
        ).toJson(),
        {'id': '', 'server': 'secret-host.internal', 'user': 'secret-user'},
      ]);
      await prefs.setString(ProfileStore.prefsKeyProfilesJson, raw);

      final loaded = await loggedStore.loadProfiles();
      expect(loaded, hasLength(1));
      expect(loaded.single.id, 'valid-1');
      expect(prefs.getString(ProfileStore.prefsKeyProfilesJsonBackup), raw);
      final errLog = logs.singleWhere((l) => l.$1 == LogLevel.error).$2;
      expect(errLog, contains('index=1'));
      expect(errLog, contains('keys=[id, server, user]'));
      expect(errLog, isNot(contains('secret-host.internal')));
      expect(errLog, isNot(contains('secret-user')));
    });

    test(
      'upsertProfile leaves profile list unchanged when secret write throws',
      () async {
        final throwingWriteStore = _ThrowingWriteSecretStore();
        final guardedStore = ProfileStore(
          prefsOverride: prefs,
          secretsOverride: throwingWriteStore,
        );
        const profile = Profile(
          id: 'id-fail-write',
          displayName: 'FailWrite',
          server: 's.example',
          user: 'alice',
          dnsAutomatic: true,
          dns1Host: '',
          dns1Protocol: DnsProtocol.dnsOverUdp,
          dns2Host: '',
          dns2Protocol: DnsProtocol.dnsOverUdp,
        );

        await expectLater(
          guardedStore.upsertProfile(profile, password: 'pw', psk: 'psk'),
          throwsA(isA<PlatformException>()),
        );
        expect(await guardedStore.loadProfiles(), isEmpty);
      },
    );

    test(
      'checkUpgradeStatusOnce logs once and warns when state is not ok',
      () async {
        final logs = <(LogLevel, String)>[];
        final fakeSecrets = _FakeUpgradeSecretStore(
          const SecureStorageUpgradeStatus(
            state: SecureStorageUpgradeState.legacyDataUnreadable,
            reason: SecureStorageUpgradeReason.decryptFailed,
            entryCount: 2,
            willDiscardOnNextAccess: false,
          ),
        );
        final upgradeStore = ProfileStore(
          prefsOverride: prefs,
          secretsOverride: fakeSecrets,
          onLog: (level, message) => logs.add((level, message)),
        );

        await upgradeStore.checkUpgradeStatusOnce();
        await upgradeStore.checkUpgradeStatusOnce();

        expect(fakeSecrets.calls, 1);
        expect(logs, hasLength(1));
        expect(logs.single.$1, LogLevel.warning);
        expect(
          logs.single.$2,
          'secure_storage upgrade state=legacyDataUnreadable reason=decryptFailed entries=2 discardNext=false',
        );
      },
    );

    test(
      'toggleProfileFavorite orders starred first, unstars to top of others, and enforces max 5',
      () async {
        for (var i = 1; i <= 6; i++) {
          await store.upsertProfile(
            Profile(
              id: 'p$i',
              displayName: 'Profile $i',
              server: 's$i.example',
              user: 'u',
            ),
            password: 'pw',
            psk: '',
          );
        }

        // First starred goes to top; second starred follows it.
        var res = await store.toggleProfileFavorite('p4');
        expect(res.limitReached, isFalse);
        expect(res.favorite, isTrue);
        expect(res.profiles.map((p) => p.id), [
          'p4',
          'p1',
          'p2',
          'p3',
          'p5',
          'p6',
        ]);

        res = await store.toggleProfileFavorite('p2');
        expect(res.limitReached, isFalse);
        expect(res.profiles.map((p) => p.id), [
          'p4',
          'p2',
          'p1',
          'p3',
          'p5',
          'p6',
        ]);

        // Star up to 5.
        await store.toggleProfileFavorite('p6');
        await store.toggleProfileFavorite('p1');
        res = await store.toggleProfileFavorite('p5');
        expect(res.profiles.where((p) => p.favorite).length, 5);
        expect(res.profiles.map((p) => p.id), [
          'p4',
          'p2',
          'p6',
          'p1',
          'p5',
          'p3',
        ]);

        // 6th favorite is rejected without modifying order.
        final blocked = await store.toggleProfileFavorite('p3');
        expect(blocked.limitReached, isTrue);
        expect(blocked.favorite, isFalse);
        expect(blocked.profiles.map((p) => p.id), [
          'p4',
          'p2',
          'p6',
          'p1',
          'p5',
          'p3',
        ]);
        expect((await store.loadProfiles()).where((p) => p.favorite).length, 5);

        // Unstarring p4 puts it right below remaining favorites (top of non-favorites).
        final unstarred = await store.toggleProfileFavorite('p4');
        expect(unstarred.limitReached, isFalse);
        expect(unstarred.favorite, isFalse);
        expect(unstarred.profiles.map((p) => p.id), [
          'p2',
          'p6',
          'p1',
          'p5',
          'p4',
          'p3',
        ]);
      },
    );

    test(
      'reorderProfiles moves favorites and non-favorites separately and persists',
      () async {
        for (final id in ['a', 'b', 'c', 'd', 'e']) {
          await store.upsertProfile(
            Profile(
              id: id,
              displayName: id.toUpperCase(),
              server: '$id.example',
              user: 'u',
            ),
            password: 'pw',
            psk: '',
          );
        }
        await store.toggleProfileFavorite('d');
        await store.toggleProfileFavorite('b');
        // Order now: [d*, b*, a, c, e]

        final favReordered = await store.reorderProfiles(
          favoritesSection: true,
          oldIndex: 0,
          newIndex: 1,
        );
        expect(favReordered.map((p) => p.id), ['b', 'd', 'a', 'c', 'e']);

        final otherReordered = await store.reorderProfiles(
          favoritesSection: false,
          oldIndex: 2,
          newIndex: 0,
        );
        expect(otherReordered.map((p) => p.id), ['b', 'd', 'e', 'a', 'c']);

        final reloaded = await store.loadProfiles();
        expect(reloaded.map((p) => p.id), ['b', 'd', 'e', 'a', 'c']);
        expect(reloaded.where((p) => p.favorite).map((p) => p.id), ['b', 'd']);
      },
    );

    test('upsertProfile preserves favorite flag and position', () async {
      await store.upsertProfile(
        const Profile(
          id: 'p1',
          displayName: 'One',
          server: 'one.example',
          user: 'u',
        ),
        password: 'pw',
        psk: '',
      );
      await store.upsertProfile(
        const Profile(
          id: 'p2',
          displayName: 'Two',
          server: 'two.example',
          user: 'u',
        ),
        password: 'pw',
        psk: '',
      );
      await store.toggleProfileFavorite('p2');
      // Order: [p2*, p1]

      await store.upsertProfile(
        const Profile(
          id: 'p2',
          displayName: 'Two Updated',
          server: 'two.example',
          user: 'u',
          favorite: true,
        ),
        password: 'pw',
        psk: '',
      );

      final loaded = await store.loadProfiles();
      expect(loaded.map((p) => p.id), ['p2', 'p1']);
      expect(loaded.first.favorite, isTrue);
      expect(loaded.first.displayName, 'Two Updated');
    });

    test(
      'PPTP profile does not mark secretsMissing when psk secret is absent',
      () async {
        const pptp = Profile(
          id: 'p-pptp',
          displayName: 'PPTP Branch',
          server: 'pptp.example',
          user: 'alice',
          protocol: TunnelProtocol.pptp,
        );
        await store.upsertProfile(pptp, password: 'pw', psk: 'ignored');
        await secrets.delete(ProfileStore.pskKey('p-pptp'));

        final row = await store.loadProfileWithSecrets('p-pptp');
        expect(row, isNotNull);
        expect(row!.profile.protocol, TunnelProtocol.pptp);
        expect(row.password, 'pw');
        expect(row.psk, isEmpty);
        expect(row.secretsMissing, isFalse);
      },
    );

    test('Profile value equality compares all fields', () {
      const a = Profile(
        id: 'p1',
        displayName: 'Alpha',
        server: 'alpha.example',
        user: 'alice',
        protocol: TunnelProtocol.l2tp,
      );
      const b = Profile(
        id: 'p1',
        displayName: 'Alpha',
        server: 'alpha.example',
        user: 'alice',
        protocol: TunnelProtocol.l2tp,
      );
      const c = Profile(
        id: 'p1',
        displayName: 'Alpha',
        server: 'alpha.example',
        user: 'alice',
        protocol: TunnelProtocol.pptp,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));

      final forced = a.copyWith(forceUserspaceVpn: true);
      expect(forced.forceUserspaceVpn, isTrue);
      expect(forced.toJson()['forceUserspaceVpn'], isTrue);
      expect(a, isNot(equals(forced)));

      final switchedToPptp = forced.copyWith(protocol: TunnelProtocol.pptp);
      expect(switchedToPptp.forceUserspaceVpn, isFalse);
      expect(switchedToPptp.toJson().containsKey('forceUserspaceVpn'), isFalse);

      final parsedL2tp = Profile.tryFromJson(forced.toJson());
      expect(parsedL2tp?.forceUserspaceVpn, isTrue);
      final parsedPptp = Profile.tryFromJson({
        ...switchedToPptp.toJson(),
        'forceUserspaceVpn': true,
      });
      expect(parsedPptp?.forceUserspaceVpn, isFalse);
    });

    test(
      'upsertProfile with selectAsLastProfile=false keeps lastProfileId unchanged',
      () async {
        await store.upsertProfile(
          const Profile(
            id: 'p1',
            displayName: 'One',
            server: 'one.example',
            user: 'u1',
          ),
          password: 'pw1',
          psk: 'psk1',
        );
        expect(await store.loadLastProfileId(), 'p1');

        await store.upsertProfile(
          const Profile(
            id: 'p2',
            displayName: 'Two',
            server: 'two.example',
            user: 'u2',
          ),
          password: 'pw2',
          psk: 'psk2',
          selectAsLastProfile: false,
        );
        expect(await store.loadLastProfileId(), 'p1');
      },
    );
  });
}
