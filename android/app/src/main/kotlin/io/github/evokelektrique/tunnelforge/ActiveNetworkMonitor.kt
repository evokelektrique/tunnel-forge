package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.ParcelFileDescriptor
import android.util.Log
import java.net.Inet4Address
import java.net.Inet6Address
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

internal enum class NetworkTransitionEvent {
    NONE,
    GAINED_USABLE_NETWORK,
    ACTIVE_NETWORK_SWITCHED,
    ALL_NETWORKS_LOST,
}

internal enum class TransportTier(val priority: Int) {
    OTHER(1),
    CELLULAR(2),
    WIFI(3),
    ETHERNET(4),
}

/**
 * Pure JVM state machine tracking underlying non-VPN physical networks.
 * Emits switch events only once connected or recovering when the preferred physical route changes.
 */
internal class PhysicalNetworkTracker {
    private val networks = LinkedHashMap<Long, TransportTier>()
    private var activeHandle: Long? = null
    private var connected = false

    @Synchronized
    fun hasUsableNetwork(): Boolean = networks.isNotEmpty()

    @Synchronized
    fun preferredHandle(): Long? = activeHandle ?: selectPreferredHandle()

    @Synchronized
    fun markConnected() {
        connected = true
        if (activeHandle == null || !networks.containsKey(activeHandle)) {
            activeHandle = selectPreferredHandle()
        }
    }

    @Synchronized
    fun resetConnected() {
        connected = false
    }

    @Synchronized
    fun onNetworkAvailable(
        handle: Long,
        tier: TransportTier,
    ): NetworkTransitionEvent {
        val wasEmpty = networks.isEmpty()
        val previousTier = networks[handle]
        networks[handle] = tier
        val preferred = selectPreferredHandle()
        val previousActive = activeHandle
        activeHandle = preferred
        if (wasEmpty) {
            return NetworkTransitionEvent.GAINED_USABLE_NETWORK
        }
        if (connected && preferred != null && preferred != previousActive && previousTier == null) {
            return NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED
        }
        return NetworkTransitionEvent.NONE
    }

    @Synchronized
    fun onCapabilitiesChanged(
        handle: Long,
        tier: TransportTier,
    ): NetworkTransitionEvent {
        if (!networks.containsKey(handle)) return NetworkTransitionEvent.NONE
        networks[handle] = tier
        val preferred = selectPreferredHandle()
        val previousActive = activeHandle
        activeHandle = preferred
        if (connected && preferred != null && preferred != previousActive) {
            return NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED
        }
        return NetworkTransitionEvent.NONE
    }

    @Synchronized
    fun onNetworkLost(handle: Long): NetworkTransitionEvent {
        val existed = networks.remove(handle) != null
        if (!existed) return NetworkTransitionEvent.NONE
        if (networks.isEmpty()) {
            activeHandle = null
            return NetworkTransitionEvent.ALL_NETWORKS_LOST
        }
        val wasActive = activeHandle == handle
        activeHandle = selectPreferredHandle()
        if (connected && wasActive && activeHandle != null) {
            return NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED
        }
        return NetworkTransitionEvent.NONE
    }

    private fun selectPreferredHandle(): Long? {
        var bestHandle: Long? = null
        var bestPriority = -1
        for ((handle, tier) in networks) {
            if (tier.priority >= bestPriority) {
                bestPriority = tier.priority
                bestHandle = handle
            }
        }
        return bestHandle
    }
}

internal interface NetworkAvailabilityObserver {
    fun hasUsableNetwork(): Boolean
    fun markTunnelConnected()
    fun resetTunnelConnected()
    fun stop()
}

