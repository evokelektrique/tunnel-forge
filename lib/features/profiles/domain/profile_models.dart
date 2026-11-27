import 'dart:convert';

import 'package:tunnel_forge/l10n/app_localizations.dart';
import 'package:tunnel_forge/l10n/generated/app_localizations_en.dart';

/// VPN tunneling protocol selected per saved profile.
enum TunnelProtocol {
  l2tp('l2tp', 'L2TP'),
  pptp('pptp', 'PPTP');

  const TunnelProtocol(this.jsonValue, this.shortLabel);

  final String jsonValue;
  final String shortLabel;

  bool get isPptp => this == TunnelProtocol.pptp;

  static const List<TunnelProtocol> orderedValues = <TunnelProtocol>[
    TunnelProtocol.l2tp,
    TunnelProtocol.pptp,
  ];

  String localizedDropdownLabel(AppLocalizations t) {
    return switch (this) {
      TunnelProtocol.l2tp => t.protocolL2tp,
      TunnelProtocol.pptp => t.protocolPptpRoot,
    };
  }

  static TunnelProtocol fromJson(Object? raw) {
    return tryParseWire(raw) ?? TunnelProtocol.l2tp;
  }

  static TunnelProtocol? tryParseWire(Object? raw) {
    if (raw is! String) return null;
    return switch (raw.trim().toLowerCase()) {
      'l2tp' => TunnelProtocol.l2tp,
      'pptp' => TunnelProtocol.pptp,
      _ => null,
    };
  }
}

/// PPP authentication policy selected per saved profile.
enum PppAuthMethod {
  auto('auto', 'Auto'),
  mschapV2('mschapv2', 'MS-CHAPv2'),
  chapMd5('chap-md5', 'CHAP-MD5'),
  pap('pap', 'PAP');

  const PppAuthMethod(this.jsonValue, this.shortLabel);

  final String jsonValue;
  final String shortLabel;

  static const List<PppAuthMethod> orderedValues = <PppAuthMethod>[
    PppAuthMethod.auto,
    PppAuthMethod.mschapV2,
    PppAuthMethod.chapMd5,
    PppAuthMethod.pap,
  ];

  String localizedDropdownLabel(AppLocalizations t) {
    return switch (this) {
      PppAuthMethod.auto => t.pppAuthAuto,
      PppAuthMethod.mschapV2 => t.pppAuthMschapV2,
      PppAuthMethod.chapMd5 => t.pppAuthChapMd5,
      PppAuthMethod.pap => t.pppAuthPap,
    };
  }

  String localizedHelperText(AppLocalizations t) {
    return switch (this) {
      PppAuthMethod.auto => t.pppAuthAutoHelp,
      PppAuthMethod.mschapV2 => t.pppAuthMschapV2Help,
      PppAuthMethod.chapMd5 => t.pppAuthChapMd5Help,
      PppAuthMethod.pap => t.pppAuthPapHelp,
    };
  }

  static PppAuthMethod fromJson(Object? raw) {
    return tryParseWire(raw) ?? PppAuthMethod.auto;
  }

  static PppAuthMethod? tryParseWire(Object? raw) {
    if (raw is! String) return null;
    return switch (raw.trim().toLowerCase()) {
      'auto' => PppAuthMethod.auto,
      'mschapv2' || 'mschap-v2' || 'ms-chapv2' => PppAuthMethod.mschapV2,
      'chap-md5' || 'chap_md5' || 'chapmd5' => PppAuthMethod.chapMd5,
      'pap' => PppAuthMethod.pap,
      _ => null,
    };
  }
}

/// PPTP MPPE encryption policy selected per saved profile.
enum MppeMode {
  auto('auto', 'Auto'),
  on('on', 'On'),
  off('off', 'Off');

  const MppeMode(this.jsonValue, this.shortLabel);

  final String jsonValue;
  final String shortLabel;

