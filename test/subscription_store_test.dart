import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

class _CountingSecretStore extends MemorySecretStore {
  int writes = 0;
  int deletes = 0;

  @override
  Future<void> write(String key, String value) async {
    writes += 1;
    await super.write(key, value);
  }

  @override
  Future<void> delete(String key) async {
    deletes += 1;
    await super.delete(key);
  }
}

ProfileTransferEnvelope _env({
  required String name,
  required String server,
  String user = 'vpn',
  String password = 'pw',
  String psk = 'psk',
  TunnelProtocol protocol = TunnelProtocol.l2tp,
}) {
  return ProfileTransferEnvelope(
    protocol: protocol,
    displayName: name,
    server: server,
    user: user,
    password: password,
    psk: psk,
    dnsAutomatic: true,
    dns1Host: '',
    dns1Protocol: DnsProtocol.dnsOverUdp,
    dns2Host: '',
    dns2Protocol: DnsProtocol.dnsOverUdp,
    mtu: Profile.defaultVpnMtu,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({ProfileStore store, _CountingSecretStore secrets})>
  makeStore() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = _CountingSecretStore();
    return (
      store: ProfileStore(prefsOverride: prefs, secretsOverride: secrets),
      secrets: secrets,
    );
  }

  group('ProfileStore subscription sync', () {
    test(
      'diffs imported, updated, unchanged, and removed while preserving IDs, favorites, and Local profiles',
      () async {
        final env = await makeStore();
        final store = env.store;
        final secrets = env.secrets;

        // Seed one local profile that must remain untouched.
        await store.upsertProfile(
          const Profile(
            id: 'local-1',
            displayName: 'Home',
            server: 'home.example.com',
            user: 'me',
          ),
          password: 'hpw',
          psk: 'hpsk',
        );

        const sub = Subscription(
          id: 'sub-a',
          name: 'Provider A',
          url: 'https://example.com/sub',
        );

        final t1 = DateTime.utc(2026, 11, 20, 10, 0);
        final initial = await store.applySubscriptionSync(
          subscription: sub,
          envelopes: [
            _env(
              name: 'DE 1 · 100ms',
              server: 'de1.example.com',
              user: 'u1',
              password: 'p1',
              psk: 'k1',
            ),
            _env(
              name: 'US 1',
              server: 'us1.example.com',
              user: 'u2',
              password: 'p2',
              psk: 'k2',
            ),
            _env(
              name: 'JP 1',
              server: 'jp1.example.com',
              user: 'u3',
              password: 'p3',
              psk: 'k3',
            ),
          ],
          trigger: SubscriptionSyncTrigger.initialAdd,
          syncedAt: t1,
        );
        expect(initial.importedCount, 3);
        expect(initial.updatedCount, 0);
        expect(initial.removedCount, 0);

        final profilesAfterAdd = await store.loadProfiles();
        final deProfile = profilesAfterAdd.firstWhere(
          (p) => p.server == 'de1.example.com',
        );
        final jpProfile = profilesAfterAdd.firstWhere(
          (p) => p.server == 'jp1.example.com',
        );

        // Star DE 1 and select JP 1 as last profile.
        await store.toggleProfileFavorite(deProfile.id);
        await store.setLastProfileId(jpProfile.id);

        final writesBeforeNoChange = secrets.writes;
        final t2 = DateTime.utc(2026, 11, 20, 11, 0);
        final noChange = await store.applySubscriptionSync(
          subscription: sub,
          envelopes: [
            _env(
              name: 'DE 1 · 100ms',
              server: 'DE1.EXAMPLE.COM',
              user: 'u1',
              password: 'p1',
              psk: 'k1',
            ),
            _env(
              name: 'US 1',
              server: 'us1.example.com',
              user: 'u2',
              password: 'p2',
              psk: 'k2',
            ),
            _env(
              name: 'JP 1',
              server: 'jp1.example.com',
              user: 'u3',
              password: 'p3',
              psk: 'k3',
            ),
          ],
          trigger: SubscriptionSyncTrigger.manual,
          syncedAt: t2,
        );
        expect(noChange.hasChanges, isFalse);
        // Unchanged sync must skip redundant keystore writes.
        expect(secrets.writes, writesBeforeNoChange);

        // Update DE 1 (renamed + new password), keep US 1, remove JP 1, import FR 1.
        final t3 = DateTime.utc(2026, 11, 20, 12, 0);
        final diff = await store.applySubscriptionSync(
          subscription: sub,
          envelopes: [
            _env(
              name: 'DE 1 · 75ms',
              server: 'de1.example.com',
              user: 'u1',
              password: 'p1-new',
              psk: 'k1',
            ),
            _env(
              name: 'US 1',
              server: 'us1.example.com',
              user: 'u2',
              password: 'p2',
              psk: 'k2',
            ),
            _env(
              name: 'FR 1',
              server: 'fr1.example.com',
              user: 'u4',
              password: 'p4',
              psk: 'k4',
            ),
          ],
          trigger: SubscriptionSyncTrigger.manual,
          syncedAt: t3,
        );
        expect(diff.importedCount, 1);
        expect(diff.updatedCount, 1);
        expect(diff.removedCount, 1);

        final finalProfiles = await store.loadProfiles();
        expect(finalProfiles.any((p) => p.id == 'local-1'), isTrue);
        final updatedDe = finalProfiles.firstWhere((p) => p.id == deProfile.id);
        expect(updatedDe.displayName, 'DE 1 · 75ms');
        expect(updatedDe.favorite, isTrue);
        final deSecrets = await store.loadProfileWithSecrets(deProfile.id);
        expect(deSecrets?.password, 'p1-new');

        // JP 1 was removed, so its secrets and lastProfileId must be cleaned up.
        expect(finalProfiles.any((p) => p.id == jpProfile.id), isFalse);
        expect(await store.loadLastProfileId(), isNull);
        expect(
          await secrets.read(ProfileStore.passwordKey(jpProfile.id)),
          isNull,
        );

        final subs = await store.loadSubscriptions();
        expect(subs.single.lastUpdatedAtMs, t3.millisecondsSinceEpoch);
        expect(subs.single.lastError, isNull);
      },
    );

    test(
      'enforces max 5 favorites per tab independently and scopes reordering',
      () async {
        final env = await makeStore();
        final store = env.store;

        for (var i = 1; i <= 6; i++) {
          await store.upsertProfile(
            Profile(
              id: 'l$i',
              displayName: 'Local $i',
              server: 'l$i.example.com',
              user: 'u',
            ),
            password: 'p',
            psk: 'k',
          );
        }
        await store.applySubscriptionSync(
          subscription: const Subscription(
            id: 'sub-1',
            name: 'Sub 1',
            url: 'https://example.com/1',
          ),
          envelopes: [
            for (var i = 1; i <= 6; i++)
              _env(name: 'Sub $i', server: 's$i.example.com'),
          ],
          trigger: SubscriptionSyncTrigger.initialAdd,
          syncedAt: DateTime.utc(2026, 11, 20),
        );

        for (var i = 1; i <= 5; i++) {
          final r = await store.toggleProfileFavorite('l$i');
          expect(r.limitReached, isFalse);
        }
        expect((await store.toggleProfileFavorite('l6')).limitReached, isTrue);

        // Sub 1 still has its own independent 5-favorite budget.
        final subProfiles = (await store.loadProfiles())
            .where((p) => p.subscriptionId == 'sub-1')
            .toList();
        for (var i = 0; i < 5; i++) {
          final r = await store.toggleProfileFavorite(subProfiles[i].id);
          expect(r.limitReached, isFalse);
        }
        expect(
          (await store.toggleProfileFavorite(subProfiles[5].id)).limitReached,
          isTrue,
        );

        // Reorder inside Local favorites does not perturb Sub 1 order.
        final beforeSubOrder = (await store.loadProfiles())
            .where((p) => p.subscriptionId == 'sub-1')
            .map((p) => p.id)
            .toList();
        final reordered = await store.reorderProfiles(
          favoritesSection: true,
          oldIndex: 0,
          newIndex: 2,
          subscriptionId: null,
          filterBySubscription: true,
        );
        final localFavs = reordered
            .where((p) => p.subscriptionId == null && p.favorite)
            .map((p) => p.id)
            .toList();
        expect(localFavs.sublist(0, 3), ['l2', 'l3', 'l1']);
        final afterSubOrder = reordered
            .where((p) => p.subscriptionId == 'sub-1')
            .map((p) => p.id)
            .toList();
        expect(afterSubOrder, beforeSubOrder);
      },
    );

    test(
      'deleteSubscription removes profiles, secrets, and pending summaries',
      () async {
        final env = await makeStore();
        final store = env.store;
        final secrets = env.secrets;

        await store.upsertProfile(
          const Profile(
            id: 'local-keep',
            displayName: 'Keep',
            server: 'keep.example.com',
            user: 'u',
          ),
          password: 'pw',
          psk: 'psk',
        );
        await store.applySubscriptionSync(
          subscription: const Subscription(
            id: 'sub-del',
            name: 'ToDelete',
            url: 'https://example.com/del',
          ),
          envelopes: [
            _env(name: 'One', server: 'one.example.com'),
            _env(name: 'Two', server: 'two.example.com'),
          ],
          trigger: SubscriptionSyncTrigger.initialAdd,
          syncedAt: DateTime.utc(2026, 11, 20),
        );
        await store.enqueuePendingSubscriptionSummary(
          const SubscriptionSyncSummary(
            subscriptionId: 'sub-del',
            subscriptionName: 'ToDelete',
            importedCount: 2,
            updatedCount: 0,
            removedCount: 0,
            syncedAtMs: 1000,
            trigger: SubscriptionSyncTrigger.backgroundAuto,
          ),
        );
        final subProfiles = (await store.loadProfiles())
            .where((p) => p.subscriptionId == 'sub-del')
            .toList();
        await store.setLastProfileId(subProfiles.first.id);

        final result = await store.deleteSubscription('sub-del');
        expect(result.removedProfilesCount, 2);
        expect(await store.loadSubscriptions(), isEmpty);
        expect((await store.loadProfiles()).map((p) => p.id).toList(), [
          'local-keep',
        ]);
        expect(await store.loadLastProfileId(), isNull);
        expect(await store.consumePendingSubscriptionSummaries(), isEmpty);
        for (final p in subProfiles) {
          expect(await secrets.read(ProfileStore.passwordKey(p.id)), isNull);
        }
      },
    );

    test(
      'applySubscriptionSync aborts if deleted mid-flight and preserves concurrent edits',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{});
        final secrets = MemorySecretStore();
        final store = ProfileStore(secretsOverride: secrets);

        const initialSub = Subscription(
          id: 'sub-race',
          name: 'Original Name',
          url: 'https://example.com/race',
          autoUpdate: false,
        );
        await store.saveSubscription(initialSub);
        await store.saveSubscription(
          initialSub.copyWith(name: 'Renamed Name', autoUpdate: true),
        );

        // Sync started with stale snapshot `initialSub`; should preserve concurrent rename/toggle.
        await store.applySubscriptionSync(
          subscription: initialSub,
          envelopes: [_env(name: 'One', server: 'one.example.com')],
          trigger: SubscriptionSyncTrigger.manual,
          syncedAt: DateTime.utc(2026, 11, 22),
        );
        final subsAfterEdit = await store.loadSubscriptions();
        expect(subsAfterEdit.single.name, 'Renamed Name');
        expect(subsAfterEdit.single.autoUpdate, isTrue);

        // Now delete the subscription, then finish an in-flight manual sync -> must abort cleanly.
        await store.deleteSubscription('sub-race');
        await store.applySubscriptionSync(
          subscription: initialSub,
          envelopes: [_env(name: 'Ghost', server: 'ghost.example.com')],
          trigger: SubscriptionSyncTrigger.manual,
          syncedAt: DateTime.utc(2026, 11, 22),
        );
        expect(await store.loadSubscriptions(), isEmpty);
        expect(await store.loadProfiles(), isEmpty);
      },
    );

    test(
      'stores subscription URL in SecretStore, scrubs SharedPreferences, migrates legacy, and clears on reset',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          ProfileStore.prefsKeySubscriptionsJson:
              '[{"id":"legacy-1","name":"Legacy","url":"https://legacy.example/sub"}]',
        });
        final prefs = await SharedPreferences.getInstance();
        final secrets = MemorySecretStore();
        final store = ProfileStore(
          prefsOverride: prefs,
          secretsOverride: secrets,
        );

        final loaded = await store.loadSubscriptions();
        expect(loaded.single.url, 'https://legacy.example/sub');
        expect(loaded.single.urlMissing, isFalse);
        expect(
          await secrets.read(ProfileStore.subscriptionUrlKey('legacy-1')),
          'https://legacy.example/sub',
        );
        expect(
          prefs.getString(ProfileStore.prefsKeySubscriptionsJson),
          isNot(contains('legacy.example')),
        );

        await store.resetSecureStorage();
        final afterReset = await store.loadSubscriptions();
        expect(afterReset.single.url, isEmpty);
        expect(afterReset.single.urlMissing, isTrue);
      },
    );
  });
}
