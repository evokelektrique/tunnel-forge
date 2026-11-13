import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';

class FakeDiagnosticsBridge implements DiagnosticsBridge {
  final List<Map<String, Object?>> appendedEntries = <Map<String, Object?>>[];
  String tailText = '';
  List<String> exportPaths = <String>[];
  bool tombstoneAvailable = false;
  int clearCalls = 0;
  bool? lastExportIncludeTombstone;
  Object? appendError;
  Object? exportError;

  @override
  Future<void> appendLogs(List<Map<String, Object?>> entries) async {
    final error = appendError;
    if (error != null) throw error;
    appendedEntries.addAll(entries.map(Map<String, Object?>.from));
  }

  @override
  Future<String> readLogTail({int maxLines = 5000}) async => tailText;

  @override
  Future<List<String>> exportLogs({bool includeTombstone = false}) async {
    lastExportIncludeTombstone = includeTombstone;
    final error = exportError;
    if (error != null) throw error;
    return List<String>.from(exportPaths);
  }

  @override
  Future<bool> hasTombstone() async => tombstoneAvailable;

  @override
  Future<void> clearLogs() async {
    clearCalls += 1;
    tailText = '';
    appendedEntries.clear();
  }
}
