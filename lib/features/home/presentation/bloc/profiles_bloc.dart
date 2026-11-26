import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_contract.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import '../../../home/data/home_repositories_impl.dart';
import '../../../home/domain/home_models.dart';
import '../../../home/domain/home_repositories.dart';
import '../../../home/domain/log_redaction.dart';

sealed class ProfilesEvent extends Equatable {
  const ProfilesEvent();

  @override
  List<Object?> get props => const [];
}

final class ProfilesStarted extends ProfilesEvent {
  const ProfilesStarted();
}

final class ProfilesSelectionChanged extends ProfilesEvent {
  const ProfilesSelectionChanged(this.id);

  final String? id;

  @override
  List<Object?> get props => [id];
}

final class ProfilesImportRequested extends ProfilesEvent {
  const ProfilesImportRequested(this.request);

  final ImportTransferRequest request;

  @override
  List<Object?> get props => [request];
}

final class ProfilesImportBatchRequested extends ProfilesEvent {
  const ProfilesImportBatchRequested(
    this.transfers, {
    required this.selectAsLastProfile,
  });

  final List<IncomingProfileTransfer> transfers;
  final bool selectAsLastProfile;

  @override
  List<Object?> get props => [transfers, selectAsLastProfile];
}

final class ProfilesDeleteRequested extends ProfilesEvent {
  const ProfilesDeleteRequested(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

final class ProfilesDeleteMultipleRequested extends ProfilesEvent {
  const ProfilesDeleteMultipleRequested(this.ids);

  final List<String> ids;

  @override
  List<Object?> get props => [ids];
}

final class ProfilesRefreshRequested extends ProfilesEvent {
  const ProfilesRefreshRequested({
    this.preferredActiveId,
    this.editedProfileId,
  });

  final String? preferredActiveId;
  final String? editedProfileId;

  @override
  List<Object?> get props => [preferredActiveId, editedProfileId];
}

final class ProfilesCopyShareLinkRequested extends ProfilesEvent {
  const ProfilesCopyShareLinkRequested(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

final class ProfilesCopyShareLinksRequested extends ProfilesEvent {
  const ProfilesCopyShareLinksRequested(this.ids);

  final List<String> ids;

  @override
  List<Object?> get props => [ids];
}

final class ProfilesExportFileRequested extends ProfilesEvent {
  const ProfilesExportFileRequested(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

final class ProfilesExportFilesRequested extends ProfilesEvent {
  const ProfilesExportFilesRequested(this.ids, {this.combined = false});

  final List<String> ids;
  final bool combined;

  @override
  List<Object?> get props => [ids, combined];
}

final class ProfilesImportSelectionPolicyChanged extends ProfilesEvent {
  const ProfilesImportSelectionPolicyChanged(
    this.selectImportedProfileWhenIdle,
  );

  final bool selectImportedProfileWhenIdle;

  @override
  List<Object?> get props => [selectImportedProfileWhenIdle];
}

final class ProfilesFavoriteToggled extends ProfilesEvent {
  const ProfilesFavoriteToggled(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

final class ProfilesGroupReordered extends ProfilesEvent {
  const ProfilesGroupReordered({
    required this.favoritesSection,
    required this.oldIndex,
    required this.newIndex,
    this.subscriptionId,
    this.filterBySubscription = false,
  });

  final bool favoritesSection;
  final int oldIndex;
  final int newIndex;
  final String? subscriptionId;
  final bool filterBySubscription;

  @override
  List<Object?> get props => [
    favoritesSection,
    oldIndex,
    newIndex,
    subscriptionId,
    filterBySubscription,
  ];
}

final class ProfilesSubscriptionAddRequested extends ProfilesEvent {
  const ProfilesSubscriptionAddRequested({
    required this.name,
    required this.url,
    required this.autoUpdate,
    required this.updateIntervalMinutes,
    required this.intervalUnit,
  });

  final String name;
  final String url;
  final bool autoUpdate;
  final int updateIntervalMinutes;
  final SubscriptionIntervalUnit intervalUnit;

  @override
  List<Object?> get props => [
    name,
    url,
    autoUpdate,
    updateIntervalMinutes,
    intervalUnit,
  ];
}

final class ProfilesSubscriptionEditRequested extends ProfilesEvent {
  const ProfilesSubscriptionEditRequested({
    required this.subscription,
    required this.urlChanged,
    required this.autoUpdateNewlyEnabled,
  });

  final Subscription subscription;
  final bool urlChanged;
  final bool autoUpdateNewlyEnabled;

  @override
  List<Object?> get props => [subscription, urlChanged, autoUpdateNewlyEnabled];
}

final class ProfilesSubscriptionSyncRequested extends ProfilesEvent {
  const ProfilesSubscriptionSyncRequested(
    this.subscriptionId, {
    this.trigger = SubscriptionSyncTrigger.manual,
  });

  final String subscriptionId;
  final SubscriptionSyncTrigger trigger;

  @override
  List<Object?> get props => [subscriptionId, trigger];
}

final class ProfilesSubscriptionDeleteRequested extends ProfilesEvent {
  const ProfilesSubscriptionDeleteRequested(this.subscriptionId);

  final String subscriptionId;

  @override
  List<Object?> get props => [subscriptionId];
}

final class ProfilesDueSubscriptionsCheckRequested extends ProfilesEvent {
  const ProfilesDueSubscriptionsCheckRequested();
}

final class _ProfilesScheduledSubscriptionSyncRequested extends ProfilesEvent {
  const _ProfilesScheduledSubscriptionSyncRequested(
    this.subscriptionId,
    this.completer,
  );

  final String subscriptionId;
  final Completer<String> completer;

  @override
  List<Object?> get props => [subscriptionId];
}

enum ActiveProfileTunnelAction { reconnect, disconnect }

class ActiveProfileTunnelEffect extends Equatable {
  const ActiveProfileTunnelEffect._({
    required this.id,
    required this.action,
    this.row,
  });

  const ActiveProfileTunnelEffect.reconnect({
    required int id,
    required ProfileSecretRow row,
  }) : this._(id: id, action: ActiveProfileTunnelAction.reconnect, row: row);

  const ActiveProfileTunnelEffect.disconnect({required int id})
    : this._(id: id, action: ActiveProfileTunnelAction.disconnect);

  final int id;
  final ActiveProfileTunnelAction action;
  final ProfileSecretRow? row;

  @override
  List<Object?> get props => [id, action, row];
}

class ProfilesState extends Equatable {
  const ProfilesState({
    this.loading = true,
    this.profiles = const <Profile>[],
    this.subscriptions = const <Subscription>[],
    this.updatingSubscriptionIds = const <String>{},
    this.subscriptionSubmitting = false,
    this.subscriptionSubmissionId = 0,
    this.subscriptionSubmissionError,
    this.lastSavedSubscriptionId,
    this.pendingSummaryEvent,
    this.activeProfileId,
    this.activeProfileRow,
    this.selectImportedProfileWhenIdle = true,
    this.message,
    this.pendingTunnelEffect,
  });

  final bool loading;
  final List<Profile> profiles;
  final List<Subscription> subscriptions;
  final Set<String> updatingSubscriptionIds;
  final bool subscriptionSubmitting;
  final int subscriptionSubmissionId;
  final String? subscriptionSubmissionError;
  final String? lastSavedSubscriptionId;
  final SubscriptionSyncSummaryEvent? pendingSummaryEvent;
  final String? activeProfileId;
  final ProfileSecretRow? activeProfileRow;
  final bool selectImportedProfileWhenIdle;
  final HomeMessage? message;
  final ActiveProfileTunnelEffect? pendingTunnelEffect;

  bool get hasActiveProfile {
    final activeId = activeProfileId;
    return activeId != null &&
        profiles.any((profile) => profile.id == activeId);
  }

  ProfilesState copyWith({
    bool? loading,
    List<Profile>? profiles,
    List<Subscription>? subscriptions,
    Set<String>? updatingSubscriptionIds,
    bool? subscriptionSubmitting,
    int? subscriptionSubmissionId,
    String? subscriptionSubmissionError,
    bool clearSubscriptionSubmissionError = false,
    String? lastSavedSubscriptionId,
    bool clearLastSavedSubscriptionId = false,
    SubscriptionSyncSummaryEvent? pendingSummaryEvent,
    bool clearPendingSummaryEvent = false,
    String? activeProfileId,
    bool clearActiveProfileId = false,
    ProfileSecretRow? activeProfileRow,
    bool clearActiveProfileRow = false,
    bool? selectImportedProfileWhenIdle,
    HomeMessage? message,
    bool clearMessage = false,
    ActiveProfileTunnelEffect? pendingTunnelEffect,
    bool clearPendingTunnelEffect = false,
  }) {
    return ProfilesState(
      loading: loading ?? this.loading,
      profiles: profiles ?? this.profiles,
      subscriptions: subscriptions ?? this.subscriptions,
      updatingSubscriptionIds:
          updatingSubscriptionIds ?? this.updatingSubscriptionIds,
      subscriptionSubmitting:
          subscriptionSubmitting ?? this.subscriptionSubmitting,
      subscriptionSubmissionId:
          subscriptionSubmissionId ?? this.subscriptionSubmissionId,
      subscriptionSubmissionError: clearSubscriptionSubmissionError
          ? null
          : (subscriptionSubmissionError ?? this.subscriptionSubmissionError),
      lastSavedSubscriptionId: clearLastSavedSubscriptionId
          ? null
          : (lastSavedSubscriptionId ?? this.lastSavedSubscriptionId),
      pendingSummaryEvent: clearPendingSummaryEvent
          ? null
          : (pendingSummaryEvent ?? this.pendingSummaryEvent),
      activeProfileId: clearActiveProfileId
          ? null
          : (activeProfileId ?? this.activeProfileId),
      activeProfileRow: clearActiveProfileRow
          ? null
          : (activeProfileRow ?? this.activeProfileRow),
      selectImportedProfileWhenIdle:
          selectImportedProfileWhenIdle ?? this.selectImportedProfileWhenIdle,
      message: clearMessage ? null : (message ?? this.message),
      pendingTunnelEffect: clearPendingTunnelEffect
          ? null
          : (pendingTunnelEffect ?? this.pendingTunnelEffect),
    );
  }

  @override
  List<Object?> get props => [
    loading,
    profiles,
    subscriptions,
    updatingSubscriptionIds,
    subscriptionSubmitting,
    subscriptionSubmissionId,
    subscriptionSubmissionError,
    lastSavedSubscriptionId,
    pendingSummaryEvent,
    activeProfileId,
    activeProfileRow,
    selectImportedProfileWhenIdle,
    message,
    pendingTunnelEffect,
  ];
}

class ProfilesBloc extends Bloc<ProfilesEvent, ProfilesState> {
  ProfilesBloc(
    this._profilesRepository,
    this._transferRepository, {
    SubscriptionsRepository? subscriptionsRepository,
    LogsRepository? logsRepository,
    DateTime Function()? clock,
  }) : _subscriptionsRepository = subscriptionsRepository,
       _logsRepository = logsRepository,
       _clock = clock ?? DateTime.now,
       super(const ProfilesState()) {
    on<ProfilesStarted>(_onStarted);
    on<ProfilesSelectionChanged>(_onSelectionChanged);
    on<ProfilesImportRequested>(_onImportRequested);
    on<ProfilesImportBatchRequested>(_onImportBatchRequested);
    on<ProfilesDeleteRequested>(_onDeleteRequested);
    on<ProfilesDeleteMultipleRequested>(_onDeleteMultipleRequested);
    on<ProfilesRefreshRequested>(_onRefreshRequested);
    on<ProfilesCopyShareLinkRequested>(_onCopyShareLinkRequested);
    on<ProfilesCopyShareLinksRequested>(_onCopyShareLinksRequested);
    on<ProfilesExportFileRequested>(_onExportFileRequested);
    on<ProfilesExportFilesRequested>(_onExportFilesRequested);
    on<ProfilesImportSelectionPolicyChanged>(_onImportSelectionPolicyChanged);
    on<ProfilesFavoriteToggled>(_onFavoriteToggled);
    on<ProfilesGroupReordered>(_onGroupReordered);
    on<ProfilesSubscriptionAddRequested>(_onSubscriptionAddRequested);
    on<ProfilesSubscriptionEditRequested>(_onSubscriptionEditRequested);
    on<ProfilesSubscriptionSyncRequested>(_onSubscriptionSyncRequested);
    on<ProfilesSubscriptionDeleteRequested>(_onSubscriptionDeleteRequested);
    on<ProfilesDueSubscriptionsCheckRequested>(
      _onDueSubscriptionsCheckRequested,
    );
    on<_ProfilesScheduledSubscriptionSyncRequested>(
      _onScheduledSubscriptionSyncRequested,
    );
  }

  final ProfilesRepository _profilesRepository;
  final ProfileTransferRepository _transferRepository;
  final SubscriptionsRepository? _subscriptionsRepository;
  final LogsRepository? _logsRepository;
  final DateTime Function() _clock;
  StreamSubscription<IncomingProfileTransfer>? _transferSub;
  int _messageId = 0;
  int _summaryEventId = 0;
  int _tunnelEffectId = 0;

  void _log(LogLevel level, String message) {
    _logsRepository?.logDart(level, 'profiles', message);
  }

  String _describeTransferSource(IncomingProfileTransfer transfer) {
    final source = transfer.source;
    if (source == 'Clipboard') return 'origin=clipboard';
    if (source != null && source.isNotEmpty) {
      return 'origin=file file=${quoteLogValue(source)}';
    }
    return 'origin=file';
  }

  Future<void> _onStarted(
    ProfilesStarted event,
    Emitter<ProfilesState> emit,
  ) async {
    await _profilesRepository.checkSecureStorageUpgrade();
    await _reloadProfiles(
      emit,
      preferredActiveId: await _profilesRepository.loadLastProfileId(),
    );
    await _transferSub?.cancel();
    _transferSub = _transferRepository.incomingTransfers.listen(
      _queueIncomingTransfer,
    );
    final pendingTransfers = await _transferRepository.start();
    for (final transfer in pendingTransfers) {
      _queueIncomingTransfer(transfer);
    }
    final subsRepo = _subscriptionsRepository;
    if (subsRepo != null) {
      subsRepo.setScheduledUpdateHandler(_handleScheduledUpdate);
      await subsRepo.syncSchedules(state.subscriptions);
      final pendingSummaries = await subsRepo.consumePendingSummaries();
      if (pendingSummaries.isNotEmpty) {
        emit(
          state.copyWith(
            pendingSummaryEvent: _nextSummaryEvent(pendingSummaries),
          ),
        );
      }
      if (state.subscriptions.any((s) => s.isDueAt(_clock()))) {
        add(const ProfilesDueSubscriptionsCheckRequested());
      }
    }
  }

  Future<void> _onSelectionChanged(
    ProfilesSelectionChanged event,
    Emitter<ProfilesState> emit,
  ) async {
    if (event.id == null) {
      await _profilesRepository.setLastProfileId(null);
      _log(LogLevel.debug, 'Profile selection cleared');
      emit(
        state.copyWith(clearActiveProfileId: true, clearActiveProfileRow: true),
      );
      return;
    }
    final row = await _profilesRepository.loadProfileWithSecrets(event.id!);
    if (row == null) {
      _log(
        LogLevel.warning,
        'Profile selection failed: missing profile=${event.id}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(
            AppL10n.current.profileNoLongerExists,
            error: true,
          ),
        ),
      );
      return;
    }
    await _profilesRepository.setLastProfileId(event.id);
    _log(
      LogLevel.debug,
      'Profile selected profile=${event.id} '
      'name=${quoteLogValue(row.profile.displayName)} '
      'server=${row.profile.server} favorite=${row.profile.favorite}',
    );
    emit(state.copyWith(activeProfileId: event.id, activeProfileRow: row));
  }

  Future<void> _onImportRequested(
    ProfilesImportRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final transfer = event.request.transfer;
    final sourceDesc = _describeTransferSource(transfer);
    final t = AppL10n.current;
    if (transfer.isError) {
      _log(
        LogLevel.warning,
        'Profile import failed $sourceDesc type=${transfer.type} reason=transfer_error',
      );
      emit(
        state.copyWith(
          message: _nextMessage(
            transfer.message ?? t.couldNotOpenIncomingProfile,
            error: true,
          ),
        ),
      );
      return;
    }
    try {
      final envelopes = ProfileTransferEnvelope.fromIncomingTransferList(
        transfer,
      );
      final imported = await _profilesRepository.saveImportedProfiles(
        envelopes,
        selectAsLastProfile: event.request.selectAsLastProfile,
      );
      _log(
        LogLevel.debug,
        'Imported profiles count=${imported.length} $sourceDesc type=${transfer.type} '
        'selected=${event.request.selectAsLastProfile} '
        'ids=${imported.map((p) => p.id).join(',')}',
      );
      await _reloadProfiles(
        emit,
        preferredActiveId:
            event.request.selectAsLastProfile && imported.isNotEmpty
            ? imported.last.id
            : null,
      );
      final source = switch ((transfer.source, transfer.type)) {
        ('Clipboard', ProfileTransferContract.typeTfUri) =>
          t.importSourceClipboardLink,
        ('Clipboard', _) => t.importSourceClipboard,
        (_, ProfileTransferContract.typeTfUri) => t.importSourceShareLink,
        _ => t.importSourceTfpFile,
      };
      final count = imported.length;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1
                ? t.importedProfileNamedFromSource(
                    imported.single.displayName,
                    source,
                  )
                : t.importedProfilesCountFromSource(count, source),
          ),
        ),
      );
    } on ProfileTransferFormatException catch (error) {
      _log(
        LogLevel.warning,
        'Profile import failed $sourceDesc type=${transfer.type} reason=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(error.localizedMessage(t), error: true),
        ),
      );
    } on FormatException catch (error) {
      _log(
        LogLevel.warning,
        'Profile import failed $sourceDesc type=${transfer.type} reason=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(t.profileTransferInvalidFile, error: true),
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Profile import failed $sourceDesc type=${transfer.type} reason=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(t.couldNotImportProfile, error: true),
        ),
      );
    }
  }

  Future<void> _onImportBatchRequested(
    ProfilesImportBatchRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    if (event.transfers.isEmpty) return;
    final t = AppL10n.current;
    try {
      final envelopes = <ProfileTransferEnvelope>[];
      for (final transfer in event.transfers) {
        if (transfer.isError) {
          throw FormatException(
            transfer.message ?? t.couldNotOpenIncomingProfile,
          );
        }
        envelopes.add(ProfileTransferEnvelope.fromIncomingTransfer(transfer));
      }
      final imported = await _profilesRepository.saveImportedProfiles(
        envelopes,
        selectAsLastProfile: event.selectAsLastProfile,
      );
      _log(
        LogLevel.debug,
        'Imported profiles batch count=${imported.length} origin=clipboard '
        'selected=${event.selectAsLastProfile} '
        'ids=${imported.map((p) => p.id).join(',')}',
      );
      await _reloadProfiles(
        emit,
        preferredActiveId: event.selectAsLastProfile && imported.isNotEmpty
            ? imported.last.id
            : null,
      );
      final count = imported.length;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1
                ? t.importedProfileNamedFromClipboard(
                    imported.single.displayName,
                  )
                : t.importedProfilesCountFromClipboard(count),
          ),
        ),
      );
    } on ProfileTransferFormatException catch (error) {
      _log(
        LogLevel.warning,
        'Profile batch import failed origin=clipboard count=${event.transfers.length} reason=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(error.localizedMessage(t), error: true),
        ),
      );
    } on FormatException catch (error) {
      _log(
        LogLevel.warning,
        'Profile batch import failed origin=clipboard count=${event.transfers.length} reason=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(t.profileTransferInvalidFile, error: true),
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Profile batch import failed origin=clipboard count=${event.transfers.length} reason=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(t.couldNotImportProfiles, error: true),
        ),
      );
    }
  }

  Future<void> _onDeleteRequested(
    ProfilesDeleteRequested event,
    Emitter<ProfilesState> emit,
  ) => _deleteProfiles([event.id], emit);

  Future<void> _onDeleteMultipleRequested(
    ProfilesDeleteMultipleRequested event,
    Emitter<ProfilesState> emit,
  ) => _deleteProfiles(event.ids, emit);

  Future<void> _deleteProfiles(
    List<String> ids,
    Emitter<ProfilesState> emit,
  ) async {
    final uniqueIds = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (uniqueIds.isEmpty) return;
    try {
      await _profilesRepository.deleteProfiles(uniqueIds);
      _log(
        LogLevel.debug,
        'Deleted profiles count=${uniqueIds.length} ids=${uniqueIds.join(',')}',
      );
      final shouldSelectFallback =
          state.activeProfileId != null &&
          uniqueIds.contains(state.activeProfileId);
      final nextId = shouldSelectFallback ? null : state.activeProfileId;
      await _reloadProfiles(emit, preferredActiveId: nextId);
      if (shouldSelectFallback &&
          state.activeProfileId == null &&
          state.profiles.isNotEmpty) {
        add(ProfilesSelectionChanged(state.profiles.first.id));
      }
      final count = uniqueIds.length;
      final t = AppL10n.current;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1 ? t.profileRemoved : t.profilesRemovedCount(count),
          ),
          pendingTunnelEffect: shouldSelectFallback
              ? _nextTunnelDisconnectEffect()
              : null,
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Delete profiles failed count=${uniqueIds.length} error=${error.runtimeType}',
      );
      final count = uniqueIds.length;
      final t = AppL10n.current;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1 ? t.couldNotDeleteProfile : t.couldNotDeleteProfiles,
            error: true,
          ),
        ),
      );
    }
  }

  Future<void> _onRefreshRequested(
    ProfilesRefreshRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final previousActiveId = state.activeProfileId;
    await _reloadProfiles(
      emit,
      preferredActiveId: event.preferredActiveId ?? state.activeProfileId,
    );
    if (event.editedProfileId != null &&
        event.editedProfileId == previousActiveId &&
        state.activeProfileId == previousActiveId &&
        state.activeProfileRow != null) {
      emit(
        state.copyWith(
          pendingTunnelEffect: _nextTunnelReconnectEffect(
            state.activeProfileRow!,
          ),
        ),
      );
    }
  }

  Future<void> _onCopyShareLinkRequested(
    ProfilesCopyShareLinkRequested event,
    Emitter<ProfilesState> emit,
  ) => _copyShareLinks([event.id], emit);

  Future<void> _onCopyShareLinksRequested(
    ProfilesCopyShareLinksRequested event,
    Emitter<ProfilesState> emit,
  ) => _copyShareLinks(event.ids, emit);

  Future<void> _copyShareLinks(
    List<String> ids,
    Emitter<ProfilesState> emit,
  ) async {
    if (ids.isEmpty) return;
    final t = AppL10n.current;
    try {
      await _profilesRepository.copyProfileShareLinks(ids);
      _log(LogLevel.debug, 'Copied share links count=${ids.length}');
      final count = ids.length;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1 ? t.shareLinkCopied : t.shareLinksCopiedCount(count),
          ),
        ),
      );
    } on ProfileRepositoryException catch (error) {
      _log(
        LogLevel.warning,
        'Copy share links failed count=${ids.length} reason=repository_exception',
      );
      emit(
        state.copyWith(
          message: _nextMessage(error.localizedMessage(t), error: true),
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Copy share links failed count=${ids.length} error=${error.runtimeType}',
      );
      final count = ids.length;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1 ? t.couldNotCopyShareLink : t.couldNotCopyShareLinks,
            error: true,
          ),
        ),
      );
    }
  }

  Future<void> _onExportFileRequested(
    ProfilesExportFileRequested event,
    Emitter<ProfilesState> emit,
  ) => _exportFiles([event.id], emit);

  Future<void> _onExportFilesRequested(
    ProfilesExportFilesRequested event,
    Emitter<ProfilesState> emit,
  ) => _exportFiles(event.ids, emit, combined: event.combined);

  Future<void> _exportFiles(
    List<String> ids,
    Emitter<ProfilesState> emit, {
    bool combined = false,
  }) async {
    if (ids.isEmpty) return;
    final t = AppL10n.current;
    try {
      await _profilesRepository.exportProfileFiles(ids, combined: combined);
      _log(
        LogLevel.debug,
        'Exported profile files count=${ids.length} combined=$combined',
      );
      final count = ids.length;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1 || combined
                ? t.profileFileReady
                : t.profileFilesReadyCount(count),
          ),
        ),
      );
    } on ProfileRepositoryException catch (error) {
      _log(
        LogLevel.warning,
        'Export profile files failed count=${ids.length} combined=$combined reason=repository_exception',
      );
      emit(
        state.copyWith(
          message: _nextMessage(error.localizedMessage(t), error: true),
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Export profile files failed count=${ids.length} combined=$combined error=${error.runtimeType}',
      );
      final count = ids.length;
      emit(
        state.copyWith(
          message: _nextMessage(
            count == 1 || combined
                ? t.couldNotExportTfpFile
                : t.couldNotExportTfpFiles,
            error: true,
          ),
        ),
      );
    }
  }

  void _onImportSelectionPolicyChanged(
    ProfilesImportSelectionPolicyChanged event,
    Emitter<ProfilesState> emit,
  ) {
    emit(
      state.copyWith(
        selectImportedProfileWhenIdle: event.selectImportedProfileWhenIdle,
      ),
    );
  }

  Future<void> _onFavoriteToggled(
    ProfilesFavoriteToggled event,
    Emitter<ProfilesState> emit,
  ) async {
    try {
      final result = await _profilesRepository.toggleProfileFavorite(event.id);
      if (result.limitReached) {
        _log(
          LogLevel.debug,
          'Favorite limit reached max=${Profile.maxFavorites} profile=${event.id}',
        );
        emit(
          state.copyWith(
            message: _nextMessage(
              AppL10n.current.favoriteLimitReached(Profile.maxFavorites),
            ),
          ),
        );
        return;
      }
      final favoritesCount = result.profiles.where((p) => p.favorite).length;
      _log(
        LogLevel.debug,
        'Profile ${result.favorite ? 'favorited' : 'unfavorited'} '
        'profile=${event.id} favoritesCount=$favoritesCount',
      );
      final currentActiveRow = state.activeProfileRow;
      var nextActiveRow = currentActiveRow;
      if (currentActiveRow != null && currentActiveRow.profile.id == event.id) {
        for (final profile in result.profiles) {
          if (profile.id == event.id) {
            nextActiveRow = ProfileSecretRow(
              profile: profile,
              password: currentActiveRow.password,
              psk: currentActiveRow.psk,
              secretsMissing: currentActiveRow.secretsMissing,
            );
            break;
          }
        }
      }
      emit(
        state.copyWith(
          profiles: result.profiles,
          activeProfileRow: nextActiveRow,
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Profile favorite toggle failed profile=${event.id} error=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(
            AppL10n.current.couldNotUpdateFavoriteProfile,
            error: true,
          ),
        ),
      );
    }
  }

  Future<void> _onGroupReordered(
    ProfilesGroupReordered event,
    Emitter<ProfilesState> emit,
  ) async {
    final nextProfiles = ProfileStore.reorderProfileSection(
      state.profiles,
      favoritesSection: event.favoritesSection,
      oldIndex: event.oldIndex,
      newIndex: event.newIndex,
      subscriptionId: event.subscriptionId,
      filterBySubscription: event.filterBySubscription,
    );
    if (_sameProfileOrder(state.profiles, nextProfiles)) return;
    // Emit immediately so SliverReorderableList does not snap back before disk write finishes.
    emit(state.copyWith(profiles: nextProfiles));
    try {
      final persisted = await _profilesRepository.reorderProfiles(
        favoritesSection: event.favoritesSection,
        oldIndex: event.oldIndex,
        newIndex: event.newIndex,
        subscriptionId: event.subscriptionId,
        filterBySubscription: event.filterBySubscription,
      );
      _log(
        LogLevel.debug,
        'Profiles reordered section=${event.favoritesSection ? 'favorites' : 'others'} '
        'oldIndex=${event.oldIndex} newIndex=${event.newIndex}',
      );
      if (!_sameProfileOrder(state.profiles, persisted)) {
        emit(state.copyWith(profiles: persisted));
      }
    } catch (error) {
      _log(
        LogLevel.warning,
        'Profiles reorder failed section=${event.favoritesSection ? 'favorites' : 'others'} '
        'error=${error.runtimeType}',
      );
      await _reloadProfiles(emit, preferredActiveId: state.activeProfileId);
      emit(
        state.copyWith(
          message: _nextMessage(
            AppL10n.current.couldNotSaveProfileOrder,
            error: true,
          ),
        ),
      );
    }
  }

  Future<String> _handleScheduledUpdate(
    String subscriptionId, {
    required bool isBackground,
  }) {
    if (isClosed) {
      return Future<String>.value(SubscriptionContract.outcomeRetry);
    }
    final completer = Completer<String>();
    add(_ProfilesScheduledSubscriptionSyncRequested(subscriptionId, completer));
    return completer.future;
  }

  Future<void> _onSubscriptionAddRequested(
    ProfilesSubscriptionAddRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final subsRepo = _subscriptionsRepository;
    if (subsRepo == null) return;
    final t = AppL10n.current;
    emit(
      state.copyWith(
        subscriptionSubmitting: true,
        clearSubscriptionSubmissionError: true,
        clearMessage: true,
      ),
    );
    try {
      if (event.autoUpdate) {
        await subsRepo.requestNotificationPermission();
      }
      final summary = await subsRepo.addAndSyncSubscription(
        name: event.name,
        url: event.url,
        autoUpdate: event.autoUpdate,
        updateIntervalMinutes: event.updateIntervalMinutes,
        intervalUnit: event.intervalUnit,
      );
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      await subsRepo.syncSchedules(state.subscriptions);
      emit(
        state.copyWith(
          subscriptionSubmitting: false,
          subscriptionSubmissionId: state.subscriptionSubmissionId + 1,
          clearSubscriptionSubmissionError: true,
          lastSavedSubscriptionId: summary.subscriptionId,
          pendingSummaryEvent: _nextSummaryEvent([summary]),
        ),
      );
    } on SubscriptionException catch (error) {
      final msg = error.localizedMessage(t);
      emit(
        state.copyWith(
          subscriptionSubmitting: false,
          subscriptionSubmissionId: state.subscriptionSubmissionId + 1,
          subscriptionSubmissionError: msg,
          message: _nextMessage(msg, error: true),
        ),
      );
    } catch (_) {
      final msg = t.couldNotSaveSubscription;
      emit(
        state.copyWith(
          subscriptionSubmitting: false,
          subscriptionSubmissionId: state.subscriptionSubmissionId + 1,
          subscriptionSubmissionError: msg,
          message: _nextMessage(msg, error: true),
        ),
      );
    }
  }

  Future<void> _onSubscriptionEditRequested(
    ProfilesSubscriptionEditRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final subsRepo = _subscriptionsRepository;
    if (subsRepo == null) return;
    final t = AppL10n.current;
    emit(
      state.copyWith(
        subscriptionSubmitting: true,
        clearSubscriptionSubmissionError: true,
        clearMessage: true,
      ),
    );
    try {
      if (event.autoUpdateNewlyEnabled) {
        await subsRepo.requestNotificationPermission();
      }
      await subsRepo.saveSubscriptionSettings(event.subscription);
      SubscriptionSyncSummary? syncSummary;
      if (event.urlChanged) {
        syncSummary = await subsRepo.syncSubscriptionById(
          event.subscription.id,
          trigger: SubscriptionSyncTrigger.manual,
        );
      }
      final previousActiveId = state.activeProfileId;
      final previousActiveRow = state.activeProfileRow;
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      await subsRepo.syncSchedules(state.subscriptions);
      final tunnelEffect = event.urlChanged
          ? _tunnelEffectAfterSubscriptionReload(
              previousActiveId: previousActiveId,
              previousActiveRow: previousActiveRow,
            )
          : null;
      emit(
        state.copyWith(
          subscriptionSubmitting: false,
          subscriptionSubmissionId: state.subscriptionSubmissionId + 1,
          clearSubscriptionSubmissionError: true,
          lastSavedSubscriptionId: event.subscription.id,
          pendingSummaryEvent: syncSummary == null
              ? null
              : _nextSummaryEvent([syncSummary]),
          message: syncSummary == null
              ? _nextMessage(t.subscriptionSaved)
              : null,
          pendingTunnelEffect: tunnelEffect,
        ),
      );
    } on SubscriptionException catch (error) {
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final msg = error.localizedMessage(t);
      emit(
        state.copyWith(
          subscriptionSubmitting: false,
          subscriptionSubmissionId: state.subscriptionSubmissionId + 1,
          subscriptionSubmissionError: msg,
          message: _nextMessage(msg, error: true),
        ),
      );
    } catch (_) {
      final msg = t.couldNotSaveSubscription;
      emit(
        state.copyWith(
          subscriptionSubmitting: false,
          subscriptionSubmissionId: state.subscriptionSubmissionId + 1,
          subscriptionSubmissionError: msg,
          message: _nextMessage(msg, error: true),
        ),
      );
    }
  }

  Future<void> _onSubscriptionSyncRequested(
    ProfilesSubscriptionSyncRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final subsRepo = _subscriptionsRepository;
    if (subsRepo == null) return;
    if (state.updatingSubscriptionIds.contains(event.subscriptionId)) return;
    final t = AppL10n.current;
    emit(
      state.copyWith(
        updatingSubscriptionIds: <String>{
          ...state.updatingSubscriptionIds,
          event.subscriptionId,
        },
        clearMessage: true,
      ),
    );
    try {
      final previousActiveId = state.activeProfileId;
      final previousActiveRow = state.activeProfileRow;
      final summary = await subsRepo.syncSubscriptionById(
        event.subscriptionId,
        trigger: event.trigger,
      );
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
        ..remove(event.subscriptionId);
      final shouldShowDialog =
          summary != null && (!event.trigger.isAuto || summary.hasChanges);
      emit(
        state.copyWith(
          updatingSubscriptionIds: nextUpdating,
          pendingSummaryEvent: shouldShowDialog
              ? _nextSummaryEvent([summary])
              : null,
          pendingTunnelEffect: _tunnelEffectAfterSubscriptionReload(
            previousActiveId: previousActiveId,
            previousActiveRow: previousActiveRow,
          ),
        ),
      );
    } on SubscriptionException catch (error) {
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
        ..remove(event.subscriptionId);
      emit(
        state.copyWith(
          updatingSubscriptionIds: nextUpdating,
          message: event.trigger.isAuto
              ? null
              : _nextMessage(error.localizedMessage(t), error: true),
        ),
      );
    } catch (_) {
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
        ..remove(event.subscriptionId);
      emit(
        state.copyWith(
          updatingSubscriptionIds: nextUpdating,
          message: event.trigger.isAuto
              ? null
              : _nextMessage(t.subscriptionErrorUnexpected, error: true),
        ),
      );
    }
  }

  Future<void> _onScheduledSubscriptionSyncRequested(
    _ProfilesScheduledSubscriptionSyncRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final subsRepo = _subscriptionsRepository;
    if (subsRepo == null) {
      if (!event.completer.isCompleted) {
        event.completer.complete(SubscriptionContract.outcomeFailure);
      }
      return;
    }
    emit(
      state.copyWith(
        updatingSubscriptionIds: <String>{
          ...state.updatingSubscriptionIds,
          event.subscriptionId,
        },
      ),
    );
    var outcome = SubscriptionContract.outcomeSuccess;
    try {
      final previousActiveId = state.activeProfileId;
      final previousActiveRow = state.activeProfileRow;
      final summary = await subsRepo.syncSubscriptionById(
        event.subscriptionId,
        trigger: SubscriptionSyncTrigger.foregroundAuto,
      );
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
        ..remove(event.subscriptionId);
      emit(
        state.copyWith(
          updatingSubscriptionIds: nextUpdating,
          pendingSummaryEvent: summary != null && summary.hasChanges
              ? _nextSummaryEvent([summary])
              : null,
          pendingTunnelEffect: _tunnelEffectAfterSubscriptionReload(
            previousActiveId: previousActiveId,
            previousActiveRow: previousActiveRow,
          ),
        ),
      );
    } on SubscriptionException catch (error) {
      outcome = error.isRetryable
          ? SubscriptionContract.outcomeRetry
          : SubscriptionContract.outcomeFailure;
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
        ..remove(event.subscriptionId);
      emit(state.copyWith(updatingSubscriptionIds: nextUpdating));
    } catch (_) {
      outcome = SubscriptionContract.outcomeRetry;
      final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
        ..remove(event.subscriptionId);
      emit(state.copyWith(updatingSubscriptionIds: nextUpdating));
    } finally {
      if (!event.completer.isCompleted) {
        event.completer.complete(outcome);
      }
    }
  }

  Future<void> _onSubscriptionDeleteRequested(
    ProfilesSubscriptionDeleteRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final subsRepo = _subscriptionsRepository;
    if (subsRepo == null) return;
    final t = AppL10n.current;
    try {
      final result = await subsRepo.deleteSubscription(event.subscriptionId);
      _log(
        LogLevel.debug,
        'Deleted subscription id=${event.subscriptionId} removedProfiles=${result.removedProfilesCount}',
      );
      final activeWasInSub =
          state.activeProfileId != null &&
          state.profiles.any(
            (p) =>
                p.id == state.activeProfileId &&
                p.subscriptionId == event.subscriptionId,
          );
      final nextPreferred = activeWasInSub ? null : state.activeProfileId;
      await _reloadProfiles(emit, preferredActiveId: nextPreferred);
      if (activeWasInSub &&
          state.activeProfileId == null &&
          state.profiles.isNotEmpty) {
        add(ProfilesSelectionChanged(state.profiles.first.id));
      }
      await subsRepo.syncSchedules(state.subscriptions);
      emit(
        state.copyWith(
          message: _nextMessage(t.subscriptionDeleted),
          pendingTunnelEffect: activeWasInSub
              ? _nextTunnelDisconnectEffect()
              : null,
        ),
      );
    } catch (error) {
      _log(
        LogLevel.warning,
        'Delete subscription failed id=${event.subscriptionId} error=${error.runtimeType}',
      );
      emit(
        state.copyWith(
          message: _nextMessage(t.couldNotDeleteSubscription, error: true),
        ),
      );
    }
  }

  Future<void> _onDueSubscriptionsCheckRequested(
    ProfilesDueSubscriptionsCheckRequested event,
    Emitter<ProfilesState> emit,
  ) async {
    final subsRepo = _subscriptionsRepository;
    if (subsRepo == null) return;
    await subsRepo.reloadStore();
    final pendingSummaries = await subsRepo.consumePendingSummaries();
    final loadedSubscriptions = await subsRepo.loadSubscriptions();

    if (pendingSummaries.isNotEmpty ||
        loadedSubscriptions != state.subscriptions) {
      final previousActiveId = state.activeProfileId;
      final previousActiveRow = state.activeProfileRow;
      await _reloadProfiles(
        emit,
        preferredActiveId: state.activeProfileId,
        showLoading: false,
      );
      final tunnelEffect = _tunnelEffectAfterSubscriptionReload(
        previousActiveId: previousActiveId,
        previousActiveRow: previousActiveRow,
      );
      if (pendingSummaries.isNotEmpty || tunnelEffect != null) {
        emit(
          state.copyWith(
            pendingSummaryEvent: pendingSummaries.isNotEmpty
                ? _nextSummaryEvent(pendingSummaries)
                : null,
            pendingTunnelEffect: tunnelEffect,
          ),
        );
      }
    }

    final now = _clock();
    final due = loadedSubscriptions
        .where(
          (s) =>
              s.isDueAt(now) && !state.updatingSubscriptionIds.contains(s.id),
        )
        .toList();
    if (due.isEmpty) return;

    final changedSummaries = <SubscriptionSyncSummary>[];
    for (final sub in due) {
      emit(
        state.copyWith(
          updatingSubscriptionIds: <String>{
            ...state.updatingSubscriptionIds,
            sub.id,
          },
        ),
      );
      try {
        final summary = await subsRepo.syncSubscriptionById(
          sub.id,
          trigger: SubscriptionSyncTrigger.foregroundAuto,
        );
        if (summary != null && summary.hasChanges) {
          changedSummaries.add(summary);
        }
      } catch (_) {
        // Auto-update failures are recorded on the subscription and logged silently.
      } finally {
        final nextUpdating = Set<String>.of(state.updatingSubscriptionIds)
          ..remove(sub.id);
        emit(state.copyWith(updatingSubscriptionIds: nextUpdating));
      }
    }

    final previousActiveId = state.activeProfileId;
    final previousActiveRow = state.activeProfileRow;
    await _reloadProfiles(
      emit,
      preferredActiveId: state.activeProfileId,
      showLoading: false,
    );
    final tunnelEffect = _tunnelEffectAfterSubscriptionReload(
      previousActiveId: previousActiveId,
      previousActiveRow: previousActiveRow,
    );
    if (changedSummaries.isNotEmpty || tunnelEffect != null) {
      emit(
        state.copyWith(
          pendingSummaryEvent: changedSummaries.isNotEmpty
              ? _nextSummaryEvent(changedSummaries)
              : null,
          pendingTunnelEffect: tunnelEffect,
        ),
      );
    }
  }

  static bool _sameProfileOrder(List<Profile> a, List<Profile> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id ||
          a[i].favorite != b[i].favorite ||
          a[i].subscriptionId != b[i].subscriptionId) {
        return false;
      }
    }
    return true;
  }

  void _queueIncomingTransfer(IncomingProfileTransfer transfer) {
    add(
      ProfilesImportRequested(
        ImportTransferRequest(
          transfer: transfer,
          selectAsLastProfile: state.selectImportedProfileWhenIdle,
        ),
      ),
    );
  }

  Future<void> _reloadProfiles(
    Emitter<ProfilesState> emit, {
    String? preferredActiveId,
    bool showLoading = true,
  }) async {
    if (showLoading) {
      emit(state.copyWith(loading: true, clearMessage: true));
    }
    final profiles = await _profilesRepository.loadProfiles();
    final subscriptions = _subscriptionsRepository == null
        ? state.subscriptions
        : await _subscriptionsRepository.loadSubscriptions();
    final candidateId = preferredActiveId ?? state.activeProfileId;
    final targetId =
        candidateId != null &&
            profiles.any((profile) => profile.id == candidateId)
        ? candidateId
        : null;
    ProfileSecretRow? targetRow;
    if (targetId != null) {
      targetRow = await _profilesRepository.loadProfileWithSecrets(targetId);
    }
    emit(
      state.copyWith(
        loading: false,
        profiles: profiles,
        subscriptions: subscriptions,
        activeProfileId: targetRow == null ? null : targetId,
        clearActiveProfileId: targetRow == null,
        activeProfileRow: targetRow,
        clearActiveProfileRow: targetRow == null,
      ),
    );
  }

  HomeMessage _nextMessage(String text, {bool error = false}) {
    _messageId += 1;
    return HomeMessage(id: _messageId, text: text, error: error);
  }

  SubscriptionSyncSummaryEvent _nextSummaryEvent(
    List<SubscriptionSyncSummary> summaries,
  ) {
    _summaryEventId += 1;
    return SubscriptionSyncSummaryEvent(
      id: _summaryEventId,
      summaries: List<SubscriptionSyncSummary>.unmodifiable(summaries),
    );
  }

  ActiveProfileTunnelEffect? _tunnelEffectAfterSubscriptionReload({
    required String? previousActiveId,
    required ProfileSecretRow? previousActiveRow,
  }) {
    if (previousActiveId == null) return null;
    if (state.activeProfileId == null) {
      return _nextTunnelDisconnectEffect();
    }
    if (state.activeProfileId == previousActiveId &&
        previousActiveRow != null &&
        state.activeProfileRow != null &&
        previousActiveRow != state.activeProfileRow) {
      return _nextTunnelReconnectEffect(state.activeProfileRow!);
    }
    return null;
  }

  ActiveProfileTunnelEffect _nextTunnelReconnectEffect(ProfileSecretRow row) {
    _tunnelEffectId += 1;
    return ActiveProfileTunnelEffect.reconnect(id: _tunnelEffectId, row: row);
  }

  ActiveProfileTunnelEffect _nextTunnelDisconnectEffect() {
    _tunnelEffectId += 1;
    return ActiveProfileTunnelEffect.disconnect(id: _tunnelEffectId);
  }

  @override
  Future<void> close() async {
    _subscriptionsRepository?.setScheduledUpdateHandler(null);
    await _transferSub?.cancel();
    return super.close();
  }
}
