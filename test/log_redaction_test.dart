import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/home/domain/log_redaction.dart';

void main() {
  test('leaves plain diagnostic messages and local IPv4 visible', () {
    expect(redactLogMessage('vpn ready clientIpv4=10.0.0.2'), 'vpn ready clientIpv4=10.0.0.2');
    expect(redactLogMessage('timestamp 2026-01-02T03:04:05.123Z'), 'timestamp 2026-01-02T03:04:05.123Z');
  });

  test('redacts underscore compound secret keys, comma secrets, and IPv6 addresses', () {
    final redacted = redactLogMessage(
      'api_key=sec123,456 access_token=tok_a,tok_b host=2001:db8::1 peer=[2001:db8::2]:443 mapped=::ffff:192.0.2.1',
    );
    expect(redacted, isNot(contains('sec123')));
    expect(redacted, isNot(contains(',456')));
    expect(redacted, isNot(contains('tok_a')));
    expect(redacted, isNot(contains('tok_b')));
    expect(redacted, isNot(contains('2001:db8::1')));
    expect(redacted, isNot(contains('2001:db8::2')));
    expect(redacted, isNot(contains('192.0.2.1')));
    expect(redacted, contains('api_key=[REDACTED]'));
    expect(redacted, contains('access_token=[REDACTED]'));
    expect(redacted, contains('host=[REDACTED_HOST]'));
    expect(redacted, isNot(contains('[REDACTED_HOST]:1')));
    expect(redacted, contains('peer=[REDACTED_HOST]:443'));
  });
}