  static const List<MppeMode> orderedValues = <MppeMode>[
    MppeMode.auto,
    MppeMode.on,
    MppeMode.off,
  ];

  String localizedDropdownLabel(AppLocalizations t) {
    return switch (this) {
      MppeMode.auto => t.mppeAuto,
      MppeMode.on => t.mppeOn,
      MppeMode.off => t.mppeOff,
    };
  }

  String localizedHelperText(AppLocalizations t) {
    return switch (this) {
      MppeMode.auto => t.mppeAutoHelp,
      MppeMode.on => t.mppeOnHelp,
      MppeMode.off => t.mppeOffHelp,
    };
  }

  static MppeMode fromJson(Object? raw) {
    return tryParseWire(raw) ?? MppeMode.auto;
  }

  static MppeMode? tryParseWire(Object? raw) {
    if (raw is! String) return null;
    return switch (raw.trim().toLowerCase()) {
      'auto' => MppeMode.auto,
      'on' => MppeMode.on,
      'off' => MppeMode.off,
      _ => null,
    };
  }
}

/// Connection surface: Android VPN/TUN vs. local proxy listeners only.
enum ConnectionMode {
  vpnTunnel('vpnTunnel'),
  proxyOnly('proxyOnly');

  const ConnectionMode(this.jsonValue);
  final String jsonValue;

  static ConnectionMode fromJson(Object? raw) {
    if (raw is! String) return ConnectionMode.vpnTunnel;
    return switch (raw) {
      'proxyOnly' => ConnectionMode.proxyOnly,
      _ => ConnectionMode.vpnTunnel,
    };
  }
}

/// Split-tunneling behavior when it is enabled.
enum SplitTunnelMode {
  inclusive('inclusive'),
  exclusive('exclusive');

  const SplitTunnelMode(this.jsonValue);
  final String jsonValue;

  static SplitTunnelMode fromJson(Object? raw) {
    if (raw is! String) return SplitTunnelMode.inclusive;
    return switch (raw) {
      'exclusive' => SplitTunnelMode.exclusive,
      _ => SplitTunnelMode.inclusive,
    };
  }
}

/// Global split-tunneling settings shared across profiles.
class SplitTunnelSettings {
  const SplitTunnelSettings({
    this.enabled = false,
    this.mode = SplitTunnelMode.inclusive,
    this.inclusivePackages = const <String>[],
    this.exclusivePackages = const <String>[],
  });

  final bool enabled;
  final SplitTunnelMode mode;
  final List<String> inclusivePackages;
  final List<String> exclusivePackages;

  List<String> get activePackages =>
      mode == SplitTunnelMode.inclusive ? inclusivePackages : exclusivePackages;

  SplitTunnelSettings copyWith({
    bool? enabled,
    SplitTunnelMode? mode,
    List<String>? inclusivePackages,
    List<String>? exclusivePackages,
  }) {
    return SplitTunnelSettings(
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      inclusivePackages: normalizePackages(
        inclusivePackages ?? this.inclusivePackages,
      ),
      exclusivePackages: normalizePackages(
        exclusivePackages ?? this.exclusivePackages,
      ),
    );
  }

  static List<String> normalizePackages(Iterable<String> packages) {
    final next =
        packages
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    return List<String>.unmodifiable(next);
  }

  @override
  bool operator ==(Object other) {
    return other is SplitTunnelSettings &&
        enabled == other.enabled &&
        mode == other.mode &&
        _sameStringList(inclusivePackages, other.inclusivePackages) &&
        _sameStringList(exclusivePackages, other.exclusivePackages);
  }

  @override
  int get hashCode => Object.hash(
    enabled,
    mode,
    Object.hashAll(inclusivePackages),
    Object.hashAll(exclusivePackages),
  );

