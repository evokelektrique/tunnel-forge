import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/core/platform/app_info_bridge.dart';
import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_bridge.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_client.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_runtime_state.dart';
import '../domain/home_models.dart';
import '../domain/home_repositories.dart';

class ProfilesRepositoryImpl implements ProfilesRepository {
  ProfilesRepositoryImpl(this._profileStore);

  final ProfileStore _profileStore;

  @override
  Future<void> copyProfileShareLink(String id) async {
    final row = await _profileStore.loadProfileWithSecrets(id);
    if (row == null) {
      throw const ProfileRepositoryException('This profile no longer exists.');
    }
    if (row.secretsMissing) {
      throw const ProfileRepositoryException(
        'Saved password/PSK could not be read. Re-enter them before sharing.',
      );
    }
    final envelope = ProfileTransferEnvelope.fromProfile(
      profile: row.profile,
      password: row.password,
      psk: row.psk,
    );
    await Clipboard.setData(ClipboardData(text: envelope.toTfUri()));
  }

  @override
  Future<void> deleteProfile(String id) => _profileStore.deleteProfile(id);

  @override
  Future<void> exportProfileFile(String id) async {
    final row = await _profileStore.loadProfileWithSecrets(id);
    if (row == null) {
      throw const ProfileRepositoryException('This profile no longer exists.');
    }
    if (row.secretsMissing) {
      throw const ProfileRepositoryException(
        'Saved password/PSK could not be read. Re-enter them before sharing.',
      );
    }
    final envelope = ProfileTransferEnvelope.fromProfile(
      profile: row.profile,
      password: row.password,
      psk: row.psk,
    );
    final bytes = Uint8List.fromList(utf8.encode(envelope.toFileJson()));
    final fileName = ProfileTransferEnvelope.exportFileNameFor(row.profile);
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(bytes, mimeType: ProfileTransferEnvelope.mimeType),
        ],
        fileNameOverrides: [fileName],
        title: 'Export TunnelForge profile',
      ),
    );
  }

  @override
  Future<void> checkSecureStorageUpgrade() =>
      _profileStore.checkUpgradeStatusOnce();

  @override
  Future<void> resetSecureStorage() => _profileStore.resetSecureStorage();

  @override
  Future<String?> loadLastProfileId() => _profileStore.loadLastProfileId();

  @override
  Future<List<Profile>> loadProfiles() => _profileStore.loadProfiles();

  @override
  Future<ProfileSecretRow?> loadProfileWithSecrets(String id) async {
    final row = await _profileStore.loadProfileWithSecrets(id);
    if (row == null) return null;
    return ProfileSecretRow(
      profile: row.profile,
      password: row.password,
      psk: row.psk,
      secretsMissing: row.secretsMissing,
    );
  }

  @override
  String newProfileId() => ProfileStore.newProfileId();

  @override
  Future<Profile> saveImportedProfile(
    ProfileTransferEnvelope envelope, {
    bool selectAsLastProfile = true,
  }) {
    return _profileStore.saveImportedProfile(
      envelope,
      selectAsLastProfile: selectAsLastProfile,
    );
  }

  @override
  Future<void> setLastProfileId(String? id) =>
      _profileStore.setLastProfileId(id);

  @override
  Future<void> upsertProfile(
    Profile profile, {
    required String password,
    required String psk,
  }) {
    return _profileStore.upsertProfile(profile, password: password, psk: psk);
  }
}

