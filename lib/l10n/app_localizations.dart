import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  english('en', 'English', 'English'),
  persian('fa', 'Persian', 'فارسی'),
  french('fr', 'French', 'Français');

  const AppLanguage(this.code, this.englishName, this.nativeName);

  final String code;
  final String englishName;
  final String nativeName;

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) {
    return switch (code) {
      'fa' => AppLanguage.persian,
      'fr' => AppLanguage.french,
      _ => AppLanguage.english,
    };
  }
}

class AppLanguageController extends ChangeNotifier {
  AppLanguageController() {
    _load();
  }

  static const String _prefsKey = 'app_language_v1';

  AppLanguage _language = AppLanguage.english;

  AppLanguage get language => _language;

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final next = AppLanguage.fromCode(prefs.getString(_prefsKey));
    if (next == _language) return;
    _language = next;
    AppText.setLanguage(next);
    notifyListeners();
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (language == _language) return;
    _language = language;
    AppText.setLanguage(language);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, language.code);
  }

  static AppLanguageController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppLanguageScope>();
    assert(scope != null, 'No AppLanguageScope found in context.');
    return scope!.controller;
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

class AppLocalizations {
  const AppLocalizations(this.language);

  final AppLanguage language;

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('fa'),
    Locale('fr'),
  ];

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations) ??
        AppText.current;
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return AppLocalizations.supportedLocales.any(
      (supported) => supported.languageCode == locale.languageCode,
    );
  }

  @override
  Future<AppLocalizations> load(Locale locale) {
    final language = AppLanguage.fromCode(locale.languageCode);
    AppText.setLanguage(language);
    return SynchronousFuture<AppLocalizations>(AppText.current);
  }

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

class AppText {
  AppText._();

  static AppLocalizations current = const AppLocalizations(AppLanguage.english);

  static void setLanguage(AppLanguage language) {
    current = AppLocalizations(language);
  }

  static bool get isFa => current.language == AppLanguage.persian;

  /// Returns the string for the current language. [fr] is optional: English is
  /// used when no French translation is provided.
  static String pick(String en, String fa, {String? fr}) =>
      switch (current.language) {
        AppLanguage.persian => fa,
        AppLanguage.french => fr ?? en,
        AppLanguage.english => en,
      };
}

