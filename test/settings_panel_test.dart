import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/settings_panel.dart';

void main() {
  Finder connectivityUrlField() =>
      find.byKey(const Key('connectivity_url_field'));
  Finder connectivityTimeoutField() =>
      find.byKey(const Key('connectivity_timeout_field'));
  Finder settingsScrollView() => find.byType(Scrollable).first;
  Finder proxyEndpointsTitle() => find.text('Proxy endpoints');

  Widget buildPanel({
    required ProxySettings proxySettings,
    ConnectionMode connectionMode = ConnectionMode.proxyOnly,
    SplitTunnelSettings splitTunnelSettings = const SplitTunnelSettings(),
    ProxyExposure? proxyExposure,
    ConnectivityCheckSettings connectivityCheckSettings =
        const ConnectivityCheckSettings(),
    BatteryOptimizationStatus batteryOptimizationStatus =
        const BatteryOptimizationStatus(
          state: BatteryOptimizationState.restricted,
        ),
    bool batteryOptimizationBusy = false,
    bool updateCheckConsentGranted = true,
    ValueChanged<SplitTunnelSettings>? onSplitTunnelSettingsChanged,
    ValueChanged<ProxySettings>? onProxySettingsChanged,
    ProxyPortAvailabilityChecker? onCheckProxyPortAvailable,
    ValueChanged<ConnectivityCheckSettings>? onConnectivityCheckSettingsChanged,
    VoidCallback? onRequestBatteryOptimization,
    VoidCallback? onRefreshVersionCheck,
    VoidCallback? onOpenL2tpSecurityNotice,
  }) {
    final theme = ThemeData.light();
    return MaterialApp(
      home: Scaffold(
        body: SettingsPanel(
          selectedLocale: const Locale('en'),
          onLocaleChanged: (_) {},
          themeMode: ThemeMode.light,
          onThemeModeChanged: (_) {},
          connectionMode: connectionMode,
          splitTunnelSettings: splitTunnelSettings,
          proxySettings: proxySettings,
          proxyExposure: proxyExposure,
          connectivityCheckSettings: connectivityCheckSettings,
          batteryOptimizationStatus: batteryOptimizationStatus,
          batteryOptimizationBusy: batteryOptimizationBusy,
          onConnectionModeChanged: (_) {},
          onSplitTunnelSettingsChanged: onSplitTunnelSettingsChanged ?? (_) {},
          onProxySettingsChanged: onProxySettingsChanged ?? (_) {},
          onCheckProxyPortAvailable: onCheckProxyPortAvailable,
          onConnectivityCheckSettingsChanged:
              onConnectivityCheckSettingsChanged ?? (_) {},
          onRequestBatteryOptimization: onRequestBatteryOptimization ?? () {},
          onChooseApps: () {},
          onOpenL2tpSecurityNotice: onOpenL2tpSecurityNotice,
          installedVersion: '0.3.0+11',
          updateCheckConsentGranted: updateCheckConsentGranted,
          appUpdateStatus: AppUpdateStatus.idle,
          onRefreshVersionCheck: onRefreshVersionCheck ?? () {},
          onOpenTelegram: () {},
          onOpenGithub: () {},
          routingLocked: false,
          colorScheme: theme.colorScheme,
          textTheme: theme.textTheme,
        ),
      ),
    );
  }

  testWidgets('settings groups controls into three ordered cards', (
    tester,
  ) async {
    await tester.pumpWidget(buildPanel(proxySettings: const ProxySettings()));

    expect(find.text('General'), findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.byType(Divider), findsWidgets);

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings_about_card')),
      300,
      scrollable: settingsScrollView(),
    );
    expect(find.text('About'), findsOneWidget);

    final aboutCard = tester.widget<Card>(
      find.byKey(const Key('settings_about_card')),
    );
    final aboutChildren = (aboutCard.child! as Column).children;
    final updateIndex = aboutChildren.indexWhere(
      (child) => child.key == const Key('settings_update_card'),
    );
    final versionIndex = aboutChildren.indexWhere(
      (child) => child.key == const Key('settings_version_footer'),
    );
    expect(updateIndex, lessThan(versionIndex));
  });

  testWidgets('proxy port fields update when persisted settings load later', (
    tester,
  ) async {
    await tester.pumpWidget(buildPanel(proxySettings: const ProxySettings()));

    expect(find.text('8080'), findsOneWidget);
    expect(find.text('1080'), findsOneWidget);

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(httpPort: 18080, socksPort: 11080),
      ),
    );
    await tester.pump();

    expect(find.text('18080'), findsWidgets);
    expect(find.text('11080'), findsWidgets);

    await tester.scrollUntilVisible(
      proxyEndpointsTitle(),
      200,
      scrollable: settingsScrollView(),
    );

    expect(find.textContaining('HTTP: 127.0.0.1:18080'), findsOneWidget);
    expect(find.textContaining('SOCKS5: 127.0.0.1:11080'), findsOneWidget);
  });

  testWidgets('editing a proxy port emits parsed settings', (tester) async {
    ProxySettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onProxySettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    await tester.enterText(
      find.byKey(const Key('proxy_http_port_field')),
      '18080',
    );
    await tester.pump();

    expect(changed?.httpPort, 18080);
    expect(changed?.socksPort, ProxySettings.defaultSocksPort);
  });

  testWidgets('invalid and reserved proxy ports show error and clear on fix', (
    tester,
  ) async {
    ProxySettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onProxySettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    final httpField = find.byKey(const Key('proxy_http_port_field'));
    await tester.enterText(httpField, '80');
    await tester.pump();

    const privilegedMessage =
        'Ports 1–1023 are reserved by Android and require system privileges. Use 1024–65535.';
    expect(find.text(privilegedMessage), findsOneWidget);
    expect(changed, isNull);

    await tester.enterText(httpField, '5353');
    await tester.pump();
    expect(
      find.text('Port 5353 is reserved on Android (mDNS) and cannot be used.'),
      findsOneWidget,
    );
    expect(changed, isNull);

    await tester.enterText(httpField, '5555');
    await tester.pump();
    expect(
      find.text(
        'Port 5555 is reserved on Android (ADB over TCP) and cannot be used.',
      ),
      findsOneWidget,
    );
    expect(changed, isNull);

    await tester.enterText(httpField, '');
    await tester.pump();
    expect(
      find.text('Enter a port number between 1024 and 65535.'),
      findsOneWidget,
    );
    expect(changed, isNull);

    await tester.enterText(httpField, '18080');
    await tester.pump();
    expect(find.text(privilegedMessage), findsNothing);
    expect(
      find.text('Enter a port number between 1024 and 65535.'),
      findsNothing,
    );
    expect(changed?.httpPort, 18080);
  });

  testWidgets('duplicate HTTP and SOCKS5 ports show error on both fields', (
    tester,
  ) async {
    ProxySettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onProxySettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    await tester.enterText(
      find.byKey(const Key('proxy_http_port_field')),
      '1080',
    );
    await tester.pump();

    expect(
      find.text('HTTP and SOCKS5 ports must be different before connecting.'),
      findsNWidgets(2),
    );
    expect(changed, isNull);

    await tester.enterText(
      find.byKey(const Key('proxy_socks_port_field')),
      '8080',
    );
    await tester.pump();

    expect(
      find.text('HTTP and SOCKS5 ports must be different before connecting.'),
      findsNothing,
    );
    expect(changed?.httpPort, 1080);
    expect(changed?.socksPort, 8080);
  });

  testWidgets(
    'free port checker flags busy ports after typing and clears when free',
    (tester) async {
      ProxySettings? changed;
      final checkedPorts = <int>[];

      await tester.pumpWidget(
        buildPanel(
          proxySettings: const ProxySettings(),
          onProxySettingsChanged: (value) {
            changed = value;
          },
          onCheckProxyPortAvailable: (port, {required allowLan}) async {
            checkedPorts.add(port);
            return port != 19090;
          },
        ),
      );

      final httpField = find.byKey(const Key('proxy_http_port_field'));
      await tester.enterText(httpField, '19090');
      await tester.pump(const Duration(milliseconds: 200));
      expect(checkedPorts, isEmpty);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(checkedPorts, [19090]);
      expect(
        find.text('Port 19090 is currently in use by another app or service.'),
        findsOneWidget,
      );
      expect(changed, isNull);

      await tester.enterText(httpField, '19091');
      await tester.pump();
      expect(
        find.text('Port 19090 is currently in use by another app or service.'),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      expect(checkedPorts, [19090, 19091]);
      expect(changed?.httpPort, 19091);
    },
  );

  testWidgets('free port checker runs immediately when field loses focus', (
    tester,
  ) async {
    ProxySettings? changed;
    final checkedPorts = <int>[];

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onProxySettingsChanged: (value) {
          changed = value;
        },
        onCheckProxyPortAvailable: (port, {required allowLan}) async {
          checkedPorts.add(port);
          return true;
        },
      ),
    );

    await tester.enterText(
      find.byKey(const Key('proxy_http_port_field')),
      '18081',
    );
    await tester.pump();
    expect(checkedPorts, isEmpty);

    await tester.drag(settingsScrollView(), const Offset(0, -240));
    await tester.pump();
    await tester.tap(find.byKey(const Key('proxy_socks_port_field')));
    await tester.pump();
    expect(checkedPorts, [18081]);
    expect(changed?.httpPort, 18081);
  });

  testWidgets('free port checker recovers when check throws or times out', (
    tester,
  ) async {
    ProxySettings? changed;
    var throwOnCheck = true;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onProxySettingsChanged: (value) {
          changed = value;
        },
        onCheckProxyPortAvailable: (port, {required allowLan}) async {
          if (throwOnCheck) {
            throw StateError('boom');
          }
          return Completer<bool?>().future;
        },
      ),
    );

    final httpField = find.byKey(const Key('proxy_http_port_field'));
    await tester.enterText(httpField, '18082');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(changed?.httpPort, 18082);

    throwOnCheck = false;
    await tester.enterText(httpField, '18083');
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(changed?.httpPort, 18083);
  });

  testWidgets('VPN mode shows split tunneling and proxy controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('proxy_allow_lan_switch')),
      200,
      scrollable: settingsScrollView(),
    );

    expect(
      find.byKey(const Key('split_tunnel_enabled_switch')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('proxy_allow_lan_switch')), findsOneWidget);
  });

  testWidgets('local proxy mode hides split tunneling section', (tester) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.proxyOnly,
      ),
    );

    expect(find.byKey(const Key('split_tunnel_enabled_switch')), findsNothing);
    expect(find.text('Split tunneling'), findsNothing);
  });

  testWidgets('split-tunnel toggle emits updated settings', (tester) async {
    SplitTunnelSettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
        onSplitTunnelSettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    await tester.drag(settingsScrollView(), const Offset(0, -320));
    await tester.pump();
    await tester.tap(find.byKey(const Key('split_tunnel_enabled_switch')));
    await tester.pump();

    expect(changed?.enabled, isTrue);
    expect(changed?.mode, SplitTunnelMode.inclusive);
  });

  testWidgets('disabled split tunneling hides mode controls', (tester) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    );

    expect(find.text('Mode'), findsNothing);
    expect(find.text('Inclusive'), findsNothing);
    expect(find.text('Exclusive'), findsNothing);
    expect(find.text('Select apps using VPN'), findsNothing);
    expect(find.text('Select apps outside VPN'), findsNothing);
  });

  testWidgets('enabled split tunneling shows mode controls', (tester) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
        splitTunnelSettings: const SplitTunnelSettings(enabled: true),
      ),
    );

    expect(find.text('Mode'), findsOneWidget);
    expect(find.text('Inclusive'), findsOneWidget);
    expect(find.text('Exclusive'), findsOneWidget);
  });

  testWidgets('inclusive split tunneling shows validation subtitle', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
        splitTunnelSettings: const SplitTunnelSettings(enabled: true),
      ),
    );

    expect(find.textContaining('Choose at least one app'), findsOneWidget);
  });

  testWidgets('LAN switch emits updated proxy settings', (tester) async {
    ProxySettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onProxySettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('proxy_allow_lan_switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('proxy_allow_lan_switch')));
    await tester.pump();

    expect(changed?.allowLanConnections, isTrue);
  });

  testWidgets('active proxy exposure shows detected LAN IP', (tester) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(allowLanConnections: true),
        proxyExposure: const ProxyExposure(
          active: true,
          bindAddress: '192.168.1.24',
          displayAddress: '192.168.1.24',
          httpPort: 18080,
          socksPort: 11080,
          lanRequested: true,
          lanActive: true,
        ),
      ),
    );
    await tester.scrollUntilVisible(
      proxyEndpointsTitle(),
      200,
      scrollable: settingsScrollView(),
    );

    expect(find.textContaining('HTTP: 192.168.1.24:18080'), findsOneWidget);
    expect(find.textContaining('SOCKS5: 192.168.1.24:11080'), findsOneWidget);
    expect(
      find.textContaining('LAN clients on the same Wi-Fi or hotspot'),
      findsOneWidget,
    );
  });

  testWidgets('LAN warning is shown when no shareable address is available', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(allowLanConnections: true),
        proxyExposure: const ProxyExposure(
          active: true,
          bindAddress: '127.0.0.1',
          displayAddress: '127.0.0.1',
          httpPort: 8080,
          socksPort: 1080,
          lanRequested: true,
          lanActive: false,
          warning:
              'LAN sharing is enabled, but no shareable local IPv4 is currently available.',
        ),
      ),
    );
    await tester.scrollUntilVisible(
      proxyEndpointsTitle(),
      200,
      scrollable: settingsScrollView(),
    );

    expect(
      find.textContaining('no shareable local IPv4 is currently available'),
      findsOneWidget,
    );
  });

  testWidgets('connectivity URL field updates when persisted value changes', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    );

    await tester.scrollUntilVisible(
      connectivityUrlField(),
      200,
      scrollable: settingsScrollView(),
    );
    expect(find.text(ConnectivityCheckSettings.defaultUrl), findsWidgets);
    expect(
      find.text('${ConnectivityCheckSettings.defaultTimeoutMs}'),
      findsWidgets,
    );

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
        connectivityCheckSettings: const ConnectivityCheckSettings(
          url: 'https://example.com/ping',
          timeoutMs: 3200,
        ),
      ),
    );
    await tester.pump();

    expect(find.text('https://example.com/ping'), findsWidgets);
    expect(find.text('3200'), findsWidgets);
  });

  testWidgets('battery optimization card shows restricted action', (
    tester,
  ) async {
    var requested = false;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onRequestBatteryOptimization: () {
          requested = true;
        },
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('battery_optimization_card')),
      200,
      scrollable: settingsScrollView(),
    );

    expect(find.byKey(const Key('battery_optimization_card')), findsOneWidget);
    expect(
      find.byKey(const Key('battery_optimization_refresh_button')),
      findsNothing,
    );
    expect(find.text('Battery optimization'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);

    await tester.ensureVisible(
      find.byKey(const Key('battery_optimization_request_button')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('battery_optimization_request_button')),
    );
    await tester.pump();

    expect(requested, isTrue);
  });

  testWidgets('battery optimization allowed state hides request action', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        batteryOptimizationStatus: const BatteryOptimizationStatus(
          state: BatteryOptimizationState.allowed,
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('battery_optimization_card')),
      200,
      scrollable: settingsScrollView(),
    );

    expect(find.text('Allow'), findsNothing);
    expect(find.text('Allowed for background use.'), findsOneWidget);
  });

  testWidgets('editing connectivity URL emits parsed global settings', (
    tester,
  ) async {
    ConnectivityCheckSettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
        onConnectivityCheckSettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    await tester.scrollUntilVisible(
      connectivityUrlField(),
      200,
      scrollable: settingsScrollView(),
    );
    await tester.enterText(
      connectivityUrlField(),
      'https://example.com/health',
    );
    await tester.pump();

    expect(changed?.url, 'https://example.com/health');
    expect(changed?.timeoutMs, ConnectivityCheckSettings.defaultTimeoutMs);
  });

  testWidgets('editing connectivity timeout emits parsed global settings', (
    tester,
  ) async {
    ConnectivityCheckSettings? changed;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
        onConnectivityCheckSettingsChanged: (value) {
          changed = value;
        },
      ),
    );

    await tester.scrollUntilVisible(
      connectivityTimeoutField(),
      200,
      scrollable: settingsScrollView(),
    );
    await tester.enterText(connectivityTimeoutField(), '3200');
    await tester.pump();

    expect(changed?.url, ConnectivityCheckSettings.defaultUrl);
    expect(changed?.timeoutMs, 3200);
  });

  testWidgets('invalid connectivity URL shows validation error', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    );

    await tester.scrollUntilVisible(
      connectivityUrlField(),
      200,
      scrollable: settingsScrollView(),
    );
    await tester.enterText(connectivityUrlField(), 'ftp://example.com');
    await tester.pump();

    expect(find.text('Only HTTP and HTTPS URLs are supported'), findsOneWidget);
  });

  testWidgets('invalid connectivity timeout shows validation error', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    );

    await tester.scrollUntilVisible(
      connectivityTimeoutField(),
      200,
      scrollable: settingsScrollView(),
    );
    await tester.enterText(connectivityTimeoutField(), '0');
    await tester.pump();

    expect(find.text('Enter a timeout greater than 0 ms'), findsOneWidget);
  });

  testWidgets('L2TP security notice tile is shown and opens callback', (
    tester,
  ) async {
    var opened = false;

    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        onOpenL2tpSecurityNotice: () {
          opened = true;
        },
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('l2tp_security_notice_tile')),
      200,
      scrollable: settingsScrollView(),
    );
    await Scrollable.ensureVisible(
      tester.element(find.byKey(const Key('l2tp_security_notice_tile'))),
      alignment: 0.1,
      duration: Duration.zero,
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('l2tp_security_notice_tile')));
    await tester.pump();

    expect(opened, isTrue);
  });

  testWidgets('connectivity help text stays short and actionable', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        connectionMode: ConnectionMode.vpnTunnel,
      ),
    );

    await tester.scrollUntilVisible(
      connectivityUrlField(),
      200,
      scrollable: settingsScrollView(),
    );

    expect(
      find.textContaining('Used for the status check after you connect'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Tap the badge anytime to refresh'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Maximum time to wait before marking the check unreachable',
      ),
      findsOneWidget,
    );
  });

  testWidgets('update check asks for consent before refreshing', (
    tester,
  ) async {
    var refreshCount = 0;
    await tester.pumpWidget(
      buildPanel(
        proxySettings: const ProxySettings(),
        updateCheckConsentGranted: false,
        onRefreshVersionCheck: () {
          refreshCount += 1;
        },
      ),
    );

    await tester.scrollUntilVisible(
      find.byKey(const Key('settings_update_refresh_button')),
      250,
      scrollable: settingsScrollView(),
    );
    await tester.ensureVisible(
      find.byKey(const Key('settings_update_refresh_button')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('settings_update_refresh_button')));
    await tester.pumpAndSettle();

    expect(refreshCount, 0);
    expect(find.text('Check GitHub releases?'), findsOneWidget);

    await tester.tap(find.text('Check releases'));
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
  });

  testWidgets('language tile opens scalable picker with system default', (
    tester,
  ) async {
    Locale? picked = const Locale('en');
    final theme = ThemeData.light();
    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SettingsPanel(
              selectedLocale: picked,
              onLocaleChanged: (locale) => setState(() => picked = locale),
              connectionMode: ConnectionMode.proxyOnly,
              splitTunnelSettings: const SplitTunnelSettings(),
              proxySettings: const ProxySettings(),
              connectivityCheckSettings: const ConnectivityCheckSettings(),
              batteryOptimizationStatus: const BatteryOptimizationStatus(
                state: BatteryOptimizationState.allowed,
              ),
              batteryOptimizationBusy: false,
              onConnectionModeChanged: (_) {},
              onSplitTunnelSettingsChanged: (_) {},
              onProxySettingsChanged: (_) {},
              onConnectivityCheckSettingsChanged: (_) {},
              onRequestBatteryOptimization: () {},
              onChooseApps: () {},
              updateCheckConsentGranted: true,
              appUpdateStatus: AppUpdateStatus.idle,
              onRefreshVersionCheck: () {},
              onOpenTelegram: () {},
              onOpenGithub: () {},
              routingLocked: false,
              colorScheme: theme.colorScheme,
              textTheme: theme.textTheme,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('settings_language_tile')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('language_option_system')), findsOneWidget);
    expect(find.byKey(const Key('language_option_en')), findsOneWidget);
    expect(find.byKey(const Key('language_option_fa')), findsOneWidget);

    await tester.tap(find.byKey(const Key('language_option_fa')));
    await tester.pumpAndSettle();
    expect(picked, const Locale('fa'));

    await tester.tap(find.byKey(const Key('settings_language_tile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('language_option_system')));
    await tester.pumpAndSettle();
    expect(picked, isNull);
  });
}
