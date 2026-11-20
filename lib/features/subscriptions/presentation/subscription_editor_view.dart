import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:tunnel_forge/features/subscriptions/domain/subscription_models.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

typedef SubscriptionEditorSubmit =
    void Function({
      required String name,
      required String url,
      required bool autoUpdate,
      required int updateIntervalMinutes,
      required SubscriptionIntervalUnit intervalUnit,
      required bool urlChanged,
      required bool autoUpdateNewlyEnabled,
    });

/// In-sheet editor for creating or editing a subscription URL and auto-update schedule.
class SubscriptionEditorView extends StatefulWidget {
  const SubscriptionEditorView({
    super.key,
    this.initialSubscription,
    required this.submitting,
    required this.onClose,
    required this.onSubmit,
  });

  final Subscription? initialSubscription;
  final bool submitting;
  final VoidCallback onClose;
  final SubscriptionEditorSubmit onSubmit;

  @override
  State<SubscriptionEditorView> createState() => _SubscriptionEditorViewState();
}

class _SubscriptionEditorViewState extends State<SubscriptionEditorView> {
  static const int _kCustomFrequencyValue = -1;
  static const double _kIntervalControlHeight = 56;

  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _customValueController;

  late bool _autoUpdate;
  late int _selectedFrequency;
  late SubscriptionIntervalUnit _customUnit;
  bool _attemptedSubmit = false;

  bool get _isEditing => widget.initialSubscription != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSubscription;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _urlController = TextEditingController(text: initial?.url ?? '');
    _autoUpdate = initial?.autoUpdate ?? false;

