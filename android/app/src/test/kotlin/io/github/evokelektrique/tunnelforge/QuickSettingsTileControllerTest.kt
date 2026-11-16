package io.github.evokelektrique.tunnelforge

import android.service.quicksettings.Tile
import org.junit.Assert.assertEquals
import org.junit.Test

class QuickSettingsTileControllerTest {

    private val strings =
        QuickSettingsStrings(
            defaultLabel = "TunnelForge",
            noProfile = "No profile selected",
            connected = "Connected",
            connecting = "Connecting...",
            waitingForNetwork = "Waiting for network",
            reconnecting = "Reconnecting...",
        )

    private fun sampleConfig(name: String = "Office"): TunnelLaunchConfig =
        TunnelLaunchConfig(
            profileId = "p1",
            profileName = name,
            server = "vpn.example",
            user = "alice",
            password = "pw",
            psk = "psk",
            secretsMissing = false,
            dnsAutomatic = true,
            dnsServers = emptyList(),
            mtu = TunnelVpnService.DEFAULT_TUN_MTU,
            connectionMode = VpnContract.MODE_VPN_TUNNEL,
            splitTunnelEnabled = false,
            splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE,
            inclusivePackages = emptyList(),
            exclusivePackages = emptyList(),
            proxyHttpPort = ProxyTunnelService.DEFAULT_HTTP_PORT,
            proxySocksPort = ProxyTunnelService.DEFAULT_SOCKS_PORT,
            proxyAllowLan = false,
        )

    @Test
    fun unavailableWhenIdleWithNoProfile() {
        val presentation =
            QuickSettingsTileController.resolvePresentation(
                runtimeSnapshot = null,
                storedConfig = null,
                strings = strings,
            )
        assertEquals(Tile.STATE_UNAVAILABLE, presentation.state)
        assertEquals("TunnelForge", presentation.label)
        assertEquals("No profile selected", presentation.subtitle)
    }

    @Test
    fun inactiveWithProfileNameWhenIdle() {
        val presentation =
            QuickSettingsTileController.resolvePresentation(
                runtimeSnapshot = null,
                storedConfig = sampleConfig("Tokyo"),
                strings = strings,
            )
        assertEquals(Tile.STATE_INACTIVE, presentation.state)
        assertEquals("Tokyo", presentation.subtitle)
    }

    @Test
    fun activeForConnectedAndConnectingStates() {
        val connected =
            QuickSettingsTileController.resolvePresentation(
                runtimeSnapshot = mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_CONNECTED),
                storedConfig = sampleConfig("Tokyo"),
                strings = strings,
            )
        assertEquals(Tile.STATE_ACTIVE, connected.state)
        assertEquals("Tokyo", connected.subtitle)
        assertEquals("Connected · Tokyo", connected.stateDescription)

        val reconnecting =
            QuickSettingsTileController.resolvePresentation(
                runtimeSnapshot = mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_RECONNECTING),
                storedConfig = sampleConfig(""),
                strings = strings,
            )
        assertEquals(Tile.STATE_ACTIVE, reconnecting.state)
        assertEquals("vpn.example", reconnecting.subtitle)
        assertEquals("Reconnecting... · vpn.example", reconnecting.stateDescription)
    }
}
