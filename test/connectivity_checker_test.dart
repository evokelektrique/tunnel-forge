import 'dart:async';
import 'dart:convert';
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

  test(
    'cancelSignal closes client immediately without waiting for response',
    () async {
      final client = _Client();
      final uri = Uri.parse('https://example.com/check');
      final pendingRequest = Completer<HttpClientRequest>();
      final cancelCompleter = Completer<void>();
      when(() => client.getUrl(uri)).thenAnswer((_) => pendingRequest.future);

      final resultFuture = HttpConnectivityChecker(clientFactory: () => client)
          .ping(
            ConnectivityPingRequest.direct(uri.toString()),
            cancelSignal: cancelCompleter.future,
          );

      cancelCompleter.complete();
      final result = await resultFuture;

      expect(result.reachable, isFalse);
      expect(result.error, 'Cancelled');
      verify(() => client.close(force: true)).called(1);
    },
  );

  test(
    'authenticates HTTP proxy challenges when proxy credentials are provided',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final expectedAuth = 'Basic ${base64Encode(utf8.encode('user:secret'))}';
      final authHeadersSeen = <String?>[];

      unawaited(() async {
        await for (final socket in server) {
          final buffer = StringBuffer();
          await for (final chunk in socket) {
            buffer.write(utf8.decode(chunk, allowMalformed: true));
            if (buffer.toString().contains('\r\n\r\n')) break;
          }
          final lines = buffer.toString().split('\r\n');
          String? authHeader;
          for (final line in lines) {
            final idx = line.indexOf(':');
            if (idx > 0 &&
                line.substring(0, idx).trim().toLowerCase() ==
                    'proxy-authorization') {
              authHeader = line.substring(idx + 1).trim();
            }
          }
          authHeadersSeen.add(authHeader);
          if (authHeader == expectedAuth) {
            socket.write(
              'HTTP/1.1 204 No Content\r\n'
              'Content-Length: 0\r\n'
              'Connection: close\r\n'
              '\r\n',
            );
          } else {
            socket.write(
              'HTTP/1.1 407 Proxy Authentication Required\r\n'
              'Proxy-Authenticate: Basic realm="TunnelForge"\r\n'
              'Content-Length: 0\r\n'
              'Connection: close\r\n'
              '\r\n',
            );
          }
          await socket.flush();
          await socket.close();
          if (authHeader == expectedAuth) break;
        }
      }());

      final result = await HttpConnectivityChecker().ping(
        ConnectivityPingRequest.localHttpProxy(
          url: 'http://example.com/generate_204',
          proxyPort: server.port,
          proxyUsername: 'user',
          proxyPassword: 'secret',
        ),
      );

      expect(result.reachable, isTrue);
      expect(result.statusCode, 204);
      expect(authHeadersSeen, [null, expectedAuth]);
    },
  );
}
