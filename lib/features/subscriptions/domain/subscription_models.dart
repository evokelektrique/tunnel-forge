import 'package:equatable/equatable.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

/// Unit for custom subscription auto-update intervals.
enum SubscriptionIntervalUnit {
  minutes('minutes', 1),
  hours('hours', 60),
  days('days', 1440);

  const SubscriptionIntervalUnit(this.jsonValue, this.minutesPerUnit);

  final String jsonValue;
  final int minutesPerUnit;

  static const List<SubscriptionIntervalUnit> orderedValues =
      <SubscriptionIntervalUnit>[
        SubscriptionIntervalUnit.minutes,
        SubscriptionIntervalUnit.hours,
        SubscriptionIntervalUnit.days,
      ];

  String localizedLabel(AppLocalizations t) {
    return switch (this) {
      SubscriptionIntervalUnit.minutes => t.unitMinutes,
      SubscriptionIntervalUnit.hours => t.unitHours,
      SubscriptionIntervalUnit.days => t.unitDays,
    };
  }

  static SubscriptionIntervalUnit fromJson(Object? raw) {
    if (raw is! String) return SubscriptionIntervalUnit.hours;
    return switch (raw.trim().toLowerCase()) {
      'minutes' => SubscriptionIntervalUnit.minutes,
      'days' => SubscriptionIntervalUnit.days,
      _ => SubscriptionIntervalUnit.hours,
    };
  }
}

/// Origin of a subscription sync run.
enum SubscriptionSyncTrigger {
  initialAdd('initialAdd'),
  manual('manual'),
  foregroundAuto('foregroundAuto'),
  backgroundAuto('backgroundAuto');

  const SubscriptionSyncTrigger(this.jsonValue);

  final String jsonValue;

  bool get isAuto =>
      this == SubscriptionSyncTrigger.foregroundAuto ||
      this == SubscriptionSyncTrigger.backgroundAuto;

  static SubscriptionSyncTrigger fromJson(Object? raw) {
    if (raw is! String) return SubscriptionSyncTrigger.manual;
    return switch (raw) {
      'initialAdd' => SubscriptionSyncTrigger.initialAdd,
      'foregroundAuto' => SubscriptionSyncTrigger.foregroundAuto,
      'backgroundAuto' => SubscriptionSyncTrigger.backgroundAuto,
      _ => SubscriptionSyncTrigger.manual,
    };
  }
}

enum SubscriptionErrorCode {
  noValidProfiles('noValidProfiles', retryable: false),
  http('http', retryable: true),
  timeout('timeout', retryable: true),
  network('network', retryable: true),
  tls('tls', retryable: false),
  tooLarge('tooLarge', retryable: false),
  invalidEncoding('invalidEncoding', retryable: false),
  tunnelRecovering('tunnelRecovering', retryable: true),
  unexpected('unexpected', retryable: true);

  const SubscriptionErrorCode(this.wireValue, {required this.retryable});

  final String wireValue;
  final bool retryable;

  static SubscriptionErrorCode fromWire(Object? raw) {
    if (raw is! String) return SubscriptionErrorCode.unexpected;
    for (final value in SubscriptionErrorCode.values) {
      if (value.wireValue == raw) return value;
    }
    return SubscriptionErrorCode.unexpected;
  }
}

class SubscriptionException implements Exception {
  const SubscriptionException(
    this.message, {
    required this.code,
    this.statusCode,
  });

  /// Strictly English diagnostic message for logs.
  final String message;
  final SubscriptionErrorCode code;
  final int? statusCode;

  bool get isRetryable {
    if (code == SubscriptionErrorCode.http) {
      final status = statusCode;
      return status == null || status == 429 || status >= 500;
    }
    return code.retryable;
  }

  String localizedMessage(AppLocalizations t) {
    return switch (code) {
      SubscriptionErrorCode.noValidProfiles =>
        t.subscriptionErrorNoValidProfiles,
      SubscriptionErrorCode.http =>
        statusCode != null
            ? t.subscriptionErrorHttp(statusCode!)
            : t.subscriptionErrorUnexpected,
      SubscriptionErrorCode.timeout => t.subscriptionErrorTimeout,
      SubscriptionErrorCode.network => t.subscriptionErrorNetwork,
      SubscriptionErrorCode.tls => t.subscriptionErrorTls,
      SubscriptionErrorCode.tooLarge => t.subscriptionErrorTooLarge,
      SubscriptionErrorCode.invalidEncoding =>
        t.subscriptionErrorInvalidEncoding,
      SubscriptionErrorCode.tunnelRecovering =>
        t.subscriptionErrorTunnelRecovering,
      SubscriptionErrorCode.unexpected => t.subscriptionErrorUnexpected,
    };
  }

