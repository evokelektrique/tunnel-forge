import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tunnel_forge/features/app_selector/presentation/pages/app_selector_page.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';

final Uint8List _pngA = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);
final Uint8List _pngB = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=',
);

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

  testWidgets(
    'updates icon when filtered slot changes and clears cache on dispose',
    (tester) async {
      var loadCount = 0;
      Future<Uint8List?> loadIcon(String pkg) async {
        loadCount++;
        return pkg == 'aaa.pkg' ? _pngA : _pngB;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute<Set<String>>(
                      builder: (_) => AppSelectorPage(
                        title: 'Split tunneling',
                        initialSelection: const {},
                        loadApps: () async => const [
                          CandidateApp(packageName: 'aaa.pkg', label: 'Alpha'),
                          CandidateApp(packageName: 'zzz.pkg', label: 'Zeta'),
                        ],
                        loadIcon: loadIcon,
                      ),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(
        (tester
                    .widget<CircleAvatar>(find.byType(CircleAvatar).first)
                    .backgroundImage
                as MemoryImage?)
            ?.bytes,
        equals(_pngA),
      );

      await tester.enterText(find.byType(TextField), 'Zeta');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(SwitchListTile, 'Zeta'), findsOneWidget);
      expect(
        (tester
                    .widget<CircleAvatar>(find.byType(CircleAvatar).first)
                    .backgroundImage
                as MemoryImage?)
            ?.bytes,
        equals(_pngB),
      );

      final loadsBeforePop = loadCount;
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(loadCount, greaterThan(loadsBeforePop));
    },
  );
}
