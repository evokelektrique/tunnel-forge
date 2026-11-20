package io.github.evokelektrique.tunnelforge

/**
 * Resolves how subscription HTTP requests should be routed so they always traverse
 * TunnelForge's active tunnel (VPN TUN or local HTTP proxy) or any active external VPN.
 */
internal object SubscriptionRouteResolver {
    fun resolveCurrent(): Map<String, Any?> =
        resolve(
            vpnSnapshot = TunnelVpnService.runtimeSnapshot(),
            proxySnapshot = ProxyTunnelService.runtimeSnapshot(),
        )

    internal fun resolve(
        vpnSnapshot: Map<String, Any?>?,
        proxySnapshot: Map<String, Any?>?,
    ): Map<String, Any?> {
        if (vpnSnapshot != null) {
            val state = vpnSnapshot[VpnContract.ARG_TUNNEL_STATE] as? String
            return when (state) {
                VpnContract.TUNNEL_CONNECTED ->
                    // TunnelForge never excludes itself from its live TUN, so direct traffic goes via VPN.
                    mapOf(SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DIRECT)
                VpnContract.TUNNEL_CONNECTING,
                VpnContract.TUNNEL_WAITING_FOR_NETWORK,
                VpnContract.TUNNEL_RECONNECTING,
                ->
                    mapOf(
                        SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DEFER,
                        SubscriptionContract.ARG_REASON to "TunnelForge VPN tunnel is $state",
                    )
                else ->
                    mapOf(SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DIRECT)
            }
        }

        if (proxySnapshot != null) {
            val state = proxySnapshot[VpnContract.ARG_TUNNEL_STATE] as? String
            return when (state) {
                VpnContract.TUNNEL_CONNECTED -> {
                    val active = proxySnapshot[VpnContract.ARG_PROXY_EXPOSURE_ACTIVE] == true
                    val httpPort = (proxySnapshot[VpnContract.ARG_PROXY_EXPOSURE_HTTP_PORT] as? Number)?.toInt()
                    if (active && httpPort != null && ProxyPortAllocator.isAllowedPort(httpPort)) {
                        mapOf(
                            SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_LOCAL_HTTP_PROXY,
                            SubscriptionContract.ARG_PROXY_HOST to ProxyExposureInfo.LOOPBACK,
                            SubscriptionContract.ARG_PROXY_PORT to httpPort,
                        )
                    } else {
                        mapOf(
                            SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DEFER,
                            SubscriptionContract.ARG_REASON to "Local proxy listener port is not ready",
                        )
                    }
                }
                VpnContract.TUNNEL_CONNECTING,
                VpnContract.TUNNEL_WAITING_FOR_NETWORK,
                VpnContract.TUNNEL_RECONNECTING,
                ->
                    mapOf(
                        SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DEFER,
                        SubscriptionContract.ARG_REASON to "TunnelForge local proxy is $state",
                    )
                else ->
                    mapOf(SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DIRECT)
            }
        }

        // Idle: default Android network routes automatically through any active external VPN.
        return mapOf(SubscriptionContract.ARG_ROUTE to SubscriptionContract.ROUTE_DIRECT)
    }
}
