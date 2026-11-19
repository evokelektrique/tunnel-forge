import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/profiles_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/settings_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/tunnel_bloc.dart';
import 'package:tunnel_forge/features/profile_form/presentation/bloc/profile_form_bloc.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_contract.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_failure.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_runtime_state.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

class _InMemoryLogsRepository implements LogsRepository {
  final List<LogEntry> _entries = <LogEntry>[];

  @override
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  @override
  Stream<List<LogEntry>> get entriesStream => const Stream.empty();

  @override
  void append(LogEntry entry) => _entries.add(entry);

  @override
  void clear() => _entries.clear();

  @override
  Future<void> loadPersisted() async {}
}

class _StubTransferRepo implements ProfileTransferRepository {
  @override
  Stream<IncomingProfileTransfer> get incomingTransfers => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<List<IncomingProfileTransfer>> start() async => const [];
}

class _StubTunnelRepo implements TunnelRepository {
  @override
  Stream<TunnelHostUpdate> get tunnelStates => const Stream.empty();

  @override
  Stream<EngineLogMessage> get engineLogs => const Stream.empty();

  @override
  Stream<ProxyExposure> get proxyExposures => const Stream.empty();

  @override
  Stream<BatteryOptimizationStatus> get batteryOptimizationStatuses =>
      const Stream.empty();

  @override
  Stream<void> get quickSettingsConnectRequests => const Stream.empty();

  @override
  Future<bool> prepareVpn() async => true;

  @override
  Future<TunnelRuntimeState> getRuntimeState() async =>
      const TunnelRuntimeState(
        state: VpnTunnelState.stopped,
        connectionMode: ConnectionMode.vpnTunnel,
        detail: '',
        attemptId: '',
      );

  @override
  Future<void> syncQuickSettingsProfile(
    QuickSettingsProfileConfig? config,
  ) async {}

  @override
  Future<bool> consumePendingQuickSettingsConnect() async => false;

  @override
  Future<void> connect(TunnelConnectRequest request) async {}

  @override
  Future<void> disconnect({
    required ConnectionMode connectionMode,
    String attemptId = '',
  }) async {}

  @override
  Future<void> setLogLevel(LogDisplayLevel level) async {}

  @override
  Future<BatteryOptimizationStatus> getBatteryOptimizationStatus() async =>
      const BatteryOptimizationStatus(state: BatteryOptimizationState.allowed);

  @override
  Future<BatteryOptimizationRequestResult>
  requestIgnoreBatteryOptimizations() async =>
      const BatteryOptimizationRequestResult(
        outcome: BatteryOptimizationRequestOutcome.alreadyAllowed,
      );

  @override
  Future<BatteryOptimizationRequestResult>
  openBatteryOptimizationSettings() async =>
      const BatteryOptimizationRequestResult(
        outcome: BatteryOptimizationRequestOutcome.settingsOpened,
      );

  @override
  Future<BatteryOptimizationRequestResult>
  openManufacturerBackgroundSettings() async =>
      const BatteryOptimizationRequestResult(
        outcome: BatteryOptimizationRequestOutcome.settingsOpened,
      );

  @override
  Future<List<CandidateApp>> listVpnCandidateApps() async => const [];

  @override
  Future<Uint8List?> getAppIcon(String packageName) async => null;

  @override
  Future<bool?> checkProxyPortAvailable(
    int port, {
    required bool allowLanConnections,
  }) async => true;

  @override
  void dispose() {}
}

class _StubVersionRepo implements AppVersionRepository {
  @override
  Future<AppVersionInfo> loadInstalledVersion() async => const AppVersionInfo(
    displayVersion: '0.8.0+213',
    semanticVersion: SemanticVersion(major: 0, minor: 8, patch: 0),
  );
}

class _FailingUpdateRepo implements AppUpdateRepository {
  @override
  Future<AppReleaseInfo> fetchLatestRelease() async {
    throw const AppUpdateException(
      kind: AppUpdateErrorKind.http,
      statusCode: 503,
      userMessage: 'GitHub Releases returned HTTP 503.',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AppL10n.syncLocale(const Locale('en'));
  });

