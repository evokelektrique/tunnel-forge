/// Host/channel contract for app metadata, appearance, and locale sync.
abstract final class AppInfoContract {
  static const String channel = 'io.github.evokelektrique.tunnelforge/appInfo';

  /// Flutter -> host: returns the installed version name / build number map.
  static const String getInstalledVersion = 'getInstalledVersion';
  static const String setThemeMode = 'setThemeMode';
  static const String setAppLocale = 'setAppLocale';
  static const String isRootDetected = 'isRootDetected';

  static const String argVersionName = 'versionName';
  static const String argBuildNumber = 'buildNumber';
}
