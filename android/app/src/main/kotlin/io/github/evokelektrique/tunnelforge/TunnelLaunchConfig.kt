package io.github.evokelektrique.tunnelforge

/** Parsed tunnel launch parameters shared by [MainActivity] and Quick Settings. */
internal data class TunnelLaunchConfig(
    val profileId: String,
    val profileName: String,
    val server: String,
    val user: String,
    val password: String,
    val psk: String,
    val secretsMissing: Boolean,
    val dnsAutomatic: Boolean,
    val dnsServers: List<DnsServerConfig>,
    val mtu: Int?,
    val connectionMode: String,
    val splitTunnelEnabled: Boolean,
    val splitTunnelMode: String,
    val inclusivePackages: List<String>,
    val exclusivePackages: List<String>,
    val proxyHttpPort: Int,
    val proxySocksPort: Int,
    val proxyAllowLan: Boolean,
    val protocol: String = VpnContract.PROTOCOL_L2TP,
    val pppAuth: String = VpnContract.PPP_AUTH_AUTO,
    val mppe: String = VpnContract.MPPE_AUTO,
    val proxyAuthEnabled: Boolean = false,
    val proxyAuthUsername: String = "",
    val proxyAuthPassword: String = "",
) {
    val displayLabel: String
        get() = profileName.ifBlank { server }

    val hasIncompleteProxyAuth: Boolean
        get() = proxyAuthEnabled && (proxyAuthUsername.isBlank() || proxyAuthPassword.isEmpty())

    companion object {
        fun fromMap(
            args: Map<*, *>,
            requireNonBlankServer: Boolean = true,
        ): TunnelLaunchConfig? {
            val rawServer = args[VpnContract.ARG_SERVER] as? String
            val server = rawServer?.trim().orEmpty()
            if (requireNonBlankServer && server.isEmpty()) {
                return null
            }
            val profileId = (args[VpnContract.ARG_PROFILE_ID] as? String)?.trim().orEmpty()
            val profileName = (args[VpnContract.ARG_PROFILE_NAME] as? String)?.trim().orEmpty()
            val user = args[VpnContract.ARG_USER] as? String ?: ""
            val password = args[VpnContract.ARG_PASSWORD] as? String ?: ""
            val psk = args[VpnContract.ARG_PSK] as? String ?: ""
            val secretsMissing = args[VpnContract.ARG_SECRETS_MISSING] as? Boolean ?: false
            val dnsAutomatic = args[VpnContract.ARG_DNS_AUTOMATIC] as? Boolean ?: true
            val dnsServers = parseDnsServers(args[VpnContract.ARG_DNS_SERVERS])
            val mtuRaw = args[VpnContract.ARG_MTU]
            val mtu = TunnelVpnService.sanitizeOptionalMtu(
                when (mtuRaw) {
                    is Int -> mtuRaw
                    is Long -> mtuRaw.toInt()
                    is Number -> mtuRaw.toInt()
                    else -> null
                },
            )
            val connectionMode =
                if ((args[VpnContract.ARG_CONNECTION_MODE] as? String) == VpnContract.MODE_PROXY_ONLY) {
                    VpnContract.MODE_PROXY_ONLY
                } else {
                    VpnContract.MODE_VPN_TUNNEL
                }
            val splitTunnelEnabled = args[VpnContract.ARG_SPLIT_TUNNEL_ENABLED] as? Boolean ?: false
            val splitTunnelMode =
                if ((args[VpnContract.ARG_SPLIT_TUNNEL_MODE] as? String) == VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE) {
                    VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE
                } else {
                    VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE
                }
            val inclusivePackages = parsePackageList(args[VpnContract.ARG_SPLIT_TUNNEL_INCLUSIVE_PACKAGES])
            val exclusivePackages = parsePackageList(args[VpnContract.ARG_SPLIT_TUNNEL_EXCLUSIVE_PACKAGES])
            val protocol =
                if ((args[VpnContract.ARG_PROTOCOL] as? String) == VpnContract.PROTOCOL_PPTP) {
                    VpnContract.PROTOCOL_PPTP
                } else {
                    VpnContract.PROTOCOL_L2TP
                }
            val pppAuth = normalizePppAuth(args[VpnContract.ARG_PPP_AUTH] as? String)
            val mppe =
                if (protocol == VpnContract.PROTOCOL_PPTP) {
                    normalizeMppe(args[VpnContract.ARG_MPPE] as? String)
                } else {
                    VpnContract.MPPE_AUTO
                }
            val proxyHttpPort = sanitizePort(args[VpnContract.ARG_PROXY_HTTP_PORT], ProxyTunnelService.DEFAULT_HTTP_PORT)
            val proxySocksPort = sanitizePort(args[VpnContract.ARG_PROXY_SOCKS_PORT], ProxyTunnelService.DEFAULT_SOCKS_PORT)
            val proxyAllowLan = args[VpnContract.ARG_PROXY_ALLOW_LAN] as? Boolean ?: false
            val proxyAuthEnabled = args[VpnContract.ARG_PROXY_AUTH_ENABLED] as? Boolean ?: false
            val proxyAuthUsername = (args[VpnContract.ARG_PROXY_AUTH_USERNAME] as? String)?.trim().orEmpty()
            val proxyAuthPassword = args[VpnContract.ARG_PROXY_AUTH_PASSWORD] as? String ?: ""
            return TunnelLaunchConfig(
                profileId = profileId,
                profileName = profileName,
                server = server,
                user = user,
                password = password,
                psk = psk,
                secretsMissing = secretsMissing,
                dnsAutomatic = dnsAutomatic,
                dnsServers = dnsServers,
                mtu = mtu,
                connectionMode = connectionMode,
                splitTunnelEnabled = splitTunnelEnabled,
                splitTunnelMode = splitTunnelMode,
                inclusivePackages = inclusivePackages,
                exclusivePackages = exclusivePackages,
                proxyHttpPort = proxyHttpPort,
                proxySocksPort = proxySocksPort,
                proxyAllowLan = proxyAllowLan,
                protocol = protocol,
                pppAuth = pppAuth,
                mppe = mppe,
                proxyAuthEnabled = proxyAuthEnabled,
                proxyAuthUsername = proxyAuthUsername,
                proxyAuthPassword = proxyAuthPassword,
            )
        }

        fun normalizePppAuth(raw: String?): String =
            when (raw?.trim()?.lowercase()) {
                VpnContract.PPP_AUTH_MSCHAPV2 -> VpnContract.PPP_AUTH_MSCHAPV2
                VpnContract.PPP_AUTH_CHAP_MD5 -> VpnContract.PPP_AUTH_CHAP_MD5
                VpnContract.PPP_AUTH_PAP -> VpnContract.PPP_AUTH_PAP
                else -> VpnContract.PPP_AUTH_AUTO
            }

        fun normalizeMppe(raw: String?): String =
            when (raw?.trim()?.lowercase()) {
                VpnContract.MPPE_ON -> VpnContract.MPPE_ON
                VpnContract.MPPE_OFF -> VpnContract.MPPE_OFF
                else -> VpnContract.MPPE_AUTO
            }

        private fun parsePackageList(raw: Any?): List<String> {
            val out = mutableListOf<String>()
            if (raw is List<*>) {
                for (entry in raw) {
                    val value = entry as? String
                    if (!value.isNullOrBlank()) {
                        out.add(value.trim())
                    }
                }
            }
            return out
        }

        private fun sanitizePort(raw: Any?, fallback: Int): Int {
            val candidate =
                when (raw) {
                    is Int -> raw
                    is Long -> raw.toInt()
                    is Number -> raw.toInt()
                    else -> fallback
                }
            return ProxyPortAllocator.sanitizePort(candidate, fallback)
        }

        private fun parseDnsServers(raw: Any?): List<DnsServerConfig> {
            val out = mutableListOf<DnsServerConfig>()
            if (raw is List<*>) {
                for (entry in raw) {
                    val map = entry as? Map<*, *> ?: continue
                    val host = (map[VpnContract.ARG_DNS_SERVER_HOST] as? String)?.trim().orEmpty()
                    val protocol = DnsProtocol.fromWireValue(map[VpnContract.ARG_DNS_SERVER_PROTOCOL] as? String)
                    out += DnsServerConfig(host = host, protocol = protocol)
                }
            }
            return DnsConfigSupport.sanitize(out)
        }
    }
}
