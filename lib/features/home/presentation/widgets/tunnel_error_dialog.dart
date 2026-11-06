import 'package:flutter/material.dart';
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
    try {
      await Clipboard.setData(ClipboardData(text: widget.failure.copyText));
      if (mounted) {
        showAppSnackBar(
          context,
          AppText.pick('Error details copied', 'جزئیات خطا کپی شد'),
        );
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppText.pick(
            'Could not copy error details',
            'کپی جزئیات خطا انجام نشد',
          ),
          error: true,
        );
      }
    }
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    showAppSnackBar(
      context,
      AppText.pick('Preparing logs...', 'در حال آماده‌سازی گزارش‌ها...'),
    );
    try {
      // The share callback reports its outcome using the app toast.
      await widget.onExportLogs();
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppText.pick('Could not export logs', 'صدور گزارش‌ها انجام نشد'),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    actionsPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    title: Text(widget.failure.label),
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
          Text(widget.failure.explanation),
          if (widget.failure.detail.isNotEmpty) ...[
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              expandedCrossAxisAlignment: CrossAxisAlignment.start,
              title: Text(
                AppText.pick('Error details', 'جزئیات خطا'),
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
            label: Text(AppText.pick('Close', 'بستن')),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: AppText.pick('Copy error details', 'کپی جزئیات خطا'),
                onPressed: _copy,
                icon: const Icon(Icons.copy_rounded),
              ),
              IconButton(
                tooltip: AppText.pick('Export logs', 'صدور گزارش‌ها'),
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
