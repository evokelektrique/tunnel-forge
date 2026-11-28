package io.github.evokelektrique.tunnelforge

import android.app.Application
import android.content.res.Configuration
import android.os.LocaleList
import android.util.Log

class TunnelForgeApplication : Application() {
    @Volatile
    private var lastConfigLocales: LocaleList? = null

    override fun onCreate() {
        super.onCreate()
        lastConfigLocales = resources.configuration.locales
        DiagnosticLog.init(this)
        RootAccessDetector.startAsyncProbe()
        QuickSettingsTileController.init(this)
        installUncaughtHandler()
        ExitReasonReporter.report(this)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (newConfig.locales != lastConfigLocales) {
            lastConfigLocales = newConfig.locales
            AppLocaleSupport.refreshActiveNotifications(this)
        }
    }

    private fun installUncaughtHandler() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            runCatching {
                DiagnosticLog.write(
                    Log.ERROR,
                    VpnContract.LOG_SOURCE_KOTLIN,
                    "Uncaught",
                    "thread=${thread.name}\n${throwable.stackTraceToString().trimEnd()}",
                )
            }
            previous?.uncaughtException(thread, throwable)
        }
    }
}
