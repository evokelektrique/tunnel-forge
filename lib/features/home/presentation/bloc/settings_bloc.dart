import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import '../../domain/home_models.dart';
import '../../../home/domain/home_repositories.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

sealed class SettingsEvent extends Equatable {
  const SettingsEvent();

  @override
  List<Object?> get props => const [];
}

final class SettingsStarted extends SettingsEvent {
  const SettingsStarted();
}

final class SettingsConnectionModeChanged extends SettingsEvent {
  const SettingsConnectionModeChanged(this.mode);

  final ConnectionMode mode;

  @override
  List<Object?> get props => [mode];
}

final class SettingsSplitTunnelSettingsChanged extends SettingsEvent {
  const SettingsSplitTunnelSettingsChanged(this.settings);

  final SplitTunnelSettings settings;

  @override
  List<Object?> get props => [settings];
}

final class SettingsVersionCheckRequested extends SettingsEvent {
  const SettingsVersionCheckRequested();
}

final class SettingsVersionCheckConsentGranted extends SettingsEvent {
  const SettingsVersionCheckConsentGranted();
}

final class SettingsBatteryOptimizationRefreshRequested extends SettingsEvent {
  const SettingsBatteryOptimizationRefreshRequested();
}

final class SettingsBatteryOptimizationStatusChanged extends SettingsEvent {
  const SettingsBatteryOptimizationStatusChanged(this.status);

  final BatteryOptimizationStatus status;

  @override
  List<Object?> get props => [status];
}

final class SettingsBatteryOptimizationRequestPressed extends SettingsEvent {
  const SettingsBatteryOptimizationRequestPressed();
}

final class SettingsBatteryOptimizationVpnConnectAttempted
    extends SettingsEvent {
  const SettingsBatteryOptimizationVpnConnectAttempted();
}

final class SettingsBatteryOptimizationSettingsPressed extends SettingsEvent {
  const SettingsBatteryOptimizationSettingsPressed();
}

final class SettingsManufacturerBackgroundSettingsPressed
    extends SettingsEvent {
  const SettingsManufacturerBackgroundSettingsPressed();
}

final class SettingsProxySettingsChanged extends SettingsEvent {
  const SettingsProxySettingsChanged(this.settings);

  final ProxySettings settings;

  @override
  List<Object?> get props => [settings];
}

final class SettingsConnectivityCheckSettingsChanged extends SettingsEvent {
  const SettingsConnectivityCheckSettingsChanged(this.settings);

  final ConnectivityCheckSettings settings;

  @override
  List<Object?> get props => [settings];
}

final class SettingsConnectionHapticsChanged extends SettingsEvent {
  const SettingsConnectionHapticsChanged(this.enabled);

  final bool enabled;

  @override
  List<Object?> get props => [enabled];
}

class SettingsState extends Equatable {
  const SettingsState({
    this.loading = true,
    this.installedVersionLoaded = false,
    this.connectionMode = ConnectionMode.vpnTunnel,
    this.splitTunnelSettings = const SplitTunnelSettings(),
    this.proxySettings = const ProxySettings(),
    this.connectivityCheckSettings = const ConnectivityCheckSettings(),
    this.connectionHapticsEnabled = true,
    this.connectivityUrlError,
    this.installedVersion,
    this.installedVersionError,
    this.installedSemanticVersion,
    this.updateCheckConsentGranted = false,
    this.appUpdateStatus = AppUpdateStatus.idle,
    this.latestReleaseVersion,
    this.latestReleaseUrl,
    this.updateErrorMessage,
    this.updateErrorKind,
    this.updateErrorStatusCode,
    this.batteryOptimizationStatus = const BatteryOptimizationStatus.unknown(),
    this.batteryOptimizationBusy = false,
    this.message,
  });