class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl(this._profileStore);

  final ProfileStore _profileStore;

  @override
  Future<ConnectionMode> loadConnectionMode() {
    return _profileStore.loadConnectionMode();
  }

  @override
  Future<ConnectivityCheckSettings> loadConnectivityCheckSettings() {
    return _profileStore.loadConnectivityCheckSettings();
  }

  @override
  Future<LogDisplayLevel> loadLogDisplayLevel() {
    return _profileStore.loadLogDisplayLevel();
  }

  @override
  Future<bool> loadBatteryOptimizationConnectPromptShown() {
    return _profileStore.loadBatteryOptimizationConnectPromptShown();
  }

  @override
  Future<bool> loadUpdateCheckConsentGranted() {
    return _profileStore.loadUpdateCheckConsentGranted();
  }

  @override
  Future<ProxySettings> loadProxySettings() {
    return _profileStore.loadProxySettings();
  }

  @override
  Future<SplitTunnelSettings> loadSplitTunnelSettings() {
    return _profileStore.loadSplitTunnelSettings();
  }

  @override
  Future<void> saveConnectionMode(ConnectionMode mode) {
    return _profileStore.saveConnectionMode(mode);
  }

  @override
  Future<void> saveConnectivityCheckSettings(
    ConnectivityCheckSettings settings,
  ) {
    return _profileStore.saveConnectivityCheckSettings(settings);
  }

  @override
  Future<void> saveLogDisplayLevel(LogDisplayLevel level) {
    return _profileStore.saveLogDisplayLevel(level);
  }

  @override
  Future<void> saveBatteryOptimizationConnectPromptShown(bool shown) {
    return _profileStore.saveBatteryOptimizationConnectPromptShown(shown);
  }

  @override
  Future<void> saveUpdateCheckConsentGranted(bool granted) {
    return _profileStore.saveUpdateCheckConsentGranted(granted);
  }

  @override
  Future<void> saveProxySettings(ProxySettings settings) {
    return _profileStore.saveProxySettings(settings);
  }

  @override
  Future<void> saveSplitTunnelSettings(SplitTunnelSettings settings) {
    return _profileStore.saveSplitTunnelSettings(settings);
  }
}

class AppVersionRepositoryImpl implements AppVersionRepository {
  AppVersionRepositoryImpl({
    Future<PackageInfo> Function()? packageInfoLoader,
    Future<({String? versionName, String? buildNumber})> Function()?
    nativeVersionLoader,
  }) : _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _nativeVersionLoader =
           nativeVersionLoader ?? AppInfoBridge().loadInstalledVersion;

  final Future<PackageInfo> Function() _packageInfoLoader;
  final Future<({String? versionName, String? buildNumber})> Function()
  _nativeVersionLoader;

  @override
  Future<AppVersionInfo> loadInstalledVersion() async {
    Object? packageInfoError;
    try {
      final info = await _packageInfoLoader();
      final displayVersion = _displayVersion(
        versionName: info.version,
        buildNumber: info.buildNumber,
      );
      if (displayVersion != null) {
        return AppVersionInfo(
          displayVersion: displayVersion,
          semanticVersion: SemanticVersion.tryParse(displayVersion),
        );
      }
      packageInfoError = const FormatException(
        'package_info_plus returned an empty version.',
      );
    } catch (error) {
      packageInfoError = error;
    }

    try {
      final native = await _nativeVersionLoader();
      final displayVersion = _displayVersion(
        versionName: native.versionName,
        buildNumber: native.buildNumber,
      );
      if (displayVersion != null) {
        return AppVersionInfo(
          displayVersion: displayVersion,
          semanticVersion: SemanticVersion.tryParse(displayVersion),
        );
      }
      return AppVersionInfo(
        semanticVersion: null,
        errorReason:
            'Installed version unavailable. Native version lookup returned empty values.',
      );
    } catch (nativeError) {
      return AppVersionInfo(
        semanticVersion: null,
        errorReason: _versionErrorReason(packageInfoError, nativeError),
      );
    }
  }

  static String? _displayVersion({
    required String? versionName,
    required String? buildNumber,
  }) {
    final version = versionName?.trim() ?? '';
    final build = buildNumber?.trim() ?? '';
    return switch ((version.isEmpty, build.isEmpty)) {
      (false, false) => '$version+$build',
      (false, true) => version,
      (true, false) => build,
      _ => null,
    };
  }

  static String _versionErrorReason(
    Object? packageInfoError,
    Object nativeError,
  ) {
    final packageInfoMessage = packageInfoError == null
        ? 'package_info_plus reason unavailable'
        : packageInfoError.toString();
    return 'Installed version unavailable. package_info_plus failed: $packageInfoMessage. Native fallback failed: ${nativeError.toString()}.';
  }
}

class AppUpdateRepositoryImpl implements AppUpdateRepository {
  AppUpdateRepositoryImpl({
    Future<String> Function(Uri uri)? fetcher,
    this.owner = 'evokelektrique',
    this.repo = 'tunnel-forge',
  }) : _fetcher = fetcher ?? _fetchJson;

