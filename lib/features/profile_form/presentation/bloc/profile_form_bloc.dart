import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';

import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import '../../../home/domain/home_repositories.dart';
import '../../../home/domain/log_redaction.dart';

sealed class ProfileFormEvent extends Equatable {
  const ProfileFormEvent();

  @override
  List<Object?> get props => const [];
}

final class ProfileFormStarted extends ProfileFormEvent {
  const ProfileFormStarted(this.profileId);

  final String? profileId;

  @override
  List<Object?> get props => [profileId];
}

final class ProfileFormDisplayNameChanged extends ProfileFormEvent {
  const ProfileFormDisplayNameChanged(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormProtocolChanged extends ProfileFormEvent {
  const ProfileFormProtocolChanged(this.value);

  final TunnelProtocol value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormServerChanged extends ProfileFormEvent {
  const ProfileFormServerChanged(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormUserChanged extends ProfileFormEvent {
  const ProfileFormUserChanged(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormPasswordChanged extends ProfileFormEvent {
  const ProfileFormPasswordChanged(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormPskChanged extends ProfileFormEvent {
  const ProfileFormPskChanged(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormDnsAutomaticChanged extends ProfileFormEvent {
  const ProfileFormDnsAutomaticChanged(this.value);

  final bool value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormDns1Changed extends ProfileFormEvent {
  const ProfileFormDns1Changed(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormDns1ProtocolChanged extends ProfileFormEvent {
  const ProfileFormDns1ProtocolChanged(this.value);

  final DnsProtocol value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormDns2Changed extends ProfileFormEvent {
  const ProfileFormDns2Changed(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormDns2ProtocolChanged extends ProfileFormEvent {
  const ProfileFormDns2ProtocolChanged(this.value);

  final DnsProtocol value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormMtuChanged extends ProfileFormEvent {
  const ProfileFormMtuChanged(this.value);

  final String value;

  @override
  List<Object?> get props => [value];
}

final class ProfileFormSaveRequested extends ProfileFormEvent {
  const ProfileFormSaveRequested();
}

final class ProfileFormSecureStorageResetRequested extends ProfileFormEvent {
  const ProfileFormSecureStorageResetRequested();
}

class ProfileFormState extends Equatable {
  const ProfileFormState({
    this.profileId = '',
    this.loading = true,
    this.saving = false,
    this.loadError,
    this.displayName = '',
    this.protocol = TunnelProtocol.l2tp,
    this.server = '',
    this.user = '',
    this.password = '',
    this.psk = '',
    this.dnsAutomatic = true,
    this.dns1 = '',
    this.dns1Protocol = DnsProtocol.dnsOverUdp,
    this.dns2 = '',
    this.dns2Protocol = DnsProtocol.dnsOverUdp,
    this.mtu = '${Profile.defaultVpnMtu}',
    this.favorite = false,
    this.subscriptionId,
    this.messageId = 0,
    this.message,
    this.saved = false,
    this.secureStorageWriteFailed = false,
  });

  final String profileId;
  final bool loading;
  final bool saving;
  final String? loadError;
  final String displayName;
  final TunnelProtocol protocol;
  final String server;
  final String user;
  final String password;
  final String psk;
  final bool dnsAutomatic;
  final String dns1;
  final DnsProtocol dns1Protocol;
  final String dns2;
  final DnsProtocol dns2Protocol;
  final String mtu;
  final bool favorite;
  final String? subscriptionId;
  final int messageId;
  final String? message;
  final bool saved;
  final bool secureStorageWriteFailed;

  String? get dns1ErrorText =>
      dnsAutomatic ? null : _dnsErrorText('DNS 1', dns1, dns1Protocol);
  String? get dns2ErrorText =>
      dnsAutomatic ? null : _dnsErrorText('DNS 2', dns2, dns2Protocol);
  String? get mtuErrorText => _mtuValidationMessage(mtu);

  ProfileFormState copyWith({
    String? profileId,
    bool? loading,
    bool? saving,
    String? loadError,
    bool clearLoadError = false,
    String? displayName,
    TunnelProtocol? protocol,
    String? server,
    String? user,
    String? password,
    String? psk,
    bool? dnsAutomatic,
    String? dns1,
    DnsProtocol? dns1Protocol,
    String? dns2,
    DnsProtocol? dns2Protocol,
    String? mtu,
    bool? favorite,
    String? subscriptionId,
    bool clearSubscriptionId = false,
    int? messageId,
    String? message,
    bool clearMessage = false,
    bool? saved,
    bool? secureStorageWriteFailed,
  }) {
    return ProfileFormState(
      profileId: profileId ?? this.profileId,
      loading: loading ?? this.loading,
      saving: saving ?? this.saving,
      loadError: clearLoadError ? null : (loadError ?? this.loadError),
      displayName: displayName ?? this.displayName,
      protocol: protocol ?? this.protocol,
      server: server ?? this.server,
      user: user ?? this.user,
      password: password ?? this.password,
      psk: psk ?? this.psk,
      dnsAutomatic: dnsAutomatic ?? this.dnsAutomatic,
      dns1: dns1 ?? this.dns1,
      dns1Protocol: dns1Protocol ?? this.dns1Protocol,
      dns2: dns2 ?? this.dns2,
      dns2Protocol: dns2Protocol ?? this.dns2Protocol,
      mtu: mtu ?? this.mtu,
      favorite: favorite ?? this.favorite,
      subscriptionId: clearSubscriptionId
          ? null
          : (subscriptionId ?? this.subscriptionId),
      messageId: messageId ?? this.messageId,
      message: clearMessage ? null : (message ?? this.message),
      saved: saved ?? this.saved,
      secureStorageWriteFailed:
          secureStorageWriteFailed ?? this.secureStorageWriteFailed,
    );
  }

  @override
  List<Object?> get props => [
    profileId,
    loading,
    saving,
    loadError,
    displayName,
    protocol,
    server,
    user,
    password,
    psk,
    dnsAutomatic,
    dns1,
    dns1Protocol,
    dns2,
    dns2Protocol,
    mtu,
    favorite,
    subscriptionId,
    messageId,
    message,
    saved,
    secureStorageWriteFailed,
  ];
}

String? _mtuValidationMessage(String value) {
  final t = AppL10n.current;
  final normalized = value.trim();
  if (normalized.isEmpty) {
    return t.mtuRequired;
  }
  final mtuParsed = int.tryParse(normalized);
  if (mtuParsed == null) {
    return t.mtuWholeNumber;
  }
  if (mtuParsed < Profile.minVpnMtu || mtuParsed > Profile.maxVpnMtu) {
    return t.mtuOutOfRange(Profile.minVpnMtu, Profile.maxVpnMtu);
  }
  return null;
}

class ProfileFormBloc extends Bloc<ProfileFormEvent, ProfileFormState> {
  ProfileFormBloc(this._profilesRepository, {LogsRepository? logsRepository})
    : _logsRepository = logsRepository,
      super(const ProfileFormState()) {
    on<ProfileFormStarted>(_onStarted);
    on<ProfileFormDisplayNameChanged>(
      (event, emit) =>
          emit(state.copyWith(displayName: event.value, saved: false)),
    );
    on<ProfileFormProtocolChanged>(
      (event, emit) =>
          emit(state.copyWith(protocol: event.value, saved: false)),
    );
    on<ProfileFormServerChanged>(
      (event, emit) => emit(state.copyWith(server: event.value, saved: false)),
    );
    on<ProfileFormUserChanged>(
      (event, emit) => emit(state.copyWith(user: event.value, saved: false)),
    );
    on<ProfileFormPasswordChanged>(
      (event, emit) =>
          emit(state.copyWith(password: event.value, saved: false)),
    );
    on<ProfileFormPskChanged>(
      (event, emit) => emit(state.copyWith(psk: event.value, saved: false)),
    );
    on<ProfileFormDnsAutomaticChanged>(
      (event, emit) =>
          emit(state.copyWith(dnsAutomatic: event.value, saved: false)),
    );
    on<ProfileFormDns1Changed>(
      (event, emit) => emit(state.copyWith(dns1: event.value, saved: false)),
    );
    on<ProfileFormDns1ProtocolChanged>(
      (event, emit) =>
          emit(state.copyWith(dns1Protocol: event.value, saved: false)),
    );
    on<ProfileFormDns2Changed>(
      (event, emit) => emit(state.copyWith(dns2: event.value, saved: false)),
    );
    on<ProfileFormDns2ProtocolChanged>(
      (event, emit) =>
          emit(state.copyWith(dns2Protocol: event.value, saved: false)),
    );
    on<ProfileFormMtuChanged>(
      (event, emit) =>
          emit(state.copyWith(mtu: event.value.trim(), saved: false)),
    );
    on<ProfileFormSaveRequested>(_onSaveRequested);
    on<ProfileFormSecureStorageResetRequested>(_onSecureStorageResetRequested);
  }

  final ProfilesRepository _profilesRepository;
  final LogsRepository? _logsRepository;
  bool _isNewProfile = false;

  void _log(LogLevel level, String message) {
    _logsRepository?.logDart(level, 'profile_form', message);
  }

  void _logSaved(Profile profile, {bool afterReset = false}) {
    final action = _isNewProfile ? 'created' : 'updated';
    final suffix = afterReset ? ' after reset' : '';
    _log(
      LogLevel.debug,
      'Profile $action$suffix profile=${profile.id} '
      'protocol=${profile.protocol.jsonValue} '
      'name=${quoteLogValue(profile.displayName)} server=${profile.server} '
      'dnsAuto=${profile.dnsAutomatic} mtu=${profile.mtu}',
    );
    _isNewProfile = false;
  }

  Future<void> _onStarted(
    ProfileFormStarted event,
    Emitter<ProfileFormState> emit,
  ) async {
    final profileId = event.profileId;
    _isNewProfile = profileId == null;
    if (profileId == null) {
      final existing = await _profilesRepository.loadProfiles();
      final defaultName = ProfileStore.nextDefaultProfileName(
        existing.map((p) => p.displayName),
      );
      emit(
        state.copyWith(
          profileId: _profilesRepository.newProfileId(),
          loading: false,
          clearLoadError: true,
          displayName: defaultName,
          protocol: TunnelProtocol.l2tp,
          server: 'vpn.example.com',
          user: '',
          password: '',
          psk: '',
          dnsAutomatic: true,
          dns1: '',
          dns1Protocol: DnsProtocol.dnsOverUdp,
          dns2: '',
          dns2Protocol: DnsProtocol.dnsOverUdp,
          mtu: '${Profile.defaultVpnMtu}',
          favorite: false,
          clearSubscriptionId: true,
          saved: false,
        ),
      );
      return;
    }
    final row = await _profilesRepository.loadProfileWithSecrets(profileId);
    if (row == null) {
      emit(
        state.copyWith(
          profileId: profileId,
          loading: false,
          loadError: AppL10n.current.profileNoLongerExists,
        ),
      );
      return;
    }
    final profile = row.profile;
    emit(
      state.copyWith(
        profileId: profile.id,
        loading: false,
        clearLoadError: true,
        displayName: profile.displayName,
        protocol: profile.protocol,
        server: profile.server,
        user: profile.user,
        password: row.password,
        psk: row.psk,
        dnsAutomatic: profile.dnsAutomatic,
        dns1: profile.dns1Host,
        dns1Protocol: profile.dns1Protocol,
        dns2: profile.dns2Host,
        dns2Protocol: profile.dns2Protocol,
        mtu: '${profile.mtu}',
        favorite: profile.favorite,
        subscriptionId: profile.subscriptionId,
        clearSubscriptionId: profile.subscriptionId == null,
      ),
    );
  }

  Profile? _validateAndBuildProfile(
    Emitter<ProfileFormState> emit, {
    String? fallbackDisplayName,
  }) {
    final serverTrim = state.server.trim();
    if (serverTrim.isEmpty) {
      _log(LogLevel.debug, 'Profile save blocked: empty server');
      emit(_messageState(AppL10n.current.enterServerAddress));
      return null;
    }
    final mtuErrorText = state.mtuErrorText;
    if (mtuErrorText != null) {
      _log(LogLevel.debug, 'Profile save blocked: invalid mtu');
      emit(_messageState(mtuErrorText));
      return null;
    }
    final mtuParsed = int.parse(state.mtu.trim());
    if (!state.dnsAutomatic) {
      final invalidDns1 = Profile.invalidDnsServer(
        state.dns1,
        state.dns1Protocol,
      );
      if (invalidDns1 != null) {
        _log(LogLevel.debug, 'Profile save blocked: invalid dns1');
        emit(
          _messageState(
            Profile.validationMessageForDnsServer(
              'DNS 1',
              state.dns1,
              state.dns1Protocol,
            ),
          ),
        );
        return null;
      }
      final invalidDns2 = Profile.invalidDnsServer(
        state.dns2,
        state.dns2Protocol,
      );
      if (invalidDns2 != null) {
        _log(LogLevel.debug, 'Profile save blocked: invalid dns2');
        emit(
          _messageState(
            Profile.validationMessageForDnsServer(
              'DNS 2',
              state.dns2,
              state.dns2Protocol,
            ),
          ),
        );
        return null;
      }
      if (Profile.orderedDnsServers(
        dns1Host: state.dns1,
        dns1Protocol: state.dns1Protocol,
        dns2Host: state.dns2,
        dns2Protocol: state.dns2Protocol,
      ).isEmpty) {
        _log(LogLevel.debug, 'Profile save blocked: empty custom dns');
        emit(_messageState(AppL10n.current.enterDnsOrEnableAutomatic));
        return null;
      }
    }

    final trimmedDisplayName = state.displayName.trim();
    final trimmedFallback = fallbackDisplayName?.trim() ?? '';
    final resolvedDisplayName = trimmedDisplayName.isNotEmpty
        ? trimmedDisplayName
        : (trimmedFallback.isNotEmpty ? trimmedFallback : serverTrim);

    return Profile(
      id: state.profileId,
      displayName: resolvedDisplayName,
      server: serverTrim,
      user: state.user,
      protocol: state.protocol,
      dnsAutomatic: state.dnsAutomatic,
      dns1Host: Profile.normalizeDnsServerForProtocol(
        state.dns1,
        state.dns1Protocol,
      ),
      dns1Protocol: state.dns1Protocol,
      dns2Host: Profile.normalizeDnsServerForProtocol(
        state.dns2,
        state.dns2Protocol,
      ),
      dns2Protocol: state.dns2Protocol,
      mtu: Profile.normalizeMtu(mtuParsed),
      favorite: state.favorite,
      subscriptionId: state.subscriptionId,
    );
  }

  Future<String?> _resolveFallbackDisplayName() async {
    if (state.displayName.trim().isNotEmpty) return null;
    final existing = await _profilesRepository.loadProfiles();
    return ProfileStore.nextDefaultProfileName(
      existing.where((p) => p.id != state.profileId).map((p) => p.displayName),
    );
  }

  Future<void> _onSaveRequested(
    ProfileFormSaveRequested event,
    Emitter<ProfileFormState> emit,
  ) async {
    final fallbackDisplayName = await _resolveFallbackDisplayName();
    final profile = _validateAndBuildProfile(
      emit,
      fallbackDisplayName: fallbackDisplayName,
    );
    if (profile == null) return;

    emit(
      state.copyWith(
        saving: true,
        clearMessage: true,
        saved: false,
        secureStorageWriteFailed: false,
      ),
    );
    try {
      await _profilesRepository.upsertProfile(
        profile,
        password: state.password,
        psk: state.protocol.isPptp ? '' : state.psk,
      );
      _logSaved(profile);
      emit(state.copyWith(saving: false, saved: true));
    } catch (error) {
      _log(
        LogLevel.warning,
        'Profile save failed profile=${profile.id} error=${error.runtimeType}',
      );
      emit(
        _messageState(
          AppL10n.current.couldNotSaveChanges,
          saving: false,
          secureStorageWriteFailed: true,
        ),
      );
    }
  }

  Future<void> _onSecureStorageResetRequested(
    ProfileFormSecureStorageResetRequested event,
    Emitter<ProfileFormState> emit,
  ) async {
    final fallbackDisplayName = await _resolveFallbackDisplayName();
    final profile = _validateAndBuildProfile(
      emit,
      fallbackDisplayName: fallbackDisplayName,
    );
    if (profile == null) return;

    emit(
      state.copyWith(
        saving: true,
        clearMessage: true,
        saved: false,
        secureStorageWriteFailed: false,
      ),
    );
    _log(
      LogLevel.debug,
      'Retrying profile save after secure storage reset profile=${profile.id}',
    );
    try {
      await _profilesRepository.resetSecureStorage();
      await _profilesRepository.upsertProfile(
        profile,
        password: state.password,
        psk: state.protocol.isPptp ? '' : state.psk,
      );
      _logSaved(profile, afterReset: true);
      emit(state.copyWith(saving: false, saved: true));
    } catch (error) {
      _log(
        LogLevel.warning,
        'Profile save after secure storage reset failed profile=${profile.id} error=${error.runtimeType}',
      );
      emit(
        _messageState(
          AppL10n.current.couldNotSaveChanges,
          saving: false,
          secureStorageWriteFailed: false,
        ),
      );
    }
  }

  ProfileFormState _messageState(
    String message, {
    bool? saving,
    bool? secureStorageWriteFailed,
  }) {
    return state.copyWith(
      saving: saving ?? false,
      messageId: state.messageId + 1,
      message: message,
      saved: false,
      secureStorageWriteFailed: secureStorageWriteFailed,
    );
  }
}

String? _dnsErrorText(String label, String value, DnsProtocol protocol) {
  final invalid = Profile.invalidDnsServer(value, protocol);
  if (invalid == null) return null;
  return Profile.validationMessageForDnsServer(label, value, protocol);
}