  final bool loading;
  final bool installedVersionLoaded;
  final ConnectionMode connectionMode;
  final SplitTunnelSettings splitTunnelSettings;
  final ProxySettings proxySettings;
  final ConnectivityCheckSettings connectivityCheckSettings;
  final bool connectionHapticsEnabled;
  final String? connectivityUrlError;
  final String? installedVersion;
  final String? installedVersionError;
  final SemanticVersion? installedSemanticVersion;
  final bool updateCheckConsentGranted;
  final AppUpdateStatus appUpdateStatus;
  final String? latestReleaseVersion;
  final String? latestReleaseUrl;
  final String? updateErrorMessage;
  final AppUpdateErrorKind? updateErrorKind;
  final int? updateErrorStatusCode;
  final BatteryOptimizationStatus batteryOptimizationStatus;
  final bool batteryOptimizationBusy;
  final HomeMessage? message;

  SettingsState copyWith({
    bool? loading,
    bool? installedVersionLoaded,
    ConnectionMode? connectionMode,
    SplitTunnelSettings? splitTunnelSettings,
    ProxySettings? proxySettings,
    ConnectivityCheckSettings? connectivityCheckSettings,
    bool? connectionHapticsEnabled,
    String? connectivityUrlError,
    bool clearConnectivityUrlError = false,
    String? installedVersion,
    String? installedVersionError,
    bool clearInstalledVersionError = false,
    SemanticVersion? installedSemanticVersion,
    bool preserveInstalledSemanticVersion = true,
    bool? updateCheckConsentGranted,
    AppUpdateStatus? appUpdateStatus,
    String? latestReleaseVersion,
    String? latestReleaseUrl,
    String? updateErrorMessage,
    AppUpdateErrorKind? updateErrorKind,
    int? updateErrorStatusCode,
    bool clearUpdateErrorMessage = false,
    BatteryOptimizationStatus? batteryOptimizationStatus,
    bool? batteryOptimizationBusy,
    HomeMessage? message,
    bool clearMessage = false,
  }) {
    return SettingsState(
      loading: loading ?? this.loading,
      installedVersionLoaded:
          installedVersionLoaded ?? this.installedVersionLoaded,
      connectionMode: connectionMode ?? this.connectionMode,
      splitTunnelSettings: splitTunnelSettings ?? this.splitTunnelSettings,
      proxySettings: proxySettings ?? this.proxySettings,
      connectivityCheckSettings:
          connectivityCheckSettings ?? this.connectivityCheckSettings,
      connectionHapticsEnabled:
          connectionHapticsEnabled ?? this.connectionHapticsEnabled,
      connectivityUrlError: clearConnectivityUrlError
          ? null
          : (connectivityUrlError ?? this.connectivityUrlError),
      installedVersion: installedVersion ?? this.installedVersion,
      installedVersionError: clearInstalledVersionError
          ? null
          : (installedVersionError ?? this.installedVersionError),
      installedSemanticVersion: preserveInstalledSemanticVersion
          ? (installedSemanticVersion ?? this.installedSemanticVersion)
          : installedSemanticVersion,
      updateCheckConsentGranted:
          updateCheckConsentGranted ?? this.updateCheckConsentGranted,
      appUpdateStatus: appUpdateStatus ?? this.appUpdateStatus,
      latestReleaseVersion: latestReleaseVersion ?? this.latestReleaseVersion,
      latestReleaseUrl: latestReleaseUrl ?? this.latestReleaseUrl,
      updateErrorMessage: clearUpdateErrorMessage
          ? null
          : (updateErrorMessage ?? this.updateErrorMessage),
      updateErrorKind: clearUpdateErrorMessage
          ? null
          : (updateErrorKind ?? this.updateErrorKind),
      updateErrorStatusCode: clearUpdateErrorMessage
          ? null
          : (updateErrorStatusCode ?? this.updateErrorStatusCode),
      batteryOptimizationStatus:
          batteryOptimizationStatus ?? this.batteryOptimizationStatus,
      batteryOptimizationBusy:
          batteryOptimizationBusy ?? this.batteryOptimizationBusy,
      message: clearMessage ? null : (message ?? this.message),
    );
  }