extension AppStrings on AppLocalizations {
  bool get isRtl => language == AppLanguage.persian;
  String get appTitle => 'TunnelForge';
  String get vpn => AppText.pick('VPN', 'وی‌پی‌ان', fr: "VPN");
  String get logs => AppText.pick('Logs', 'گزارش‌ها', fr: "Journal");
  String get settings => AppText.pick('Settings', 'تنظیمات', fr: "Réglages");
  String get cancel => AppText.pick('Cancel', 'لغو', fr: "Annuler");
  String get delete => AppText.pick('Delete', 'حذف', fr: "Supprimer");
  String get close => AppText.pick('Close', 'بستن', fr: "Fermer");
  String get save => AppText.pick('Save', 'ذخیره', fr: "Enregistrer");
  String get done => AppText.pick('Done', 'انجام شد', fr: "Terminé");
  String get continueLabel =>
      AppText.pick('Continue', 'ادامه', fr: "Continuer");
  String get confirm => AppText.pick('Confirm', 'تایید', fr: "Confirmer");
  String confirmInSeconds(int seconds) => AppText.pick(
    'Confirm in ${seconds}s',
    'تایید تا $seconds ثانیه',
    fr: "Confirmer dans $seconds s",
  );
  String get dismiss => AppText.pick('Dismiss', 'بستن', fr: "Fermer");
  String get languageLabel => AppText.pick('Language', 'زبان', fr: "Langue");
  String get chooseLanguage => AppText.pick(
    'Choose your language',
    'انتخاب زبان',
    fr: "Choisissez votre langue",
  );
  String get languageSubtitle => AppText.pick(
    'Set the language for every screen before you continue.',
    'زبان برنامه را انتخاب کنید. همه بخش‌ها با همین زبان نمایش داده می‌شوند.',
    fr: "Choisissez la langue de tous les écrans avant de continuer.",
  );
  String get languageBody => AppText.pick(
    'This choice updates the app immediately. You can change it later from Settings.',
    'بعدا هم می‌توانید از تنظیمات، زبان را تغییر دهید.',
    fr: "Ce choix s'applique immédiatement. Vous pourrez le modifier plus tard dans les réglages.",
  );
  String get english => 'English';
  String get persian => 'فارسی';
  String get french => 'Français';
  String get notice => AppText.pick('Notice', 'اطلاعیه', fr: "Avertissement");
  String get onboardingIntroSubtitle => AppText.pick(
    'Legacy L2TP support for modern Android, with setup and connection management in one place.',
    'این نرم‌افزار کمک می‌کند اتصال‌های L2TP را روی اندرویدهای جدید راحت‌تر بسازید و مدیریت کنید.',
    fr: "Le L2TP historique sur les Android récents, avec la configuration et la gestion des connexions au même endroit.",
  );
  String get onboardingIntroP1 => AppText.pick(
    'Create and organize profiles, switch between connections, and keep the essentials close at hand.',
    'پروفایل‌های مختلف را بسازید، نام‌گذاری کنید و هر وقت لازم بود سریع بین آن‌ها جابه‌جا شوید.',
    fr: "Créez et organisez vos profils, passez d'une connexion à l'autre et gardez l'essentiel à portée de main.",
  );
  String get onboardingIntroP2 => AppText.pick(
    'Designed for environments that still depend on L2TP, without forcing an outdated setup experience.',
    'اگر شبکه یا سرویس شما هنوز به L2TP نیاز دارد، لازم نیست با تنظیمات پیچیده و پراکنده درگیر شوید.',
    fr: "Conçu pour les environnements qui dépendent encore du L2TP, sans imposer une configuration d'un autre âge.",
  );
  String get onboardingIntroP3 => AppText.pick(
    'A focused way to manage legacy VPN access on current Android devices.',
    'همه چیز ساده نگه داشته شده تا فقط روی ساختن و وصل شدن تمرکز کنید.',
    fr: "Une solution dédiée pour gérer les accès VPN historiques sur les appareils Android actuels.",
  );
  String get securityNoticeTitle => AppText.pick(
    'Review security notice',
    'نکته امنیتی',
    fr: "Avertissement de sécurité",
  );
  String get securityNoticeSubtitle => AppText.pick(
    'L2TP/IPsec is provided for legacy compatibility, is not considered secure by modern standards, and should only be used when stronger protocols are not available.',
    'L2TP/IPsec برای سازگاری با سرویس‌های قدیمی پشتیبانی می‌شود. این روش، انتخاب امن و مدرن امروز نیست.',
    fr: "L2TP/IPsec est proposé pour la compatibilité avec l'existant. Il n'est pas considéré comme sûr selon les standards actuels et ne doit être utilisé que si aucun protocole plus robuste n'est disponible.",
  );
  String get securityReadOnlySubtitle => AppText.pick(
    'L2TP should only be used when no stronger option is available.',
    'از L2TP فقط وقتی استفاده کنید که گزینه بهتری در دسترس نیست.',
    fr: "N'utilisez L2TP que si aucune option plus robuste n'est disponible.",
  );
  String get securityP1 => AppText.pick(
    'This protocol remains available to support older infrastructure, not as a recommended default for new deployments.',
    'بعضی شبکه‌ها هنوز فقط با L2TP کار می‌کنند. پشتیبانی از آن برای همین شرایط در برنامه قرار گرفته است.',
    fr: "Ce protocole reste disponible pour les infrastructures anciennes, pas comme choix recommandé pour de nouveaux déploiements.",
  );
  String get securityP2 => AppText.pick(
    'It should be treated as easier to decrypt than modern VPN protocols. If your network supports WireGuard, OpenVPN, or another modern alternative, that should be the preferred choice.',
    'اگر برای همان سرویس WireGuard، OpenVPN یا گزینه جدیدتری دارید، بهتر است از همان استفاده کنید.',
    fr: "Considérez-le comme plus facile à déchiffrer que les protocoles VPN modernes. Si votre réseau prend en charge WireGuard, OpenVPN ou une autre solution moderne, préférez-la.",
  );
  String get securityReadOnlyP1 => AppText.pick(
    'L2TP/IPsec no longer meets modern security expectations for sensitive traffic.',
    'L2TP/IPsec برای داده‌های حساس انتخاب مناسبی نیست.',
    fr: "L2TP/IPsec ne répond plus aux exigences de sécurité actuelles pour les données sensibles.",
  );
  String get securityReadOnlyP2 => AppText.pick(
    'Use this option only when compatibility is required and no stronger protocol is available.',
    'فقط زمانی از آن استفاده کنید که سرویس شما گزینه بهتری ارائه نمی‌دهد.',
    fr: "N'utilisez cette option que si la compatibilité l'exige et qu'aucun protocole plus robuste n'est disponible.",
  );
  String get introCheckbox => AppText.pick(
    'Keep VPN profiles organized.',
    'پروفایل‌ها مرتب می‌مانند.',
    fr: "Gardez vos profils VPN organisés.",
  );
  String get riskCheckbox => AppText.pick(
    'I understand the L2TP risk.',
    'محدودیت امنیتی L2TP را می‌دانم.',
    fr: "Je comprends le risque lié à L2TP.",
  );
  String get compatibilityOnly => AppText.pick(
    'Use only when compatibility requires it',
    'فقط برای سرویس‌های قدیمی',
    fr: "À utiliser uniquement si la compatibilité l'exige",
  );
  String get compatibilityBody => AppText.pick(
    'Proceed only if this connection depends on L2TP/IPsec, you understand that it is not a secure modern protocol, and no stronger option is available for the same service.',
    'اگر سرویس شما فقط با L2TP/IPsec وصل می‌شود، می‌توانید ادامه دهید. در غیر این صورت، استفاده از یک پروتکل جدیدتر انتخاب بهتری است.',
    fr: "Ne continuez que si cette connexion repose sur L2TP/IPsec, que vous comprenez qu'il ne s'agit pas d'un protocole moderne et sûr, et qu'aucune option plus robuste n'est disponible pour ce service.",
  );