  static bool _sameStringList(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Ordered by UI display and by the contract sent to Android.
enum DnsProtocol {
  dnsOverTcp('dnsOverTcp', 'TCP', 'DNS-over-TCP'),
  dnsOverUdp('dnsOverUdp', 'UDP', 'DNS-over-UDP'),
  dnsOverTls('dnsOverTls', 'TLS', 'DNS-over-TLS'),
  dnsOverHttps('dnsOverHttps', 'HTTPS', 'DNS-over-HTTPS');

  const DnsProtocol(this.jsonValue, this.shortLabel, this.displayLabel);

  final String jsonValue;
  final String shortLabel;
  final String displayLabel;

  bool get requiresHostname =>
      this == DnsProtocol.dnsOverTls || this == DnsProtocol.dnsOverHttps;

  static const List<DnsProtocol> orderedValues = <DnsProtocol>[
    DnsProtocol.dnsOverTcp,
    DnsProtocol.dnsOverUdp,
    DnsProtocol.dnsOverTls,
    DnsProtocol.dnsOverHttps,
  ];

  static DnsProtocol fromJson(Object? raw) {
    if (raw is! String) return DnsProtocol.dnsOverUdp;
    return switch (raw) {
      'dnsOverTcp' => DnsProtocol.dnsOverTcp,
      'dnsOverTls' => DnsProtocol.dnsOverTls,
      'dnsOverHttps' => DnsProtocol.dnsOverHttps,
      _ => DnsProtocol.dnsOverUdp,
    };
  }
}

class DnsServerConfig {
  const DnsServerConfig({required this.host, required this.protocol});

  final String host;
  final DnsProtocol protocol;

  DnsServerConfig copyWith({String? host, DnsProtocol? protocol}) {
    return DnsServerConfig(
      host: host ?? this.host,
      protocol: protocol ?? this.protocol,
    );
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'protocol': protocol.jsonValue,
  };

  @override
  bool operator ==(Object other) =>
      other is DnsServerConfig &&
      host == other.host &&
      protocol == other.protocol;

  @override
  int get hashCode => Object.hash(host, protocol);
}

/// Global local-proxy settings shared across VPN and local-proxy modes.
class ProxySettings {
  const ProxySettings({
    this.httpPort = defaultHttpPort,
    this.socksPort = defaultSocksPort,
    this.allowLanConnections = false,
    this.authEnabled = false,
    this.authUsername = '',
    this.authPassword = '',
  });

  static const int defaultHttpPort = 8080;
  static const int defaultSocksPort = 1080;
  static const int minPort = 1024;
  static const int maxPort = 65535;
  static const Map<int, String> reservedPorts = <int, String>{
    1701: 'L2TP',
    1723: 'PPTP',
    4500: 'IPsec NAT-T',
    5037: 'ADB',
    5353: 'mDNS',
    5554: 'Android Emulator',
    5555: 'ADB over TCP',
  };

  final int httpPort;
  final int socksPort;
  final bool allowLanConnections;
  final bool authEnabled;
  final String authUsername;
  final String authPassword;

  bool get hasCompleteAuthCredentials =>
      authUsername.trim().isNotEmpty && authPassword.isNotEmpty;

  bool get requiresAuthCredentials =>
      authEnabled && !hasCompleteAuthCredentials;

  static bool isAllowedPort(int port) {
    return port >= minPort &&
        port <= maxPort &&
        !reservedPorts.containsKey(port);
  }

  static int normalizePort(int value, {required int fallback}) {
    if (!isAllowedPort(value)) return fallback;
    return value;
  }

  static int? parseValidPort(String text) {
    final parsed = int.tryParse(text.trim());
    if (parsed == null || !isAllowedPort(parsed)) return null;
    return parsed;
  }

  static String? validatePortText(String text, {AppLocalizations? l10n}) {
    final t = l10n ?? AppL10n.current;
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return t.proxyPortInvalidFormat;
    }
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 1 || parsed > maxPort) {
      return t.proxyPortInvalidFormat;
    }
    if (parsed < minPort) {
      return t.proxyPortPrivileged;
    }
    final reservedService = reservedPorts[parsed];
    if (reservedService != null) {
      return t.proxyPortReserved(parsed, reservedService);
    }
    return null;
  }

