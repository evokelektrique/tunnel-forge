import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tunnel_forge/core/logging/diagnostics_bridge.dart';
import 'package:tunnel_forge/features/profiles/data/profile_store.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_background_runner.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_contract.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_http_client.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/main.dart';

class _PassthroughHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SubscriptionContract.methodChannel);
  const diagnostics = MethodChannel(DiagnosticsContract.channel);
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    channel.setMethodCallHandler(null);
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(diagnostics, null);
  });

  Future<Object?> runScheduledUpdate(
    String subscriptionId, {
    bool isBackground = true,
  }) async {
    final outcome = Completer<Object?>();
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(
        MethodCall(SubscriptionContract.methodRunScheduledUpdate, {
          SubscriptionContract.argSubscriptionId: subscriptionId,
          SubscriptionContract.argIsBackground: isBackground,
        }),
      ),
      (reply) => outcome.complete(codec.decodeEnvelope(reply!)),
    );
    return outcome.future;
  }

  test(
    'scheduled update handler is registered before signaling readiness',
    () async {
      final ready = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, SubscriptionContract.methodBackgroundRunnerReady);
        ready.complete();
        return null;
      });

      await subscriptionBackgroundMain();
      expect(ready.isCompleted, isTrue);
      expect(
        await runScheduledUpdate('removed-subscription'),
        SubscriptionContract.outcomeSuccess,
      );
    },
  );

  test('scheduled updates report retryable and permanent failures', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 403;
        await request.response.close();
      });
      final store = ProfileStore(secretsOverride: MemorySecretStore());
      await store.saveSubscription(
        Subscription(
          id: 'fixture',
          name: 'Local fixture',
          url: 'http://127.0.0.1:${server.port}/list',
        ),
      );

      Object? route = {
        SubscriptionContract.argRoute: SubscriptionContract.routeDefer,
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method != SubscriptionContract.methodGetActiveNetworkRoute) {
          return null;
        }
        if (route is PlatformException) throw route;
        return route;
      });
      var diagnosticWrites = 0;
      messenger.setMockMethodCallHandler(diagnostics, (call) async {
        expect(call.method, DiagnosticsContract.appendLogs);
        diagnosticWrites++;
        throw PlatformException(code: 'fixture-log-offline');
      });
      await runSubscriptionBackgroundMain(
        profileStore: store,
        httpClient: DartSubscriptionHttpClient(allowLoopback: true),
      );
      expect(
        await runScheduledUpdate('fixture', isBackground: false),
        SubscriptionContract.outcomeRetry,
      );
      expect(diagnosticWrites, greaterThan(0));

      route = null;
      expect(
        await runScheduledUpdate('fixture'),
        SubscriptionContract.outcomeFailure,
      );

      route = PlatformException(code: 'fixture-route-offline');
      expect(
        await runScheduledUpdate('fixture'),
        SubscriptionContract.outcomeRetry,
      );
    }, _PassthroughHttpOverrides());
  });
}
