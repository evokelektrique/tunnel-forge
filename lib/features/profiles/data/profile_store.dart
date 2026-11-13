// Profile list JSON in [SharedPreferences]; password and PSK in [SecretStore].
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';

/// Persists sensitive strings (password, PSK) outside [SharedPreferences].
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
  Future<SecureStorageUpgradeStatus> checkUpgradeStatus() async =>
      SecureStorageUpgradeStatus.unsupported;
}

/// Production [SecretStore] backed by [FlutterSecureStorage].
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Throw instead of silently wiping every secret on a keystore/cipher error.
            aOptions: AndroidOptions(resetOnError: false),
          );

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<SecureStorageUpgradeStatus> checkUpgradeStatus() =>
      _storage.checkUpgradeStatus();
}

/// In-memory [SecretStore] for tests and widget tests.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) {
    if (initial != null) _data.addAll(initial);
  }

  final Map<String, String> _data = {};

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<void> deleteAll() async => _data.clear();

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<SecureStorageUpgradeStatus> checkUpgradeStatus() async =>
      SecureStorageUpgradeStatus.unsupported;
}

typedef ProfileStoreLog = void Function(LogLevel level, String message);

/// Loads, saves, and deletes [Profile] rows; tests may inject [prefsOverride] / [secretsOverride].
class ProfileStore {
  ProfileStore({
    SharedPreferences? prefsOverride,
    SecretStore? secretsOverride,
    ProfileStoreLog? onLog,
  }) : _prefsOverride = prefsOverride,
       _secrets = secretsOverride ?? FlutterSecureSecretStore(),
       _onLog = onLog;

  static const prefsKeyProfilesJson = 'vpn_profiles_json_v3';
  static const prefsKeyProfilesJsonBackup = 'vpn_profiles_json_v3_backup';
  static const prefsKeyLastProfileId = 'vpn_last_profile_id_v1';
  static const prefsKeyConnectionMode = 'connection_mode_v1';
  static const prefsKeyProxyHttpPort = 'proxy_http_port_v1';
  static const prefsKeyProxySocksPort = 'proxy_socks_port_v1';
  static const prefsKeyProxyAllowLanConnections =
      'proxy_allow_lan_connections_v1';
  static const prefsKeySplitTunnelEnabled = 'split_tunnel_enabled_v1';
  static const prefsKeySplitTunnelMode = 'split_tunnel_mode_v1';
  static const prefsKeySplitTunnelInclusivePackages =
      'split_tunnel_inclusive_packages_v1';
  static const prefsKeySplitTunnelExclusivePackages =
      'split_tunnel_exclusive_packages_v1';
  static const prefsKeyConnectivityCheckUrl = 'connectivity_check_url_v1';
  static const prefsKeyConnectivityCheckTimeoutMs =
      'connectivity_check_timeout_ms_v1';
  static const prefsKeyLogDisplayLevel = 'log_display_level_v1';
  static const prefsKeyBatteryOptimizationConnectPromptShown =
      'battery_optimization_connect_prompt_shown_v1';
  static const prefsKeyUpdateCheckConsentGranted =
      'update_check_consent_granted_v1';

  final SharedPreferences? _prefsOverride;
  final SecretStore _secrets;
  final ProfileStoreLog? _onLog;
  bool _upgradeChecked = false;

  static String passwordKey(String profileId) =>
      'tunnel_forge/profile/$profileId/password';
  static String pskKey(String profileId) =>
      'tunnel_forge/profile/$profileId/psk';

  String _passwordKey(String profileId) => passwordKey(profileId);
  String _pskKey(String profileId) => pskKey(profileId);

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? SharedPreferences.getInstance();

  static String newProfileId() {
    final b = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    return base64UrlEncode(b).replaceAll('=', '');
  }

  Future<void> checkUpgradeStatusOnce() async {
    if (_upgradeChecked) return;
    _upgradeChecked = true;
    try {
      final s = await _secrets.checkUpgradeStatus();
      final level = s.state == SecureStorageUpgradeState.ok
          ? LogLevel.info
          : LogLevel.warning;
      _onLog?.call(
        level,
        'secure_storage upgrade state=${s.state.name} reason=${s.reason.name} entries=${s.entryCount} discardNext=${s.willDiscardOnNextAccess}',
      );
    } catch (e) {
      _onLog?.call(
        LogLevel.warning,
        'secure_storage upgrade check failed error=${e.runtimeType}',
      );
    }
  }

  Future<void> _backupProfilesJsonIfAbsent(
    SharedPreferences prefs,
    String raw,
  ) async {
    if (prefs.containsKey(prefsKeyProfilesJsonBackup)) return;
    await prefs.setString(prefsKeyProfilesJsonBackup, raw);
  }