  String get appearance => AppText.pick('Appearance', 'ظاهر', fr: "Apparence");
  String get system => AppText.pick('System', 'سیستم', fr: "Système");
  String get light => AppText.pick('Light', 'روشن', fr: "Clair");
  String get dark => AppText.pick('Dark', 'تاریک', fr: "Sombre");
  String get connectionMode =>
      AppText.pick('Connection mode', 'حالت اتصال', fr: "Mode de connexion");
  String get localProxy =>
      AppText.pick('Local proxy', 'پروکسی محلی', fr: "Proxy local");
  String get splitTunneling => AppText.pick(
    'Split tunneling',
    'تونل‌سازی تفکیکی',
    fr: "Tunnel fractionné",
  );
  String get enableSplitTunneling => AppText.pick(
    'Enable split tunneling',
    'فعال کردن تونل‌سازی تفکیکی',
    fr: "Activer le tunnel fractionné",
  );
  String splitTunnelApply(String mode) => AppText.pick(
    'Apply the selected app list using $mode mode.',
    'فهرست برنامه‌های انتخاب‌شده با حالت $mode اعمال می‌شود.',
    fr: "Applique la liste d'applications choisie en mode $mode.",
  );
  String get splitTunnelRouteAll => AppText.pick(
    'Route all apps through the VPN and keep both app lists saved for later.',
    'همه برنامه‌ها از وی‌پی‌ان عبور می‌کنند و هر دو فهرست برنامه برای بعد ذخیره می‌شود.',
    fr: "Fait passer toutes les applications par le VPN et conserve les deux listes pour plus tard.",
  );
  String get mode => AppText.pick('Mode', 'حالت', fr: "Mode");
  String get inclusive => AppText.pick('Inclusive', 'شامل', fr: "Inclusif");
  String get exclusive => AppText.pick('Exclusive', 'مستثنی', fr: "Exclusif");
  String get inclusiveDescription => AppText.pick(
    'Inclusive routes only the apps you choose through the VPN.',
    'حالت شامل فقط برنامه‌هایی را که انتخاب می‌کنید از وی‌پی‌ان عبور می‌دهد.',
    fr: "Inclusif : seules les applications choisies passent par le VPN.",
  );
  String get exclusiveDescription => AppText.pick(
    'Exclusive routes all apps through the VPN except the apps you choose.',
    'حالت مستثنی همه برنامه‌ها را به جز برنامه‌های انتخابی شما از وی‌پی‌ان عبور می‌دهد.',
    fr: "Exclusif : toutes les applications passent par le VPN, sauf celles choisies.",
  );
  String get selectAppsUsingVpn => AppText.pick(
    'Select apps using VPN',
    'انتخاب برنامه‌های داخل وی‌پی‌ان',
    fr: "Choisir les applications qui utilisent le VPN",
  );
  String get selectAppsOutsideVpn => AppText.pick(
    'Select apps outside VPN',
    'انتخاب برنامه‌های خارج از وی‌پی‌ان',
    fr: "Choisir les applications hors du VPN",
  );
  String get noAppsUseVpn => AppText.pick(
    'No apps selected. Choose at least one app to use the VPN.',
    'برنامه‌ای انتخاب نشده است. حداقل یک برنامه را برای استفاده از وی‌پی‌ان انتخاب کنید.',
    fr: "Aucune application choisie. Choisissez-en au moins une pour utiliser le VPN.",
  );
  String appsWillUseVpn(int count) => AppText.pick(
    '$count app${count == 1 ? '' : 's'} will use the VPN.',
    '$count برنامه از وی‌پی‌ان استفاده می‌کند.',
    fr: "$count application${count == 1 ? '' : 's'} ${count == 1 ? 'utilisera' : 'utiliseront'} le VPN.",
  );
  String get noAppsBypassVpn => AppText.pick(
    'No apps selected. All apps will continue using the VPN.',
    'برنامه‌ای انتخاب نشده است. همه برنامه‌ها همچنان از وی‌پی‌ان استفاده می‌کنند.',
    fr: "Aucune application choisie. Toutes les applications continueront d'utiliser le VPN.",
  );
  String appsWillBypassVpn(int count) => AppText.pick(
    '$count app${count == 1 ? '' : 's'} will bypass the VPN.',
    '$count برنامه وی‌پی‌ان را دور می‌زند.',
    fr: "$count application${count == 1 ? '' : 's'} ${count == 1 ? 'contournera' : 'contourneront'} le VPN.",
  );
  String get httpPort =>
      AppText.pick('HTTP port', 'درگاه HTTP', fr: "Port HTTP");
  String get socksPort =>
      AppText.pick('SOCKS5 port', 'درگاه SOCKS5', fr: "Port SOCKS5");
  String get allowLan => AppText.pick(
    'Allow connections from LAN',
    'اجازه اتصال از شبکه محلی',
    fr: "Autoriser les connexions du réseau local",
  );
  String get allowLanOn => AppText.pick(
    'Detect a shareable local IPv4 and expose both listeners to devices on the same Wi-Fi or hotspot when available.',
    'یک IPv4 محلی قابل اشتراک را شناسایی می‌کند و در صورت امکان هر دو شنونده را برای دستگاه‌های همان وای‌فای یا هات‌اسپات در دسترس می‌گذارد.',
    fr: "Détecte une adresse IPv4 locale partageable et rend les deux ports d'écoute accessibles aux appareils du même Wi-Fi ou point d'accès, si possible.",
  );
  String get allowLanOff => AppText.pick(
    'Keep both listeners on this device only.',
    'هر دو شنونده فقط روی همین دستگاه می‌مانند.',
    fr: "Garde les deux ports d'écoute accessibles uniquement depuis cet appareil.",
  );
  String get proxyPortsDifferent => AppText.pick(
    'HTTP and SOCKS5 ports must be different before connecting.',
    'درگاه‌های HTTP و SOCKS5 قبل از اتصال باید متفاوت باشند.',
    fr: "Les ports HTTP et SOCKS5 doivent être différents avant de vous connecter.",
  );
  String get proxyEndpoints => AppText.pick(
    'Proxy endpoints',
    'نقطه‌های پایانی پروکسی',
    fr: "Adresses du proxy",
  );
  String get lanClientsCanUse => AppText.pick(
    'LAN clients on the same Wi-Fi or hotspot can use this address.',
    'دستگاه‌های همان وای‌فای یا هات‌اسپات می‌توانند از این نشانی استفاده کنند.',
    fr: "Les appareils du même Wi-Fi ou point d'accès peuvent utiliser cette adresse.",
  );
  String get lanSharingEnabled => AppText.pick(
    'LAN sharing is enabled for this session.',
    'اشتراک‌گذاری شبکه محلی برای این نشست فعال است.',
    fr: "Le partage sur le réseau local est activé pour cette session.",
  );
  String get connectToDetectLan => AppText.pick(
    'Connect to detect the current LAN IP for other devices.',
    'برای تشخیص IP شبکه محلی جهت دستگاه‌های دیگر وصل شوید.',
    fr: "Connectez-vous pour détecter l'adresse IP locale à utiliser par les autres appareils.",
  );
  String get lanDisabled => AppText.pick(
    'LAN access is disabled.',
    'دسترسی شبکه محلی غیرفعال است.',
    fr: "L'accès depuis le réseau local est désactivé.",
  );
  String get connectivityCheck => AppText.pick(
    'Connectivity check',
    'بررسی اتصال',
    fr: "Test de connectivité",
  );
  String get batteryOptimization => AppText.pick(
    'Battery optimization',
    'بهینه‌سازی باتری',
    fr: "Optimisation de la batterie",
  );
  String get batteryOptimizationAllowed => AppText.pick(
    'Allowed for background use.',
    'برای استفاده در پس‌زمینه مجاز است.',
    fr: "Autorisé en arrière-plan.",
  );
  String get batteryOptimizationRestricted => AppText.pick(
    'Restricted in the background.',
    'در پس‌زمینه محدود است.',
    fr: "Restreint en arrière-plan.",
  );
  String get batteryOptimizationUnsupported => AppText.pick(
    'Not required on this device.',
    'در این دستگاه لازم نیست.',
    fr: "Inutile sur cet appareil.",
  );
  String get batteryOptimizationUnknown => AppText.pick(
    'Status unavailable.',
    'وضعیت در دسترس نیست.',
    fr: "État indisponible.",
  );
  String get allowBackgroundVpn =>
      AppText.pick('Allow', 'اجازه', fr: "Autoriser");
  String get statusCheckUrl => AppText.pick(
    'Status check URL',
    'نشانی بررسی وضعیت',
    fr: "Adresse du test d'état",
  );
  String get statusCheckHelp => AppText.pick(
    'Used for the status check after you connect. Tap the badge anytime to refresh.',
    'پس از اتصال برای بررسی وضعیت استفاده می‌شود. هر زمان برای تازه‌سازی روی نشان بزنید.',
    fr: "Utilisée pour le test d'état après la connexion. Touchez le badge à tout moment pour l'actualiser.",
  );
  String get connectivityUrl => AppText.pick(
    'Connectivity URL',
    'نشانی اتصال',
    fr: "Adresse de test de connectivité",
  );
  String get connectivityTimeout => AppText.pick(
    'Connectivity timeout (ms)',
    'مهلت اتصال (میلی‌ثانیه)',
    fr: "Délai du test de connectivité (ms)",
  );
  String get timeoutHelp => AppText.pick(
    'Maximum time to wait before marking the check unreachable.',
    'بیشترین زمان انتظار پیش از ناموفق دانستن بررسی.',
    fr: "Temps d'attente maximal avant de considérer la cible comme injoignable.",
  );
  String get l2tpSecurityNotice => AppText.pick(
    'L2TP security notice',
    'اطلاعیه امنیتی L2TP',
    fr: "Avertissement de sécurité L2TP",
  );
  String get reviewL2tpNotice => AppText.pick(
    'Review the L2TP/IPsec compatibility notice.',
    'اطلاعیه سازگاری L2TP/IPsec را مرور کنید.',
    fr: "Relire l'avertissement sur la compatibilité L2TP/IPsec.",
  );
  String get updates =>
      AppText.pick('Updates', 'به‌روزرسانی‌ها', fr: "Mises à jour");
  String get refresh => AppText.pick('Refresh', 'تازه‌سازی', fr: "Actualiser");
  String get openReleasePage => AppText.pick(
    'Open release page',
    'باز کردن صفحه انتشار',
    fr: "Ouvrir la page de publication",
  );
  String get versionUnavailable => AppText.pick(
    'Version unavailable',
    'نسخه در دسترس نیست',
    fr: "Version indisponible",
  );
  String version(String value) =>
      AppText.pick('Version $value', 'نسخه $value', fr: "Version $value");
  String get about => AppText.pick('About', 'درباره', fr: "À propos");
  String get aboutText => AppText.pick(
    'TunnelForge keeps L2TP/IPsec usable on modern Android, with profile management, local proxy access, per-app routing, and clear connection logs in one place.',
    'TunnelForge برای زمانی است که هنوز به اتصال L2TP/IPsec نیاز دارید. پروفایل‌ها، پروکسی محلی، مسیریابی برنامه‌ها و گزارش اتصال را یکجا و بدون شلوغی مدیریت می‌کند.',
    fr: "TunnelForge permet d'utiliser L2TP/IPsec sur les Android récents, avec la gestion des profils, un proxy local, le routage par application et un journal de connexion clair, au même endroit.",
  );
  String get telegramTitle =>
      AppText.pick('Telegram', 'تلگرام', fr: "Telegram");
  String get githubTitle => AppText.pick('GitHub', 'گیت‌هاب', fr: "GitHub");
  String get checkingUpdates => AppText.pick(
    'Checking for updates',
    'در حال بررسی به‌روزرسانی',
    fr: "Recherche de mises à jour",
  );
  String get updateAvailable => AppText.pick(
    'Update available',
    'به‌روزرسانی در دسترس است',
    fr: "Mise à jour disponible",
  );
  String get buildNewer => AppText.pick(
    'Installed build is newer',
    'نسخه نصب‌شده جدیدتر است',
    fr: "La version installée est plus récente",
  );
  String get updateCheckUnavailable => AppText.pick(
    'Update check unavailable',
    'بررسی به‌روزرسانی در دسترس نیست',
    fr: "Recherche de mises à jour indisponible",
  );
  String get appUpToDate => AppText.pick(
    'App is up to date',
    'برنامه به‌روز است',
    fr: "L'application est à jour",
  );
  String get checkForUpdates => AppText.pick(
    'Check for updates',
    'بررسی به‌روزرسانی',
    fr: "Rechercher des mises à jour",
  );
  String get lookingUpRelease => AppText.pick(
    'Looking up the latest published GitHub release.',
    'در حال دریافت آخرین انتشار GitHub.',
    fr: "Recherche de la dernière version publiée sur GitHub.",
  );
  String get updateCheckConsentTitle => AppText.pick(
    'Check GitHub releases?',
    'بررسی انتشارهای GitHub؟',
    fr: "Consulter les versions publiées sur GitHub ?",
  );
  String get updateCheckConsentMessage => AppText.pick(
    'TunnelForge will contact GitHub Releases to compare your installed version with the latest published build. This is used only when you request an update check.',
    'TunnelForge برای مقایسه نسخه نصب‌شده با آخرین انتشار، به GitHub Releases وصل می‌شود. این کار فقط زمانی انجام می‌شود که خودتان بررسی به‌روزرسانی را درخواست کنید.',
    fr: "TunnelForge va contacter GitHub Releases pour comparer la version installée avec la dernière version publiée. Cela n'a lieu que lorsque vous demandez une recherche de mises à jour.",
  );
  String get updateCheckConsentAllow => AppText.pick(
    'Check releases',
    'بررسی انتشارها',
    fr: "Consulter les versions",
  );
  String latestReleaseRunning(String latest, String installed) => AppText.pick(
    'Latest release: $latest. You are running $installed.',
    'آخرین انتشار: $latest. نسخه نصب‌شده شما $installed است.',
    fr: "Dernière version : $latest. Vous utilisez $installed.",
  );
  String latestPublished(String latest) => AppText.pick(
    'You are running the latest published release: $latest.',
    'شما آخرین انتشار منتشرشده را اجرا می‌کنید: $latest.',
    fr: "Vous utilisez la dernière version publiée : $latest.",
  );
  String buildNewerThanLatest(String latest) => AppText.pick(
    'This build is newer than the latest GitHub release ($latest).',
    'این نسخه از آخرین انتشار GitHub جدیدتر است ($latest).',
    fr: "Cette version est plus récente que la dernière version publiée sur GitHub ($latest).",
  );
  String latestCannotCompare(String latest, String reason) => AppText.pick(
    'Latest release: $latest. $reason',
    'آخرین انتشار: $latest. $reason',
    fr: "Dernière version : $latest. $reason",
  );
  String get unknownBuild => AppText.pick(
    'an unknown build',
    'یک نسخه نامشخص',
    fr: "une version inconnue",
  );
  String get couldNotCheckUpdates => AppText.pick(
    'Couldn\'t check for updates right now.',
    'اکنون امکان بررسی به‌روزرسانی نیست.',
    fr: "Impossible de rechercher des mises à jour pour le moment.",
  );
  String updateCheckError(String message) {
    if (!isRtl) return message;
    if (message.startsWith('GitHub Releases returned HTTP ')) {
      final status = message
          .replaceFirst('GitHub Releases returned HTTP ', '')
          .replaceFirst('.', '');
      return 'سرور GitHub پاسخ ناموفق برگرداند ($status).';
    }
    return switch (message) {
      'Network error while contacting GitHub Releases.' =>
        'اتصال به GitHub برای بررسی به‌روزرسانی برقرار نشد.',
      'GitHub Releases request timed out.' =>
        'بررسی به‌روزرسانی بیش از حد طول کشید.',
      'Secure connection to GitHub Releases failed.' =>
        'اتصال امن به GitHub برقرار نشد.',
      'GitHub Releases returned malformed data.' =>
        'پاسخ GitHub قابل خواندن نبود.',
      'GitHub Releases returned no usable releases.' =>
        'انتشار قابل استفاده‌ای در GitHub پیدا نشد.',
      'Unexpected error while checking GitHub Releases.' =>
        'هنگام بررسی به‌روزرسانی خطای غیرمنتظره‌ای رخ داد.',
      'Installed version unavailable, so this build cannot be compared.' =>
        installedVersionUnavailableCompare,
      _ => message,
    };
  }