  static int portFromText(String text, {required int fallback}) {
    final parsed = parseValidPort(text);
    return parsed ?? fallback;
  }

  ProxySettings copyWith({
    int? httpPort,
    int? socksPort,
    bool? allowLanConnections,
    bool? authEnabled,
    String? authUsername,
    String? authPassword,
  }) {
    return ProxySettings(
      httpPort: httpPort ?? this.httpPort,
      socksPort: socksPort ?? this.socksPort,
      allowLanConnections: allowLanConnections ?? this.allowLanConnections,
      authEnabled: authEnabled ?? this.authEnabled,
      authUsername: authUsername ?? this.authUsername,
      authPassword: authPassword ?? this.authPassword,
    );
  }
}

/// Runtime proxy listener exposure reported by Android after the listeners start.
class ProxyExposure {
  const ProxyExposure({
    required this.active,
    required this.bindAddress,
    required this.displayAddress,
    required this.httpPort,
    required this.socksPort,
    required this.lanRequested,
    required this.lanActive,
    this.warning,
  });

  static const String loopbackAddress = '127.0.0.1';

  final bool active;
  final String bindAddress;
  final String displayAddress;
  final int httpPort;
  final int socksPort;
  final bool lanRequested;
  final bool lanActive;
  final String? warning;

  List<String> get displayAddresses {
    if (lanActive && displayAddress != loopbackAddress) {
      return [loopbackAddress, displayAddress];
    }
    return [displayAddress];
  }

  bool get hasWarning => warning != null && warning!.trim().isNotEmpty;

  static ProxyExposure? tryFromMap(
    Object? raw, {
    required String activeKey,
    required String bindAddressKey,
    required String displayAddressKey,
    required String httpPortKey,
    required String socksPortKey,
    required String lanRequestedKey,
    required String lanActiveKey,
    required String warningKey,
  }) {
    if (raw is! Map) return null;
    final bindAddress = raw[bindAddressKey]?.toString() ?? '';
    final displayAddress = raw[displayAddressKey]?.toString() ?? '';
    final httpPort = _parsePort(raw[httpPortKey]);
    final socksPort = _parsePort(raw[socksPortKey]);
    if (bindAddress.isEmpty ||
        displayAddress.isEmpty ||
        httpPort == null ||
        socksPort == null) {
      return null;
    }
    return ProxyExposure(
      active: _parseBool(raw[activeKey]),
      bindAddress: bindAddress,
      displayAddress: displayAddress,
      httpPort: httpPort,
      socksPort: socksPort,
      lanRequested: _parseBool(raw[lanRequestedKey]),
      lanActive: _parseBool(raw[lanActiveKey]),
      warning: raw[warningKey]?.toString(),
    );
  }

  static int? _parsePort(Object? raw) {
    return switch (raw) {
      int value => value,
      _ => int.tryParse(raw?.toString() ?? ''),
    };
  }

  static bool _parseBool(Object? raw) {
    return switch (raw) {
      bool value => value,
      String value => value.toLowerCase() == 'true',
      _ => false,
    };
  }

  @override
  bool operator ==(Object other) {
    return other is ProxyExposure &&
        active == other.active &&
        bindAddress == other.bindAddress &&
        displayAddress == other.displayAddress &&
        httpPort == other.httpPort &&
        socksPort == other.socksPort &&
        lanRequested == other.lanRequested &&
        lanActive == other.lanActive &&
        warning == other.warning;
  }

  @override
  int get hashCode => Object.hash(
    active,
    bindAddress,
    displayAddress,
    httpPort,
    socksPort,
    lanRequested,
    lanActive,
    warning,
  );
}

/// Global endpoint used by the connectivity badge for direct reachability checks.
class ConnectivityCheckSettings {
  const ConnectivityCheckSettings({
    this.url = defaultUrl,
    this.timeoutMs = defaultTimeoutMs,
  });