  @override
  List<Object?> get props => [
    loading,
    installedVersionLoaded,
    connectionMode,
    splitTunnelSettings,
    proxySettings,
    connectivityCheckSettings,
    connectionHapticsEnabled,
    connectivityUrlError,
    installedVersion,
    installedVersionError,
    installedSemanticVersion,
    updateCheckConsentGranted,
    appUpdateStatus,
    latestReleaseVersion,
    latestReleaseUrl,
    updateErrorMessage,
    updateErrorKind,
    updateErrorStatusCode,
    batteryOptimizationStatus,
    batteryOptimizationBusy,
    message,
  ];
}

class SettingsBloc extends Bloc<SettingsEvent, SettingsState> {
  SettingsBloc(
    this._settingsRepository,
    this._appVersionRepository,
    this._appUpdateRepository,
    this._logsRepository,
    this._tunnelRepository,
  ) : super(const SettingsState()) {
    on<SettingsStarted>(_onStarted);
    on<SettingsConnectionModeChanged>(_onConnectionModeChanged);
    on<SettingsSplitTunnelSettingsChanged>(_onSplitTunnelSettingsChanged);
    on<SettingsProxySettingsChanged>(_onProxySettingsChanged);
    on<SettingsConnectivityCheckSettingsChanged>(
      _onConnectivityCheckSettingsChanged,
    );
    on<SettingsConnectionHapticsChanged>(_onConnectionHapticsChanged);
    on<SettingsVersionCheckRequested>(_onVersionCheckRequested);
    on<SettingsVersionCheckConsentGranted>(_onVersionCheckConsentGranted);
    on<SettingsBatteryOptimizationRefreshRequested>(
      _onBatteryOptimizationRefreshRequested,
    );
    on<SettingsBatteryOptimizationStatusChanged>(
      _onBatteryOptimizationStatusChanged,
    );
    on<SettingsBatteryOptimizationRequestPressed>(
      _onBatteryOptimizationRequestPressed,
    );
    on<SettingsBatteryOptimizationVpnConnectAttempted>(
      _onBatteryOptimizationVpnConnectAttempted,
    );
    on<SettingsBatteryOptimizationSettingsPressed>(
      _onBatteryOptimizationSettingsPressed,
    );
    on<SettingsManufacturerBackgroundSettingsPressed>(
      _onManufacturerBackgroundSettingsPressed,
    );
    _batteryStatusSubscription = _tunnelRepository.batteryOptimizationStatuses
        .listen((status) {
          if (!isClosed) {
            add(SettingsBatteryOptimizationStatusChanged(status));
          }
        });
  }

  final SettingsRepository _settingsRepository;
  final AppVersionRepository _appVersionRepository;
  final AppUpdateRepository _appUpdateRepository;
  final LogsRepository _logsRepository;
  final TunnelRepository _tunnelRepository;
  StreamSubscription<BatteryOptimizationStatus>? _batteryStatusSubscription;
  int _messageId = 0;
  bool _batteryOptimizationConnectPromptInFlight = false;
  bool _batteryRefreshInFlight = false;
  bool _batteryRefreshQueued = false;
  bool _batteryUnrestrictedLoggedThisSession = false;
  bool _pendingExternalBatterySettingsLog = false;
  final Map<String, Timer> _debouncedLogTimers = <String, Timer>{};

  @override
  Future<void> close() async {
    for (final timer in _debouncedLogTimers.values) {
      timer.cancel();
    }
    _debouncedLogTimers.clear();
    await _batteryStatusSubscription?.cancel();
    return super.close();
  }

  void _scheduleDebouncedDebugLog(String key, String tag, String message) {
    _debouncedLogTimers.remove(key)?.cancel();
    _debouncedLogTimers[key] = Timer(const Duration(milliseconds: 500), () {
      _debouncedLogTimers.remove(key);
      if (!isClosed) {
        _appendLog(LogLevel.debug, message, tag: tag);
      }
    });
  }

