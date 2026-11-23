package io.github.evokelektrique.tunnelforge

import android.util.Log
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NettyProxyServerRuntimeTest {
    @Test
    fun httpConnectUsesNettyFrontendTransport() {
        val requests = CopyOnWriteArrayList<ProxyConnectRequest>()
        val opened = CountDownLatch(1)
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession {
                            requests.add(request)
                            opened.countDown()
                            return inertSession(request)
                        }
                    },
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: 93.184.216.34:443\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()

                val response = readHeaders(input)

                assertTrue(response.startsWith("HTTP/1.1 200 Connection Established"))
            }
            assertTrue(opened.await(2, TimeUnit.SECONDS))
            assertEquals(1, requests.size)
            assertEquals(ProxyConnectRequest("93.184.216.34", 443, "http-connect"), requests.first())
        } finally {
            runtime.stop()
        }
    }

    @Test
    fun socksConnectUsesNettyFrontendTransport() {
        val requests = CopyOnWriteArrayList<ProxyConnectRequest>()
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = false, httpPort = 8080, socksEnabled = true, socksPort = findFreePort()),
                transport = recordingTransport(requests),
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().socksPort).use { socket ->
                socket.soTimeout = 2_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write(byteArrayOf(0x05, 0x01, 0x00))
                output.flush()
                assertEquals(0x05, input.read())
                assertEquals(0x00, input.read())

                val host = "example.com".toByteArray(StandardCharsets.US_ASCII)
                output.write(byteArrayOf(0x05, 0x01, 0x00, 0x03, host.size.toByte()))
                output.write(host)
                output.write(byteArrayOf(0x01, 0xbb.toByte()))
                output.flush()

                assertEquals(0x05, input.read())
                assertEquals(0x00, input.read())
            }
            assertEquals(1, requests.size)
            assertEquals(ProxyConnectRequest("example.com", 443, "socks5-connect"), requests.first())
        } finally {
            runtime.stop()
        }
    }

    @Test
    fun httpConnectBurstCompletesWithoutThreadPerAcceptedSocket() {
        val requestCount = 120
        val opened = AtomicInteger(0)
        val allOpened = CountDownLatch(requestCount)
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession {
                            opened.incrementAndGet()
                            allOpened.countDown()
                            return inertSession(request)
                        }
                    },
                connectTimeoutMs = 2_000,
            )
        runtime.start()
        val executor = Executors.newFixedThreadPool(16)
        try {
            repeat(requestCount) { index ->
                executor.execute {
                    Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                        socket.soTimeout = 5_000
                        val output = BufferedOutputStream(socket.getOutputStream())
                        val input = BufferedInputStream(socket.getInputStream())
                        output.write("CONNECT 93.184.216.${index % 200}:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                        output.flush()
                        val response = readHeaders(input)
                        assertTrue(response.startsWith("HTTP/1.1 200 Connection Established"))
                    }
                }
            }
            assertTrue(allOpened.await(10, TimeUnit.SECONDS))
            executor.shutdown()
            assertTrue(executor.awaitTermination(10, TimeUnit.SECONDS))
            assertEquals(requestCount, opened.get())
        } finally {
            executor.shutdownNow()
            runtime.stop()
        }
    }

    @Test
    fun httpConnectReturnsEarlySuccessBeforeSlowTransportOpenCompletes() {
        val awaitEntered = CountDownLatch(1)
        val allowConnect = CountDownLatch(1)
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(11, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    awaitEntered.countDown()
                                    assertTrue(allowConnect.await(2, TimeUnit.SECONDS))
                                }

                                override fun readRemoteBytes(maxLen: Int, timeoutMs: Int): ByteArray? {
                                    Thread.sleep(25)
                                    return null
                                }

                                override fun writeClientBytes(bytes: ByteArray, timeoutMs: Int): Int = bytes.size

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {}
                            }
                    },
                connectTimeoutMs = 5_000,
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                socket.soTimeout = 1_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()

                val response = readHeaders(input)

                assertTrue(response.startsWith("HTTP/1.1 200 Connection Established"))
                assertTrue(awaitEntered.await(1, TimeUnit.SECONDS))
                allowConnect.countDown()
            }
        } finally {
            allowConnect.countDown()
            runtime.stop()
        }
    }

    @Test
    fun httpConnectClosesWithoutHttpErrorWhenEarlyOpenFails() {
        val logs = CopyOnWriteArrayList<String>()
        val runtime =
            NettyProxyServerRuntime(
                config =
                    ProxyRuntimeConfig(
                        httpEnabled = true,
                        httpPort = findFreePort(),
                        socksEnabled = false,
                        socksPort = 1080,
                        suppressUpstreamHttpErrors = true,
                    ),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(1, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    throw ProxyTransportException(ProxyTransportFailureReason.upstreamTimeout, "TCP connect timed out")
                                }

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {}
                            }
                    },
                levelLogger = { _, message -> logs.add(message) },
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                socket.soTimeout = 2_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()

                val response = readHeaders(input)
                val trailing = readUntilClosed(input)

                assertTrue(response.startsWith("HTTP/1.1 200 Connection Established"))
                assertFalse(trailing.contains("502 Bad Gateway"))
                assertFalse(trailing.contains("504 Gateway Timeout"))
            }
            assertNotNull(logs.firstOrNull { it.contains("earlyConnectOpenFailed") && it.contains("reason=upstreamTimeout") })
        } finally {
            runtime.stop()
        }
    }

    @Test
    fun channelCloseDuringPendingOpenClosesTransportSession() {
        val closeCalled = CountDownLatch(1)
        val awaitEntered = CountDownLatch(1)
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(77, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    awaitEntered.countDown()
                                    assertTrue(closeCalled.await(2, TimeUnit.SECONDS))
                                    throw ProxyTransportException(ProxyTransportFailureReason.clientAborted, "client closed")
                                }

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {
                                    closeCalled.countDown()
                                }
                            }
                    },
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                val output = BufferedOutputStream(socket.getOutputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                assertTrue(awaitEntered.await(2, TimeUnit.SECONDS))
            }
            assertTrue(closeCalled.await(2, TimeUnit.SECONDS))
        } finally {
            runtime.stop()
        }
    }

    @Test
    fun httpConnectPendingOpenBufferOverflowClosesAndCancelsOpen() {
        val closeCalled = CountDownLatch(1)
        val awaitEntered = CountDownLatch(1)
        val allowReturn = CountDownLatch(1)
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(21, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    awaitEntered.countDown()
                                    assertTrue(closeCalled.await(2, TimeUnit.SECONDS))
                                    allowReturn.await(2, TimeUnit.SECONDS)
                                    throw ProxyTransportException(ProxyTransportFailureReason.clientAborted, "client closed")
                                }

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {
                                    closeCalled.countDown()
                                }
                            }
                    },
                connectTimeoutMs = 5_000,
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                socket.soTimeout = 2_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                assertTrue(readHeaders(input).startsWith("HTTP/1.1 200 Connection Established"))
                assertTrue(awaitEntered.await(1, TimeUnit.SECONDS))
                output.write(ByteArray(64 * 1024 + 1) { 1 })
                output.flush()
                assertEquals("", readUntilClosed(input))
                assertTrue(closeCalled.await(2, TimeUnit.SECONDS))
            }
        } finally {
            allowReturn.countDown()
            runtime.stop()
        }
    }

    @Test
    fun httpConnectFlushesPendingBytesInOrderAfterOpenEstablishes() {
        val awaitEntered = CountDownLatch(1)
        val allowConnect = CountDownLatch(1)
        val flushed = CountDownLatch(1)
        val closeCalled = CountDownLatch(1)
        val received = CopyOnWriteArrayList<String>()
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(31, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    awaitEntered.countDown()
                                    assertTrue(allowConnect.await(2, TimeUnit.SECONDS))
                                }

                                override fun readRemoteBytes(maxLen: Int, timeoutMs: Int): ByteArray? {
                                    Thread.sleep(25)
                                    return null
                                }

                                override fun writeClientBytes(bytes: ByteArray, timeoutMs: Int): Int {
                                    received.add(bytes.toString(StandardCharsets.US_ASCII))
                                    if (received.joinToString("") == "first-second-third") {
                                        flushed.countDown()
                                    }
                                    return bytes.size
                                }

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {
                                    closeCalled.countDown()
                                }
                            }
                    },
                connectTimeoutMs = 5_000,
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                socket.soTimeout = 2_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\nfirst-".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                assertTrue(readHeaders(input).startsWith("HTTP/1.1 200 Connection Established"))
                assertTrue(awaitEntered.await(1, TimeUnit.SECONDS))
                output.write("second-".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                output.write("third".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                Thread.sleep(100)
                allowConnect.countDown()
                assertTrue(flushed.await(2, TimeUnit.SECONDS))
                assertEquals("first-second-third", received.joinToString(""))
            }
        } finally {
            allowConnect.countDown()
            runtime.stop()
        }
        assertTrue(closeCalled.await(2, TimeUnit.SECONDS))
    }

    @Test
    fun stopWhileConnectAndWriteInFlightDoesNotLeakOrCrashWorkerThreads() {
        val openEntered = CountDownLatch(1)
        val allowOpenFinish = CountDownLatch(1)
        val writeEntered = CountDownLatch(1)
        val allowWriteFinish = CountDownLatch(1)
        val slowSessionClosed = CountDownLatch(1)
        val sessionCounter = AtomicInteger(1)
        val uncaughtErrors = CopyOnWriteArrayList<Throwable>()
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            if (thread.name == "netty-proxy-transport") {
                uncaughtErrors.add(throwable)
            } else {
                previousHandler?.uncaughtException(thread, throwable)
            }
        }
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession {
                            val id = sessionCounter.getAndIncrement()
                            return object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(id, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    if (request.host == "198.51.100.2") {
                                        openEntered.countDown()
                                        // Keep returning after Netty's EventLoop terminates, simulating JNI open unblocking late.
                                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
                                        while (System.nanoTime() < deadline && allowOpenFinish.count > 0) {
                                            try {
                                                allowOpenFinish.await(50, TimeUnit.MILLISECONDS)
                                            } catch (_: InterruptedException) {
                                            }
                                        }
                                    }
                                }

                                override fun readRemoteBytes(maxLen: Int, timeoutMs: Int): ByteArray? {
                                    Thread.sleep(25)
                                    return null
                                }

                                override fun writeClientBytes(bytes: ByteArray, timeoutMs: Int): Int {
                                    if (request.host == "198.51.100.1") {
                                        writeEntered.countDown()
                                        allowWriteFinish.await(2, TimeUnit.SECONDS)
                                    }
                                    return bytes.size
                                }

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {
                                    if (request.host == "198.51.100.2") {
                                        slowSessionClosed.countDown()
                                    }
                                }
                            }
                        }
                    },
                connectTimeoutMs = 5_000,
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { writeSocket ->
                writeSocket.soTimeout = 2_000
                val wOut = BufferedOutputStream(writeSocket.getOutputStream())
                val wIn = BufferedInputStream(writeSocket.getInputStream())
                wOut.write("CONNECT 198.51.100.1:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                wOut.flush()
                assertTrue(readHeaders(wIn).startsWith("HTTP/1.1 200 Connection Established"))
                wOut.write("payload".toByteArray(StandardCharsets.US_ASCII))
                wOut.flush()
                assertTrue(writeEntered.await(2, TimeUnit.SECONDS))

                Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { openSocket ->
                    openSocket.soTimeout = 2_000
                    val oOut = BufferedOutputStream(openSocket.getOutputStream())
                    val oIn = BufferedInputStream(openSocket.getInputStream())
                    oOut.write("CONNECT 198.51.100.2:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                    oOut.flush()
                    assertTrue(readHeaders(oIn).startsWith("HTTP/1.1 200 Connection Established"))
                    assertTrue(openEntered.await(2, TimeUnit.SECONDS))

                    runtime.stop()
                    Thread.sleep(150)
                    allowWriteFinish.countDown()
                    allowOpenFinish.countDown()
                    Thread.sleep(200)
                }
            }
            assertTrue("Session opened right before shutdown finishes must still close", slowSessionClosed.await(2, TimeUnit.SECONDS))
            assertTrue("Expected no uncaught worker exceptions on stop, got $uncaughtErrors", uncaughtErrors.isEmpty())
        } finally {
            allowWriteFinish.countDown()
            allowOpenFinish.countDown()
            runtime.stop()
            Thread.setDefaultUncaughtExceptionHandler(previousHandler)
        }
    }

    @Test
    fun nettyRelayLogsPeerResetAtDebugInsteadOfWarn() {
        val warnLogs = CopyOnWriteArrayList<String>()
        val debugLogs = CopyOnWriteArrayList<String>()
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(51, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {}

                                override fun readRemoteBytes(maxLen: Int, timeoutMs: Int): ByteArray? {
                                    throw java.io.IOException("gVisor TCP read failed: connection reset.")
                                }

                                override fun writeClientBytes(bytes: ByteArray, timeoutMs: Int): Int = bytes.size

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {}
                            }
                    },
                levelLogger = { level, message ->
                    if (level >= Log.WARN) warnLogs.add(message) else debugLogs.add(message)
                },
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                socket.soTimeout = 2_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                assertTrue(readHeaders(input).startsWith("HTTP/1.1 200 Connection Established"))
                assertEquals("", readUntilClosed(input))
            }
            assertTrue("Peer reset should not log at WARN: $warnLogs", warnLogs.none { it.contains("connection reset") })
            assertTrue("Peer reset should log at DEBUG: $debugLogs", debugLogs.any { it.contains("remote->client") && it.contains("connection reset") })
        } finally {
            runtime.stop()
        }
    }

    @Test
    fun httpConnectSerializesBufferedAndSubsequentClientWrites() {
        val awaitEntered = CountDownLatch(1)
        val allowConnect = CountDownLatch(1)
        val firstWriteBlocked = CountDownLatch(1)
        val overlappingWrites = AtomicInteger(0)
        val activeWriters = AtomicInteger(0)
        val writtenChunks = CopyOnWriteArrayList<String>()
        val allWritten = CountDownLatch(1)
        val runtime =
            NettyProxyServerRuntime(
                config = ProxyRuntimeConfig(httpEnabled = true, httpPort = findFreePort(), socksEnabled = false, socksPort = 1080),
                transport =
                    object : ProxyTransport {
                        override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession =
                            object : ProxyTransportSession {
                                override val descriptor = ProxySessionDescriptor(61, request, System.currentTimeMillis())

                                override fun awaitConnected(timeoutMs: Long) {
                                    awaitEntered.countDown()
                                    assertTrue(allowConnect.await(2, TimeUnit.SECONDS))
                                }

                                override fun readRemoteBytes(maxLen: Int, timeoutMs: Int): ByteArray? {
                                    Thread.sleep(25)
                                    return null
                                }

                                override fun writeClientBytes(bytes: ByteArray, timeoutMs: Int): Int {
                                    if (activeWriters.incrementAndGet() > 1) {
                                        overlappingWrites.incrementAndGet()
                                    }
                                    try {
                                        val text = bytes.toString(StandardCharsets.US_ASCII)
                                        if (text.startsWith("one-")) {
                                            firstWriteBlocked.countDown()
                                            Thread.sleep(100)
                                        }
                                        writtenChunks.add(text)
                                        if (writtenChunks.joinToString("") == "one-two") {
                                            allWritten.countDown()
                                        }
                                        return bytes.size
                                    } finally {
                                        activeWriters.decrementAndGet()
                                    }
                                }

                                override fun pumpBidirectional(client: ProxyClientConnection) {}

                                override fun close() {}
                            }
                    },
            )
        runtime.start()
        try {
            Socket("127.0.0.1", runtime.exposureInfo().httpPort).use { socket ->
                socket.soTimeout = 2_000
                val output = BufferedOutputStream(socket.getOutputStream())
                val input = BufferedInputStream(socket.getInputStream())
                output.write("CONNECT 93.184.216.34:443 HTTP/1.1\r\nHost: test\r\n\r\none-".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                assertTrue(readHeaders(input).startsWith("HTTP/1.1 200 Connection Established"))
                assertTrue(awaitEntered.await(1, TimeUnit.SECONDS))
                allowConnect.countDown()
                assertTrue(firstWriteBlocked.await(2, TimeUnit.SECONDS))
                output.write("two".toByteArray(StandardCharsets.US_ASCII))
                output.flush()
                assertTrue(allWritten.await(2, TimeUnit.SECONDS))
                assertEquals("one-two", writtenChunks.joinToString(""))
                assertEquals(0, overlappingWrites.get())
            }
        } finally {
            allowConnect.countDown()
            runtime.stop()
        }
    }

    private fun recordingTransport(requests: MutableList<ProxyConnectRequest>): ProxyTransport =
        object : ProxyTransport {
            override fun openTcpSession(request: ProxyConnectRequest): ProxyTransportSession {
                requests.add(request)
                return inertSession(request)
            }
        }

    private fun inertSession(request: ProxyConnectRequest): ProxyTransportSession =
        object : ProxyTransportSession {
            override val descriptor: ProxySessionDescriptor =
                ProxySessionDescriptor(1, request, System.currentTimeMillis())

            override fun awaitConnected(timeoutMs: Long) {}

            override fun readRemoteBytes(maxLen: Int, timeoutMs: Int): ByteArray? = null

            override fun writeClientBytes(bytes: ByteArray, timeoutMs: Int): Int = bytes.size

            override fun pumpBidirectional(client: ProxyClientConnection) {}

            override fun close() {}
        }

    private fun readHeaders(input: BufferedInputStream): String {
        val bytes = mutableListOf<Byte>()
        while (true) {
            val next = input.read()
            if (next < 0) break
            bytes += next.toByte()
            if (bytes.size >= 4 && bytes.takeLast(4) == listOf('\r'.code.toByte(), '\n'.code.toByte(), '\r'.code.toByte(), '\n'.code.toByte())) {
                break
            }
        }
        return bytes.toByteArray().toString(StandardCharsets.US_ASCII)
    }

    private fun readUntilClosed(input: BufferedInputStream): String {
        val bytes = mutableListOf<Byte>()
        while (true) {
            val next = input.read()
            if (next < 0) break
            bytes += next.toByte()
        }
        return bytes.toByteArray().toString(StandardCharsets.US_ASCII)
    }

    private fun findFreePort(): Int =
        ServerSocket(0).use { it.localPort }
}
