import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tunnel_forge/core/network/connectivity_checker.dart';
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
    this.maxRedirects = defaultMaxRedirects,
    this.allowLoopback = false,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  static const int defaultMaxResponseBytes = 5 * 1024 * 1024; // 5 MiB
  static const int defaultMaxRedirects = 5;

  final Duration connectTimeout;
  final Duration readTimeout;
  final int maxResponseBytes;
  final int maxRedirects;
  final bool allowLoopback;
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

    final initialIsPrivate = _isPrivateNetworkHost(uri.host);
    await _validateTargetUri(
      uri,
      route: route,
      previousUri: null,
      initialIsPrivate: initialIsPrivate,
      allowInitialLoopback: allowLoopback,
    );

    final deadline = DateTime.now().add(connectTimeout + readTimeout);
    Duration remainingBudget() {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('Subscription request timed out');
      }
      return left;
    }

    final client = _clientFactory();
    client.connectionTimeout = connectTimeout;
    client.findProxy = (_) => _proxyDirectiveFor(route);
    if (route.kind == SubscriptionRouteKind.localHttpProxy) {
      configureLocalHttpProxyAuth(
        client,
        proxyHost: route.proxyHost,
        proxyPort: route.proxyPort,
        username: route.proxyUsername,
        password: route.proxyPassword,
      );
    }

    try {
      var currentUri = uri;
      late HttpClientResponse response;
      for (var redirects = 0; ; redirects++) {
        final stepTimeout = remainingBudget();
        final connectStep = stepTimeout < connectTimeout ? stepTimeout : connectTimeout;
        final request = await client.getUrl(currentUri).timeout(connectStep);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, 'text/plain, */*;q=0.8');
        request.headers.set(HttpHeaders.userAgentHeader, 'TunnelForge');

        final readStep = remainingBudget();
        final closeTimeout = readStep < readTimeout ? readStep : readTimeout;
        response = await request.close().timeout(closeTimeout);
        final statusCode = response.statusCode;

        if (statusCode == HttpStatus.movedPermanently ||
            statusCode == HttpStatus.found ||
            statusCode == HttpStatus.movedTemporarily ||
            statusCode == HttpStatus.seeOther ||
            statusCode == HttpStatus.temporaryRedirect ||
            statusCode == HttpStatus.permanentRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}, onError: (_) {}, cancelOnError: true).cancel();
          if (redirects >= maxRedirects) {
            throw const SubscriptionException(
              'Too many redirects',
              code: SubscriptionErrorCode.network,
            );
          }
          if (location == null || location.trim().isEmpty) {
            throw const SubscriptionException(
              'Redirect response missing Location header',
              code: SubscriptionErrorCode.network,
            );
          }
          final nextUri = currentUri.resolve(location.trim());
          await _validateTargetUri(
            nextUri,
            route: route,
            previousUri: currentUri,
            initialIsPrivate: initialIsPrivate,
            allowInitialLoopback: false,
          );
          currentUri = nextUri;
          continue;
        }

        if (statusCode < 200 || statusCode >= 300) {
          throw SubscriptionException(
            'Subscription server returned HTTP $statusCode',
            code: SubscriptionErrorCode.http,
            statusCode: statusCode,
          );
        }
        break;
      }

      final builder = BytesBuilder(copy: false);
      var totalBytes = 0;
      await for (final chunk in response.timeout(remainingBudget())) {
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

  static Future<void> validateRedirectTarget(
    Uri targetUri, {
    required Uri previousUri,
    required Uri initialUri,
  }) => _validateTargetUri(
    targetUri,
    route: const SubscriptionFetchRoute.direct(),
    previousUri: previousUri,
    initialIsPrivate: _isPrivateNetworkHost(initialUri.host),
    allowInitialLoopback: false,
  );

  static Future<void> _validateTargetUri(
    Uri uri, {
    required SubscriptionFetchRoute route,
    required Uri? previousUri,
    required bool initialIsPrivate,
    required bool allowInitialLoopback,
  }) async {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.trim();
    if ((scheme != 'http' && scheme != 'https') || host.isEmpty) {
      throw const SubscriptionException(
        'Invalid subscription URL',
        code: SubscriptionErrorCode.unexpected,
      );
    }
    if (previousUri != null &&
        previousUri.scheme.toLowerCase() == 'https' &&
        scheme != 'https') {
      throw const SubscriptionException(
        'Blocked insecure HTTPS redirect downgrade',
        code: SubscriptionErrorCode.tls,
      );
    }

    final normalizedHost = host
        .replaceFirst(RegExp(r'^\[(.*)\]$'), r'$1')
        .split('%')
        .first
        .toLowerCase();
    if (!allowInitialLoopback &&
        (normalizedHost == 'localhost' ||
            normalizedHost.endsWith('.localhost'))) {
      throw const SubscriptionException(
        'Blocked loopback subscription target',
        code: SubscriptionErrorCode.network,
      );
    }

    final parsedIp = InternetAddress.tryParse(normalizedHost);
    if (parsedIp != null) {
      _validateIpAddress(
        parsedIp,
        isRedirect: previousUri != null,
        initialIsPrivate: initialIsPrivate,
        allowLoopback: allowInitialLoopback,
      );
      return;
    }

    if (route.kind == SubscriptionRouteKind.direct && !allowInitialLoopback) {
      try {
        final resolved = await InternetAddress.lookup(normalizedHost);
        for (final addr in resolved) {
          _validateIpAddress(
            addr,
            isRedirect: previousUri != null,
            initialIsPrivate: initialIsPrivate,
            allowLoopback: false,
          );
        }
      } on SocketException {
        // Defer unreachable host handling to HttpClient unless it resolved locally.
      }
    }
  }

  static void _validateIpAddress(
    InternetAddress addr, {
    required bool isRedirect,
    required bool initialIsPrivate,
    required bool allowLoopback,
  }) {
    final raw = addr.rawAddress;
    final ipv4 = _extractIpv4Bytes(raw);
    if (ipv4 != null) {
      final b0 = ipv4[0];
      final b1 = ipv4[1];
      final isUnspecified = b0 == 0 && ipv4[1] == 0 && ipv4[2] == 0 && ipv4[3] == 0;
      final isLoopback = b0 == 127;
      final isLinkLocal = b0 == 169 && b1 == 254;
      final isPrivate =
          b0 == 10 ||
          (b0 == 172 && b1 >= 16 && b1 <= 31) ||
          (b0 == 192 && b1 == 168);
      if (isUnspecified || isLinkLocal || (isLoopback && !allowLoopback)) {
        throw const SubscriptionException(
          'Blocked restricted subscription target address',
          code: SubscriptionErrorCode.network,
        );
      }
      if (isRedirect && isPrivate && !initialIsPrivate) {
        throw const SubscriptionException(
          'Blocked redirect to private network address',
          code: SubscriptionErrorCode.network,
        );
      }
      return;
    }

    final isZero = raw.every((b) => b == 0);
    final isUla = raw.length == 16 && (raw[0] & 0xfe) == 0xfc;
    if (isZero || addr.isLinkLocal || (addr.isLoopback && !allowLoopback)) {
      throw const SubscriptionException(
        'Blocked restricted subscription target address',
        code: SubscriptionErrorCode.network,
      );
    }
    if (isRedirect && isUla && !initialIsPrivate) {
      throw const SubscriptionException(
        'Blocked redirect to private network address',
        code: SubscriptionErrorCode.network,
      );
    }
  }

  static bool _isPrivateNetworkHost(String host) {
    final clean = host
        .trim()
        .replaceFirst(RegExp(r'^\[(.*)\]$'), r'$1')
        .split('%')
        .first;
    final addr = InternetAddress.tryParse(clean);
    if (addr == null) return false;
    final ipv4 = _extractIpv4Bytes(addr.rawAddress);
    if (ipv4 != null) {
      final b0 = ipv4[0];
      final b1 = ipv4[1];
      return b0 == 10 ||
          (b0 == 172 && b1 >= 16 && b1 <= 31) ||
          (b0 == 192 && b1 == 168);
    }
    return addr.rawAddress.length == 16 && (addr.rawAddress[0] & 0xfe) == 0xfc;
  }

  static Uint8List? _extractIpv4Bytes(Uint8List raw) {
    if (raw.length == 4) return raw;
    if (raw.length == 16) {
      var isMapped = true;
      for (var i = 0; i < 10; i++) {
        if (raw[i] != 0) {
          isMapped = false;
          break;
        }
      }
      if (isMapped && raw[10] == 0xff && raw[11] == 0xff) {
        return raw.sublist(12, 16);
      }
    }
    return null;
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