  Future<void> _onStarted(
    SettingsStarted event,
    Emitter<SettingsState> emit,
  ) async {
    final connectionModeFuture = _settingsRepository.loadConnectionMode();
    final splitTunnelSettingsFuture = _settingsRepository
        .loadSplitTunnelSettings();
    final proxySettingsFuture = _settingsRepository.loadProxySettings();
    final connectivityCheckSettingsFuture = _settingsRepository
        .loadConnectivityCheckSettings();
    final connectionHapticsEnabledFuture = _settingsRepository
        .loadConnectionHapticsEnabled();
    final installedVersionFuture = _appVersionRepository.loadInstalledVersion();
    final batteryOptimizationStatusFuture = _tunnelRepository
        .getBatteryOptimizationStatus();
    final updateCheckConsentFuture = _settingsRepository
        .loadUpdateCheckConsentGranted();

    final connectionMode = await connectionModeFuture;
    final splitTunnelSettings = await splitTunnelSettingsFuture;
    final proxySettings = await proxySettingsFuture;
    final connectivityCheckSettings = await connectivityCheckSettingsFuture;
    final connectionHapticsEnabled = await connectionHapticsEnabledFuture;
    final batteryOptimizationStatus = await batteryOptimizationStatusFuture;
    final updateCheckConsentGranted = await updateCheckConsentFuture;

    emit(
      state.copyWith(
        loading: false,
        connectionMode: connectionMode,
        splitTunnelSettings: splitTunnelSettings,
        proxySettings: proxySettings,
        connectivityCheckSettings: connectivityCheckSettings,
        connectionHapticsEnabled: connectionHapticsEnabled,
        batteryOptimizationStatus: batteryOptimizationStatus,
        updateCheckConsentGranted: updateCheckConsentGranted,
        clearConnectivityUrlError: true,
        clearUpdateErrorMessage: true,
      ),
    );

    final installedVersion = await installedVersionFuture;
    if (installedVersion.errorReason != null) {
      _appendLog(LogLevel.warning, 'version: ${installedVersion.errorReason!}');
    }
    emit(
      state.copyWith(
        installedVersion: installedVersion.displayVersion,
        installedVersionError: installedVersion.errorReason,
        clearInstalledVersionError: installedVersion.errorReason == null,
        installedSemanticVersion: installedVersion.semanticVersion,
        preserveInstalledSemanticVersion: false,
        installedVersionLoaded: true,
      ),
    );
  }

  Future<void> _onBatteryOptimizationRefreshRequested(
    SettingsBatteryOptimizationRefreshRequested event,
    Emitter<SettingsState> emit,
  ) async {
    if (_batteryRefreshInFlight || state.batteryOptimizationBusy) {
      _batteryRefreshQueued = true;
      return;
    }
    _batteryRefreshInFlight = true;
    try {
      final status = await _tunnelRepository.getBatteryOptimizationStatus();
      _applyBatteryOptimizationStatus(status, emit: emit);
    } finally {
      _batteryRefreshInFlight = false;
      if (_batteryRefreshQueued && !isClosed) {
        _batteryRefreshQueued = false;
        add(const SettingsBatteryOptimizationRefreshRequested());
      }
    }
  }

  void _onBatteryOptimizationStatusChanged(
    SettingsBatteryOptimizationStatusChanged event,
    Emitter<SettingsState> emit,
  ) {
    if (state.batteryOptimizationBusy) {
      _batteryRefreshQueued = true;
      return;
    }
    _applyBatteryOptimizationStatus(event.status, emit: emit);
  }

  void _applyBatteryOptimizationStatus(
    BatteryOptimizationStatus status, {
    required Emitter<SettingsState> emit,
  }) {
    final changed = status != state.batteryOptimizationStatus;
    final shouldLog = changed || _pendingExternalBatterySettingsLog;
    _pendingExternalBatterySettingsLog = false;
    if (shouldLog && status.state != BatteryOptimizationState.unknown) {
      _logBatteryOptimization(action: 'refresh', status: status);
    }
    if (changed) {
      emit(state.copyWith(batteryOptimizationStatus: status));
    }
  }

  Future<void> _onBatteryOptimizationRequestPressed(
    SettingsBatteryOptimizationRequestPressed event,
    Emitter<SettingsState> emit,
  ) async {
    await _runBatteryOptimizationAction(
      emit,
      action: _tunnelRepository.requestIgnoreBatteryOptimizations,
      logAction: 'request',
    );
  }

