import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tunnel_forge/features/app_selector/presentation/pages/app_selector_page.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';

void main() {
  testWidgets('filter apps and return the edited split-tunnel selection', (
    tester,
  ) async {
    Set<String>? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selection = await Navigator.of(context).push(
                  MaterialPageRoute<Set<String>>(
                    builder: (_) => AppSelectorPage(
                      title: 'Split tunneling',
                      initialSelection: const {'mail.pkg'},
                      loadApps: () async => const [
                        CandidateApp(packageName: 'mail.pkg', label: 'Mail'),
                        CandidateApp(packageName: 'maps.pkg', label: 'Maps'),
                      ],
                      loadIcon: (_) async => null,
                    ),
                  ),
                );
              },
              child: const Text('Choose apps'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Choose apps'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'map');
    await tester.pumpAndSettle();
    expect(find.text('Mail'), findsNothing);
    expect(find.widgetWithText(SwitchListTile, 'Maps'), findsOneWidget);

    await tester.tap(find.text('Maps'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(selection, {'mail.pkg', 'maps.pkg'});
  });
}
