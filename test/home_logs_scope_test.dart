import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/app/di/injection.dart';
import 'package:tunnel_forge/app/theme/app_theme.dart';
import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/app_theme/presentation/bloc/app_theme_bloc.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/pages/home_page.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/connection_panel.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

import 'support/fake_diagnostics_bridge.dart';
import 'support/vpn_channel_mock.dart';

class _CappedStreamLogsRepository implements LogsRepository {
  _CappedStreamLogsRepository(List<LogEntry> initial)
    : _entries = List<LogEntry>.from(initial);

  static const int _maxEntries = 5000;
  final List<LogEntry> _entries;
  final StreamController<List<LogEntry>> _controller =
      StreamController<List<LogEntry>>.broadcast();

  @override
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  @override
  Stream<List<LogEntry>> get entriesStream => _controller.stream;

  @override
  Future<void> loadPersisted() async {}

  @override
  void append(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > _maxEntries) {
      _entries.removeRange(0, _entries.length - _maxEntries);
    }
    _controller.add(entries);
  }

  @override
  void clear() {
    _entries.clear();
    _controller.add(entries);
  }

  Future<void> close() => _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DiagnosticsBridge.instance = FakeDiagnosticsBridge();
    installVpnChannelMock(<String>[]);
  });

  tearDown(() {
    uninstallVpnChannelMock();
    DiagnosticsBridge.instance = MethodChannelDiagnosticsBridge();
  });

  Future<({_CappedStreamLogsRepository logs, AppLanguageController lang})>
  pumpHome(WidgetTester tester, {required int initialCount}) async {
    SharedPreferences.setMockInitialValues({});
    final initial = List<LogEntry>.generate(
      initialCount,
      (i) => LogEntry(
        timestamp: DateTime.utc(2026, 1, 1, 0, 0, i % 60),
        level: LogLevel.info,
        source: LogSource.dart,
        tag: 'test',
        message: 'line-$i',
      ),
    );
    final logs = _CappedStreamLogsRepository(initial);
    final locator = createAppLocator(
      profileStore: ProfileStore(secretsOverride: MemorySecretStore()),
    );
    await locator.unregister<LogsRepository>();
    locator.registerSingleton<LogsRepository>(logs);
    final lang = AppLanguageController();
    addTearDown(() async {
      await logs.close();
      disposeLocator(locator);
      lang.dispose();
    });

    await tester.pumpWidget(
      AppLanguageScope(
        controller: lang,
        child: BlocProvider<AppThemeBloc>(
          create: (_) => locator<AppThemeBloc>()..add(const AppThemeStarted()),
          child: MaterialApp(
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            theme: appTheme(Brightness.light),
            home: VpnHomePage(locator: locator),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return (logs: logs, lang: lang);
  }

  testWidgets(
    'connection tab does not rebuild when LogsBloc receives entries',
    (tester) async {
      final env = await pumpHome(tester, initialCount: 1);
      final beforePanel = tester.widget<ConnectionPanel>(
        find.byType(ConnectionPanel),
      );

      env.logs.append(
        LogEntry(
          timestamp: DateTime.utc(2026, 1, 1, 0, 1, 0),
          level: LogLevel.info,
          source: LogSource.dart,
          tag: 'test',
          message: 'new-log-entry',
        ),
      );
      await tester.pump();
      await tester.pump();

      final afterPanel = tester.widget<ConnectionPanel>(
        find.byType(ConnectionPanel),
      );
      expect(identical(beforePanel, afterPanel), isTrue);
    },
  );

  testWidgets('logs tab auto-scrolls on entry 5001 when buffer stays at 5000', (
    tester,
  ) async {
    final env = await pumpHome(tester, initialCount: 5000);
    await tester.tap(find.byIcon(Icons.article_outlined));
    await tester.pumpAndSettle();

    final listViewFinder = find.byType(ListView);
    expect(listViewFinder, findsOneWidget);
    final controller = tester.widget<ListView>(listViewFinder).controller!;
    expect(
      controller.position.pixels,
      equals(controller.position.maxScrollExtent),
    );

    env.logs.append(
      LogEntry(
        timestamp: DateTime.utc(2026, 1, 1, 0, 5, 0),
        level: LogLevel.info,
        source: LogSource.dart,
        tag: 'test',
        message: List<String>.filled(8, 'overflow-wrap-entry-5001').join('\n'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      controller.position.pixels,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1.0),
    );
  });
}
