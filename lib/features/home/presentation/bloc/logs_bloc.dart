import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import '../../../home/domain/home_repositories.dart';

sealed class LogsEvent extends Equatable {
  const LogsEvent();

  @override
  List<Object?> get props => const [];
}

final class LogsStarted extends LogsEvent {
  const LogsStarted();
}

final class LogsEntriesChanged extends LogsEvent {
  const LogsEntriesChanged(this.entries);

  final List<LogEntry> entries;

  @override
  List<Object?> get props => [entries];
}

final class LogsLevelChangeRequested extends LogsEvent {
  const LogsLevelChangeRequested(this.level);

  final LogDisplayLevel level;

  @override
  List<Object?> get props => [level];
}

final class LogsWordWrapToggled extends LogsEvent {
  const LogsWordWrapToggled();
}

final class LogsCleared extends LogsEvent {
  const LogsCleared();
}

class LogsState extends Equatable {
  const LogsState({
    this.entries = const <LogEntry>[],
    this.level = LogDisplayLevel.info,
    this.wordWrap = true,
    this.revision = 0,
    List<LogEntry>? visibleLogs,
  }) : _visibleLogs = visibleLogs;

  final List<LogEntry> entries;
  final LogDisplayLevel level;
  final bool wordWrap;
  final int revision;
  final List<LogEntry>? _visibleLogs;

  static List<LogEntry> _filterVisible(
    List<LogEntry> entries,
    LogDisplayLevel level,
  ) {
    if (entries.isEmpty) return const <LogEntry>[];
    return List<LogEntry>.unmodifiable(
      entries.where((entry) => level.includes(entry.level)),
    );
  }

  List<LogEntry> get visibleLogs =>
      _visibleLogs ?? _filterVisible(entries, level);

  String get levelLabel => level.label;

  LogsState copyWith({
    List<LogEntry>? entries,
    LogDisplayLevel? level,
    bool? wordWrap,
    int? revision,
  }) {
    final nextEntries = entries ?? this.entries;
    final nextLevel = level ?? this.level;
    final nextVisible =
        (entries == null && level == null && _visibleLogs != null)
        ? _visibleLogs
        : _filterVisible(nextEntries, nextLevel);
    return LogsState(
      entries: nextEntries,
      level: nextLevel,
      wordWrap: wordWrap ?? this.wordWrap,
      revision: revision ?? this.revision,
      visibleLogs: nextVisible,
    );
  }

  @override
  List<Object?> get props => [entries, level, wordWrap, revision];
}

class LogsBloc extends Bloc<LogsEvent, LogsState> {
  LogsBloc(
    this._logsRepository,
    this._settingsRepository,
    this._tunnelRepository,
  ) : super(const LogsState()) {
    on<LogsStarted>(_onStarted);
    on<LogsEntriesChanged>(_onEntriesChanged);
    on<LogsLevelChangeRequested>(_onLevelChangeRequested);
    on<LogsWordWrapToggled>(_onWordWrapToggled);
    on<LogsCleared>(_onCleared);
  }

  final LogsRepository _logsRepository;
  final SettingsRepository _settingsRepository;
  final TunnelRepository _tunnelRepository;
  StreamSubscription<List<LogEntry>>? _entriesSub;

  Future<void> _onStarted(LogsStarted event, Emitter<LogsState> emit) async {
    final level = await _settingsRepository.loadLogDisplayLevel();
    _entriesSub?.cancel();
    _entriesSub = _logsRepository.entriesStream.listen((entries) {
      add(LogsEntriesChanged(entries));
    });
    await _tunnelRepository.setLogLevel(LogDisplayLevel.debug);
    await _logsRepository.loadPersisted();
    final initialEntries = _logsRepository.entries;
    emit(
      state.copyWith(
        level: level,
        entries: initialEntries,
        revision: initialEntries.isEmpty ? state.revision : state.revision + 1,
      ),
    );
  }

  void _onEntriesChanged(LogsEntriesChanged event, Emitter<LogsState> emit) {
    emit(state.copyWith(entries: event.entries, revision: state.revision + 1));
  }

  Future<void> _onLevelChangeRequested(
    LogsLevelChangeRequested event,
    Emitter<LogsState> emit,
  ) async {
    if (state.level == event.level) return;
    final previous = state.level;
    emit(state.copyWith(level: event.level));
    await _settingsRepository.saveLogDisplayLevel(event.level);
    _logsRepository.logDart(
      LogLevel.debug,
      'logs',
      'Log level changed previous=${previous.storageValue} to=${event.level.storageValue}',
    );
  }

  void _onWordWrapToggled(LogsWordWrapToggled event, Emitter<LogsState> emit) {
    emit(state.copyWith(wordWrap: !state.wordWrap));
  }

  void _onCleared(LogsCleared event, Emitter<LogsState> emit) {
    _logsRepository.clear();
  }

  @override
  Future<void> close() async {
    await _entriesSub?.cancel();
    return super.close();
  }
}
