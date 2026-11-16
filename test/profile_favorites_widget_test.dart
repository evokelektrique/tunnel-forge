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

  Future<ProfileStore> seedProfiles(
    List<String> ids, {
    String? lastActiveId,
  }) async {
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
    if (lastActiveId != null) {
      await store.setLastProfileId(lastActiveId);
    }
    return store;
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    installVpnChannelMock(<String>[]);
  });

  tearDown(uninstallVpnChannelMock);

  testWidgets(
    'star sits left of dots, prioritizes first-starred at top with divider, and enforces max 5',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = await seedProfiles([
        'p1',
        'p2',
        'p3',
        'p4',
        'p5',
        'p6',
      ], lastActiveId: 'p1');
      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();

      // Star button sits to the left of the dots button on each profile row.
      final p1Tile = find.byKey(const ValueKey<String>('p1'));
      final p1Star = find.byKey(const Key('favorite_button_p1'));
      final p1Dots = find.descendant(
        of: p1Tile,
        matching: find.byTooltip('Profile actions'),
      );
      expect(
        tester.getCenter(p1Star).dx,
        lessThan(tester.getCenter(p1Dots).dx),
      );
      expect(find.byKey(const Key('favorites_divider')), findsNothing);

      // Star p4 first, then p2 -> p4 stays top, p2 follows, divider appears.
      await tester.tap(find.byKey(const Key('favorite_button_p4')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('favorites_divider')), findsOneWidget);

      await tester.tap(find.byKey(const Key('favorite_button_p2')));
      await tester.pumpAndSettle();

      // Sheet stays open and active profile stays Profile p1.
      expect(find.text('Profiles'), findsOneWidget);
      final p4Y = tester
          .getTopLeft(find.byKey(const ValueKey<String>('p4')))
          .dy;
      final p2Y = tester
          .getTopLeft(find.byKey(const ValueKey<String>('p2')))
          .dy;
      final p1Y = tester
          .getTopLeft(find.byKey(const ValueKey<String>('p1')))
          .dy;
      expect(p4Y, lessThan(p2Y));
      expect(p2Y, lessThan(p1Y));

      final listScrollable = find.descendant(
        of: find.byType(CustomScrollView).last,
        matching: find.byType(Scrollable),
      );
      Future<void> bringIntoView(Finder target, double delta) async {
        await tester.scrollUntilVisible(
          target,
          delta,
          scrollable: listScrollable,
        );
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
      }

      // Star up to 5 profiles (p1, p3, p5).
      await tester.tap(find.byKey(const Key('favorite_button_p1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('favorite_button_p3')));
      await tester.pumpAndSettle();
      final p5FavoriteButton = find.byKey(const Key('favorite_button_p5'));
      await bringIntoView(p5FavoriteButton, 120);
      await tester.tap(p5FavoriteButton);
      await tester.pumpAndSettle();

      // Remaining 6th star is visually dimmed and tapping it shows the limit toast.
      final p6FavoriteButton = find.byKey(const Key('favorite_button_p6'));
      await bringIntoView(p6FavoriteButton, 120);
      final p6StarIcon = tester.widget<Icon>(
        find.descendant(of: p6FavoriteButton, matching: find.byType(Icon)),
      );
      expect(p6StarIcon.icon, Icons.star_border_rounded);
      expect(p6StarIcon.color!.a, lessThan(0.5));

      await tester.tap(p6FavoriteButton);
      await tester.pumpAndSettle();

      expect(find.text('You can favorite up to 5 profiles'), findsOneWidget);
      expect((await store.loadProfiles()).where((p) => p.favorite).length, 5);

      // Unstar p4 -> moves right below remaining favorites (top of non-favorites).
      final p4FavoriteButton = find.byKey(const Key('favorite_button_p4'));
      await bringIntoView(p4FavoriteButton, -120);
      await tester.tap(p4FavoriteButton);
      await tester.pumpAndSettle();
      final afterUnstar = await store.loadProfiles();
      expect(afterUnstar.map((p) => p.id), [
        'p2',
        'p1',
        'p3',
        'p5',
        'p4',
        'p6',
      ]);
      await bringIntoView(find.byKey(const ValueKey<String>('p6')), 120);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey<String>('p4'))).dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey<String>('p6'))).dy,
        ),
      );
      expect(await store.loadLastProfileId(), 'p1');
    },
  );

  testWidgets(
    'multi-select hides star, dots, and drag handles, and reorders sections via body hold',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = await seedProfiles(['p1', 'p2', 'p3', 'p4']);
      await store.toggleProfileFavorite('p3');
      // Now: [p3*, p1, p2, p4] -> 1 favorite (non-reorderable), 3 non-favorites.
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
      expect(find.byKey(const Key('drag_handle_p3')), findsNothing);
      expect(find.byKey(const Key('drag_handle_p1')), findsNothing);

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

      // Quick swipe without holding does not reorder p3.
      final favStep =
          tester.getCenter(find.text('Profile p1')).dy -
          tester.getCenter(find.text('Profile p3')).dy;
      await tester.timedDrag(
        find.text('Profile p3'),
        Offset(0, favStep + 20),
        const Duration(milliseconds: 200),
      );
      await tester.pumpAndSettle();
      expect((await store.loadProfiles()).map((p) => p.id), [
        'p3',
        'p1',
        'p2',
        'p4',
      ]);

      Future<void> dragInSteps(TestGesture activeGesture, Offset delta) async {
        const steps = 6;
        final step = delta / steps.toDouble();
        for (var i = 0; i < steps; i++) {
          await activeGesture.moveBy(step);
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      // Hold p3 body for 550 ms and drag below p1 within favorites.
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
      expect(find.text('1 selected'), findsOneWidget);

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
      // Order: [p3*, p1*, p2, p4].
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

      // Keep holding and move past touch slop to drag p3 below p1 immediately.
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

  testWidgets(
    'quick vertical swipe on profile body scrolls list in multi-select mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(480, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = await seedProfiles([for (var i = 1; i <= 15; i++) 'p$i']);
      await pumpApp(tester, store);

      await tester.tap(find.byKey(const Key('profile_picker_tile')));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Profile p1')),
      );
      await tester.pump(const Duration(seconds: 1));
      await gesture.up();
      await tester.pumpAndSettle();

      final sheetScrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(CustomScrollView).last,
          matching: find.byType(Scrollable),
        ),
      );
      expect(sheetScrollable.position.pixels, 0.0);
      await tester.drag(
        find.byKey(const ValueKey<String>('p2')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      expect(sheetScrollable.position.pixels, greaterThan(100));
      expect((await store.loadProfiles()).map((p) => p.id).first, 'p1');
    },
  );

  testWidgets('editing a favorited profile preserves its favorite state', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = await seedProfiles(['p1', 'p2']);
    await store.toggleProfileFavorite('p2');
    await pumpApp(tester, store);

    await tester.tap(find.byKey(const Key('profile_picker_tile')));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('Profile p2'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile, matching: find.byTooltip('Profile actions')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Profile p2 Edited');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final loaded = await store.loadProfiles();
    expect(loaded.map((p) => p.id), ['p2', 'p1']);
    expect(loaded.first.favorite, isTrue);
    expect(loaded.first.displayName, 'Profile p2 Edited');
  });

  testWidgets('holding favorite star or actions menu does not start hold-to-select', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(480, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = await seedProfiles(['p1', 'p2']);
    await pumpApp(tester, store);

    await tester.tap(find.byKey(const Key('profile_picker_tile')));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text('Profile p1'),
      matching: find.byType(ListTile),
    );
    final holdFill = find.descendant(
      of: find.ancestor(of: tile, matching: find.byType(Stack)).first,
      matching: find.byType(FractionallySizedBox),
    );

    // Short press on favorite star shows no hold fill and toggles favorite on release.
    final starButton = find.byKey(const Key('favorite_button_p1'));
    var gesture = await tester.startGesture(tester.getCenter(starButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(holdFill, findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('multi_select_delete')), findsNothing);
    expect((await store.loadProfiles()).first.favorite, isTrue);

    // Holding favorite star for >1s shows no hold fill and stays out of multi-select.
    gesture = await tester.startGesture(tester.getCenter(starButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(holdFill, findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    expect(holdFill, findsNothing);
    expect(find.byKey(const Key('multi_select_delete')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('multi_select_delete')), findsNothing);

    // Holding three-dots menu for >1s shows no hold fill and stays out of multi-select.
    final actionsButton = find.descendant(
      of: tile,
      matching: find.byTooltip('Profile actions'),
    );
    gesture = await tester.startGesture(tester.getCenter(actionsButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(holdFill, findsNothing);
    await tester.pump(const Duration(milliseconds: 600));
    expect(holdFill, findsNothing);
    expect(find.byKey(const Key('multi_select_delete')), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('multi_select_delete')), findsNothing);

    // Short press on three-dots menu shows no hold fill and opens menu on release.
    gesture = await tester.startGesture(tester.getCenter(actionsButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(holdFill, findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('multi_select_delete')), findsNothing);
    expect(find.text('Edit profile'), findsOneWidget);

    // Dismiss popup menu before verifying tile-body hold still enters multi-select.
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    gesture = await tester.startGesture(
      tester.getCenter(find.text('Profile p1')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(holdFill, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('multi_select_delete')), findsOneWidget);
  });
}