  final Future<String> Function(Uri uri) _fetcher;
  final String owner;
  final String repo;

  @override
  Future<AppReleaseInfo> fetchLatestRelease() async {
    final uri = Uri.https('api.github.com', '/repos/$owner/$repo/releases');
    final body = await _fetcher(uri);
    final Object decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException catch (error) {
      throw AppUpdateException(
        kind: AppUpdateErrorKind.response,
        userMessage: 'GitHub Releases returned malformed data.',
        details: error.message,
      );
    }
    if (decoded is! List) {
      throw const AppUpdateException(
        kind: AppUpdateErrorKind.response,
        userMessage: 'GitHub Releases returned malformed data.',
        details: 'Expected a GitHub releases list.',
      );
    }

    final releases =
        decoded
            .whereType<Map>()
            .map((entry) => _parseRelease(Map<String, dynamic>.from(entry)))
            .whereType<AppReleaseInfo>()
            .toList()
          ..sort(
            (left, right) => right.publishedAt.compareTo(left.publishedAt),
          );

    if (releases.isEmpty) {
      throw const AppUpdateException(
        kind: AppUpdateErrorKind.response,
        userMessage: 'GitHub Releases returned no usable releases.',
        details: 'No valid published releases were found.',
      );
    }

    return releases.first;
  }

  AppReleaseInfo? _parseRelease(Map<String, dynamic> json) {
    if (json['draft'] == true) return null;

    final publishedAtValue = json['published_at'] as String?;
    final htmlUrl = json['html_url'] as String?;
    final tagName = json['tag_name'] as String?;
    if (publishedAtValue == null || htmlUrl == null || tagName == null) {
      return null;
    }

    final publishedAt = DateTime.tryParse(publishedAtValue);
    final version = SemanticVersion.tryParse(tagName);
    if (publishedAt == null || version == null) return null;

    return AppReleaseInfo(
      version: version,
      htmlUrl: htmlUrl,
      publishedAt: publishedAt,
      prerelease: json['prerelease'] == true,
    );
  }

  static Future<String> _fetchJson(Uri uri) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.set(HttpHeaders.userAgentHeader, 'TunnelForgeApp/1.0');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AppUpdateException(
          kind: AppUpdateErrorKind.http,
          userMessage: 'GitHub Releases returned HTTP ${response.statusCode}.',
          statusCode: response.statusCode,
          details: body.isEmpty ? null : body,
        );
      }
      return body;
    } on TimeoutException {
      throw const AppUpdateException(
        kind: AppUpdateErrorKind.timeout,
        userMessage: 'GitHub Releases request timed out.',
      );
    } on HandshakeException catch (error) {
      throw AppUpdateException(
        kind: AppUpdateErrorKind.tls,
        userMessage: 'Secure connection to GitHub Releases failed.',
        details: error.message,
      );
    } on SocketException catch (error) {
      throw AppUpdateException(
        kind: AppUpdateErrorKind.network,
        userMessage: 'Network error while contacting GitHub Releases.',
        details: error.message,
      );
    } on AppUpdateException {
      rethrow;
    } on FormatException catch (error) {
      throw AppUpdateException(
        kind: AppUpdateErrorKind.response,
        userMessage: 'GitHub Releases returned malformed data.',
        details: error.message,
      );
    } catch (error) {
      throw AppUpdateException(
        kind: AppUpdateErrorKind.unknown,
        userMessage: 'Unexpected error while checking GitHub Releases.',
        details: error.toString(),
      );
    } finally {
      client.close(force: true);
    }
  }
}

class TunnelRepositoryImpl implements TunnelRepository {
  TunnelRepositoryImpl({VpnClient? client}) {
    _client =
        client ??
        VpnClient(
          onTunnelState: (state, detail, attemptId, failure) {
            _tunnelStateController.add(
              TunnelHostUpdate(
                failure: failure,
                state: state,
                detail: detail,
                attemptId: attemptId,
              ),
            );
          },
          onEngineLog: (level, source, tag, message) {
            _engineLogController.add(
              EngineLogMessage(
                timestamp: DateTime.now(),
                level: level,
                source: source,
                tag: tag,
                message: message,
              ),
            );
          },
          onProxyExposureChanged: (exposure) {
            _proxyExposureController.add(exposure);
          },
          onBatteryOptimizationStatusChanged: (status) {
            _batteryOptimizationStatusController.add(status);
          },
        );
  }

