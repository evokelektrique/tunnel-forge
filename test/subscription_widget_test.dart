import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/main.dart';

import 'support/vpn_channel_mock.dart';

class _AcceptedOnboardingRepository implements OnboardingRepository {
  const _AcceptedOnboardingRepository();

  @override
  Future<int?> loadAcknowledgedVersion() async => kCurrentL2tpDisclosureVersion;

  @override
  Future<void> saveAcknowledgedVersion(int version) async {}
}

class _TestSubscriptionBridge extends SubscriptionBridge {
  @override
  Future<void> syncSchedules(List<Subscription> subscriptions) async {}

  @override
  Future<bool> requestNotificationPermission() async => true;

  @override
  Future<SubscriptionFetchRoute> getActiveNetworkRoute() async =>
      const SubscriptionFetchRoute.direct();
}

class _MutableHttpClient implements SubscriptionHttpClient {
  String body =
      'tf://de.example.com?displayName=Germany&user=u1&password=p1&psk=k1\n'
      'tf://nl.example.com?displayName=Netherlands&user=u2&password=p2&psk=k2';

  @override
  Future<String> fetchBody(
    Uri uri, {
    required SubscriptionFetchRoute route,
  }) async => body;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installVpnChannelMock(<String>[]);
  });

  tearDown(uninstallVpnChannelMock);

  testWidgets(
    'adds subscription from + menu, creates Local + Sub tabs, updates, and deletes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final prefs = await SharedPreferences.getInstance();
      final store = ProfileStore(
        prefsOverride: prefs,
        secretsOverride: MemorySecretStore(),
      );
      await store.upsertProfile(
        const Profile(
          id: 'local-1',
          displayName: 'Local VPN',
          server: 'local.example.com',
          user: 'me',
        ),
        password: 'pw',
        psk: 'psk',
      );
      final http = _MutableHttpClient();

      await tester.pumpWidget(
        TunnelForgeApp(
          onboardingRepository: const _AcceptedOnboardingRepository(),
          profileStore: store,
          subscriptionBridge: _TestSubscriptionBridge(),
          subscriptionHttpClient: http,
        ),
      );
      await tester.pumpAndSettle();

      // Open profile picker; with 0 subscriptions, tab bar must stay hidden.
      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('profile_tabs')), findsNothing);
      expect(find.text('Local VPN'), findsWidgets);

      // Open '+' menu and tap "Add a subscription URL".
      await tester.tap(find.byTooltip('Add profile'));
      await tester.pumpAndSettle();
      expect(find.text('Add a subscription URL'), findsOneWidget);
      await tester.tap(find.text('Add a subscription URL'));
      await tester.pumpAndSettle();

      // Fill name, URL, enable Auto-update, select Custom + Minutes, test <15 validation then 15.
      await tester.enterText(
        find.byKey(const Key('subscription_name_field')),
        'My Sub',
      );
      await tester.enterText(
        find.byKey(const Key('subscription_url_field')),
        'https://example.com/sub.txt',
      );
      await tester.tap(
        find.byKey(const Key('subscription_auto_update_checkbox')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('subscription_frequency_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Custom').last);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('subscription_custom_unit_dropdown')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Minutes').last);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('subscription_custom_interval_field')),
        '10',
      );
      await tester.tap(find.byKey(const Key('subscription_save_button')));
      await tester.pumpAndSettle();
      expect(find.text('Minimum interval is 15 minutes'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('subscription_custom_interval_field')),
        '15',
      );
      await tester.tap(find.byKey(const Key('subscription_save_button')));
      await tester.pumpAndSettle();

      // Summary dialog appears showing 2 imported profiles.
      expect(
        find.byKey(const Key('subscription_update_dialog')),
        findsOneWidget,
      );
      expect(find.text('Imported: 2'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('subscription_update_dialog_close')),
      );
      await tester.pumpAndSettle();

      // Tabs now appear: "Local" and "My Sub", with "My Sub" selected.
      expect(find.byKey(const Key('profile_tabs')), findsOneWidget);
      expect(find.byKey(const Key('profile_tab_local')), findsOneWidget);
      expect(find.text('My Sub'), findsOneWidget);
      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('Netherlands'), findsOneWidget);
      expect(find.textContaining('Updated '), findsOneWidget);

      final subId = (await store.loadSubscriptions()).single.id;

      // Manual refresh with NO changes shows dismissible dialog saying "No changes.".
      await tester.tap(
        find.byKey(ValueKey<String>('subscription_refresh_$subId')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('subscription_update_dialog')),
        findsOneWidget,
      );
      expect(find.text('No changes.'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('subscription_update_dialog_close')),
      );
      await tester.pumpAndSettle();

      // Manual refresh WITH changes shows Imported: 1, Updated: 1, Removed: 1.
      http.body =
          'tf://de.example.com?displayName=Germany+Fast&user=u1&password=p1&psk=k1\n'
          'tf://jp.example.com?displayName=Japan&user=u3&password=p3&psk=k3';
      await tester.tap(
        find.byKey(ValueKey<String>('subscription_refresh_$subId')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Imported: 1'), findsOneWidget);
      expect(find.text('Updated: 1'), findsOneWidget);
      expect(find.text('Removed: 1'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('subscription_update_dialog_close')),
      );
      await tester.pumpAndSettle();

      // Delete subscription via tab overflow menu -> tab bar disappears again.
      await tester.tap(
        find.byKey(ValueKey<String>('subscription_actions_$subId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete subscription'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile_tabs')), findsNothing);
      expect(find.text('Local VPN'), findsWidgets);
    },
  );
}
