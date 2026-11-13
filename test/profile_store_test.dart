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
      expect(p.mtu, Profile.defaultVpnMtu);
      expect(p.toJson().containsKey('routingMode'), isFalse);
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

    test('defaults log display level to info and persists updates', () async {
      expect(await store.loadLogDisplayLevel(), LogDisplayLevel.info);

      await store.saveLogDisplayLevel(LogDisplayLevel.warning);

      expect(await store.loadLogDisplayLevel(), LogDisplayLevel.warning);
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
  });
}
