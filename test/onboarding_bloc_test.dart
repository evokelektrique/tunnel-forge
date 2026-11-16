import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/onboarding/domain/app_exit_controller.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/onboarding/presentation/bloc/onboarding_bloc.dart';

class _FakeOnboardingRepository implements OnboardingRepository {
  _FakeOnboardingRepository({this.version});

  int? version;
  int? savedVersion;

  @override
  Future<int?> loadAcknowledgedVersion() async => version;

  @override
  Future<void> saveAcknowledgedVersion(int version) async {
    savedVersion = version;
    this.version = version;
  }
}

class _FakeAppExitController implements AppExitController {
  int closeCalls = 0;
  final Completer<void> closeCompleter = Completer<void>();

  @override
  Future<void> closeApp() async {
    closeCalls += 1;
    if (!closeCompleter.isCompleted) {
      closeCompleter.complete();
    }
  }
}

void main() {
  group('OnboardingBloc', () {
    blocTest<OnboardingBloc, OnboardingState>(
      'accepts immediately when the stored version matches',
      build: () => OnboardingBloc(
        _FakeOnboardingRepository(version: kCurrentL2tpDisclosureVersion),
        _FakeAppExitController(),
      ),
      act: (bloc) => bloc.add(const OnboardingStarted()),
      expect: () => [
        const OnboardingState(status: OnboardingFlowStatus.accepted),
      ],
    );

    blocTest<OnboardingBloc, OnboardingState>(
      'presents language choice on first launch',
      build: () => OnboardingBloc(
        _FakeOnboardingRepository(),
        _FakeAppExitController(),
        skipDisclosureSteps: false,
      ),
      act: (bloc) => bloc.add(const OnboardingStarted()),
      expect: () => [
        const OnboardingState(status: OnboardingFlowStatus.presenting),
      ],
    );

    test(
      'debug mode skips intro and security notice on continue from language',
      () async {
        final repository = _FakeOnboardingRepository();
        final bloc = OnboardingBloc(repository, _FakeAppExitController());
        addTearDown(bloc.close);

        bloc.add(const OnboardingStarted());
        await Future<void>.delayed(Duration.zero);
        expect(bloc.state.status, OnboardingFlowStatus.presenting);
        expect(bloc.state.step, OnboardingStep.language);
        expect(bloc.state.skipDisclosureSteps, isTrue);

        bloc.add(const OnboardingContinuePressed());
        await Future<void>.delayed(Duration.zero);

        expect(repository.savedVersion, kCurrentL2tpDisclosureVersion);
        expect(bloc.state.status, OnboardingFlowStatus.accepted);
      },
    );

    test(
      'continue moves through intro to acknowledgement and arms countdown',
      () async {
        final bloc = OnboardingBloc(
          _FakeOnboardingRepository(),
          _FakeAppExitController(),
          skipDisclosureSteps: false,
        );
        addTearDown(bloc.close);

        bloc.add(const OnboardingStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const OnboardingContinuePressed());
        await Future<void>.delayed(Duration.zero);
        expect(bloc.state.step, OnboardingStep.intro);

        bloc.add(const OnboardingContinuePressed());
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await Future<void>.delayed(Duration.zero);

        expect(bloc.state.status, OnboardingFlowStatus.presenting);
        expect(bloc.state.step, OnboardingStep.acknowledgement);
        expect(bloc.state.secondsRemaining, 9);
      },
    );

    test('agree requires both checkbox and completed timer', () async {
      final repository = _FakeOnboardingRepository();
      final bloc = OnboardingBloc(
        repository,
        _FakeAppExitController(),
        skipDisclosureSteps: false,
      );
      addTearDown(bloc.close);

      bloc.add(const OnboardingStarted());
      await Future<void>.delayed(Duration.zero);

      bloc.add(const OnboardingCheckboxChanged(true));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.checkboxChecked, isFalse);

      bloc.add(const OnboardingContinuePressed());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OnboardingContinuePressed());
      await Future<void>.delayed(Duration.zero);

      expect(bloc.state.canAgree, isFalse);

      bloc.add(const OnboardingCheckboxChanged(true));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.canAgree, isFalse);

      await Future<void>.delayed(
        const Duration(
          seconds: kOnboardingAgreeCountdownSeconds,
          milliseconds: 100,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.timerComplete, isTrue);
      expect(bloc.state.canAgree, isTrue);

      bloc.add(const OnboardingCheckboxChanged(false));
      await Future<void>.delayed(Duration.zero);
      expect(bloc.state.canAgree, isFalse);
    });

    test(
      'agree saves the acknowledgement version and accepts the flow',
      () async {
        final repository = _FakeOnboardingRepository();
        final bloc = OnboardingBloc(
          repository,
          _FakeAppExitController(),
          skipDisclosureSteps: false,
        );
        addTearDown(bloc.close);

        bloc.add(const OnboardingStarted());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const OnboardingContinuePressed());
        await Future<void>.delayed(Duration.zero);
        bloc.add(const OnboardingContinuePressed());
        await Future<void>.delayed(
          const Duration(
            seconds: kOnboardingAgreeCountdownSeconds,
            milliseconds: 100,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        bloc.add(const OnboardingCheckboxChanged(true));
        await Future<void>.delayed(Duration.zero);
        bloc.add(const OnboardingAgreePressed());
        await Future<void>.delayed(Duration.zero);

        expect(repository.savedVersion, kCurrentL2tpDisclosureVersion);
        expect(bloc.state.status, OnboardingFlowStatus.accepted);
      },
    );

    test('cancel transitions to exiting and closes the app', () async {
      final exitController = _FakeAppExitController();
      final bloc = OnboardingBloc(_FakeOnboardingRepository(), exitController);
      addTearDown(bloc.close);

      bloc.add(const OnboardingStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OnboardingCancelPressed());
      await exitController.closeCompleter.future;

      expect(bloc.state.status, OnboardingFlowStatus.exiting);
      expect(exitController.closeCalls, 1);
    });

    blocTest<OnboardingBloc, OnboardingState>(
      'read-only mode skips timer and checkbox requirements',
      build: () =>
          OnboardingBloc(_FakeOnboardingRepository(), _FakeAppExitController()),
      act: (bloc) => bloc.add(const OnboardingReadOnlyOpened()),
      expect: () => [
        const OnboardingState(
          status: OnboardingFlowStatus.presenting,
          mode: OnboardingMode.readOnly,
          step: OnboardingStep.acknowledgement,
          secondsRemaining: 0,
        ),
      ],
    );

    test('emits DEBUG logs for onboarding transitions and actions', () async {
      final logs = _RecordingLogsRepository();
      final repository = _FakeOnboardingRepository();
      final exitController = _FakeAppExitController();
      final bloc = OnboardingBloc(
        repository,
        exitController,
        skipDisclosureSteps: false,
        logsRepository: logs,
      );
      addTearDown(bloc.close);

      bloc.add(const OnboardingStarted());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OnboardingContinuePressed());
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OnboardingContinuePressed());
      await Future<void>.delayed(
        const Duration(
          seconds: kOnboardingAgreeCountdownSeconds,
          milliseconds: 100,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OnboardingCheckboxChanged(true));
      await Future<void>.delayed(Duration.zero);
      bloc.add(const OnboardingAgreePressed());
      await Future<void>.delayed(Duration.zero);

      expect(logs.entries.every((e) => e.level == LogLevel.debug), isTrue);
      expect(logs.entries.map((e) => e.message), [
        'Onboarding step=language nextStep=intro',
        'Onboarding step=intro nextStep=acknowledgement',
        'Onboarding L2TP disclosure accepted version=$kCurrentL2tpDisclosureVersion',
      ]);

      final cancelLogs = _RecordingLogsRepository();
      final cancelBloc = OnboardingBloc(
        _FakeOnboardingRepository(),
        _FakeAppExitController(),
        logsRepository: cancelLogs,
      );
      addTearDown(cancelBloc.close);
      cancelBloc.add(const OnboardingStarted());
      await Future<void>.delayed(Duration.zero);
      cancelBloc.add(const OnboardingCancelPressed());
      await Future<void>.delayed(Duration.zero);
      expect(
        cancelLogs.entries.single.message,
        'Onboarding cancelled by user step=language',
      );

      final readOnlyLogs = _RecordingLogsRepository();
      final readOnlyBloc = OnboardingBloc(
        _FakeOnboardingRepository(),
        _FakeAppExitController(),
        logsRepository: readOnlyLogs,
      );
      addTearDown(readOnlyBloc.close);
      readOnlyBloc.add(const OnboardingReadOnlyOpened());
      await Future<void>.delayed(Duration.zero);
      expect(
        readOnlyLogs.entries.single.message,
        'Opened L2TP security notice (read-only)',
      );
    });
  });
}

class _RecordingLogsRepository implements LogsRepository {
  final List<LogEntry> _entries = <LogEntry>[];

  @override
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  @override
  Stream<List<LogEntry>> get entriesStream => const Stream.empty();

  @override
  Future<void> loadPersisted() async {}

  @override
  void append(LogEntry entry) => _entries.add(entry);

  @override
  void clear() => _entries.clear();
}
