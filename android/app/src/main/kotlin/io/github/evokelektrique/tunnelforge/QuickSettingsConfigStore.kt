package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal interface QuickSettingsKeyValueStore {
    fun getString(key: String): String?
    fun getBoolean(key: String, defaultValue: Boolean): Boolean
    fun getInt(key: String, defaultValue: Int): Int
    fun edit(block: Editor.() -> Unit)

    interface Editor {
        fun putString(key: String, value: String)
        fun putBoolean(key: String, value: Boolean)
        fun putInt(key: String, value: Int)
        fun clear()
    }
}

internal class SharedPrefsQuickSettingsStore(
    private val prefs: SharedPreferences,
) : QuickSettingsKeyValueStore {
    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun getBoolean(key: String, defaultValue: Boolean): Boolean =
        prefs.getBoolean(key, defaultValue)

    override fun getInt(key: String, defaultValue: Int): Int =
        prefs.getInt(key, defaultValue)

    override fun edit(block: QuickSettingsKeyValueStore.Editor.() -> Unit) {
        val editor = prefs.edit()
        val wrapper =
            object : QuickSettingsKeyValueStore.Editor {
                override fun putString(key: String, value: String) {
                    editor.putString(key, value)
                }

                override fun putBoolean(key: String, value: Boolean) {
                    editor.putBoolean(key, value)
                }

                override fun putInt(key: String, value: Int) {
                    editor.putInt(key, value)
                }

                override fun clear() {
                    editor.clear()
                }
            }
        wrapper.block()
        editor.apply()
    }
}

internal interface QuickSettingsSecretCipher {
    fun encrypt(plaintext: ByteArray): String
    fun decrypt(encoded: String): ByteArray?
}

internal class AndroidKeystoreSecretCipher(
    private val keyAlias: String = KEY_ALIAS,
) : QuickSettingsSecretCipher {
    override fun encrypt(plaintext: ByteArray): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(plaintext)
        val combined = ByteArray(1 + iv.size + ciphertext.size)
        combined[0] = iv.size.toByte()
        System.arraycopy(iv, 0, combined, 1, iv.size)
        System.arraycopy(ciphertext, 0, combined, 1 + iv.size, ciphertext.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    override fun decrypt(encoded: String): ByteArray? {
        return try {
            val combined = Base64.decode(encoded, Base64.NO_WRAP)
            if (combined.size < 2) return null
            val ivLength = combined[0].toInt() and 0xFF
            if (ivLength <= 0 || combined.size <= 1 + ivLength) return null
            val iv = combined.copyOfRange(1, 1 + ivLength)
            val ciphertext = combined.copyOfRange(1 + ivLength, combined.size)
            val key = getExistingKey() ?: return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_BITS, iv))
            cipher.doFinal(ciphertext)
        } catch (_: Exception) {
            null
        }
    }

    private fun getExistingKey(): SecretKey? {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        return keyStore.getKey(keyAlias, null) as? SecretKey
    }

    private fun getOrCreateKey(): SecretKey {
        getExistingKey()?.let { return it }
        val keyGenerator =
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec =
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val KEY_ALIAS = "tunnelforge_qs_key_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
    }
}

