package io.github.evokelektrique.tunnelforge

import android.app.LocaleManager
import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import android.os.Build
import androidx.core.content.edit
import android.os.LocaleList
import androidx.annotation.StringRes

/** Syncs the Flutter-selected locale with Android per-app locale and background services. */
internal object AppLocaleSupport {
    private const val PREFS_NAME = "tunnel_forge_locale"
    private const val KEY_LOCALE_TAG = "app_locale_tag"

    fun normalizeLanguageTag(rawTag: String?): String? {
        val trimmed = rawTag?.trim()?.replace('_', '-')
        if (trimmed.isNullOrEmpty() || trimmed.equals("system", ignoreCase = true)) {
            return null
        }
        return trimmed
    }

    fun applyAppLocale(context: Context, rawTag: String?) {
        val tag = normalizeLanguageTag(rawTag)
        val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit {
            if (tag == null) remove(KEY_LOCALE_TAG) else putString(KEY_LOCALE_TAG, tag)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val localeManager = context.getSystemService(LocaleManager::class.java)
            if (localeManager != null) {
                val target =
                    if (tag == null) {
                        LocaleList.getEmptyLocaleList()
                    } else {
                        LocaleList.forLanguageTags(tag)
                    }
                if (localeManager.applicationLocales != target) {
                    localeManager.applicationLocales = target
                }
            }
        }
        QuickSettingsTileController.requestUpdate(context)
        refreshActiveNotifications(context)
    }

    fun refreshActiveNotifications(context: Context) {
        val appContext = context.applicationContext
        TunnelVpnService.refreshNotificationLanguage(appContext)
        ProxyTunnelService.refreshNotificationLanguage(appContext)
        TunnelDisconnectNotification.refreshActiveNotifications(appContext)
        SubscriptionNotification.refreshActiveNotifications(appContext)
    }

    fun localizedContext(context: Context): Context {
        val tag =
            context.applicationContext
                .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .getString(KEY_LOCALE_TAG, null)
                ?.let(::normalizeLanguageTag)
        if (tag != null) {
            val config = Configuration(context.resources.configuration)
            config.setLocales(LocaleList.forLanguageTags(tag))
            return context.createConfigurationContext(config)
        }
        val systemLocales = Resources.getSystem().configuration.locales
        if (!systemLocales.isEmpty) {
            val config = Configuration(context.resources.configuration)
            config.setLocales(systemLocales)
            return context.createConfigurationContext(config)
        }
        return context
    }

    fun englishContext(context: Context): Context {
        val config = Configuration(context.resources.configuration)
        config.setLocales(LocaleList.forLanguageTags("en"))
        return context.createConfigurationContext(config)
    }

    fun getString(context: Context, @StringRes resId: Int, vararg formatArgs: Any): String {
        val resContext = localizedContext(context)
        return if (formatArgs.isEmpty()) {
            resContext.getString(resId)
        } else {
            resContext.getString(resId, *formatArgs)
        }
    }
}
