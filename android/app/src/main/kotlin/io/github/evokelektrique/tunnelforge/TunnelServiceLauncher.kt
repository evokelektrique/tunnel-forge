package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.content.Intent
import android.os.Build

/** Shared builder and foreground-service dispatcher for VPN and local-proxy sessions. */
internal object TunnelServiceLauncher {
    fun buildStartIntent(
        context: Context,
        config: TunnelLaunchConfig,
        attemptId: String,
    ): Intent {
        return if (config.connectionMode == VpnContract.MODE_PROXY_ONLY) {
            Intent(context, ProxyTunnelService::class.java).apply {
                action = ProxyTunnelService.ACTION_START
                putExtra(ProxyTunnelService.EXTRA_ATTEMPT_ID, attemptId)
                putExtra(ProxyTunnelService.EXTRA_SERVER, config.server)
                putExtra(ProxyTunnelService.EXTRA_USER, config.user)
                putExtra(ProxyTunnelService.EXTRA_PASSWORD, config.password)
                putExtra(ProxyTunnelService.EXTRA_PSK, config.psk)
                putExtra(ProxyTunnelService.EXTRA_PROTOCOL, config.protocol)
                putExtra(ProxyTunnelService.EXTRA_DNS_AUTOMATIC, config.dnsAutomatic)
                putDnsServerExtras(this, config.dnsServers)
                putExtra(ProxyTunnelService.EXTRA_MTU, config.mtu)
                putExtra(ProxyTunnelService.EXTRA_PROFILE_NAME, config.profileName)
                putExtra(ProxyTunnelService.EXTRA_PROXY_HTTP_PORT, config.proxyHttpPort)
                putExtra(ProxyTunnelService.EXTRA_PROXY_SOCKS_PORT, config.proxySocksPort)
                putExtra(ProxyTunnelService.EXTRA_PROXY_ALLOW_LAN, config.proxyAllowLan)
            }
        } else {
            Intent(context, TunnelVpnService::class.java).apply {
                action = TunnelVpnService.ACTION_START
                putExtra(TunnelVpnService.EXTRA_ATTEMPT_ID, attemptId)
                putExtra(TunnelVpnService.EXTRA_SERVER, config.server)
                putExtra(TunnelVpnService.EXTRA_USER, config.user)
                putExtra(TunnelVpnService.EXTRA_PASSWORD, config.password)
                putExtra(TunnelVpnService.EXTRA_PSK, config.psk)
                putExtra(TunnelVpnService.EXTRA_PROTOCOL, config.protocol)
                putExtra(TunnelVpnService.EXTRA_DNS_AUTOMATIC, config.dnsAutomatic)
                putDnsServerExtras(this, config.dnsServers)
                putExtra(TunnelVpnService.EXTRA_MTU, config.mtu)
                putExtra(TunnelVpnService.EXTRA_PROFILE_NAME, config.profileName)
                putExtra(TunnelVpnService.EXTRA_SPLIT_TUNNEL_ENABLED, config.splitTunnelEnabled)
                putExtra(TunnelVpnService.EXTRA_SPLIT_TUNNEL_MODE, config.splitTunnelMode)
                putExtra(TunnelVpnService.EXTRA_PROXY_HTTP_PORT, config.proxyHttpPort)
                putExtra(TunnelVpnService.EXTRA_PROXY_SOCKS_PORT, config.proxySocksPort)
                putExtra(TunnelVpnService.EXTRA_PROXY_ALLOW_LAN, config.proxyAllowLan)
                putStringArrayListExtra(
                    TunnelVpnService.EXTRA_SPLIT_TUNNEL_INCLUSIVE_PACKAGES,
                    ArrayList(config.inclusivePackages),
                )
                putStringArrayListExtra(
                    TunnelVpnService.EXTRA_SPLIT_TUNNEL_EXCLUSIVE_PACKAGES,
                    ArrayList(config.exclusivePackages),
                )
            }
        }
    }

    fun prepareForStart(connectionMode: String) {
        val cleanupTargets = VpnConnectModeSwitchPolicy.cleanupTargetsForStart(connectionMode)
        if (cleanupTargets.stopVpn) {
            TunnelVpnService.stopActiveSessionForModeSwitch("starting $connectionMode")
        }
        if (cleanupTargets.stopProxy) {
            ProxyTunnelService.stopActiveSessionForModeSwitch("starting $connectionMode")
        }
    }

    fun startForegroundWorkerService(context: Context, intent: Intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(intent)
        } else {
            context.startService(intent)
        }
    }

    fun stop(
        context: Context,
        connectionMode: String?,
        attemptId: String = "",
    ) {
        val targets = VpnDisconnectDispatchPolicy.targetsForConnectionMode(connectionMode)
        if (targets.stopVpn) {
            context.startService(
                Intent(context, TunnelVpnService::class.java).apply {
                    action = TunnelVpnService.ACTION_STOP
                    if (attemptId.isNotEmpty()) {
                        putExtra(TunnelVpnService.EXTRA_ATTEMPT_ID, attemptId)
                    }
                },
            )
        }
        if (targets.stopProxy) {
            context.startService(
                Intent(context, ProxyTunnelService::class.java).apply {
                    action = ProxyTunnelService.ACTION_STOP
                    if (attemptId.isNotEmpty()) {
                        putExtra(ProxyTunnelService.EXTRA_ATTEMPT_ID, attemptId)
                    }
                },
            )
        }
    }

    private fun putDnsServerExtras(intent: Intent, dnsServers: List<DnsServerConfig>) {
        val dns1 = dnsServers.getOrNull(0)
        val dns2 = dnsServers.getOrNull(1)
        intent.putExtra(TunnelVpnService.EXTRA_DNS_SERVER_1_HOST, dns1?.host ?: "")
        intent.putExtra(
            TunnelVpnService.EXTRA_DNS_SERVER_1_PROTOCOL,
            dns1?.protocol?.wireValue ?: DnsProtocol.dnsOverUdp.wireValue,
        )
        intent.putExtra(TunnelVpnService.EXTRA_DNS_SERVER_2_HOST, dns2?.host ?: "")
        intent.putExtra(
            TunnelVpnService.EXTRA_DNS_SERVER_2_PROTOCOL,
            dns2?.protocol?.wireValue ?: DnsProtocol.dnsOverUdp.wireValue,
        )
    }
}