  @override
  String toString() => 'SubscriptionException(${code.wireValue}): $message';
}

/// Persisted subscription source metadata.
class Subscription extends Equatable {
  const Subscription({
    required this.id,
    required this.name,
    required this.url,
    this.urlMissing = false,
    this.autoUpdate = false,
    this.updateIntervalMinutes = defaultIntervalMinutes,
    this.intervalUnit = SubscriptionIntervalUnit.hours,
    this.lastUpdatedAtMs,
    this.lastError,
  });

  /// Android WorkManager hard minimum for periodic work.
  static const int minIntervalMinutes = 15;
  static const int maxIntervalDays = 30;
  static const int maxIntervalMinutes = maxIntervalDays * 24 * 60;
  static const int defaultIntervalMinutes = 24 * 60;

  static const List<int> presetIntervalsMinutes = <int>[
    60, // 1 hour
    360, // 6 hours
    720, // 12 hours
    1440, // 24 hours
    4320, // 3 days
    10080, // 7 days
  ];

  final String id;
  final String name;
  final String url;
  final bool urlMissing;
  final bool autoUpdate;
  final int updateIntervalMinutes;
  final SubscriptionIntervalUnit intervalUnit;
  final int? lastUpdatedAtMs;
  final String? lastError;

  DateTime? get lastUpdatedAt => lastUpdatedAtMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(lastUpdatedAtMs!);

  String? localizedLastError(AppLocalizations t) {
    final raw = lastError?.trim();
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(':');
    final code = SubscriptionErrorCode.fromWire(parts.first);
    final statusCode = parts.length > 1 ? int.tryParse(parts[1]) : null;
    return SubscriptionException(
      raw,
      code: code,
      statusCode: statusCode,
    ).localizedMessage(t);
  }

  bool get isPresetInterval =>
      presetIntervalsMinutes.contains(updateIntervalMinutes);

  /// Derives the numeric value in [intervalUnit] for pre-filling the custom field.
  int get displayIntervalValue {
    final unitMinutes = intervalUnit.minutesPerUnit;
    if (updateIntervalMinutes % unitMinutes == 0) {
      return (updateIntervalMinutes ~/ unitMinutes).clamp(
        1,
        maxIntervalMinutes,
      );
    }
    return updateIntervalMinutes;
  }

  SubscriptionIntervalUnit get effectiveDisplayUnit {
    if (updateIntervalMinutes % intervalUnit.minutesPerUnit == 0) {
      return intervalUnit;
    }
    if (updateIntervalMinutes % 1440 == 0) return SubscriptionIntervalUnit.days;
    if (updateIntervalMinutes % 60 == 0) return SubscriptionIntervalUnit.hours;
    return SubscriptionIntervalUnit.minutes;
  }

  bool isDueAt(DateTime now) {
    if (!autoUpdate) return false;
    final last = lastUpdatedAtMs;
    if (last == null) return true;
    final intervalMs = normalizeIntervalMinutes(updateIntervalMinutes) * 60000;
    return now.millisecondsSinceEpoch - last >= intervalMs;
  }

  String formatIntervalLabel(AppLocalizations t) {
    return formatMinutesLabel(
      normalizeIntervalMinutes(updateIntervalMinutes),
      t,
      preferredUnit: intervalUnit,
    );
  }

  static String formatMinutesLabel(
    int minutes,
    AppLocalizations t, {
    SubscriptionIntervalUnit? preferredUnit,
  }) {
    final normalized = normalizeIntervalMinutes(minutes);
    if (preferredUnit != null &&
        normalized % preferredUnit.minutesPerUnit == 0) {
      final count = normalized ~/ preferredUnit.minutesPerUnit;
      return switch (preferredUnit) {
        SubscriptionIntervalUnit.minutes => t.frequencyEveryMinutes(count),
        SubscriptionIntervalUnit.hours => t.frequencyEveryHours(count),
        SubscriptionIntervalUnit.days => t.frequencyEveryDays(count),
      };
    }
    if (normalized == 1440) {
      return t.frequencyEveryHours(24);
    }
    if (normalized % 1440 == 0) {
      return t.frequencyEveryDays(normalized ~/ 1440);
    }
    if (normalized % 60 == 0) {
      return t.frequencyEveryHours(normalized ~/ 60);
    }
    return t.frequencyEveryMinutes(normalized);
  }

