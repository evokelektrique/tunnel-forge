package io.github.evokelektrique.tunnelforge

import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

class RootAccessDetectorTest {
    @After
    fun tearDown() {
        RootAccessDetector.resetForTest()
    }

    @Test
    fun startupProbeRunsOnceAndCachesResult() {
        val probeCalls = AtomicInteger(0)
        RootAccessDetector.resetForTest(
            customProbe = {
                probeCalls.incrementAndGet()
                true
            },
            customLogger = {},
        )

        RootAccessDetector.startAsyncProbe()
        RootAccessDetector.startAsyncProbe()

        assertTrue(RootAccessDetector.isRootDetected())
        assertTrue(RootAccessDetector.isRootDetected())
        assertEquals(1, probeCalls.get())
    }

    @Test
    fun nonRootOrExceptionFallsBackToFalse() {
        RootAccessDetector.resetForTest(
            customProbe = { throw IllegalStateException("no su") },
            customLogger = {},
        )

        assertFalse(RootAccessDetector.isRootDetected())
    }

    @Test
    fun awaitTimeoutReturnsFalseWithoutThrowing() {
        RootAccessDetector.resetForTest(
            customProbe = {
                Thread.sleep(500)
                true
            },
            customLogger = {},
        )
        RootAccessDetector.startAsyncProbe()

        assertFalse(RootAccessDetector.isRootDetected(waitTimeoutMs = 10L))
    }
}
