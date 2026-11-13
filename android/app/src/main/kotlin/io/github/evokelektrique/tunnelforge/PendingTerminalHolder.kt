package io.github.evokelektrique.tunnelforge

/** Keeps the most recent terminal tunnel event emitted while no Dart channel is attached. */
internal class PendingTerminalHolder {
    private var pending: Map<String, Any?>? = null

    @Synchronized
    fun recordIfTerminal(state: String?, payload: Map<String, Any?>, nowMs: Long) {
        if (state == VpnContract.TUNNEL_FAILED || state == VpnContract.TUNNEL_STOPPED) {
            pending = payload + (ARG_TIMESTAMP_MS to nowMs)
        }
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