  late final VpnClient _client;
  final StreamController<TunnelHostUpdate> _tunnelStateController =
      StreamController<TunnelHostUpdate>.broadcast();
  final StreamController<EngineLogMessage> _engineLogController =
      StreamController<EngineLogMessage>.broadcast();
  final StreamController<ProxyExposure> _proxyExposureController =
      StreamController<ProxyExposure>.broadcast();
  final StreamController<BatteryOptimizationStatus>
  _batteryOptimizationStatusController =
      StreamController<BatteryOptimizationStatus>.broadcast();

  @override
  Stream<EngineLogMessage> get engineLogs => _engineLogController.stream;

  @override
  Stream<ProxyExposure> get proxyExposures => _proxyExposureController.stream;

  @override
  Stream<BatteryOptimizationStatus> get batteryOptimizationStatuses =>
      _batteryOptimizationStatusController.stream;

  @override
  Stream<TunnelHostUpdate> get tunnelStates => _tunnelStateController.stream;

  @override
  Future<TunnelRuntimeState> getRuntimeState() => _client.getRuntimeState();

  @override
  Future<BatteryOptimizationStatus> getBatteryOptimizationStatus() {
    return _client.getBatteryOptimizationStatus();
  }

  @override
  Future<void> connect(TunnelConnectRequest request) {
    return _client.connect(
      attemptId: request.attemptId,
      server: request.server,
      profileName: request.profileName,
      connectionMode: request.connectionMode,
      user: request.user,
      password: request.password,
      psk: request.psk,
      dnsAutomatic: request.dnsAutomatic,
      dnsServers: request.dnsServers,
      mtu: request.mtu,
      splitTunnelSettings: request.splitTunnelSettings,
      proxySettings: request.proxySettings,
    );
  }

  @override
  Future<void> disconnect({
    required ConnectionMode connectionMode,
    String attemptId = '',
  }) {
    return _client.disconnect(
      connectionMode: connectionMode,
      attemptId: attemptId,
    );
  }

  @override
  void dispose() {
    _client.dispose();
    unawaited(_tunnelStateController.close());
    unawaited(_engineLogController.close());
    unawaited(_proxyExposureController.close());
    unawaited(_batteryOptimizationStatusController.close());
  }

  @override
  Future<Uint8List?> getAppIcon(String packageName) {
    return _client.getAppIcon(packageName);
  }

  @override
  Future<List<CandidateApp>> listVpnCandidateApps() {
    return _client.listVpnCandidateApps();
  }

  @override
  Future<BatteryOptimizationRequestResult> openBatteryOptimizationSettings() {
    return _client.openBatteryOptimizationSettings();
  }

  @override
  Future<BatteryOptimizationRequestResult>
  openManufacturerBackgroundSettings() {
    return _client.openManufacturerBackgroundSettings();
  }

  @override
  Future<bool> prepareVpn() => _client.prepareVpn();

  @override
  Future<BatteryOptimizationRequestResult> requestIgnoreBatteryOptimizations() {
    return _client.requestIgnoreBatteryOptimizations();
  }

  @override
  Future<void> setLogLevel(LogDisplayLevel level) {
    return _client.setLogLevel(level);
  }
}

class ConnectivityRepositoryImpl implements ConnectivityRepository {
  ConnectivityRepositoryImpl(this._checker);

  final ConnectivityChecker _checker;

  @override
  Future<ConnectivityPingResult> ping(
    ConnectivityPingRequest request, {
    Future<void>? cancelSignal,
  }) => _checker.ping(request, cancelSignal: cancelSignal);
}

class ProfileTransferRepositoryImpl implements ProfileTransferRepository {
  ProfileTransferRepositoryImpl({ProfileTransferBridge? bridge})
    : _bridge = bridge ?? ProfileTransferBridge();

  final ProfileTransferBridge _bridge;

  @override
  Stream<IncomingProfileTransfer> get incomingTransfers =>
      _bridge.incomingTransfers;

  @override
  Future<void> dispose() => _bridge.dispose();

  @override
  Future<List<IncomingProfileTransfer>> start() => _bridge.start();
}

