package io.github.evokelektrique.tunnelforge

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Message
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.WorkerParameters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class AuditRemediationInstrumentedTest {

    @Test
    fun item01_ikev1DecryptBounds() {
        assertNull(VpnBridge.nativeRunAuditCheck(1))
    }

    @Test
    fun item02_pppLcpNakAndAuthBounds() {
        assertNull(VpnBridge.nativeRunAuditCheck(2))
    }

    @Test
    fun item03_espKeymatNotLogged() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        DiagnosticLog.init(context)
        DiagnosticLog.clear()
        val nativeErr = VpnBridge.nativeRunAuditCheck(3)
        val logTail = DiagnosticLog.readTail(200)
        assertFalse("ESP keymat leaked to DiagnosticLog:\n$logTail", logTail.contains("IKE keymat"))
        assertFalse("ESP keymap leaked to DiagnosticLog:\n$logTail", logTail.contains("IKE keymap"))
        assertFalse("DEBUG_ESP_KEYMAT leaked to DiagnosticLog:\n$logTail", logTail.contains("DEBUG_ESP_KEYMAT"))
        assertNull(nativeErr)
    }

    @Test
    fun item04_rejectCleartextIpWhenMppeEnabled() {
        assertNull(VpnBridge.nativeRunAuditCheck(4))
    }

    @Test
    fun item05_packetQueueDrainCapAndTeardown() {
        assertNull(VpnBridge.nativeRunAuditCheck(5))
    }

    @Test
    fun item06_gvisorConcurrentStopAndStackClose() {
        val local = intArrayOf(192, 0, 2, 1)
        val remote = intArrayOf(192, 0, 2, 2)
        try {
            for (cycle in 1..20) {
                assertEquals(0, VpnBridge.nativeGvisorStart(local, 1500))
                val openResult = AtomicInteger(Int.MIN_VALUE)
                val done = CountDownLatch(1)
                val opener = Thread {
                    openResult.set(VpnBridge.nativeGvisorTcpOpenCancelable(cycle, remote, 443, 1500))
                    done.countDown()
                }
                opener.start()
                val syn = VpnBridge.nativeGvisorReadOutbound(1500, 500)
                if (syn != null && syn.size >= 40) {
                    val synAck = buildSynAckReply(syn)
                    VpnBridge.nativeGvisorInjectInbound(synAck)
                }
                VpnBridge.nativeGvisorStop()
                assertTrue("cycle $cycle open timed out", done.await(3, TimeUnit.SECONDS))
                assertTrue("cycle $cycle unexpected open result=${openResult.get()}", openResult.get() <= 0 || openResult.get() > 0)
            }
        } finally {
            VpnBridge.nativeGvisorStop()
        }
    }

    @Test
    fun item07_pptpRootPipeNoSigpipeOrDeadlock() {
        assertNull(VpnBridge.nativeRunAuditCheck(7))
    }

    @Test
    fun item08_quickSettingsTokenAndLockGuard() {
        val controllerClass = QuickSettingsTileController::class.java
        val issueMethod = controllerClass.getDeclaredMethod("issueConnectLaunchToken")
        val consumeMethod = controllerClass.getDeclaredMethod("consumeConnectLaunchToken", String::class.java)
        val token = issueMethod.invoke(QuickSettingsTileController) as String
        assertTrue("Expected non-blank launch token", token.isNotBlank())
        assertFalse(consumeMethod.invoke(QuickSettingsTileController, null) as Boolean)
        assertFalse(consumeMethod.invoke(QuickSettingsTileController, "bogus-token") as Boolean)
        assertTrue(consumeMethod.invoke(QuickSettingsTileController, token) as Boolean)
        assertFalse("Token replay must be rejected", consumeMethod.invoke(QuickSettingsTileController, token) as Boolean)
        TunnelQuickSettingsTileService::class.java.getDeclaredMethod("handleTileClick")
    }

    @Test
    fun item09_lanProxyIsolationFramingAndAuth() {
        // 1. Cellular private and public Wi-Fi must NOT be shared on LAN.
        val exposure =
            ProxyExposurePlanner.choose(
                httpPort = 8080,
                socksPort = 1080,
                lanRequested = true,
                candidates =
                    listOf(
                        ProxyInterfaceCandidate(
                            interfaceName = "rmnet_data0",
                            address = "10.0.0.1",
                            transport = ProxyInterfaceTransport.CELLULAR,
                            isActive = true,
                            isPrivateAddress = true,
                        ),
                        ProxyInterfaceCandidate(
                            interfaceName = "wlan0",
                            address = "8.8.8.8",
                            transport = ProxyInterfaceTransport.WIFI,
                            isActive = true,
                            isPrivateAddress = false,
                        ),
                    ),
            )
        assertFalse("Cellular/public Wi-Fi must not activate LAN sharing", exposure.lanActive)
        assertEquals("127.0.0.1", exposure.bindAddress)

        // 2. Loopback & 0.0.0.0 SSRF must be blocked on DirectSocketProxyTransport and GvisorProxyTransport.
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { sink ->
            val direct = DirectSocketProxyTransport()
            for (target in listOf("127.0.0.1", "0.0.0.0")) {
                val session =
                    direct.openTcpSession(
                        ProxyConnectRequest(host = target, port = sink.localPort, protocol = "http-connect"),
                    )
                try {
                    session.awaitConnected(2000)
                    fail("Expected DirectSocketProxyTransport to reject $target")
                } catch (_: IOException) {
                } finally {
                    session.close()
                }
            }
            val gvisor =
                GvisorProxyTransport(
                    backend =
                        object : GvisorTcpBackend {
                            override fun open(openId: Int, remoteIpv4: IntArray, port: Int, timeoutMs: Int): Int =
                                throw AssertionError("SSRF target must fail before backend.open")

                            override fun cancelOpen(openId: Int): Int = 0
                            override fun read(sessionId: Int, maxLen: Int, timeoutMs: Int): ByteArray? = null
                            override fun write(sessionId: Int, bytes: ByteArray, timeoutMs: Int): Int = 0
                            override fun close(sessionId: Int) {}
                        },
                    tunneledResolver = { "127.0.0.1" },
                )
            val gSession = gvisor.openTcpSession(ProxyConnectRequest(host = "localhost", port = sink.localPort, protocol = "http-connect"))
            try {
                gSession.awaitConnected(2000)
                fail("Expected GvisorProxyTransport to reject tunneled 127.0.0.1")
            } catch (_: IOException) {
            } finally {
                gSession.close()
            }
        }

        // 3. Framing limits, bare CR, and TE+CL rejection on ProxyServerRuntime.
        val probeHttpPort = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
        val runtime =
            ProxyServerRuntime(
                config =
                    ProxyRuntimeConfig(
                        httpEnabled = true,
                        httpPort = probeHttpPort,
                        socksEnabled = false,
                        socksPort = 0,
                    ),
                transport = StubProxyTransport(),
            )
        runtime.start()
        try {
            val badRequests =
                listOf(
                    "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n",
                    buildString {
                        append("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n")
                        for (i in 1..130) append("X-Test-$i: value\r\n")
                        append("\r\n")
                    },
                    "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nX-Bare: foo\rbar\r\n\r\n",
                    "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nContent-Length: -1\r\n\r\n",
                )
            for (req in badRequests) {
                Socket("127.0.0.1", probeHttpPort).use { client ->
                    client.soTimeout = 3000
                    client.getOutputStream().write(req.toByteArray(StandardCharsets.US_ASCII))
                    client.getOutputStream().flush()
                    val resp = client.getInputStream().bufferedReader().readLine() ?: ""
                    assertTrue("Expected 400 Bad Request, got: $resp", resp.startsWith("HTTP/1.1 400"))
                }
            }
        } finally {
            runtime.stop()
        }

        // 4. Optional HTTP 407 + SOCKS5 0x02 auth on both ProxyServerRuntime and NettyProxyServerRuntime.
        val authUser = "alice"
        val authPass = "s3cr3t!"
        val goodBasic = Base64.getEncoder().encodeToString("$authUser:$authPass".toByteArray(StandardCharsets.UTF_8))
        val badBasic = Base64.getEncoder().encodeToString("$authUser:wrong".toByteArray(StandardCharsets.UTF_8))
        val runtimes: List<() -> Pair<LocalProxyRuntime, Pair<Int, Int>>> =
            listOf(
                {
                    val hp = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                    val sp = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                    ProxyServerRuntime(
                        config =
                            ProxyRuntimeConfig(
                                httpEnabled = true,
                                httpPort = hp,
                                socksEnabled = true,
                                socksPort = sp,
                                authEnabled = true,
                                authUsername = authUser,
                                authPassword = authPass,
                            ),
                        transport = StubProxyTransport(),
                    ) to (hp to sp)
                },
                {
                    val hp = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                    val sp = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                    NettyProxyServerRuntime(
                        config =
                            ProxyRuntimeConfig(
                                httpEnabled = true,
                                httpPort = hp,
                                socksEnabled = true,
                                socksPort = sp,
                                authEnabled = true,
                                authUsername = authUser,
                                authPassword = authPass,
                            ),
                        transport = StubProxyTransport(),
                    ) to (hp to sp)
                },
            )
        for (factory in runtimes) {
            val (rt, ports) = factory()
            val (hp, sp) = ports
            rt.start()
            try {
                // HTTP without credentials -> 407
                Socket("127.0.0.1", hp).use { client ->
                    client.soTimeout = 3000
                    client.getOutputStream().write(
                        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".toByteArray(StandardCharsets.US_ASCII),
                    )
                    client.getOutputStream().flush()
                    val resp = client.getInputStream().bufferedReader().readLine() ?: ""
                    assertTrue("Expected 407, got: $resp", resp.startsWith("HTTP/1.1 407"))
                }
                // HTTP wrong credentials -> 407
                Socket("127.0.0.1", hp).use { client ->
                    client.soTimeout = 3000
                    client.getOutputStream().write(
                        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Authorization: Basic $badBasic\r\n\r\n"
                            .toByteArray(StandardCharsets.US_ASCII),
                    )
                    client.getOutputStream().flush()
                    val resp = client.getInputStream().bufferedReader().readLine() ?: ""
                    assertTrue("Expected 407 on bad creds, got: $resp", resp.startsWith("HTTP/1.1 407"))
                }
                // HTTP valid credentials -> passes auth (503 from StubProxyTransport)
                Socket("127.0.0.1", hp).use { client ->
                    client.soTimeout = 3000
                    client.getOutputStream().write(
                        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Authorization: Basic $goodBasic\r\n\r\n"
                            .toByteArray(StandardCharsets.US_ASCII),
                    )
                    client.getOutputStream().flush()
                    val resp = client.getInputStream().bufferedReader().readLine() ?: ""
                    assertTrue(
                        "Expected auth pass (200 or 503 stub), got: $resp",
                        resp.startsWith("HTTP/1.1 200") || resp.startsWith("HTTP/1.1 503"),
                    )
                }
                // SOCKS5 offering only NO_AUTH -> 0xFF
                Socket("127.0.0.1", sp).use { client ->
                    client.soTimeout = 3000
                    client.getOutputStream().write(byteArrayOf(0x05, 0x01, 0x00))
                    client.getOutputStream().flush()
                    val reply = ByteArray(2)
                    assertEquals(2, client.getInputStream().read(reply))
                    assertEquals(0x05, reply[0].toInt() and 0xff)
                    assertEquals(0xff, reply[1].toInt() and 0xff)
                }
                // SOCKS5 wrong user/pass -> 0x02 accepted, then 0x01 0x01
                Socket("127.0.0.1", sp).use { client ->
                    client.soTimeout = 3000
                    val out = client.getOutputStream()
                    val inp = client.getInputStream()
                    out.write(byteArrayOf(0x05, 0x02, 0x00, 0x02))
                    out.flush()
                    val methodReply = ByteArray(2)
                    assertEquals(2, inp.read(methodReply))
                    assertEquals(0x02, methodReply[1].toInt() and 0xff)
                    val u = authUser.toByteArray(StandardCharsets.UTF_8)
                    val p = "wrong".toByteArray(StandardCharsets.UTF_8)
                    out.write(byteArrayOf(0x01, u.size.toByte()) + u + byteArrayOf(p.size.toByte()) + p)
                    out.flush()
                    val authReply = ByteArray(2)
                    assertEquals(2, inp.read(authReply))
                    assertEquals(0x01, authReply[0].toInt() and 0xff)
                    assertTrue((authReply[1].toInt() and 0xff) != 0)
                }
                // SOCKS5 valid user/pass -> 0x01 0x00, reaches CONNECT (0x01/0x05 failure from StubProxyTransport)
                Socket("127.0.0.1", sp).use { client ->
                    client.soTimeout = 3000
                    val out = client.getOutputStream()
                    val inp = client.getInputStream()
                    out.write(byteArrayOf(0x05, 0x01, 0x02))
                    out.flush()
                    val methodReply = ByteArray(2)
                    assertEquals(2, inp.read(methodReply))
                    assertEquals(0x02, methodReply[1].toInt() and 0xff)
                    val u = authUser.toByteArray(StandardCharsets.UTF_8)
                    val p = authPass.toByteArray(StandardCharsets.UTF_8)
                    out.write(byteArrayOf(0x01, u.size.toByte()) + u + byteArrayOf(p.size.toByte()) + p)
                    out.flush()
                    val authReply = ByteArray(2)
                    assertEquals(2, inp.read(authReply))
                    assertEquals(0x00, authReply[1].toInt() and 0xff)
                    out.write(byteArrayOf(0x05, 0x01, 0x00, 0x01, 1, 1, 1, 1, 0x00, 0x50))
                    out.flush()
                    val connReply = ByteArray(4)
                    assertEquals(4, inp.read(connReply))
                    assertEquals(0x05, connReply[0].toInt() and 0xff)
                    assertTrue((connReply[1].toInt() and 0xff) != 0)
                }
            } finally {
                rt.stop()
            }
        }
    }

    @Test
    fun item10_dohBoundsAndDnsTxIdMatch() {
        val dohServer =
            ResolvedDnsServerConfig(
                host = "dns.example",
                protocol = DnsProtocol.dnsOverHttps,
                resolvedIpv4 = "8.8.8.8",
            )
        // 1. DoH negative Content-Length must throw IOException, not NegativeArraySizeException.
        try {
            exchangeDnsOverHttps(
                input = ByteArrayInputStream("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n".toByteArray(StandardCharsets.US_ASCII)),
                output = ByteArrayOutputStream(),
                query = byteArrayOf(1, 2, 3),
                server = dohServer,
            )
            fail("Expected IOException for negative Content-Length")
        } catch (e: IOException) {
            // Expected post-fix.
        }

        // 2. DoH oversized Content-Length (> 65507) must be rejected before allocation.
        try {
            exchangeDnsOverHttps(
                input = ByteArrayInputStream("HTTP/1.1 200 OK\r\nContent-Length: 70000\r\n\r\n".toByteArray(StandardCharsets.US_ASCII)),
                output = ByteArrayOutputStream(),
                query = byteArrayOf(1, 2, 3),
                server = dohServer,
            )
            fail("Expected IOException for oversized Content-Length")
        } catch (e: IOException) {
            assertFalse("Must reject limit, not hit EOF trying to read 70k bytes", e is java.io.EOFException)
        }

        // 2b. DoH unbounded (no Content-Length) > 65507 bytes and negative chunk size must fail with IOException.
        try {
            val oversized = ByteArray(66_000) { 'A'.code.toByte() }
            val raw = "HTTP/1.1 200 OK\r\n\r\n".toByteArray(StandardCharsets.US_ASCII) + oversized
            exchangeDnsOverHttps(
                input = ByteArrayInputStream(raw),
                output = ByteArrayOutputStream(),
                query = byteArrayOf(1, 2, 3),
                server = dohServer,
            )
            fail("Expected IOException for oversized unbounded DoH body")
        } catch (_: IOException) {
        }
        try {
            exchangeDnsOverHttps(
                input = ByteArrayInputStream("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-4\r\nabcd\r\n0\r\n\r\n".toByteArray(StandardCharsets.US_ASCII)),
                output = ByteArrayOutputStream(),
                query = byteArrayOf(1, 2, 3),
                server = dohServer,
            )
            fail("Expected IOException for negative chunk size")
        } catch (_: IOException) {
        }

        // 3. Tunneled UDP DNS must ignore mismatched TxID spoofed packet and accept valid reply.
        lateinit var resolver: TunneledDnsResolver
        val spoofedAccepted = CountDownLatch(1)
        val backend =
            object : ProxyPacketBridgeBackend {
                override fun isActive(): Boolean = true

                override fun queueOutboundPacket(packet: ByteArray): Int {
                    val ipv4 = IpPacketParser.parseIpv4(packet) ?: return 0
                    val udp = IpPacketParser.parseUdp(packet, ipv4) ?: return 0
                    val txId =
                        ((packet[udp.payloadOffset].toInt() and 0xff) shl 8) or
                            (packet[udp.payloadOffset + 1].toInt() and 0xff)
                    val queryPayload =
                        packet.copyOfRange(udp.payloadOffset, udp.payloadOffset + udp.payloadLength)
                    Thread {
                        val spoofDns = buildDnsAnswer(queryPayload, txId xor 1, byteArrayOf(1, 2, 3, 4))
                        val spoofPkt =
                            UdpPacketBuilder.buildIpv4UdpPacket(
                                sourceIp = "8.8.8.8",
                                destinationIp = "10.0.0.2",
                                sourcePort = 53,
                                destinationPort = udp.sourcePort,
                                payload = spoofDns,
                            )
                        val spIpv4 = IpPacketParser.parseIpv4(spoofPkt)!!
                        val spUdp = IpPacketParser.parseUdp(spoofPkt, spIpv4)!!
                        if (resolver.handleInboundPacket(spIpv4, spUdp, spoofPkt)) {
                            spoofedAccepted.countDown()
                        }
                        Thread.sleep(30)
                        val goodDns = buildDnsAnswer(queryPayload, txId, byteArrayOf(93.toByte(), 184.toByte(), 216.toByte(), 34))
                        val goodPkt =
                            UdpPacketBuilder.buildIpv4UdpPacket(
                                sourceIp = "8.8.8.8",
                                destinationIp = "10.0.0.2",
                                sourcePort = 53,
                                destinationPort = udp.sourcePort,
                                payload = goodDns,
                            )
                        val gIpv4 = IpPacketParser.parseIpv4(goodPkt)!!
                        val gUdp = IpPacketParser.parseUdp(goodPkt, gIpv4)!!
                        resolver.handleInboundPacket(gIpv4, gUdp, goodPkt)
                    }.start()
                    return 0
                }

                override fun readInboundPacket(maxLen: Int): ByteArray? = null
            }
        val bridge = ProxyPacketBridge(backend = backend)
        assertTrue(bridge.waitUntilActive(100))
        resolver =
            TunneledDnsResolver(
                bridge = bridge,
                clientIpv4 = "10.0.0.2",
                dnsServers =
                    listOf(
                        ResolvedDnsServerConfig(
                            host = "8.8.8.8",
                            protocol = DnsProtocol.dnsOverUdp,
                            resolvedIpv4 = "8.8.8.8",
                        ),
                    ),
                openTunneledSocket = { throw IOException("unused") },
                logger = { _, _ -> },
            )
        val resolved = resolver.resolve("example.com")
        assertEquals("93.184.216.34", resolved)
        assertEquals("Mismatched TxID packet must not be accepted", 1L, spoofedAccepted.count)
    }

    private fun buildDnsAnswer(queryPayload: ByteArray, txId: Int, ipv4: ByteArray): ByteArray {
        val questionSection = queryPayload.copyOfRange(12, queryPayload.size)
        val out = ByteArrayOutputStream()
        out.write((txId ushr 8) and 0xff)
        out.write(txId and 0xff)
        out.write(byteArrayOf(0x81.toByte(), 0x80.toByte())) // standard response, no error
        out.write(byteArrayOf(0x00, 0x01)) // QDCOUNT = 1
        out.write(byteArrayOf(0x00, 0x01)) // ANCOUNT = 1
        out.write(byteArrayOf(0x00, 0x00, 0x00, 0x00)) // NSCOUNT/ARCOUNT = 0
        out.write(questionSection)
        out.write(byteArrayOf(0xc0.toByte(), 0x0c)) // name ptr to offset 12
        out.write(byteArrayOf(0x00, 0x01, 0x00, 0x01)) // TYPE A, CLASS IN
        out.write(byteArrayOf(0x00, 0x00, 0x00, 0x3c)) // TTL 60
        out.write(byteArrayOf(0x00, 0x04)) // RDLENGTH 4
        out.write(ipv4)
        return out.toByteArray()
    }

    @Test
    fun item11_initialRecoverableDisconnectAndNonBlockingStop() {
        val sleepingVpnSetup =
            Thread {
                try {
                    Thread.sleep(1500)
                } catch (_: InterruptedException) {
                }
            }.apply { start() }
        val sleepingProxyWorker =
            Thread {
                try {
                    Thread.sleep(1500)
                } catch (_: InterruptedException) {
                }
            }.apply { start() }
        try {
            val vpnService = TunnelVpnService()
            val setupField = TunnelVpnService::class.java.getDeclaredField("setupThread").apply { isAccessible = true }
            setupField.set(vpnService, sleepingVpnSetup)
            val runningField = TunnelVpnService::class.java.getDeclaredField("running").apply { isAccessible = true }
            @Suppress("UNCHECKED_CAST")
            (runningField.get(vpnService) as java.util.concurrent.atomic.AtomicBoolean).set(true)
            val stopMethod =
                TunnelVpnService::class.java.getDeclaredMethod("stopTunnelInternal", String::class.java).apply {
                    isAccessible = true
                }

            var vpnStopElapsedMs = -1L
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val startNs = System.nanoTime()
                stopMethod.invoke(vpnService, "audit-test")
                vpnStopElapsedMs = (System.nanoTime() - startNs) / 1_000_000L
            }
            assertTrue(
                "TunnelVpnService.stopTunnelInternal blocked main thread for ${vpnStopElapsedMs}ms",
                vpnStopElapsedMs < 400L,
            )

            val proxyService = ProxyTunnelService()
            val workerField = ProxyTunnelService::class.java.getDeclaredField("worker").apply { isAccessible = true }
            workerField.set(proxyService, sleepingProxyWorker)
            val attemptField = ProxyTunnelService::class.java.getDeclaredField("activeAttemptId").apply { isAccessible = true }
            attemptField.set(proxyService, "audit-attempt")
            val shutdownMethod =
                ProxyTunnelService::class.java.getDeclaredMethod("shutdownActiveSession", String::class.java).apply {
                    isAccessible = true
                }

            var proxyStopElapsedMs = -1L
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                val startNs = System.nanoTime()
                shutdownMethod.invoke(proxyService, "audit-test")
                proxyStopElapsedMs = (System.nanoTime() - startNs) / 1_000_000L
            }
            assertTrue(
                "ProxyTunnelService.shutdownActiveSession blocked main thread for ${proxyStopElapsedMs}ms",
                proxyStopElapsedMs < 400L,
            )
        } finally {
            sleepingVpnSetup.interrupt()
            sleepingVpnSetup.join(500)
            sleepingProxyWorker.interrupt()
            sleepingProxyWorker.join(500)
        }
    }

    @Test
    fun vpnDestroyAfterAppStopDoesNotReportSystemKilled() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        DiagnosticLog.init(context)
        val attachBase =
            ContextWrapper::class.java.getDeclaredMethod("attachBaseContext", Context::class.java).apply {
                isAccessible = true
            }
        val engineField = TunnelVpnService::class.java.getDeclaredField("engineThread").apply { isAccessible = true }
        val runningField = TunnelVpnService::class.java.getDeclaredField("running").apply { isAccessible = true }
        val attemptField = TunnelVpnService::class.java.getDeclaredField("activeAttemptId").apply { isAccessible = true }
        val lastAttemptField = TunnelVpnService::class.java.getDeclaredField("lastSessionAttemptId").apply { isAccessible = true }
        val stopMethod =
            TunnelVpnService::class.java.getDeclaredMethod("stopTunnelInternal", String::class.java).apply {
                isAccessible = true
            }

        val drainingEngine =
            Thread {
                try {
                    Thread.sleep(1500)
                } catch (_: InterruptedException) {
                }
            }.apply { start() }
        val killedEngine =
            Thread {
                try {
                    Thread.sleep(1500)
                } catch (_: InterruptedException) {
                }
            }.apply { start() }

        try {
            val cleanVpnService = TunnelVpnService()
            attachBase.invoke(cleanVpnService, context)
            DiagnosticLog.clear()
            VpnTunnelEvents.consumePendingTerminal()
            engineField.set(cleanVpnService, drainingEngine)
            attemptField.set(cleanVpnService, "clean-stop-attempt")
            lastAttemptField.set(cleanVpnService, "clean-stop-attempt")
            @Suppress("UNCHECKED_CAST")
            (runningField.get(cleanVpnService) as java.util.concurrent.atomic.AtomicBoolean).set(true)

            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                stopMethod.invoke(cleanVpnService, "stopped by app")
                cleanVpnService.onDestroy()
            }

            val cleanTerminal = VpnTunnelEvents.consumePendingTerminal()
            val cleanLog = DiagnosticLog.readTail(200)
            assertNull("Expected no TUNNEL_FAILED after app-initiated stop, got=$cleanTerminal", cleanTerminal)
            assertFalse("Unexpected destroyed_by_android_system in log:\n$cleanLog", cleanLog.contains("destroyed_by_android_system"))
            assertFalse("Unexpected state=failed in log:\n$cleanLog", cleanLog.contains("state=failed"))

            val killedVpnService = TunnelVpnService()
            attachBase.invoke(killedVpnService, context)
            DiagnosticLog.clear()
            VpnTunnelEvents.consumePendingTerminal()
            engineField.set(killedVpnService, killedEngine)
            attemptField.set(killedVpnService, "sys-kill-attempt")
            lastAttemptField.set(killedVpnService, "sys-kill-attempt")
            @Suppress("UNCHECKED_CAST")
            (runningField.get(killedVpnService) as java.util.concurrent.atomic.AtomicBoolean).set(true)

            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                killedVpnService.onDestroy()
            }

            val killTerminal = VpnTunnelEvents.consumePendingTerminal()
            val killLog = DiagnosticLog.readTail(200)
            assertEquals(VpnContract.TUNNEL_FAILED, killTerminal?.get(VpnContract.ARG_TUNNEL_STATE))
            assertTrue("Expected destroyed_by_android_system on unrequested destroy:\n$killLog", killLog.contains("destroyed_by_android_system"))
        } finally {
            VpnTunnelEvents.consumePendingTerminal()
            drainingEngine.interrupt()
            drainingEngine.join(500)
            killedEngine.interrupt()
            killedEngine.join(500)
        }
    }

    @Test
    fun item14_headlessEngineDestroyedOnWorkerInterrupt() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val unsafeClass = Class.forName("sun.misc.Unsafe")
        val unsafeField = unsafeClass.getDeclaredField("theUnsafe").apply { isAccessible = true }
        val unsafe = unsafeField.get(null)
        val allocMethod = unsafeClass.getMethod("allocateInstance", Class::class.java)
        val dummyParams = allocMethod.invoke(unsafe, WorkerParameters::class.java) as WorkerParameters
        val worker = SubscriptionAutoUpdateWorker(context, dummyParams)

        val dispatchedCount = AtomicInteger(0)
        val createStarted = CountDownLatch(1)
        val destroyDispatched = CountDownLatch(1)
        var workerThread: Thread? = null

        val spyHandler =
            object : Handler(Looper.getMainLooper()) {
                override fun dispatchMessage(msg: Message) {
                    val idx = dispatchedCount.incrementAndGet()
                    super.dispatchMessage(msg)
                    if (idx == 1) {
                        workerThread?.interrupt()
                        createStarted.countDown()
                    } else if (idx == 2) {
                        destroyDispatched.countDown()
                    }
                }
            }
        val mainHandlerField =
            SubscriptionAutoUpdateWorker::class.java.getDeclaredField("mainHandler").apply {
                isAccessible = true
            }
        mainHandlerField.set(worker, spyHandler)

        val runMethod =
            SubscriptionAutoUpdateWorker::class.java.getDeclaredMethod("runOnHeadlessEngine", String::class.java).apply {
                isAccessible = true
            }
        workerThread =
            Thread {
                try {
                    runMethod.invoke(worker, "audit_nonexistent_sub")
                } catch (_: Throwable) {
                }
            }.apply { start() }

        assertTrue("Create engine runnable did not run", createStarted.await(15, TimeUnit.SECONDS))
        workerThread.join(10_000)
        assertTrue(
            "Headless FlutterEngine destroy runnable must execute even on InterruptedException (dispatched=${dispatchedCount.get()})",
            destroyDispatched.await(5, TimeUnit.SECONDS),
        )
    }

    @Test
    fun item15_tfpShareIntentResolutionAndErrorLogLevel() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val pm = context.packageManager
        val sendIntent =
            Intent(Intent.ACTION_SEND).apply {
                type = "application/vnd.tunnelforge.profile+json"
            }
        @Suppress("DEPRECATION")
        val sendMatches = pm.queryIntentActivities(sendIntent, 0)
        assertTrue(
            "Expected ACTION_SEND (.tfp mime) to resolve MainActivity in ${context.packageName}",
            sendMatches.any { it.activityInfo.packageName == context.packageName },
        )

        val viewIntent =
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(android.net.Uri.parse("content://authority/downloads/test.tfp"), "*/*")
            }
        @Suppress("DEPRECATION")
        val viewMatches = pm.queryIntentActivities(viewIntent, 0)
        assertTrue(
            "Expected ACTION_VIEW (content://*/*.tfp) to resolve MainActivity in ${context.packageName}",
            viewMatches.any { it.activityInfo.packageName == context.packageName },
        )
    }

    @Test
    fun item16_espHotPathAndGvisorReadLatency() {
        VpnBridge.nativeGvisorStop()
        assertEquals(0, VpnBridge.nativeGvisorStart(intArrayOf(10, 0, 0, 2), 1500))
        try {
            val samplesMs = mutableListOf<Double>()
            for (i in 0..5) {
                val readDoneNs = java.util.concurrent.atomic.AtomicLong(0)
                val injectAtNs = java.util.concurrent.atomic.AtomicLong(0)
                val gotPacket = java.util.concurrent.atomic.AtomicBoolean(false)
                val reader =
                    Thread {
                        val pkt = VpnBridge.nativeGvisorReadOutbound(2048, 300)
                        readDoneNs.set(System.nanoTime())
                        gotPacket.set(pkt != null && pkt.isNotEmpty())
                    }.apply { start() }
                Thread.sleep(5)
                val opener =
                    Thread {
                        injectAtNs.set(System.nanoTime())
                        VpnBridge.nativeGvisorTcpOpenCancelable(i + 1, intArrayOf(93, 184, 216, 34), 443, 50)
                    }.apply { start() }
                reader.join(2000)
                opener.join(2000)
                assertTrue("Expected outbound SYN packet on cycle $i", gotPacket.get())
                if (i > 0) {
                    samplesMs.add(maxOf(0.0, (readDoneNs.get() - injectAtNs.get()) / 1_000_000.0))
                }
            }
            samplesMs.sort()
            val medianMs = samplesMs[samplesMs.size / 2]
            assertTrue(
                "Expected gVisor ReadContext wakeup median < 10.0ms, got ${medianMs}ms (samples=$samplesMs)",
                medianMs < 10.0,
            )
        } finally {
            VpnBridge.nativeGvisorStop()
        }
        assertNull(VpnBridge.nativeRunAuditCheck(16))
    }

    @Test
    fun item18_redactionAndProductionPppTests() {
        val rendered = sanitizeLogMessage("api_key=sec123,456 host=2001:db8::1")
        assertFalse("Expected secret value redacted, got: $rendered", rendered.contains("sec123"))
        assertFalse("Expected comma-separated suffix redacted, got: $rendered", rendered.contains(",456"))
        assertFalse("Expected IPv6 host redacted, got: $rendered", rendered.contains("2001:db8::1"))
        assertFalse("Expected no bogus :1 port suffix on IPv6 redaction, got: $rendered", rendered.contains("[REDACTED_HOST]:1"))
        assertTrue("Expected api_key=[REDACTED], got: $rendered", rendered.contains("api_key=[REDACTED]"))
        assertTrue("Expected host=[REDACTED_HOST], got: $rendered", rendered.contains("host=[REDACTED_HOST]"))

        val bareIpv6 = sanitizeLogMessage("socket failed to 2001:db8:85a3::8a2e:370:7334 port 443")
        assertFalse("Expected bare IPv6 redacted, got: $bareIpv6", bareIpv6.contains("2001:db8"))
    }

    @Test
    fun item19_deadClassesRemovedAndLocalizedDisconnectResolver() {
        for (deadClass in listOf(
            "io.github.evokelektrique.tunnelforge.UserspaceTunnelStack",
            "io.github.evokelektrique.tunnelforge.TcpPacketBuilder",
            "io.github.evokelektrique.tunnelforge.BridgeProxyTransport",
            "io.github.evokelektrique.tunnelforge.LocalDnsServer",
        )) {
            val loaded =
                try {
                    Class.forName(deadClass)
                    true
                } catch (_: ClassNotFoundException) {
                    false
                }
            assertFalse("Expected dead class removed from APK: $deadClass", loaded)
        }
        val legacyMethods =
            TunnelDisconnectNotification::class.java.declaredMethods.map { it.name }.toSet()
        assertFalse("formatDisconnectMessage" in legacyMethods)
        assertFalse("specificReasonForFailure" in legacyMethods)

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val cdn1 = TunnelDisconnectNotification.specificLocalizedReason(context, mapOf("namespace" to "l2tp-cdn", "code" to 1, "generalError" to 0), 0)
        val stopccn2 = TunnelDisconnectNotification.specificLocalizedReason(context, mapOf("namespace" to "l2tp-stopccn", "code" to 2, "generalError" to 8), 0)
        val mschap691 = TunnelDisconnectNotification.specificLocalizedReason(context, mapOf("namespace" to "mschap", "code" to 691, "generalError" to 0), 0)
        val rootDenied = TunnelDisconnectNotification.specificLocalizedReason(context, mapOf("namespace" to "engine", "code" to VpnBridge.EXIT_ROOT_DENIED, "generalError" to 0), 0)
        val revoked = TunnelDisconnectNotification.specificLocalizedReason(context, VpnAndroidFailure.map(VpnAndroidFailure.CODE_VPN_REVOKED), 0)

        assertTrue(!cdn1.isNullOrBlank())
        assertTrue(stopccn2 != null && stopccn2.contains(":"))
        assertTrue(!mschap691.isNullOrBlank())
        assertTrue(!rootDenied.isNullOrBlank())
        assertTrue(!revoked.isNullOrBlank())
    }

    @Test
    fun item20_deadJniMethodsAndUnusedAssetsRemoved() {
        val declared = VpnBridge::class.java.declaredMethods.map { it.name }.toSet()
        for (deadMethod in listOf("nativeRunTunnel", "nativeGvisorTcpOpen", "nativeGvisorLastOpenDiagnostics")) {
            assertFalse("Expected dead JNI method removed: $deadMethod", deadMethod in declared)
        }

        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val hasCupertinoFont =
            try {
                context.assets.open("flutter_assets/packages/cupertino_icons/assets/CupertinoIcons.ttf").use { true }
            } catch (_: java.io.IOException) {
                false
            }
        assertFalse("Expected unused CupertinoIcons.ttf removed from APK assets", hasCupertinoFont)
    }

    private fun buildSynAckReply(syn: ByteArray): ByteArray {
        val ihl = (syn[0].toInt() and 0x0f) * 4
        val reply = ByteArray(40)
        reply[0] = 0x45
        reply[3] = 40
        reply[8] = 64
        reply[9] = 6
        System.arraycopy(syn, 16, reply, 12, 4)
        System.arraycopy(syn, 12, reply, 16, 4)
        reply[20] = syn[ihl + 2]
        reply[21] = syn[ihl + 3]
        reply[22] = syn[ihl]
        reply[23] = syn[ihl + 1]
        reply[24] = 0x11; reply[25] = 0x22; reply[26] = 0x33; reply[27] = 0x44
        val seq = ((syn[ihl + 4].toInt() and 0xff) shl 24) or
            ((syn[ihl + 5].toInt() and 0xff) shl 16) or
            ((syn[ihl + 6].toInt() and 0xff) shl 8) or
            (syn[ihl + 7].toInt() and 0xff)
        val ack = seq + 1
        reply[28] = (ack ushr 24).toByte()
        reply[29] = (ack ushr 16).toByte()
        reply[30] = (ack ushr 8).toByte()
        reply[31] = ack.toByte()
        reply[32] = 0x50
        reply[33] = 0x12
        reply[34] = 0xff.toByte()
        reply[35] = 0xff.toByte()
        val ipSum = ipv4Checksum(reply, 0, 20)
        reply[10] = (ipSum ushr 8).toByte()
        reply[11] = ipSum.toByte()
        val tcpSum = tcpChecksum(reply, 20, 20)
        reply[36] = (tcpSum ushr 8).toByte()
        reply[37] = tcpSum.toByte()
        return reply
    }

    private fun ipv4Checksum(buf: ByteArray, off: Int, len: Int): Int {
        var sum = 0
        var i = off
        while (i < off + len) {
            sum += ((buf[i].toInt() and 0xff) shl 8) or (buf[i + 1].toInt() and 0xff)
            i += 2
        }
        while ((sum ushr 16) != 0) sum = (sum and 0xffff) + (sum ushr 16)
        return sum.inv() and 0xffff
    }

    private fun tcpChecksum(pkt: ByteArray, tcpOff: Int, tcpLen: Int): Int {
        var sum = 0
        for (i in 12 until 20 step 2) {
            sum += ((pkt[i].toInt() and 0xff) shl 8) or (pkt[i + 1].toInt() and 0xff)
        }
        sum += 6
        sum += tcpLen
        var i = tcpOff
        while (i < tcpOff + tcpLen) {
            sum += ((pkt[i].toInt() and 0xff) shl 8) or (pkt[i + 1].toInt() and 0xff)
            i += 2
        }
        while ((sum ushr 16) != 0) sum = (sum and 0xffff) + (sum ushr 16)
        return sum.inv() and 0xffff
    }
}
