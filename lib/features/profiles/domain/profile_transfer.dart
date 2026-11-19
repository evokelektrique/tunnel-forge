import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:tunnel_forge/features/profiles/domain/profile_models.dart';
import 'package:tunnel_forge/features/profiles/data/profile_transfer_contract.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

enum ProfileTransferErrorCode {
  multipleProfiles,
  emptyTransfer,
  unsupportedTransfer,
  notJsonObject,
  unsupportedVersion,
  bundleEmpty,
  entryNotJsonObject,
  invalidShareLink,
  missingSharePayload,
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
    this.dnsHost,
    this.dnsProtocol,
  });

  final ProfileTransferErrorCode code;
  final String? field;
  final String? version;
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
      ProfileTransferErrorCode.bundleEmpty => t.profileTransferBundleEmpty,
      ProfileTransferErrorCode.entryNotJsonObject =>
        t.profileTransferEntryNotJsonObject,
      ProfileTransferErrorCode.invalidShareLink =>
        t.profileTransferInvalidShareLink,
      ProfileTransferErrorCode.missingSharePayload =>
        t.profileTransferMissingPayload,
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
    this.version = currentVersion,
  });

  static const int currentVersion = 3;
  static const String fileExtension = 'tfp';
  static const String mimeType = 'application/vnd.tunnelforge.profile+json';
  static const String uriScheme = 'tf';
  static const String uriHost = 'p';

  final int version;
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

  Profile toProfile(String id) {
    return Profile(
      id: id,
      displayName: displayName.trim().isEmpty ? server.trim() : displayName,
      server: server.trim(),
      user: user,
      dnsAutomatic: dnsAutomatic,
      dns1Host: Profile.normalizeDnsServerForProtocol(dns1Host, dns1Protocol),
      dns1Protocol: dns1Protocol,
      dns2Host: Profile.normalizeDnsServerForProtocol(dns2Host, dns2Protocol),
      dns2Protocol: dns2Protocol,
      mtu: Profile.normalizeMtu(mtu),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': version,
    'displayName': displayName,
    'server': server,
    'user': user,
    'password': password,
    'psk': psk,
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
    final jsonBytes = utf8.encode(jsonEncode(toJson()));
    final compressed = GZipEncoder().encode(jsonBytes);
    final payload = base64UrlEncode(compressed).replaceAll('=', '');
    return '$uriScheme://$uriHost/$payload';
  }

  static ProfileTransferEnvelope fromProfile({
    required Profile profile,
    required String password,
    required String psk,
  }) {
    return ProfileTransferEnvelope(
      displayName: profile.displayName,
      server: profile.server,
      user: profile.user,
      password: password,
      psk: psk,
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
      if (version is! int || version != currentVersion) {
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
    final uri = Uri.tryParse(text.trim());
    if (uri == null || uri.scheme != uriScheme || uri.host != uriHost) {
      throw const ProfileTransferFormatException(
        'Invalid TunnelForge share link',
        code: ProfileTransferErrorCode.invalidShareLink,
      );
    }
    if (uri.pathSegments.isEmpty) {
      throw const ProfileTransferFormatException(
        'Share link payload is missing',
        code: ProfileTransferErrorCode.missingSharePayload,
      );
    }
    final payload = uri.pathSegments.join('');
    final normalized = base64Url.normalize(payload);
    final compressed = base64Url.decode(normalized);
    final jsonBytes = Uint8List.fromList(GZipDecoder().decodeBytes(compressed));
    return fromFileJson(utf8.decode(jsonBytes));
  }

  static ProfileTransferEnvelope fromJsonMap(Map<String, Object?> map) {
    final version = map['v'];
    if (version is! int || version != currentVersion) {
      throw ProfileTransferFormatException(
        'Unsupported profile transfer version: $version',
        code: ProfileTransferErrorCode.unsupportedVersion,
        version: '$version',
      );
    }
    final displayName = _requireString(map, 'displayName');
    final server = _requireString(map, 'server');
    final user = _requireString(map, 'user');
    final password = _requireString(map, 'password');
    final psk = _requireString(map, 'psk');
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
