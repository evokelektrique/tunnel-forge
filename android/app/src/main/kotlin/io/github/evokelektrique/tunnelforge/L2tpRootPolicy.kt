package io.github.evokelektrique.tunnelforge

import android.util.Log
import java.io.File

internal data class L2tpBackendDecision(
    val useRoot: Boolean,
    val logLevel: Int,
    val logMessage: String,
)

/** Shared root-first L2TP backend selection policy for VPN and Proxy-only services. */
internal object L2tpRootPolicy {
    internal const val LIB_NAME = "libl2tp_root_helper.so"

    fun decideBackend(
        rootDetected: Boolean,
        forceUserspaceVpn: Boolean,
    ): L2tpBackendDecision {
        return when {
            !rootDetected ->
                L2tpBackendDecision(
                    useRoot = false,
                    logLevel = Log.INFO,
                    logMessage = "root not detected, switching to userspace VPN for L2TP (default behavior)",
                )

            forceUserspaceVpn ->
                L2tpBackendDecision(
                    useRoot = false,
                    logLevel = Log.INFO,
                    logMessage = "root detected, but profile forced userspace VPN for L2TP",
                )

            else ->
                L2tpBackendDecision(
                    useRoot = true,
                    logLevel = Log.INFO,
                    logMessage = "root detected, using root backend for L2TP (Kernel XFRM first with fallback)",
                )
        }
    }

    fun configureForAttempt(
        nativeLibraryDir: String,
        bindInterface: String,
        protocol: String,
        forceUserspaceVpn: Boolean,
        attemptPrefix: String,
        tag: String,
    ) {
        if (protocol == VpnContract.PROTOCOL_PPTP) {
            val helperPath = File(nativeLibraryDir, TunnelVpnService.PPTP_GRE_HELPER_LIB_NAME).absolutePath
            VpnBridge.nativeSetPptpRuntimeConfig(helperPath, bindInterface)
            return
        }
        val rootDetected = RootAccessDetector.isRootDetected()
        val decision = decideBackend(rootDetected = rootDetected, forceUserspaceVpn = forceUserspaceVpn)
        VpnTunnelEvents.emitEngineLog(decision.logLevel, tag, "$attemptPrefix${decision.logMessage}")
        val helperPath = if (decision.useRoot) File(nativeLibraryDir, LIB_NAME).absolutePath else ""
        VpnBridge.nativeSetL2tpRuntimeConfig(helperPath, bindInterface, decision.useRoot)
    }
}
