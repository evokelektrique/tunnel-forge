package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class QuickSettingsConfigStoreTest {

    private class InMemoryKeyValueStore : QuickSettingsKeyValueStore {
        val values = linkedMapOf<String, Any?>()

        override fun getString(key: String): String? = values[key] as? String

        override fun getBoolean(key: String, defaultValue: Boolean): Boolean =
            values[key] as? Boolean ?: defaultValue

        override fun getInt(key: String, defaultValue: Int): Int =
            values[key] as? Int ?: defaultValue

        override fun edit(block: QuickSettingsKeyValueStore.Editor.() -> Unit) {
            val pending = LinkedHashMap(values)
            var cleared = false
            val editor =
                object : QuickSettingsKeyValueStore.Editor {
                    override fun putString(key: String, value: String) {
                        pending[key] = value
                    }

                    override fun putBoolean(key: String, value: Boolean) {
                        pending[key] = value
                    }

                    override fun putInt(key: String, value: Int) {
                        pending[key] = value
                    }

                    override fun clear() {
                        cleared = true
                        pending.clear()
                    }
                }
            editor.block()
            if (cleared) {
                values.clear()
            }
            values.putAll(pending)
        }
    }

    private class XorTestCipher : QuickSettingsSecretCipher {
        override fun encrypt(plaintext: ByteArray): String {
            val out = ByteArray(plaintext.size) { idx -> (plaintext[idx].toInt() xor 0x5A).toByte() }
            return java.util.Base64.getEncoder().encodeToString(out)
        }

        override fun decrypt(encoded: String): ByteArray? {
            return runCatching {
                val decoded = java.util.Base64.getDecoder().decode(encoded)
                ByteArray(decoded.size) { idx -> (decoded[idx].toInt() xor 0x5A).toByte() }
            }.getOrNull()
        }
    }

    @Test
    fun roundTripsProfileAndGlobalSettings() {
        val backing = InMemoryKeyValueStore()
        val store = QuickSettingsConfigStore(backing, XorTestCipher())

        val input =
            TunnelLaunchConfig(
                profileId = "profile-1",
                profileName = "Office VPN",
                server = "vpn.office.example",
                user = "alice",
                password = "secret-password",
                psk = "secret-psk",
                secretsMissing = false,
                dnsAutomatic = false,
                dnsServers =
                    listOf(
                        DnsServerConfig("one.one.one.one", DnsProtocol.dnsOverTls),
                        DnsServerConfig("9.9.9.9", DnsProtocol.dnsOverUdp),
                    ),
                mtu = 1380,
                connectionMode = VpnContract.MODE_PROXY_ONLY,
                splitTunnelEnabled = true,
                splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE,
                inclusivePackages = listOf("com.example.one"),
                exclusivePackages = listOf("com.example.two", "com.example.three"),
                proxyHttpPort = 8888,
                proxySocksPort = 1888,
                proxyAllowLan = true,
                protocol = VpnContract.PROTOCOL_PPTP,
                pppAuth = VpnContract.PPP_AUTH_MSCHAPV2,
                mppe = VpnContract.MPPE_ON,
            )

        store.save(input)
        val rawStored = backing.values.values.joinToString("|")
        assertFalse(rawStored.contains("secret-password"))
        assertFalse(rawStored.contains("secret-psk"))

        val loaded = store.load()
        assertNotNull(loaded)
        assertEquals(input, loaded)
    }

    @Test
    fun missingStoredProtocolDefaultsToL2tp() {
        val backing = InMemoryKeyValueStore()
        val store = QuickSettingsConfigStore(backing, XorTestCipher())
        store.save(
            TunnelLaunchConfig(
                profileId = "p-legacy",
                profileName = "Legacy",
                server = "legacy.example",
                user = "bob",
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
                protocol = VpnContract.PROTOCOL_PPTP,
            ),
        )
        backing.values.remove("protocol")

        val loaded = store.load()
        assertNotNull(loaded)
        assertEquals(VpnContract.PROTOCOL_L2TP, loaded!!.protocol)
        assertEquals(VpnContract.PPP_AUTH_AUTO, loaded.pppAuth)
        assertEquals(VpnContract.MPPE_AUTO, loaded.mppe)
    }

    @Test
    fun marksSecretsMissingWhenCipherFailsToDecrypt() {
        val backing = InMemoryKeyValueStore()
        val store = QuickSettingsConfigStore(backing, XorTestCipher())

        store.save(
            TunnelLaunchConfig(
                profileId = "p1",
                profileName = "Home",
                server = "home.example",
                user = "bob",
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
            ),
        )

        val brokenCipherStore =
            QuickSettingsConfigStore(
                backing,
                object : QuickSettingsSecretCipher {
                    override fun encrypt(plaintext: ByteArray): String = ""
                    override fun decrypt(encoded: String): ByteArray? = null
                },
            )
        val loaded = brokenCipherStore.load()
        assertNotNull(loaded)
        assertTrue(loaded!!.secretsMissing)
        assertEquals("", loaded.password)
        assertEquals("", loaded.psk)
    }

    @Test
    fun savingNullClearsStore() {
        val backing = InMemoryKeyValueStore()
        val store = QuickSettingsConfigStore(backing, XorTestCipher())
        store.save(
            TunnelLaunchConfig(
                profileId = "p1",
                profileName = "Home",
                server = "home.example",
                user = "bob",
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
            ),
        )
        assertNotNull(store.load())

        store.save(null)
        assertNull(store.load())
    }

    @Test
    fun roundTripsNullMtuAsAuto() {
        val backing = InMemoryKeyValueStore()
        val store = QuickSettingsConfigStore(backing, XorTestCipher())
        val input =
            TunnelLaunchConfig(
                profileId = "p-auto-mtu",
                profileName = "Auto MTU",
                server = "auto.example",
                user = "alice",
                password = "pw",
                psk = "psk",
                secretsMissing = false,
                dnsAutomatic = true,
                dnsServers = emptyList(),
                mtu = null,
                connectionMode = VpnContract.MODE_VPN_TUNNEL,
                splitTunnelEnabled = false,
                splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE,
                inclusivePackages = emptyList(),
                exclusivePackages = emptyList(),
                proxyHttpPort = ProxyTunnelService.DEFAULT_HTTP_PORT,
                proxySocksPort = ProxyTunnelService.DEFAULT_SOCKS_PORT,
                proxyAllowLan = false,
            )

        store.save(input)
        assertEquals(TunnelVpnService.AUTO_TUN_MTU, backing.values["mtu"])
        val loaded = store.load()
        assertNotNull(loaded)
        assertNull(loaded!!.mtu)
        assertEquals(input, loaded)
    }

    @Test
    fun launchConfigFromMapParsesOptionalMtu() {
        val autoConfig = TunnelLaunchConfig.fromMap(mapOf(VpnContract.ARG_SERVER to "vpn.example"))
        assertNotNull(autoConfig)
        assertNull(autoConfig!!.mtu)

        val zeroConfig =
            TunnelLaunchConfig.fromMap(
                mapOf(
                    VpnContract.ARG_SERVER to "vpn.example",
                    VpnContract.ARG_MTU to 0,
                ),
            )
        assertNotNull(zeroConfig)
        assertNull(zeroConfig!!.mtu)

        val explicitConfig =
            TunnelLaunchConfig.fromMap(
                mapOf(
                    VpnContract.ARG_SERVER to "vpn.example",
                    VpnContract.ARG_MTU to 1400,
                ),
            )
        assertNotNull(explicitConfig)
        assertEquals(1400, explicitConfig!!.mtu)
    }
}
