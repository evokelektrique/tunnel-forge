import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/l10n/language_picker_sheet.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';

typedef ProxyPortAvailabilityChecker =
    Future<bool?> Function(int port, {required bool allowLan});

/// Theme mode, connection mode, split tunneling, and global local-proxy settings.
class SettingsPanel extends StatefulWidget {
  const SettingsPanel({
    super.key,
    required this.selectedLocale,
    required this.onLocaleChanged,
    this.themeMode,
    this.onThemeModeChanged,
    required this.connectionMode,
    required this.splitTunnelSettings,
    required this.proxySettings,
    this.proxyExposure,
    required this.connectivityCheckSettings,
    this.connectionHapticsEnabled = true,
    this.onConnectionHapticsChanged,
    required this.batteryOptimizationStatus,
    required this.batteryOptimizationBusy,
    required this.onConnectionModeChanged,
    required this.onSplitTunnelSettingsChanged,
    required this.onProxySettingsChanged,
    this.onCheckProxyPortAvailable,
    required this.onConnectivityCheckSettingsChanged,
    required this.onRequestBatteryOptimization,
    required this.onChooseApps,
    this.onOpenL2tpSecurityNotice,
    this.installedVersion,
    this.installedVersionError,
    required this.updateCheckConsentGranted,
    required this.appUpdateStatus,
    this.latestReleaseVersion,
    this.updateErrorMessage,
    this.updateErrorKind,
    this.updateErrorStatusCode,
    required this.onRefreshVersionCheck,
    this.onOpenReleasePage,
    required this.onOpenTelegram,
    required this.onOpenGithub,
    required this.routingLocked,
    required this.colorScheme,
    required this.textTheme,
  });

  final Locale? selectedLocale;
  final ValueChanged<Locale?> onLocaleChanged;
  final ThemeMode? themeMode;
  final ValueChanged<ThemeMode>? onThemeModeChanged;
  final ConnectionMode connectionMode;
  final SplitTunnelSettings splitTunnelSettings;
  final ProxySettings proxySettings;
  final ProxyExposure? proxyExposure;
  final ConnectivityCheckSettings connectivityCheckSettings;
  final bool connectionHapticsEnabled;
  final ValueChanged<bool>? onConnectionHapticsChanged;
  final BatteryOptimizationStatus batteryOptimizationStatus;
  final bool batteryOptimizationBusy;
  final ValueChanged<ConnectionMode> onConnectionModeChanged;
  final ValueChanged<SplitTunnelSettings> onSplitTunnelSettingsChanged;
  final ValueChanged<ProxySettings> onProxySettingsChanged;
  final ProxyPortAvailabilityChecker? onCheckProxyPortAvailable;
  final ValueChanged<ConnectivityCheckSettings>
  onConnectivityCheckSettingsChanged;
  final VoidCallback onRequestBatteryOptimization;
  final VoidCallback onChooseApps;
  final VoidCallback? onOpenL2tpSecurityNotice;
  final String? installedVersion;
  final String? installedVersionError;
  final bool updateCheckConsentGranted;
  final AppUpdateStatus appUpdateStatus;
  final String? latestReleaseVersion;
  final String? updateErrorMessage;
  final AppUpdateErrorKind? updateErrorKind;
  final int? updateErrorStatusCode;
  final VoidCallback onRefreshVersionCheck;
  final VoidCallback? onOpenReleasePage;
  final VoidCallback onOpenTelegram;
  final VoidCallback onOpenGithub;
  final bool routingLocked;
  final ColorScheme colorScheme;
  final TextTheme textTheme;

