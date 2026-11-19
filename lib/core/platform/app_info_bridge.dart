import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:tunnel_forge/core/platform/app_info_contract.dart';

class AppInfoBridge {
  AppInfoBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(AppInfoContract.channel);

  final MethodChannel _channel;

  Future<({String? versionName, String? buildNumber})>
  loadInstalledVersion() async {
    final raw = await _channel.invokeMapMethod<String, Object?>(
      AppInfoContract.getInstalledVersion,
    );
    return (
      versionName: raw?[AppInfoContract.argVersionName]?.toString(),
      buildNumber: raw?[AppInfoContract.argBuildNumber]?.toString(),
    );
  }

  Future<void> setAppLocale(String? languageTag) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _channel.invokeMethod<void>(
        AppInfoContract.setAppLocale,
        languageTag,
      );
    } on MissingPluginException {
      // The native app-info channel is unavailable in widget tests.
    }
  }
}
