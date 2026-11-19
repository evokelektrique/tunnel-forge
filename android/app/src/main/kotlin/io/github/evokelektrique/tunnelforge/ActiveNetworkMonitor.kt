package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.util.concurrent.ConcurrentHashMap

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
    @Volatile
    private var registered = false

    private val callback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                knownNetworks[network.networkHandle] = network
                val tier = tierFor(connectivityManager.getNetworkCapabilities(network))
                dispatch(tracker.onNetworkAvailable(network.networkHandle, tier))
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                if (!networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                    !networkCapabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                ) {
                    return
                }
                knownNetworks[network.networkHandle] = network
                val tier = tierFor(networkCapabilities)
                dispatch(tracker.onCapabilitiesChanged(network.networkHandle, tier))
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
        val activeNetwork = connectivityManager.activeNetwork
        if (activeNetwork != null) {
            val caps = connectivityManager.getNetworkCapabilities(activeNetwork)
            if (caps != null &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) {
                knownNetworks[activeNetwork.networkHandle] = activeNetwork
                tracker.onNetworkAvailable(activeNetwork.networkHandle, tierFor(caps))
            }
        }
        val request =
            NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
        connectivityManager.registerNetworkCallback(request, callback)
        registered = true
    }

    fun activeInterfaceName(): String? {
        val preferred = tracker.preferredHandle()?.let { knownNetworks[it] }
        val network =
            preferred ?: connectivityManager.activeNetwork?.takeIf { candidate ->
                val caps = connectivityManager.getNetworkCapabilities(candidate)
                caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            }
        return network?.let { connectivityManager.getLinkProperties(it)?.interfaceName }?.takeIf { it.isNotBlank() }
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
