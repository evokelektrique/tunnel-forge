import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/connection_panel.dart';
import '../../../home/domain/log_redaction.dart';
import '../../../home/domain/home_repositories.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';

sealed class ConnectivityEvent extends Equatable {
  const ConnectivityEvent();

  @override
  List<Object?> get props => const [];
}

final class ConnectivityResetRequested extends ConnectivityEvent {
  const ConnectivityResetRequested();
}

final class ConnectivityRunRequested extends ConnectivityEvent {
  const ConnectivityRunRequested(this.request);

  final ConnectivityPingRequest request;

  @override
  List<Object?> get props => [request];
}

class ConnectivityState extends Equatable {
  const ConnectivityState({
    this.badgeState = ConnectivityBadgeState.idle,
    this.latencyMs,
    this.runId = 0,
  });

  final ConnectivityBadgeState badgeState;
  final int? latencyMs;
  final int runId;

  String get badgeLabel {
    return switch (badgeState) {
      ConnectivityBadgeState.idle => 'Tap to check',
      ConnectivityBadgeState.checking => 'Checking...',
      ConnectivityBadgeState.success => '${latencyMs ?? 0} ms',
      ConnectivityBadgeState.failure => 'Unreachable',
    };
  }

  ConnectivityState copyWith({
    ConnectivityBadgeState? badgeState,
    int? latencyMs,
    int? runId,
    bool clearLatency = false,
  }) {
    return ConnectivityState(
      badgeState: badgeState ?? this.badgeState,
      latencyMs: clearLatency ? null : (latencyMs ?? this.latencyMs),
      runId: runId ?? this.runId,
    );
  }

  @override
  List<Object?> get props => [badgeState, latencyMs, runId];
}

class ConnectivityBloc extends Bloc<ConnectivityEvent, ConnectivityState> {
  ConnectivityBloc(this._connectivityRepository, this._logsRepository)
    : super(const ConnectivityState()) {
    on<ConnectivityResetRequested>(_onResetRequested);
    on<ConnectivityRunRequested>(_onRunRequested);
  }

  final ConnectivityRepository _connectivityRepository;
  final LogsRepository _logsRepository;
  Completer<void>? _activeCancel;
  int _runId = 0;

  void _cancelActiveRun({bool logCancellation = false}) {
    final activeCancel = _activeCancel;
    _activeCancel = null;
    if (activeCancel != null && !activeCancel.isCompleted) {
      activeCancel.complete();
      if (logCancellation) {
        _log(
          LogLevel.debug,
          'Connectivity check cancelled',
          tag: 'connectivity',
        );
      }
    }
  }

  void _onResetRequested(
    ConnectivityResetRequested event,
    Emitter<ConnectivityState> emit,
  ) {
    _runId++;
    _cancelActiveRun();
    emit(const ConnectivityState());
  }

  Future<void> _onRunRequested(
    ConnectivityRunRequested event,
    Emitter<ConnectivityState> emit,
  ) async {
    final runId = ++_runId;
    _cancelActiveRun(logCancellation: true);
    final cancel = Completer<void>();
    _activeCancel = cancel;

    emit(
      state.copyWith(
        badgeState: ConnectivityBadgeState.checking,
        clearLatency: true,
        runId: runId,
      ),
    );
    _log(
      LogLevel.debug,
      'Connectivity check: ${event.request.url}'
      '${event.request.route == ConnectivityPingRoute.direct ? ' via direct' : ' via proxy ${event.request.proxyHost}:${event.request.proxyPort}'}',
      tag: 'connectivity',
    );

    final ConnectivityPingResult? result;
    try {
      result = await Future.any<ConnectivityPingResult?>([
        _connectivityRepository.ping(
          event.request,
          cancelSignal: cancel.future,
        ),
        cancel.future.then<ConnectivityPingResult?>((_) => null),
      ]);
    } finally {
      if (identical(_activeCancel, cancel)) {
        _activeCancel = null;
      }
    }
    if (cancel.isCompleted || runId != _runId || emit.isDone || result == null) {
      return;
    }

    if (result.reachable && result.latencyMs != null) {
      emit(
        state.copyWith(
          badgeState: ConnectivityBadgeState.success,
          latencyMs: result.latencyMs,
        ),
      );
      _log(
        LogLevel.info,
        'Connectivity OK: ${result.latencyMs} ms'
        '${result.setupMs == null ? '' : ' setup=${result.setupMs} ms'}'
        '${result.totalMs == null ? '' : ' total=${result.totalMs} ms'}'
        '${result.statusCode == null ? '' : ' status=${result.statusCode}'}',
        tag: 'connectivity',
      );
      return;
    }

    emit(
      state.copyWith(
        badgeState: ConnectivityBadgeState.failure,
        clearLatency: true,
      ),
    );
    _log(
      LogLevel.warning,
      'Connectivity failed'
      '${result.statusCode == null ? '' : ' status=${result.statusCode}'}'
      '${result.error == null || result.error!.isEmpty ? '' : ': ${redactLogMessage(result.error!)}'}',
      tag: 'connectivity',
    );
  }

  @override
  Future<void> close() {
    _runId++;
    _cancelActiveRun();
    return super.close();
  }

  void _log(LogLevel level, String message, {required String tag}) {
    _logsRepository.append(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        source: LogSource.dart,
        tag: tag,
        message: redactLogMessage(message),
      ),
    );
  }
}
