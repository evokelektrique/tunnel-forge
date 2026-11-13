import 'package:material_ui/material_ui.dart';

abstract class ThemeRepository {
  Future<ThemeMode> loadThemeMode();
  Future<void> saveThemeMode(ThemeMode mode);
}
