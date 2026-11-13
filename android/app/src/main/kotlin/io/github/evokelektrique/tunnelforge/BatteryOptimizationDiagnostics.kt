package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.os.Build
import android.os.PowerManager
import android.util.Log

internal class BatteryOptimizationLogPolicy {
    private val lock = Any()
    private var unrestrictedLoggedInSession = false

    fun resetSession() {
        synchronized(lock) {
            unrestrictedLoggedInSession = false
        }
    }

    fun markUnrestrictedLogged() {
        synchronized(lock) {
            unrestrictedLoggedInSession = true
        }
    }

    /**
     * Suppresses secondary logs once the app session observes unrestricted (`allowed`) status,
     * resetting only on [resetSession] or if optimization becomes restricted again.
     */
    fun shouldLog(state: String): Boolean =
        synchronized(lock) {
            if (state == BatteryOptimizationDiagnostics.STATE_ALLOWED) {
                if (unrestrictedLoggedInSession) {
                    false
                } else {
                    unrestrictedLoggedInSession = true
                    true
                }
            } else {
                unrestrictedLoggedInSession = false
                true
            }
        }

    companion object {
        val shared = BatteryOptimizationLogPolicy()
    }
}

internal object BatteryOptimizationDiagnostics {
    const val STATE_UNSUPPORTED = "unsupported"
    const val STATE_ALLOWED = "allowed"
    const val STATE_RESTRICTED = "restricted"

    fun isIgnoringBatteryOptimizations(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val target = context.applicationContext ?: context
        val powerManager = target.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return powerManager.isIgnoringBatteryOptimizations(target.packageName)
    }

    fun isPowerSaveMode(context: Context): Boolean {
        val target = context.applicationContext ?: context
        val powerManager = target.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return powerManager.isPowerSaveMode
    }

    fun stateName(context: Context): String =
        when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.M -> STATE_UNSUPPORTED
            isIgnoringBatteryOptimizations(context) -> STATE_ALLOWED
            else -> STATE_RESTRICTED
        }

    fun emitForVpnEvent(
        context: Context,
        tag: String,
        attemptPrefix: String,
        stage: String,
    ) {
        val state = stateName(context)
        if (!BatteryOptimizationLogPolicy.shared.shouldLog(state)) return
        val powerSaveMode = isPowerSaveMode(context)
        val priority = if (state == STATE_RESTRICTED) Log.WARN else Log.INFO
        VpnTunnelEvents.emitEngineLog(
            priority,
            tag,
            "${attemptPrefix}battery_optimization stage=$stage state=$state powerSaveMode=$powerSaveMode",
        )
    }
}
