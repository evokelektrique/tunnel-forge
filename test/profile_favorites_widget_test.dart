import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/main.dart';

import 'support/vpn_channel_mock.dart';

class _AcceptedOnboardingRepository implements OnboardingRepository {
  const _AcceptedOnboardingRepository();

  @override
  Future<int?> loadAcknowledgedVersion() async => kCurrentL2tpDisclosureVersion;

  @override
  Future<void> saveAcknowledgedVersion(int version) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpApp(WidgetTester tester, ProfileStore store) async {
    await tester.pumpWidget(
      TunnelForgeApp(
        onboardingRepository: const _AcceptedOnboardingRepository(),
        profileStore: store,
      ),
    );
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<ProfileStore> seedProfiles(List<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear();
    final store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );
    for (final id in ids) {
      await store.upsertProfile(
        Profile(
          id: id,
          displayName: 'Profile $id',
          server: '$id.example.com',
          user: 'alice',
        ),
        password: 'pw',
        psk: '',
      );
    }
    return store;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installVpnChannelMock(<String>[]);
  });

  tearDown(uninstallVpnChannelMock);

  testWidgets(
    'multi-select hides star, dots, and drag handles, and reorders sections via body hold',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = await seedProfiles(['p1', 'p2', 'p3', 'p4']);
      await store.toggleProfileFavorite('p3');
      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();

      var gesture = await tester.startGesture(
        tester.getCenter(find.text('Profile p3')),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('favorite_button_p3')), findsNothing);
      expect(find.byTooltip('Profile actions'), findsNothing);
      expect(find.byIcon(Icons.drag_handle), findsNothing);

      // Single-item favorites section ignores hold-to-drag.
      gesture = await tester.startGesture(
        tester.getCenter(find.text('Profile p3')),
      );
      await tester.pump(const Duration(milliseconds: 550));
      await gesture.moveBy(const Offset(0, 80));
      await gesture.up();
      await tester.pumpAndSettle();
      expect((await store.loadProfiles()).map((p) => p.id), [
        'p3',
        'p1',
        'p2',
        'p4',
      ]);

      // Exit multi-select, star p1 so favorites has 2 items: [p3*, p1*, p2, p4].
      await tester.tap(find.byKey(const Key('multi_select_close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite_button_p1')));
      await tester.pumpAndSettle();

      gesture = await tester.startGesture(
        tester.getCenter(find.text('Profile p3')),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      Future<void> dragInSteps(TestGesture activeGesture, Offset delta) async {
        const steps = 6;
        final step = delta / steps.toDouble();
        for (var i = 0; i < steps; i++) {
          await activeGesture.moveBy(step);
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      // Hold p3 body for 550 ms and drag below p1 within favorites.
      final favStep =
          tester.getCenter(find.text('Profile p1')).dy -
          tester.getCenter(find.text('Profile p3')).dy;
      gesture = await tester.startGesture(
        tester.getCenter(find.text('Profile p3')),
      );
      await tester.pump(const Duration(milliseconds: 550));
      await dragInSteps(gesture, Offset(0, favStep + 20));
      await gesture.up();
      await tester.pumpAndSettle();

      expect((await store.loadProfiles()).map((p) => p.id), [
        'p1',
        'p3',
        'p2',
        'p4',
      ]);

      // Hold unchecked p4 body for 550 ms and drag above p2 within non-favorites.
      final otherStep =
          tester.getCenter(find.byKey(const ValueKey<String>('p2'))).dy -
          tester.getCenter(find.byKey(const ValueKey<String>('p4'))).dy;
      gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey<String>('p4'))),
      );
      await tester.pump(const Duration(milliseconds: 550));
      await dragInSteps(gesture, Offset(0, otherStep - 20));
      await gesture.up();
      await tester.pumpAndSettle();

      expect((await store.loadProfiles()).map((p) => p.id), [
        'p1',
        'p3',
        'p4',
        'p2',
      ]);
      expect(find.text('1 selected'), findsOneWidget);
    },
  );

  testWidgets(
    'continuous 1-second hold enters multi-select and drags without lifting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = await seedProfiles(['p1', 'p2', 'p3', 'p4']);
      await store.toggleProfileFavorite('p3');
      await store.toggleProfileFavorite('p1');
      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();

      final favStep =
          tester.getCenter(find.text('Profile p1')).dy -
          tester.getCenter(find.text('Profile p3')).dy;

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Profile p3')),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1 selected'), findsOneWidget);

      const steps = 6;
      final step = Offset(0, favStep + 20) / steps.toDouble();
      for (var i = 0; i < steps; i++) {
        await gesture.moveBy(step);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect((await store.loadProfiles()).map((p) => p.id), [
        'p1',
        'p3',
        'p2',
        'p4',
      ]);
      expect(find.text('1 selected'), findsOneWidget);
    },
  );
}