  Future<void> _onBatteryOptimizationVpnConnectAttempted(
    SettingsBatteryOptimizationVpnConnectAttempted event,
    Emitter<SettingsState> emit,
  ) async {
    if (_batteryOptimizationConnectPromptInFlight) return;
    if (state.batteryOptimizationBusy) return;
    _batteryOptimizationConnectPromptInFlight = true;
    try {
      final alreadyShown = await _settingsRepository
          .loadBatteryOptimizationConnectPromptShown();
      if (alreadyShown) return;

      var status = state.batteryOptimizationStatus;
      if (status.state == BatteryOptimizationState.unknown) {
        status = await _tunnelRepository.getBatteryOptimizationStatus();
        emit(state.copyWith(batteryOptimizationStatus: status));
      }
      if (!status.canRequestExemption) return;

      await _settingsRepository.saveBatteryOptimizationConnectPromptShown(true);
      await _runBatteryOptimizationAction(
        emit,
        action: _tunnelRepository.requestIgnoreBatteryOptimizations,
        logAction: 'connect-prompt',
      );
    } finally {
      _batteryOptimizationConnectPromptInFlight = false;
    }
  }

  Future<void> _onBatteryOptimizationSettingsPressed(
    SettingsBatteryOptimizationSettingsPressed event,
    Emitter<SettingsState> emit,
  ) async {
    await _runBatteryOptimizationAction(
      emit,
      action: _tunnelRepository.openBatteryOptimizationSettings,
      logAction: 'settings',
    );
  }

  Future<void> _onManufacturerBackgroundSettingsPressed(
    SettingsManufacturerBackgroundSettingsPressed event,
    Emitter<SettingsState> emit,
  ) async {
    await _runBatteryOptimizationAction(
      emit,
      action: _tunnelRepository.openManufacturerBackgroundSettings,
      logAction: 'manufacturer-settings',
    );
  }

  Future<void> _runBatteryOptimizationAction(
    Emitter<SettingsState> emit, {
    required Future<BatteryOptimizationRequestResult> Function() action,
    required String logAction,
  }) async {
    emit(state.copyWith(batteryOptimizationBusy: true, clearMessage: true));
    try {
      final result = await action();
      final status = await _tunnelRepository.getBatteryOptimizationStatus();
      final message = _batteryOptimizationMessage(result, status);
      if (result.outcome == BatteryOptimizationRequestOutcome.settingsOpened ||
          (result.outcome == BatteryOptimizationRequestOutcome.requested &&
              status.state != BatteryOptimizationState.allowed)) {
        _pendingExternalBatterySettingsLog = true;
      }
      _logBatteryOptimization(
        action: logAction,
        status: status,
        result: result,
      );
      emit(
        state.copyWith(
          batteryOptimizationBusy: false,
          batteryOptimizationStatus: status,
          message: _nextMessage(
            message,
            error: result.outcome == BatteryOptimizationRequestOutcome.failed,
          ),
        ),
      );
    } finally {
      if (state.batteryOptimizationBusy) {
        emit(state.copyWith(batteryOptimizationBusy: false));
      }
      if (_batteryRefreshQueued && !isClosed) {
        _batteryRefreshQueued = false;
        add(const SettingsBatteryOptimizationRefreshRequested());
      }
    }
  }

  void _logBatteryOptimization({
    required String action,
    required BatteryOptimizationStatus status,
    BatteryOptimizationRequestResult? result,
  }) {
    final isFailure =
        result?.outcome == BatteryOptimizationRequestOutcome.failed;
    if (!isFailure && status.state == BatteryOptimizationState.allowed) {
      if (_batteryUnrestrictedLoggedThisSession) return;
      _batteryUnrestrictedLoggedThisSession = true;
    } else if (!isFailure) {
      _batteryUnrestrictedLoggedThisSession = false;
    }
    final parts = <String>[
      'action=$action',
      if (result != null) 'outcome=${result.outcome.name}',
      'state=${status.state.name}',
      'powerSaveMode=${status.powerSaveMode}',
      if (result?.message != null) 'message=${result!.message}',
    ];
    _appendLog(
      isFailure ? LogLevel.warning : LogLevel.info,
      'battery_optimization: ${parts.join(' ')}',
    );
  }

