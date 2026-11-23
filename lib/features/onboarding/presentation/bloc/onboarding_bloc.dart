import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import '../../domain/onboarding_repository.dart';

const int kOnboardingAgreeCountdownSeconds = 10;

enum OnboardingFlowStatus { loading, presenting, accepted }

enum OnboardingMode { blockingFirstLaunch, readOnly }

enum OnboardingStep { language, intro, acknowledgement }

sealed class OnboardingEvent extends Equatable {
  const OnboardingEvent();

  @override
  List<Object?> get props => const [];
}

final class OnboardingStarted extends OnboardingEvent {
  const OnboardingStarted();
}

final class OnboardingReadOnlyOpened extends OnboardingEvent {
  const OnboardingReadOnlyOpened();
}

final class OnboardingContinuePressed extends OnboardingEvent {
  const OnboardingContinuePressed();
}

final class OnboardingCheckboxChanged extends OnboardingEvent {
  const OnboardingCheckboxChanged(this.checked);

  final bool checked;

  @override
  List<Object?> get props => [checked];
}

final class OnboardingAgreePressed extends OnboardingEvent {
  const OnboardingAgreePressed();
}

final class _OnboardingTimerTicked extends OnboardingEvent {
  const _OnboardingTimerTicked(this.secondsRemaining);

  final int secondsRemaining;

  @override
  List<Object?> get props => [secondsRemaining];
}

class OnboardingState extends Equatable {
  const OnboardingState({
    this.status = OnboardingFlowStatus.loading,
    this.mode = OnboardingMode.blockingFirstLaunch,
    this.step = OnboardingStep.language,
    this.checkboxChecked = false,
    this.secondsRemaining = kOnboardingAgreeCountdownSeconds,
    this.skipDisclosureSteps = false,
  });

  final OnboardingFlowStatus status;
  final OnboardingMode mode;
  final OnboardingStep step;
  final bool checkboxChecked;
  final int secondsRemaining;
  final bool skipDisclosureSteps;

  bool get timerComplete => secondsRemaining <= 0;
  bool get isBlocking => mode == OnboardingMode.blockingFirstLaunch;
  bool get isReadOnly => mode == OnboardingMode.readOnly;
  bool get isPresenting => status == OnboardingFlowStatus.presenting;
  bool get canAgree =>
      isBlocking &&
      step == OnboardingStep.acknowledgement &&
      checkboxChecked &&
      timerComplete &&
      status == OnboardingFlowStatus.presenting;

  OnboardingState copyWith({
    OnboardingFlowStatus? status,
    OnboardingMode? mode,
    OnboardingStep? step,
    bool? checkboxChecked,
    int? secondsRemaining,
    bool? skipDisclosureSteps,
  }) {
    return OnboardingState(
      status: status ?? this.status,
      mode: mode ?? this.mode,
      step: step ?? this.step,
      checkboxChecked: checkboxChecked ?? this.checkboxChecked,
      secondsRemaining: secondsRemaining ?? this.secondsRemaining,
      skipDisclosureSteps: skipDisclosureSteps ?? this.skipDisclosureSteps,
    );
  }

  @override
  List<Object?> get props => [
    status,
    mode,
    step,
    checkboxChecked,
    secondsRemaining,
    skipDisclosureSteps,
  ];
}

class OnboardingBloc extends Bloc<OnboardingEvent, OnboardingState> {
  OnboardingBloc(
    this._repository, {
    bool? skipDisclosureSteps,
    LogsRepository? logsRepository,
  }) : _skipDisclosureSteps = skipDisclosureSteps ?? kDebugMode,
       _logsRepository = logsRepository,
       super(const OnboardingState()) {
    on<OnboardingStarted>(_onStarted);
    on<OnboardingReadOnlyOpened>(_onReadOnlyOpened);
    on<OnboardingContinuePressed>(_onContinuePressed);
    on<OnboardingCheckboxChanged>(_onCheckboxChanged);
    on<OnboardingAgreePressed>(_onAgreePressed);
    on<_OnboardingTimerTicked>(_onTimerTicked);
  }

  final OnboardingRepository _repository;
  final bool _skipDisclosureSteps;
  final LogsRepository? _logsRepository;
  StreamSubscription<int>? _countdownSubscription;

