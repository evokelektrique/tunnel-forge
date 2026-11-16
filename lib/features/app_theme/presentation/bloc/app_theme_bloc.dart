import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:material_ui/material_ui.dart';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import '../../domain/theme_repository.dart';

sealed class AppThemeEvent extends Equatable {
  const AppThemeEvent();

  @override
  List<Object?> get props => const [];
}

final class AppThemeStarted extends AppThemeEvent {
  const AppThemeStarted();
}

final class AppThemeChanged extends AppThemeEvent {
  const AppThemeChanged(this.mode);

  final ThemeMode mode;

  @override
  List<Object?> get props => [mode];
}

class AppThemeState extends Equatable {
  const AppThemeState({this.themeMode = ThemeMode.system, this.loaded = false});

  final ThemeMode themeMode;
  final bool loaded;

  AppThemeState copyWith({ThemeMode? themeMode, bool? loaded}) {
    return AppThemeState(
      themeMode: themeMode ?? this.themeMode,
      loaded: loaded ?? this.loaded,
    );
  }

  @override
  List<Object?> get props => [themeMode, loaded];
}

class AppThemeBloc extends Bloc<AppThemeEvent, AppThemeState> {
  AppThemeBloc(this._themeRepository, {LogsRepository? logsRepository})
    : _logsRepository = logsRepository,
      super(const AppThemeState()) {
    on<AppThemeStarted>(_onStarted);
    on<AppThemeChanged>(_onChanged);
  }

  final ThemeRepository _themeRepository;
  final LogsRepository? _logsRepository;

  Future<void> _onStarted(
    AppThemeStarted event,
    Emitter<AppThemeState> emit,
  ) async {
    final themeMode = await _themeRepository.loadThemeMode();
    emit(state.copyWith(themeMode: themeMode, loaded: true));
  }

  Future<void> _onChanged(
    AppThemeChanged event,
    Emitter<AppThemeState> emit,
  ) async {
    final previous = state.themeMode;
    emit(state.copyWith(themeMode: event.mode, loaded: true));
    if (previous != event.mode) {
      _logsRepository?.logDart(
        LogLevel.debug,
        'theme',
        'Theme mode changed previous=${previous.name} to=${event.mode.name}',
      );
    }
    await _themeRepository.saveThemeMode(event.mode);
  }
}