  HomeMessage _nextMessage(String text, {bool error = false}) {
    _messageId += 1;
    return HomeMessage(id: _messageId, text: text, error: error);
  }

  String _batteryOptimizationMessage(
    BatteryOptimizationRequestResult result,
    BatteryOptimizationStatus status,
  ) {
    final t = AppL10n.current;
    if (result.outcome == BatteryOptimizationRequestOutcome.requested &&
        status.state == BatteryOptimizationState.allowed) {
      return t.batteryOptimizationDisabled;
    }
    return switch (result.outcome) {
      BatteryOptimizationRequestOutcome.unsupported =>
        t.batteryOptimizationUnsupportedDevice,
      BatteryOptimizationRequestOutcome.alreadyAllowed =>
        t.batteryOptimizationAlreadyDisabled,
      BatteryOptimizationRequestOutcome.requested =>
        t.batteryOptimizationRequestOpened,
      BatteryOptimizationRequestOutcome.settingsOpened =>
        t.batterySettingsOpened,
      BatteryOptimizationRequestOutcome.failed =>
        result.message ?? t.batterySettingsOpenFailed,
    };
  }

  Future<void> _onConnectionModeChanged(
    SettingsConnectionModeChanged event,
    Emitter<SettingsState> emit,
  ) async {
    emit(state.copyWith(connectionMode: event.mode));
    await _settingsRepository.saveConnectionMode(event.mode);
    _appendLog(
      LogLevel.debug,
      'Connection mode changed mode=${event.mode.jsonValue}',
      tag: 'settings',
    );
  }

  Future<void> _onSplitTunnelSettingsChanged(
    SettingsSplitTunnelSettingsChanged event,
    Emitter<SettingsState> emit,
  ) async {
    final normalized = event.settings.copyWith();
    emit(state.copyWith(splitTunnelSettings: normalized));
    await _settingsRepository.saveSplitTunnelSettings(normalized);
    _appendLog(
      LogLevel.debug,
      'Split tunnel updated enabled=${normalized.enabled} '
      'mode=${normalized.mode.jsonValue} '
      'inclusiveApps=${normalized.inclusivePackages.length} '
      'exclusiveApps=${normalized.exclusivePackages.length}',
      tag: 'settings',
    );
  }

  Future<void> _onProxySettingsChanged(
    SettingsProxySettingsChanged event,
    Emitter<SettingsState> emit,
  ) async {
    final lanChanged =
        state.proxySettings.allowLanConnections !=
        event.settings.allowLanConnections;
    final authChanged =
        state.proxySettings.authEnabled != event.settings.authEnabled;
    emit(state.copyWith(proxySettings: event.settings));
    await _settingsRepository.saveProxySettings(event.settings);
    final message =
        'Proxy settings updated http=${event.settings.httpPort} '
        'socks=${event.settings.socksPort} '
        'lan=${event.settings.allowLanConnections} '
        'auth=${event.settings.authEnabled}';
    if (lanChanged || authChanged) {
      _debouncedLogTimers.remove('proxy')?.cancel();
      _appendLog(LogLevel.debug, message, tag: 'settings');
    } else {
      _scheduleDebouncedDebugLog('proxy', 'settings', message);
    }
  }

  Future<void> _onConnectivityCheckSettingsChanged(
    SettingsConnectivityCheckSettingsChanged event,
    Emitter<SettingsState> emit,
  ) async {
    final urlError = ConnectivityCheckSettings.validateUrl(event.settings.url);
    final timeoutError = ConnectivityCheckSettings.validateTimeoutMs(
      '${event.settings.timeoutMs}',
    );
    if (urlError != null || timeoutError != null) {
      _appendLog(
        LogLevel.warning,
        'Connectivity check settings rejected',
        tag: 'settings',
      );
      emit(state.copyWith(connectivityUrlError: urlError ?? timeoutError));
      return;
    }
    final settings = state.connectivityCheckSettings.copyWith(
      url: event.settings.url,
      timeoutMs: event.settings.timeoutMs,
    );
    emit(
      state.copyWith(
        connectivityCheckSettings: settings,
        clearConnectivityUrlError: true,
      ),
    );
    await _settingsRepository.saveConnectivityCheckSettings(settings);
    _scheduleDebouncedDebugLog(
      'connectivity',
      'settings',
      'Connectivity check settings updated url=${settings.url} timeoutMs=${settings.timeoutMs}',
    );
  }