class LogsRepositoryImpl implements LogsRepository {
  LogsRepositoryImpl({
    SharedPreferences? prefsOverride,
    DiagnosticsBridge? bridgeOverride,
  }) : _prefsOverride = prefsOverride,
       _bridgeOverride = bridgeOverride;

  static const String prefsKeyLogsJson = 'logs_entries_json_v1';
  static const int _maxLines = 5000;
  static const int _maxLegacyBlobBytes = 256 * 1024;
  static const Duration _flushInterval = Duration(milliseconds: 200);
  static final RegExp _lineHeaderPattern = RegExp(
    r'^(\S+) (DEBUG|INFO|WARNING|ERROR) (dart|kotlin|native)/(\S*) (.*)$',
  );

  final SharedPreferences? _prefsOverride;
  final DiagnosticsBridge? _bridgeOverride;
  final ListQueue<LogEntry> _entries = ListQueue<LogEntry>();
  final List<LogEntry> _pendingBridgeWrites = <LogEntry>[];
  final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();
  List<LogEntry>? _entriesCache;
  Timer? _flushTimer;
  bool _hasPendingEmit = false;
  bool _loaded = false;

  DiagnosticsBridge get _bridge =>
      _bridgeOverride ?? DiagnosticsBridge.instance;

  @override
  List<LogEntry> get entries =>
      _entriesCache ??= List<LogEntry>.unmodifiable(_entries);

  @override
  Stream<List<LogEntry>> get entriesStream => _controller.stream;

  @override
  Future<void> loadPersisted() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await _prefs();
    final legacyRaw = prefs.getString(prefsKeyLogsJson);
    if (legacyRaw != null) {
      await _migrateLegacyLogs(prefs, legacyRaw);
    }

    final tail = await _bridge.readLogTail(maxLines: _maxLines);
    final loaded = _parseTail(tail);
    if (loaded.isEmpty && _entries.isEmpty) return;

