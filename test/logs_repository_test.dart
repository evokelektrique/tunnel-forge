import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';

import 'support/fake_diagnostics_bridge.dart';

void main() {
  test('parses log tail with continuation lines and fallback lines', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final bridge = FakeDiagnosticsBridge()
      ..tailText = [
        '2026-01-02T03:04:05.123+0000 WARNING native/proxy_lwip first line',
        '\tsecond line',
        'unmatched raw crash note',
      ].join('\n');
    final repository = LogsRepositoryImpl(
      prefsOverride: prefs,
      bridgeOverride: bridge,
    );

    await repository.loadPersisted();

    expect(repository.entries, hasLength(2));
    expect(repository.entries[0].level, LogLevel.warning);
    expect(repository.entries[0].source, LogSource.native);
    expect(repository.entries[0].tag, 'proxy_lwip');
    expect(repository.entries[0].message, 'first line\nsecond line');
    expect(repository.entries[1].level, LogLevel.info);
    expect(repository.entries[1].source, LogSource.kotlin);
    expect(repository.entries[1].tag, 'DiagnosticLog');
    expect(repository.entries[1].message, 'unmatched raw crash note');
  });

  test('migrates valid legacy JSON entries and deletes legacy key', () async {
    SharedPreferences.setMockInitialValues({
      LogsRepositoryImpl.prefsKeyLogsJson: jsonEncode([
        {
          'timestamp': '2026-01-02T03:04:05.000Z',
          'level': 'warning',
          'source': 'native',
          'tag': 'proxy_lwip',
          'message': 'persisted entry',
        },
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final bridge = FakeDiagnosticsBridge();
    final repository = LogsRepositoryImpl(
      prefsOverride: prefs,
      bridgeOverride: bridge,
    );

    await repository.loadPersisted();

    expect(bridge.appendedEntries, hasLength(1));
    expect(
      bridge.appendedEntries.single[DiagnosticsContract.argTs],
      DateTime.parse('2026-01-02T03:04:05.000Z').millisecondsSinceEpoch,
    );
    expect(
      bridge.appendedEntries.single[DiagnosticsContract.argMessage],
      'persisted entry',
    );
    expect(prefs.getString(LogsRepositoryImpl.prefsKeyLogsJson), isNull);
  });

  test(
    'preserves corrupt legacy JSON in a capped entry and keeps key if bridge fails',
    () async {
      final oversized = '{corrupt-${'x' * (260 * 1024)}';
      SharedPreferences.setMockInitialValues({
        LogsRepositoryImpl.prefsKeyLogsJson: oversized,
      });
      final prefs = await SharedPreferences.getInstance();
      final failingBridge = FakeDiagnosticsBridge()
        ..appendError = StateError('disk full');
      final failingRepo = LogsRepositoryImpl(
        prefsOverride: prefs,
        bridgeOverride: failingBridge,
      );

      await failingRepo.loadPersisted();
      expect(prefs.getString(LogsRepositoryImpl.prefsKeyLogsJson), oversized);

      final workingBridge = FakeDiagnosticsBridge();
      final workingRepo = LogsRepositoryImpl(
        prefsOverride: prefs,
        bridgeOverride: workingBridge,
      );
      await workingRepo.loadPersisted();

      expect(workingBridge.appendedEntries, hasLength(1));
      final msg =
          workingBridge.appendedEntries.single[DiagnosticsContract.argMessage]
              as String;
      expect(msg, startsWith('legacy log blob (unparsed): {corrupt-'));
      expect(utf8.encode(msg).length, lessThanOrEqualTo(256 * 1024 + 64));
      expect(prefs.getString(LogsRepositoryImpl.prefsKeyLogsJson), isNull);
    },
  );

  test(
    'coalesces bursts over 200ms, caps at 5000, and forwards only dart entries',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final bridge = FakeDiagnosticsBridge();
      final repository = LogsRepositoryImpl(
        prefsOverride: prefs,
        bridgeOverride: bridge,
      );
      var streamEmits = 0;
      final sub = repository.entriesStream.listen((_) => streamEmits += 1);

      for (var i = 0; i < 5500; i++) {
        repository.append(
          LogEntry(
            timestamp: DateTime(2026, 1, 2, 3, 4, 5),
            level: LogLevel.info,
            source: i.isEven ? LogSource.dart : LogSource.kotlin,
            tag: 'Test',
            message: 'entry-$i',
          ),
        );
      }

      expect(streamEmits, 0);
      expect(bridge.appendedEntries, isEmpty);
      expect(repository.entries, hasLength(5000));
      expect(repository.entries.first.message, 'entry-500');
      expect(repository.entries.last.message, 'entry-5499');

      await Future<void>.delayed(const Duration(milliseconds: 260));

      expect(streamEmits, 1);
      expect(bridge.appendedEntries, hasLength(2750));
      expect(
        bridge.appendedEntries.every(
          (e) => e[DiagnosticsContract.argSource] == 'dart',
        ),
        isTrue,
      );

      repository.clear();
      await Future<void>.delayed(Duration.zero);
      expect(repository.entries, isEmpty);
      expect(bridge.clearCalls, 1);
      await sub.cancel();
      await repository.dispose();
    },
  );
}
