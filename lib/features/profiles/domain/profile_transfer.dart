import 'dart:convert';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

enum ProfileTransferErrorCode {
  multipleProfiles,
  emptyTransfer,
  unsupportedTransfer,
  notJsonObject,
  unsupportedVersion,
  unsupportedProtocol,
  bundleEmpty,
  entryNotJsonObject,
  invalidShareLink,
  tooManyDnsServers,
  serverRequired,
  invalidDns,
  manualDnsRequired,
  invalidIntField,
  missingField,
}

class ProfileTransferFormatException extends FormatException {
  const ProfileTransferFormatException(
    super.message, {
    required this.code,
    this.field,
    this.version,
    this.protocol,
    this.dnsHost,
    this.dnsProtocol,
  });

  final ProfileTransferErrorCode code;
  final String? field;
  final String? version;
  final String? protocol;
  final String? dnsHost;
  final DnsProtocol? dnsProtocol;

  String localizedMessage(AppLocalizations t) {
    return switch (code) {
      ProfileTransferErrorCode.multipleProfiles =>
        t.profileTransferMultipleProfiles,
      ProfileTransferErrorCode.emptyTransfer => t.profileTransferEmpty,
      ProfileTransferErrorCode.unsupportedTransfer =>
        t.profileTransferUnsupported,
      ProfileTransferErrorCode.notJsonObject => t.profileTransferNotJsonObject,
      ProfileTransferErrorCode.unsupportedVersion =>
        t.profileTransferUnsupportedVersion(version ?? ''),
      ProfileTransferErrorCode.unsupportedProtocol =>
        t.profileTransferUnsupportedProtocol(protocol ?? ''),
      ProfileTransferErrorCode.bundleEmpty => t.profileTransferBundleEmpty,
      ProfileTransferErrorCode.entryNotJsonObject =>
        t.profileTransferEntryNotJsonObject,
      ProfileTransferErrorCode.invalidShareLink =>
        t.profileTransferInvalidShareLink,
      ProfileTransferErrorCode.tooManyDnsServers =>
        t.profileTransferTooManyDnsServers,
      ProfileTransferErrorCode.serverRequired =>
        t.profileTransferServerRequired,
      ProfileTransferErrorCode.invalidDns =>
        Profile.validationMessageForDnsServer(
          field ?? 'DNS',
          dnsHost ?? '',
          dnsProtocol ?? DnsProtocol.dnsOverUdp,
          l10n: t,
        ),
      ProfileTransferErrorCode.manualDnsRequired =>
        t.profileTransferManualDnsRequired,
      ProfileTransferErrorCode.invalidIntField =>
        t.profileTransferInvalidIntField(field ?? ''),
      ProfileTransferErrorCode.missingField => t.profileTransferMissingField(
        field ?? '',
      ),
    };
  }
}

class ProfileTransferEnvelope {
  const ProfileTransferEnvelope({
    required this.displayName,
    required this.server,
    required this.user,
    required this.password,
    required this.psk,
    required this.dnsAutomatic,
    required this.dns1Host,
    required this.dns1Protocol,
    required this.dns2Host,
    required this.dns2Protocol,
    required this.mtu,
    this.protocol = TunnelProtocol.l2tp,
    this.version = currentVersion,
  });

  static const int legacyVersion = 3;
  static const int currentVersion = 4;
  static const String fileExtension = 'tfp';
  static const String mimeType = 'application/vnd.tunnelforge.profile+json';
  static const String uriScheme = 'tf';
  static const int maxDnsServers = 2;
  static final RegExp _malformedPercentEscapePattern = RegExp(
    r'%(?![0-9A-Fa-f]{2})',
  );
  static const Map<String, DnsProtocol> _dnsUriSchemes = <String, DnsProtocol>{
    'udp': DnsProtocol.dnsOverUdp,
    'tcp': DnsProtocol.dnsOverTcp,
    'tls': DnsProtocol.dnsOverTls,
    'https': DnsProtocol.dnsOverHttps,
  };

  final int version;
  final TunnelProtocol protocol;
  final String displayName;
  final String server;
  final String user;
  final String password;
  final String psk;
  final bool dnsAutomatic;
  final String dns1Host;
  final DnsProtocol dns1Protocol;
  final String dns2Host;
  final DnsProtocol dns2Protocol;
  final int mtu;

