import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';
import 'package:tunnel_forge/features/profile_form/presentation/bloc/profile_form_bloc.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProfileStore store;
  late ProfileFormBloc bloc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = ProfileStore(secretsOverride: MemorySecretStore());
    bloc = ProfileFormBloc(ProfilesRepositoryImpl(store));
    addTearDown(bloc.close);
  });

  Future<ProfileFormState> dispatch(
    ProfileFormEvent event,
    bool Function(ProfileFormState) matches,
  ) {
    final result = bloc.stream.firstWhere(matches);
    bloc.add(event);
    return result;
  }

  test('opening a deleted profile reports that it no longer exists', () async {
    final state = await dispatch(
      const ProfileFormStarted('deleted-id'),
      (state) => state.loadError != null,
    );
    expect(state.profileId, 'deleted-id');
    expect(state.loading, isFalse);
    expect(state.loadError, AppL10n.current.profileNoLongerExists);
  });

  test('manual DNS validation keeps invalid settings out of storage', () async {
    await dispatch(
      const ProfileFormStarted(null),
      (state) => !state.loading && state.profileId.isNotEmpty,
    );
    await dispatch(
      const ProfileFormDnsAutomaticChanged(false),
      (state) => !state.dnsAutomatic,
    );

    Future<void> expectSaveError(String message) async {
      final previousMessage = bloc.state.messageId;
      final state = await dispatch(
        const ProfileFormSaveRequested(),
        (state) => state.messageId > previousMessage,
      );
      expect(state.message, message);
      expect(state.saved, isFalse);
      expect(await store.loadProfiles(), isEmpty);
    }

    await expectSaveError(AppL10n.current.enterDnsOrEnableAutomatic);
    await dispatch(
      const ProfileFormDns1ProtocolChanged(DnsProtocol.dnsOverTls),
      (state) => state.dns1Protocol == DnsProtocol.dnsOverTls,
    );
    const invalidServer = 'https://example.com/path';
    await dispatch(
      const ProfileFormDns1Changed(invalidServer),
      (state) => state.dns1 == invalidServer,
    );
    await expectSaveError(
      Profile.validationMessageForDnsServer(
        'DNS 1',
        invalidServer,
        DnsProtocol.dnsOverTls,
      ),
    );

    await dispatch(
      const ProfileFormDns1Changed('dns.example.com'),
      (state) => state.dns1 == 'dns.example.com',
    );
    await dispatch(
      const ProfileFormDns2ProtocolChanged(DnsProtocol.dnsOverTls),
      (state) => state.dns2Protocol == DnsProtocol.dnsOverTls,
    );
    await dispatch(
      const ProfileFormDns2Changed(invalidServer),
      (state) => state.dns2 == invalidServer,
    );
    await expectSaveError(
      Profile.validationMessageForDnsServer(
        'DNS 2',
        invalidServer,
        DnsProtocol.dnsOverTls,
      ),
    );
  });

  test('validates and persists pppAuth and mppeMode policies', () async {
    await dispatch(
      const ProfileFormStarted(null),
      (state) => !state.loading && state.profileId.isNotEmpty,
    );
    await dispatch(
      const ProfileFormProtocolChanged(TunnelProtocol.pptp),
      (state) => state.protocol == TunnelProtocol.pptp,
    );
    await dispatch(
      const ProfileFormPppAuthChanged(PppAuthMethod.chapMd5),
      (state) => state.pppAuth == PppAuthMethod.chapMd5,
    );
    await dispatch(
      const ProfileFormMppeModeChanged(MppeMode.on),
      (state) => state.mppeMode == MppeMode.on,
    );
    expect(bloc.state.mppeErrorText, AppL10n.current.mppeRequiresMschapV2);

    final prevMsg = bloc.state.messageId;
    final blocked = await dispatch(
      const ProfileFormSaveRequested(),
      (state) => state.messageId > prevMsg,
    );
    expect(blocked.saved, isFalse);
    expect(blocked.message, AppL10n.current.mppeRequiresMschapV2);

    await dispatch(
      const ProfileFormPppAuthChanged(PppAuthMethod.mschapV2),
      (state) => state.pppAuth == PppAuthMethod.mschapV2,
    );
    expect(bloc.state.mppeErrorText, isNull);

    final savedState = await dispatch(
      const ProfileFormSaveRequested(),
      (state) => state.saved,
    );
    expect(savedState.saved, isTrue);
    final stored = (await store.loadProfiles()).single;
    expect(stored.protocol, TunnelProtocol.pptp);
    expect(stored.pppAuth, PppAuthMethod.mschapV2);
    expect(stored.mppeMode, MppeMode.on);
  });
}
