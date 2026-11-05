import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/core/platform/app_info_contract.dart';
import 'package:tunnel_forge/features/app_theme/data/shared_prefs_theme_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(AppInfoContract.channel);
  final calls = <MethodCall>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final mode in ThemeMode.values) {
    test('persists $mode and syncs Android splash on save and load', () async {
      final repository = SharedPrefsThemeRepository();
      await repository.saveThemeMode(mode);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kThemeModePrefsKey), themeModeToStorage(mode));
      expect(await repository.loadThemeMode(), mode);
      expect(calls, hasLength(2));
      for (final call in calls) {
        expect(call.method, AppInfoContract.setThemeMode);
        expect(call.arguments, themeModeToStorage(mode));
      }
    });
  }
}
