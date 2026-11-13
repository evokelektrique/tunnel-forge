import 'dart:async';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/tunnel_error_dialog.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_failure.dart';

void main() {
  testWidgets('copies error details, exports immediately, and closes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const failure = TunnelFailure(
      namespace: 'mschap',
      code: '691',
      detail: 'PPP failed',
    );
    String? copied;
    final export = Completer<void>();
    var exports = 0;
    var copyFails = false;
    var exportFails = false;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          if (copyFails) throw PlatformException(code: 'clipboard_unavailable');
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TunnelErrorDialog(
                failure: failure,
                onExportLogs: () {
                  exports++;
                  if (exportFails) throw StateError('Share unavailable');
                  return export.future;
                },
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text(failure.label), findsOneWidget);
    expect(find.text(failure.codeLabel), findsOneWidget);
    expect(find.byTooltip('Copy error details'), findsOneWidget);
    expect(find.byTooltip('Export logs'), findsOneWidget);
    final closeRect = tester.getRect(find.widgetWithText(TextButton, 'Close'));
    final copyRect = tester.getRect(find.byTooltip('Copy error details'));
    final exportRect = tester.getRect(find.byTooltip('Export logs'));
    expect(closeRect.right, lessThan(copyRect.left));
    expect(copyRect.right, lessThanOrEqualTo(exportRect.left));
    expect(closeRect.center.dy, copyRect.center.dy);
    expect(find.text('PPP failed').hitTestable(), findsNothing);
    await tester.ensureVisible(find.text('Error details'));
    await tester.tap(find.text('Error details'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('PPP failed'));
    expect(find.text('PPP failed').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Copy error details'));
    await tester.pumpAndSettle();
    expect(copied, failure.copyText);
    expect(
      find.descendant(
        of: find.byKey(const Key('app_toast')),
        matching: find.text('Error details copied'),
      ),
      findsOneWidget,
    );
    copyFails = true;
    await tester.tap(find.byTooltip('Copy error details'));
    await tester.pumpAndSettle();
    expect(find.text('Could not copy error details'), findsOneWidget);
    await tester.tap(find.byTooltip('Export logs'));
    await tester.pump();
    expect(exports, 1);
    expect(
      find.descendant(
        of: find.byKey(const Key('app_toast')),
        matching: find.text('Preparing logs...'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Export logs'));
    expect(exports, 1);
    export.complete();
    await tester.pumpAndSettle();
    exportFails = true;
    await tester.tap(find.byTooltip('Export logs'));
    await tester.pumpAndSettle();
    expect(find.text('Could not export logs'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(TunnelErrorDialog), findsNothing);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(TunnelErrorDialog), findsNothing);
  });
}