  @override
  State<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<SettingsPanel> {
  static const double _kSectionGap = 24;
  static const double _kSectionHeaderGap = 8;
  static const EdgeInsets _kCardTilePadding = EdgeInsets.fromLTRB(
    16,
    12,
    16,
    12,
  );
  static const EdgeInsets _kCardContentPadding = EdgeInsets.fromLTRB(
    16,
    16,
    16,
    20,
  );

  static const Duration _kPortCheckDebounce = Duration(milliseconds: 500);
  static const Duration _kPortCheckTimeout = Duration(seconds: 3);

  late final _ProxyPortSlot _httpPortSlot;
  late final _ProxyPortSlot _socksPortSlot;
  late final TextEditingController _proxyAuthUsernameController;
  late final TextEditingController _proxyAuthPasswordController;
  late final TextEditingController _connectivityUrlController;
  late final TextEditingController _connectivityTimeoutController;
  bool _obscureProxyPassword = true;
  String? _connectivityUrlError;
  String? _connectivityTimeoutError;

  @override
  void initState() {
    super.initState();
    _httpPortSlot = _ProxyPortSlot(
      initialPort: widget.proxySettings.httpPort,
      onBlur: () => _handlePortFieldBlur(_httpPortSlot),
    );
    _socksPortSlot = _ProxyPortSlot(
      initialPort: widget.proxySettings.socksPort,
      onBlur: () => _handlePortFieldBlur(_socksPortSlot),
    );
    _syncProxyFieldValidation(allowCheck: false);
    _proxyAuthUsernameController = TextEditingController(
      text: widget.proxySettings.authUsername,
    );
    _proxyAuthPasswordController = TextEditingController(
      text: widget.proxySettings.authPassword,
    );
    _connectivityUrlController = TextEditingController(
      text: widget.connectivityCheckSettings.url,
    );
    _connectivityTimeoutController = TextEditingController(
      text: '${widget.connectivityCheckSettings.timeoutMs}',
    );
  }

  @override
  void didUpdateWidget(covariant SettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final httpUpdated = _syncSlotWithExternalPort(
      _httpPortSlot,
      oldPort: oldWidget.proxySettings.httpPort,
      newPort: widget.proxySettings.httpPort,
    );
    final socksUpdated = _syncSlotWithExternalPort(
      _socksPortSlot,
      oldPort: oldWidget.proxySettings.socksPort,
      newPort: widget.proxySettings.socksPort,
    );
    final allowLanChanged =
        oldWidget.proxySettings.allowLanConnections !=
        widget.proxySettings.allowLanConnections;
    if (allowLanChanged) {
      _httpPortSlot.resetAvailability();
      _socksPortSlot.resetAvailability();
    }
    if (httpUpdated || socksUpdated || allowLanChanged) {
      _syncProxyFieldValidation(
        allowCheck: allowLanChanged && !widget.routingLocked,
        immediateCheck: allowLanChanged,
      );
    }
    if (oldWidget.proxySettings.authUsername !=
            widget.proxySettings.authUsername &&
        _proxyAuthUsernameController.text !=
            widget.proxySettings.authUsername) {
      _proxyAuthUsernameController.text = widget.proxySettings.authUsername;
    }
    if (oldWidget.proxySettings.authPassword !=
            widget.proxySettings.authPassword &&
        _proxyAuthPasswordController.text !=
            widget.proxySettings.authPassword) {
      _proxyAuthPasswordController.text = widget.proxySettings.authPassword;
    }
    if (oldWidget.connectivityCheckSettings.url !=
        widget.connectivityCheckSettings.url) {
      final nextText = widget.connectivityCheckSettings.url;
      if (_connectivityUrlController.text != nextText) {
        _connectivityUrlController.text = nextText;
      }
      if (_connectivityUrlError != null) {
        _connectivityUrlError = null;
      }
    }
    if (oldWidget.connectivityCheckSettings.timeoutMs !=
        widget.connectivityCheckSettings.timeoutMs) {
      final nextText = '${widget.connectivityCheckSettings.timeoutMs}';
      if (_connectivityTimeoutController.text != nextText) {
        _connectivityTimeoutController.text = nextText;
      }
      if (_connectivityTimeoutError != null) {
        _connectivityTimeoutError = null;
      }
    }
  }

  @override
  void dispose() {
    _httpPortSlot.dispose();
    _socksPortSlot.dispose();
    _proxyAuthUsernameController.dispose();
    _proxyAuthPasswordController.dispose();
    _connectivityUrlController.dispose();
    _connectivityTimeoutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final splitTunnelSettings = widget.splitTunnelSettings;
    final t = AppL10n.of(context);
    final selectedLocale = widget.selectedLocale;
    final languageSummary = selectedLocale == null
        ? t.systemDefaultLanguageSummary(
            AppLanguageController.nativeNameFor(
              AppLanguageController.resolveLocale(
                null,
                PlatformDispatcher.instance.locales,
              ),
            ),
          )
        : AppLanguageController.nativeNameFor(selectedLocale);
    final isInclusive = splitTunnelSettings.mode == SplitTunnelMode.inclusive;
    final activePackages = splitTunnelSettings.activePackages;
    final activePackagesEmpty = activePackages.isEmpty;
    final splitTunnelSubtitle = switch (splitTunnelSettings.mode) {
      SplitTunnelMode.inclusive when activePackagesEmpty => t.noAppsUseVpn,
      SplitTunnelMode.inclusive => t.appsWillUseVpn(activePackages.length),
      SplitTunnelMode.exclusive when activePackagesEmpty => t.noAppsBypassVpn,
      SplitTunnelMode.exclusive => t.appsWillBypassVpn(activePackages.length),
    };
    final proxyMode = widget.connectionMode == ConnectionMode.proxyOnly;
    final activeProxyExposure = widget.proxyExposure?.active == true
        ? widget.proxyExposure
        : null;
    final proxyDisplayHosts =
        activeProxyExposure?.displayAddresses ??
        const [ProxyExposure.loopbackAddress];
    final proxyHttpPort =
        activeProxyExposure?.httpPort ?? widget.proxySettings.httpPort;
    final proxySocksPort =
        activeProxyExposure?.socksPort ?? widget.proxySettings.socksPort;
    final proxyEndpointStatus = switch (activeProxyExposure) {
      ProxyExposure exposure when exposure.hasWarning => exposure.warning!,
      ProxyExposure exposure when exposure.lanActive => t.lanClientsCanUse,
      ProxyExposure exposure when exposure.lanRequested => t.lanSharingEnabled,
      _ when widget.proxySettings.allowLanConnections => t.connectToDetectLan,
      _ => t.lanDisabled,
    };

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _sectionTitle(t.general),
        const SizedBox(height: _kSectionHeaderGap),
        _buildGeneralGroup(t, languageSummary),
        const SizedBox(height: _kSectionGap),
        _sectionTitle(t.connection),
        const SizedBox(height: _kSectionHeaderGap),
        _buildConnectionGroup(
          t,
          proxyMode: proxyMode,
          splitTunnelSettings: splitTunnelSettings,
          isInclusive: isInclusive,
          activePackagesEmpty: activePackagesEmpty,
          splitTunnelSubtitle: splitTunnelSubtitle,
          proxyDisplayHosts: proxyDisplayHosts,
          proxyHttpPort: proxyHttpPort,
          proxySocksPort: proxySocksPort,
          proxyEndpointStatus: proxyEndpointStatus,
        ),
        const SizedBox(height: _kSectionGap),
        _sectionTitle(t.about),
        const SizedBox(height: _kSectionHeaderGap),
        _buildAboutGroup(t),
      ],
    );
  }

  Widget _buildGeneralGroup(AppLocalizations t, String languageSummary) {
    final children = <Widget>[
      ListTile(
        key: const Key('settings_language_tile'),
        contentPadding: _kCardTilePadding,
        leading: Icon(
          Icons.translate_rounded,
          color: widget.colorScheme.onSurfaceVariant,
        ),
        title: _cardTitle(t.languageLabel),
        subtitle: _cardText(
          languageSummary,
          color: widget.colorScheme.onSurfaceVariant,
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: widget.colorScheme.onSurfaceVariant,
        ),
        onTap: () => showLanguagePickerSheet(
          context,
          selectedLocale: widget.selectedLocale,
          onSelected: widget.onLocaleChanged,
        ),
      ),
    ];

    if (widget.themeMode != null && widget.onThemeModeChanged != null) {
      children.add(
        Padding(
          padding: _kCardContentPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cardTitle(t.appearance),
              const SizedBox(height: 12),
              SegmentedButton<ThemeMode>(
                segments: [
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.system,
                    label: Text(t.system),
                    icon: const Icon(Icons.brightness_auto_outlined, size: 18),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.light,
                    label: Text(t.light),
                    icon: const Icon(Icons.light_mode_outlined, size: 18),
                  ),
                  ButtonSegment<ThemeMode>(
                    value: ThemeMode.dark,
                    label: Text(t.dark),
                    icon: const Icon(Icons.dark_mode_outlined, size: 18),
                  ),
                ],
                selected: {widget.themeMode!},
                onSelectionChanged: (next) {
                  if (next.isEmpty) return;
                  widget.onThemeModeChanged!(next.first);
                },
              ),
            ],
          ),
        ),
      );
    }

    children.add(
      SwitchListTile(
        key: const Key('connection_haptics_switch'),
        contentPadding: _kCardTilePadding,
        title: _cardTitle(t.connectionHaptics),
        subtitle: _cardText(
          t.connectionHapticsHelp,
          color: widget.colorScheme.onSurfaceVariant,
        ),
        value: widget.connectionHapticsEnabled,
        onChanged: widget.onConnectionHapticsChanged,
      ),
    );
    children.add(
      Padding(
        key: const Key('battery_optimization_card'),
        padding: _kCardTilePadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _cardTitle(t.batteryOptimization),
                  _cardText(
                    _batteryOptimizationSubtitle(t),
                    color: _batteryOptimizationColor(),
                  ),
                ],
              ),
            ),
            if (widget.batteryOptimizationStatus.canRequestExemption) ...[
              const SizedBox(width: 12),
              FilledButton.tonalIcon(
                key: const Key('battery_optimization_request_button'),
                onPressed: widget.batteryOptimizationBusy
                    ? null
                    : widget.onRequestBatteryOptimization,
                icon: const Icon(Icons.shield_outlined),
                label: Text(t.allowBackgroundVpn),
              ),
            ],
          ],
        ),
      ),
    );
    return _groupCard(children);
  }

  Widget _buildConnectionGroup(
    AppLocalizations t, {
    required bool proxyMode,
    required SplitTunnelSettings splitTunnelSettings,
    required bool isInclusive,
    required bool activePackagesEmpty,
    required String splitTunnelSubtitle,
    required List<String> proxyDisplayHosts,
    required int proxyHttpPort,
    required int proxySocksPort,
    required String proxyEndpointStatus,
  }) {
    final children = <Widget>[
      Padding(
        padding: _kCardContentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(t.connectionMode),
            const SizedBox(height: 12),
            SegmentedButton<ConnectionMode>(
              segments: [
                ButtonSegment<ConnectionMode>(
                  value: ConnectionMode.vpnTunnel,
                  label: Text(t.vpn),
                  icon: const Icon(Icons.vpn_key_outlined, size: 18),
                ),
                ButtonSegment<ConnectionMode>(
                  value: ConnectionMode.proxyOnly,
                  label: Text(t.localProxy),
                  icon: const Icon(Icons.lan_outlined, size: 18),
                ),
              ],
              selected: {widget.connectionMode},
              onSelectionChanged: widget.routingLocked
                  ? null
                  : (next) {
                      if (next.isEmpty) return;
                      widget.onConnectionModeChanged(next.first);
                    },
            ),
          ],
        ),
      ),
    ];

    if (!proxyMode) {
      children.add(
        Padding(
          padding: _kCardContentPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cardTitle(t.splitTunneling),
              const SizedBox(height: 8),
              SwitchListTile(
                key: const Key('split_tunnel_enabled_switch'),
                contentPadding: EdgeInsets.zero,
                title: _cardTitle(t.enableSplitTunneling),
                subtitle: _cardText(
                  splitTunnelSettings.enabled
                      ? t.splitTunnelApply(
                          isInclusive ? t.inclusive : t.exclusive,
                        )
                      : t.splitTunnelRouteAll,
                  color: widget.colorScheme.onSurfaceVariant,
                ),
                value: splitTunnelSettings.enabled,
                onChanged: widget.routingLocked
                    ? null
                    : (value) => widget.onSplitTunnelSettingsChanged(
                        splitTunnelSettings.copyWith(enabled: value),
                      ),
              ),
              if (splitTunnelSettings.enabled) ...[
                const SizedBox(height: 8),
                _cardTitle(t.mode),
                _cardText(
                  isInclusive ? t.inclusiveDescription : t.exclusiveDescription,
                  color: widget.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<SplitTunnelMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment<SplitTunnelMode>(
                        value: SplitTunnelMode.inclusive,
                        label: Text(t.inclusive),
                      ),
                      ButtonSegment<SplitTunnelMode>(
                        value: SplitTunnelMode.exclusive,
                        label: Text(t.exclusive),
                      ),
                    ],
                    selected: {splitTunnelSettings.mode},
                    onSelectionChanged: widget.routingLocked
                        ? null
                        : (next) {
                            if (next.isEmpty) return;
                            widget.onSplitTunnelSettingsChanged(
                              splitTunnelSettings.copyWith(mode: next.first),
                            );
                          },
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  enabled: !widget.routingLocked,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    isInclusive
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_outward_rounded,
                    color: widget.colorScheme.onSurfaceVariant,
                  ),
                  title: _cardTitle(
                    isInclusive ? t.selectAppsUsingVpn : t.selectAppsOutsideVpn,
                  ),
                  subtitle: _cardText(
                    splitTunnelSubtitle,
                    color: isInclusive && activePackagesEmpty
                        ? widget.colorScheme.error
                        : widget.colorScheme.onSurfaceVariant,
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: widget.colorScheme.onSurfaceVariant,
                  ),
                  onTap: widget.onChooseApps,
                ),
              ],
            ],
          ),
        ),
      );
    }

    children.add(
      Padding(
        padding: _kCardContentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(t.localProxy),
            const SizedBox(height: 12),
            _buildProxyPortField(
              key: const Key('proxy_http_port_field'),
              label: t.httpPort,
              slot: _httpPortSlot,
            ),
            const SizedBox(height: 16),
            _buildProxyPortField(
              key: const Key('proxy_socks_port_field'),
              label: t.socksPort,
              slot: _socksPortSlot,
            ),
            const SizedBox(height: 8),
            _cardText(
              t.proxyPortLimitsNote,
              color: widget.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('proxy_allow_lan_switch'),
              contentPadding: EdgeInsets.zero,
              title: _cardTitle(t.allowLan),
              subtitle: _cardText(
                widget.proxySettings.allowLanConnections
                    ? t.allowLanOn
                    : t.allowLanOff,
                color: widget.colorScheme.onSurfaceVariant,
              ),
              value: widget.proxySettings.allowLanConnections,
              onChanged: widget.routingLocked
                  ? null
                  : (value) => widget.onProxySettingsChanged(
                      widget.proxySettings.copyWith(allowLanConnections: value),
                    ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('proxy_auth_switch'),
              contentPadding: EdgeInsets.zero,
              title: _cardTitle(t.proxyAuthTitle),
              subtitle: _cardText(
                t.proxyAuthSubtitle,
                color: widget.colorScheme.onSurfaceVariant,
              ),
              value: widget.proxySettings.authEnabled,
              onChanged: widget.routingLocked
                  ? null
                  : (value) => widget.onProxySettingsChanged(
                      widget.proxySettings.copyWith(authEnabled: value),
                    ),
            ),
            if (widget.proxySettings.authEnabled) ...[
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('proxy_auth_username_field'),
                controller: _proxyAuthUsernameController,
                enabled: !widget.routingLocked,
                decoration: InputDecoration(labelText: t.proxyAuthUsername),
                onChanged: (value) => widget.onProxySettingsChanged(
                  widget.proxySettings.copyWith(authUsername: value),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const Key('proxy_auth_password_field'),
                controller: _proxyAuthPasswordController,
                enabled: !widget.routingLocked,
                obscureText: _obscureProxyPassword,
                decoration: InputDecoration(
                  labelText: t.proxyAuthPassword,
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureProxyPassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                    onPressed: () => setState(
                      () => _obscureProxyPassword = !_obscureProxyPassword,
                    ),
                  ),
                ),
                onChanged: (value) => widget.onProxySettingsChanged(
                  widget.proxySettings.copyWith(authPassword: value),
                ),
              ),
              if (!widget.proxySettings.hasCompleteAuthCredentials) ...[
                const SizedBox(height: 8),
                _cardText(
                  t.proxyAuthCredentialsRequired,
                  color: widget.colorScheme.error,
                ),
              ],
            ],
            const SizedBox(height: 12),
            _cardTitle(t.proxyEndpoints),
            const SizedBox(height: 8),
            _cardText(
              [
                'HTTP: ${proxyDisplayHosts.map((host) => '$host:$proxyHttpPort').join(', ')}',
                'SOCKS5: ${proxyDisplayHosts.map((host) => '$host:$proxySocksPort').join(', ')}',
                proxyEndpointStatus,
              ].join('\n'),
            ),
          ],
        ),
      ),
    );
    children.add(
      Padding(
        padding: _kCardContentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(t.connectivityCheck),
            const SizedBox(height: 8),
            _cardTitle(t.statusCheckUrl),
            _cardText(
              t.statusCheckHelp,
              color: widget.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('connectivity_url_field'),
              controller: _connectivityUrlController,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: t.connectivityUrl,
                hintText: ConnectivityCheckSettings.defaultUrl,
                errorText: _connectivityUrlError,
              ),
              onChanged: (value) {
                final error = ConnectivityCheckSettings.validateUrl(
                  value,
                  l10n: t,
                );
                if (_connectivityUrlError != error) {
                  setState(() => _connectivityUrlError = error);
                }
                if (error != null) return;
                widget.onConnectivityCheckSettingsChanged(
                  widget.connectivityCheckSettings.copyWith(url: value),
                );
              },
            ),
            const SizedBox(height: 14),
            TextFormField(
              key: const Key('connectivity_timeout_field'),
              controller: _connectivityTimeoutController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: t.connectivityTimeout,
                hintText: '${ConnectivityCheckSettings.defaultTimeoutMs}',
                errorText: _connectivityTimeoutError,
              ),
              onChanged: (value) {
                final error = ConnectivityCheckSettings.validateTimeoutMs(
                  value,
                  l10n: t,
                );
                if (_connectivityTimeoutError != error) {
                  setState(() => _connectivityTimeoutError = error);
                }
                if (error != null) return;
                final timeoutMs = ConnectivityCheckSettings.parseTimeoutMs(
                  value,
                );
                if (timeoutMs == null) return;
                widget.onConnectivityCheckSettingsChanged(
                  widget.connectivityCheckSettings.copyWith(
                    timeoutMs: timeoutMs,
                  ),
                );
              },
            ),
            _cardText(
              t.timeoutHelp,
              color: widget.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
    return _groupCard(children);
  }

  Widget _buildAboutGroup(AppLocalizations t) {
    final children = <Widget>[];
    if (widget.onOpenL2tpSecurityNotice != null) {
      children.add(
        ListTile(
          key: const Key('l2tp_security_notice_tile'),
          contentPadding: _kCardTilePadding,
          title: _cardTitle(t.l2tpSecurityNotice),
          subtitle: _cardText(
            t.reviewL2tpNotice,
            color: widget.colorScheme.onSurfaceVariant,
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: widget.colorScheme.onSurfaceVariant,
          ),
          onTap: widget.onOpenL2tpSecurityNotice,
        ),
      );
    }
    children.add(
      Padding(
        padding: _kCardContentPadding,
        child: _cardText(
          t.aboutText,
          color: widget.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    children.add(
      ListTile(
        key: const Key('settings_about_telegram_tile'),
        contentPadding: _kCardTilePadding,
        title: _cardTitle(t.telegramTitle),
        subtitle: _cardText(
          'https://t.me/TunnelForge',
          color: widget.colorScheme.onSurfaceVariant,
        ),
        trailing: Icon(
          Icons.open_in_new,
          color: widget.colorScheme.onSurfaceVariant,
        ),
        onTap: widget.onOpenTelegram,
      ),
    );
    children.add(
      ListTile(
        key: const Key('settings_about_github_tile'),
        contentPadding: _kCardTilePadding,
        title: _cardTitle(t.githubTitle),
        subtitle: _cardText(
          'https://github.com/evokelektrique/tunnel-forge',
          color: widget.colorScheme.onSurfaceVariant,
        ),
        trailing: Icon(
          Icons.open_in_new,
          color: widget.colorScheme.onSurfaceVariant,
        ),
        onTap: widget.onOpenGithub,
      ),
    );
    children.add(
      Padding(
        key: const Key('settings_update_card'),
        padding: _kCardContentPadding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cardTitle(_updateTitle(t)),
            _cardText(
              _updateSubtitle(t),
              color: widget.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  key: const Key('settings_update_refresh_button'),
                  onPressed: _handleVersionCheckPressed,
                  icon: const Icon(Icons.refresh),
                  label: Text(t.refresh),
                ),
                if (widget.onOpenReleasePage != null)
                  FilledButton.tonalIcon(
                    key: const Key('settings_update_open_button'),
                    onPressed: widget.onOpenReleasePage,
                    icon: const Icon(Icons.open_in_new),
                    label: Text(t.openReleasePage),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
    children.add(
      Padding(
        key: const Key('settings_version_footer'),
        padding: const EdgeInsets.all(16),
        child: Text(
          widget.installedVersion == null
              ? t.versionUnavailable
              : t.version(widget.installedVersion!),
          textAlign: TextAlign.center,
          style: widget.textTheme.bodySmall?.copyWith(
            color: widget.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
    return _groupCard(children, key: const Key('settings_about_card'));
  }

  Widget _groupCard(List<Widget> children, {Key? key}) {
    final content = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) content.add(const Divider(height: 1));
      content.add(children[i]);
    }
    return Card(
      key: key,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: content,
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: widget.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    );
  }

  Widget _cardTitle(String text) {
    return Text(
      text,
      style: widget.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    );
  }

  Widget _cardText(String text, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: widget.textTheme.bodySmall?.copyWith(color: color),
      ),
    );
  }

  Future<void> _handleVersionCheckPressed() async {
    if (widget.updateCheckConsentGranted) {
      widget.onRefreshVersionCheck();
      return;
    }
    final t = AppL10n.of(context);
    final granted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.updateCheckConsentTitle),
        content: Text(t.updateCheckConsentMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.updateCheckConsentAllow),
          ),
        ],
      ),
    );
    if (!mounted || granted != true) return;
    widget.onRefreshVersionCheck();
  }

  String _batteryOptimizationSubtitle(AppLocalizations t) {
    return switch (widget.batteryOptimizationStatus.state) {
      BatteryOptimizationState.allowed => t.batteryOptimizationAllowed,
      BatteryOptimizationState.restricted => t.batteryOptimizationRestricted,
      BatteryOptimizationState.unsupported => t.batteryOptimizationUnsupported,
      BatteryOptimizationState.unknown => t.batteryOptimizationUnknown,
    };
  }

  Color _batteryOptimizationColor() {
    return switch (widget.batteryOptimizationStatus.state) {
      BatteryOptimizationState.allowed => widget.colorScheme.primary,
      BatteryOptimizationState.restricted => widget.colorScheme.error,
      BatteryOptimizationState.unsupported ||
      BatteryOptimizationState.unknown => widget.colorScheme.onSurfaceVariant,
    };
  }

  String _updateTitle(AppLocalizations t) {
    return switch (widget.appUpdateStatus) {
      AppUpdateStatus.loading => t.checkingUpdates,
      AppUpdateStatus.updateAvailable => t.updateAvailable,
      AppUpdateStatus.aheadOfRelease => t.buildNewer,
      AppUpdateStatus.comparisonUnavailable => t.versionUnavailable,
      AppUpdateStatus.error => t.updateCheckUnavailable,
      AppUpdateStatus.upToDate => t.appUpToDate,
      AppUpdateStatus.idle => t.checkForUpdates,
    };
  }

  String _updateSubtitle(AppLocalizations t) {
    final latestRelease = widget.latestReleaseVersion;
    return switch (widget.appUpdateStatus) {
      AppUpdateStatus.loading => t.lookingUpRelease,
      AppUpdateStatus.updateAvailable when latestRelease != null =>
        t.latestReleaseRunning(
          latestRelease,
          widget.installedVersion ?? t.unknownBuild,
        ),
      AppUpdateStatus.upToDate when latestRelease != null => t.latestPublished(
        latestRelease,
      ),
      AppUpdateStatus.aheadOfRelease when latestRelease != null =>
        t.buildNewerThanLatest(latestRelease),
      AppUpdateStatus.comparisonUnavailable when latestRelease != null =>
        t.latestCannotCompare(
          latestRelease,
          t.installedVersionUnavailableCompare,
        ),
      AppUpdateStatus.error => _localizedUpdateError(t),
      _ => t.checkGithubReleases,
    };
  }

  String _localizedUpdateError(AppLocalizations t) {
    return switch (widget.updateErrorKind) {
      AppUpdateErrorKind.http =>
        widget.updateErrorStatusCode != null
            ? t.updateErrorHttp(widget.updateErrorStatusCode!)
            : t.couldNotCheckUpdates,
      AppUpdateErrorKind.network => t.updateErrorNetwork,
      AppUpdateErrorKind.timeout => t.updateErrorTimeout,
      AppUpdateErrorKind.tls => t.updateErrorTls,
      AppUpdateErrorKind.response => t.updateErrorMalformed,
      AppUpdateErrorKind.noReleases => t.updateErrorNoReleases,
      AppUpdateErrorKind.unknown => t.updateErrorUnexpected,
      null => widget.updateErrorMessage ?? t.couldNotCheckUpdates,
    };
  }

  Widget _buildProxyPortField({
    required Key key,
    required String label,
    required _ProxyPortSlot slot,
  }) {
    return TextFormField(
      key: key,
      controller: slot.controller,
      focusNode: slot.focusNode,
      enabled: !widget.routingLocked,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(5),
      ],
      decoration: InputDecoration(
        labelText: label,
        errorText: slot.errorText,
        errorMaxLines: 2,
        suffixIcon: slot.checking
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : null,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
      ),
      onChanged: (_) => _handlePortFieldChanged(slot),
      onEditingComplete: () => _handlePortFieldBlur(slot),
    );
  }

  bool _syncSlotWithExternalPort(
    _ProxyPortSlot slot, {
    required int oldPort,
    required int newPort,
  }) {
    if (oldPort == newPort) return false;
    final nextText = '$newPort';
    if (!slot.focusNode.hasFocus &&
        slot.errorText == null &&
        slot.controller.text != nextText) {
      slot.controller.text = nextText;
      slot.resetAvailability(verifiedPort: newPort);
      return true;
    }
    return false;
  }

  void _handlePortFieldChanged(_ProxyPortSlot changedSlot) {
    changedSlot.cancelPendingCheck();
    final parsed = ProxySettings.parseValidPort(changedSlot.controller.text);
    if (changedSlot.inUsePort != parsed) {
      changedSlot.inUsePort = null;
    }
    _syncProxyFieldValidation(
      allowCheck: true,
      changedSlot: changedSlot,
      notifyWidget: true,
    );
  }

  void _handlePortFieldBlur(_ProxyPortSlot slot) {
    if (slot.debounceTimer != null || slot.pendingCheckPort != null) {
      slot.debounceTimer?.cancel();
      slot.debounceTimer = null;
      unawaited(_runPortCheck(slot));
    }
  }

  void _syncProxyFieldValidation({
    required bool allowCheck,
    _ProxyPortSlot? changedSlot,
    bool immediateCheck = false,
    bool notifyWidget = false,
  }) {
    final httpText = _httpPortSlot.controller.text;
    final socksText = _socksPortSlot.controller.text;
    final t = AppL10n.current;
    final httpSyntaxError = ProxySettings.validatePortText(httpText, l10n: t);
    final socksSyntaxError = ProxySettings.validatePortText(socksText, l10n: t);
    final httpPort = ProxySettings.parseValidPort(httpText);
    final socksPort = ProxySettings.parseValidPort(socksText);
    final colliding =
        httpPort != null && socksPort != null && httpPort == socksPort;

    void applySlot(_ProxyPortSlot slot, String? syntaxError, int? parsedPort) {
      if (colliding) {
        slot.cancelPendingCheck();
        slot.errorText = AppL10n.current.proxyPortsDifferent;
        return;
      }
      if (syntaxError != null) {
        slot.cancelPendingCheck();
        slot.inUsePort = null;
        slot.errorText = syntaxError;
        return;
      }
      if (parsedPort != null && slot.inUsePort == parsedPort) {
        slot.errorText = AppL10n.current.proxyPortInUse(parsedPort);
        return;
      }
      slot.inUsePort = null;
      slot.errorText = null;
    }

    applySlot(_httpPortSlot, httpSyntaxError, httpPort);
    applySlot(_socksPortSlot, socksSyntaxError, socksPort);

    if (notifyWidget && mounted) {
      setState(() {});
    }

    if (colliding || !allowCheck) return;

    if (widget.onCheckProxyPortAvailable == null) {
      _emitProxyPortsIfReady();
      return;
    }

    var scheduledAny = false;
    for (final (slot, parsedPort) in [
      (_httpPortSlot, httpPort),
      (_socksPortSlot, socksPort),
    ]) {
      if (parsedPort == null || slot.errorText != null) continue;
      final needsCheck =
          slot == changedSlot ||
          immediateCheck ||
          slot.lastCheckedFreePort != parsedPort;
      if (!needsCheck) continue;
      scheduledAny = true;
      if (immediateCheck) {
        unawaited(_runPortCheck(slot));
      } else {
        _schedulePortCheck(slot, parsedPort);
      }
    }
    if (!scheduledAny) {
      _emitProxyPortsIfReady();
    }
  }

  void _schedulePortCheck(_ProxyPortSlot slot, int port) {
    slot.debounceTimer?.cancel();
    slot.pendingCheckPort = port;
    slot.debounceTimer = Timer(_kPortCheckDebounce, () {
      slot.debounceTimer = null;
      unawaited(_runPortCheck(slot));
    });
  }

  Future<void> _runPortCheck(_ProxyPortSlot slot) async {
    final checker = widget.onCheckProxyPortAvailable;
    if (checker == null || widget.routingLocked) return;
    final port = ProxySettings.parseValidPort(slot.controller.text);
    final httpPort = ProxySettings.parseValidPort(
      _httpPortSlot.controller.text,
    );
    final socksPort = ProxySettings.parseValidPort(
      _socksPortSlot.controller.text,
    );
    if (port == null || (httpPort != null && httpPort == socksPort)) {
      slot.pendingCheckPort = null;
      return;
    }
    final generation = ++slot.checkGeneration;
    final allowLan = widget.proxySettings.allowLanConnections;
    slot.timeoutTimer?.cancel();
    slot.timeoutTimer = Timer(_kPortCheckTimeout, () {
      slot.timeoutTimer = null;
      if (!mounted || generation != slot.checkGeneration) return;
      slot.checkGeneration += 1;
      setState(() => slot.checking = false);
      _emitProxyPortsIfReady();
    });
    if (mounted) {
      setState(() {
        slot.checking = true;
        slot.pendingCheckPort = null;
      });
    }
    bool? available;
    try {
      available = await checker(port, allowLan: allowLan);
    } catch (_) {
      available = null;
    } finally {
      if (generation == slot.checkGeneration) {
        slot.timeoutTimer?.cancel();
        slot.timeoutTimer = null;
      }
    }
    if (!mounted || generation != slot.checkGeneration) return;
    final currentPort = ProxySettings.parseValidPort(slot.controller.text);
    final currentHttp = ProxySettings.parseValidPort(
      _httpPortSlot.controller.text,
    );
    final currentSocks = ProxySettings.parseValidPort(
      _socksPortSlot.controller.text,
    );
    final currentColliding =
        currentHttp != null &&
        currentSocks != null &&
        currentHttp == currentSocks;
    if (currentPort != port ||
        allowLan != widget.proxySettings.allowLanConnections) {
      setState(() => slot.checking = false);
      return;
    }
    setState(() {
      slot.checking = false;
      if (available == false) {
        slot.inUsePort = port;
        slot.lastCheckedFreePort = null;
        if (!currentColliding) {
          slot.errorText = AppL10n.current.proxyPortInUse(port);
        }
      } else {
        slot.inUsePort = null;
        slot.lastCheckedFreePort = port;
        if (!currentColliding) {
          slot.errorText = null;
        }
      }
    });
    _emitProxyPortsIfReady();
  }

  void _emitProxyPortsIfReady() {
    final httpPort = ProxySettings.parseValidPort(
      _httpPortSlot.controller.text,
    );
    final socksPort = ProxySettings.parseValidPort(
      _socksPortSlot.controller.text,
    );
    if (httpPort == null || socksPort == null || httpPort == socksPort) return;
    if (_httpPortSlot.hasBlockingState || _socksPortSlot.hasBlockingState) {
      return;
    }
    if (httpPort != widget.proxySettings.httpPort ||
        socksPort != widget.proxySettings.socksPort) {
      widget.onProxySettingsChanged(
        widget.proxySettings.copyWith(httpPort: httpPort, socksPort: socksPort),
      );
    }
  }
}

