import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_sync_service.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

class _FakeBridge extends SubscriptionBridge {
  SubscriptionFetchRoute route = const SubscriptionFetchRoute.direct();
  final List<String> progressStages = <String>[];
  int progressCancels = 0;
  final List<({String id, int imported, int updated, int removed})> results =
      [];

  @override
  Future<SubscriptionFetchRoute> getActiveNetworkRoute() async => route;

  @override
  Future<void> showProgressNotification({
    required String subscriptionId,
    required String subscriptionName,
    required String stage,
    int processed = 0,
    int total = 0,
  }) async {
    progressStages.add(stage);
  }

  @override
  Future<void> cancelProgressNotification(String subscriptionId) async {
    progressCancels += 1;
  }

  @override
  Future<void> showResultNotification({
    required String subscriptionId,
    required String subscriptionName,
    required int importedCount,
    required int updatedCount,
    required int removedCount,
  }) async {
    results.add((
      id: subscriptionId,
      imported: importedCount,
      updated: updatedCount,
      removed: removedCount,
    ));
  }
}

class _PassthroughHttpOverrides extends HttpOverrides {}

class _FakeHttpClient implements SubscriptionHttpClient {
  _FakeHttpClient(this.handler);

  final Future<String> Function(Uri uri, SubscriptionFetchRoute route) handler;
  SubscriptionFetchRoute? lastRoute;
  int calls = 0;

  @override
  Future<String> fetchBody(Uri uri, {required SubscriptionFetchRoute route}) {
    calls += 1;
    lastRoute = route;
    return handler(uri, route);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SubscriptionSyncService', () {
    test(
      'defers without hitting network when TunnelForge VPN is recovering',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = ProfileStore(
          prefsOverride: await SharedPreferences.getInstance(),
          secretsOverride: MemorySecretStore(),
        );
        final bridge = _FakeBridge()
          ..route = const SubscriptionFetchRoute.defer(reason: 'reconnecting');
        final http = _FakeHttpClient((_, _) async => 'tf://a.example.com');
        final svc = SubscriptionSyncService(
          profileStore: store,
          bridge: bridge,
          httpClient: http,
        );

        await expectLater(
          svc.addAndSyncSubscription(
            name: 'Test',
            url: 'https://example.com/sub',
            autoUpdate: true,
            updateIntervalMinutes: 60,
            intervalUnit: SubscriptionIntervalUnit.hours,
          ),
          throwsA(
            isA<SubscriptionException>().having(
              (e) => e.code,
              'code',
              SubscriptionErrorCode.tunnelRecovering,
            ),
          ),
        );
        expect(http.calls, 0);
      },
    );

