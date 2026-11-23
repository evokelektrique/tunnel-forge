import 'package:flutter_test/flutter_test.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_failure.dart';

void main() {
  test('error text uses no em or en dashes', () {
    for (final namespace in [
      'mschap',
      'chap',
      'pap',
      'engine',
      'l2tp-stopccn',
      'l2tp-cdn',
      'pptp-ctrl',
      'pptp-call',
      'pptp-cdn',
      'app',
    ]) {
      for (final code in [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
        '10',
        '11',
        '646',
        '647',
        '648',
        '649',
        '691',
        '709',
        'UNKNOWN',
      ]) {
        final failure = TunnelFailure(namespace: namespace, code: code);
        expect(failure.copyText, isNot(matches('[\u2014\u2013]')));
      }
    }
  });
  test('CHAP and PAP rejections are labeled without inventing RAS codes', () {
    expect(
      const TunnelFailure(namespace: 'chap', code: '4').summary,
      'Error CHAP 4: Authentication failed',
    );
    expect(
      const TunnelFailure(namespace: 'pap', code: '3').summary,
      'Error PAP 3: Authentication failed',
    );
  });
  test(
    'MS-CHAP reports authentication rejection, not a proven wrong password',
    () {
      const failure = TunnelFailure(namespace: 'mschap', code: '691');
      expect(failure.summary, 'Error MSCHAP 691: Authentication failed');
      expect(failure.explanation, contains('account permissions'));
      expect(
        const TunnelFailure(namespace: 'mschap', code: '69').label,
        'Unknown authentication error',
      );
    },
  );

  test('StopCCN and CDN results retain their distinct meanings', () {
    const stop = TunnelFailure(namespace: 'l2tp-stopccn', code: '4');
    const cdn = TunnelFailure(namespace: 'l2tp-cdn', code: '4');
    expect(stop.label, 'Control connection not authorized');
    expect(cdn.label, 'Server resources temporarily unavailable');
    expect(
      const TunnelFailure(namespace: 'l2tp-cdn', code: '1').label,
      'Carrier lost',
    );
    expect(
      const TunnelFailure(namespace: 'engine', code: '15').label,
      'Disconnected by server',
    );
  });

  test('general error is interpreted only for general-error result', () {
    const failure = TunnelFailure(
      namespace: 'l2tp-stopccn',
      code: '2',
      generalError: 8,
    );
    expect(failure.summary, contains('General 8'));
    expect(failure.label, contains('Unsupported mandatory attribute'));
    expect(
      const TunnelFailure(
        namespace: 'l2tp-stopccn',
        code: '5',
        generalError: 256,
      ).summary,
      isNot(contains('General')),
    );
  });

  test('unknown codes and malformed payloads remain diagnosable', () {
    final failure = TunnelFailure.fromMap({
      'namespace': 'mschap',
      'code': 999,
    }, detail: 'PPP failed');
    expect(failure.summary, contains('999'));
    expect(failure.copyText, contains('PPP failed'));
    expect(TunnelFailure.fromMap({'code': 'bad'}).code, 'UNKNOWN');
    expect(
      const TunnelFailure(namespace: 'engine', code: '1').explanation,
      contains('doesn\'t necessarily mean the shared secret is wrong'),
    );
  });

  test(
    'android disconnect codes resolve to specific labels and explanations',
    () {
      const revoked = TunnelFailure(namespace: 'android', code: '1');
      const systemStopped = TunnelFailure(namespace: 'android', code: '2');
      const taskRemoved = TunnelFailure(namespace: 'android', code: '3');
      const platformString = TunnelFailure(
        namespace: 'android',
        code: 'vpn_err',
      );

      expect(revoked.label, 'VPN revoked');
      expect(revoked.explanation, contains('another VPN started'));
      expect(systemStopped.label, 'Stopped by Android system');
      expect(taskRemoved.label, 'App removed from recents');
      expect(platformString.label, 'Android platform error');
      expect(platformString.explanation, contains('Check the error details'));
    },
  );

  test('PPTP and root engine failures resolve to specific guidance', () {
    const noRoot = TunnelFailure(namespace: 'engine', code: '6');
    const rootDenied = TunnelFailure(namespace: 'engine', code: '7');
    const greFailed = TunnelFailure(namespace: 'engine', code: '8');
    const mppeFailed = TunnelFailure(namespace: 'engine', code: '9');
    const mppeRequired = TunnelFailure(namespace: 'engine', code: '16');
    const authMismatch = TunnelFailure(namespace: 'engine', code: '17');
    const ctrlRejected = TunnelFailure(namespace: 'pptp-ctrl', code: '4');

    expect(noRoot.label, 'Root access unavailable');
    expect(noRoot.explanation, contains('su binary'));
    expect(rootDenied.label, 'Root permission denied');
    expect(rootDenied.explanation, contains('Magisk'));
    expect(greFailed.label, 'GRE socket setup failed');
    expect(mppeFailed.label, 'MPPE encryption failed');
    expect(mppeRequired.label, 'MPPE required by server');
    expect(mppeRequired.explanation, contains('Off'));
    expect(authMismatch.label, 'PPP authentication rejected');
    expect(ctrlRejected.label, 'PPTP control connection rejected');
  });
}
