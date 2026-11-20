import 'dart:typed_data';

import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_runtime_state.dart';
import 'home_models.dart';

abstract class ProfilesRepository {
  Future<List<Profile>> loadProfiles();
  Future<String?> loadLastProfileId();
  Future<void> setLastProfileId(String? id);
  Future<ProfileSecretRow?> loadProfileWithSecrets(String id);
  Future<void> upsertProfile(
    Profile profile, {
    required String password,
    required String psk,
  });
  Future<Profile> saveImportedProfile(
    ProfileTransferEnvelope envelope, {
    bool selectAsLastProfile = true,
  });
  Future<List<Profile>> saveImportedProfiles(
    List<ProfileTransferEnvelope> envelopes, {
    bool selectAsLastProfile = true,
  });
  Future<void> deleteProfile(String id);
  Future<void> deleteProfiles(List<String> ids);
  Future<({List<Profile> profiles, bool limitReached, bool favorite})>
  toggleProfileFavorite(String id);
  Future<List<Profile>> reorderProfiles({
    required bool favoritesSection,
    required int oldIndex,
    required int newIndex,
    String? subscriptionId,
    bool filterBySubscription = false,
  });
  Future<void> copyProfileShareLink(String id);
  Future<void> copyProfileShareLinks(List<String> ids);
  Future<void> exportProfileFile(String id);
  Future<void> exportProfileFiles(List<String> ids, {bool combined = false});
  Future<void> checkSecureStorageUpgrade();
  Future<void> resetSecureStorage();
  String newProfileId();
}

abstract class SettingsRepository {
  Future<ConnectionMode> loadConnectionMode();
  Future<void> saveConnectionMode(ConnectionMode mode);
  Future<ProxySettings> loadProxySettings();
  Future<void> saveProxySettings(ProxySettings settings);
  Future<SplitTunnelSettings> loadSplitTunnelSettings();
  Future<void> saveSplitTunnelSettings(SplitTunnelSettings settings);
  Future<ConnectivityCheckSettings> loadConnectivityCheckSettings();
  Future<void> saveConnectivityCheckSettings(
    ConnectivityCheckSettings settings,
  );
  Future<bool> loadConnectionHapticsEnabled();
  Future<void> saveConnectionHapticsEnabled(bool enabled);
  Future<LogDisplayLevel> loadLogDisplayLevel();
  Future<void> saveLogDisplayLevel(LogDisplayLevel level);
  Future<bool> loadBatteryOptimizationConnectPromptShown();
  Future<void> saveBatteryOptimizationConnectPromptShown(bool shown);
  Future<bool> loadUpdateCheckConsentGranted();
  Future<void> saveUpdateCheckConsentGranted(bool granted);
}

abstract class AppVersionRepository {
  Future<AppVersionInfo> loadInstalledVersion();
}

abstract class AppUpdateRepository {
  Future<AppReleaseInfo> fetchLatestRelease();
}

abstract class TunnelRepository {
  Stream<TunnelHostUpdate> get tunnelStates;
  Stream<EngineLogMessage> get engineLogs;
  Stream<ProxyExposure> get proxyExposures;
  Stream<BatteryOptimizationStatus> get batteryOptimizationStatuses;
  Stream<void> get quickSettingsConnectRequests;

  Future<bool> prepareVpn();
  Future<TunnelRuntimeState> getRuntimeState();
  Future<void> syncQuickSettingsProfile(QuickSettingsProfileConfig? config);
  Future<bool> consumePendingQuickSettingsConnect();
  Future<void> connect(TunnelConnectRequest request);
  Future<void> disconnect({
    required ConnectionMode connectionMode,
    String attemptId = '',
  });
  Future<void> setLogLevel(LogDisplayLevel level);
  Future<BatteryOptimizationStatus> getBatteryOptimizationStatus();
  Future<BatteryOptimizationRequestResult> requestIgnoreBatteryOptimizations();
  Future<BatteryOptimizationRequestResult> openBatteryOptimizationSettings();
  Future<BatteryOptimizationRequestResult> openManufacturerBackgroundSettings();
  Future<List<CandidateApp>> listVpnCandidateApps();
  Future<Uint8List?> getAppIcon(String packageName);
  Future<bool?> checkProxyPortAvailable(
    int port, {
    required bool allowLanConnections,
  });
  void dispose();
}

abstract class ConnectivityRepository {
  Future<ConnectivityPingResult> ping(
    ConnectivityPingRequest request, {
    Future<void>? cancelSignal,
  });
}

abstract class ProfileTransferRepository {
  Stream<IncomingProfileTransfer> get incomingTransfers;
  Future<List<IncomingProfileTransfer>> start();
  Future<void> dispose();
}

abstract class SubscriptionsRepository {
  Future<List<Subscription>> loadSubscriptions();
  Future<SubscriptionSyncSummary> addAndSyncSubscription({
    required String name,
    required String url,
    required bool autoUpdate,
    required int updateIntervalMinutes,
    required SubscriptionIntervalUnit intervalUnit,
  });
  Future<void> saveSubscriptionSettings(Subscription subscription);
  Future<SubscriptionSyncSummary?> syncSubscriptionById(
    String subscriptionId, {
    required SubscriptionSyncTrigger trigger,
  });
  Future<({int removedProfilesCount})> deleteSubscription(
    String subscriptionId,
  );
  Future<void> syncSchedules(List<Subscription> subscriptions);
  Future<bool> requestNotificationPermission();
  Future<List<SubscriptionSyncSummary>> consumePendingSummaries();
  Future<void> reloadStore();
  void setScheduledUpdateHandler(ScheduledSubscriptionUpdateHandler? handler);
  void dispose();
}

abstract class LogsRepository {
  List<LogEntry> get entries;
  Stream<List<LogEntry>> get entriesStream;
  Future<void> loadPersisted();
  void append(LogEntry entry);
  void clear();
}

extension LogsRepositoryDartLog on LogsRepository {
  void logDart(LogLevel level, String tag, String message) {
    append(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        source: LogSource.dart,
        tag: tag,
        message: message,
      ),
    );
  }
}