  Future<void> _onConnectionHapticsChanged(
    SettingsConnectionHapticsChanged event,
    Emitter<SettingsState> emit,
  ) async {
    emit(state.copyWith(connectionHapticsEnabled: event.enabled));
    await _settingsRepository.saveConnectionHapticsEnabled(event.enabled);
  }

  Future<void> _onVersionCheckRequested(
    SettingsVersionCheckRequested event,
    Emitter<SettingsState> emit,
  ) async {
    if (!state.updateCheckConsentGranted) {
      emit(
        state.copyWith(
          appUpdateStatus: AppUpdateStatus.idle,
          updateErrorMessage: null,
          clearUpdateErrorMessage: true,
        ),
      );
      _appendLog(
        LogLevel.info,
        'update: GitHub release check skipped until consent is granted.',
      );
      return;
    }

    _appendLog(LogLevel.debug, 'update: checking GitHub releases');
    emit(
      state.copyWith(
        appUpdateStatus: AppUpdateStatus.loading,
        clearUpdateErrorMessage: true,
      ),
    );

    try {
      final release = await _appUpdateRepository.fetchLatestRelease();
      final installedVersion = state.installedSemanticVersion;
      final status = switch (installedVersion?.compareTo(release.version)) {
        null => AppUpdateStatus.comparisonUnavailable,
        < 0 => AppUpdateStatus.updateAvailable,
        > 0 => AppUpdateStatus.aheadOfRelease,
        _ => AppUpdateStatus.upToDate,
      };
      final updateMessage = status == AppUpdateStatus.comparisonUnavailable
          ? (state.installedVersionError ??
                'Installed version unavailable, so this build cannot be compared.')
          : null;

      emit(
        state.copyWith(
          appUpdateStatus: status,
          latestReleaseVersion: release.versionLabel,
          latestReleaseUrl: release.htmlUrl,
          updateErrorMessage: updateMessage,
          clearUpdateErrorMessage: updateMessage == null,
        ),
      );
      if (status == AppUpdateStatus.comparisonUnavailable) {
        _appendLog(
          LogLevel.warning,
          'update: fetched ${release.versionLabel} but could not compare installed build. ${updateMessage ?? ''}'
              .trim(),
        );
      } else {
        _appendLog(
          LogLevel.debug,
          'update: check complete status=${status.name} latest=${release.versionLabel}',
        );
      }
    } on AppUpdateException catch (error) {
      _appendLog(
        LogLevel.warning,
        'update: ${error.userMessage}${error.details == null ? '' : ' ${error.details!}'}',
      );
      emit(
        state.copyWith(
          appUpdateStatus: AppUpdateStatus.error,
          updateErrorMessage: error.userMessage,
          updateErrorKind: error.kind,
          updateErrorStatusCode: error.statusCode,
        ),
      );
    } catch (error) {
      _appendLog(LogLevel.error, 'update: unexpected failure $error');
      emit(
        state.copyWith(
          appUpdateStatus: AppUpdateStatus.error,
          updateErrorMessage:
              'Unexpected error while checking GitHub Releases.',
          updateErrorKind: AppUpdateErrorKind.unknown,
        ),
      );
    }
  }

  Future<void> _onVersionCheckConsentGranted(
    SettingsVersionCheckConsentGranted event,
    Emitter<SettingsState> emit,
  ) async {
    await _settingsRepository.saveUpdateCheckConsentGranted(true);
    _appendLog(LogLevel.debug, 'update: consent granted by user');
    emit(state.copyWith(updateCheckConsentGranted: true));
    add(const SettingsVersionCheckRequested());
  }

  void _appendLog(
    LogLevel level,
    String message, {
    String tag = 'settings_update',
  }) {
    _logsRepository.logDart(level, tag, message);
  }
}