  Future<List<Profile>> loadProfiles() async {
    final p = await _prefs();
    final raw = p.getString(prefsKeyProfilesJson);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        await _backupProfilesJsonIfAbsent(p, raw);
        _onLog?.call(
          LogLevel.error,
          'Profile list decode failed (expected List, got ${decoded.runtimeType}); raw backed up (${raw.length} chars)',
        );
        return [];
      }
      final out = <Profile>[];
      var backedUp = false;
      for (var i = 0; i < decoded.length; i++) {
        final entry = decoded[i];
        final row = Profile.tryFromJson(entry);
        if (row != null) {
          out.add(row);
        } else {
          if (!backedUp) {
            await _backupProfilesJsonIfAbsent(p, raw);
            backedUp = true;
          }
          final detail = entry is Map
              ? 'keys=[${(entry.keys.map((k) => k.toString()).toList()..sort()).join(', ')}]'
              : 'type=${entry.runtimeType}';
          _onLog?.call(LogLevel.error, 'Dropped profile row index=$i $detail');
        }
      }
      return out;
    } catch (e) {
      await _backupProfilesJsonIfAbsent(p, raw);
      _onLog?.call(
        LogLevel.error,
        'Profile list decode failed (${e.runtimeType}); raw backed up (${raw.length} chars)',
      );
      return [];
    }
  }

  Future<String?> loadLastProfileId() async {
    final p = await _prefs();
    return p.getString(prefsKeyLastProfileId);
  }

  Future<void> setLastProfileId(String? id) async {
    final p = await _prefs();
    if (id == null || id.isEmpty) {
      await p.remove(prefsKeyLastProfileId);
    } else {
      await p.setString(prefsKeyLastProfileId, id);
    }
  }

  Future<ConnectionMode> loadConnectionMode() async {
    final p = await _prefs();
    return ConnectionMode.fromJson(p.getString(prefsKeyConnectionMode));
  }

  Future<void> saveConnectionMode(ConnectionMode mode) async {
    final p = await _prefs();
    await p.setString(prefsKeyConnectionMode, mode.jsonValue);
  }

  Future<ProxySettings> loadProxySettings() async {
    final p = await _prefs();
    return ProxySettings(
      httpPort: ProxySettings.normalizePort(
        p.getInt(prefsKeyProxyHttpPort) ?? ProxySettings.defaultHttpPort,
        fallback: ProxySettings.defaultHttpPort,
      ),
      socksPort: ProxySettings.normalizePort(
        p.getInt(prefsKeyProxySocksPort) ?? ProxySettings.defaultSocksPort,
        fallback: ProxySettings.defaultSocksPort,
      ),
      allowLanConnections: p.getBool(prefsKeyProxyAllowLanConnections) ?? false,
    );
  }

  Future<void> saveProxySettings(ProxySettings settings) async {
    final p = await _prefs();
    await p.setInt(
      prefsKeyProxyHttpPort,
      ProxySettings.normalizePort(
        settings.httpPort,
        fallback: ProxySettings.defaultHttpPort,
      ),
    );
    await p.setInt(
      prefsKeyProxySocksPort,
      ProxySettings.normalizePort(
        settings.socksPort,
        fallback: ProxySettings.defaultSocksPort,
      ),
    );
    await p.setBool(
      prefsKeyProxyAllowLanConnections,
      settings.allowLanConnections,
    );
  }

  Future<SplitTunnelSettings> loadSplitTunnelSettings() async {
    final p = await _prefs();
    return SplitTunnelSettings(
      enabled: p.getBool(prefsKeySplitTunnelEnabled) ?? false,
      mode: SplitTunnelMode.fromJson(p.getString(prefsKeySplitTunnelMode)),
      inclusivePackages: SplitTunnelSettings.normalizePackages(
        p.getStringList(prefsKeySplitTunnelInclusivePackages) ?? const [],
      ),
      exclusivePackages: SplitTunnelSettings.normalizePackages(
        p.getStringList(prefsKeySplitTunnelExclusivePackages) ?? const [],
      ),
    );
  }

  Future<void> saveSplitTunnelSettings(SplitTunnelSettings settings) async {
    final p = await _prefs();
    final normalized = settings.copyWith();
    await p.setBool(prefsKeySplitTunnelEnabled, normalized.enabled);
    await p.setString(prefsKeySplitTunnelMode, normalized.mode.jsonValue);
    await p.setStringList(
      prefsKeySplitTunnelInclusivePackages,
      normalized.inclusivePackages,
    );
    await p.setStringList(
      prefsKeySplitTunnelExclusivePackages,
      normalized.exclusivePackages,
    );
  }

  Future<ConnectivityCheckSettings> loadConnectivityCheckSettings() async {
    final p = await _prefs();
    return ConnectivityCheckSettings(
      url: ConnectivityCheckSettings.normalizeUrl(
        p.getString(prefsKeyConnectivityCheckUrl) ??
            ConnectivityCheckSettings.defaultUrl,
      ),
      timeoutMs: ConnectivityCheckSettings.normalizeTimeoutMs(
        p.getInt(prefsKeyConnectivityCheckTimeoutMs) ??
            ConnectivityCheckSettings.defaultTimeoutMs,
      ),
    );
  }

  Future<void> saveConnectivityCheckSettings(
    ConnectivityCheckSettings settings,
  ) async {
    final p = await _prefs();
    await p.setString(
      prefsKeyConnectivityCheckUrl,
      ConnectivityCheckSettings.normalizeUrl(settings.url),
    );
    await p.setInt(
      prefsKeyConnectivityCheckTimeoutMs,
      ConnectivityCheckSettings.normalizeTimeoutMs(settings.timeoutMs),
    );
  }

  Future<LogDisplayLevel> loadLogDisplayLevel() async {
    final p = await _prefs();
    return LogDisplayLevel.fromStorage(p.getString(prefsKeyLogDisplayLevel));
  }

  Future<void> saveLogDisplayLevel(LogDisplayLevel level) async {
    final p = await _prefs();
    await p.setString(prefsKeyLogDisplayLevel, level.storageValue);
  }

  Future<bool> loadBatteryOptimizationConnectPromptShown() async {
    final p = await _prefs();
    return p.getBool(prefsKeyBatteryOptimizationConnectPromptShown) ?? false;
  }

  Future<void> saveBatteryOptimizationConnectPromptShown(bool shown) async {
    final p = await _prefs();
    await p.setBool(prefsKeyBatteryOptimizationConnectPromptShown, shown);
  }

  Future<bool> loadUpdateCheckConsentGranted() async {
    final p = await _prefs();
    return p.getBool(prefsKeyUpdateCheckConsentGranted) ?? false;
  }

  Future<void> saveUpdateCheckConsentGranted(bool granted) async {
    final p = await _prefs();
    await p.setBool(prefsKeyUpdateCheckConsentGranted, granted);
  }

  Future<void> _saveProfileList(List<Profile> list) async {
    final p = await _prefs();
    await p.setString(
      prefsKeyProfilesJson,
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> upsertProfile(
    Profile profile, {
    required String password,
    required String psk,
  }) async {
    final list = await loadProfiles();
    final idx = list.indexWhere((e) => e.id == profile.id);
    if (idx >= 0) {
      list[idx] = profile;
    } else {
      list.add(profile);
    }
    // Write secrets before the profile list so a failed secret write never leaves a secretless profile.
    await _secrets.write(_passwordKey(profile.id), password);
    await _secrets.write(_pskKey(profile.id), psk);
    await _saveProfileList(list);
    await setLastProfileId(profile.id);
  }

  Future<Profile> saveImportedProfile(
    ProfileTransferEnvelope envelope, {
    bool selectAsLastProfile = true,
  }) async {
    final imported = envelope.toProfile(newProfileId());
    final list = await loadProfiles()
      ..add(imported);
    await _secrets.write(_passwordKey(imported.id), envelope.password);
    await _secrets.write(_pskKey(imported.id), envelope.psk);
    await _saveProfileList(list);
    if (selectAsLastProfile) {
      await setLastProfileId(imported.id);
    }
    return imported;
  }

  Future<void> deleteProfile(String id) async {
    if (id.isEmpty) return;
    final list = await loadProfiles();
    list.removeWhere((e) => e.id == id);
    await _saveProfileList(list);
    await _secrets.delete(_passwordKey(id));
    await _secrets.delete(_pskKey(id));
    final last = await loadLastProfileId();
    if (last == id) await setLastProfileId(null);
  }

  Future<void> resetSecureStorage() async {
    _onLog?.call(
      LogLevel.warning,
      'Resetting secure storage (deleting all saved credentials)',
    );
    await _secrets.deleteAll();
  }

  Future<String?> _readSecret(String key, String id, String label) async {
    try {
      final v = await _secrets.read(key);
      if (v == null) {
        _onLog?.call(
          LogLevel.warning,
          'Secret missing profile=$id field=$label',
        );
      }
      return v;
    } catch (e) {
      _onLog?.call(
        LogLevel.error,
        'Secret read failed profile=$id field=$label error=${e.runtimeType}',
      );
      return null;
    }
  }

  Future<({Profile profile, String password, String psk, bool secretsMissing})?>
  loadProfileWithSecrets(String id) async {
    final list = await loadProfiles();
    Profile? profile;
    for (final p in list) {
      if (p.id == id) {
        profile = p;
        break;
      }
    }
    if (profile == null) return null;
    final passwordRaw = await _readSecret(_passwordKey(id), id, 'password');
    final pskRaw = await _readSecret(_pskKey(id), id, 'psk');
    return (
      profile: profile,
      password: passwordRaw ?? '',
      psk: pskRaw ?? '',
      secretsMissing: passwordRaw == null || pskRaw == null,
    );
  }
}
