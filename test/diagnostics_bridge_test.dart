import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/app/app.dart';
import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';

import 'support/fake_diagnostics_bridge.dart';

FakeDiagnosticsBridge _installFakeErrorHooks({Object? appendError}) {
  final previousBridge = DiagnosticsBridge.instance;
  final previousFlutterError = FlutterError.onError;
  final previousPlatformError = PlatformDispatcher.instance.onError;
  final previousDebugPrint = debugPrint;
  final fake = FakeDiagnosticsBridge()..appendError = appendError;
  DiagnosticsBridge.instance = fake;
  // Silence expected error/stack prints from the global hooks under test.
  debugPrint = (String? message, {int? wrapWidth}) {};
  addTearDown(() {
    debugPrint = previousDebugPrint;
    DiagnosticsBridge.instance = previousBridge;
    FlutterError.onError = previousFlutterError;
    PlatformDispatcher.instance.onError = previousPlatformError;
  });
  installGlobalErrorHooks();
  return fake;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'installGlobalErrorHooks forwards FlutterError and PlatformDispatcher errors to bridge',
    () async {
      final fake = _installFakeErrorHooks();

      FlutterError.onError!(
        FlutterErrorDetails(
          exception: StateError('boom-ui'),
          stack: StackTrace.current,
        ),
      );
      final handled = PlatformDispatcher.instance.onError!(
        ArgumentError('boom-async'),
        StackTrace.current,
      );
      await pumpEventQueue();

      expect(handled, isTrue);
      expect(fake.appendedEntries, hasLength(2));
      expect(
        fake.appendedEntries[0][DiagnosticsContract.argTag],
        'FlutterError',
      );
      expect(
        fake.appendedEntries[0][DiagnosticsContract.argMessage].toString(),
        contains('boom-ui'),
      );
      expect(
        fake.appendedEntries[1][DiagnosticsContract.argTag],
        'PlatformDispatcher',
      );
      expect(
        fake.appendedEntries[1][DiagnosticsContract.argMessage].toString(),
        contains('boom-async'),
      );
    },
  );

  test('installGlobalErrorHooks swallows bridge failures', () async {
    _installFakeErrorHooks(appendError: Exception('ipc down'));
    final handled = PlatformDispatcher.instance.onError!(
      StateError('still-handled'),
      StackTrace.current,
    );
    await pumpEventQueue();

    expect(handled, isTrue);
  });

  test(
    'MethodChannelDiagnosticsBridge calls tunnel_forge/diagnostics channel',
    () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel(DiagnosticsContract.channel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return switch (call.method) {
              DiagnosticsContract.readLogTail => 'tail-line',
              DiagnosticsContract.hasTombstone => true,
              DiagnosticsContract.exportLogs => <String>['/tmp/a.txt'],
              _ => null,
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final bridge = MethodChannelDiagnosticsBridge();
      await bridge.appendLogs(<Map<String, Object?>>[
        <String, Object?>{
          'ts': 1,
          'level': 'info',
          'source': 'dart',
          'tag': 'T',
          'message': 'M',
        },
      ]);
      expect(await bridge.readLogTail(maxLines: 100), 'tail-line');
      expect(await bridge.hasTombstone(), isTrue);
      expect(await bridge.exportLogs(includeTombstone: true), <String>[
        '/tmp/a.txt',
      ]);
      await bridge.clearLogs();

      expect(calls.map((c) => c.method).toList(), <String>[
        DiagnosticsContract.appendLogs,
        DiagnosticsContract.readLogTail,
        DiagnosticsContract.hasTombstone,
        DiagnosticsContract.exportLogs,
        DiagnosticsContract.clearLogs,
      ]);
    },
  );
}
