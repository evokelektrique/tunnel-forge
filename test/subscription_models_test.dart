import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/l10n/generated/app_localizations_en.dart';

void main() {
  final l10n = AppLocalizationsEn();

  group('Subscription validation', () {
    test('validates name and URLs including cleartext http detection', () {
      expect(Subscription.validateName('', l10n: l10n), isNotNull);
      expect(Subscription.validateName('   ', l10n: l10n), isNotNull);
      expect(Subscription.validateName('My Sub', l10n: l10n), isNull);

      expect(Subscription.validateUrl('', l10n: l10n), isNotNull);
      expect(
        Subscription.validateUrl('ftp://example.com/sub', l10n: l10n),
        isNotNull,
      );
      expect(
        Subscription.validateUrl('example.com/sub', l10n: l10n),
        isNotNull,
      );
      expect(
        Subscription.validateUrl('https://example.com/sub', l10n: l10n),
        isNull,
      );
      expect(
        Subscription.validateUrl('http://192.168.1.5/sub', l10n: l10n),
        isNull,
      );

      expect(Subscription.isCleartextHttpUrl('http://example.com/sub'), isTrue);
      expect(
        Subscription.isCleartextHttpUrl('https://example.com/sub'),
        isFalse,
      );
    });

    test(
      'validates custom interval with minutes/hours/days units and 15 min floor',
      () {
        expect(
          Subscription.validateCustomInterval(
            '14',
            SubscriptionIntervalUnit.minutes,
            l10n: l10n,
          ),
          isNotNull,
        );
        expect(
          Subscription.validateCustomInterval(
            '15',
            SubscriptionIntervalUnit.minutes,
            l10n: l10n,
          ),
          isNull,
        );
        expect(
          Subscription.parseCustomIntervalMinutes(
            '45',
            SubscriptionIntervalUnit.minutes,
          ),
          45,
        );
        expect(
          Subscription.parseCustomIntervalMinutes(
            '2',
            SubscriptionIntervalUnit.hours,
          ),
          120,
        );
        expect(
          Subscription.parseCustomIntervalMinutes(
            '3',
            SubscriptionIntervalUnit.days,
          ),
          4320,
        );
        expect(
          Subscription.validateCustomInterval(
            '31',
            SubscriptionIntervalUnit.days,
            l10n: l10n,
          ),
          isNotNull,
        );
        expect(
          Subscription.parseCustomIntervalMinutes(
            '31',
            SubscriptionIntervalUnit.days,
          ),
          isNull,
        );
      },
    );
  });

  group('Subscription scheduling and serialization', () {
    test('isDueAt checks autoUpdate flag and elapsed interval', () {
      final t0 = DateTime.utc(2026, 11, 20, 12, 0);
      final disabled = Subscription(
        id: 's1',
        name: 'Disabled',
        url: 'https://example.com/sub',
        autoUpdate: false,
        updateIntervalMinutes: 15,
      );
      expect(disabled.isDueAt(t0), isFalse);

      final neverUpdated = disabled.copyWith(autoUpdate: true);
      expect(neverUpdated.isDueAt(t0), isTrue);

      final recent = neverUpdated.copyWith(
        lastUpdatedAtMs: t0
            .subtract(const Duration(minutes: 14))
            .millisecondsSinceEpoch,
      );
      expect(recent.isDueAt(t0), isFalse);

      final due = neverUpdated.copyWith(
        lastUpdatedAtMs: t0
            .subtract(const Duration(minutes: 15))
            .millisecondsSinceEpoch,
      );
      expect(due.isDueAt(t0), isTrue);
    });

    test('round-trips Subscription and coalesces SubscriptionSyncSummary', () {
      const sub = Subscription(
        id: 'sub-1',
        name: 'Provider A',
        url: 'https://example.com/sub.txt',
        autoUpdate: true,
        updateIntervalMinutes: 45,
        intervalUnit: SubscriptionIntervalUnit.minutes,
        lastUpdatedAtMs: 1700000000000,
        lastError: 'http:503',
      );
      final restored = Subscription.tryFromJson(sub.toJson());
      expect(restored, sub);
      expect(restored!.localizedLastError(l10n), contains('503'));

      const first = SubscriptionSyncSummary(
        subscriptionId: 'sub-1',
        subscriptionName: 'Provider A',
        importedCount: 2,
        updatedCount: 1,
        removedCount: 0,
        skippedInvalidLines: 1,
        syncedAtMs: 1000,
        trigger: SubscriptionSyncTrigger.backgroundAuto,
      );
      const second = SubscriptionSyncSummary(
        subscriptionId: 'sub-1',
        subscriptionName: 'Provider A',
        importedCount: 1,
        updatedCount: 2,
        removedCount: 3,
        skippedInvalidLines: 0,
        syncedAtMs: 2000,
        trigger: SubscriptionSyncTrigger.backgroundAuto,
      );
      final merged = first.coalesceWith(second);
      expect(merged.importedCount, 3);
      expect(merged.updatedCount, 3);
      expect(merged.removedCount, 3);
      expect(merged.syncedAtMs, 2000);
      expect(SubscriptionSyncSummary.tryFromJson(merged.toJson()), merged);
    });
  });
}
