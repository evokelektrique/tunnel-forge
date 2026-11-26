// Profile list JSON in [SharedPreferences]; password and PSK in [SecretStore].
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

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
  static const prefsKeyProxyAuthEnabled = 'proxy_auth_enabled_v1';
  static const prefsKeyProxyAuthUsername = 'proxy_auth_username_v1';
  static const secretKeyProxyAuthPassword = 'tunnel_forge/proxy/auth_password';
  static const prefsKeySplitTunnelEnabled = 'split_tunnel_enabled_v1';
  static const prefsKeySplitTunnelMode = 'split_tunnel_mode_v1';
  static const prefsKeySplitTunnelInclusivePackages =
      'split_tunnel_inclusive_packages_v1';
  static const prefsKeySplitTunnelExclusivePackages =
      'split_tunnel_exclusive_packages_v1';
  static const prefsKeyConnectivityCheckUrl = 'connectivity_check_url_v1';
  static const prefsKeyConnectivityCheckTimeoutMs =
      'connectivity_check_timeout_ms_v1';
  static const prefsKeyConnectionHapticsEnabled =
      'connection_haptics_enabled_v1';
  static const prefsKeyLogDisplayLevel = 'log_display_level_v1';
  static const prefsKeyBatteryOptimizationConnectPromptShown =
      'battery_optimization_connect_prompt_shown_v1';
  static const prefsKeyUpdateCheckConsentGranted =
      'update_check_consent_granted_v1';
  static const prefsKeySubscriptionsJson = 'vpn_subscriptions_json_v1';
  static const prefsKeyPendingSubscriptionSummariesJson =
      'vpn_pending_subscription_summaries_v1';

  final SharedPreferences? _prefsOverride;
  final SecretStore _secrets;
  final ProfileStoreLog? _onLog;
  bool _upgradeChecked = false;
  Future<void> _writeQueue = Future<void>.value();

  Future<T> _runSerialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.catchError((_) {}).then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  /// Keeps favorites at the front (capped at [Profile.maxFavorites] per tab/subscription)
  /// while preserving relative order within each bucket.
  static List<Profile> normalizeProfiles(List<Profile> profiles) {
    final buckets = <String?, List<Profile>>{};
    for (final profile in profiles) {
      buckets
          .putIfAbsent(profile.subscriptionId, () => <Profile>[])
          .add(profile);
    }
    final out = <Profile>[];
    for (final bucket in buckets.values) {
      final favorites = <Profile>[];
      final others = <Profile>[];
      for (final profile in bucket) {
        if (profile.favorite && favorites.length < Profile.maxFavorites) {
          favorites.add(profile);
        } else {
          others.add(
            profile.favorite ? profile.copyWith(favorite: false) : profile,
          );
        }
      }
      out
        ..addAll(favorites)
        ..addAll(others);
    }
    return out;
  }

  /// Reorders an item strictly within either the favorites or non-favorites slice.
  /// When [filterBySubscription] is true, scopes reordering to [subscriptionId] (`null` = Local).
  /// Expects [newIndex] as the post-removal destination index (matching [SliverReorderableList.onReorderItem]).
  static List<Profile> reorderProfileSection(
    List<Profile> profiles, {
    required bool favoritesSection,
    required int oldIndex,
    required int newIndex,
    String? subscriptionId,
    bool filterBySubscription = false,
  }) {
    final normalized = normalizeProfiles(profiles);
    if (!filterBySubscription) {
      final favorites = normalized.where((p) => p.favorite).toList();
      final others = normalized.where((p) => !p.favorite).toList();
      final target = favoritesSection ? favorites : others;
      if (oldIndex < 0 ||
          oldIndex >= target.length ||
          newIndex < 0 ||
          newIndex >= target.length ||
          oldIndex == newIndex) {
        return normalized;
      }
      final moved = target.removeAt(oldIndex);
      target.insert(newIndex, moved);
      return <Profile>[...favorites, ...others];
    }
    final inBucket = normalized
        .where((p) => p.subscriptionId == subscriptionId)
        .toList();
    final othersOutside = normalized
        .where((p) => p.subscriptionId != subscriptionId)
        .toList();
    final favorites = inBucket.where((p) => p.favorite).toList();
    final others = inBucket.where((p) => !p.favorite).toList();
    final target = favoritesSection ? favorites : others;
    if (oldIndex < 0 ||
        oldIndex >= target.length ||
        newIndex < 0 ||
        newIndex >= target.length ||
        oldIndex == newIndex) {
      return normalized;
    }
    final moved = target.removeAt(oldIndex);
    target.insert(newIndex, moved);
    return normalizeProfiles(<Profile>[
      ...othersOutside,
      ...favorites,
      ...others,
    ]);
  }

  static String passwordKey(String profileId) =>
      'tunnel_forge/profile/$profileId/password';
  static String pskKey(String profileId) =>
      'tunnel_forge/profile/$profileId/psk';
  static String subscriptionUrlKey(String subscriptionId) =>
      'tunnel_forge/subscription/$subscriptionId/url';

  String _passwordKey(String profileId) => passwordKey(profileId);
  String _pskKey(String profileId) => pskKey(profileId);

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? SharedPreferences.getInstance();

  /// Refreshes cached [SharedPreferences] after a background isolate write.
  Future<void> reloadPreferences() async {
    if (_prefsOverride != null) return;
    final p = await _prefs();
    await p.reload();
  }

  static String newProfileId() {
    final b = Uint8List.fromList(
      List<int>.generate(16, (_) => Random.secure().nextInt(256)),
    );
    return base64UrlEncode(b).replaceAll('=', '');
  }

  static String nextDefaultProfileName(
    Iterable<String> existingNames, {
    String Function(int number)? formatter,
  }) {
    final used = existingNames
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
    final formatName = formatter ?? AppL10n.current.defaultProfileName;
    for (var n = 1; ; n++) {
      final candidate = formatName(n).trim();
      if (!used.contains(candidate.toLowerCase())) {
        return candidate;
      }
    }
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
      return normalizeProfiles(out);
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
    String authPassword = '';
    try {
      authPassword = (await _secrets.read(secretKeyProxyAuthPassword)) ?? '';
    } catch (_) {
      authPassword = '';
    }
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
      authEnabled: p.getBool(prefsKeyProxyAuthEnabled) ?? false,
      authUsername: p.getString(prefsKeyProxyAuthUsername) ?? '',
      authPassword: authPassword,
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
    await p.setBool(prefsKeyProxyAuthEnabled, settings.authEnabled);
    final username = settings.authUsername.trim();
    if (username.isEmpty) {
      await p.remove(prefsKeyProxyAuthUsername);
    } else {
      await p.setString(prefsKeyProxyAuthUsername, username);
    }
    if (settings.authPassword.isEmpty) {
      await _secrets.delete(secretKeyProxyAuthPassword);
    } else {
      await _secrets.write(secretKeyProxyAuthPassword, settings.authPassword);
    }
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

  Future<bool> loadConnectionHapticsEnabled() async {
    final p = await _prefs();
    return p.getBool(prefsKeyConnectionHapticsEnabled) ?? true;
  }

  Future<void> saveConnectionHapticsEnabled(bool enabled) async {
    final p = await _prefs();
    await p.setBool(prefsKeyConnectionHapticsEnabled, enabled);
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
    final normalized = normalizeProfiles(list);
    await p.setString(
      prefsKeyProfilesJson,
      jsonEncode(normalized.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> upsertProfile(
    Profile profile, {
    required String password,
    required String psk,
    bool selectAsLastProfile = true,
  }) {
    return _runSerialized(() async {
      final list = await loadProfiles();
      final idx = list.indexWhere((e) => e.id == profile.id);
      if (idx >= 0) {
        list[idx] = profile;
      } else {
        list.add(profile);
      }
      // Write secrets before the profile list so a failed secret write never leaves a secretless profile.
      await _secrets.write(_passwordKey(profile.id), password);
      await _secrets.write(
        _pskKey(profile.id),
        profile.protocol.isPptp ? '' : psk,
      );
      await _saveProfileList(list);
      if (selectAsLastProfile) {
        await setLastProfileId(profile.id);
      }
    });
  }

  Future<({List<Profile> profiles, bool limitReached, bool favorite})>
  toggleProfileFavorite(String id) {
    return _runSerialized(() async {
      final list = await loadProfiles();
      final idx = list.indexWhere((e) => e.id == id);
      if (idx < 0) {
        return (profiles: list, limitReached: false, favorite: false);
      }
      final target = list[idx];
      final bucket = target.subscriptionId;
      final inBucket = list.where((p) => p.subscriptionId == bucket).toList();
      final outsideBucket = list
          .where((p) => p.subscriptionId != bucket)
          .toList();
      final bucketIdx = inBucket.indexWhere((e) => e.id == id);
      final favCount = inBucket.where((p) => p.favorite).length;
      if (!target.favorite) {
        if (favCount >= Profile.maxFavorites) {
          return (profiles: list, limitReached: true, favorite: false);
        }
        final updatedBucket = List<Profile>.of(inBucket)..removeAt(bucketIdx);
        updatedBucket.insert(favCount, target.copyWith(favorite: true));
        final normalized = normalizeProfiles(<Profile>[
          ...outsideBucket,
          ...updatedBucket,
        ]);
        await _saveProfileList(normalized);
        return (profiles: normalized, limitReached: false, favorite: true);
      }
      final updatedBucket = List<Profile>.of(inBucket)..removeAt(bucketIdx);
      updatedBucket.insert(favCount - 1, target.copyWith(favorite: false));
      final normalized = normalizeProfiles(<Profile>[
        ...outsideBucket,
        ...updatedBucket,
      ]);
      await _saveProfileList(normalized);
      return (profiles: normalized, limitReached: false, favorite: false);
    });
  }

  Future<List<Profile>> reorderProfiles({
    required bool favoritesSection,
    required int oldIndex,
    required int newIndex,
    String? subscriptionId,
    bool filterBySubscription = false,
  }) {
    return _runSerialized(() async {
      final list = await loadProfiles();
      final next = reorderProfileSection(
        list,
        favoritesSection: favoritesSection,
        oldIndex: oldIndex,
        newIndex: newIndex,
        subscriptionId: subscriptionId,
        filterBySubscription: filterBySubscription,
      );
      await _saveProfileList(next);
      return next;
    });
  }

  Future<Profile> saveImportedProfile(
    ProfileTransferEnvelope envelope, {
    bool selectAsLastProfile = true,
  }) async {
    final saved = await saveImportedProfiles([
      envelope,
    ], selectAsLastProfile: selectAsLastProfile);
    return saved.single;
  }

  Future<List<Profile>> saveImportedProfiles(
    List<ProfileTransferEnvelope> envelopes, {
    bool selectAsLastProfile = true,
  }) {
    if (envelopes.isEmpty) return Future.value(const []);
    return _runSerialized(() async {
      final list = await loadProfiles();
      final usedNames = list
          .map((p) => p.displayName.trim().toLowerCase())
          .where((name) => name.isNotEmpty)
          .toSet();
      final imported = <Profile>[];
      for (final envelope in envelopes) {
        final fallbackName = envelope.displayName.trim().isEmpty
            ? nextDefaultProfileName(usedNames)
            : null;
        final profile = envelope.toProfile(
          newProfileId(),
          fallbackDisplayName: fallbackName,
        );
        usedNames.add(profile.displayName.trim().toLowerCase());
        await _secrets.write(_passwordKey(profile.id), envelope.password);
        await _secrets.write(
          _pskKey(profile.id),
          profile.protocol.isPptp ? '' : envelope.psk,
        );
        list.add(profile);
        imported.add(profile);
      }
      await _saveProfileList(list);
      if (selectAsLastProfile) {
        await setLastProfileId(imported.last.id);
      }
      return imported;
    });
  }

  Future<void> deleteProfile(String id) => deleteProfiles([id]);

  Future<void> deleteProfiles(Iterable<String> ids) {
    final idSet = ids.where((id) => id.isNotEmpty).toSet();
    if (idSet.isEmpty) return Future.value();
    return _runSerialized(() async {
      final list = await loadProfiles();
      list.removeWhere((e) => idSet.contains(e.id));
      await _saveProfileList(list);
      for (final id in idSet) {
        await _secrets.delete(_passwordKey(id));
        await _secrets.delete(_pskKey(id));
      }
      final last = await loadLastProfileId();
      if (last != null && idSet.contains(last)) await setLastProfileId(null);
    });
  }

  Future<void> resetSecureStorage() {
    return _runSerialized(() async {
      _onLog?.call(
        LogLevel.warning,
        'Resetting secure storage (deleting all saved credentials)',
      );
      await _secrets.deleteAll();
    });
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
    if (profile.protocol.isPptp) {
      return (
        profile: profile,
        password: passwordRaw ?? '',
        psk: '',
        secretsMissing: passwordRaw == null,
      );
    }
    final pskRaw = await _readSecret(_pskKey(id), id, 'psk');
    return (
      profile: profile,
      password: passwordRaw ?? '',
      psk: pskRaw ?? '',
      secretsMissing: passwordRaw == null || pskRaw == null,
    );
  }

  static String subscriptionMatchKey({
    required TunnelProtocol protocol,
    required String server,
    required String user,
  }) => '${protocol.jsonValue}|${server.trim().toLowerCase()}|$user';

  static bool _sameProfileFields(Profile a, Profile b) {
    return a.displayName == b.displayName &&
        a.server.trim().toLowerCase() == b.server.trim().toLowerCase() &&
        a.user == b.user &&
        a.protocol == b.protocol &&
        a.pppAuth == b.pppAuth &&
        a.mppeMode == b.mppeMode &&
        a.dnsAutomatic == b.dnsAutomatic &&
        a.dns1Host == b.dns1Host &&
        a.dns1Protocol == b.dns1Protocol &&
        a.dns2Host == b.dns2Host &&
        a.dns2Protocol == b.dns2Protocol &&
        a.mtu == b.mtu &&
        a.subscriptionId == b.subscriptionId;
  }

  Future<List<Subscription>> loadSubscriptions() async {
    final p = await _prefs();
    final raw = p.getString(prefsKeySubscriptionsJson);
    if (raw == null || raw.isEmpty) return const <Subscription>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Subscription>[];
      final out = <Subscription>[];
      var migrated = false;
      for (final entry in decoded) {
        final sub = Subscription.tryFromJson(entry);
        if (sub == null) continue;
        if (sub.url.isNotEmpty) {
          try {
            await _secrets.write(subscriptionUrlKey(sub.id), sub.url);
            migrated = true;
            out.add(sub.copyWith(urlMissing: false));
          } catch (e) {
            _onLog?.call(
              LogLevel.warning,
              'Subscription URL secret migration failed id=${sub.id} error=${e.runtimeType}',
            );
            out.add(sub.copyWith(urlMissing: false));
          }
        } else {
          String? secretUrl;
          try {
            secretUrl = await _secrets.read(subscriptionUrlKey(sub.id));
          } catch (e) {
            _onLog?.call(
              LogLevel.error,
              'Subscription URL secret read failed id=${sub.id} error=${e.runtimeType}',
            );
            secretUrl = null;
          }
          final clean = secretUrl?.trim() ?? '';
          if (clean.isEmpty) {
            out.add(sub.copyWith(url: '', urlMissing: true));
          } else {
            out.add(sub.copyWith(url: clean, urlMissing: false));
          }
        }
      }
      if (migrated) {
        await _saveSubscriptions(out);
      }
      return out;
    } catch (e) {
      _onLog?.call(
        LogLevel.error,
        'Subscription list decode failed (${e.runtimeType})',
      );
      return const <Subscription>[];
    }
  }

  Future<void> _saveSubscriptions(List<Subscription> subscriptions) async {
    final p = await _prefs();
    await p.setString(
      prefsKeySubscriptionsJson,
      jsonEncode(
        subscriptions.map((s) => s.toJson(includeUrl: false)).toList(),
      ),
    );
  }

  Future<void> saveSubscription(Subscription subscription) {
    return _runSerialized(() async {
      final list = List<Subscription>.of(await loadSubscriptions());
      final cleanUrl = subscription.url.trim();
      if (cleanUrl.isNotEmpty) {
        await _secrets.write(subscriptionUrlKey(subscription.id), cleanUrl);
      }
      final stored = subscription.copyWith(
        url: cleanUrl,
        urlMissing: cleanUrl.isEmpty,
      );
      final idx = list.indexWhere((s) => s.id == stored.id);
      if (idx >= 0) {
        list[idx] = stored;
      } else {
        list.add(stored);
      }
      await _saveSubscriptions(list);
    });
  }

  Future<void> recordSubscriptionError(
    String subscriptionId,
    String errorMessage,
  ) {
    return _runSerialized(() async {
      final list = List<Subscription>.of(await loadSubscriptions());
      final idx = list.indexWhere((s) => s.id == subscriptionId);
      if (idx < 0) return;
      list[idx] = list[idx].copyWith(lastError: errorMessage);
      await _saveSubscriptions(list);
    });
  }

  /// Atomically diffs [envelopes] into [subscription]'s profiles, preserving IDs
  /// and favorite stars on `(protocol, server, user)` matches.
  Future<SubscriptionSyncSummary> applySubscriptionSync({
    required Subscription subscription,
    required List<ProfileTransferEnvelope> envelopes,
    int skippedInvalidLines = 0,
    required SubscriptionSyncTrigger trigger,
    required DateTime syncedAt,
    void Function(int processed, int total)? onProgress,
  }) {
    return _runSerialized(() async {
      await reloadPreferences();
      final subs = List<Subscription>.of(await loadSubscriptions());
      final subIdx = subs.indexWhere((s) => s.id == subscription.id);
      if (trigger != SubscriptionSyncTrigger.initialAdd && subIdx < 0) {
        return SubscriptionSyncSummary(
          subscriptionId: subscription.id,
          subscriptionName: subscription.name,
          importedCount: 0,
          updatedCount: 0,
          removedCount: 0,
          skippedInvalidLines: skippedInvalidLines,
          syncedAtMs: syncedAt.millisecondsSinceEpoch,
          trigger: trigger,
        );
      }

      final allProfiles = await loadProfiles();
      final otherProfiles = allProfiles
          .where((p) => p.subscriptionId != subscription.id)
          .toList();
      final existingSubProfiles = allProfiles
          .where((p) => p.subscriptionId == subscription.id)
          .toList();

      final queues = <String, ListQueue<Profile>>{};
      for (final profile in existingSubProfiles) {
        final key = subscriptionMatchKey(
          protocol: profile.protocol,
          server: profile.server,
          user: profile.user,
        );
        queues.putIfAbsent(key, ListQueue<Profile>.new).addLast(profile);
      }

      final usedNames = <String>{
        for (final p in otherProfiles)
          if (p.displayName.trim().isNotEmpty)
            p.displayName.trim().toLowerCase(),
      };
      final nextSubProfiles = <Profile>[];
      var importedCount = 0;
      var updatedCount = 0;
      final total = envelopes.length;

      for (var i = 0; i < total; i++) {
        final envelope = envelopes[i];
        final key = subscriptionMatchKey(
          protocol: envelope.protocol,
          server: envelope.server,
          user: envelope.user,
        );
        final queue = queues[key];
        final matched = (queue != null && queue.isNotEmpty)
            ? queue.removeFirst()
            : null;
        final desiredPsk = envelope.protocol.isPptp ? '' : envelope.psk;

        if (matched != null) {
          final fallbackName = envelope.displayName.trim().isEmpty
              ? matched.displayName
              : null;
          final candidate = envelope.toProfile(
            matched.id,
            fallbackDisplayName: fallbackName,
            subscriptionId: subscription.id,
            favorite: matched.favorite,
          );
          usedNames.add(candidate.displayName.trim().toLowerCase());
          final existingPassword = await _readSecret(
            _passwordKey(matched.id),
            matched.id,
            'password',
          );
          final existingPsk = matched.protocol.isPptp
              ? ''
              : await _readSecret(_pskKey(matched.id), matched.id, 'psk');
          final secretsChanged =
              existingPassword == null ||
              existingPassword != envelope.password ||
              (!candidate.protocol.isPptp &&
                  (existingPsk == null || existingPsk != desiredPsk));
          final fieldsChanged = !_sameProfileFields(matched, candidate);
          if (secretsChanged) {
            await _secrets.write(_passwordKey(matched.id), envelope.password);
            await _secrets.write(_pskKey(matched.id), desiredPsk);
          }
          if (fieldsChanged || secretsChanged) {
            updatedCount += 1;
            nextSubProfiles.add(candidate);
          } else {
            nextSubProfiles.add(matched);
          }
        } else {
          final fallbackName = envelope.displayName.trim().isEmpty
              ? nextDefaultProfileName(usedNames)
              : null;
          final newProfile = envelope.toProfile(
            newProfileId(),
            fallbackDisplayName: fallbackName,
            subscriptionId: subscription.id,
          );
          usedNames.add(newProfile.displayName.trim().toLowerCase());
          // Write secrets before saving profile list so a failed keystore write never leaves a secretless profile.
          await _secrets.write(_passwordKey(newProfile.id), envelope.password);
          await _secrets.write(_pskKey(newProfile.id), desiredPsk);
          nextSubProfiles.add(newProfile);
          importedCount += 1;
        }
        onProgress?.call(i + 1, total);
      }

      final removedIds = <String>[];
      for (final queue in queues.values) {
        for (final leftover in queue) {
          removedIds.add(leftover.id);
        }
      }

      await _saveProfileList(<Profile>[...otherProfiles, ...nextSubProfiles]);
      for (final id in removedIds) {
        await _secrets.delete(_passwordKey(id));
        await _secrets.delete(_pskKey(id));
      }

      final lastId = await loadLastProfileId();
      if (lastId != null && removedIds.contains(lastId)) {
        await setLastProfileId(null);
      }

      final baseSub = subIdx >= 0 ? subs[subIdx] : subscription;
      final updatedSub = baseSub.copyWith(
        lastUpdatedAtMs: syncedAt.millisecondsSinceEpoch,
        clearLastError: true,
      );
      if (subIdx >= 0) {
        subs[subIdx] = updatedSub;
      } else {
        final cleanUrl = updatedSub.url.trim();
        if (cleanUrl.isNotEmpty) {
          await _secrets.write(subscriptionUrlKey(updatedSub.id), cleanUrl);
        }
        subs.add(updatedSub);
      }
      await _saveSubscriptions(subs);

      return SubscriptionSyncSummary(
        subscriptionId: updatedSub.id,
        subscriptionName: updatedSub.name,
        importedCount: importedCount,
        updatedCount: updatedCount,
        removedCount: removedIds.length,
        skippedInvalidLines: skippedInvalidLines,
        syncedAtMs: syncedAt.millisecondsSinceEpoch,
        trigger: trigger,
      );
    });
  }

  Future<({int removedProfilesCount})> deleteSubscription(
    String subscriptionId,
  ) {
    return _runSerialized(() async {
      final subs = List<Subscription>.of(await loadSubscriptions());
      subs.removeWhere((s) => s.id == subscriptionId);
      await _saveSubscriptions(subs);
      await _secrets.delete(subscriptionUrlKey(subscriptionId));

      final profiles = await loadProfiles();
      final removedIds = profiles
          .where((p) => p.subscriptionId == subscriptionId)
          .map((p) => p.id)
          .toList();
      profiles.removeWhere((p) => p.subscriptionId == subscriptionId);
      await _saveProfileList(profiles);

      for (final id in removedIds) {
        await _secrets.delete(_passwordKey(id));
        await _secrets.delete(_pskKey(id));
      }
      final lastId = await loadLastProfileId();
      if (lastId != null && removedIds.contains(lastId)) {
        await setLastProfileId(null);
      }

      final pending = await _loadPendingSummariesUnlocked();
      final filtered = pending
          .where((s) => s.subscriptionId != subscriptionId)
          .toList();
      if (filtered.length != pending.length) {
        await _savePendingSummariesUnlocked(filtered);
      }
      return (removedProfilesCount: removedIds.length);
    });
  }

  Future<List<SubscriptionSyncSummary>> _loadPendingSummariesUnlocked() async {
    final p = await _prefs();
    final raw = p.getString(prefsKeyPendingSubscriptionSummariesJson);
    if (raw == null || raw.isEmpty) return const <SubscriptionSyncSummary>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <SubscriptionSyncSummary>[];
      return decoded
          .map(SubscriptionSyncSummary.tryFromJson)
          .whereType<SubscriptionSyncSummary>()
          .toList();
    } catch (_) {
      return const <SubscriptionSyncSummary>[];
    }
  }

  Future<void> _savePendingSummariesUnlocked(
    List<SubscriptionSyncSummary> summaries,
  ) async {
    final p = await _prefs();
    if (summaries.isEmpty) {
      await p.remove(prefsKeyPendingSubscriptionSummariesJson);
    } else {
      await p.setString(
        prefsKeyPendingSubscriptionSummariesJson,
        jsonEncode(summaries.map((s) => s.toJson()).toList()),
      );
    }
  }

  Future<void> enqueuePendingSubscriptionSummary(
    SubscriptionSyncSummary summary,
  ) {
    return _runSerialized(() async {
      final current = List<SubscriptionSyncSummary>.of(
        await _loadPendingSummariesUnlocked(),
      );
      final idx = current.indexWhere(
        (item) => item.subscriptionId == summary.subscriptionId,
      );
      if (idx >= 0) {
        current[idx] = current[idx].coalesceWith(summary);
      } else {
        current.add(summary);
      }
      await _savePendingSummariesUnlocked(current);
    });
  }

  Future<List<SubscriptionSyncSummary>> consumePendingSubscriptionSummaries() {
    return _runSerialized(() async {
      final current = await _loadPendingSummariesUnlocked();
      if (current.isNotEmpty) {
        await _savePendingSummariesUnlocked(const <SubscriptionSyncSummary>[]);
      }
      return current;
    });
  }
}
