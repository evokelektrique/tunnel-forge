package io.github.evokelektrique.tunnelforge

/** Keeps the most recent terminal tunnel event emitted while no Dart channel is attached. */
internal class PendingTerminalHolder {
    private var pending: Map<String, Any?>? = null

    @Synchronized
    fun recordIfTerminal(state: String?, payload: Map<String, Any?>, nowMs: Long) {
        if (state != VpnContract.TUNNEL_FAILED && state != VpnContract.TUNNEL_STOPPED) return
        val existing = pending
        if (existing != null &&
            state == VpnContract.TUNNEL_STOPPED &&
            existing[VpnContract.ARG_TUNNEL_STATE] == VpnContract.TUNNEL_FAILED
        ) {
            val existingAttempt = existing[VpnContract.ARG_ATTEMPT_ID] as? String ?: ""
            val incomingAttempt = payload[VpnContract.ARG_ATTEMPT_ID] as? String ?: ""
            if (existingAttempt == incomingAttempt) return
        }
        pending = payload + (ARG_TIMESTAMP_MS to nowMs)
    }

    @Synchronized
    fun consume(): Map<String, Any?>? {
        val snapshot = pending
        pending = null
        return snapshot
    }

    companion object {
        const val ARG_TIMESTAMP_MS = "timestampMs"
    }
}
