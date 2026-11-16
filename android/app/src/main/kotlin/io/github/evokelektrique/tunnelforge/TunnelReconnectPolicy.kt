package io.github.evokelektrique.tunnelforge

import kotlin.math.min

internal object VpnAndroidFailure {
    const val NAMESPACE = "android"
    const val CODE_VPN_REVOKED = 1
    const val CODE_SYSTEM_DESTROYED = 2
    const val CODE_TASK_REMOVED = 3
    const val CODE_VPN_PERMISSION_REVOKED = 4
    const val CODE_LOCAL_PROXY_FAILED = 5
    const val CODE_UNEXPECTED_STOP = 6

    fun map(code: Int): Map<String, Any> =
        mapOf(
            "namespace" to NAMESPACE,
            "code" to code,
            "generalError" to 0,
        )
}

internal object TunnelReconnectPolicy {
    const val INITIAL_BACKOFF_MS = 1_000L
    const val MAX_BACKOFF_MS = 30_000L
    const val STALLED_RECONNECT_ALERT_ATTEMPT = 3

    private val TERMINAL_AUTH_NAMESPACES = setOf("mschap", "chap", "pap")
    private val TERMINAL_STOPCCN_CODES = setOf(4, 5, 8)
    private const val CDN_ADMIN_DISCONNECT = 3

    fun backoffMsForAttempt(attemptIndex: Int): Long {
        if (attemptIndex <= 0) return INITIAL_BACKOFF_MS
        val shift = attemptIndex.coerceAtMost(10)
        return min(INITIAL_BACKOFF_MS shl shift, MAX_BACKOFF_MS)
    }

    fun isTerminalFailure(
        exitCode: Int,
        failure: Map<String, Any>?,
    ): Boolean {
        if (exitCode == VpnBridge.EXIT_BAD_ARGS ||
            exitCode == VpnBridge.EXIT_PROXY_NOT_IMPLEMENTED ||
            exitCode == VpnBridge.EXIT_STOPPED ||
            exitCode == VpnBridge.EXIT_PEER_CLOSED
        ) {
            return true
        }
        val namespace = failure?.get("namespace") as? String ?: return false
        val code = (failure["code"] as? Number)?.toInt()
        return when (namespace) {
            in TERMINAL_AUTH_NAMESPACES -> true
            "l2tp-stopccn" -> code in TERMINAL_STOPCCN_CODES
            "l2tp-cdn" -> code == CDN_ADMIN_DISCONNECT
            else -> false
        }
    }

    fun shouldFailOnInitialAttempt(
        hasEverConnected: Boolean,
        hasUsableNetwork: Boolean,
        exitCode: Int,
        failure: Map<String, Any>?,
    ): Boolean {
        if (isTerminalFailure(exitCode, failure)) return true
        if (!hasEverConnected &&
            hasUsableNetwork &&
            (exitCode == VpnBridge.EXIT_IKE_FAILED ||
                exitCode == VpnBridge.EXIT_L2TP_FAILED ||
                exitCode == VpnBridge.EXIT_PPP_FAILED)
        ) {
            return true
        }
        return false
    }

    fun recoveryStateForConnectivity(hasUsableNetwork: Boolean): String =
        if (hasUsableNetwork) {
            VpnContract.TUNNEL_RECONNECTING
        } else {
            VpnContract.TUNNEL_WAITING_FOR_NETWORK
        }

    fun shouldPostStalledReconnectAlert(
        onlineFailureCount: Int,
        alreadyNotified: Boolean,
    ): Boolean = !alreadyNotified && onlineFailureCount >= STALLED_RECONNECT_ALERT_ATTEMPT
}
