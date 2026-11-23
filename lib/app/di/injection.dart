import 'dart:async';

import 'package:get_it/get_it.dart';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/core/network/connectivity_checker.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_sync_service.dart';
import 'package:tunnel_forge/features/tunnel/data/vpn_client.dart';
import 'package:tunnel_forge/features/onboarding/data/shared_prefs_onboarding_repository.dart';
import 'package:tunnel_forge/features/onboarding/domain/onboarding_repository.dart';
import 'package:tunnel_forge/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:tunnel_forge/features/app_theme/data/shared_prefs_theme_repository.dart';
import 'package:tunnel_forge/features/app_theme/domain/theme_repository.dart';
import 'package:tunnel_forge/features/app_theme/presentation/bloc/app_theme_bloc.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/connectivity_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/home_nav_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/logs_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/profiles_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/settings_bloc.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/tunnel_bloc.dart';

GetIt createAppLocator({
  ProfileStore? profileStore,
  ConnectivityChecker? connectivityChecker,
  VpnClient? vpnClient,
  ProfileTransferBridge? profileTransferBridge,
  SubscriptionBridge? subscriptionBridge,
  SubscriptionHttpClient? subscriptionHttpClient,
  AppVersionRepository? appVersionRepository,
  AppUpdateRepository? appUpdateRepository,
  OnboardingRepository? onboardingRepository,
  bool? skipOnboardingDisclosure,
}) {
  final locator = GetIt.asNewInstance();

  locator.registerLazySingleton<ProfileStore>(
    () =>
        profileStore ??
        ProfileStore(
          onLog: (level, message) {
            locator<LogsRepository>().append(
              LogEntry(
                timestamp: DateTime.now(),
                level: level,
                source: LogSource.dart,
                tag: 'ProfileStore',
                message: message,
              ),
            );
          },
        ),
  );
  locator.registerLazySingleton<ConnectivityChecker>(
    () => connectivityChecker ?? HttpConnectivityChecker(),
  );
  locator.registerLazySingleton<ThemeRepository>(
    SharedPrefsThemeRepository.new,
  );
  locator.registerLazySingleton<OnboardingRepository>(
    () => onboardingRepository ?? SharedPrefsOnboardingRepository(),
  );
  locator.registerLazySingleton<ProfilesRepository>(
    () => ProfilesRepositoryImpl(locator<ProfileStore>()),
  );
  locator.registerLazySingleton<SettingsRepository>(
    () => SettingsRepositoryImpl(locator<ProfileStore>()),
  );
  locator.registerLazySingleton<AppVersionRepository>(
    () => appVersionRepository ?? AppVersionRepositoryImpl(),
  );
  locator.registerLazySingleton<AppUpdateRepository>(
    () => appUpdateRepository ?? AppUpdateRepositoryImpl(),
  );
  locator.registerLazySingleton<TunnelRepository>(
    () => TunnelRepositoryImpl(client: vpnClient),
    dispose: (repo) => repo.dispose(),
  );
  locator.registerLazySingleton<ConnectivityRepository>(
    () => ConnectivityRepositoryImpl(locator<ConnectivityChecker>()),
  );
  locator.registerLazySingleton<ProfileTransferRepository>(
    () => ProfileTransferRepositoryImpl(bridge: profileTransferBridge),
    dispose: (repo) => repo.dispose(),
  );
  locator.registerLazySingleton<SubscriptionBridge>(
    () => subscriptionBridge ?? SubscriptionBridge(),
    dispose: (bridge) => bridge.dispose(),
  );
  locator.registerLazySingleton<SubscriptionHttpClient>(
    () => subscriptionHttpClient ?? DartSubscriptionHttpClient(),
  );
  locator.registerLazySingleton<SubscriptionSyncService>(
    () => SubscriptionSyncService(
      profileStore: locator<ProfileStore>(),
      bridge: locator<SubscriptionBridge>(),
      httpClient: locator<SubscriptionHttpClient>(),
      onLog: (level, message) =>
          locator<LogsRepository>().logDart(level, 'subscriptions', message),
    ),
  );
  locator.registerLazySingleton<SubscriptionsRepository>(
    () => SubscriptionsRepositoryImpl(
      profileStore: locator<ProfileStore>(),
      syncService: locator<SubscriptionSyncService>(),
      bridge: locator<SubscriptionBridge>(),
    ),
    dispose: (repo) => repo.dispose(),
  );
  locator.registerSingleton<LogsRepository>(
    LogsRepositoryImpl(),
    dispose: (repo) => repo is LogsRepositoryImpl ? repo.dispose() : null,
  );

  locator.registerFactory<AppThemeBloc>(
    () => AppThemeBloc(
      locator<ThemeRepository>(),
      logsRepository: locator<LogsRepository>(),
    ),
  );
  locator.registerFactory<OnboardingBloc>(
    () => OnboardingBloc(
      locator<OnboardingRepository>(),
      skipDisclosureSteps: skipOnboardingDisclosure,
      logsRepository: locator<LogsRepository>(),
    ),
  );
  locator.registerFactory<HomeNavBloc>(HomeNavBloc.new);
  locator.registerFactory<ProfilesBloc>(
    () => ProfilesBloc(
      locator<ProfilesRepository>(),
      locator<ProfileTransferRepository>(),
      subscriptionsRepository: locator<SubscriptionsRepository>(),
      logsRepository: locator<LogsRepository>(),
    ),
  );
  locator.registerFactory<SettingsBloc>(
    () => SettingsBloc(
      locator<SettingsRepository>(),
      locator<AppVersionRepository>(),
      locator<AppUpdateRepository>(),
      locator<LogsRepository>(),
      locator<TunnelRepository>(),
    ),
  );
  locator.registerFactory<LogsBloc>(
    () => LogsBloc(
      locator<LogsRepository>(),
      locator<SettingsRepository>(),
      locator<TunnelRepository>(),
    ),
  );
  locator.registerFactory<TunnelBloc>(
    () => TunnelBloc(locator<TunnelRepository>(), locator<LogsRepository>()),
  );
  locator.registerFactory<ConnectivityBloc>(
    () => ConnectivityBloc(
      locator<ConnectivityRepository>(),
      locator<LogsRepository>(),
    ),
  );

  return locator;
}

void disposeLocator(GetIt locator) {
  unawaited(locator.reset(dispose: true));
}