    final currentSessionEntries = List<LogEntry>.from(_entries);
    _entries.clear();
    final merged = <LogEntry>[...loaded, ...currentSessionEntries];
    final start = merged.length > _maxLines ? merged.length - _maxLines : 0;
    for (var i = start; i < merged.length; i++) {
      _entries.addLast(merged[i]);
    }
    _entriesCache = null;
    if (!_controller.isClosed) {
      _controller.add(entries);
    }
  }

  @override
  void append(LogEntry entry) {
    _entries.addLast(entry);
    while (_entries.length > _maxLines) {
      _entries.removeFirst();
    }
    _entriesCache = null;
    _hasPendingEmit = true;
    if (entry.source == LogSource.dart) {
      _pendingBridgeWrites.add(entry);
    }
    _flushTimer ??= Timer(_flushInterval, _flush);
  }

  @override
  void clear() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingBridgeWrites.clear();
    _hasPendingEmit = false;
    _entries.clear();
    _entriesCache = const <LogEntry>[];
    if (!_controller.isClosed) {
      _controller.add(entries);
    }
    unawaited(_clearBackingStores());
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _pendingBridgeWrites.clear();
    _hasPendingEmit = false;
    await _controller.close();
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_hasPendingEmit) {
      _hasPendingEmit = false;
      if (!_controller.isClosed) {
        _controller.add(entries);
      }
    }
    if (_pendingBridgeWrites.isNotEmpty) {
      final batch = List<LogEntry>.from(_pendingBridgeWrites);
      _pendingBridgeWrites.clear();
      unawaited(_sendBridgeBatchSafely(batch));
    }
  }

  Future<void> _sendBridgeBatchSafely(List<LogEntry> batch) async {
    try {
      await _bridge.appendLogs(_serializeBridgeBatch(batch));
    } catch (_) {
      // File logging stays best-effort so UI and app startup never fail on diagnostics I/O.
    }
  }

  List<Map<String, Object?>> _serializeBridgeBatch(List<LogEntry> batch) =>
      batch
          .map(
            (entry) => <String, Object?>{
              DiagnosticsContract.argTs: entry.timestamp.millisecondsSinceEpoch,
              DiagnosticsContract.argLevel: entry.level.name,
              DiagnosticsContract.argSource: entry.source.label,
              DiagnosticsContract.argTag: entry.tag,
              DiagnosticsContract.argMessage: entry.message,
            },
          )
          .toList(growable: false);

  Future<void> _migrateLegacyLogs(
    SharedPreferences prefs,
    String legacyRaw,
  ) async {
    if (legacyRaw.trim().isEmpty) {
      await prefs.remove(prefsKeyLogsJson);
      return;
    }
    final migrated = _parseLegacyMigrationEntries(legacyRaw);
    try {
      await _bridge.appendLogs(_serializeBridgeBatch(migrated));
      await prefs.remove(prefsKeyLogsJson);
    } catch (_) {
      // Keep the legacy blob intact when migration to the log file fails.
    }
  }

  List<LogEntry> _parseLegacyMigrationEntries(String legacyRaw) {
    try {
      final decoded = jsonDecode(legacyRaw);
      if (decoded is List) {
        final entries = decoded
            .map(_entryFromJson)
            .whereType<LogEntry>()
            .toList(growable: false);
        if (entries.isNotEmpty || decoded.isEmpty) {
          return entries;
        }
      }
    } catch (_) {
      // Preserve corrupt legacy blobs verbatim in a capped entry instead of dropping them.
    }
    return <LogEntry>[
      LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.warning,
        source: LogSource.dart,
        tag: 'LogsMigration',
        message: 'legacy log blob (unparsed): ${_capUtf8Bytes(legacyRaw)}',
      ),
    ];
  }

  String _capUtf8Bytes(String text) {
    final bytes = utf8.encode(text);
    if (bytes.length <= _maxLegacyBlobBytes) return text;
    return utf8.decode(
      bytes.sublist(0, _maxLegacyBlobBytes),
      allowMalformed: true,
    );
  }

  List<LogEntry> _parseTail(String tail) {
    if (tail.isEmpty) return const <LogEntry>[];
    final entries = <LogEntry>[];
    final lines = const LineSplitter().convert(tail);
    for (final line in lines) {
      if (line.isEmpty) continue;
      if (line.startsWith('\t') && entries.isNotEmpty) {
        final prev = entries.removeLast();
        entries.add(
          LogEntry(
            timestamp: prev.timestamp,
            level: prev.level,
            source: prev.source,
            tag: prev.tag,
            message: '${prev.message}\n${line.substring(1)}',
          ),
        );
        continue;
      }
      final match = _lineHeaderPattern.firstMatch(line);
      final parsedTs = match == null
          ? null
          : DateTime.tryParse(match.group(1)!);
      if (match != null && parsedTs != null) {
        entries.add(
          LogEntry(
            timestamp: parsedTs.toLocal(),
            level: _logLevelFromStorage(match.group(2)),
            source: LogSource.parse(match.group(3)),
            tag: match.group(4) ?? '',
            message: match.group(5) ?? '',
          ),
        );
      } else {
        entries.add(
          LogEntry(
            timestamp: DateTime.now(),
            level: LogLevel.info,
            source: LogSource.kotlin,
            tag: 'DiagnosticLog',
            message: line,
          ),
        );
      }
    }
    if (entries.length <= _maxLines) return entries;
    return entries.sublist(entries.length - _maxLines);
  }

  Future<void> _clearBackingStores() async {
    try {
      await _bridge.clearLogs();
    } catch (_) {}
    try {
      final prefs = await _prefs();
      await prefs.remove(prefsKeyLogsJson);
    } catch (_) {}
  }

  Future<SharedPreferences> _prefs() async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  LogEntry? _entryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final timestamp = DateTime.tryParse(raw['timestamp']?.toString() ?? '');
    if (timestamp == null) return null;
    return LogEntry(
      timestamp: timestamp,
      level: _logLevelFromStorage(raw['level']),
      source: LogSource.parse(raw['source']?.toString()),
      tag: raw['tag']?.toString() ?? '',
      message: raw['message']?.toString() ?? '',
    );
  }

  LogLevel _logLevelFromStorage(Object? raw) {
    return switch (raw?.toString().trim().toLowerCase()) {
      'debug' => LogLevel.debug,
      'info' => LogLevel.info,
      'warning' || 'warn' => LogLevel.warning,
      'error' => LogLevel.error,
      _ => LogLevel.info,
    };
  }
}

class ProfileRepositoryException implements Exception {
  const ProfileRepositoryException(this.message);

  final String message;
}
