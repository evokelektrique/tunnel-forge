package io.github.evokelektrique.tunnelforge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelReconnectPolicyTest {
    @Test
    fun backoffDoublesAndCapsAtThirtySeconds() {
        assertEquals(1_000L, TunnelReconnectPolicy.backoffMsForAttempt(0))
        assertEquals(2_000L, TunnelReconnectPolicy.backoffMsForAttempt(1))
        assertEquals(4_000L, TunnelReconnectPolicy.backoffMsForAttempt(2))
        assertEquals(8_000L, TunnelReconnectPolicy.backoffMsForAttempt(3))
        assertEquals(16_000L, TunnelReconnectPolicy.backoffMsForAttempt(4))
        assertEquals(30_000L, TunnelReconnectPolicy.backoffMsForAttempt(5))
        assertEquals(30_000L, TunnelReconnectPolicy.backoffMsForAttempt(20))
    }

    @Test
    fun terminalClassifierStopsAuthAndInvalidConfigImmediately() {
        assertTrue(TunnelReconnectPolicy.isTerminalFailure(VpnBridge.EXIT_BAD_ARGS, null))
        assertTrue(TunnelReconnectPolicy.isTerminalFailure(VpnBridge.EXIT_STOPPED, null))
        assertTrue(
            TunnelReconnectPolicy.isTerminalFailure(
                VpnBridge.EXIT_PPP_FAILED,
                mapOf("namespace" to "mschap", "code" to 691, "generalError" to 0),
            ),
        )
        assertTrue(
            TunnelReconnectPolicy.isTerminalFailure(
                VpnBridge.EXIT_PPP_FAILED,
                mapOf("namespace" to "pap", "code" to 1, "generalError" to 0),
            ),
        )
        assertTrue(
            TunnelReconnectPolicy.isTerminalFailure(
                VpnBridge.EXIT_L2TP_FAILED,
                mapOf("namespace" to "l2tp-stopccn", "code" to 4, "generalError" to 0),
            ),
        )
        assertTrue(
            TunnelReconnectPolicy.isTerminalFailure(
                VpnBridge.EXIT_PEER_CLOSED,
                mapOf("namespace" to "l2tp-cdn", "code" to 1, "generalError" to 0),
            ),
        )
        assertTrue(
            TunnelReconnectPolicy.isTerminalFailure(
                VpnBridge.EXIT_PEER_CLOSED,
                null,
            ),
        )
    }

    @Test
    fun recoverableClassifierRetriesNetworkLossAndDeadPeer() {
        assertFalse(TunnelReconnectPolicy.isTerminalFailure(VpnBridge.EXIT_NETWORK_LOST, null))
        assertFalse(TunnelReconnectPolicy.isTerminalFailure(VpnBridge.EXIT_PEER_UNREACHABLE, null))
        assertFalse(TunnelReconnectPolicy.isTerminalFailure(VpnBridge.EXIT_POLL_ERROR, null))
        assertFalse(
            TunnelReconnectPolicy.isTerminalFailure(
                VpnBridge.EXIT_L2TP_FAILED,
                mapOf("namespace" to "l2tp-stopccn", "code" to 1, "generalError" to 0),
            ),
        )
    }

    @Test
    fun initialAttemptFailsIkeOnlineButWaitsOffline() {
        assertTrue(
            TunnelReconnectPolicy.shouldFailOnInitialAttempt(
                hasEverConnected = false,
                hasUsableNetwork = true,
                exitCode = VpnBridge.EXIT_IKE_FAILED,
                failure = null,
            ),
        )
        assertFalse(
            TunnelReconnectPolicy.shouldFailOnInitialAttempt(
                hasEverConnected = false,
                hasUsableNetwork = false,
                exitCode = VpnBridge.EXIT_IKE_FAILED,
                failure = null,
            ),
        )
        assertFalse(
            TunnelReconnectPolicy.shouldFailOnInitialAttempt(
                hasEverConnected = true,
                hasUsableNetwork = true,
                exitCode = VpnBridge.EXIT_IKE_FAILED,
                failure = null,
            ),
        )
    }

    @Test
    fun networkTrackerHandlesLossSwitchAndRecovery() {
        val tracker = PhysicalNetworkTracker()
        assertFalse(tracker.hasUsableNetwork())

        // Cellular + WiFi available during startup
        assertEquals(
            NetworkTransitionEvent.GAINED_USABLE_NETWORK,
            tracker.onNetworkAvailable(handle = 1L, tier = TransportTier.CELLULAR),
        )
        assertEquals(
            NetworkTransitionEvent.NONE,
            tracker.onNetworkAvailable(handle = 2L, tier = TransportTier.WIFI),
        )
        assertTrue(tracker.hasUsableNetwork())

        // Mark connected on WiFi
        tracker.markConnected()

        // WiFi lost -> falls back to cellular -> active switch
        assertEquals(
            NetworkTransitionEvent.ACTIVE_NETWORK_SWITCHED,
            tracker.onNetworkLost(2L),
        )
        assertTrue(tracker.hasUsableNetwork())

        // Cellular lost -> all networks lost
        assertEquals(
            NetworkTransitionEvent.ALL_NETWORKS_LOST,
            tracker.onNetworkLost(1L),
        )
        assertFalse(tracker.hasUsableNetwork())

        // WiFi returns -> gained network
        assertEquals(
            NetworkTransitionEvent.GAINED_USABLE_NETWORK,
            tracker.onNetworkAvailable(handle = 3L, tier = TransportTier.WIFI),
        )
        assertTrue(tracker.hasUsableNetwork())
    }

    @Test
    fun stopPolicyCountsBlockingTunAsActiveSession() {
        assertTrue(
            TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
                running = false,
                hasSetupThread = false,
                hasEngineThread = false,
                hasTunInterface = false,
                hasDnsServer = false,
                hasLocalProxyRuntime = false,
                hasBlockingTunInterface = true,
            ),
        )
    }

    @Test
    fun disconnectNotificationFormatsSpecificReasonsAndAlertGates() {
        assertTrue(
            TunnelDisconnectNotification.isPeerTeardownFailure(
                VpnBridge.EXIT_PEER_CLOSED,
                null,
            ),
        )
        assertEquals(
            "Work: Carrier lost.",
            TunnelDisconnectNotification.formatDisconnectMessage(
                detail = "Disconnected by peer",
                failure = mapOf("namespace" to "l2tp-cdn", "code" to 1, "generalError" to 0),
                profileLabel = "Work",
            ),
        )
        assertEquals(
            "Work: VPN server is shutting down.",
            TunnelDisconnectNotification.formatDisconnectMessage(
                detail = "Disconnected by peer",
                failure = mapOf("namespace" to "l2tp-stopccn", "code" to 6, "generalError" to 0),
                profileLabel = "Work",
            ),
        )
        assertEquals(
            "Work: Server reported a general error: Unsupported mandatory attribute.",
            TunnelDisconnectNotification.formatDisconnectMessage(
                detail = "Disconnected by peer",
                failure = mapOf("namespace" to "l2tp-stopccn", "code" to 2, "generalError" to 8),
                profileLabel = "Work",
            ),
        )
        assertEquals(
            "Authentication failed.",
            TunnelDisconnectNotification.formatDisconnectMessage(
                detail = "PPP negotiation failed.",
                failure = mapOf("namespace" to "mschap", "code" to 691, "generalError" to 0),
            ),
        )
        assertEquals(
            "Work: VPN was revoked by Android.",
            TunnelDisconnectNotification.formatDisconnectMessage(
                detail = "Disconnected: VPN revoked by Android",
                failure = VpnAndroidFailure.map(VpnAndroidFailure.CODE_VPN_REVOKED),
                profileLabel = "Work",
            ),
        )
        assertEquals(
            "Work: Connection lost. Reconnecting in background...",
            TunnelDisconnectNotification.formatStalledReconnectMessage(profileLabel = "Work"),
        )

        // Foreground gating: skip alert on initial connect failure in foreground; allow in background or after connect.
        assertFalse(
            TunnelDisconnectNotification.shouldPostDisconnectAlert(
                userStopRequested = false,
                hasEverConnected = false,
                isAppForeground = true,
            ),
        )
        assertTrue(
            TunnelDisconnectNotification.shouldPostDisconnectAlert(
                userStopRequested = false,
                hasEverConnected = false,
                isAppForeground = false,
            ),
        )
        assertTrue(
            TunnelDisconnectNotification.shouldPostDisconnectAlert(
                userStopRequested = false,
                hasEverConnected = true,
                isAppForeground = true,
            ),
        )
        assertFalse(
            TunnelDisconnectNotification.shouldPostDisconnectAlert(
                userStopRequested = true,
                hasEverConnected = true,
                isAppForeground = false,
            ),
        )

        // Stalled-reconnect alert threshold & one-shot suppression.
        assertFalse(TunnelReconnectPolicy.shouldPostStalledReconnectAlert(onlineFailureCount = 2, alreadyNotified = false))
        assertTrue(TunnelReconnectPolicy.shouldPostStalledReconnectAlert(onlineFailureCount = 3, alreadyNotified = false))
        assertFalse(TunnelReconnectPolicy.shouldPostStalledReconnectAlert(onlineFailureCount = 3, alreadyNotified = true))
    }
}