  String get checkGithubReleases => AppText.pick(
    'Check GitHub releases to see whether a newer build is available.',
    'انتشارهای GitHub را بررسی کنید تا مشخص شود نسخه جدیدتری هست یا نه.',
    fr: "Consultez les versions publiées sur GitHub pour savoir si une version plus récente existe.",
  );
  String get installedVersionUnavailableCompare => AppText.pick(
    'Installed version unavailable, so this build cannot be compared.',
    'نسخه نصب‌شده در دسترس نیست؛ بنابراین این نسخه قابل مقایسه نیست.',
    fr: "Version installée inconnue : impossible de comparer.",
  );

  String get activeProfile =>
      AppText.pick('Active profile', 'پروفایل فعال', fr: "Profil actif");
  String get noSavedProfile => AppText.pick(
    'No saved profile',
    'پروفایل ذخیره‌شده‌ای نیست',
    fr: "Aucun profil enregistré",
  );
  String get quickConnect =>
      AppText.pick('Quick connect', 'اتصال سریع', fr: "Connexion rapide");
  String get createFirstProfile => AppText.pick(
    'Create your first profile',
    'اولین پروفایل خود را بسازید',
    fr: "Créez votre premier profil",
  );
  String get selectSavedProfile => AppText.pick(
    'Select a saved profile',
    'یک پروفایل ذخیره‌شده انتخاب کنید',
    fr: "Choisissez un profil enregistré",
  );
  String get selectProfile =>
      AppText.pick('Select profile', 'انتخاب پروفایل', fr: "Choisir un profil");
  String get ready => AppText.pick('Ready', 'آماده', fr: "Prêt");
  String get connected => AppText.pick('Connected', 'متصل', fr: "Connecté");
  String get proxyReady =>
      AppText.pick('Proxy ready', 'پروکسی آماده است', fr: "Proxy prêt");
  String get working =>
      AppText.pick('Working...', 'در حال کار...', fr: "En cours…");
  String get connectingTapCancel => AppText.pick(
    'Connecting... tap to cancel',
    'در حال اتصال... برای لغو بزنید',
    fr: "Connexion… touchez pour annuler",
  );
  String get disconnecting => AppText.pick(
    'Disconnecting...',
    'در حال قطع اتصال...',
    fr: "Déconnexion…",
  );
  String get canceling =>
      AppText.pick('Canceling...', 'در حال لغو...', fr: "Annulation…");
  String get tapToCheck => AppText.pick(
    'Tap to check',
    'برای بررسی بزنید',
    fr: "Touchez pour tester",
  );
  String get checking =>
      AppText.pick('Checking...', 'در حال بررسی...', fr: "Test en cours…");
  String get unreachable =>
      AppText.pick('Unreachable', 'غیرقابل دسترس', fr: "Injoignable");
  String get logLevel =>
      AppText.pick('Log level', 'سطح گزارش', fr: "Niveau de journal");
  String get wordWrapOff => AppText.pick(
    'Turn off word wrap (wide lines scroll sideways)',
    'خاموش کردن شکست خط',
    fr: "Désactiver le retour à la ligne (défilement horizontal des lignes longues)",
  );
  String get wordWrapOn => AppText.pick(
    'Turn on word wrap',
    'روشن کردن شکست خط',
    fr: "Activer le retour à la ligne",
  );
  String get copyVisible => AppText.pick(
    'Copy visible',
    'کپی موارد نمایان',
    fr: "Copier les lignes visibles",
  );
  String get shareDebugLogs => AppText.pick(
    'Share debug logs',
    'اشتراک‌گذاری گزارش‌های دیباگ',
    fr: "Partager le journal de débogage",
  );
  String get clear => AppText.pick('Clear', 'پاک کردن', fr: "Effacer");
  String get noLogsMatch => AppText.pick(
    'No logs match this level',
    'گزارشی با این سطح نیست',
    fr: "Aucune ligne pour ce niveau",
  );
  String get noActivityYet => AppText.pick(
    'No activity yet',
    'هنوز فعالیتی نیست',
    fr: "Aucune activité pour le moment",
  );
  String get differentLogLevel => AppText.pick(
    'Try a different log level to see more entries.',
    'برای دیدن موارد بیشتر سطح گزارش دیگری را امتحان کنید.',
    fr: "Choisissez un autre niveau pour afficher plus de lignes.",
  );
  String get logsWillAppear => AppText.pick(
    'Connection events and diagnostics will appear here.',
    'رویدادهای اتصال و عیب‌یابی اینجا نمایش داده می‌شوند.',
    fr: "Les événements de connexion et les diagnostics s'afficheront ici.",
  );
  String get latest => AppText.pick('Latest', 'آخرین', fr: "Récent");