  void _logDebug(String message) {
    _logsRepository?.logDart(LogLevel.debug, 'onboarding', message);
  }

  Future<void> _onStarted(
    OnboardingStarted event,
    Emitter<OnboardingState> emit,
  ) async {
    final version = await _repository.loadAcknowledgedVersion();
    if (version == kCurrentL2tpDisclosureVersion) {
      emit(state.copyWith(status: OnboardingFlowStatus.accepted));
      return;
    }
    emit(
      state.copyWith(
        status: OnboardingFlowStatus.presenting,
        mode: OnboardingMode.blockingFirstLaunch,
        step: OnboardingStep.language,
        checkboxChecked: false,
        secondsRemaining: kOnboardingAgreeCountdownSeconds,
        skipDisclosureSteps: _skipDisclosureSteps,
      ),
    );
  }

  Future<void> _onReadOnlyOpened(
    OnboardingReadOnlyOpened event,
    Emitter<OnboardingState> emit,
  ) async {
    await _stopCountdown();
    _logDebug('Opened L2TP security notice (read-only)');
    emit(
      state.copyWith(
        status: OnboardingFlowStatus.presenting,
        mode: OnboardingMode.readOnly,
        step: OnboardingStep.acknowledgement,
        checkboxChecked: false,
        secondsRemaining: 0,
      ),
    );
  }

  Future<void> _onContinuePressed(
    OnboardingContinuePressed event,
    Emitter<OnboardingState> emit,
  ) async {
    if (!state.isBlocking) return;
    if (state.step == OnboardingStep.language) {
      if (_skipDisclosureSteps) {
        await _repository.saveAcknowledgedVersion(
          kCurrentL2tpDisclosureVersion,
        );
        _logDebug(
          'Onboarding completed from language step (disclosure skipped)',
        );
        emit(state.copyWith(status: OnboardingFlowStatus.accepted));
        return;
      }
      _logDebug('Onboarding step=language nextStep=intro');
      emit(state.copyWith(step: OnboardingStep.intro));
      return;
    }
    if (state.step != OnboardingStep.intro) return;
    _logDebug('Onboarding step=intro nextStep=acknowledgement');
    emit(
      state.copyWith(
        step: OnboardingStep.acknowledgement,
        checkboxChecked: false,
        secondsRemaining: kOnboardingAgreeCountdownSeconds,
      ),
    );
    _startCountdown();
  }

  void _onCheckboxChanged(
    OnboardingCheckboxChanged event,
    Emitter<OnboardingState> emit,
  ) {
    if (!state.isBlocking || state.step != OnboardingStep.acknowledgement) {
      return;
    }
    emit(state.copyWith(checkboxChecked: event.checked));
  }

  Future<void> _onAgreePressed(
    OnboardingAgreePressed event,
    Emitter<OnboardingState> emit,
  ) async {
    if (!state.canAgree) return;
    await _repository.saveAcknowledgedVersion(kCurrentL2tpDisclosureVersion);
    await _stopCountdown();
    _logDebug(
      'Onboarding L2TP disclosure accepted version=$kCurrentL2tpDisclosureVersion',
    );
    emit(state.copyWith(status: OnboardingFlowStatus.accepted));
  }

  void _onTimerTicked(
    _OnboardingTimerTicked event,
    Emitter<OnboardingState> emit,
  ) {
    if (!state.isBlocking || state.step != OnboardingStep.acknowledgement) {
      return;
    }
    emit(state.copyWith(secondsRemaining: event.secondsRemaining));
  }

  void _startCountdown() {
    _countdownSubscription?.cancel();
    _countdownSubscription =
        Stream<int>.periodic(
          const Duration(seconds: 1),
          (tick) => kOnboardingAgreeCountdownSeconds - tick - 1,
        ).take(kOnboardingAgreeCountdownSeconds).listen((secondsRemaining) {
          add(_OnboardingTimerTicked(secondsRemaining));
        });
  }

  Future<void> _stopCountdown() async {
    await _countdownSubscription?.cancel();
    _countdownSubscription = null;
  }

  @override
  Future<void> close() async {
    await _stopCountdown();
    return super.close();
  }
}
