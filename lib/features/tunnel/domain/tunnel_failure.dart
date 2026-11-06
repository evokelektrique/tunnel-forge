import 'package:equatable/equatable.dart';

/// Codes remain namespaced: L2TP results are not Windows RAS error codes.
class TunnelFailure extends Equatable {
  const TunnelFailure({
    required this.namespace,
    required this.code,
    this.generalError = 0,
    this.detail = '',
  });

  factory TunnelFailure.fromMap(Object? raw, {String detail = ''}) {
    if (raw is Map && raw['namespace'] is String && raw['code'] is int) {
      return TunnelFailure(
        namespace: raw['namespace'] as String,
        code: raw['code'].toString(),
        generalError: raw['generalError'] is int
            ? raw['generalError'] as int
            : 0,
        detail: detail,
      );
    }
    return TunnelFailure(namespace: 'app', code: 'UNKNOWN', detail: detail);
  }

  final String namespace;
  final String code;
  final int generalError;
  final String detail;

  static const _authentication = (
    'Authentication failed',
    'The server didn\'t accept your login. Check your username and password. If they\'re correct, ask the administrator to check your account permissions.',
  );

  static const _mschap = <String, (String, String)>{
    '646': (
      'Restricted logon hours',
      'Your account can only connect at certain times. Ask the administrator to check your allowed sign-in hours.',
    ),
    '647': (
      'Account disabled',
      'Your account is disabled. Ask the administrator to enable it.',
    ),
    '648': (
      'Password expired',
      'Your password has expired. Change it using the method your VPN provider supports.',
    ),
    '649': (
      'Account not permitted',
      'Your account isn\'t allowed to connect. Ask the administrator to check your remote access permissions.',
    ),
    '691': _authentication,
    '709': (
      'Password change failed',
      'The server couldn\'t change your password. Try changing it through your account provider, or contact the administrator.',
    ),
  };

  // RFC 2661 §4.4.2 / IANA: StopCCN and CDN have separate result tables.
  static const _stop = <String, String>{
    '1': 'Server closed the control connection',
    '2': 'General error',
    '3': 'Control connection already exists',
    '4': 'Control connection not authorized',
    '5': 'Unsupported protocol version',
    '6': 'Server shutting down',
    '7': 'Protocol state error',
    '8': 'Mismatching CCDS value',
  };
  static const _cdn = <String, String>{
    '1': 'Carrier lost',
    '2': 'Session error',
    '3': 'Session administratively disconnected',
    '4': 'Server resources temporarily unavailable',
    '5': 'Required server facilities unavailable',
    '6': 'Invalid destination',
    '7': 'No carrier detected',
    '8': 'Destination busy',
    '9': 'No dial tone',
    '10': 'Session establishment timed out',
    '11': 'No appropriate framing detected',
    '12': 'Mismatching SDS value',
  };
  static const _general = <int, String>{
    1: 'No control connection exists',
    2: 'Invalid message length',
    3: 'Invalid field value',
    4: 'Insufficient server resources',
    5: 'Invalid session ID',
    6: 'Vendor-specific error',
    7: 'Try another server',
    8: 'Unsupported mandatory attribute',
    9: 'Try another directed server',
    10: 'Next hop unreachable',
    11: 'Next hop busy',
    12: 'Tunnel switching aggregator busy',
  };
  static const _engine = <String, (String, String)>{
    '1': (
      'IPsec negotiation failed',
      'Check the server address, shared secret (PSK) and IPsec settings. Make sure the server is reachable on UDP ports 500 and 4500. A timeout doesn\'t necessarily mean the shared secret is wrong.',
    ),
    '2': (
      'L2TP handshake failed',
      'The connection couldn\'t complete L2TP setup after IPsec. Check the server\'s L2TP settings and logs.',
    ),
    '3': (
      'PPP negotiation failed',
      'The connection couldn\'t finish PPP setup. Check the server logs for problems with login methods, account settings or IP address assignment.',
    ),
    '4': (
      'Tunnel I/O error',
      'The tunnel couldn\'t keep sending or receiving data. Check your network connection and try connecting again.',
    ),
    '10': (
      'Invalid tunnel settings',
      'Check the server address and tunnel settings in your profile, then try connecting again.',
    ),
    '11': (
      'Proxy transport unavailable',
      'This version of the app doesn\'t support the requested proxy transport. Use VPN mode or a version that supports it.',
    ),
  };

  bool get _hasGeneralError =>
      (namespace == 'l2tp-stopccn' || namespace == 'l2tp-cdn') &&
      code == '2' &&
      generalError != 0;

  String get label {
    final base = switch (namespace) {
      'mschap' => _mschap[code]?.$1 ?? 'Unknown authentication error',
      'chap' => code == '4' ? _authentication.$1 : 'Unknown CHAP error',
      'pap' => code == '3' ? _authentication.$1 : 'Unknown PAP error',
      'l2tp-stopccn' => _stop[code] ?? 'Unknown control connection result',
      'l2tp-cdn' => _cdn[code] ?? 'Unknown session result',
      'engine' => _engine[code]?.$1 ?? 'Unknown tunnel engine error',
      'android' => 'Android platform error',
      _ => 'Connection error',
    };
    return _hasGeneralError
        ? '$base: ${_general[generalError] ?? 'Unknown general error'}'
        : base;
  }

  String get explanation => switch (namespace) {
    'mschap' =>
      _mschap[code]?.$2 ??
          'The server returned an authentication error the app doesn\'t recognize. Check the server logs or contact the administrator.',
    'chap' || 'pap' => _authentication.$2,
    'engine' =>
      _engine[code]?.$2 ??
          'The tunnel stopped with an error the app doesn\'t recognize. Export the logs to help find the cause.',
    'l2tp-stopccn' || 'l2tp-cdn' =>
      'The L2TP server closed the ${namespace == 'l2tp-stopccn' ? 'control connection' : 'session'}. ${_hasGeneralError && generalError == 4 || code == '6' && namespace == 'l2tp-stopccn' || code == '4' && namespace == 'l2tp-cdn' ? 'Wait a moment, then try again.' : 'Check the server logs, access rules and supported protocol settings.'}',
    _ =>
      'Check the error details for more information. If it keeps happening, export the logs to help find the cause.',
  };

  String get codeLabel =>
      'Error ${namespace.toUpperCase()} $code${_hasGeneralError ? ' / General $generalError' : ''}';

  String get summary => '$codeLabel: $label';

  String get copyText =>
      '$summary\n\n$explanation${detail.isEmpty ? '' : '\n\n$detail'}';

  @override
  List<Object?> get props => [namespace, code, generalError, detail];
}
