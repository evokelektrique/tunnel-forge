import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'package:tunnel_forge/app/theme/app_theme.dart';
import 'package:tunnel_forge/l10n/app_localizations.dart';

/// Shared selectable card tile used by Onboarding and the language picker.
class LanguageChoiceTile extends StatelessWidget {
  const LanguageChoiceTile({
    super.key,
    required this.locale,
    required this.title,
    this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final Locale? locale;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final semanticColors =
        Theme.of(context).extension<AppSemanticColors>() ??
        AppSemanticColors.fallback(Theme.of(context).brightness);
    final borderColor = selected
        ? semanticColors.connected
        : colorScheme.outlineVariant.withValues(alpha: 0.72);
    final backgroundColor = selected
        ? semanticColors.connected.withValues(alpha: 0.10)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.42);
    final direction = locale == null
        ? Directionality.of(context)
        : AppLanguageController.textDirectionFor(locale!);

    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: backgroundColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
            ),
            child: Directionality(
              textDirection: direction,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: textTheme.bodySmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: selected
                          ? semanticColors.connected
                          : Colors.transparent,
                      border: Border.all(
                        color: selected
                            ? semanticColors.connected
                            : colorScheme.outline,
                        width: 2,
                      ),
                    ),
                    child: selected
                        ? Icon(
                            Icons.check,
                            size: 17,
                            color: semanticColors.onConnected,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a scrollable, searchable bottom sheet listing System default and all
/// locales discovered in [AppLocalizations.supportedLocales].
Future<void> showLanguagePickerSheet(
  BuildContext context, {
  required Locale? selectedLocale,
  required ValueChanged<Locale?> onSelected,
  bool? showSearchOverride,
}) {
  final theme = Theme.of(context);
  final sheetColor =
      theme.bottomSheetTheme.backgroundColor ??
      theme.colorScheme.surfaceContainerLow;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: sheetColor,
    builder: (_) => _LanguagePickerSheet(
      selectedLocale: selectedLocale,
      onSelected: onSelected,
      showSearchOverride: showSearchOverride,
    ),
  );
}

class _LanguagePickerSheet extends StatefulWidget {
  const _LanguagePickerSheet({
    required this.selectedLocale,
    required this.onSelected,
    this.showSearchOverride,
  });

  final Locale? selectedLocale;
  final ValueChanged<Locale?> onSelected;
  final bool? showSearchOverride;

  @override
  State<_LanguagePickerSheet> createState() => _LanguagePickerSheetState();
}

class _LanguagePickerSheetState extends State<_LanguagePickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppL10n.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final locales = AppLocalizations.supportedLocales;
    final showSearch = widget.showSearchOverride ?? (locales.length >= 6);
    final normalizedQuery = _query.trim().toLowerCase();
    final deviceResolved = AppLanguageController.resolveLocale(
      null,
      PlatformDispatcher.instance.locales,
    );
    final showSystemDefault =
        normalizedQuery.isEmpty ||
        t.systemDefaultLanguage.toLowerCase().contains(normalizedQuery) ||
        t.systemDefaultLanguageSubtitle.toLowerCase().contains(normalizedQuery);
    final filteredLocales = locales
        .where((locale) {
          if (normalizedQuery.isEmpty) return true;
          final nativeName = AppLanguageController.nativeNameFor(
            locale,
          ).toLowerCase();
          final tag = AppLanguageController.localeTag(locale).toLowerCase();
          return nativeName.contains(normalizedQuery) ||
              tag.contains(normalizedQuery);
        })
        .toList(growable: false);

    final maxHeight = MediaQuery.sizeOf(context).height * 0.72;
    final selectedTag = widget.selectedLocale == null
        ? null
        : AppLanguageController.localeTag(widget.selectedLocale!);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  t.chooseLanguage,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (showSearch) ...[
                TextField(
                  key: const Key('language_picker_search_field'),
                  controller: _searchController,
                  onChanged: (value) => setState(() => _query = value),
                  decoration: InputDecoration(
                    hintText: t.searchLanguages,
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Flexible(
                child: !showSystemDefault && filteredLocales.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          t.noLanguagesMatch,
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          if (showSystemDefault) ...[
                            LanguageChoiceTile(
                              key: const Key('language_option_system'),
                              locale: null,
                              title: t.systemDefaultLanguage,
                              subtitle: t.systemDefaultLanguageSummary(
                                AppLanguageController.nativeNameFor(
                                  deviceResolved,
                                ),
                              ),
                              selected: selectedTag == null,
                              onTap: () {
                                widget.onSelected(null);
                                Navigator.of(context).pop();
                              },
                            ),
                            const SizedBox(height: 10),
                          ],
                          for (var i = 0; i < filteredLocales.length; i++) ...[
                            LanguageChoiceTile(
                              key: Key(
                                'language_option_${AppLanguageController.localeTag(filteredLocales[i])}',
                              ),
                              locale: filteredLocales[i],
                              title: AppLanguageController.nativeNameFor(
                                filteredLocales[i],
                              ),
                              subtitle: AppLanguageController.localeTag(
                                filteredLocales[i],
                              ),
                              selected:
                                  selectedTag ==
                                  AppLanguageController.localeTag(
                                    filteredLocales[i],
                                  ),
                              onTap: () {
                                widget.onSelected(filteredLocales[i]);
                                Navigator.of(context).pop();
                              },
                            ),
                            if (i < filteredLocales.length - 1)
                              const SizedBox(height: 10),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
