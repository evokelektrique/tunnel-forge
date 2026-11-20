import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:get_it/get_it.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/tunnel_error_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:tunnel_forge/app/ui/app_scaffold_messenger.dart';
import 'package:tunnel_forge/features/app_selector/presentation/pages/app_selector_page.dart';
import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/presentation/profile_editor_sheet.dart';
import 'package:tunnel_forge/features/profiles/presentation/profile_picker_sheet.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/subscriptions/presentation/subscription_update_dialog.dart';
import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/connection_panel.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/logs_panel.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/settings_panel.dart';
import '../../../app_theme/presentation/bloc/app_theme_bloc.dart';
import '../../../home/domain/home_models.dart';
import '../../../home/domain/home_repositories.dart';
import '../../../onboarding/presentation/bloc/onboarding_bloc.dart';
import '../../../onboarding/presentation/pages/onboarding_page.dart';
import '../bloc/connectivity_bloc.dart';
import '../bloc/home_nav_bloc.dart';
import '../bloc/logs_bloc.dart';
import '../bloc/profiles_bloc.dart';
import '../bloc/settings_bloc.dart';
import '../bloc/tunnel_bloc.dart';

class VpnHomePage extends StatelessWidget {
  const VpnHomePage({super.key, required this.locator});

  final GetIt locator;

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider<HomeNavBloc>(create: (_) => locator<HomeNavBloc>()),
        BlocProvider<ProfilesBloc>(
          create: (_) => locator<ProfilesBloc>()..add(const ProfilesStarted()),
        ),
        BlocProvider<SettingsBloc>(
          create: (_) => locator<SettingsBloc>()..add(const SettingsStarted()),
        ),
        BlocProvider<LogsBloc>(
          create: (_) => locator<LogsBloc>()..add(const LogsStarted()),
        ),
        BlocProvider<TunnelBloc>(
          create: (_) => locator<TunnelBloc>()..add(const TunnelStarted()),
        ),
        BlocProvider<ConnectivityBloc>(
          create: (_) => locator<ConnectivityBloc>(),
        ),
      ],
      child: _VpnHomePageView(locator: locator),
    );
  }
}

class _VpnHomePageView extends StatefulWidget {
  const _VpnHomePageView({required this.locator});

  final GetIt locator;

  @override
  State<_VpnHomePageView> createState() => _VpnHomePageViewState();
}