    test(
      'passes localHttpProxy route and suppresses notification/dialog on zero-change background sync',
      () async {
        SharedPreferences.setMockInitialValues({});
        final store = ProfileStore(
          prefsOverride: await SharedPreferences.getInstance(),
          secretsOverride: MemorySecretStore(),
        );
        final bridge = _FakeBridge()
          ..route = const SubscriptionFetchRoute.localHttpProxy(port: 8080);
        var payload =
            'tf://vpn1.example.com?displayName=Node1&user=u&password=p&psk=k';
        final http = _FakeHttpClient((_, _) async => payload);
        final svc = SubscriptionSyncService(
          profileStore: store,
          bridge: bridge,
          httpClient: http,
        );

        final initial = await svc.addAndSyncSubscription(
          name: 'Proxied Sub',
          url: 'https://example.com/sub',
          autoUpdate: true,
          updateIntervalMinutes: 60,
          intervalUnit: SubscriptionIntervalUnit.hours,
        );
        expect(
          http.lastRoute,
          const SubscriptionFetchRoute.localHttpProxy(port: 8080),
        );
        expect(initial.importedCount, 1);

        // Background auto-update with NO changes: shows & cancels progress, NO result notif, NO queued dialog.
        final bgNoChange = await svc.syncSubscriptionById(
          initial.subscriptionId,
          trigger: SubscriptionSyncTrigger.backgroundAuto,
        );
        expect(bgNoChange!.hasChanges, isFalse);
        expect(bridge.progressStages, contains('fetching'));
        expect(bridge.progressCancels, 1);
        expect(bridge.results, isEmpty);
        expect(await store.consumePendingSubscriptionSummaries(), isEmpty);

        // Background auto-update WITH changes: shows result notif AND enqueues pending summary.
        payload =
            'tf://vpn1.example.com?displayName=Node1&user=u&password=p&psk=k\n'
            'tf://vpn2.example.com?displayName=Node2&user=u&password=p&psk=k';
        final bgChanged = await svc.syncSubscriptionById(
          initial.subscriptionId,
          trigger: SubscriptionSyncTrigger.backgroundAuto,
        );
        expect(bgChanged!.importedCount, 1);
        expect(bridge.progressCancels, 2);
        expect(bridge.results, hasLength(1));
        expect(bridge.results.single.imported, 1);
        final queued = await store.consumePendingSubscriptionSummaries();
        expect(queued, hasLength(1));
        expect(queued.single.importedCount, 1);
      },
    );
  });

  group('DartSubscriptionHttpClient', () {
    test(
      'fetches plaintext, handles HTTP status errors, and enforces response byte cap',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          server.listen((request) async {
            switch (request.uri.path) {
              case '/ok':
                request.response
                  ..statusCode = 200
                  ..write(
                    'tf://srv.example.com?displayName=Srv&user=u&password=p&psk=k',
                  );
                await request.response.close();
              case '/err':
                request.response.statusCode = 502;
                await request.response.close();
              case '/big':
                request.response
                  ..statusCode = 200
                  ..add(List<int>.filled(2048, 0x41));
                await request.response.close();
            }
          });

          final client = DartSubscriptionHttpClient(
            maxResponseBytes: 1024,
            allowLoopback: true,
          );
          final base = 'http://127.0.0.1:${server.port}';

          final body = await client.fetchBody(
            Uri.parse('$base/ok'),
            route: const SubscriptionFetchRoute.direct(),
          );
          expect(body, contains('tf://srv.example.com'));

          await expectLater(
            client.fetchBody(
              Uri.parse('$base/err'),
              route: const SubscriptionFetchRoute.direct(),
            ),
            throwsA(
              isA<SubscriptionException>()
                  .having((e) => e.code, 'code', SubscriptionErrorCode.http)
                  .having((e) => e.statusCode, 'statusCode', 502),
            ),
          );

          await expectLater(
            client.fetchBody(
              Uri.parse('$base/big'),
              route: const SubscriptionFetchRoute.direct(),
            ),
            throwsA(
              isA<SubscriptionException>().having(
                (e) => e.code,
                'code',
                SubscriptionErrorCode.tooLarge,
              ),
            ),
          );
        }, _PassthroughHttpOverrides());
      },
    );

    test(
      'blocks loopback/SSRF redirects, https-to-http downgrades, and hanging 500 body streams',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final openResponses = <HttpResponse>[];
          addTearDown(() async {
            for (final resp in openResponses) {
              try {
                await resp.close();
              } catch (_) {}
            }
          });
          server.listen((request) async {
            switch (request.uri.path) {
              case '/redirect-loopback':
                request.response.statusCode = 302;
                request.response.headers.set(
                  HttpHeaders.locationHeader,
                  'http://127.0.0.1:${server.port}/secret',
                );
                await request.response.close();
              case '/hang-500':
                request.response.statusCode = 500;
                request.response.write('err');
                await request.response.flush();
                // Intentionally keep stream open; client must not hang on drain().
                openResponses.add(request.response);
              case '/secret':
                request.response
                  ..statusCode = 200
                  ..write('tf://should-never-reach.example.com');
                await request.response.close();
            }
          });

          final client = DartSubscriptionHttpClient(
            readTimeout: const Duration(seconds: 2),
          );
          final base = 'http://127.0.0.1:${server.port}';

          // 1. Default client rejects direct loopback SSRF targets.
          await expectLater(
            client.fetchBody(
              Uri.parse('$base/secret'),
              route: const SubscriptionFetchRoute.direct(),
            ),
            throwsA(isA<SubscriptionException>()),
          );

          // 2. Redirects from https->http, public->RFC1918, or to loopback are blocked,
          //    and /hang-500 closes immediately without hanging on response.drain().
          await expectLater(
            DartSubscriptionHttpClient.validateRedirectTarget(
              Uri.parse('http://example.com/downgrade'),
              previousUri: Uri.parse('https://example.com/sub'),
              initialUri: Uri.parse('https://example.com/sub'),
            ),
            throwsA(isA<SubscriptionException>()),
          );
          await expectLater(
            DartSubscriptionHttpClient.validateRedirectTarget(
              Uri.parse('https://10.0.0.1/internal'),
              previousUri: Uri.parse('https://example.com/sub'),
              initialUri: Uri.parse('https://example.com/sub'),
            ),
            throwsA(isA<SubscriptionException>()),
          );

          final hangClient = DartSubscriptionHttpClient(
            readTimeout: const Duration(seconds: 3),
            allowLoopback: true,
          );
          await expectLater(
            hangClient.fetchBody(
              Uri.parse('$base/redirect-loopback'),
              route: const SubscriptionFetchRoute.direct(),
            ),
            throwsA(isA<SubscriptionException>()),
          );

          final sw = Stopwatch()..start();
          await expectLater(
            hangClient.fetchBody(
              Uri.parse('$base/hang-500'),
              route: const SubscriptionFetchRoute.direct(),
            ),
            throwsA(
              isA<SubscriptionException>()
                  .having((e) => e.code, 'code', SubscriptionErrorCode.http)
                  .having((e) => e.statusCode, 'statusCode', 500),
            ),
          );
          sw.stop();
          expect(sw.elapsedMilliseconds, lessThan(500));
        }, _PassthroughHttpOverrides());
      },
    );
  });
}
