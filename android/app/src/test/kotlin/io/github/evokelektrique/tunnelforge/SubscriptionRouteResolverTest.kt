package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Test

class SubscriptionRouteResolverTest {

    @Test
    fun idleResolvesDirectForExternalVpnOrDefaultNetwork() {
        val route = SubscriptionRouteResolver.resolve(vpnSnapshot = null, proxySnapshot = null)
        assertEquals(SubscriptionContract.ROUTE_DIRECT, route[SubscriptionContract.ARG_ROUTE])
    }

    @Test
    fun vpnConnectedResolvesDirectBecauseAppTrafficUsesTun() {
        val route =
            SubscriptionRouteResolver.resolve(
                vpnSnapshot = mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_CONNECTED),
                proxySnapshot = null,
            )
        assertEquals(SubscriptionContract.ROUTE_DIRECT, route[SubscriptionContract.ARG_ROUTE])
    }

    @Test
    fun vpnRecoveringDefersToAvoidBypassingKillSwitchTun() {
        for (state in listOf(
            VpnContract.TUNNEL_CONNECTING,
            VpnContract.TUNNEL_WAITING_FOR_NETWORK,
            VpnContract.TUNNEL_RECONNECTING,
        )) {
            val route =
                SubscriptionRouteResolver.resolve(
                    vpnSnapshot = mapOf(VpnContract.ARG_TUNNEL_STATE to state),
                    proxySnapshot = null,
                )
            assertEquals(SubscriptionContract.ROUTE_DEFER, route[SubscriptionContract.ARG_ROUTE])
        }
    }

    @Test
    fun proxyConnectedResolvesLocalHttpProxy() {
        val route =
            SubscriptionRouteResolver.resolve(
                vpnSnapshot = null,
                proxySnapshot =
                    mapOf(
                        VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_CONNECTED,
                        VpnContract.ARG_PROXY_EXPOSURE_ACTIVE to true,
                        VpnContract.ARG_PROXY_EXPOSURE_HTTP_PORT to 8123,
                    ),
            )
        assertEquals(SubscriptionContract.ROUTE_LOCAL_HTTP_PROXY, route[SubscriptionContract.ARG_ROUTE])
        assertEquals(ProxyExposureInfo.LOOPBACK, route[SubscriptionContract.ARG_PROXY_HOST])
        assertEquals(8123, route[SubscriptionContract.ARG_PROXY_PORT])
    }

    @Test
    fun proxyConnectingDefers() {
        val route =
            SubscriptionRouteResolver.resolve(
                vpnSnapshot = null,
                proxySnapshot = mapOf(VpnContract.ARG_TUNNEL_STATE to VpnContract.TUNNEL_RECONNECTING),
            )
        assertEquals(SubscriptionContract.ROUTE_DEFER, route[SubscriptionContract.ARG_ROUTE])
    }
}
