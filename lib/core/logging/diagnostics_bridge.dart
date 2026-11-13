import 'package:flutter/services.dart';

abstract final class DiagnosticsContract {
  static const String channel = 'tunnel_forge/diagnostics';

  static const String appendLogs = 'appendLogs';
  static const String readLogTail = 'readLogTail';
  static const String exportLogs = 'exportLogs';
  static const String hasTombstone = 'hasTombstone';
  static const String clearLogs = 'clearLogs';

  static const String argTs = 'ts';
  static const String argLevel = 'level';
  static const String argSource = 'source';
  static const String argTag = 'tag';
  static const String argMessage = 'message';
  static const String argMaxLines = 'maxLines';
  static const String argIncludeTombstone = 'includeTombstone';
}

abstract class DiagnosticsBridge {
  static DiagnosticsBridge instance = MethodChannelDiagnosticsBridge();

  Future<void> appendLogs(List<Map<String, Object?>> entries);
  Future<String> readLogTail({int maxLines = 5000});
  Future<List<String>> exportLogs({bool includeTombstone = false});
  Future<bool> hasTombstone();
  Future<void> clearLogs();
}

class MethodChannelDiagnosticsBridge implements DiagnosticsBridge {
  MethodChannelDiagnosticsBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(DiagnosticsContract.channel);

  final MethodChannel _channel;

  @override
  Future<void> appendLogs(List<Map<String, Object?>> entries) async {
    if (entries.isEmpty) return;
    try {
      await _channel.invokeMethod<void>(
        DiagnosticsContract.appendLogs,
        entries,
      );
    } on MissingPluginException {
      // Ignored in tests or platforms without the Android host channel.
    }
  }

  @override
  Future<String> readLogTail({int maxLines = 5000}) async {
    try {
      final result = await _channel.invokeMethod<String>(
        DiagnosticsContract.readLogTail,
        <String, Object?>{DiagnosticsContract.argMaxLines: maxLines},
      );
      return result ?? '';
    } on MissingPluginException {
      return '';
    }
  }

  @override
  Future<List<String>> exportLogs({bool includeTombstone = false}) async {
    try {
      final result = await _channel.invokeListMethod<String>(
        DiagnosticsContract.exportLogs,
        <String, Object?>{
          DiagnosticsContract.argIncludeTombstone: includeTombstone,
        },
      );
      return result ?? const <String>[];
    } on MissingPluginException {
      return const <String>[];
    }
  }

  @override
  Future<bool> hasTombstone() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        DiagnosticsContract.hasTombstone,
      );
      return result ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> clearLogs() async {
    try {
      await _channel.invokeMethod<void>(DiagnosticsContract.clearLogs);
    } on MissingPluginException {
      // Ignored in tests or platforms without the Android host channel.
    }
  }
}