internal class ActiveNetworkMonitor(
    context: Context,
    private val onTransition: (NetworkTransitionEvent) -> Unit,
) : NetworkAvailabilityObserver {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val tracker = PhysicalNetworkTracker()
    private val knownNetworks = ConcurrentHashMap<Long, Network>()
    private val initialSeedLatch = CountDownLatch(1)
    @Volatile
    private var seeding = false
    @Volatile
    private var registered = false

    private val callback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                knownNetworks[network.networkHandle] = network
                val tier = tierFor(connectivityManager.getNetworkCapabilities(network))
                val event = tracker.onNetworkAvailable(network.networkHandle, tier)
                initialSeedLatch.countDown()
                if (!seeding) {
                    dispatch(event)
                }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                if (!isUsablePhysicalCapabilities(networkCapabilities)) {
                    return
                }
                knownNetworks[network.networkHandle] = network
                val tier = tierFor(networkCapabilities)
                val event = tracker.onCapabilitiesChanged(network.networkHandle, tier)
                initialSeedLatch.countDown()
                if (!seeding) {
                    dispatch(event)
                }
            }

            override fun onLost(network: Network) {
                knownNetworks.remove(network.networkHandle)
                dispatch(tracker.onNetworkLost(network.networkHandle))
            }

            override fun onUnavailable() {
                dispatch(NetworkTransitionEvent.ALL_NETWORKS_LOST)
            }
        }

    fun start() {
        if (registered) return
        seeding = true
        seedActivePhysicalNetwork()
        val request =
            NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
        connectivityManager.registerNetworkCallback(request, callback)
        registered = true
        // Wait briefly for initial callback when activeNetwork is still a tearing-down VPN or null.
        if (!tracker.hasUsableNetwork()) {
            try {
                initialSeedLatch.await(150, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        seeding = false
    }

    private fun seedActivePhysicalNetwork() {
        val network = connectivityManager.activeNetwork ?: return
        val caps = connectivityManager.getNetworkCapabilities(network) ?: return
        if (isUsablePhysicalCapabilities(caps)) {
            knownNetworks[network.networkHandle] = network
            tracker.onNetworkAvailable(network.networkHandle, tierFor(caps))
        }
    }

    private fun isUsablePhysicalCapabilities(caps: NetworkCapabilities): Boolean =
        caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)

    fun activePhysicalNetwork(): Network? {
        val preferred = tracker.preferredHandle()?.let { knownNetworks[it] }
        return preferred ?: connectivityManager.activeNetwork?.takeIf { candidate ->
            val caps = connectivityManager.getNetworkCapabilities(candidate)
            caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        }
    }

    fun interfaceNameFor(network: Network?): String? =
        network?.let { connectivityManager.getLinkProperties(it)?.interfaceName }?.takeIf { it.isNotBlank() }

    fun activeInterfaceName(): String? = interfaceNameFor(activePhysicalNetwork())

    internal fun bindSocketFd(fd: Int, tag: String, logPrefix: String, noNetworkLogLevel: Int = Log.DEBUG): Boolean {
        val network = activePhysicalNetwork()
        if (network == null) {
            VpnTunnelEvents.emitEngineLog(noNetworkLogLevel, tag, "$logPrefix bindNet=none")
            return false
        }
        val iface = interfaceNameFor(network) ?: "none"
        val binding = "$logPrefix bindNet=${network.networkHandle} iface=$iface"
        return try {
            ParcelFileDescriptor.fromFd(fd).use { dupPfd ->
                network.bindSocket(dupPfd.fileDescriptor)
            }
            VpnTunnelEvents.emitEngineLog(Log.DEBUG, tag, "$binding bindOk=true")
            true
        } catch (e: Exception) {
            VpnTunnelEvents.emitEngineLog(
                Log.WARN,
                tag,
                "$binding bindOk=false err=${e.javaClass.simpleName}:${e.message}",
            )
            false
        }
    }

    fun describeNetworkState(): String {
        val active = activePhysicalNetwork()
        val caps = active?.let { connectivityManager.getNetworkCapabilities(it) }
        val lp = active?.let { connectivityManager.getLinkProperties(it) }
        val defaultActive = connectivityManager.activeNetwork
        val defaultMatches = active != null && defaultActive?.networkHandle == active.networkHandle
        val v4Addrs =
            lp?.linkAddresses
                ?.filter { it.address is Inet4Address }
                ?.joinToString("+") { "${it.address.hostAddress}/${it.prefixLength}" }
                ?.ifEmpty { "none" }
                ?: "none"
        val v6Count = lp?.linkAddresses?.count { it.address is Inet6Address } ?: 0
        val defaultV4 = lp?.routes?.any { it.isDefaultRoute && it.destination.address is Inet4Address } == true
        val defaultV6 = lp?.routes?.any { it.isDefaultRoute && it.destination.address is Inet6Address } == true
        val gwV4 =
            lp?.routes
                ?.firstOrNull { it.isDefaultRoute && it.destination.address is Inet4Address }
                ?.gateway
                ?.hostAddress
                ?: "none"
        val dnsList = lp?.dnsServers.orEmpty()
        val dnsSummary =
            if (dnsList.isEmpty()) {
                "dnsCount=0"
            } else {
                val indexed =
                    dnsList.take(3).mapIndexed { idx, addr ->
                        "dns$idx=${addr.hostAddress ?: "?"}"
                    }.joinToString(" ")
                "dnsCount=${dnsList.size} $indexed"
            }
        val privateDnsMode = formatPrivateDnsMode(lp)
        val trackedSummary =
            if (knownNetworks.isEmpty()) {
                "none"
            } else {
                knownNetworks.values.joinToString(",") { net ->
                    val netCaps = connectivityManager.getNetworkCapabilities(net)
                    val netLp = connectivityManager.getLinkProperties(net)
                    val validated = netCaps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
                    "${tierFor(netCaps)}:${netLp?.interfaceName ?: "?"}:val=$validated"
                }
            }
        return "netHandle=${active?.networkHandle ?: -1L} " +
            "tier=${tierFor(caps)} " +
            "iface=${lp?.interfaceName ?: "none"} " +
            "validated=${caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true} " +
            "captivePortal=${caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL) == true} " +
            "internet=${caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true} " +
            "metered=${caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) == false} " +
            "linkMtu=${lp?.mtu ?: 0} " +
            "v4=$v4Addrs v6Count=$v6Count defaultV4=$defaultV4 defaultV6=$defaultV6 gwV4=$gwV4 " +
            "$dnsSummary privateDns=$privateDnsMode " +
            "defaultNetMatches=$defaultMatches dataSaver=${connectivityManager.restrictBackgroundStatus} " +
            "trackedNets=[$trackedSummary]"
    }

    private fun formatPrivateDnsMode(lp: LinkProperties?): String =
        when {
            lp == null -> "unknown"
            !lp.isPrivateDnsActive -> "off"
            lp.privateDnsServerName.isNullOrBlank() -> "opportunistic"
            else -> "strict"
        }

    override fun hasUsableNetwork(): Boolean = tracker.hasUsableNetwork()

    override fun markTunnelConnected() {
        tracker.markConnected()
    }

    override fun resetTunnelConnected() {
        tracker.resetConnected()
    }

    override fun stop() {
        if (!registered) return
        registered = false
        knownNetworks.clear()
        try {
            connectivityManager.unregisterNetworkCallback(callback)
        } catch (_: IllegalArgumentException) {
        }
    }

    private fun dispatch(event: NetworkTransitionEvent) {
        if (event != NetworkTransitionEvent.NONE) {
            onTransition(event)
        }
    }

    private fun tierFor(capabilities: NetworkCapabilities?): TransportTier =
        when {
            capabilities == null -> TransportTier.OTHER
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> TransportTier.ETHERNET
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> TransportTier.WIFI
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> TransportTier.CELLULAR
            else -> TransportTier.OTHER
        }
}
