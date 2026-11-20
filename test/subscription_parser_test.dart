import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_parser.dart';

void main() {
  group('SubscriptionParser', () {
    test('parses plaintext tf:// lines with BOM, comments, and blank lines', () {
      const payload =
          '\uFEFF# Provider header\n'
          '\n'
          'tf://vpn1.example.com?protocol=l2tp&displayName=Germany+1&user=alice&password=pw1&psk=k1&dns=1.1.1.1&mtu=1400\n'
          '   # another comment\r\n'
          'tf://vpn2.example.com?protocol=pptp&displayName=Office+PPTP&user=bob&password=pw2\r\n';

      final parsed = SubscriptionParser.parse(payload);
      expect(parsed.skippedInvalidLines, 0);
      expect(parsed.envelopes, hasLength(2));

      final first = parsed.envelopes[0];
      expect(first.server, 'vpn1.example.com');
      expect(first.protocol, TunnelProtocol.l2tp);
      expect(first.displayName, 'Germany+1');
      expect(first.user, 'alice');
      expect(first.password, 'pw1');
      expect(first.psk, 'k1');
      expect(first.dnsAutomatic, isFalse);
      expect(first.dns1Host, '1.1.1.1');
      expect(first.mtu, 1400);

      final second = parsed.envelopes[1];
      expect(second.server, 'vpn2.example.com');
      expect(second.protocol, TunnelProtocol.pptp);
      expect(second.psk, '');
    });

    test('skips malformed lines while keeping valid tf:// entries', () {
      const payload =
          'tf://good1.example.com?displayName=Good%201&user=u1&password=p1&psk=s1\n'
          'l2tp://vpn:vpn@1.2.3.4?psk=vpn#Legacy\n'
          'not a link at all\n'
          'tf://good2.example.com?displayName=Good%202&user=u2&password=p2&psk=s2\n';

      final parsed = SubscriptionParser.parse(payload);
      expect(parsed.envelopes, hasLength(2));
      expect(parsed.skippedInvalidLines, 2);
      expect(parsed.envelopes.first.displayName, 'Good 1');
      expect(parsed.envelopes.last.displayName, 'Good 2');
    });

    test('throws noValidProfiles for empty, comment-only, or HTML bodies', () {
      for (final bad in ['', '   \n# only comment\n', '<html>404</html>']) {
        expect(
          () => SubscriptionParser.parse(bad),
          throwsA(
            isA<SubscriptionException>().having(
              (e) => e.code,
              'code',
              SubscriptionErrorCode.noValidProfiles,
            ),
          ),
        );
      }
    });
  });
}