class _ProxyPortSlot {
  _ProxyPortSlot({required int initialPort, required VoidCallback onBlur})
    : controller = TextEditingController(text: '$initialPort'),
      focusNode = FocusNode(),
      lastCheckedFreePort = initialPort {
    _focusListener = () {
      if (!focusNode.hasFocus) {
        onBlur();
      }
    };
    focusNode.addListener(_focusListener);
  }

  final TextEditingController controller;
  final FocusNode focusNode;
  late final VoidCallback _focusListener;
  Timer? debounceTimer;
  Timer? timeoutTimer;
  int checkGeneration = 0;
  int? pendingCheckPort;
  int? lastCheckedFreePort;
  int? inUsePort;
  bool checking = false;
  String? errorText;

  bool get hasBlockingState =>
      errorText != null ||
      checking ||
      debounceTimer != null ||
      pendingCheckPort != null ||
      inUsePort != null;

  void cancelPendingCheck() {
    debounceTimer?.cancel();
    debounceTimer = null;
    timeoutTimer?.cancel();
    timeoutTimer = null;
    pendingCheckPort = null;
    checkGeneration += 1;
    checking = false;
  }

  void resetAvailability({int? verifiedPort}) {
    cancelPendingCheck();
    inUsePort = null;
    lastCheckedFreePort = verifiedPort;
  }

  void dispose() {
    debounceTimer?.cancel();
    timeoutTimer?.cancel();
    focusNode.removeListener(_focusListener);
    focusNode.dispose();
    controller.dispose();
  }
}
