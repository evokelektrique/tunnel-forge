import 'package:tunnel_forge/features/profiles/domain/profile_transfer.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';

/// Parses plaintext subscription payloads containing one `tf://` URI per line.
class SubscriptionParser {
  SubscriptionParser._();

  static SubscriptionParseResult parse(String body) {
    final cleaned = body.startsWith('\uFEFF') ? body.substring(1) : body;
    final lines = cleaned.split(RegExp(r'\r?\n'));
    final envelopes = <ProfileTransferEnvelope>[];
    var skippedInvalidLines = 0;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      try {
        envelopes.add(ProfileTransferEnvelope.fromTfUri(line));
      } on FormatException {
        skippedInvalidLines += 1;
      }
    }

    if (envelopes.isEmpty) {
      throw const SubscriptionException(
        'Subscription payload contained no valid tf:// profiles',
        code: SubscriptionErrorCode.noValidProfiles,
      );
    }

    return SubscriptionParseResult(
      envelopes: List<ProfileTransferEnvelope>.unmodifiable(envelopes),
      skippedInvalidLines: skippedInvalidLines,
    );
  }
}
