import 'package:material_ui/material_ui.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

/// Small dismissible dialog reporting imported, updated, and removed profile counts.
class SubscriptionUpdateDialog extends StatelessWidget {
  const SubscriptionUpdateDialog({super.key, required this.summaries});

  final List<SubscriptionSyncSummary> summaries;

  static Future<void> show(
    BuildContext context,
    List<SubscriptionSyncSummary> summaries,
  ) {
    if (summaries.isEmpty) return Future<void>.value();
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => SubscriptionUpdateDialog(summaries: summaries),
    );
  }

  Widget _buildSummaryBody(
    BuildContext context,
    SubscriptionSyncSummary summary, {
    required bool showNameHeading,
  }) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final t = AppL10n.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showNameHeading) ...[
          Text(
            summary.subscriptionName,
            style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
        ],
        if (!summary.hasChanges)
          Text(t.subscriptionNoChanges, style: tt.bodyMedium)
        else ...[
          Text(
            t.subscriptionImportedCount(summary.importedCount),
            style: tt.bodyMedium,
          ),
          const SizedBox(height: 2),
          Text(
            t.subscriptionUpdatedCount(summary.updatedCount),
            style: tt.bodyMedium,
          ),
          const SizedBox(height: 2),
          Text(
            t.subscriptionRemovedCount(summary.removedCount),
            style: tt.bodyMedium,
          ),
        ],
        if (summary.skippedInvalidLines > 0) ...[
          const SizedBox(height: 6),
          Text(
            t.subscriptionSkippedInvalidLines(summary.skippedInvalidLines),
            style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = AppL10n.of(context);
    final single = summaries.length == 1 ? summaries.single : null;
    final titleText = single != null
        ? (single.subscriptionName.trim().isNotEmpty
              ? single.subscriptionName
              : t.subscriptionUpdatedTitle)
        : t.subscriptionsUpdatedTitle;

    return AlertDialog(
      key: const Key('subscription_update_dialog'),
      title: Text(titleText),
      content: single != null
          ? _buildSummaryBody(context, single, showNameHeading: false)
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < summaries.length; i++) ...[
                    if (i > 0) const Divider(height: 20),
                    _buildSummaryBody(
                      context,
                      summaries[i],
                      showNameHeading: true,
                    ),
                  ],
                ],
              ),
            ),
      actions: [
        TextButton(
          key: const Key('subscription_update_dialog_close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.close),
        ),
      ],
    );
  }
}
