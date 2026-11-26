import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/connectivity_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/widgets/connection_panel.dart';

void main() {
  const request = ConnectivityPingRequest.direct(
    'https://www.gstatic.com/generate_204',
  );

  group('ConnectivityBloc', () {
    test(
      'cancels first check signal, ignores late first result, and emits second result',
      () async {
        final repo = _FakeConnectivityRepository();
        final logs = _RecordingLogsRepository();
        final firstCompleter = Completer<ConnectivityPingResult>();
        final secondCompleter = Completer<ConnectivityPingResult>();
        repo.enqueue(firstCompleter.future);
        repo.enqueue(secondCompleter.future);

        final bloc = ConnectivityBloc(repo, logs);
        addTearDown(bloc.close);

        bloc.add(const ConnectivityRunRequested(request));
        await Future<void>.delayed(Duration.zero);
        expect(repo.calls.length, 1);
        expect(repo.calls[0].cancelled, isFalse);
        expect(bloc.state.badgeState, ConnectivityBadgeState.checking);
        expect(bloc.state.runId, 1);

        bloc.add(const ConnectivityRunRequested(request));
        await Future<void>.delayed(Duration.zero);
        expect(repo.calls.length, 2);
        expect(repo.calls[0].cancelled, isTrue);
        expect(repo.calls[1].cancelled, isFalse);
        expect(bloc.state.badgeState, ConnectivityBadgeState.checking);
        expect(bloc.state.runId, 2);

        firstCompleter.complete(ConnectivityPingResult.failure(error: 'stale'));
        await Future<void>.delayed(Duration.zero);
        expect(bloc.state.badgeState, ConnectivityBadgeState.checking);

        secondCompleter.complete(
          ConnectivityPingResult.success(latencyMs: 57, statusCode: 204),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          bloc.state,
          const ConnectivityState(
            badgeState: ConnectivityBadgeState.success,
            latencyMs: 57,
            runId: 2,
          ),
        );
        expect(
          logs.entries.map((e) => e.message),
          contains('Connectivity check cancelled'),
        );
        expect(
          logs.entries.any((e) => e.message.contains('Connectivity failed')),
          isFalse,
        );
      },
    );

    test(
      'reset while checking cancels active check and ignores stale completion',
      () async {
        final repo = _FakeConnectivityRepository();
        final logs = _RecordingLogsRepository();
        final completer = Completer<ConnectivityPingResult>();
        repo.enqueue(completer.future);

        final bloc = ConnectivityBloc(repo, logs);
        addTearDown(bloc.close);

        bloc.add(const ConnectivityRunRequested(request));
        await Future<void>.delayed(Duration.zero);
        expect(repo.calls.single.cancelled, isFalse);

        bloc.add(const ConnectivityResetRequested());
        await Future<void>.delayed(Duration.zero);
        expect(repo.calls.single.cancelled, isTrue);
        expect(bloc.state, const ConnectivityState());

        completer.complete(
          ConnectivityPingResult.success(latencyMs: 12, statusCode: 204),
        );
        await Future<void>.delayed(Duration.zero);
        expect(bloc.state, const ConnectivityState());
      },
    );

    test('close cancels active check', () async {
      final repo = _FakeConnectivityRepository();
      final logs = _RecordingLogsRepository();
      final completer = Completer<ConnectivityPingResult>();
      repo.enqueue(completer.future);

      final bloc = ConnectivityBloc(repo, logs);
      bloc.add(const ConnectivityRunRequested(request));
      await Future<void>.delayed(Duration.zero);
      expect(repo.calls.single.cancelled, isFalse);

      await bloc.close();
      expect(repo.calls.single.cancelled, isTrue);
    });

    test(
      'auto-retry recovers after transient timeout using bounded first attempt',
      () async {
        final repo = _FakeConnectivityRepository();
        final logs = _RecordingLogsRepository();
        repo.enqueue(
          Future.value(ConnectivityPingResult.failure(error: 'Timed out')),
        );
        repo.enqueue(
          Future.value(
            ConnectivityPingResult.success(latencyMs: 90, statusCode: 204),
          ),
        );

        final bloc = ConnectivityBloc(repo, logs, retryDelay: Duration.zero);
        addTearDown(bloc.close);

        bloc.add(
          const ConnectivityRunRequested(
            request,
            retryOnTransientFailure: true,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(repo.calls.length, 2);
        expect(repo.calls[0].request.timeoutMs, 2500);
        expect(repo.calls[1].request.timeoutMs, 5000);
        expect(
          bloc.state,
          const ConnectivityState(
            badgeState: ConnectivityBadgeState.success,
            latencyMs: 90,
            runId: 1,
          ),
        );
        expect(
          logs.entries.any((e) => e.message.contains('Connectivity failed')),
          isFalse,
        );
      },
    );

    test(
      'auto-retry skips HTTP errors and respects reset during retry delay',
      () async {
        final repo = _FakeConnectivityRepository();
        final logs = _RecordingLogsRepository();
        repo.enqueue(
          Future.value(
            ConnectivityPingResult.failure(statusCode: 503, error: 'HTTP 503'),
          ),
        );

        final httpFailBloc = ConnectivityBloc(
          repo,
          logs,
          retryDelay: Duration.zero,
        );
        addTearDown(httpFailBloc.close);

        httpFailBloc.add(
          const ConnectivityRunRequested(
            request,
            retryOnTransientFailure: true,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(repo.calls.length, 1);
        expect(httpFailBloc.state.badgeState, ConnectivityBadgeState.failure);

        final cancelRepo = _FakeConnectivityRepository();
        cancelRepo.enqueue(
          Future.value(ConnectivityPingResult.failure(error: 'Timed out')),
        );
        final cancelBloc = ConnectivityBloc(
          cancelRepo,
          logs,
          retryDelay: const Duration(milliseconds: 50),
        );
        addTearDown(cancelBloc.close);

        cancelBloc.add(
          const ConnectivityRunRequested(
            request,
            retryOnTransientFailure: true,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        cancelBloc.add(const ConnectivityResetRequested());
        await Future<void>.delayed(const Duration(milliseconds: 70));

        expect(cancelRepo.calls.length, 1);
        expect(cancelBloc.state, const ConnectivityState());
      },
    );
  });
}

class _RecordedPing {
  _RecordedPing(this.request);

  final ConnectivityPingRequest request;
  bool cancelled = false;
}

class _FakeConnectivityRepository implements ConnectivityRepository {
  final List<Future<ConnectivityPingResult>> _queue = [];
  final List<_RecordedPing> calls = [];

  void enqueue(Future<ConnectivityPingResult> future) {
    _queue.add(future);
  }

  @override
  Future<ConnectivityPingResult> ping(
    ConnectivityPingRequest request, {
    Future<void>? cancelSignal,
  }) {
    final record = _RecordedPing(request);
    calls.add(record);
    if (cancelSignal != null) {
      unawaited(cancelSignal.then((_) => record.cancelled = true));
    }
    return _queue.removeAt(0);
  }
}

class _RecordingLogsRepository implements LogsRepository {
  @override
  final List<LogEntry> entries = <LogEntry>[];

  @override
  Stream<List<LogEntry>> get entriesStream => const Stream.empty();

  @override
  Future<void> loadPersisted() async {}

  @override
  void append(LogEntry entry) => entries.add(entry);

  @override
  void clear() => entries.clear();
}
