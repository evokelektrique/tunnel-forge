package io.github.evokelektrique.tunnelforge

import java.net.ServerSocket
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProxyPortAllocatorTest {
    @Test
    fun sequentialKeepsRequestedPortsWhenAvailable() {
        val selection =
            ProxyPortAllocator.chooseSequential(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { _, _ -> true },
            )

        assertNotNull(selection)
        assertEquals(8080, selection!!.httpPort)
        assertEquals(1080, selection.socksPort)
        assertFalse(selection.sequentialFallbackUsed)
        assertFalse(selection.randomFallbackUsed)
    }

    @Test
    fun sequentialIncrementsOccupiedPortsIndependently() {
        val unavailable = setOf(8080, 1080, 1081)
        val selection =
            ProxyPortAllocator.chooseSequential(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { port, _ -> port !in unavailable },
            )

        assertNotNull(selection)
        assertEquals(8081, selection!!.httpPort)
        assertEquals(1082, selection.socksPort)
        assertTrue(selection.sequentialFallbackUsed)
    }

    @Test
    fun sequentialStopsAfterFiveChecks() {
        val unavailable = (8080..8084).toSet()
        val selection =
            ProxyPortAllocator.chooseSequential(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { port, _ -> port !in unavailable },
            )

        assertNull(selection)
    }

    @Test
    fun sequentialDoesNotAssignSamePortToHttpAndSocks() {
        val selection =
            ProxyPortAllocator.chooseSequential(
                requestedHttpPort = 8080,
                requestedSocksPort = 8080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { _, _ -> true },
            )

        assertNotNull(selection)
        assertEquals(8080, selection!!.httpPort)
        assertEquals(8081, selection.socksPort)
        assertNotEquals(selection.httpPort, selection.socksPort)
    }

    @Test
    fun sequentialDetectsActuallyOccupiedLoopbackPort() {
        ServerSocket(0).use { occupied ->
            val selection =
                ProxyPortAllocator.chooseSequential(
                    requestedHttpPort = occupied.localPort,
                    requestedSocksPort = 1080,
                    bindHosts = listOf("127.0.0.1"),
                )

            assertNotNull(selection)
            assertNotEquals(occupied.localPort, selection!!.httpPort)
        }
    }

    @Test
    fun preferredKeepsRequestedPortsWhenBothAreAvailable() {
        val selection =
            ProxyPortAllocator.choosePreferredThenRandom(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { _, _ -> true },
            )

        assertNotNull(selection)
        assertEquals(8080, selection!!.httpPort)
        assertEquals(1080, selection.socksPort)
        assertFalse(selection.sequentialFallbackUsed)
        assertFalse(selection.randomFallbackUsed)
    }

    @Test
    fun preferredUsesRandomPortsWhenRequestedHttpPortIsOccupied() {
        val unavailable = setOf(8080)
        val selection =
            ProxyPortAllocator.choosePreferredThenRandom(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { port, _ -> port !in unavailable },
            )

        assertNotNull(selection)
        assertTrue(selection!!.randomFallbackUsed)
        assertFalse(selection.sequentialFallbackUsed)
        assertNotEquals(8080, selection.httpPort)
        assertNotEquals(1080, selection.socksPort)
        assertNotEquals(selection.httpPort, selection.socksPort)
        assertTrue(selection.httpPort in 20_000..60_000)
        assertTrue(selection.socksPort in 20_000..60_000)
    }

    @Test
    fun preferredUsesRandomPortsWhenRequestedSocksPortIsOccupied() {
        val unavailable = setOf(1080)
        val selection =
            ProxyPortAllocator.choosePreferredThenRandom(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { port, _ -> port !in unavailable },
            )

        assertNotNull(selection)
        assertTrue(selection!!.randomFallbackUsed)
        assertFalse(selection.sequentialFallbackUsed)
        assertNotEquals(8080, selection.httpPort)
        assertNotEquals(1080, selection.socksPort)
        assertNotEquals(selection.httpPort, selection.socksPort)
        assertTrue(selection.httpPort in 20_000..60_000)
        assertTrue(selection.socksPort in 20_000..60_000)
    }

    @Test
    fun preferredRandomFallbackIsBoundedToFivePairAttempts() {
        var randomPortChecks = 0
        val selection =
            ProxyPortAllocator.choosePreferredThenRandom(
                requestedHttpPort = 8080,
                requestedSocksPort = 1080,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { port, _ ->
                    if (port in 20_000..60_000) randomPortChecks += 1
                    false
                },
            )

        assertNull(selection)
        assertEquals(ProxyPortAllocator.RANDOM_CHECKS, randomPortChecks)
    }

    @Test
    fun rejectsPrivilegedAndReservedAndroidPorts() {
        assertFalse(ProxyPortAllocator.isAllowedPort(0))
        assertFalse(ProxyPortAllocator.isAllowedPort(80))
        assertFalse(ProxyPortAllocator.isAllowedPort(1023))
        assertTrue(ProxyPortAllocator.isAllowedPort(1024))
        assertFalse(ProxyPortAllocator.isAllowedPort(1701))
        assertFalse(ProxyPortAllocator.isAllowedPort(4500))
        assertFalse(ProxyPortAllocator.isAllowedPort(5037))
        assertFalse(ProxyPortAllocator.isAllowedPort(5353))
        assertFalse(ProxyPortAllocator.isAllowedPort(5554))
        assertFalse(ProxyPortAllocator.isAllowedPort(5555))
        assertFalse(ProxyPortAllocator.isAllowedPort(65536))

        assertEquals(8080, ProxyPortAllocator.sanitizePort(80, 8080))
        assertEquals(1080, ProxyPortAllocator.sanitizePort(5353, 1080))
        assertEquals(18080, ProxyPortAllocator.sanitizePort(18080, 8080))

        val sequential =
            ProxyPortAllocator.chooseSequential(
                requestedHttpPort = 5553,
                requestedSocksPort = 5352,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { _, _ -> true },
            )
        assertNotNull(sequential)
        assertEquals(5553, sequential!!.httpPort)
        assertEquals(5352, sequential.socksPort)

        val skippedReserved =
            ProxyPortAllocator.chooseSequential(
                requestedHttpPort = 5554,
                requestedSocksPort = 5353,
                bindHosts = listOf("127.0.0.1"),
                isPortAvailable = { _, _ -> true },
            )
        assertNotNull(skippedReserved)
        assertEquals(5556, skippedReserved!!.httpPort)
        assertEquals(5354, skippedReserved.socksPort)
    }
}
