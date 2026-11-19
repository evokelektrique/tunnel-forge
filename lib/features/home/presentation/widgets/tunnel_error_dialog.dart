import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:tunnel_forge/app/ui/app_scaffold_messenger.dart';
import 'package:tunnel_forge/features/tunnel/domain/tunnel_failure.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

class TunnelErrorDialog extends StatefulWidget {
  const TunnelErrorDialog({
    super.key,
    required this.failure,
    required this.onExportLogs,
  });

  final TunnelFailure failure;
  final Future<void> Function() onExportLogs;

  @override
  State<TunnelErrorDialog> createState() => _TunnelErrorDialogState();
}

class _TunnelErrorDialogState extends State<TunnelErrorDialog> {
  bool _exporting = false;

  Future<void> _copy() async {
    final t = AppL10n.of(context);
    try {
      // Clipboard copy stays strictly English for diagnostics and issue reports.
      await Clipboard.setData(ClipboardData(text: widget.failure.copyText));
      if (mounted) {
        showAppSnackBar(context, t.errorDetailsCopied);
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, t.couldNotCopyErrorDetails, error: true);
      }
    }
  }

  Future<void> _export() async {
    final t = AppL10n.of(context);
    setState(() => _exporting = true);
    showAppSnackBar(context, t.preparingLogs);
    try {
      // The share callback reports its outcome using the app toast.
      await widget.onExportLogs();
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, t.couldNotExportLogs, error: true);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppL10n.of(context);
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      title: Text(widget.failure.localizedLabel(t)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.failure.codeLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(widget.failure.localizedExplanation(t)),
            if (widget.failure.detail.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                title: Text(
                  t.errorDetails,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                children: [SelectableText(widget.failure.detail)],
              ),
            ],
          ],
        ),
      ),
      actions: [
        OverflowBar(
          alignment: MainAxisAlignment.spaceBetween,
          overflowAlignment: OverflowBarAlignment.end,
          children: [
            TextButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
              label: Text(t.close),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: t.copyErrorDetails,
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_rounded),
                ),
                IconButton(
                  tooltip: t.exportLogs,
                  onPressed: _exporting ? null : _export,
                  icon: _exporting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.ios_share_rounded),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