  static int normalizeIntervalMinutes(int value) {
    return value.clamp(minIntervalMinutes, maxIntervalMinutes);
  }

  static String? validateName(String text, {AppLocalizations? l10n}) {
    final t = l10n ?? AppL10n.current;
    if (text.trim().isEmpty) {
      return t.subscriptionNameRequired;
    }
    return null;
  }

  static String? validateUrl(String text, {AppLocalizations? l10n}) {
    final t = l10n ?? AppL10n.current;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return t.subscriptionUrlRequired;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme || uri.host.trim().isEmpty) {
      return t.subscriptionUrlInvalid;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return t.subscriptionUrlUnsupportedScheme;
    }
    return null;
  }

  static bool isCleartextHttpUrl(String text) {
    final uri = Uri.tryParse(text.trim());
    return uri != null &&
        uri.hasScheme &&
        uri.scheme.toLowerCase() == 'http' &&
        uri.host.trim().isNotEmpty;
  }

  static int? parseCustomIntervalMinutes(
    String text,
    SubscriptionIntervalUnit unit,
  ) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || parsed <= 0) return null;
    final total = parsed * unit.minutesPerUnit;
    if (total < minIntervalMinutes || total > maxIntervalMinutes) return null;
    return total;
  }

  static String? validateCustomInterval(
    String text,
    SubscriptionIntervalUnit unit, {
    AppLocalizations? l10n,
  }) {
    final t = l10n ?? AppL10n.current;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return t.intervalValueRequired;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed <= 0) {
      return t.intervalValueWholeNumber;
    }
    final totalMinutes = parsed * unit.minutesPerUnit;
    if (totalMinutes < minIntervalMinutes) {
      return t.intervalMinMinutesError(minIntervalMinutes);
    }
    if (totalMinutes > maxIntervalMinutes) {
      return t.intervalMaxDaysError(maxIntervalDays);
    }
    return null;
  }

  Subscription copyWith({
    String? name,
    String? url,
    bool? urlMissing,
    bool? autoUpdate,
    int? updateIntervalMinutes,
    SubscriptionIntervalUnit? intervalUnit,
    int? lastUpdatedAtMs,
    bool clearLastUpdatedAtMs = false,
    String? lastError,
    bool clearLastError = false,
  }) {
    return Subscription(
      id: id,
      name: name ?? this.name,
      url: url ?? this.url,
      urlMissing: urlMissing ?? this.urlMissing,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      updateIntervalMinutes: normalizeIntervalMinutes(
        updateIntervalMinutes ?? this.updateIntervalMinutes,
      ),
      intervalUnit: intervalUnit ?? this.intervalUnit,
      lastUpdatedAtMs: clearLastUpdatedAtMs
          ? null
          : (lastUpdatedAtMs ?? this.lastUpdatedAtMs),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, Object?> toJson({bool includeUrl = true}) => <String, Object?>{
    'id': id,
    'name': name,
    if (includeUrl && url.isNotEmpty) 'url': url,
    'autoUpdate': autoUpdate,
    'updateIntervalMinutes': normalizeIntervalMinutes(updateIntervalMinutes),
    'intervalUnit': intervalUnit.jsonValue,
    if (lastUpdatedAtMs != null) 'lastUpdatedAtMs': lastUpdatedAtMs,
    if (lastError != null && lastError!.isNotEmpty) 'lastError': lastError,
  };

  static Subscription? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final id = m['id'];
    final name = m['name'];
    if (id is! String || name is! String) return null;
    final cleanId = id.trim();
    final cleanName = name.trim();
    if (cleanId.isEmpty || cleanName.isEmpty) return null;
    final rawUrl = m['url'];
    final cleanUrl = rawUrl is String ? rawUrl.trim() : '';
    final autoUpdate = m['autoUpdate'] is bool
        ? m['autoUpdate'] as bool
        : false;
    final rawInterval = m['updateIntervalMinutes'];
    final intervalMinutes = switch (rawInterval) {
      int v => normalizeIntervalMinutes(v),
      num v => normalizeIntervalMinutes(v.toInt()),
      _ => defaultIntervalMinutes,
    };
    final intervalUnit = SubscriptionIntervalUnit.fromJson(m['intervalUnit']);
    final rawUpdated = m['lastUpdatedAtMs'];
    final lastUpdatedAtMs = switch (rawUpdated) {
      int v => v,
      num v => v.toInt(),
      _ => null,
    };
    final rawError = m['lastError'];
    final lastError = rawError is String && rawError.trim().isNotEmpty
        ? rawError.trim()
        : null;
    return Subscription(
      id: cleanId,
      name: cleanName,
      url: cleanUrl,
      urlMissing: cleanUrl.isEmpty,
      autoUpdate: autoUpdate,
      updateIntervalMinutes: intervalMinutes,
      intervalUnit: intervalUnit,
      lastUpdatedAtMs: lastUpdatedAtMs,
      lastError: lastError,
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    url,
    urlMissing,
    autoUpdate,
    updateIntervalMinutes,
    intervalUnit,
    lastUpdatedAtMs,
    lastError,
  ];
}

/// Result of syncing a subscription URL into [ProfileStore].
class SubscriptionSyncSummary extends Equatable {
  const SubscriptionSyncSummary({
    required this.subscriptionId,
    required this.subscriptionName,
    required this.importedCount,
    required this.updatedCount,
    required this.removedCount,
    this.skippedInvalidLines = 0,
    required this.syncedAtMs,
    required this.trigger,
  });

  final String subscriptionId;
  final String subscriptionName;
  final int importedCount;
  final int updatedCount;
  final int removedCount;
  final int skippedInvalidLines;
  final int syncedAtMs;
  final SubscriptionSyncTrigger trigger;

  bool get hasChanges =>
      importedCount > 0 || updatedCount > 0 || removedCount > 0;

  DateTime get syncedAt => DateTime.fromMillisecondsSinceEpoch(syncedAtMs);

  SubscriptionSyncSummary coalesceWith(SubscriptionSyncSummary newer) {
    return SubscriptionSyncSummary(
      subscriptionId: newer.subscriptionId,
      subscriptionName: newer.subscriptionName,
      importedCount: importedCount + newer.importedCount,
      updatedCount: updatedCount + newer.updatedCount,
      removedCount: removedCount + newer.removedCount,
      skippedInvalidLines: newer.skippedInvalidLines,
      syncedAtMs: newer.syncedAtMs,
      trigger: newer.trigger,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'subscriptionId': subscriptionId,
    'subscriptionName': subscriptionName,
    'importedCount': importedCount,
    'updatedCount': updatedCount,
    'removedCount': removedCount,
    'skippedInvalidLines': skippedInvalidLines,
    'syncedAtMs': syncedAtMs,
    'trigger': trigger.jsonValue,
  };

  static SubscriptionSyncSummary? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, Object?>.from(raw);
    final subscriptionId = m['subscriptionId'];
    final subscriptionName = m['subscriptionName'];
    final importedCount = m['importedCount'];
    final updatedCount = m['updatedCount'];
    final removedCount = m['removedCount'];
    final syncedAtMs = m['syncedAtMs'];
    if (subscriptionId is! String ||
        subscriptionName is! String ||
        importedCount is! int ||
        updatedCount is! int ||
        removedCount is! int ||
        syncedAtMs is! int) {
      return null;
    }
    if (subscriptionId.isEmpty) return null;
    final skipped = m['skippedInvalidLines'] is int
        ? m['skippedInvalidLines'] as int
        : 0;
    return SubscriptionSyncSummary(
      subscriptionId: subscriptionId,
      subscriptionName: subscriptionName,
      importedCount: importedCount,
      updatedCount: updatedCount,
      removedCount: removedCount,
      skippedInvalidLines: skipped,
      syncedAtMs: syncedAtMs,
      trigger: SubscriptionSyncTrigger.fromJson(m['trigger']),
    );
  }

  @override
  List<Object?> get props => [
    subscriptionId,
    subscriptionName,
    importedCount,
    updatedCount,
    removedCount,
    skippedInvalidLines,
    syncedAtMs,
    trigger,
  ];
}

/// Monotonically numbered UI event so dialogs display exactly once per sync batch.
class SubscriptionSyncSummaryEvent extends Equatable {
  const SubscriptionSyncSummaryEvent({
    required this.id,
    required this.summaries,
  });

  final int id;
  final List<SubscriptionSyncSummary> summaries;

  @override
  List<Object?> get props => [id, summaries];
}

class SubscriptionParseResult {
  const SubscriptionParseResult({
    required this.envelopes,
    required this.skippedInvalidLines,
  });

  final List<ProfileTransferEnvelope> envelopes;
  final int skippedInvalidLines;
}
