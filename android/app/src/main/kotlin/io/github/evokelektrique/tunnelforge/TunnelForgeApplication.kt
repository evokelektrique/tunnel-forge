package io.github.evokelektrique.tunnelforge

import android.app.Application
import android.util.Log

class TunnelForgeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DiagnosticLog.init(this)
        installUncaughtHandler()
        ExitReasonReporter.report(this)
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