  String get profiles => AppText.pick('Profiles', 'پروفایل‌ها', fr: "Profils");
  String get addProfile =>
      AppText.pick('Add profile', 'افزودن پروفایل', fr: "Ajouter un profil");
  String get createNewProfile => AppText.pick(
    'Create new profile',
    'ساخت پروفایل جدید',
    fr: "Créer un profil",
  );
  String get importFromFile => AppText.pick(
    'Import from file',
    'وارد کردن از فایل',
    fr: "Importer depuis un fichier",
  );
  String get importFromClipboard => AppText.pick(
    'Import from clipboard',
    'وارد کردن از کلیپ‌بورد',
    fr: "Importer depuis le presse-papiers",
  );
  String get noProfilesYet => AppText.pick(
    'No profiles yet. Tap + to create or import your first profile.',
    'هنوز پروفایلی ندارید. برای ساخت یا وارد کردن اولین پروفایل روی + بزنید.',
    fr: "Aucun profil pour le moment. Touchez + pour créer ou importer votre premier profil.",
  );
  String get profileActions => AppText.pick(
    'Profile actions',
    'کنش‌های پروفایل',
    fr: "Actions sur le profil",
  );
  String get copyShareLink => AppText.pick(
    'Copy share link',
    'کپی پیوند اشتراک',
    fr: "Copier le lien de partage",
  );
  String get exportTfp =>
      AppText.pick('Export .tfp', 'خروجی .tfp', fr: "Exporter en .tfp");
  String get editProfile =>
      AppText.pick('Edit profile', 'ویرایش پروفایل', fr: "Modifier le profil");
  String get deleteProfile =>
      AppText.pick('Delete profile', 'حذف پروفایل', fr: "Supprimer le profil");
  String get deleteProfileQuestion => AppText.pick(
    'Delete profile?',
    'پروفایل حذف شود؟',
    fr: "Supprimer le profil ?",
  );
  String get deleteProfileBody => AppText.pick(
    'This will remove the server and saved credentials from this device.',
    'این کار سرور و اطلاعات ورود ذخیره‌شده را از این دستگاه حذف می‌کند.',
    fr: "Le serveur et les identifiants enregistrés seront supprimés de cet appareil.",
  );
  String get profileSaved => AppText.pick(
    'Profile saved',
    'پروفایل ذخیره شد',
    fr: "Profil enregistré",
  );
  String get profileRefreshTimedOut => AppText.pick(
    'Profile list refresh timed out',
    'زمان تازه‌سازی فهرست پروفایل‌ها تمام شد',
    fr: "L'actualisation de la liste des profils a expiré",
  );
  String get profileImportTimedOut => AppText.pick(
    'Profile import timed out',
    'زمان وارد کردن پروفایل تمام شد',
    fr: "L'importation du profil a expiré",
  );
  String get couldNotReadSelectedFile => AppText.pick(
    'Couldn\'t read the selected file',
    'فایل انتخاب‌شده خوانده نشد',
    fr: "Impossible de lire le fichier choisi",
  );
  String get couldNotImportTfp => AppText.pick(
    'Couldn\'t import .tfp file',
    'فایل .tfp وارد نشد',
    fr: "Impossible d'importer le fichier .tfp",
  );
  String get clipboardEmpty => AppText.pick(
    'Clipboard is empty',
    'کلیپ‌بورد خالی است',
    fr: "Le presse-papiers est vide",
  );
  String get clipboardInvalidProfile => AppText.pick(
    'Clipboard does not contain a valid TunnelForge profile',
    'کلیپ‌بورد شامل پروفایل معتبر TunnelForge نیست.',
    fr: "Le presse-papiers ne contient pas de profil TunnelForge valide",
  );
  String get couldNotImportClipboard => AppText.pick(
    'Couldn\'t import a profile from the clipboard',
    'پروفایل از کلیپ‌بورد وارد نشد',
    fr: "Impossible d'importer un profil depuis le presse-papiers",
  );