  Profile toProfile(
    String id, {
    String? fallbackDisplayName,
    String? subscriptionId,
    bool favorite = false,
  }) {
    final trimmedName = displayName.trim();
    final trimmedFallback = fallbackDisplayName?.trim() ?? '';
    final resolvedName = trimmedName.isNotEmpty
        ? trimmedName
        : (trimmedFallback.isNotEmpty ? trimmedFallback : server.trim());
    return Profile(
      id: id,
      displayName: resolvedName,
      server: server.trim(),
      user: user,
      protocol: protocol,
      dnsAutomatic: dnsAutomatic,
      dns1Host: Profile.normalizeDnsServerForProtocol(dns1Host, dns1Protocol),
      dns1Protocol: dns1Protocol,
      dns2Host: Profile.normalizeDnsServerForProtocol(dns2Host, dns2Protocol),
      dns2Protocol: dns2Protocol,
      mtu: Profile.normalizeMtu(mtu),
      favorite: favorite,
      subscriptionId: subscriptionId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': version,
    'protocol': protocol.jsonValue,
    'displayName': displayName,
    'server': server,
    'user': user,
    'password': password,
    if (!protocol.isPptp) 'psk': psk,
    'dnsAutomatic': dnsAutomatic,
    'dns1Host': Profile.normalizeDnsServerForProtocol(dns1Host, dns1Protocol),
    'dns1Protocol': dns1Protocol.jsonValue,
    'dns2Host': Profile.normalizeDnsServerForProtocol(dns2Host, dns2Protocol),
    'dns2Protocol': dns2Protocol.jsonValue,
    'mtu': Profile.normalizeMtu(mtu),
  };

  String toFileJson() => const JsonEncoder.withIndent('  ').convert(toJson());

  static String toBundleFileJson(List<ProfileTransferEnvelope> envelopes) {
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'v': currentVersion,
      'profiles': envelopes.map((e) => e.toJson()).toList(),
    });
  }

  String toTfUri() {
    final params = <String>[];
    void addParam(String key, String value) {
      params.add('$key=${_encodeQueryValue(value)}');
    }

    addParam('protocol', protocol.jsonValue);
    final trimmedName = displayName.trim();
    if (trimmedName.isNotEmpty) {
      addParam('displayName', trimmedName);
    }
    if (user.isNotEmpty) {
      addParam('user', user);
    }
    if (password.isNotEmpty) {
      addParam('password', password);
    }
    if (!protocol.isPptp && psk.isNotEmpty) {
      addParam('psk', psk);
    }
    if (!dnsAutomatic) {
      final servers = Profile.orderedDnsServers(
        dns1Host: dns1Host,
        dns1Protocol: dns1Protocol,
        dns2Host: dns2Host,
        dns2Protocol: dns2Protocol,
      );
      for (final entry in servers) {
        addParam('dns', _formatDnsUriValue(entry));
      }
    }
    final normalizedMtu = Profile.normalizeMtu(mtu);
    if (normalizedMtu != Profile.defaultVpnMtu) {
      addParam('mtu', '$normalizedMtu');
    }
    final base = '$uriScheme://${server.trim()}';
    return params.isEmpty ? base : '$base?${params.join('&')}';
  }

  static ProfileTransferEnvelope fromProfile({
    required Profile profile,
    required String password,
    required String psk,
  }) {
    return ProfileTransferEnvelope(
      protocol: profile.protocol,
      displayName: profile.displayName,
      server: profile.server,
      user: profile.user,
      password: password,
      psk: profile.protocol.isPptp ? '' : psk,
      dnsAutomatic: profile.dnsAutomatic,
      dns1Host: profile.dns1Host,
      dns1Protocol: profile.dns1Protocol,
      dns2Host: profile.dns2Host,
      dns2Protocol: profile.dns2Protocol,
      mtu: profile.mtu,
    );
  }

  static ProfileTransferEnvelope fromIncomingTransfer(
    IncomingProfileTransfer transfer,
  ) {
    final list = fromIncomingTransferList(transfer);
    if (list.length != 1) {
      throw const ProfileTransferFormatException(
        'Transfer contains multiple profiles',
        code: ProfileTransferErrorCode.multipleProfiles,
      );
    }
    return list.single;
  }

  static List<ProfileTransferEnvelope> fromIncomingTransferList(
    IncomingProfileTransfer transfer,
  ) {
    final data = transfer.data;
    if (data == null || data.isEmpty) {
      throw const ProfileTransferFormatException(
        'Incoming profile transfer is empty',
        code: ProfileTransferErrorCode.emptyTransfer,
      );
    }
    return switch (transfer.type) {
      ProfileTransferContract.typeTfpJson => fromFileJsonList(data),
      ProfileTransferContract.typeTfUri => [fromTfUri(data)],
      _ => throw ProfileTransferFormatException(
        transfer.message ?? 'Unsupported transfer',
        code: ProfileTransferErrorCode.unsupportedTransfer,
      ),
    };
  }

  static ProfileTransferEnvelope fromFileJson(String text) {
    final list = fromFileJsonList(text);
    if (list.length != 1) {
      throw const ProfileTransferFormatException(
        'Profile file contains multiple profiles',
        code: ProfileTransferErrorCode.multipleProfiles,
      );
    }
    return list.single;
  }

  static List<ProfileTransferEnvelope> fromFileJsonList(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const ProfileTransferFormatException(
        'Profile file must contain a JSON object',
        code: ProfileTransferErrorCode.notJsonObject,
      );
    }
    final map = Map<String, Object?>.from(decoded);
    if (map.containsKey('profiles')) {
      final version = map['v'];
      if (version is! int ||
          (version != legacyVersion && version != currentVersion)) {
        throw ProfileTransferFormatException(
          'Unsupported profile transfer version: $version',
          code: ProfileTransferErrorCode.unsupportedVersion,
          version: '$version',
        );
      }
      final rawProfiles = map['profiles'];
      if (rawProfiles is! List || rawProfiles.isEmpty) {
        throw const ProfileTransferFormatException(
          'Profile bundle contains no profiles',
          code: ProfileTransferErrorCode.bundleEmpty,
        );
      }
      return [
        for (final entry in rawProfiles)
          if (entry is Map)
            fromJsonMap(Map<String, Object?>.from(entry))
          else
            throw const ProfileTransferFormatException(
              'Profile entry must be a JSON object',
              code: ProfileTransferErrorCode.entryNotJsonObject,
            ),
      ];
    }
    return [fromJsonMap(map)];
  }

  static ProfileTransferEnvelope fromTfUri(String text) {
    final trimmed = text.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.scheme != uriScheme ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.fragment.isNotEmpty) {
      throw const ProfileTransferFormatException(
        'Invalid TunnelForge share link',
        code: ProfileTransferErrorCode.invalidShareLink,
      );
    }
    final server = uri.host.trim();
    if (server.isEmpty) {
      throw const ProfileTransferFormatException(
        'Profile transfer server is required',
        code: ProfileTransferErrorCode.serverRequired,
      );
    }

    final rawQuery = _extractRawQuery(trimmed);
    if (_malformedPercentEscapePattern.hasMatch(rawQuery)) {
      throw const ProfileTransferFormatException(
        'Invalid TunnelForge share link',
        code: ProfileTransferErrorCode.invalidShareLink,
      );
    }
    final queryPairs = _parseRawQuery(uri.query);
    var displayName = '';
    var user = '';
    var password = '';
    var psk = '';
    String? rawProtocol;
    String? rawMtu;
    final rawDnsValues = <String>[];

    for (final pair in queryPairs) {
      switch (pair.key) {
        case 'protocol':
          rawProtocol = pair.value;
        case 'displayName':
          displayName = pair.value.trim();
        case 'user':
          user = pair.value;
        case 'password':
          password = pair.value;
        case 'psk':
          psk = pair.value;
        case 'mtu':
          rawMtu = pair.value;
        case 'dns':
          final trimmedDns = pair.value.trim();
          if (trimmedDns.isNotEmpty) {
            rawDnsValues.add(trimmedDns);
          }
      }
    }

    final TunnelProtocol protocol;
    if (rawProtocol == null || rawProtocol.trim().isEmpty) {
      protocol = TunnelProtocol.l2tp;
    } else {
      final parsedProtocol = TunnelProtocol.tryParseWire(rawProtocol);
      if (parsedProtocol == null) {
        final badProtocol = rawProtocol.trim();
        throw ProfileTransferFormatException(
          'Unsupported protocol: $badProtocol',
          code: ProfileTransferErrorCode.unsupportedProtocol,
          protocol: badProtocol,
        );
      }
      protocol = parsedProtocol;
    }
    if (protocol.isPptp) {
      psk = '';
    }

    final int mtu;
    if (rawMtu == null || rawMtu.trim().isEmpty) {
      mtu = Profile.defaultVpnMtu;
    } else {
      final parsedMtu = int.tryParse(rawMtu.trim());
      if (parsedMtu == null) {
        throw const ProfileTransferFormatException(
          'Invalid integer field: mtu',
          code: ProfileTransferErrorCode.invalidIntField,
          field: 'mtu',
        );
      }
      mtu = Profile.normalizeMtu(parsedMtu);
    }

    final dnsEntries = <DnsServerConfig>[];
    final seenDns = <String>{};
    for (final rawDns in rawDnsValues) {
      final label = dnsEntries.length < 2
          ? 'DNS ${dnsEntries.length + 1}'
          : 'DNS';
      final parsed = _parseDnsUriValue(rawDns, label: label);
      final invalid = Profile.invalidDnsServer(parsed.host, parsed.protocol);
      if (invalid != null) {
        throw ProfileTransferFormatException(
          Profile.englishValidationMessageForDnsServer(
            label,
            parsed.host,
            parsed.protocol,
          ),
          code: ProfileTransferErrorCode.invalidDns,
          field: label,
          dnsHost: parsed.host,
          dnsProtocol: parsed.protocol,
        );
      }
      final normalizedHost = Profile.normalizeDnsServerForProtocol(
        parsed.host,
        parsed.protocol,
      );
      final fingerprint = '${parsed.protocol.jsonValue}:$normalizedHost';
      if (!seenDns.add(fingerprint)) continue;
      if (dnsEntries.length >= maxDnsServers) {
        throw const ProfileTransferFormatException(
          'Share link can include at most 2 DNS servers',
          code: ProfileTransferErrorCode.tooManyDnsServers,
        );
      }
      dnsEntries.add(
        DnsServerConfig(host: normalizedHost, protocol: parsed.protocol),
      );
    }

    final dnsAutomatic = dnsEntries.isEmpty;
    final dns1 = dnsEntries.isNotEmpty ? dnsEntries[0] : null;
    final dns2 = dnsEntries.length > 1 ? dnsEntries[1] : null;

    return ProfileTransferEnvelope(
      protocol: protocol,
      displayName: displayName,
      server: server,
      user: user,
      password: password,
      psk: psk,
      dnsAutomatic: dnsAutomatic,
      dns1Host: dns1?.host ?? '',
      dns1Protocol: dns1?.protocol ?? DnsProtocol.dnsOverUdp,
      dns2Host: dns2?.host ?? '',
      dns2Protocol: dns2?.protocol ?? DnsProtocol.dnsOverUdp,
      mtu: mtu,
    );
  }

  static String _formatDnsUriValue(DnsServerConfig entry) {
    return switch (entry.protocol) {
      DnsProtocol.dnsOverUdp => entry.host,
      DnsProtocol.dnsOverTcp => 'tcp://${entry.host}',
      DnsProtocol.dnsOverTls => 'tls://${entry.host}',
      DnsProtocol.dnsOverHttps =>
        entry.host.toLowerCase().startsWith('https://')
            ? entry.host
            : 'https://${entry.host}',
    };
  }

  static DnsServerConfig _parseDnsUriValue(
    String raw, {
    required String label,
  }) {
    final schemeIndex = raw.indexOf('://');
    if (schemeIndex < 0) {
      return DnsServerConfig(host: raw, protocol: DnsProtocol.dnsOverUdp);
    }
    final scheme = raw.substring(0, schemeIndex).toLowerCase();
    final remainder = raw.substring(schemeIndex + 3);
    final protocol = _dnsUriSchemes[scheme];
    if (protocol == null || remainder.isEmpty) {
      final effectiveProtocol = protocol ?? DnsProtocol.dnsOverUdp;
      throw ProfileTransferFormatException(
        Profile.englishValidationMessageForDnsServer(
          label,
          raw,
          effectiveProtocol,
        ),
        code: ProfileTransferErrorCode.invalidDns,
        field: label,
        dnsHost: raw,
        dnsProtocol: effectiveProtocol,
      );
    }
    final host =
        protocol == DnsProtocol.dnsOverHttps &&
            !remainder.contains('/') &&
            !remainder.contains('?') &&
            !remainder.contains(':')
        ? remainder
        : (protocol == DnsProtocol.dnsOverHttps
              ? 'https://$remainder'
              : remainder);
    return DnsServerConfig(host: host, protocol: protocol);
  }

  static String _extractRawQuery(String uriText) {
    final queryStart = uriText.indexOf('?');
    if (queryStart < 0) return '';
    final afterQuestion = uriText.substring(queryStart + 1);
    final hashIndex = afterQuestion.indexOf('#');
    return hashIndex < 0
        ? afterQuestion
        : afterQuestion.substring(0, hashIndex);
  }

  static List<({String key, String value})> _parseRawQuery(String rawQuery) {
    if (rawQuery.isEmpty) return const [];
    final out = <({String key, String value})>[];
    for (final part in rawQuery.split('&')) {
      if (part.isEmpty) continue;
      final eqIndex = part.indexOf('=');
      final rawKey = eqIndex < 0 ? part : part.substring(0, eqIndex);
      final rawValue = eqIndex < 0 ? '' : part.substring(eqIndex + 1);
      try {
        out.add((
          key: Uri.decodeComponent(rawKey),
          value: Uri.decodeComponent(rawValue),
        ));
      } on ArgumentError {
        throw const ProfileTransferFormatException(
          'Invalid TunnelForge share link',
          code: ProfileTransferErrorCode.invalidShareLink,
        );
      } on FormatException {
        throw const ProfileTransferFormatException(
          'Invalid TunnelForge share link',
          code: ProfileTransferErrorCode.invalidShareLink,
        );
      }
    }
    return out;
  }

  static String _encodeQueryValue(String value) {
    final bytes = utf8.encode(value);
    final buffer = StringBuffer();
    for (final byte in bytes) {
      if (_isUnencodedQueryByte(byte)) {
        buffer.writeCharCode(byte);
      } else {
        buffer.write('%');
        buffer.write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return buffer.toString();
  }

  static bool _isUnencodedQueryByte(int byte) {
    return (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2D ||
        byte == 0x2E ||
        byte == 0x5F ||
        byte == 0x7E ||
        byte == 0x3A ||
        byte == 0x2F;
  }

  static ProfileTransferEnvelope fromJsonMap(Map<String, Object?> map) {
    final version = map['v'];
    if (version is! int ||
        (version != legacyVersion && version != currentVersion)) {
      throw ProfileTransferFormatException(
        'Unsupported profile transfer version: $version',
        code: ProfileTransferErrorCode.unsupportedVersion,
        version: '$version',
      );
    }
    final TunnelProtocol protocol;
    if (version == legacyVersion && !map.containsKey('protocol')) {
      protocol = TunnelProtocol.l2tp;
    } else {
      final rawProtocol = _requireString(map, 'protocol');
      final parsedProtocol = TunnelProtocol.tryParseWire(rawProtocol);
      if (parsedProtocol == null) {
        final badProtocol = rawProtocol.trim();
        throw ProfileTransferFormatException(
          'Unsupported protocol: $badProtocol',
          code: ProfileTransferErrorCode.unsupportedProtocol,
          protocol: badProtocol,
        );
      }
      protocol = parsedProtocol;
    }
    final displayName = _requireString(map, 'displayName');
    final server = _requireString(map, 'server');
    final user = _requireString(map, 'user');
    final password = _requireString(map, 'password');
    final String psk;
    if (protocol.isPptp) {
      final rawPsk = map['psk'];
      if (rawPsk != null && rawPsk is! String) {
        throw const ProfileTransferFormatException(
          'Missing string field: psk',
          code: ProfileTransferErrorCode.missingField,
          field: 'psk',
        );
      }
      psk = '';
    } else {
      psk = _requireString(map, 'psk');
    }
    final dnsAutomatic = _requireBool(map, 'dnsAutomatic');
    final dns1Host = _requireString(map, 'dns1Host');
    final dns1Protocol = DnsProtocol.fromJson(
      _requireString(map, 'dns1Protocol'),
    );
    final dns2Host = _requireString(map, 'dns2Host');
    final dns2Protocol = DnsProtocol.fromJson(
      _requireString(map, 'dns2Protocol'),
    );
    final mtu = _requireInt(map, 'mtu');
    if (server.trim().isEmpty) {
      throw const ProfileTransferFormatException(
        'Profile transfer server is required',
        code: ProfileTransferErrorCode.serverRequired,
      );
    }
    final invalidDns1 = Profile.invalidDnsServer(dns1Host, dns1Protocol);
    if (invalidDns1 != null) {
      throw ProfileTransferFormatException(
        Profile.englishValidationMessageForDnsServer(
          'DNS 1',
          dns1Host,
          dns1Protocol,
        ),
        code: ProfileTransferErrorCode.invalidDns,
        field: 'DNS 1',
        dnsHost: dns1Host,
        dnsProtocol: dns1Protocol,
      );
    }
    final invalidDns2 = Profile.invalidDnsServer(dns2Host, dns2Protocol);
    if (invalidDns2 != null) {
      throw ProfileTransferFormatException(
        Profile.englishValidationMessageForDnsServer(
          'DNS 2',
          dns2Host,
          dns2Protocol,
        ),
        code: ProfileTransferErrorCode.invalidDns,
        field: 'DNS 2',
        dnsHost: dns2Host,
        dnsProtocol: dns2Protocol,
      );
    }
    if (!dnsAutomatic &&
        Profile.orderedDnsServers(
          dns1Host: dns1Host,
          dns1Protocol: dns1Protocol,
          dns2Host: dns2Host,
          dns2Protocol: dns2Protocol,
        ).isEmpty) {
      throw const ProfileTransferFormatException(
        'Manual DNS requires at least one DNS server',
        code: ProfileTransferErrorCode.manualDnsRequired,
      );
    }
    return ProfileTransferEnvelope(
      version: version,
      protocol: protocol,
      displayName: displayName,
      server: server,
      user: user,
      password: password,
      psk: psk,
      dnsAutomatic: dnsAutomatic,
      dns1Host: Profile.normalizeDnsServerForProtocol(dns1Host, dns1Protocol),
      dns1Protocol: dns1Protocol,
      dns2Host: Profile.normalizeDnsServerForProtocol(dns2Host, dns2Protocol),
      dns2Protocol: dns2Protocol,
      mtu: mtu,
    );
  }

  static String combinedExportFileNameFor(int count) =>
      'tf_export_$count.$fileExtension';

  static String exportFileNameFor(Profile profile) {
    final base = _sanitizeFileName(
      profile.displayName.trim().isEmpty ? profile.server : profile.displayName,
    );
    final fallback = base.isEmpty ? 'tunnel-forge-profile' : base;
    return '$fallback.$fileExtension';
  }

  static List<String> exportFileNamesFor(Iterable<Profile> profiles) {
    final used = <String, int>{};
    final out = <String>[];
    for (final profile in profiles) {
      final initial = exportFileNameFor(profile);
      final count = (used[initial] ?? 0) + 1;
      used[initial] = count;
      if (count == 1) {
        out.add(initial);
      } else {
        final stem = initial.substring(
          0,
          initial.length - fileExtension.length - 1,
        );
        out.add('$stem-$count.$fileExtension');
      }
    }
    return out;
  }

  static String _sanitizeFileName(String value) {
    return value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '')
        .toLowerCase();
  }

  static int _requireInt(Map<String, Object?> map, String key) {
    final value = map[key];
    return switch (value) {
      int v => v,
      num v => v.toInt(),
      String v =>
        int.tryParse(v.trim()) ??
            (throw ProfileTransferFormatException(
              'Invalid integer field: $key',
              code: ProfileTransferErrorCode.invalidIntField,
              field: key,
            )),
      _ => throw ProfileTransferFormatException(
        'Missing integer field: $key',
        code: ProfileTransferErrorCode.missingField,
        field: key,
      ),
    };
  }

  static bool _requireBool(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! bool) {
      throw ProfileTransferFormatException(
        'Missing bool field: $key',
        code: ProfileTransferErrorCode.missingField,
        field: key,
      );
    }
    return value;
  }

  static String _requireString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is! String) {
      throw ProfileTransferFormatException(
        'Missing string field: $key',
        code: ProfileTransferErrorCode.missingField,
        field: key,
      );
    }
    return value;
  }
}

class IncomingProfileTransfer {
  const IncomingProfileTransfer({
    required this.type,
    this.data,
    this.message,
    this.source,
  });

  final String type;
  final String? data;
  final String? message;
  final String? source;

  bool get isError => type == ProfileTransferContract.typeError;

  static IncomingProfileTransfer? tryFromMap(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final type = map[ProfileTransferContract.argType];
    if (type is! String || type.isEmpty) return null;
    return IncomingProfileTransfer(
      type: type,
      data: map[ProfileTransferContract.argData] as String?,
      message: map[ProfileTransferContract.argMessage] as String?,
      source: map[ProfileTransferContract.argSource] as String?,
    );
  }
}
