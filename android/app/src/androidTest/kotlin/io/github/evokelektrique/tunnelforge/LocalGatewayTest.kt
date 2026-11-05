package io.github.evokelektrique.tunnelforge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Opt-in real gateway test. Credentials are supplied as instrumentation arguments. */
@RunWith(AndroidJUnit4::class)
class LocalGatewayTest {
    @Test
    fun fullDeviceVpnCarriesTraffic() {
        val args = InstrumentationRegistry.getArguments()
        val host = args.getString("vpnHost")
        assumeTrue("Local gateway arguments required", host != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assumeTrue("VPN consent must already be granted", android.net.VpnService.prepare(context) == null)
        val start = android.content.Intent(context, TunnelVpnService::class.java)
            .setAction(TunnelVpnService.ACTION_START)
            .putExtra("server", host).putExtra("user", args.getString("vpnUser"))
            .putExtra("password", args.getString("vpnPassword")).putExtra("psk", args.getString("vpnPsk"))
            .putExtra("attemptId", "docker-device-verification")
        try {
            context.startForegroundService(start)
            val deadline = System.currentTimeMillis() + 60000
            while (System.currentTimeMillis() < deadline &&
                TunnelVpnService.runtimeSnapshot()?.get("tunnelState") != "connected") Thread.sleep(100)
            assertEquals("connected", TunnelVpnService.runtimeSnapshot()?.get("tunnelState"))
            val connectivity = context.getSystemService(android.net.ConnectivityManager::class.java)
            fun vpnActive() = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
                ?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true
            while (!vpnActive() && System.currentTimeMillis() < deadline) Thread.sleep(100)
            assertTrue("Android selected the VPN network", vpnActive())
            java.net.DatagramSocket().use { socket ->
                socket.soTimeout = 1000
                val payload = "TunnelForge full VPN proof".toByteArray()
                var echoed = false
                repeat(3) {
                    if (!echoed) {
                        socket.send(java.net.DatagramPacket(payload, payload.size,
                            java.net.InetAddress.getByName("192.168.42.1"), 41888))
                        val reply = java.net.DatagramPacket(ByteArray(256), 256)
                        try {
                            socket.receive(reply)
                            echoed = payload.contentEquals(reply.data.copyOf(reply.length))
                        } catch (_: java.net.SocketTimeoutException) { }
                    }
                }
                assertTrue("Normal UDP socket crossed the Android VPN", echoed)
            }
        } finally {
            context.startService(android.content.Intent(context, TunnelVpnService::class.java)
                .setAction(TunnelVpnService.ACTION_STOP))
            val deadline = System.currentTimeMillis() + 10000
            while ((TunnelVpnService.runtimeSnapshot() != null || NativeTunnelSessions.shared.currentOwner() != null) && System.currentTimeMillis() < deadline) Thread.sleep(100)
            assertTrue("VPN service stopped", TunnelVpnService.runtimeSnapshot() == null)
        }
    }

    @Test
    fun negotiatesAndReconnects() {
        val args = InstrumentationRegistry.getArguments()
        val host = args.getString("vpnHost")
        assumeTrue("Local gateway arguments required", host != null)
        VpnBridge.nativeSetSocketProtectionEnabled(false)
        try {
            repeat(2) {
                val address = IntArray(4)
                val result = VpnBridge.nativeNegotiate(
                    host!!, args.getString("vpnUser")!!, args.getString("vpnPassword")!!,
                    args.getString("vpnPsk")!!, 1400, address, IntArray(4), IntArray(4),
                )
                assertEquals("IKE/L2TP/PPP negotiation", 0, result)
                assertTrue("IPCP assigned an address", address.any { it != 0 })
                val loop = Thread { VpnBridge.nativeStartProxyLoop() }.apply { start() }
                try {
                    assertTrue("Packet bridge ready", ProxyPacketBridge().waitUntilActive())
                    val payload = "TunnelForge gateway proof".toByteArray()
                    val packet = UdpPacketBuilder.buildIpv4UdpPacket(
                        address.joinToString("."), "192.168.42.1", 41887, 41888, payload,
                    )
                    assertEquals(0, VpnBridge.nativeQueueProxyOutboundPacket(packet))
                    val deadline = System.currentTimeMillis() + 10000
                    var echoed = false
                    while (!echoed && System.currentTimeMillis() < deadline) {
                        val incoming = VpnBridge.nativeReadProxyInboundPacket(4096)
                        echoed = incoming != null && incoming.size >= 28 + payload.size &&
                            incoming.takeLast(payload.size).toByteArray().contentEquals(payload)
                        if (!echoed) Thread.sleep(20)
                    }
                    assertTrue("UDP echo crossed PPP/IPsec in both directions", echoed)
                } finally {
                    VpnBridge.nativeStopTunnel()
                    loop.join(5000)
                    assertTrue("Tunnel loop stopped", !loop.isAlive)
                }
            }
        } finally {
            VpnBridge.nativeStopTunnel()
            VpnBridge.nativeSetSocketProtectionEnabled(true)
        }
    }
}
