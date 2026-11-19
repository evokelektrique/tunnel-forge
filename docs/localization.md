# Localization Guide

TunnelForge uses standard, platform-agnostic localization files so translation platforms such as Crowdin or Weblate can manage all languages without Dart or Kotlin code changes.

## Resource Files

| Surface | Source (English template) | Translations |
| --- | --- | --- |
| Flutter UI, dialogs, toasts | `lib/l10n/app_en.arb` | `lib/l10n/app_<locale>.arb` |
| Android notifications | `android/app/src/main/res/values/strings.xml` | `android/app/src/main/res/values-<b+locale>/strings.xml` |

## Adding a New Language

1. Copy `lib/l10n/app_en.arb` to `lib/l10n/app_<locale>.arb` (for example `app_es.arb` or `app_pt_BR.arb`).
2. Set `"@@locale"` and translate `"languageNativeName"` to the language's own name (endonym, for example `"Español"` or `"Português (Brasil)"`).
3. Copy translatable entries from `android/app/src/main/res/values/strings.xml` into `android/app/src/main/res/values-<locale>/strings.xml` (omit entries marked `translatable="false"`).
4. Run `flutter pub get` to regenerate `lib/l10n/generated/` and test with `flutter test`.

No Dart or Kotlin files need editing:
- `flutter gen-l10n` auto-discovers `lib/l10n/app_*.arb` and populates `AppLocalizations.supportedLocales`.
- `AppLanguageController` reads each locale's `languageNativeName` and detects RTL layout from the locale.
- Android Gradle Plugin (`generateLocaleConfig = true`) auto-generates the Android 13+ per-app `localeConfig` from `res/values-*` directories.

## Strict English-Only Diagnostic Boundary

Never localize logs, diagnostic dumps, crash tombstones, raw engine error details, or clipboard error reports (`TunnelFailure.copyText`). Keep all `LogsRepository`, `DiagnosticLogStore`, `AppLog`, and `TunnelFailure.label` / `explanation` outputs strictly in English so bug reports stay searchable and consistent across locales.

## Crowdin / Weblate Setup

Point your translation project at both resource pairs:
- Flutter ARB: source `lib/l10n/app_en.arb`, translation pattern `lib/l10n/app_%two_letters_code%.arb` (or `%locale_with_underscore%`).
- Android XML: source `android/app/src/main/res/values/strings.xml`, translation pattern `android/app/src/main/res/values-%android_code%/strings.xml`.

`lib/l10n/generated/` is gitignored and regenerated on `flutter pub get`, so translator pull requests only modify `.arb` and `strings.xml` files.
