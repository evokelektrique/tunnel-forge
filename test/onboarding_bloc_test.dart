import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  group('OnboardingBloc', () {
    blocTest<OnboardingBloc, OnboardingState>(
      'accepts immediately when the stored version matches',
      build: () => OnboardingBloc(
        _FakeOnboardingRepository(version: kCurrentL2tpDisclosureVersion),
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
        final bloc = OnboardingBloc(repository);
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
      final bloc = OnboardingBloc(repository, skipDisclosureSteps: false);
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
        final bloc = OnboardingBloc(repository, skipDisclosureSteps: false);
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

    blocTest<OnboardingBloc, OnboardingState>(
      'read-only mode skips timer and checkbox requirements',
      build: () => OnboardingBloc(_FakeOnboardingRepository()),
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
  });
}
