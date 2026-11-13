package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PendingTerminalHolderTest {

    @Test
    fun recordsOnlyTerminalStatesAndConsumesOnce() {
        val holder = PendingTerminalHolder()

        holder.recordIfTerminal(
            VpnContract.TUNNEL_CONNECTING,
            mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_CONNECTING),
            100L,
        )
        assertNull(holder.consume())

        holder.recordIfTerminal(
            VpnContract.TUNNEL_CONNECTED,
            mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_CONNECTED),
            200L,
        )
        assertNull(holder.consume())

        holder.recordIfTerminal(
            VpnContract.TUNNEL_STOPPED,
            mapOf(
                VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_STOPPED,
                VpnContract.ARG_TUNNEL_DETAIL to "Stopped",
            ),
            300L,
        )
        holder.recordIfTerminal(
            VpnContract.TUNNEL_FAILED,
            mapOf(
                VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_FAILED,
                VpnContract.ARG_TUNNEL_DETAIL to "Handshake failed",
            ),
            400L,
        )

        val consumed = holder.consume()
        assertEquals(VpnContract.TUNNEL_FAILED, consumed?.get(VpnContract.ARG_TUNNEL_STATE))
        assertEquals("Handshake failed", consumed?.get(VpnContract.ARG_TUNNEL_DETAIL))
        assertEquals(400L, consumed?.get(PendingTerminalHolder.ARG_TIMESTAMP_MS))
        assertNull(holder.consume())
    }
}
