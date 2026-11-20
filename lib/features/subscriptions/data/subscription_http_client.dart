import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/subscriptions/data/subscription_bridge.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

/// Fetches plaintext subscription bodies over HTTP(S), routing through local proxy when needed.
abstract class SubscriptionHttpClient {
  Future<String> fetchBody(Uri uri, {required SubscriptionFetchRoute route});
}

class DartSubscriptionHttpClient implements SubscriptionHttpClient {
  DartSubscriptionHttpClient({
    this.connectTimeout = const Duration(seconds: 15),
    this.readTimeout = const Duration(seconds: 20),
    this.maxResponseBytes = defaultMaxResponseBytes,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  static const int defaultMaxResponseBytes = 5 * 1024 * 1024; // 5 MiB

  final Duration connectTimeout;
  final Duration readTimeout;
  final int maxResponseBytes;
  final HttpClient Function() _clientFactory;

  @override
  Future<String> fetchBody(
    Uri uri, {
    required SubscriptionFetchRoute route,
  }) async {
    if (route.kind == SubscriptionRouteKind.defer) {
      throw SubscriptionException(
        route.reason ?? 'TunnelForge VPN tunnel is recovering',
        code: SubscriptionErrorCode.tunnelRecovering,
      );
    }

    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') || uri.host.trim().isEmpty) {
      throw const SubscriptionException(
        'Invalid subscription URL',
        code: SubscriptionErrorCode.unexpected,
      );
    }

    final client = _clientFactory();
    client.connectionTimeout = connectTimeout;
    client.findProxy = (_) => _proxyDirectiveFor(route);

    try {
      final request = await client.getUrl(uri).timeout(connectTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.acceptHeader, 'text/plain, */*;q=0.8');
      request.headers.set(HttpHeaders.userAgentHeader, 'TunnelForge');

      final response = await request.close().timeout(readTimeout);
      final statusCode = response.statusCode;
      if (statusCode < 200 || statusCode >= 300) {
        await response.drain<void>().catchError((_) {});
        throw SubscriptionException(
          'Subscription server returned HTTP $statusCode',
          code: SubscriptionErrorCode.http,
          statusCode: statusCode,
        );
      }

      final builder = BytesBuilder(copy: false);
      var totalBytes = 0;
      await for (final chunk in response.timeout(readTimeout)) {
        totalBytes += chunk.length;
        if (totalBytes > maxResponseBytes) {
          throw SubscriptionException(
            'Subscription response exceeded $maxResponseBytes bytes',
            code: SubscriptionErrorCode.tooLarge,
          );
        }
        builder.add(chunk);
      }

      try {
        return utf8.decode(builder.takeBytes());
      } on FormatException catch (error) {
        throw SubscriptionException(
          'Subscription response is not valid UTF-8: ${error.message}',
          code: SubscriptionErrorCode.invalidEncoding,
        );
      }
    } on SubscriptionException {
      rethrow;
    } on TimeoutException {
      throw const SubscriptionException(
        'Subscription request timed out',
        code: SubscriptionErrorCode.timeout,
      );
    } on HandshakeException catch (error) {
      throw SubscriptionException(
        'TLS handshake failed: ${error.message}',
        code: SubscriptionErrorCode.tls,
      );
    } on SocketException catch (error) {
      throw SubscriptionException(
        'Network error: ${error.message}',
        code: SubscriptionErrorCode.network,
      );
    } on HttpException catch (error) {
      throw SubscriptionException(
        'HTTP error: ${error.message}',
        code: SubscriptionErrorCode.network,
      );
    } catch (error) {
      throw SubscriptionException(
        'Unexpected error: ${error.runtimeType}',
        code: SubscriptionErrorCode.unexpected,
      );
    } finally {
      client.close(force: true);
    }
  }

  static String _proxyDirectiveFor(SubscriptionFetchRoute route) {
    return switch (route.kind) {
      SubscriptionRouteKind.direct => 'DIRECT',
      SubscriptionRouteKind.localHttpProxy => () {
        final host = route.proxyHost?.trim();
        final port = route.proxyPort;
        if (host == null ||
            host.isEmpty ||
            port == null ||
            !ProxySettings.isAllowedPort(port)) {
          throw const SocketException('Invalid local HTTP proxy configuration');
        }
        return 'PROXY $host:$port';
      }(),
      SubscriptionRouteKind.defer => 'DIRECT',
    };
  }
}