  String get profileDetails => AppText.pick(
    'Profile details',
    'جزئیات پروفایل',
    fr: "Détails du profil",
  );
  String get name => AppText.pick('Name', 'نام', fr: "Nom");
  String get nameHint =>
      AppText.pick('e.g. Office VPN', 'مثلا VPN دفتر', fr: "ex. VPN du bureau");
  String get server => AppText.pick('Server', 'سرور', fr: "Serveur");
  String get serverHint => AppText.pick(
    'Hostname or IP address',
    'نام میزبان یا نشانی IP',
    fr: "Nom d'hôte ou adresse IP",
  );
  String get username =>
      AppText.pick('Username', 'نام کاربری', fr: "Identifiant");
  String get password =>
      AppText.pick('Password', 'رمز عبور', fr: "Mot de passe");
  String get showPassword => AppText.pick(
    'Show password',
    'نمایش رمز عبور',
    fr: "Afficher le mot de passe",
  );
  String get hidePassword => AppText.pick(
    'Hide password',
    'پنهان کردن رمز عبور',
    fr: "Masquer le mot de passe",
  );
  String get ipsecPsk =>
      AppText.pick('IPsec PSK', 'کلید مشترک IPsec', fr: "PSK IPsec");
  String get showIpsecPsk => AppText.pick(
    'Show IPsec PSK',
    'نمایش کلید مشترک IPsec',
    fr: "Afficher la PSK IPsec",
  );
  String get hideIpsecPsk => AppText.pick(
    'Hide IPsec PSK',
    'پنهان کردن کلید مشترک IPsec',
    fr: "Masquer la PSK IPsec",
  );
  String get ipsecPskHint =>
      AppText.pick('Optional', 'اختیاری', fr: "Facultatif");
  String get automatic =>
      AppText.pick('Automatic', 'خودکار', fr: "Automatique");
  String get automaticDnsHelp => AppText.pick(
    'Receive DNS configuration automatically from the VPN server during PPP negotiation.',
    'پیکربندی DNS هنگام مذاکره PPP به صورت خودکار از سرور وی‌پی‌ان دریافت می‌شود.',
    fr: "Recevoir automatiquement la configuration DNS du serveur VPN pendant la négociation PPP.",
  );
  String get dnsServers =>
      AppText.pick('DNS servers', 'سرورهای DNS', fr: "Serveurs DNS");
  String get dnsHelp => AppText.pick(
    'DNS 1 is primary. DNS 2 is fallback.',
    'DNS 1 اصلی است. DNS 2 پشتیبان است.',
    fr: "DNS 1 est le serveur principal, DNS 2 le serveur de secours.",
  );
  String mtuHelper(int min, int max, int defaultValue) => AppText.pick(
    'Range $min-$max. Use $defaultValue unless you need a smaller MTU.',
    'بازه $min تا $max. مگر اینکه به MTU کوچک‌تری نیاز دارید، از $defaultValue استفاده کنید.',
    fr: "Plage $min-$max. Utilisez $defaultValue, sauf besoin d'un MTU plus petit.",
  );