class _VpnHomePageViewState extends State<_VpnHomePageView>
    with WidgetsBindingObserver {
  static const String _kGithubReleasesUrl =
      'https://github.com/evokelektrique/tunnel-forge/releases';
  static const String _kProjectGithubUrl =
      'https://github.com/evokelektrique/tunnel-forge';
  static const String _kTelegramUrl = 'https://t.me/TunnelForge';

  final ScrollController _logsScroll = ScrollController();
  bool _logsStickToBottom = true;
  int _lastProfilesMessageId = 0;
  int _lastSubscriptionSummaryEventId = 0;
  int _lastTunnelMessageId = 0;
  int _lastSettingsMessageId = 0;
  bool _lastTunnelUp = false;
  bool _connectionAttemptActive = false;
  int _lastLogsEntryCount = 0;
  bool _hasSyncedQuickSettings = false;
  QuickSettingsProfileConfig? _lastSyncedQuickSettingsConfig;
  bool _pendingQuickSettingsConnect = false;
  StreamSubscription<void>? _quickSettingsConnectSub;
  Timer? _dueSubscriptionsTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _logsScroll.addListener(_syncLogsStickToBottom);
    final tunnelRepository = widget.locator<TunnelRepository>();
    _quickSettingsConnectSub = tunnelRepository.quickSettingsConnectRequests
        .listen((_) => _handleQuickSettingsConnectSignal());
    unawaited(_consumePendingQuickSettingsConnect());
    _dueSubscriptionsTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      context.read<ProfilesBloc>().add(
        const ProfilesDueSubscriptionsCheckRequested(),
      );
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncQuickSettings(
        context.read<ProfilesBloc>().state,
        context.read<SettingsBloc>().state,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dueSubscriptionsTimer?.cancel();
    _quickSettingsConnectSub?.cancel();
    _logsScroll.removeListener(_syncLogsStickToBottom);
    _logsScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !mounted) return;
    context.read<TunnelBloc>().add(const TunnelRuntimeSyncRequested());
    context.read<SettingsBloc>().add(
      const SettingsBatteryOptimizationRefreshRequested(),
    );
    context.read<ProfilesBloc>().add(
      const ProfilesDueSubscriptionsCheckRequested(),
    );
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.state != ViewFocusState.focused || !mounted) return;
    context.read<TunnelBloc>().add(const TunnelRuntimeSyncRequested());
    context.read<SettingsBloc>().add(
      const SettingsBatteryOptimizationRefreshRequested(),
    );
  }

  void _syncLogsStickToBottom() {
    if (!_logsScroll.hasClients) return;
    final metrics = _logsScroll.position;
    const edge = 88.0;
    final atBottom = metrics.pixels >= metrics.maxScrollExtent - edge;
    if (atBottom == _logsStickToBottom) return;
    setState(() => _logsStickToBottom = atBottom);
  }

  void _scheduleScrollLogsToEnd() {
    if (!_logsStickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_logsScroll.hasClients) return;
      _logsScroll.position.jumpTo(_logsScroll.position.maxScrollExtent);
    });
  }

  void _jumpLogsToBottom() {
    setState(() => _logsStickToBottom = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_logsScroll.hasClients) return;
      _logsScroll.animateTo(
        _logsScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _toast(String text, {bool error = false}) {
    showAppSnackBar(context, text, error: error);
  }

  Future<void> _consumePendingQuickSettingsConnect() async {
    final pending = await widget
        .locator<TunnelRepository>()
        .consumePendingQuickSettingsConnect();
    if (!mounted || !pending) return;
    _handleQuickSettingsConnectSignal();
  }

  void _handleQuickSettingsConnectSignal() {
    _pendingQuickSettingsConnect = true;
    _triggerPendingQuickSettingsConnectIfReady();
  }

  void _triggerPendingQuickSettingsConnectIfReady() {
    if (!mounted || !_pendingQuickSettingsConnect) return;
    final profilesState = context.read<ProfilesBloc>().state;
    final settingsState = context.read<SettingsBloc>().state;
    if (profilesState.loading || settingsState.loading) return;
    _pendingQuickSettingsConnect = false;
    final tunnelState = context.read<TunnelBloc>().state;
    if (tunnelState.busy ||
        tunnelState.stopRequested ||
        tunnelState.tunnelUp ||
        tunnelState.awaitingTunnel) {
      return;
    }
    _primaryAction(profilesState, settingsState, tunnelState);
  }

  void _syncQuickSettings(
    ProfilesState profilesState,
    SettingsState settingsState,
  ) {
    if (profilesState.loading || settingsState.loading) return;
    final row = profilesState.activeProfileRow;
    final QuickSettingsProfileConfig? nextConfig =
        profilesState.hasActiveProfile && row != null
        ? QuickSettingsProfileConfig(
            profileId: row.profile.id,
            profileName: row.profile.displayName,
            server: row.profile.server,
            user: row.profile.user,
            password: row.password,
            psk: row.psk,
            protocol: row.profile.protocol,
            secretsMissing: row.secretsMissing,
            dnsAutomatic: row.profile.dnsAutomatic,
            dnsServers: row.profile.dnsAutomatic
                ? const <DnsServerConfig>[]
                : Profile.orderedDnsServers(
                    dns1Host: row.profile.dns1Host,
                    dns1Protocol: row.profile.dns1Protocol,
                    dns2Host: row.profile.dns2Host,
                    dns2Protocol: row.profile.dns2Protocol,
                  ),
            mtu: row.profile.mtu,
            connectionMode: settingsState.connectionMode,
            splitTunnelSettings: settingsState.splitTunnelSettings,
            proxySettings: settingsState.proxySettings,
          )
        : null;
    if (_hasSyncedQuickSettings &&
        _lastSyncedQuickSettingsConfig == nextConfig) {
      _triggerPendingQuickSettingsConnectIfReady();
      return;
    }
    _hasSyncedQuickSettings = true;
    _lastSyncedQuickSettingsConfig = nextConfig;
    unawaited(
      widget.locator<TunnelRepository>().syncQuickSettingsProfile(nextConfig),
    );
    _triggerPendingQuickSettingsConnectIfReady();
  }

  Future<void> _handleProfilesStateChange(ProfilesState state) async {
    final message = state.message;
    if (message != null && message.id != _lastProfilesMessageId) {
      _lastProfilesMessageId = message.id;
      _toast(message.text, error: message.error);
    }
    final summaryEvent = state.pendingSummaryEvent;
    if (summaryEvent != null &&
        summaryEvent.id != _lastSubscriptionSummaryEventId) {
      _lastSubscriptionSummaryEventId = summaryEvent.id;
      unawaited(SubscriptionUpdateDialog.show(context, summaryEvent.summaries));
    }
    _syncQuickSettings(state, context.read<SettingsBloc>().state);
  }

  ConnectivityPingRequest _connectivityPingRequest(
    SettingsState settingsState,
    TunnelState tunnelState,
  ) {
    final connectivitySettings = settingsState.connectivityCheckSettings;
    final url = connectivitySettings.url;
    final timeoutMs = connectivitySettings.timeoutMs;
    if (settingsState.connectionMode == ConnectionMode.proxyOnly) {
      final proxyPort = tunnelState.proxyExposure?.httpPort;
      return ConnectivityPingRequest.localHttpProxy(
        url: url,
        timeoutMs: timeoutMs,
        proxyPort: ProxySettings.normalizePort(
          proxyPort ?? settingsState.proxySettings.httpPort,
          fallback: ProxySettings.defaultHttpPort,
        ),
      );
    }
    return ConnectivityPingRequest.directWithTimeout(
      url: url,
      timeoutMs: timeoutMs,
    );
  }

  Future<void> _handleTunnelStateChange(TunnelState current) async {
    if (current.busy && !_lastTunnelUp) {
      _connectionAttemptActive = true;
    }
    final message = current.message;
    if (message != null && message.id != _lastTunnelMessageId) {
      _lastTunnelMessageId = message.id;
      final failure = message.failure;
      if (failure != null) {
        // The message ID is consumed before opening the dialog, so rebuilds
        // cannot display the same error twice.
        unawaited(
          showDialog<void>(
            context: context,
            barrierDismissible: true,
            builder: (_) => TunnelErrorDialog(
              failure: failure,
              onExportLogs: () =>
                  _shareDebugLogs(context.read<LogsBloc>().state),
            ),
          ),
        );
      } else {
        _toast(message.text, error: message.error);
      }
      if (_connectionAttemptActive && message.error) {
        unawaited(_playConnectionHaptic(failure: true));
        _connectionAttemptActive = false;
      }
    }
    final settingsState = context.read<SettingsBloc>().state;
    if (!_lastTunnelUp && current.tunnelUp && !current.stopRequested) {
      if (_connectionAttemptActive) {
        unawaited(_playConnectionHaptic(failure: false));
      }
      _connectionAttemptActive = false;
      context.read<ConnectivityBloc>().add(
        ConnectivityRunRequested(
          _connectivityPingRequest(settingsState, current),
        ),
      );
    } else if (_lastTunnelUp && !current.tunnelUp) {
      context.read<ConnectivityBloc>().add(const ConnectivityResetRequested());
    }
    context.read<ProfilesBloc>().add(
      ProfilesImportSelectionPolicyChanged(
        !current.busy &&
            !current.stopRequested &&
            !current.tunnelUp &&
            !current.awaitingTunnel,
      ),
    );
    _lastTunnelUp = current.tunnelUp;
  }

  Future<void> _playConnectionHaptic({required bool failure}) async {
    if (!context.read<SettingsBloc>().state.connectionHapticsEnabled) return;
    try {
      if (failure) {
        await HapticFeedback.mediumImpact();
      } else {
        await HapticFeedback.lightImpact();
      }
    } on MissingPluginException {
      // Haptic feedback is optional on platforms without the plugin.
    } on PlatformException {
      // Haptic feedback must not affect connection results.
    }
  }

  Future<void> _handleLogsStateChange(LogsState current) async {
    if (_lastLogsEntryCount != current.entries.length) {
      _lastLogsEntryCount = current.entries.length;
      _scheduleScrollLogsToEnd();
    }
  }

  Future<void> _openProfilePicker() async {
    final profilesBloc = context.read<ProfilesBloc>();
    final settingsBloc = context.read<SettingsBloc>();
    final tunnelBloc = context.read<TunnelBloc>();
    final profilesState = profilesBloc.state;
    if (profilesState.loading || !mounted) return;
    final previousActiveId = profilesState.activeProfileId;
    final selectedId = await ProfilePickerSheet.show(
      context,
      profilesBloc: profilesBloc,
      store: widget.locator<ProfileStore>(),
      logsRepository: widget.locator<LogsRepository>(),
    );
    if (!mounted || selectedId == null || selectedId == previousActiveId) {
      return;
    }
    final tunnelState = tunnelBloc.state;
    final isTunnelActive = tunnelState.tunnelUp || tunnelState.awaitingTunnel;
    if (!isTunnelActive || tunnelState.busy || tunnelState.stopRequested) {
      return;
    }
    await _reconnectToProfile(
      selectedId,
      profilesBloc: profilesBloc,
      settingsBloc: settingsBloc,
      tunnelBloc: tunnelBloc,
    );
  }

  Future<void> _reconnectToProfile(
    String selectedId, {
    required ProfilesBloc profilesBloc,
    required SettingsBloc settingsBloc,
    required TunnelBloc tunnelBloc,
  }) async {
    var resolved = profilesBloc.state;
    if (resolved.loading ||
        resolved.activeProfileId != selectedId ||
        resolved.activeProfileRow?.profile.id != selectedId) {
      try {
        resolved = await profilesBloc.stream
            .firstWhere(
              (state) =>
                  !state.loading &&
                  state.activeProfileId == selectedId &&
                  state.activeProfileRow?.profile.id == selectedId,
            )
            .timeout(const Duration(seconds: 5));
      } on TimeoutException {
        return;
      }
    }
    if (!mounted) return;
    final row = resolved.activeProfileRow;
    if (row == null) return;
    if (row.secretsMissing) {
      unawaited(_handleMissingSecrets(row.profile));
      return;
    }
    final settingsState = settingsBloc.state;
    if (settingsState.connectionMode == ConnectionMode.vpnTunnel) {
      settingsBloc.add(const SettingsBatteryOptimizationVpnConnectAttempted());
    }
    tunnelBloc.add(
      TunnelReconnectRequested(_buildConnectRequest(row, settingsState)),
    );
  }

  Future<void> _pickAppsForVpn() async {
    final t = AppL10n.of(context);
    final splitTunnelSettings = context
        .read<SettingsBloc>()
        .state
        .splitTunnelSettings;
    final isInclusive = splitTunnelSettings.mode == SplitTunnelMode.inclusive;
    final current = splitTunnelSettings.activePackages;
    final repository = widget.locator<TunnelRepository>();
    final picked = await Navigator.of(context, rootNavigator: true)
        .push<Set<String>>(
          MaterialPageRoute(
            fullscreenDialog: true,
            builder: (ctx) => AppSelectorPage(
              title: isInclusive ? t.appsUsingVpn : t.appsOutsideVpn,
              description: isInclusive
                  ? t.onlySelectedAppsVpn
                  : t.selectedAppsBypass,
              initialSelection: Set<String>.from(current),
              loadApps: repository.listVpnCandidateApps,
              loadIcon: repository.getAppIcon,
            ),
          ),
        );
    if (!mounted || picked == null) return;
    final nextSettings = isInclusive
        ? splitTunnelSettings.copyWith(inclusivePackages: picked.toList())
        : splitTunnelSettings.copyWith(exclusivePackages: picked.toList());
    context.read<SettingsBloc>().add(
      SettingsSplitTunnelSettingsChanged(nextSettings),
    );
  }

  Future<void> _openL2tpSecurityNotice() async {
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => BlocProvider<OnboardingBloc>(
          create: (_) =>
              widget.locator<OnboardingBloc>()
                ..add(const OnboardingReadOnlyOpened()),
          child: const OnboardingPage(),
        ),
      ),
    );
  }

  Future<void> _openExternalUrl(
    String url, {
    required String invalidMessage,
    required String failureMessage,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      _toast(invalidMessage, error: true);
      return;
    }
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      _toast(failureMessage, error: true);
    }
  }

  Future<void> _openReleasePage(String url) {
    final t = AppL10n.of(context);
    return _openExternalUrl(
      url,
      invalidMessage: t.releasePageUrlInvalid,
      failureMessage: t.couldNotOpenReleasePage,
    );
  }

  void _handleMissingProfileTap(ProfilesState profilesState) {
    final t = AppL10n.of(context);
    final message = profilesState.profiles.isEmpty
        ? t.createProfileBeforeConnecting
        : t.selectProfileBeforeConnecting;
    _toast(message, error: true);
    widget.locator<LogsRepository>().append(
      LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.warning,
        source: LogSource.dart,
        tag: 'tunnel',
        message: 'Connect blocked: no active profile',
      ),
    );
  }

  Future<void> _handleMissingSecrets(Profile profile) async {
    final t = AppL10n.of(context);
    _toast(
      t.savedSecretsUnreadableForProfile(profile.displayName),
      error: true,
    );
    widget.locator<LogsRepository>().append(
      LogEntry(
        timestamp: DateTime.now(),
        level: LogLevel.warning,
        source: LogSource.dart,
        tag: 'tunnel',
        message: 'Connect blocked: secrets unreadable profile=${profile.id}',
      ),
    );
    final profilesBloc = context.read<ProfilesBloc>();
    final saved = await ProfileEditorSheet.show(
      context,
      profileId: profile.id,
      store: widget.locator<ProfileStore>(),
      logsRepository: widget.locator<LogsRepository>(),
    );
    if (!mounted || !saved) return;
    final refreshResult = profilesBloc.stream
        .firstWhere((state) {
          return !state.loading &&
              state.activeProfileId == profile.id &&
              state.profiles.any((p) => p.id == profile.id);
        })
        .timeout(const Duration(seconds: 5));
    profilesBloc.add(ProfilesRefreshRequested(preferredActiveId: profile.id));
    try {
      await refreshResult;
    } on TimeoutException {
      if (!mounted) return;
      _toast(AppL10n.of(context).profileRefreshTimedOut, error: true);
    }
  }

  TunnelConnectRequest _buildConnectRequest(
    ProfileSecretRow row,
    SettingsState settingsState,
  ) {
    final profile = row.profile;
    final trimmedName = profile.displayName.trim();
    final dnsServers = profile.dnsAutomatic
        ? const <DnsServerConfig>[]
        : Profile.orderedDnsServers(
            dns1Host: profile.dns1Host,
            dns1Protocol: profile.dns1Protocol,
            dns2Host: profile.dns2Host,
            dns2Protocol: profile.dns2Protocol,
          );
    return TunnelConnectRequest(
      activeProfileId: profile.id,
      profileName: trimmedName.isEmpty ? null : trimmedName,
      server: profile.server,
      user: profile.user,
      password: row.password,
      psk: row.psk,
      protocol: profile.protocol,
      dnsAutomatic: profile.dnsAutomatic,
      dnsServers: dnsServers,
      mtu: profile.mtu,
      connectionMode: settingsState.connectionMode,
      splitTunnelSettings: settingsState.splitTunnelSettings,
      proxySettings: settingsState.proxySettings,
    );
  }

  void _primaryAction(
    ProfilesState profilesState,
    SettingsState settingsState,
    TunnelState tunnelState,
  ) {
    if (tunnelState.busy || tunnelState.stopRequested) {
      return;
    }
    if (tunnelState.tunnelUp ||
        (tunnelState.awaitingTunnel && !tunnelState.tunnelUp)) {
      context.read<TunnelBloc>().add(const TunnelDisconnectRequested());
      return;
    }
    final row = profilesState.activeProfileRow;
    if (row == null || !profilesState.hasActiveProfile) {
      _handleMissingProfileTap(profilesState);
      return;
    }
    if (row.secretsMissing) {
      unawaited(_handleMissingSecrets(row.profile));
      return;
    }
    if (settingsState.connectionMode == ConnectionMode.vpnTunnel) {
      context.read<SettingsBloc>().add(
        const SettingsBatteryOptimizationVpnConnectAttempted(),
      );
    }
    context.read<TunnelBloc>().add(
      TunnelConnectRequested(_buildConnectRequest(row, settingsState)),
    );
  }

  Future<bool> _promptIncludeTombstone() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final t = AppL10n.of(ctx);
        return AlertDialog(
          title: Text(t.includeNativeCrashDumpTitle),
          content: Text(t.includeNativeCrashDumpBody),
          actions: [
            FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.noLabel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.yesLabel),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _shareDebugLogs(LogsState logsState) async {
    final t = AppL10n.of(context);
    try {
      final bridge = DiagnosticsBridge.instance;
      var includeTombstone = false;
      if (await bridge.hasTombstone()) {
        if (!mounted) return;
        includeTombstone = await _promptIncludeTombstone();
        if (!mounted) return;
      }
      final paths = await bridge.exportLogs(includeTombstone: includeTombstone);
      if (paths.isEmpty) {
        _toast(t.noDebugLogsToShare);
        return;
      }
      await SharePlus.instance.share(
        ShareParams(
          files: paths.map((path) => XFile(path)).toList(growable: false),
          title: t.shareDebugLogsTitle,
        ),
      );
      widget.locator<LogsRepository>().logDart(
        LogLevel.debug,
        'logs',
        'Shared debug logs files=${paths.length} includeTombstone=$includeTombstone',
      );
      _toast(t.preparedDebugLogArchive);
    } catch (error) {
      widget.locator<LogsRepository>().logDart(
        LogLevel.warning,
        'logs',
        'Share debug logs failed error=${error.runtimeType}',
      );
      _toast(t.couldNotShareDebugLogs, error: true);
    }
  }

  void _clearLogs() {
    context.read<LogsBloc>().add(const LogsCleared());
    setState(() => _logsStickToBottom = true);
    _toast(AppL10n.of(context).logsCleared);
  }

  String _connectButtonLabel(
    AppLocalizations t,
    TunnelState tunnelState,
    bool hasActiveProfile,
    ConnectionMode connectionMode,
  ) {
    if (tunnelState.stopRequested && tunnelState.tunnelUp) {
      return t.disconnecting;
    }
    if (tunnelState.stopRequested) return t.canceling;
    if (tunnelState.busy && tunnelState.tunnelUp) return t.disconnecting;
    if (tunnelState.recoveryPhase == TunnelRecoveryPhase.waitingForNetwork) {
      return connectionMode == ConnectionMode.vpnTunnel
          ? t.waitingForNetworkBlocking
          : t.waitingForNetwork;
    }
    if (tunnelState.recoveryPhase == TunnelRecoveryPhase.reconnecting) {
      return t.reconnectingTapCancel;
    }
    if (tunnelState.awaitingTunnel && !tunnelState.tunnelUp) {
      return t.connectingTapCancel;
    }
    if (tunnelState.busy) return t.working;
    if (tunnelState.tunnelUp) {
      return connectionMode == ConnectionMode.proxyOnly
          ? t.proxyReady
          : t.connected;
    }
    if (!hasActiveProfile) return t.selectProfile;
    return t.ready;
  }

  String _connectivityBadgeLabel(AppLocalizations t, ConnectivityState state) {
    return switch (state.badgeState) {
      ConnectivityBadgeState.idle => t.tapToCheck,
      ConnectivityBadgeState.checking => t.checking,
      ConnectivityBadgeState.success => '${state.latencyMs ?? 0} ms',
      ConnectivityBadgeState.failure => t.unreachable,
    };
  }

  @override
  Widget build(BuildContext context) {
    final navState = context.watch<HomeNavBloc>().state;
    final profilesState = context.watch<ProfilesBloc>().state;
    final settingsState = context.watch<SettingsBloc>().state;
    final tunnelState = context.watch<TunnelBloc>().state;
    final logsState = context.watch<LogsBloc>().state;
    final connectivityState = context.watch<ConnectivityBloc>().state;
    final appThemeState = context.watch<AppThemeBloc>().state;
    final t = AppL10n.of(context);
    final hasDebugLogs = logsState.entries.isNotEmpty;
    final languageController = AppLanguageController.of(context);

    final effectiveProfileId = profilesState.hasActiveProfile
        ? profilesState.activeProfileId
        : null;
    Profile? activeProfile;
    if (effectiveProfileId != null) {
      for (final profile in profilesState.profiles) {
        if (profile.id == effectiveProfileId) {
          activeProfile = profile;
          break;
        }
      }
    }
    final profileSummaryTitle = activeProfile != null
        ? activeProfile.displayName
        : (profilesState.profiles.isEmpty ? t.noSavedProfile : t.quickConnect);
    final profileSummarySubtitle = activeProfile != null
        ? activeProfile.server
        : (profilesState.profiles.isEmpty
              ? t.createFirstProfile
              : t.selectSavedProfile);
    final appBarTitle = switch (navState.index) {
      0 => t.appTitle,
      1 => t.logs,
      _ => t.settings,
    };

    return MultiBlocListener(
      listeners: [
        BlocListener<ProfilesBloc, ProfilesState>(
          listenWhen: (previous, current) =>
              previous.message != current.message ||
              previous.pendingSummaryEvent != current.pendingSummaryEvent ||
              previous.loading != current.loading ||
              previous.activeProfileId != current.activeProfileId ||
              previous.activeProfileRow != current.activeProfileRow,
          listener: (context, state) => _handleProfilesStateChange(state),
        ),
        BlocListener<TunnelBloc, TunnelState>(
          listenWhen: (previous, current) =>
              previous.message != current.message ||
              previous.tunnelUp != current.tunnelUp ||
              previous.busy != current.busy ||
              previous.awaitingTunnel != current.awaitingTunnel ||
              previous.recoveryPhase != current.recoveryPhase ||
              previous.stopRequested != current.stopRequested,
          listener: (context, state) => _handleTunnelStateChange(state),
        ),
        BlocListener<LogsBloc, LogsState>(
          listenWhen: (previous, current) =>
              previous.entries.length != current.entries.length,
          listener: (context, state) => _handleLogsStateChange(state),
        ),
        BlocListener<SettingsBloc, SettingsState>(
          listenWhen: (previous, current) =>
              previous.message != current.message ||
              previous.loading != current.loading ||
              previous.connectionMode != current.connectionMode ||
              previous.splitTunnelSettings != current.splitTunnelSettings ||
              previous.proxySettings != current.proxySettings,
          listener: (context, state) {
            final message = state.message;
            if (message != null && message.id != _lastSettingsMessageId) {
              _lastSettingsMessageId = message.id;
              _toast(message.text, error: message.error);
            }
            _syncQuickSettings(context.read<ProfilesBloc>().state, state);
          },
        ),
      ],
      child: Scaffold(
        appBar: AppBar(
          title: AnimatedSwitcher(
            duration: const Duration(milliseconds: 360),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.18),
                    end: Offset.zero,
                  ).animate(curved),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.98, end: 1).animate(curved),
                    child: child,
                  ),
                ),
              );
            },
            child: Text(appBarTitle, key: ValueKey<String>(appBarTitle)),
          ),
          actions: [
            if (navState.index == 1)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PopupMenuButton<LogDisplayLevel>(
                      tooltip: t.logLevel,
                      initialValue: logsState.level,
                      onSelected: (level) => context.read<LogsBloc>().add(
                        LogsLevelChangeRequested(level),
                      ),
                      itemBuilder: (context) => const [
                        PopupMenuItem<LogDisplayLevel>(
                          value: LogDisplayLevel.info,
                          child: Text('INFO'),
                        ),
                        PopupMenuItem<LogDisplayLevel>(
                          value: LogDisplayLevel.warning,
                          child: Text('WARNING'),
                        ),
                        PopupMenuItem<LogDisplayLevel>(
                          value: LogDisplayLevel.error,
                          child: Text('ERROR'),
                        ),
                        PopupMenuItem<LogDisplayLevel>(
                          value: LogDisplayLevel.debug,
                          child: Text('DEBUG'),
                        ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.filter_list_rounded, size: 20),
                            const SizedBox(width: 6),
                            Text(
                              logsState.levelLabel,
                              style: Theme.of(context).textTheme.labelMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: logsState.wordWrap
                          ? t.wordWrapOff
                          : t.wordWrapOn,
                      onPressed: () => context.read<LogsBloc>().add(
                        const LogsWordWrapToggled(),
                      ),
                      icon: Icon(
                        logsState.wordWrap ? Icons.wrap_text : Icons.swap_horiz,
                      ),
                    ),
                    IconButton(
                      tooltip: t.shareDebugLogs,
                      onPressed: hasDebugLogs
                          ? () => _shareDebugLogs(logsState)
                          : null,
                      icon: const Icon(Icons.ios_share_rounded),
                    ),
                    IconButton(
                      tooltip: t.clear,
                      onPressed: logsState.entries.isEmpty ? null : _clearLogs,
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ],
                ),
              ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 420),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              alignment: Alignment.topCenter,
              children: <Widget>[?currentChild, ...previousChildren],
            ),
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              );
              return FadeTransition(
                opacity: curved,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.975, end: 1).animate(curved),
                  child: child,
                ),
              );
            },
            child: SizedBox.expand(
              key: ValueKey<int>(navState.index),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface,
                child: switch (navState.index) {
                  0 => Align(
                    alignment: Alignment.topCenter,
                    child: ConnectionPanel(
                      profilesLoading: profilesState.loading,
                      profileSummaryTitle: profileSummaryTitle,
                      profileSummarySubtitle: profileSummarySubtitle,
                      activeProfileProtocol: activeProfile?.protocol,
                      onOpenProfilePicker: _openProfilePicker,
                      busy: tunnelState.busy,
                      tunnelUp: tunnelState.tunnelUp,
                      awaitingTunnel: tunnelState.awaitingTunnel,
                      stopRequested: tunnelState.stopRequested,
                      canStartConnection: profilesState.hasActiveProfile,
                      connectButtonLabel: _connectButtonLabel(
                        t,
                        tunnelState,
                        profilesState.hasActiveProfile,
                        settingsState.connectionMode,
                      ),
                      onPrimary: () => _primaryAction(
                        profilesState,
                        settingsState,
                        tunnelState,
                      ),
                      onUnavailablePrimaryTap: () =>
                          _handleMissingProfileTap(profilesState),
                      connectivityBadgeState: connectivityState.badgeState,
                      connectivityBadgeLabel: _connectivityBadgeLabel(
                        t,
                        connectivityState,
                      ),
                      connectivityCheckRunId: connectivityState.runId,
                      onConnectivityTap: () =>
                          context.read<ConnectivityBloc>().add(
                            ConnectivityRunRequested(
                              _connectivityPingRequest(
                                settingsState,
                                tunnelState,
                              ),
                            ),
                          ),
                      colorScheme: Theme.of(context).colorScheme,
                      textTheme: Theme.of(context).textTheme,
                    ),
                  ),
                  1 => LogsPanel(
                    logs: logsState.visibleLogs,
                    scrollController: _logsScroll,
                    colorScheme: Theme.of(context).colorScheme,
                    textTheme: Theme.of(context).textTheme,
                    stickToBottom: _logsStickToBottom,
                    onJumpToLatest: _jumpLogsToBottom,
                    wordWrap: logsState.wordWrap,
                    hasAnyLogs: logsState.entries.isNotEmpty,
                  ),
                  _ => SettingsPanel(
                    selectedLocale: languageController.locale,
                    onLocaleChanged: languageController.setLocale,
                    themeMode: appThemeState.themeMode,
                    onThemeModeChanged: (mode) =>
                        context.read<AppThemeBloc>().add(AppThemeChanged(mode)),
                    connectionMode: settingsState.connectionMode,
                    splitTunnelSettings: settingsState.splitTunnelSettings,
                    proxySettings: settingsState.proxySettings,
                    connectivityCheckSettings:
                        settingsState.connectivityCheckSettings,
                    connectionHapticsEnabled:
                        settingsState.connectionHapticsEnabled,
                    onConnectionHapticsChanged: (enabled) => context
                        .read<SettingsBloc>()
                        .add(SettingsConnectionHapticsChanged(enabled)),
                    onConnectionModeChanged: (mode) => context
                        .read<SettingsBloc>()
                        .add(SettingsConnectionModeChanged(mode)),
                    onSplitTunnelSettingsChanged: (settings) => context
                        .read<SettingsBloc>()
                        .add(SettingsSplitTunnelSettingsChanged(settings)),
                    onProxySettingsChanged: (settings) => context
                        .read<SettingsBloc>()
                        .add(SettingsProxySettingsChanged(settings)),
                    onCheckProxyPortAvailable: (port, {required allowLan}) =>
                        widget
                            .locator<TunnelRepository>()
                            .checkProxyPortAvailable(
                              port,
                              allowLanConnections: allowLan,
                            ),
                    proxyExposure: tunnelState.proxyExposure,
                    onConnectivityCheckSettingsChanged: (settings) =>
                        context.read<SettingsBloc>().add(
                          SettingsConnectivityCheckSettingsChanged(settings),
                        ),
                    batteryOptimizationStatus:
                        settingsState.batteryOptimizationStatus,
                    batteryOptimizationBusy:
                        settingsState.batteryOptimizationBusy,
                    onRequestBatteryOptimization: () => context
                        .read<SettingsBloc>()
                        .add(const SettingsBatteryOptimizationRequestPressed()),
                    onChooseApps: _pickAppsForVpn,
                    onOpenL2tpSecurityNotice: _openL2tpSecurityNotice,
                    installedVersion: settingsState.installedVersion,
                    installedVersionError: settingsState.installedVersionError,
                    updateCheckConsentGranted:
                        settingsState.updateCheckConsentGranted,
                    appUpdateStatus: settingsState.appUpdateStatus,
                    latestReleaseVersion: settingsState.latestReleaseVersion,
                    updateErrorMessage: settingsState.updateErrorMessage,
                    updateErrorKind: settingsState.updateErrorKind,
                    updateErrorStatusCode: settingsState.updateErrorStatusCode,
                    onRefreshVersionCheck: () =>
                        context.read<SettingsBloc>().add(
                          settingsState.updateCheckConsentGranted
                              ? const SettingsVersionCheckRequested()
                              : const SettingsVersionCheckConsentGranted(),
                        ),
                    onOpenReleasePage: () => _openReleasePage(
                      settingsState.latestReleaseUrl ?? _kGithubReleasesUrl,
                    ),
                    onOpenTelegram: () => _openExternalUrl(
                      _kTelegramUrl,
                      invalidMessage: t.telegramLinkInvalid,
                      failureMessage: t.couldNotOpenTelegram,
                    ),
                    onOpenGithub: () => _openExternalUrl(
                      _kProjectGithubUrl,
                      invalidMessage: t.githubLinkInvalid,
                      failureMessage: t.couldNotOpenGithub,
                    ),
                    routingLocked:
                        profilesState.loading ||
                        tunnelState.busy ||
                        tunnelState.stopRequested ||
                        tunnelState.tunnelUp ||
                        tunnelState.awaitingTunnel,
                    colorScheme: Theme.of(context).colorScheme,
                    textTheme: Theme.of(context).textTheme,
                  ),
                },
              ),
            ),
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: navState.index,
          onDestinationSelected: (index) {
            context.read<HomeNavBloc>().add(HomeNavChanged(index));
            if (index == 1) _scheduleScrollLogsToEnd();
          },
          backgroundColor: Theme.of(context).colorScheme.surface,
          surfaceTintColor: Colors.transparent,
          indicatorColor: Theme.of(context).colorScheme.secondaryContainer,
          height: 72,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          animationDuration: const Duration(milliseconds: 360),
          destinations: [
            NavigationDestination(
              icon: const Icon(Icons.vpn_key_outlined),
              selectedIcon: const Icon(Icons.vpn_key),
              label: t.vpn,
            ),
            NavigationDestination(
              icon: const Icon(Icons.article_outlined),
              selectedIcon: const Icon(Icons.article),
              label: t.logs,
            ),
            NavigationDestination(
              icon: const Icon(Icons.settings_outlined),
              selectedIcon: const Icon(Icons.settings),
              label: t.settings,
            ),
          ],
        ),
      ),
    );
  }
}
