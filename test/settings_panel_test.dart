import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/settings_panel.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';

void main() {
  Finder settingsScrollView() => find.byType(Scrollable).first;

  Widget buildPanel({
    required ProxySettings proxySettings,
    bool updateCheckConsentGranted = true,
    ValueChanged<ProxySettings>? onProxySettingsChanged,
    ProxyPortAvailabilityChecker? onCheckProxyPortAvailable,
    VoidCallback? onRefreshVersionCheck,
  }) {
    final theme = ThemeData.light();
    return MaterialApp(
      home: Scaffold(
        body: SettingsPanel(
          selectedLocale: const Locale('en'),
          onLocaleChanged: (_) {},
          themeMode: ThemeMode.light,
          onThemeModeChanged: (_) {},
          connectionMode: ConnectionMode.proxyOnly,
          splitTunnelSettings: const SplitTunnelSettings(),
          proxySettings: proxySettings,
          connectivityCheckSettings: const ConnectivityCheckSettings(),
          batteryOptimizationStatus: const BatteryOptimizationStatus(
            state: BatteryOptimizationState.restricted,
          ),
          batteryOptimizationBusy: false,
          onConnectionModeChanged: (_) {},
          onSplitTunnelSettingsChanged: (_) {},
          onProxySettingsChanged: onProxySettingsChanged ?? (_) {},
          onCheckProxyPortAvailable: onCheckProxyPortAvailable,
          onConnectivityCheckSettingsChanged: (_) {},
          onRequestBatteryOptimization: () {},
          onChooseApps: () {},
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
}
