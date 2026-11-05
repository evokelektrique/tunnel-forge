import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:tunnel_forge/core/network/connectivity_checker.dart';

class _Client extends Mock implements HttpClient {}

class _Request extends Mock implements HttpClientRequest {}

class _Response extends Mock implements HttpClientResponse {}

void main() {
  test(
    'latency excludes connection setup and response body download',
    () async {
      final client = _Client();
      final request = _Request();
      final response = _Response();
      final uri = Uri.parse('https://example.com/check');
      when(() => client.getUrl(uri)).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return request;
      });
      when(request.close).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 30));
        return response;
      });
      when(() => response.statusCode).thenReturn(204);
      when(() => response.drain<void>()).thenAnswer((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });

      final result = await HttpConnectivityChecker(
        clientFactory: () => client,
      ).ping(ConnectivityPingRequest.direct(uri.toString()));

      expect(result.reachable, isTrue);
      expect(result.setupMs, greaterThanOrEqualTo(140));
      expect(result.latencyMs, greaterThanOrEqualTo(20));
      expect(
        result.totalMs! - result.setupMs! - result.latencyMs!,
        greaterThanOrEqualTo(140),
      );
      verify(() => client.close(force: true)).called(1);
    },
  );

  test('HTTP failures remain unreachable and close the client', () async {
    final client = _Client();
    final request = _Request();
    final response = _Response();
    final uri = Uri.parse('https://example.com/check');
    when(() => client.getUrl(uri)).thenAnswer((_) async => request);
    when(request.close).thenAnswer((_) async => response);
    when(() => response.statusCode).thenReturn(503);
    when(() => response.drain<void>()).thenAnswer((_) async {});

    final result = await HttpConnectivityChecker(
      clientFactory: () => client,
    ).ping(ConnectivityPingRequest.direct(uri.toString()));

    expect(result.reachable, isFalse);
    expect(result.statusCode, 503);
    expect(result.latencyMs, isNull);
    verify(() => client.close(force: true)).called(1);
  });
}
