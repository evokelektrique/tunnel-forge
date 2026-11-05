import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/core/platform/app_info_contract.dart';

import '../domain/theme_repository.dart';

const String kThemeModePrefsKey = 'app_theme_mode';

String themeModeToStorage(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
    case ThemeMode.system:
      return 'system';
  }
}

ThemeMode themeModeFromStorage(String? raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    default:
      return ThemeMode.system;
  }
}

class SharedPrefsThemeRepository implements ThemeRepository {
  SharedPrefsThemeRepository({SharedPreferences? prefsOverride})
    : _prefsOverride = prefsOverride;

  final SharedPreferences? _prefsOverride;

  Future<SharedPreferences> _prefs() async {
    return _prefsOverride ?? SharedPreferences.getInstance();
  }

  @override
  Future<ThemeMode> loadThemeMode() async {
    final prefs = await _prefs();
    final mode = themeModeFromStorage(prefs.getString(kThemeModePrefsKey));
    await _syncAndroidTheme(mode);
    return mode;
  }

  @override
  Future<void> saveThemeMode(ThemeMode mode) async {
    final prefs = await _prefs();
    await prefs.setString(kThemeModePrefsKey, themeModeToStorage(mode));
    await _syncAndroidTheme(mode);
  }

  Future<void> _syncAndroidTheme(ThemeMode mode) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await const MethodChannel(AppInfoContract.channel).invokeMethod<void>(
        AppInfoContract.setThemeMode,
        themeModeToStorage(mode),
      );
    } on MissingPluginException {
      // The native appearance channel is unavailable in widget tests.
    }
  }
}
