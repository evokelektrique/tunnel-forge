import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/core/logging/log_entry.dart';
import 'package:tunnel_forge/features/home/data/home_repositories_impl.dart';
import 'package:tunnel_forge/features/home/domain/home_models.dart';
import 'package:tunnel_forge/features/home/domain/home_repositories.dart';
import 'package:tunnel_forge/features/home/presentation/bloc/profiles_bloc.dart';
import 'package:tunnel_forge/features/profile_form/presentation/bloc/profile_form_bloc.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';

import 'support/fake_diagnostics_bridge.dart';

class _FakeProfileTransferRepository implements ProfileTransferRepository {
  final StreamController<IncomingProfileTransfer> _controller =
      StreamController<IncomingProfileTransfer>.broadcast();

  @override
  Stream<IncomingProfileTransfer> get incomingTransfers => _controller.stream;

  @override
  Future<List<IncomingProfileTransfer>> start() async => const [];

  @override
  Future<void> dispose() => _controller.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late ProfileStore store;
  late ProfilesRepositoryImpl profilesRepository;
  late LogsRepositoryImpl logsRepository;
  late _FakeProfileTransferRepository transferRepository;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = ProfileStore(
      prefsOverride: prefs,
      secretsOverride: MemorySecretStore(),
    );
    profilesRepository = ProfilesRepositoryImpl(store);
    logsRepository = LogsRepositoryImpl(
      prefsOverride: prefs,
      bridgeOverride: FakeDiagnosticsBridge(),
    );
    transferRepository = _FakeProfileTransferRepository();
  });

  tearDown(() async {
    await logsRepository.dispose();
    await transferRepository.dispose();
  });

  test(
    'ProfileFormBloc logs redacted create, update, and validation blocks',
    () async {
      final createBloc = ProfileFormBloc(
        profilesRepository,
        logsRepository: logsRepository,
      );
      addTearDown(createBloc.close);

      createBloc.add(const ProfileFormStarted(null));
      await Future<void>.delayed(Duration.zero);

      createBloc.add(const ProfileFormServerChanged(''));
      createBloc.add(const ProfileFormSaveRequested());
      await Future<void>.delayed(Duration.zero);
      expect(
        logsRepository.entries.map((e) => e.message),
        contains('Profile save blocked: empty server'),
      );

      createBloc.add(const ProfileFormDisplayNameChanged('Secret "Home" VPN'));
      createBloc.add(const ProfileFormServerChanged('vpn.secret-home.example'));
      createBloc.add(const ProfileFormUserChanged('alice'));
      createBloc.add(const ProfileFormPasswordChanged('hunter2'));
      createBloc.add(const ProfileFormPskChanged('psk-secret'));
      createBloc.add(const ProfileFormSaveRequested());
      await Future<void>.delayed(Duration.zero);

      final createdLog = logsRepository.entries.last;
      expect(createdLog.level, LogLevel.debug);
      expect(createdLog.tag, 'profile_form');
      expect(createdLog.message, startsWith('Profile created profile='));
      expect(createdLog.message, contains('name="[REDACTED]"'));
      expect(createdLog.message, contains('server=[REDACTED_HOST]'));
      expect(createdLog.message, isNot(contains('Secret')));
      expect(createdLog.message, isNot(contains('Home')));
      expect(createdLog.message, isNot(contains('vpn.secret-home.example')));
      expect(createdLog.message, isNot(contains('hunter2')));
      expect(createdLog.message, isNot(contains('psk-secret')));

      final createdId = createBloc.state.profileId;
      final editBloc = ProfileFormBloc(
        profilesRepository,
        logsRepository: logsRepository,
      );
      addTearDown(editBloc.close);

      editBloc.add(ProfileFormStarted(createdId));
      await Future<void>.delayed(Duration.zero);
      editBloc.add(const ProfileFormDisplayNameChanged('Updated Office'));
      editBloc.add(const ProfileFormSaveRequested());
      await Future<void>.delayed(Duration.zero);

      final updatedLog = logsRepository.entries.last;
      expect(updatedLog.level, LogLevel.debug);
      expect(
        updatedLog.message,
        startsWith('Profile updated profile=$createdId'),
      );
      expect(updatedLog.message, contains('name="[REDACTED]"'));
      expect(updatedLog.message, isNot(contains('Updated Office')));
    },
  );

  test(
    'ProfilesBloc logs redacted select, favorite, 5-favorite limit, reorder, import, share link, and delete',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') return null;
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      for (var i = 1; i <= 6; i++) {
        await store.upsertProfile(
          Profile(
            id: 'p$i',
            displayName: 'Private Label $i',
            server: 'server$i.secret.example',
            user: 'user$i',
          ),
          password: 'pw$i',
          psk: 'psk$i',
        );
      }

      final bloc = ProfilesBloc(
        profilesRepository,
        transferRepository,
        logsRepository: logsRepository,
      );
      addTearDown(bloc.close);

      bloc.add(const ProfilesStarted());
      await Future<void>.delayed(Duration.zero);

      bloc.add(const ProfilesSelectionChanged('p2'));
      await Future<void>.delayed(Duration.zero);
      final selectLog = logsRepository.entries.last;
      expect(selectLog.level, LogLevel.debug);
      expect(selectLog.tag, 'profiles');
      expect(selectLog.message, contains('Profile selected profile=p2'));
      expect(selectLog.message, contains('name="[REDACTED]"'));
      expect(selectLog.message, contains('server=[REDACTED_HOST]'));
      expect(selectLog.message, isNot(contains('Private Label 2')));
      expect(selectLog.message, isNot(contains('server2.secret.example')));

      bloc.add(const ProfilesSelectionChanged(null));
      await Future<void>.delayed(Duration.zero);
      expect(logsRepository.entries.last.message, 'Profile selection cleared');

      bloc.add(const ProfilesSelectionChanged('missing-id'));
      await Future<void>.delayed(Duration.zero);
      expect(logsRepository.entries.last.level, LogLevel.warning);
      expect(
        logsRepository.entries.last.message,
        'Profile selection failed: missing profile=missing-id',
      );

      for (var i = 1; i <= 5; i++) {
        bloc.add(ProfilesFavoriteToggled('p$i'));
        await Future<void>.delayed(Duration.zero);
        expect(
          logsRepository.entries.last.message,
          'Profile favorited profile=p$i favoritesCount=$i',
        );
      }

      bloc.add(const ProfilesFavoriteToggled('p6'));
      await Future<void>.delayed(Duration.zero);
      final limitLog = logsRepository.entries.last;
      expect(limitLog.level, LogLevel.debug);
      expect(
        limitLog.message,
        'Favorite limit reached max=${Profile.maxFavorites} profile=p6',
      );

      bloc.add(const ProfilesFavoriteToggled('p1'));
      await Future<void>.delayed(Duration.zero);
      expect(
        logsRepository.entries.last.message,
        'Profile unfavorited profile=p1 favoritesCount=4',
      );

      bloc.add(
        const ProfilesGroupReordered(
          favoritesSection: true,
          oldIndex: 0,
          newIndex: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        logsRepository.entries.last.message,
        'Profiles reordered section=favorites oldIndex=0 newIndex=1',
      );

      const envelope = ProfileTransferEnvelope(
        displayName: 'Imported Secret',
        server: 'import.secret.example',
        user: 'bob',
        password: 'pw',
        psk: 'psk',
        dnsAutomatic: true,
        dns1Host: '',
        dns1Protocol: DnsProtocol.dnsOverUdp,
        dns2Host: '',
        dns2Protocol: DnsProtocol.dnsOverUdp,
        mtu: 1400,
      );
      bloc.add(
        ProfilesImportRequested(
          ImportTransferRequest(
            transfer: IncomingProfileTransfer(
              type: ProfileTransferContract.typeTfpJson,
              data: envelope.toFileJson(),
              source: 'secret-import.tfp',
            ),
            selectAsLastProfile: false,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final importLog = logsRepository.entries.last;
      expect(importLog.level, LogLevel.debug);
      expect(importLog.message, contains('Imported profiles count=1'));
      expect(importLog.message, contains('origin=file file="[REDACTED]"'));
      expect(importLog.message, isNot(contains('secret-import.tfp')));
      expect(importLog.message, isNot(contains('Imported Secret')));
      expect(importLog.message, isNot(contains('import.secret.example')));

      bloc.add(const ProfilesCopyShareLinkRequested('p2'));
      await Future<void>.delayed(Duration.zero);
      expect(logsRepository.entries.last.message, 'Copied share links count=1');
      expect(logsRepository.entries.last.message, isNot(contains('tf://')));

      bloc.add(const ProfilesDeleteRequested('p6'));
      await Future<void>.delayed(Duration.zero);
      expect(
        logsRepository.entries.last.message,
        'Deleted profiles count=1 ids=p6',
      );
    },
  );
}