  String get selectAll =>
      AppText.pick('Select all', 'انتخاب همه', fr: "Tout sélectionner");
  String get clearAll =>
      AppText.pick('Clear all', 'پاک کردن همه', fr: "Tout désélectionner");
  String get searchApps => AppText.pick(
    'Search by name or package',
    'جستجو بر اساس نام یا بسته',
    fr: "Rechercher par nom ou par paquet",
  );
  String get noLaunchableApps => AppText.pick(
    'No launchable apps found. If this is wrong, check that the app can query other packages on your Android version.',
    'برنامه قابل اجرا پیدا نشد. اگر این درست نیست، بررسی کنید برنامه روی نسخه اندروید شما اجازه دیدن بسته‌های دیگر را دارد.',
    fr: "Aucune application lançable trouvée. Si c'est inexact, vérifiez que l'application peut interroger les autres paquets sur votre version d'Android.",
  );
  String get noMatches =>
      AppText.pick('No matches.', 'موردی پیدا نشد.', fr: "Aucun résultat.");
  String get appsUsingVpn => AppText.pick(
    'Apps using VPN',
    'برنامه‌های داخل وی‌پی‌ان',
    fr: "Applications qui utilisent le VPN",
  );
  String get appsOutsideVpn => AppText.pick(
    'Apps outside VPN',
    'برنامه‌های خارج از وی‌پی‌ان',
    fr: "Applications hors du VPN",
  );
  String get onlySelectedAppsVpn => AppText.pick(
    'Only the selected apps will use the VPN.',
    'فقط برنامه‌های انتخاب‌شده از وی‌پی‌ان استفاده می‌کنند.',
    fr: "Seules les applications choisies utiliseront le VPN.",
  );
  String get selectedAppsBypass => AppText.pick(
    'Selected apps will bypass the VPN and use the normal network.',
    'برنامه‌های انتخاب‌شده وی‌پی‌ان را دور می‌زنند و از شبکه عادی استفاده می‌کنند.',
    fr: "Les applications choisies contourneront le VPN et utiliseront le réseau habituel.",
  );
}