    if (initial == null) {
      _selectedFrequency = Subscription.defaultIntervalMinutes;
      _customUnit = SubscriptionIntervalUnit.hours;
      _customValueController = TextEditingController(text: '24');
    } else if (initial.isPresetInterval &&
        initial.intervalUnit != SubscriptionIntervalUnit.minutes) {
      _selectedFrequency = initial.updateIntervalMinutes;
      _customUnit = initial.effectiveDisplayUnit;
      _customValueController = TextEditingController(
        text: '${initial.displayIntervalValue}',
      );
    } else {
      _selectedFrequency = _kCustomFrequencyValue;
      _customUnit = initial.effectiveDisplayUnit;
      _customValueController = TextEditingController(
        text: '${initial.displayIntervalValue}',
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _customValueController.dispose();
    super.dispose();
  }

  InputDecoration _deco(BuildContext context, {String? label, String? hint}) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(8);
    final border = OutlineInputBorder(borderRadius: radius);
    return InputDecoration(
      labelText: label,
      hintText: hint,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: cs.primary, width: 2),
      ),
    );
  }

  String _presetLabel(int minutes, AppLocalizations t) {
    if (minutes == 1440) {
      return t.frequencyEveryHours(24);
    }
    if (minutes % 1440 == 0) {
      return t.frequencyEveryDays(minutes ~/ 1440);
    }
    return t.frequencyEveryHours(minutes ~/ 60);
  }

  SubscriptionIntervalUnit _unitForPreset(int minutes) {
    if (minutes == 1440) return SubscriptionIntervalUnit.hours;
    if (minutes % 1440 == 0) return SubscriptionIntervalUnit.days;
    return SubscriptionIntervalUnit.hours;
  }

  void _handleSave(BuildContext context) {
    final t = AppL10n.of(context);
    setState(() => _attemptedSubmit = true);

    final nameError = Subscription.validateName(_nameController.text, l10n: t);
    final urlError = Subscription.validateUrl(_urlController.text, l10n: t);
    String? customError;
    if (_autoUpdate && _selectedFrequency == _kCustomFrequencyValue) {
      customError = Subscription.validateCustomInterval(
        _customValueController.text,
        _customUnit,
        l10n: t,
      );
    }
    if (nameError != null || urlError != null || customError != null) {
      return;
    }

    final int intervalMinutes;
    final SubscriptionIntervalUnit unit;
    if (!_autoUpdate) {
      intervalMinutes =
          widget.initialSubscription?.updateIntervalMinutes ??
          Subscription.defaultIntervalMinutes;
      unit =
          widget.initialSubscription?.intervalUnit ??
          SubscriptionIntervalUnit.hours;
    } else if (_selectedFrequency == _kCustomFrequencyValue) {
      intervalMinutes =
          Subscription.parseCustomIntervalMinutes(
            _customValueController.text,
            _customUnit,
          ) ??
          Subscription.defaultIntervalMinutes;
      unit = _customUnit;
    } else {
      intervalMinutes = _selectedFrequency;
      unit = _unitForPreset(_selectedFrequency);
    }

    final trimmedName = _nameController.text.trim();
    final trimmedUrl = _urlController.text.trim();
    final initial = widget.initialSubscription;
    final urlChanged = initial == null || initial.url.trim() != trimmedUrl;
    final autoUpdateNewlyEnabled =
        _autoUpdate && (initial == null || !initial.autoUpdate);

    FocusScope.of(context).unfocus();
    widget.onSubmit(
      name: trimmedName,
      url: trimmedUrl,
      autoUpdate: _autoUpdate,
      updateIntervalMinutes: intervalMinutes,
      intervalUnit: unit,
      urlChanged: urlChanged,
      autoUpdateNewlyEnabled: autoUpdateNewlyEnabled,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tt = theme.textTheme;
    final sheetColor =
        theme.bottomSheetTheme.backgroundColor ?? cs.surfaceContainerLow;
    final maxH = MediaQuery.sizeOf(context).height * 0.9;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final t = AppL10n.of(context);

    final nameError = _attemptedSubmit
        ? Subscription.validateName(_nameController.text, l10n: t)
        : null;
    final urlError = _attemptedSubmit
        ? Subscription.validateUrl(_urlController.text, l10n: t)
        : null;
    final showHttpWarning =
        urlError == null &&
        Subscription.isCleartextHttpUrl(_urlController.text);
    final isCustom = _selectedFrequency == _kCustomFrequencyValue;
    final customError = _attemptedSubmit && _autoUpdate && isCustom
        ? Subscription.validateCustomInterval(
            _customValueController.text,
            _customUnit,
            l10n: t,
          )
        : null;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: maxH,
        child: Scaffold(
          backgroundColor: sheetColor,
          resizeToAvoidBottomInset: false,
          appBar: AppBar(
            automaticallyImplyLeading: false,
            backgroundColor: sheetColor,
            surfaceTintColor: Colors.transparent,
            title: Text(
              _isEditing ? t.editSubscription : t.subscriptionDetails,
            ),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: widget.submitting ? null : widget.onClose,
            ),
            actions: [
              TextButton(
                key: const Key('subscription_save_button'),
                onPressed: widget.submitting
                    ? null
                    : () => _handleSave(context),
                child: Text(t.save),
              ),
            ],
          ),
          body: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + safeBottom),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.submitting) ...[
                  const LinearProgressIndicator(
                    key: Key('subscription_fetching_progress'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    t.fetchingSubscription,
                    style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  key: const Key('subscription_name_field'),
                  controller: _nameController,
                  enabled: !widget.submitting,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) {
                    if (_attemptedSubmit) setState(() {});
                  },
                  decoration: _deco(
                    context,
                    label: t.subscriptionName,
                    hint: t.subscriptionNameHint,
                  ).copyWith(errorText: nameError),
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('subscription_url_field'),
                  controller: _urlController,
                  enabled: !widget.submitting,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  decoration:
                      _deco(
                        context,
                        label: t.subscriptionUrl,
                        hint: t.subscriptionUrlHint,
                      ).copyWith(
                        errorText: urlError,
                        helperText: showHttpWarning
                            ? t.subscriptionHttpWarning
                            : null,
                        helperMaxLines: 2,
                        helperStyle: showHttpWarning
                            ? tt.bodySmall?.copyWith(color: cs.tertiary)
                            : null,
                      ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  key: const Key('subscription_auto_update_checkbox'),
                  value: _autoUpdate,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  title: Text(t.autoUpdate),
                  subtitle: Text(t.autoUpdateHelp),
                  onChanged: widget.submitting
                      ? null
                      : (value) => setState(() => _autoUpdate = value ?? false),
                ),
                if (_autoUpdate) ...[
                  const SizedBox(height: 12),
                  InputDecorator(
                    isEmpty: false,
                    decoration: _deco(context, label: t.updateFrequency)
                        .copyWith(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                        ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: const Key('subscription_frequency_dropdown'),
                        value: _selectedFrequency,
                        isExpanded: true,
                        borderRadius: BorderRadius.circular(12),
                        onChanged: widget.submitting
                            ? null
                            : (value) {
                                if (value == null) return;
                                setState(() {
                                  _selectedFrequency = value;
                                  if (value != _kCustomFrequencyValue) {
                                    _customUnit = _unitForPreset(value);
                                    _customValueController.text =
                                        '${value ~/ _customUnit.minutesPerUnit}';
                                  }
                                });
                              },
                        items: [
                          for (final preset
                              in Subscription.presetIntervalsMinutes)
                            DropdownMenuItem<int>(
                              value: preset,
                              child: Text(_presetLabel(preset, t)),
                            ),
                          DropdownMenuItem<int>(
                            value: _kCustomFrequencyValue,
                            child: Text(t.frequencyCustom),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (isCustom) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key(
                              'subscription_custom_interval_field',
                            ),
                            controller: _customValueController,
                            enabled: !widget.submitting,
                            keyboardType: TextInputType.number,
                            inputFormatters: <TextInputFormatter>[
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            onChanged: (_) {
                              if (_attemptedSubmit) setState(() {});
                            },
                            decoration: _deco(context, label: t.intervalValue)
                                .copyWith(
                                  errorText: customError,
                                  errorMaxLines: 2,
                                  helperText: t.intervalHelperMinMinutes(
                                    Subscription.minIntervalMinutes,
                                  ),
                                  helperMaxLines: 2,
                                ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 132,
                          height: _kIntervalControlHeight,
                          child: InputDecorator(
                            isEmpty: false,
                            decoration: _deco(context, label: t.intervalUnit)
                                .copyWith(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<SubscriptionIntervalUnit>(
                                key: const Key(
                                  'subscription_custom_unit_dropdown',
                                ),
                                value: _customUnit,
                                isExpanded: true,
                                borderRadius: BorderRadius.circular(12),
                                onChanged: widget.submitting
                                    ? null
                                    : (value) {
                                        if (value == null) return;
                                        setState(() => _customUnit = value);
                                      },
                                items: SubscriptionIntervalUnit.orderedValues
                                    .map(
                                      (unit) => DropdownMenuItem(
                                        value: unit,
                                        child: Text(unit.localizedLabel(t)),
                                      ),
                                    )
                                    .toList(growable: false),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
