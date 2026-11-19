import 'package:equatable/equatable.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

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
    '13': ('Connection lost', 'The underlying network connection was lost.'),
    '14': (
      'Server unreachable',
      'The VPN server stopped responding to keepalive probes.',
    ),
    '15': ('Disconnected by server', 'The VPN server closed the connection.'),
  };
  static const _android = <String, (String, String)>{
    '1': (
      'VPN revoked',
      'Android stopped the VPN because another VPN started, system VPN was turned off, or Always-on VPN revoked access.',
    ),
    '2': (
      'Stopped by Android system',
      'Android terminated the background tunnel service. Allow unrestricted battery usage for TunnelForge if this happens while idle.',
    ),
    '3': (
      'App removed from recents',
      'The tunnel service stopped after the app was dismissed from recent apps.',
    ),
    '4': (
      'VPN permission revoked',
      'VPN permission is no longer granted. Grant VPN permission again to reconnect.',
    ),
    '5': (
      'Local proxy startup failed',
      'The local HTTP/SOCKS proxy listeners could not start after tunnel negotiation.',
    ),
    '6': (
      'Tunnel disconnected unexpectedly',
      'The tunnel closed without a user disconnect request. Export the logs if this keeps happening.',
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
      'android' => _android[code]?.$1 ?? 'Android platform error',
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
    'android' =>
      _android[code]?.$2 ??
          'Check the error details for more information. If it keeps happening, export the logs to help find the cause.',
    _ =>
      'Check the error details for more information. If it keeps happening, export the logs to help find the cause.',
  };

  String get codeLabel =>
      'Error ${namespace.toUpperCase()} $code${_hasGeneralError ? ' / General $generalError' : ''}';

  String get summary => '$codeLabel: $label';

  String get copyText =>
      '$summary\n\n$explanation${detail.isEmpty ? '' : '\n\n$detail'}';

  /// User-facing localized title; [label] and [copyText] remain English for logs.
  String localizedLabel(AppLocalizations t) {
    final base = switch (namespace) {
      'mschap' => switch (code) {
        '646' => t.tunnelFailureMschap646Title,
        '647' => t.tunnelFailureMschap647Title,
        '648' => t.tunnelFailureMschap648Title,
        '649' => t.tunnelFailureMschap649Title,
        '691' => t.tunnelFailureAuthTitle,
        '709' => t.tunnelFailureMschap709Title,
        _ => t.tunnelFailureMschapUnknownTitle,
      },
      'chap' =>
        code == '4'
            ? t.tunnelFailureAuthTitle
            : t.tunnelFailureChapUnknownTitle,
      'pap' =>
        code == '3' ? t.tunnelFailureAuthTitle : t.tunnelFailurePapUnknownTitle,
      'l2tp-stopccn' => switch (code) {
        '1' => t.tunnelFailureStopCcn1Title,
        '2' => t.tunnelFailureStopCcn2Title,
        '3' => t.tunnelFailureStopCcn3Title,
        '4' => t.tunnelFailureStopCcn4Title,
        '5' => t.tunnelFailureStopCcn5Title,
        '6' => t.tunnelFailureStopCcn6Title,
        '7' => t.tunnelFailureStopCcn7Title,
        '8' => t.tunnelFailureStopCcn8Title,
        _ => t.tunnelFailureStopCcnUnknownTitle,
      },
      'l2tp-cdn' => switch (code) {
        '1' => t.tunnelFailureCdn1Title,
        '2' => t.tunnelFailureCdn2Title,
        '3' => t.tunnelFailureCdn3Title,
        '4' => t.tunnelFailureCdn4Title,
        '5' => t.tunnelFailureCdn5Title,
        '6' => t.tunnelFailureCdn6Title,
        '7' => t.tunnelFailureCdn7Title,
        '8' => t.tunnelFailureCdn8Title,
        '9' => t.tunnelFailureCdn9Title,
        '10' => t.tunnelFailureCdn10Title,
        '11' => t.tunnelFailureCdn11Title,
        '12' => t.tunnelFailureCdn12Title,
        _ => t.tunnelFailureCdnUnknownTitle,
      },
      'engine' => switch (code) {
        '1' => t.tunnelFailureEngine1Title,
        '2' => t.tunnelFailureEngine2Title,
        '3' => t.tunnelFailureEngine3Title,
        '4' => t.tunnelFailureEngine4Title,
        '10' => t.tunnelFailureEngine10Title,
        '11' => t.tunnelFailureEngine11Title,
        '13' => t.tunnelFailureEngine13Title,
        '14' => t.tunnelFailureEngine14Title,
        '15' => t.tunnelFailureEngine15Title,
        _ => t.tunnelFailureEngineUnknownTitle,
      },
      'android' => switch (code) {
        '1' => t.tunnelFailureAndroid1Title,
        '2' => t.tunnelFailureAndroid2Title,
        '3' => t.tunnelFailureAndroid3Title,
        '4' => t.tunnelFailureAndroid4Title,
        '5' => t.tunnelFailureAndroid5Title,
        '6' => t.tunnelFailureAndroid6Title,
        _ => t.tunnelFailureAndroidUnknownTitle,
      },
      _ => t.tunnelFailureGenericTitle,
    };
    if (!_hasGeneralError) return base;
    final generalDetail = switch (generalError) {
      1 => t.tunnelFailureGeneral1,
      2 => t.tunnelFailureGeneral2,
      3 => t.tunnelFailureGeneral3,
      4 => t.tunnelFailureGeneral4,
      5 => t.tunnelFailureGeneral5,
      6 => t.tunnelFailureGeneral6,
      7 => t.tunnelFailureGeneral7,
      8 => t.tunnelFailureGeneral8,
      9 => t.tunnelFailureGeneral9,
      10 => t.tunnelFailureGeneral10,
      11 => t.tunnelFailureGeneral11,
      12 => t.tunnelFailureGeneral12,
      _ => t.tunnelFailureGeneralUnknown,
    };
    return t.tunnelFailureWithGeneralError(base, generalDetail);
  }

  /// User-facing localized guidance; [explanation] and [copyText] remain English.
  String localizedExplanation(AppLocalizations t) {
    return switch (namespace) {
      'mschap' => switch (code) {
        '646' => t.tunnelFailureMschap646Explanation,
        '647' => t.tunnelFailureMschap647Explanation,
        '648' => t.tunnelFailureMschap648Explanation,
        '649' => t.tunnelFailureMschap649Explanation,
        '691' => t.tunnelFailureAuthExplanation,
        '709' => t.tunnelFailureMschap709Explanation,
        _ => t.tunnelFailureMschapUnknownExplanation,
      },
      'chap' || 'pap' => t.tunnelFailureAuthExplanation,
      'engine' => switch (code) {
        '1' => t.tunnelFailureEngine1Explanation,
        '2' => t.tunnelFailureEngine2Explanation,
        '3' => t.tunnelFailureEngine3Explanation,
        '4' => t.tunnelFailureEngine4Explanation,
        '10' => t.tunnelFailureEngine10Explanation,
        '11' => t.tunnelFailureEngine11Explanation,
        '13' => t.tunnelFailureEngine13Explanation,
        '14' => t.tunnelFailureEngine14Explanation,
        '15' => t.tunnelFailureEngine15Explanation,
        _ => t.tunnelFailureEngineUnknownExplanation,
      },
      'l2tp-stopccn' || 'l2tp-cdn' => () {
        final retryLater =
            (_hasGeneralError && generalError == 4) ||
            (code == '6' && namespace == 'l2tp-stopccn') ||
            (code == '4' && namespace == 'l2tp-cdn');
        final advice = retryLater
            ? t.tunnelFailureL2tpAdviceRetryLater
            : t.tunnelFailureL2tpAdviceCheckServer;
        return namespace == 'l2tp-stopccn'
            ? t.tunnelFailureL2tpControlExplanation(advice)
            : t.tunnelFailureL2tpSessionExplanation(advice);
      }(),
      'android' => switch (code) {
        '1' => t.tunnelFailureAndroid1Explanation,
        '2' => t.tunnelFailureAndroid2Explanation,
        '3' => t.tunnelFailureAndroid3Explanation,
        '4' => t.tunnelFailureAndroid4Explanation,
        '5' => t.tunnelFailureAndroid5Explanation,
        '6' => t.tunnelFailureAndroid6Explanation,
        _ => t.tunnelFailureGenericExplanation,
      },
      _ => t.tunnelFailureGenericExplanation,
    };
  }

  @override
  List<Object?> get props => [namespace, code, generalError, detail];
}