  static const String defaultUrl = 'https://www.gstatic.com/generate_204';
  static const int defaultTimeoutMs = 5000;

  final String url;
  final int timeoutMs;

  static String normalizeUrl(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? defaultUrl : trimmed;
  }

  static int normalizeTimeoutMs(int value) {
    return value > 0 ? value : defaultTimeoutMs;
  }

  static int? parseTimeoutMs(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return defaultTimeoutMs;
    final value = int.tryParse(trimmed);
    if (value == null || value <= 0) return null;
    return value;
  }

  static String? validateUrl(String text, {AppLocalizations? l10n}) {
    final t = l10n ?? AppL10n.current;
    final normalized = normalizeUrl(text);
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return t.connectivityUrlInvalid;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return t.connectivityUrlUnsupportedScheme;
    }
    return null;
  }

  static String? validateTimeoutMs(String text, {AppLocalizations? l10n}) {
    final t = l10n ?? AppL10n.current;
    if (text.trim().isEmpty) return null;
    final value = int.tryParse(text.trim());
    if (value == null) {
      return t.connectivityTimeoutWholeNumber;
    }
    if (value <= 0) {
      return t.connectivityTimeoutPositive;
    }
    return null;
  }

  ConnectivityCheckSettings copyWith({String? url, int? timeoutMs}) {
    return ConnectivityCheckSettings(
      url: normalizeUrl(url ?? this.url),
      timeoutMs: normalizeTimeoutMs(timeoutMs ?? this.timeoutMs),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is ConnectivityCheckSettings &&
        url == other.url &&
        timeoutMs == other.timeoutMs;
  }

  @override
  int get hashCode => Object.hash(url, timeoutMs);
}

/// One launchable app row from [VpnClient.listVpnCandidateApps].
class CandidateApp {
  const CandidateApp({required this.packageName, required this.label});

  final String packageName;
  final String label;

  static CandidateApp? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final pkg = m['packageName'];
    final label = m['label'];
    if (pkg is! String || label is! String) return null;
    if (pkg.isEmpty) return null;
    return CandidateApp(packageName: pkg, label: label);
  }
}

