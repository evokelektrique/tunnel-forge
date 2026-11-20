package io.github.evokelektrique.tunnelforge

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.AfterClass
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.lang.reflect.Modifier

private object NativeCoverage {
    @JvmStatic external fun writeProfile(path: String): Int
}

/**
 * Widget/integration tests mock the VPN channel, so they never exercise JNI. These calls stay on
 * low-risk native entrypoints and should fail immediately if library loading or RegisterNatives is broken.
 */
@RunWith(AndroidJUnit4::class)
class JniEntryPointsTest {
    companion object {
        @AfterClass
        @JvmStatic
        fun writeNativeCoverage() {
            val arguments = InstrumentationRegistry.getArguments()
            if (arguments.getString("nativeCoverage") != "true") return
            val outputDir = checkNotNull(arguments.getString("additionalTestOutputDir"))
            assertEquals(0, NativeCoverage.writeProfile(File(outputDir, "tunnel-engine.profraw").path))
        }
    }


    @Test
    fun nativeCodeCanStillResolveKotlinJniPeers() {
        val protect =
            TunnelVpnService::class.java.getDeclaredMethod(
                "protectSocketFd",
                Int::class.javaPrimitiveType,
            )
        assertTrue(Modifier.isStatic(protect.modifiers))
        protect.isAccessible = true
        assertTrue(protect.invoke(null, -1) is Boolean)

        val ready =
            TunnelVpnService::class.java.getDeclaredMethod(
                "onNativeTunnelReady",
                String::class.java,
            )
        assertTrue(Modifier.isStatic(ready.modifiers))
        ready.isAccessible = true
        assertNull(ready.invoke(null, "TUN interface ready; tunnel loop active"))
    }

    @Test
    fun nativeBridgeMethodsAreRegisteredAndCallable() {
        VpnBridge.nativeSetSocketProtectionEnabled(false)
        assertFalse(VpnBridge.nativeIsProxyPacketBridgeActive())
        assertNull(VpnBridge.nativeReadProxyInboundPacket(0))
        VpnBridge.nativeStopTunnel()
    }

    @Test
    fun nativeBridgeStartsAndStopsThePackagedGoStack() {
        assertEquals(0, VpnBridge.nativeGvisorStart(intArrayOf(192, 0, 2, 1), 1500))
        try {
            assertEquals(1, VpnBridge.nativeGvisorStats()[0])
            assertNull(VpnBridge.nativeGvisorReadOutbound(1500, 0))
        } finally {
            VpnBridge.nativeGvisorStop()
        }
        assertEquals(0, VpnBridge.nativeGvisorStats()[0])
    }
}