  test('ARB files have matching keys and placeholders across locales', () {
    final enRaw =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    final faRaw =
        jsonDecode(File('lib/l10n/app_fa.arb').readAsStringSync())
            as Map<String, dynamic>;

    final enKeys = enRaw.keys.where((key) => !key.startsWith('@')).toSet();
    final faKeys = faRaw.keys.where((key) => !key.startsWith('@')).toSet();

    expect(faKeys, enKeys);

    final placeholderPattern = RegExp(r'\{([a-zA-Z0-9_]+)(?:,|\})');
    for (final key in enKeys) {
      final enVal = enRaw[key] as String;
      final faVal = faRaw[key] as String;
      final enPlaceholders = placeholderPattern
          .allMatches(enVal)
          .map((m) => m.group(1)!)
          .toSet();
      final faPlaceholders = placeholderPattern
          .allMatches(faVal)
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        faPlaceholders,
        enPlaceholders,
        reason: 'Placeholder mismatch for key "$key"',
      );
    }

    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      expect(l10n.languageNativeName.trim(), isNotEmpty);
    }
  });

  test(
    'AppLanguageController resolves system default, migrates legacy prefs, and falls back safely',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final freshController = AppLanguageController(prefsOverride: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(freshController.locale, isNull);
      expect(
        AppLanguageController.resolveLocale(null, const [Locale('de', 'DE')]),
        const Locale('en'),
      );
      expect(
        AppLanguageController.resolveLocale(null, const [Locale('fa', 'IR')]),
        const Locale('fa'),
      );

      await freshController.setLocale(const Locale('fa'));
      expect(prefs.getString('app_language_v1'), 'fa');
      expect(AppL10n.current.localeName, 'fa');
      expect(
        AppLanguageController.textDirectionFor(const Locale('fa')),
        TextDirection.rtl,
      );
      expect(
        AppLanguageController.textDirectionFor(const Locale('en')),
        TextDirection.ltr,
      );

      await freshController.setLocale(null);
      expect(prefs.containsKey('app_language_v1'), isFalse);

      await prefs.setString('app_language_v1', 'en');
      final legacyEnController = AppLanguageController(prefsOverride: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(legacyEnController.locale, const Locale('en'));

      await prefs.setString('app_language_v1', 'xx_INVALID');
      final invalidController = AppLanguageController(prefsOverride: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(invalidController.locale, isNull);
    },
  );

  test(
    'logs remain strictly English when active UI locale is Persian',
    () async {
      SharedPreferences.setMockInitialValues({'app_language_v1': 'fa'});
      final prefs = await SharedPreferences.getInstance();
      final controller = AppLanguageController(prefsOverride: prefs);
      await Future<void>.delayed(Duration.zero);
      expect(AppL10n.current.localeName, 'fa');

      final logs = _InMemoryLogsRepository();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );
      final profilesRepo = ProfilesRepositoryImpl(store);
      final settingsRepo = SettingsRepositoryImpl(store);
      final tunnelRepo = _StubTunnelRepo();

      final profilesBloc = ProfilesBloc(
        profilesRepo,
        _StubTransferRepo(),
        logsRepository: logs,
      );
      final tunnelBloc = TunnelBloc(tunnelRepo, logs);
      final settingsBloc = SettingsBloc(
        settingsRepo,
        _StubVersionRepo(),
        _FailingUpdateRepo(),
        logs,
        tunnelRepo,
      );
      final formBloc = ProfileFormBloc(profilesRepo, logsRepository: logs);

      profilesBloc.add(const ProfilesStarted());
      tunnelBloc.add(const TunnelStarted());
      settingsBloc.add(const SettingsStarted());
      formBloc.add(const ProfileFormStarted(null));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      profilesBloc.add(const ProfilesSelectionChanged('missing-id'));
      profilesBloc.add(
        const ProfilesImportRequested(
          ImportTransferRequest(
            transfer: IncomingProfileTransfer(
              type: ProfileTransferContract.typeTfpJson,
              data: '{"v":999}',
              source: 'bad.tfp',
            ),
          ),
        ),
      );
      tunnelBloc.add(
        const TunnelConnectRequested(
          TunnelConnectRequest(
            activeProfileId: 'p1',
            profileName: 'Work',
            server: '',
            user: 'u',
            password: 'p',
            psk: 'k',
            dnsAutomatic: true,
            dnsServers: [],
            mtu: 1400,
            connectionMode: ConnectionMode.vpnTunnel,
            splitTunnelSettings: SplitTunnelSettings(),
            proxySettings: ProxySettings(),
          ),
        ),
      );
      tunnelBloc.add(
        const TunnelHostStateReceived(
          TunnelHostUpdate(
            state: VpnTunnelState.failed,
            detail: 'Authentication failed',
            failure: TunnelFailure(
              namespace: 'mschap',
              code: '691',
              detail: 'PPP failed',
            ),
          ),
        ),
      );
      settingsBloc.add(const SettingsVersionCheckConsentGranted());
      settingsBloc.add(
        const SettingsConnectivityCheckSettingsChanged(
          ConnectivityCheckSettings(
            url: 'ftp://invalid.local',
            timeoutMs: 1000,
          ),
        ),
      );
      formBloc.add(const ProfileFormServerChanged(''));
      formBloc.add(const ProfileFormSaveRequested());

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(logs.entries, isNotEmpty);
      final persianChars = RegExp(r'[\u0600-\u06FF]');
      for (final entry in logs.entries) {
        expect(
          persianChars.hasMatch(entry.message),
          isFalse,
          reason: 'Non-English text leaked into log entry: ${entry.message}',
        );
      }

      // UI error messages emitted while Persian is active ARE localized.
      expect(profilesBloc.state.message?.text, matches(persianChars));
      expect(formBloc.state.message, matches(persianChars));

      await profilesBloc.close();
      await tunnelBloc.close();
      await settingsBloc.close();
      await formBloc.close();
      controller.dispose();
    },
  );

  test(
    'TunnelFailure provides Persian UI text while keeping copyText strictly English',
    () {
      final fa = lookupAppLocalizations(const Locale('fa'));
      final persianChars = RegExp(r'[\u0600-\u06FF]');

      const samples = <TunnelFailure>[
        TunnelFailure(namespace: 'mschap', code: '691', detail: 'PPP failed'),
        TunnelFailure(namespace: 'mschap', code: '646'),
        TunnelFailure(namespace: 'chap', code: '4'),
        TunnelFailure(namespace: 'pap', code: '3'),
        TunnelFailure(namespace: 'l2tp-stopccn', code: '2', generalError: 8),
        TunnelFailure(namespace: 'l2tp-cdn', code: '1'),
        TunnelFailure(namespace: 'engine', code: '1'),
        TunnelFailure(namespace: 'android', code: '2'),
        TunnelFailure(namespace: 'app', code: 'UNKNOWN', detail: 'raw detail'),
      ];

      for (final failure in samples) {
        expect(failure.localizedLabel(fa), matches(persianChars));
        expect(failure.localizedExplanation(fa), matches(persianChars));
        expect(failure.copyText, isNot(matches(persianChars)));
        expect(failure.label, isNot(matches(persianChars)));
        expect(failure.explanation, isNot(matches(persianChars)));
      }
    },
  );
}