/// Saved VPN identity: public fields only; password and PSK live in [ProfileStore] secrets.
class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    required this.server,
    required this.user,
    this.protocol = TunnelProtocol.l2tp,
    this.pppAuth = PppAuthMethod.auto,
    this.mppeMode = MppeMode.auto,
    this.dnsAutomatic = true,
    this.dns1Host = '',
    this.dns1Protocol = DnsProtocol.dnsOverUdp,
    this.dns2Host = '',
    this.dns2Protocol = DnsProtocol.dnsOverUdp,
    this.mtu,
    this.favorite = false,
    this.subscriptionId,
  });

  /// Maximum number of profiles a user can mark as favorites.
  static const int maxFavorites = 5;

  /// Default MTU ceiling (bytes) used by native PPP LCP negotiation when profile MTU is unset.
  static const int defaultVpnMtu = 1450;

  static const int minVpnMtu = 576;
  static const int maxVpnMtu = 1450;

  /// RFC 1334 (PAP) Peer-ID / Passwd length octets max out at 255 bytes.
  static const int maxPppUsernameUtf8Bytes = 255;
  static const int maxPppPapPasswordUtf8Bytes = 255;

  /// RFC 2759 section 8.1 bounds MS-CHAPv2 passwords to 256 UTF-16LE chars.
  static const int maxPppMschapV2PasswordUtf16CodeUnits = 256;

  static int utf8ByteLength(String value) => utf8.encode(value).length;

  final String id;
  final String displayName;
  final String server;
  final String user;
  final TunnelProtocol protocol;
  final PppAuthMethod pppAuth;
  final MppeMode mppeMode;
  final bool dnsAutomatic;
  final String dns1Host;
  final DnsProtocol dns1Protocol;
  final String dns2Host;
  final DnsProtocol dns2Protocol;

  /// Optional Android VpnService [Builder.setMtu]; null negotiates MTU via PPP LCP, else clamped [minVpnMtu]–[maxVpnMtu].
  final int? mtu;
  final bool favorite;

  /// Null for local profiles; otherwise the owning [Subscription.id].
  final String? subscriptionId;

  static bool isIncompatiblePppAuthAndMppe(
    TunnelProtocol protocol,
    PppAuthMethod pppAuth,
    MppeMode mppeMode,
  ) {
    return protocol.isPptp &&
        mppeMode == MppeMode.on &&
        (pppAuth == PppAuthMethod.pap || pppAuth == PppAuthMethod.chapMd5);
  }

  Profile copyWith({
    bool? favorite,
    TunnelProtocol? protocol,
    PppAuthMethod? pppAuth,
    MppeMode? mppeMode,
    String? subscriptionId,
    bool clearSubscriptionId = false,
  }) {
    final nextProtocol = protocol ?? this.protocol;
    return Profile(
      id: id,
      displayName: displayName,
      server: server,
      user: user,
      protocol: nextProtocol,
      pppAuth: pppAuth ?? this.pppAuth,
      mppeMode: nextProtocol.isPptp
          ? (mppeMode ?? this.mppeMode)
          : MppeMode.auto,
      dnsAutomatic: dnsAutomatic,
      dns1Host: dns1Host,
      dns1Protocol: dns1Protocol,
      dns2Host: dns2Host,
      dns2Protocol: dns2Protocol,
      mtu: mtu,
      favorite: favorite ?? this.favorite,
      subscriptionId: clearSubscriptionId
          ? null
          : (subscriptionId ?? this.subscriptionId),
    );
  }

  List<DnsServerConfig> get manualDnsServers => orderedDnsServers(
    dns1Host: dns1Host,
    dns1Protocol: dns1Protocol,
    dns2Host: dns2Host,
    dns2Protocol: dns2Protocol,
  );
  String? get invalidDns1 => invalidDnsServer(dns1Host, dns1Protocol);
  String? get invalidDns2 => invalidDnsServer(dns2Host, dns2Protocol);

  static int normalizeMtu(int value) => value.clamp(minVpnMtu, maxVpnMtu);

  static int? normalizeOptionalMtu(int? value) =>
      value == null ? null : normalizeMtu(value);

  /// Parses editor / free-form input; invalid or empty [text] returns `null`.
  static int? mtuFromText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final v = int.tryParse(trimmed);
    if (v == null) return null;
    return normalizeMtu(v);
  }

  static bool isValidIpv4DnsServer(String value) {
    final parts = value.trim().split('.');
    if (parts.length != 4) return false;
    for (final part in parts) {
      if (part.isEmpty || !RegExp(r'^\d+$').hasMatch(part)) return false;
      final octet = int.tryParse(part);
      if (octet == null || octet < 0 || octet > 255) return false;
    }
    return true;
  }

  static String normalizeDnsServer(String text) => text.trim();

  static const String _dohPath = '/dns-query';

  static bool isValidDnsHostname(String value) {
    final token = value.trim();
    if (token.isEmpty || token.length > 253) return false;
    if (token.contains('://') ||
        token.contains('/') ||
        token.contains('?') ||
        token.contains('#') ||
        token.contains(':') ||
        token.startsWith('.') ||
        token.endsWith('.')) {
      return false;
    }
    final labels = token.split('.');
    if (labels.any((label) => label.isEmpty || label.length > 63)) {
      return false;
    }
    final labelPattern = RegExp(
      r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
    );
    return labels.every(labelPattern.hasMatch);
  }

  static String? _normalizedDoHEndpoint(String text) {
    final token = normalizeDnsServer(text);
    if (token.isEmpty) return null;
    final hasScheme = token.contains('://');
    final uri = Uri.tryParse(hasScheme ? token : 'https://$token');
    if (uri == null ||
        uri.host.isEmpty ||
        uri.fragment.isNotEmpty ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    if (uri.scheme.toLowerCase() != 'https') return null;
    final host = uri.host;
    if (isValidIpv4DnsServer(host) || !isValidDnsHostname(host)) {
      return null;
    }
    final hasExplicitTarget =
        hasScheme ||
        token.contains('/') ||
        token.contains('?') ||
        token.contains(':');
    final authority = uri.hasPort ? '$host:${uri.port}' : host;
    final path = uri.path.isEmpty
        ? (hasExplicitTarget ? '/' : _dohPath)
        : uri.path;
    final query = uri.hasQuery ? '?${uri.query}' : '';
    if (hasScheme) return 'https://$authority$path$query';
    if (hasExplicitTarget) return '$authority$path$query';
    return host;
  }

  static String normalizeDnsServerForProtocol(
    String text,
    DnsProtocol protocol,
  ) {
    final token = normalizeDnsServer(text);
    if (token.isEmpty) return '';
    if (protocol == DnsProtocol.dnsOverHttps) {
      return _normalizedDoHEndpoint(token) ?? token;
    }
    return token;
  }

  static String? invalidDnsServer(String text, DnsProtocol protocol) {
    final token = normalizeDnsServer(text);
    if (token.isEmpty) return null;
    if (protocol == DnsProtocol.dnsOverHttps) {
      return _normalizedDoHEndpoint(token) == null ? token : null;
    }
    if (protocol.requiresHostname) {
      return !isValidIpv4DnsServer(token) && isValidDnsHostname(token)
          ? null
          : token;
    }
    return isValidIpv4DnsServer(token) || isValidDnsHostname(token)
        ? null
        : token;
  }

  static String validationMessageForDnsServer(
    String label,
    String text,
    DnsProtocol protocol, {
    AppLocalizations? l10n,
  }) {
    if (invalidDnsServer(text, protocol) == null) return '';
    final t = l10n ?? AppL10n.current;
    final requirement = switch (protocol) {
      DnsProtocol.dnsOverTcp ||
      DnsProtocol.dnsOverUdp => t.dnsRequirementHostnameOrIpv4,
      DnsProtocol.dnsOverTls => t.dnsRequirementHostname,
      DnsProtocol.dnsOverHttps => t.dnsRequirementHostnameOrHttpsUrl,
    };
    return t.dnsValidationError(label, requirement);
  }

  static String englishValidationMessageForDnsServer(
    String label,
    String text,
    DnsProtocol protocol,
  ) => validationMessageForDnsServer(
    label,
    text,
    protocol,
    l10n: AppLocalizationsEn(),
  );

  static List<DnsServerConfig> orderedDnsServers({
    required String dns1Host,
    required DnsProtocol dns1Protocol,
    required String dns2Host,
    required DnsProtocol dns2Protocol,
  }) {
    final out = <String>[];
    final configs = <DnsServerConfig>[];
    // Preserve slot priority while dropping empty and duplicate entries.
    for (final entry in <DnsServerConfig>[
      DnsServerConfig(
        host: normalizeDnsServerForProtocol(dns1Host, dns1Protocol),
        protocol: dns1Protocol,
      ),
      DnsServerConfig(
        host: normalizeDnsServerForProtocol(dns2Host, dns2Protocol),
        protocol: dns2Protocol,
      ),
    ]) {
      if (entry.host.isEmpty) continue;
      final fingerprint = '${entry.protocol.jsonValue}:${entry.host}';
      if (out.contains(fingerprint)) continue;
      out.add(fingerprint);
      configs.add(entry);
    }
    return configs;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'server': server,
    'user': user,
    'protocol': protocol.jsonValue,
    'pppAuth': pppAuth.jsonValue,
    if (protocol.isPptp) 'mppe': mppeMode.jsonValue,
    'dnsAutomatic': dnsAutomatic,
    'dns1Host': normalizeDnsServerForProtocol(dns1Host, dns1Protocol),
    'dns1Protocol': dns1Protocol.jsonValue,
    'dns2Host': normalizeDnsServerForProtocol(dns2Host, dns2Protocol),
    'dns2Protocol': dns2Protocol.jsonValue,
    if (mtu != null) 'mtu': normalizeMtu(mtu!),
    'favorite': favorite,
    if (subscriptionId != null && subscriptionId!.isNotEmpty)
      'subscriptionId': subscriptionId,
  };

  static Profile? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    final id = m['id'];
    final displayName = m['displayName'];
    final server = m['server'];
    final user = m['user'];
    final dnsAutomatic = m['dnsAutomatic'];
    final dns1Host = m['dns1Host'];
    final dns1Protocol = m['dns1Protocol'];
    final dns2Host = m['dns2Host'];
    final dns2Protocol = m['dns2Protocol'];
    if (id is! String ||
        displayName is! String ||
        server is! String ||
        user is! String ||
        dnsAutomatic is! bool ||
        dns1Host is! String ||
        dns2Host is! String ||
        dns1Protocol is! String ||
        dns2Protocol is! String) {
      return null;
    }
    if (id.isEmpty || server.isEmpty) return null;
    int? mtu;
    final mtuRaw = m['mtu'];
    final parsedDns1Protocol = DnsProtocol.fromJson(dns1Protocol);
    final parsedDns2Protocol = DnsProtocol.fromJson(dns2Protocol);
    if (mtuRaw is int) {
      mtu = normalizeMtu(mtuRaw);
    } else if (mtuRaw is num) {
      mtu = normalizeMtu(mtuRaw.toInt());
    } else if (mtuRaw is String) {
      mtu = mtuFromText(mtuRaw);
    }
    final favorite = m['favorite'] is bool ? m['favorite'] as bool : false;
    final protocol = TunnelProtocol.fromJson(m['protocol']);
    final pppAuth = PppAuthMethod.fromJson(m['pppAuth']);
    final mppeMode = protocol.isPptp
        ? MppeMode.fromJson(m['mppe'])
        : MppeMode.auto;
    final rawSubId = m['subscriptionId'];
    final subscriptionId = rawSubId is String && rawSubId.trim().isNotEmpty
        ? rawSubId.trim()
        : null;
    return Profile(
      id: id,
      displayName: displayName,
      server: server,
      user: user,
      protocol: protocol,
      pppAuth: pppAuth,
      mppeMode: mppeMode,
      dnsAutomatic: dnsAutomatic,
      dns1Host: normalizeDnsServerForProtocol(dns1Host, parsedDns1Protocol),
      dns1Protocol: parsedDns1Protocol,
      dns2Host: normalizeDnsServerForProtocol(dns2Host, parsedDns2Protocol),
      dns2Protocol: parsedDns2Protocol,
      mtu: mtu,
      favorite: favorite,
      subscriptionId: subscriptionId,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is Profile &&
        id == other.id &&
        displayName == other.displayName &&
        server == other.server &&
        user == other.user &&
        protocol == other.protocol &&
        pppAuth == other.pppAuth &&
        mppeMode == other.mppeMode &&
        dnsAutomatic == other.dnsAutomatic &&
        dns1Host == other.dns1Host &&
        dns1Protocol == other.dns1Protocol &&
        dns2Host == other.dns2Host &&
        dns2Protocol == other.dns2Protocol &&
        mtu == other.mtu &&
        favorite == other.favorite &&
        subscriptionId == other.subscriptionId;
  }

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    server,
    user,
    protocol,
    pppAuth,
    mppeMode,
    dnsAutomatic,
    dns1Host,
    dns1Protocol,
    dns2Host,
    dns2Protocol,
    mtu,
    favorite,
    subscriptionId,
  );
}