/** Persists the current profile and global settings for Quick Settings tile access. */
internal class QuickSettingsConfigStore(
    private val store: QuickSettingsKeyValueStore,
    private val cipher: QuickSettingsSecretCipher,
) {
    fun save(config: TunnelLaunchConfig?) {
        if (config == null || config.server.isBlank()) {
            clear()
            return
        }
        val encryptedSecrets =
            try {
                cipher.encrypt(encodeSecrets(config.password, config.psk))
            } catch (e: Exception) {
                AppLog.e(TAG, "Failed to encrypt Quick Settings secrets", e)
                null
            }
        val encryptedProxyAuthPassword =
            if (config.proxyAuthPassword.isEmpty()) {
                null
            } else {
                try {
                    cipher.encrypt(config.proxyAuthPassword.toByteArray(StandardCharsets.UTF_8))
                } catch (e: Exception) {
                    AppLog.e(TAG, "Failed to encrypt Quick Settings proxy auth password", e)
                    null
                }
            }
        val secretsMissing = config.secretsMissing || encryptedSecrets == null
        val dns1 = config.dnsServers.getOrNull(0)
        val dns2 = config.dnsServers.getOrNull(1)
        store.edit {
            clear()
            putInt(KEY_SCHEMA_VERSION, SCHEMA_VERSION)
            putBoolean(KEY_HAS_CONFIG, true)
            putString(KEY_PROFILE_ID, config.profileId)
            putString(KEY_PROFILE_NAME, config.profileName)
            putString(KEY_SERVER, config.server)
            putString(KEY_USER, config.user)
            if (encryptedSecrets != null) {
                putString(KEY_SECRETS, encryptedSecrets)
            }
            putBoolean(KEY_SECRETS_MISSING, secretsMissing)
            putBoolean(KEY_DNS_AUTOMATIC, config.dnsAutomatic)
            putString(KEY_DNS1_HOST, dns1?.host.orEmpty())
            putString(KEY_DNS1_PROTOCOL, dns1?.protocol?.wireValue.orEmpty())
            putString(KEY_DNS2_HOST, dns2?.host.orEmpty())
            putString(KEY_DNS2_PROTOCOL, dns2?.protocol?.wireValue.orEmpty())
            putInt(KEY_MTU, config.mtu ?: TunnelVpnService.AUTO_TUN_MTU)
            putString(KEY_PROTOCOL, config.protocol)
            putString(KEY_PPP_AUTH, config.pppAuth)
            putString(KEY_MPPE, config.mppe)
            putBoolean(
                KEY_FORCE_USERSPACE_VPN,
                config.protocol != VpnContract.PROTOCOL_PPTP && config.forceUserspaceVpn,
            )
            putString(KEY_CONNECTION_MODE, config.connectionMode)
            putBoolean(KEY_SPLIT_TUNNEL_ENABLED, config.splitTunnelEnabled)
            putString(KEY_SPLIT_TUNNEL_MODE, config.splitTunnelMode)
            putString(KEY_SPLIT_TUNNEL_INCLUSIVE, config.inclusivePackages.joinToString("\n"))
            putString(KEY_SPLIT_TUNNEL_EXCLUSIVE, config.exclusivePackages.joinToString("\n"))
            putInt(KEY_PROXY_HTTP_PORT, config.proxyHttpPort)
            putInt(KEY_PROXY_SOCKS_PORT, config.proxySocksPort)
            putBoolean(KEY_PROXY_ALLOW_LAN, config.proxyAllowLan)
            putBoolean(KEY_PROXY_AUTH_ENABLED, config.proxyAuthEnabled)
            putString(KEY_PROXY_AUTH_USERNAME, config.proxyAuthUsername)
            if (encryptedProxyAuthPassword != null) {
                putString(KEY_PROXY_AUTH_PASSWORD, encryptedProxyAuthPassword)
            }
        }
    }

    fun load(): TunnelLaunchConfig? {
        if (store.getInt(KEY_SCHEMA_VERSION, 0) != SCHEMA_VERSION ||
            !store.getBoolean(KEY_HAS_CONFIG, false)
        ) {
            return null
        }
        val server = store.getString(KEY_SERVER)?.trim().orEmpty()
        if (server.isEmpty()) return null
        val encryptedSecrets = store.getString(KEY_SECRETS)
        val decodedSecrets =
            encryptedSecrets?.let { encoded ->
                cipher.decrypt(encoded)?.let(::decodeSecrets)
            }
        val secretsMissing =
            store.getBoolean(KEY_SECRETS_MISSING, false) || decodedSecrets == null
        val dnsServers =
            DnsConfigSupport.sanitize(
                listOfNotNull(
                    readDnsEntry(KEY_DNS1_HOST, KEY_DNS1_PROTOCOL),
                    readDnsEntry(KEY_DNS2_HOST, KEY_DNS2_PROTOCOL),
                ),
            )
        val protocol =
            if (store.getString(KEY_PROTOCOL) == VpnContract.PROTOCOL_PPTP) {
                VpnContract.PROTOCOL_PPTP
            } else {
                VpnContract.PROTOCOL_L2TP
            }
        val pppAuth = TunnelLaunchConfig.normalizePppAuth(store.getString(KEY_PPP_AUTH))
        val mppe =
            if (protocol == VpnContract.PROTOCOL_PPTP) {
                TunnelLaunchConfig.normalizeMppe(store.getString(KEY_MPPE))
            } else {
                VpnContract.MPPE_AUTO
            }
        val forceUserspaceVpn =
            protocol != VpnContract.PROTOCOL_PPTP &&
                store.getBoolean(KEY_FORCE_USERSPACE_VPN, false)
        val connectionMode =
            if (store.getString(KEY_CONNECTION_MODE) == VpnContract.MODE_PROXY_ONLY) {
                VpnContract.MODE_PROXY_ONLY
            } else {
                VpnContract.MODE_VPN_TUNNEL
            }
        val splitTunnelMode =
            if (store.getString(KEY_SPLIT_TUNNEL_MODE) == VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE) {
                VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE
            } else {
                VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE
            }
        val encryptedProxyAuth = store.getString(KEY_PROXY_AUTH_PASSWORD)
        val decodedProxyAuthPassword =
            encryptedProxyAuth?.let { encoded ->
                cipher.decrypt(encoded)?.let { String(it, StandardCharsets.UTF_8) }
            }.orEmpty()
        return TunnelLaunchConfig(
            profileId = store.getString(KEY_PROFILE_ID).orEmpty(),
            profileName = store.getString(KEY_PROFILE_NAME).orEmpty(),
            server = server,
            user = store.getString(KEY_USER).orEmpty(),
            password = decodedSecrets?.first.orEmpty(),
            psk = decodedSecrets?.second.orEmpty(),
            secretsMissing = secretsMissing,
            dnsAutomatic = store.getBoolean(KEY_DNS_AUTOMATIC, true),
            dnsServers = dnsServers,
            mtu = TunnelVpnService.sanitizeOptionalMtu(
                store.getInt(KEY_MTU, TunnelVpnService.AUTO_TUN_MTU),
            ),
            connectionMode = connectionMode,
            splitTunnelEnabled = store.getBoolean(KEY_SPLIT_TUNNEL_ENABLED, false),
            splitTunnelMode = splitTunnelMode,
            inclusivePackages = readPackageList(KEY_SPLIT_TUNNEL_INCLUSIVE),
            exclusivePackages = readPackageList(KEY_SPLIT_TUNNEL_EXCLUSIVE),
            proxyHttpPort = ProxyPortAllocator.sanitizePort(
                store.getInt(KEY_PROXY_HTTP_PORT, ProxyTunnelService.DEFAULT_HTTP_PORT),
                ProxyTunnelService.DEFAULT_HTTP_PORT,
            ),
            proxySocksPort = ProxyPortAllocator.sanitizePort(
                store.getInt(KEY_PROXY_SOCKS_PORT, ProxyTunnelService.DEFAULT_SOCKS_PORT),
                ProxyTunnelService.DEFAULT_SOCKS_PORT,
            ),
            proxyAllowLan = store.getBoolean(KEY_PROXY_ALLOW_LAN, false),
            protocol = protocol,
            pppAuth = pppAuth,
            mppe = mppe,
            forceUserspaceVpn = forceUserspaceVpn,
            proxyAuthEnabled = store.getBoolean(KEY_PROXY_AUTH_ENABLED, false),
            proxyAuthUsername = store.getString(KEY_PROXY_AUTH_USERNAME).orEmpty(),
            proxyAuthPassword = decodedProxyAuthPassword,
        )
    }

    fun clear() {
        store.edit { clear() }
    }

    private fun readDnsEntry(hostKey: String, protocolKey: String): DnsServerConfig? {
        val host = store.getString(hostKey)?.trim().orEmpty()
        if (host.isEmpty()) return null
        val protocol = DnsProtocol.fromWireValue(store.getString(protocolKey))
        return DnsServerConfig(host = host, protocol = protocol)
    }

    private fun readPackageList(key: String): List<String> {
        val raw = store.getString(key).orEmpty()
        if (raw.isEmpty()) return emptyList()
        return raw.split('\n').map { it.trim() }.filter { it.isNotEmpty() }
    }

    private fun encodeSecrets(password: String, psk: String): ByteArray {
        val passwordBytes = password.toByteArray(StandardCharsets.UTF_8)
        val pskBytes = psk.toByteArray(StandardCharsets.UTF_8)
        val out = ByteArrayOutputStream(8 + passwordBytes.size + pskBytes.size)
        DataOutputStream(out).use { data ->
            data.writeInt(passwordBytes.size)
            data.write(passwordBytes)
            data.writeInt(pskBytes.size)
            data.write(pskBytes)
        }
        return out.toByteArray()
    }

    private fun decodeSecrets(bytes: ByteArray): Pair<String, String>? {
        return try {
            DataInputStream(ByteArrayInputStream(bytes)).use { data ->
                val passwordLen = data.readInt()
                if (passwordLen < 0 || passwordLen > MAX_SECRET_BYTES) return null
                val passwordBytes = ByteArray(passwordLen)
                data.readFully(passwordBytes)
                val pskLen = data.readInt()
                if (pskLen < 0 || pskLen > MAX_SECRET_BYTES) return null
                val pskBytes = ByteArray(pskLen)
                data.readFully(pskBytes)
                String(passwordBytes, StandardCharsets.UTF_8) to
                    String(pskBytes, StandardCharsets.UTF_8)
            }
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val TAG = "QuickSettingsStore"
        private const val PREFS_NAME = "tunnelforge_quick_settings_v1"
        private const val SCHEMA_VERSION = 1
        private const val MAX_SECRET_BYTES = 16 * 1024

        private const val KEY_SCHEMA_VERSION = "schema_version"
        private const val KEY_HAS_CONFIG = "has_config"
        private const val KEY_PROFILE_ID = "profile_id"
        private const val KEY_PROFILE_NAME = "profile_name"
        private const val KEY_SERVER = "server"
        private const val KEY_USER = "user"
        private const val KEY_SECRETS = "secrets"
        private const val KEY_SECRETS_MISSING = "secrets_missing"
        private const val KEY_DNS_AUTOMATIC = "dns_automatic"
        private const val KEY_DNS1_HOST = "dns1_host"
        private const val KEY_DNS1_PROTOCOL = "dns1_protocol"
        private const val KEY_DNS2_HOST = "dns2_host"
        private const val KEY_DNS2_PROTOCOL = "dns2_protocol"
        private const val KEY_MTU = "mtu"
        private const val KEY_PROTOCOL = "protocol"
        private const val KEY_PPP_AUTH = "ppp_auth"
        private const val KEY_MPPE = "mppe"
        private const val KEY_FORCE_USERSPACE_VPN = "force_userspace_vpn"
        private const val KEY_CONNECTION_MODE = "connection_mode"
        private const val KEY_SPLIT_TUNNEL_ENABLED = "split_tunnel_enabled"
        private const val KEY_SPLIT_TUNNEL_MODE = "split_tunnel_mode"
        private const val KEY_SPLIT_TUNNEL_INCLUSIVE = "split_tunnel_inclusive"
        private const val KEY_SPLIT_TUNNEL_EXCLUSIVE = "split_tunnel_exclusive"
        private const val KEY_PROXY_HTTP_PORT = "proxy_http_port"
        private const val KEY_PROXY_SOCKS_PORT = "proxy_socks_port"
        private const val KEY_PROXY_ALLOW_LAN = "proxy_allow_lan"
        private const val KEY_PROXY_AUTH_ENABLED = "proxy_auth_enabled"
        private const val KEY_PROXY_AUTH_USERNAME = "proxy_auth_username"
        private const val KEY_PROXY_AUTH_PASSWORD = "proxy_auth_password"

        fun create(context: Context): QuickSettingsConfigStore {
            val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return QuickSettingsConfigStore(
                store = SharedPrefsQuickSettingsStore(prefs),
                cipher = AndroidKeystoreSecretCipher(),
            )
        }
    }
}
