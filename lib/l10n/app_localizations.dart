import 'package:cupertino_ui/cupertino_ui.dart'
    show GlobalCupertinoLocalizations;
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalWidgetsLocalizations;
import 'package:intl/intl.dart' show Bidi;
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tunnel_forge/l10n/generated/app_localizations.dart';
import 'package:tunnel_forge/l10n/generated/app_localizations_en.dart';

export 'package:tunnel_forge/l10n/generated/app_localizations.dart';

/// Holds the active [AppLocalizations] snapshot for BLoCs, validators, and tests
/// that render without localization delegates.
class AppL10n {
  AppL10n._();

  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ];

  static AppLocalizations current = AppLocalizationsEn();

  static AppLocalizations of(BuildContext context) {
    return AppLocalizations.of(context) ?? current;
  }

  static void syncLocale(Locale locale) {
    final supported =
        AppLanguageController.matchSupportedLocale(locale) ??
        const Locale('en');
    current = lookupAppLocalizations(supported);
  }
}

class AppLanguageController extends ChangeNotifier {
  AppLanguageController({
    void Function(Locale? previous, Locale? next)? onLocaleChanged,
    void Function(Locale? loaded)? onLocaleLoaded,
    SharedPreferences? prefsOverride,
  }) : _onLocaleChanged = onLocaleChanged,
       _onLocaleLoaded = onLocaleLoaded,
       _prefsOverride = prefsOverride {
    _load();
  }

  static const String _prefsKey = 'app_language_v1';
  static const String _systemPrefsValue = 'system';

  final void Function(Locale? previous, Locale? next)? _onLocaleChanged;
  final void Function(Locale? loaded)? _onLocaleLoaded;
  final SharedPreferences? _prefsOverride;

  /// Explicit user-selected locale, or `null` when following system default.
  Locale? _locale;

  Locale? get locale => _locale;

  List<Locale> get supportedLocales => AppLocalizations.supportedLocales;

  Locale get effectiveLocale =>
      resolveLocale(_locale, PlatformDispatcher.instance.locales);

  Future<SharedPreferences> _prefs() => _prefsOverride != null
      ? Future<SharedPreferences>.value(_prefsOverride)
      : SharedPreferences.getInstance();

  Future<void> _load() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_prefsKey);
    final next = raw == null || raw == _systemPrefsValue
        ? null
        : parseSupportedLocale(raw);
    AppL10n.syncLocale(
      resolveLocale(next, PlatformDispatcher.instance.locales),
    );
    _onLocaleLoaded?.call(next);
    if (_sameLocale(_locale, next)) return;
    _locale = next;
    notifyListeners();
  }

  Future<void> setLocale(Locale? locale) async {
    final next = locale == null ? null : matchSupportedLocale(locale);
    if (_sameLocale(_locale, next)) return;
    final previous = _locale;
    _locale = next;
    AppL10n.syncLocale(effectiveLocale);
    notifyListeners();
    _onLocaleChanged?.call(previous, next);
    final prefs = await _prefs();
    if (next == null) {
      await prefs.remove(_prefsKey);
    } else {
      await prefs.setString(_prefsKey, localeTag(next));
    }
  }

  void handleSystemLocalesChanged() {
    if (_locale != null) return;
    AppL10n.syncLocale(effectiveLocale);
    notifyListeners();
  }

  static AppLanguageController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppLanguageScope>();
    assert(scope != null, 'No AppLanguageScope found in context.');
    return scope!.controller;
  }

  static String nativeNameFor(Locale locale) {
    final matched = matchSupportedLocale(locale) ?? const Locale('en');
    return lookupAppLocalizations(matched).languageNativeName;
  }

  static TextDirection textDirectionFor(Locale locale) {
    return Bidi.isRtlLanguage(locale.languageCode)
        ? TextDirection.rtl
        : TextDirection.ltr;
  }

  static String localeTag(Locale locale) => locale.toLanguageTag();

  static Locale resolveLocale(Locale? selected, List<Locale> deviceLocales) {
    if (selected != null) {
      return matchSupportedLocale(selected) ?? const Locale('en');
    }
    for (final candidate in deviceLocales) {
      final matched = matchSupportedLocale(candidate);
      if (matched != null) return matched;
    }
    return const Locale('en');
  }

  static Locale? parseSupportedLocale(String? tag) {
    final trimmed = tag?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final parts = trimmed.replaceAll('_', '-').split('-');
    if (parts.isEmpty || parts.first.isEmpty) return null;
    final languageCode = parts.first.toLowerCase();
    String? scriptCode;
    String? countryCode;
    for (var i = 1; i < parts.length; i++) {
      final part = parts[i];
      if (part.isEmpty) continue;
      if (scriptCode == null && part.length == 4) {
        scriptCode = part[0].toUpperCase() + part.substring(1).toLowerCase();
      } else if (countryCode == null &&
          (part.length == 2 || part.length == 3)) {
        countryCode = part.toUpperCase();
      }
    }
    return matchSupportedLocale(
      Locale.fromSubtags(
        languageCode: languageCode,
        scriptCode: scriptCode,
        countryCode: countryCode,
      ),
    );
  }

  static Locale? matchSupportedLocale(Locale candidate) {
    final supported = AppLocalizations.supportedLocales;
    final candidateLang = candidate.languageCode.toLowerCase();
    final candidateScript = candidate.scriptCode?.toLowerCase();
    final candidateCountry = candidate.countryCode?.toUpperCase();

    for (final locale in supported) {
      if (locale.languageCode.toLowerCase() == candidateLang &&
          locale.scriptCode?.toLowerCase() == candidateScript &&
          locale.countryCode?.toUpperCase() == candidateCountry) {
        return locale;
      }
    }
    if (candidateScript != null) {
      for (final locale in supported) {
        if (locale.languageCode.toLowerCase() == candidateLang &&
            locale.scriptCode?.toLowerCase() == candidateScript &&
            (locale.countryCode == null || locale.countryCode!.isEmpty)) {
          return locale;
        }
      }
    }
    if (candidateCountry != null) {
      for (final locale in supported) {
        if (locale.languageCode.toLowerCase() == candidateLang &&
            locale.countryCode?.toUpperCase() == candidateCountry &&
            (locale.scriptCode == null || locale.scriptCode!.isEmpty)) {
          return locale;
        }
      }
    }
    for (final locale in supported) {
      if (locale.languageCode.toLowerCase() == candidateLang &&
          (locale.scriptCode == null || locale.scriptCode!.isEmpty) &&
          (locale.countryCode == null || locale.countryCode!.isEmpty)) {
        return locale;
      }
    }
    for (final locale in supported) {
      if (locale.languageCode.toLowerCase() == candidateLang) {
        return locale;
      }
    }
    return null;
  }

  static bool _sameLocale(Locale? a, Locale? b) {
    if (a == null || b == null) return a == b;
    return a.toLanguageTag() == b.toLanguageTag();
  }
}

class AppLanguageScope extends InheritedNotifier<AppLanguageController> {
  const AppLanguageScope({
    super.key,
    required AppLanguageController controller,
    required super.child,
  }) : super(notifier: controller);

  AppLanguageController get controller => notifier!;
}
