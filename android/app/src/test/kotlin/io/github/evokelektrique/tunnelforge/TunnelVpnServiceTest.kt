package io.github.evokelektrique.tunnelforge

import android.util.Log
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TunnelVpnServiceTest {

    @Test
    fun effectiveInclusivePackagesAddsTunnelForgePackage() {
        val effective =
            TunnelVpnService.effectiveInclusivePackages(
                splitTunnelEnabled = true,
                splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE,
                inclusivePackages = listOf(" com.example.alpha ", "com.example.beta"),
                selfPackageName = "io.github.evokelektrique.tunnelforge",
            )

        assertEquals(
            listOf(
                "com.example.alpha",
                "com.example.beta",
                "io.github.evokelektrique.tunnelforge",
            ),
            effective,
        )
    }

    @Test
    fun effectiveInclusivePackagesDoesNotDuplicateTunnelForgePackage() {
        val effective =
            TunnelVpnService.effectiveInclusivePackages(
                splitTunnelEnabled = true,
                splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE,
                inclusivePackages =
                    listOf(
                        "io.github.evokelektrique.tunnelforge",
                        "com.example.alpha",
                        "io.github.evokelektrique.tunnelforge",
                    ),
                selfPackageName = "io.github.evokelektrique.tunnelforge",
            )

        assertEquals(
            listOf("io.github.evokelektrique.tunnelforge", "com.example.alpha"),
            effective,
        )
    }

    @Test
    fun effectiveInclusivePackagesIsEmptyWhenDisabled() {
        val effective =
            TunnelVpnService.effectiveInclusivePackages(
                splitTunnelEnabled = false,
                splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_INCLUSIVE,
                inclusivePackages = listOf("com.example.alpha"),
                selfPackageName = "io.github.evokelektrique.tunnelforge",
            )

        assertEquals(emptyList<String>(), effective)
    }

    @Test
    fun requestedExclusivePackagesTrimsDedupesAndSkipsSelf() {
        val requested =
            TunnelVpnService.requestedExclusivePackages(
                splitTunnelEnabled = true,
                splitTunnelMode = VpnContract.SPLIT_TUNNEL_MODE_EXCLUSIVE,
                exclusivePackages =
                    listOf(
                        " com.example.alpha ",
                        "io.github.evokelektrique.tunnelforge",
                        "com.example.alpha",
                        "com.example.beta",
                    ),
                selfPackageName = "io.github.evokelektrique.tunnelforge",
            )

        assertEquals(listOf("com.example.alpha", "com.example.beta"), requested)
    }

    @Test
    fun localProxyRuntimeConfigKeepsClientCapacityUnlimited() {
        val config =
            ProxyRuntimeConfig(
                httpEnabled = true,
                httpPort = 8080,
                socksEnabled = true,
                socksPort = 1080,
                maxConcurrentClients = 1,
            )
        val exposure =
            ProxyExposureInfo.loopback(
                httpPort = config.httpPort,
                socksPort = config.socksPort,
                lanRequested = false,
            )

        val runtimeConfig = TunnelVpnService.localProxyRuntimeConfig(config, exposure)

        assertNull(runtimeConfig.maxConcurrentClients)
        assertEquals(exposure, runtimeConfig.exposure)
    }

    @Test
    fun manualVpnDnsAdvertisesVirtualResolver() {
        val dnsServers =
            TunnelVpnService.tunDnsServersForBuilder(
                dnsAutomatic = false,
                automaticDnsServers =
                    listOf(
                        ResolvedDnsServerConfig(
                            host = "172.20.21.22",
                            protocol = DnsProtocol.dnsOverUdp,
                            resolvedIpv4 = "172.20.21.22",
                        ),
                    ),
            )

        assertEquals(listOf(TunnelVpnService.MANUAL_DNS_VIRTUAL_IPV4), dnsServers)
    }

    @Test
    fun automaticVpnDnsAdvertisesNegotiatedResolvers() {
        val dnsServers =
            TunnelVpnService.tunDnsServersForBuilder(
                dnsAutomatic = true,
                automaticDnsServers =
                    listOf(
                        ResolvedDnsServerConfig(
                            host = "172.20.21.22",
                            protocol = DnsProtocol.dnsOverUdp,
                            resolvedIpv4 = "172.20.21.22",
                        ),
                    ),
            )

        assertEquals(listOf("172.20.21.22"), dnsServers)
    }

    @Test
    fun actionStopDoesNotEmitStoppedWhenTunnelServiceIsIdle() {
        assertFalse(
            TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
                running = false,
                hasSetupThread = false,
                hasEngineThread = false,
                hasTunInterface = false,
                hasDnsServer = false,
                hasLocalProxyRuntime = false,
            ),
        )
    }

    @Test
    fun actionStopEmitsStoppedWhenTunnelServiceHasActiveState() {
        assertTrue(
            TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
                running = false,
                hasSetupThread = false,
                hasEngineThread = true,
                hasTunInterface = false,
                hasDnsServer = false,
                hasLocalProxyRuntime = false,
            ),
        )
        assertTrue(
            TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
                running = false,
                hasSetupThread = false,
                hasEngineThread = false,
                hasTunInterface = true,
                hasDnsServer = false,
                hasLocalProxyRuntime = false,
            ),
        )
        assertTrue(
            TunnelVpnServiceStopPolicy.shouldEmitStoppedOnActionStop(
                running = false,
                hasSetupThread = true,
                hasEngineThread = false,
                hasTunInterface = false,
                hasDnsServer = false,
                hasLocalProxyRuntime = false,
            ),
        )
    }

    @Test
    fun staleStopRequestIsIgnoredWhenAttemptDoesNotMatchActiveAttempt() {
        assertTrue(
            VpnStopAttemptPolicy.shouldIgnoreStopRequest(
                requestedAttemptId = "attempt-old",
                activeAttemptId = "attempt-new",
            ),
        )
        assertFalse(
            VpnStopAttemptPolicy.shouldIgnoreStopRequest(
                requestedAttemptId = "attempt-current",
                activeAttemptId = "attempt-current",
            ),
        )
        assertFalse(
            VpnStopAttemptPolicy.shouldIgnoreStopRequest(
                requestedAttemptId = "",
                activeAttemptId = "attempt-current",
            ),
        )
    }

    @Test
    fun batteryOptimizationLogPolicySuppressesRepeatedUnrestrictedUntilReset() {
        val policy = BatteryOptimizationLogPolicy()

        assertTrue(policy.shouldLog(BatteryOptimizationDiagnostics.STATE_RESTRICTED))
        assertTrue(policy.shouldLog(BatteryOptimizationDiagnostics.STATE_ALLOWED))
        assertFalse(policy.shouldLog(BatteryOptimizationDiagnostics.STATE_ALLOWED))

        policy.resetSession()
        assertTrue(policy.shouldLog(BatteryOptimizationDiagnostics.STATE_ALLOWED))
    }

    @Test
    fun vpnDisconnectReasonPolicyDistinguishesTaskRemovalSystemDestroy() {
        assertEquals(
            "destroyed_by_android_system" to "Disconnected: stopped by Android system",
            VpnDisconnectReasonPolicy.systemDestroyReason(taskRemoved = false),
        )
        assertEquals(
            "destroyed_by_system_after_task_removed" to "Disconnected: service stopped after app removed from recents",
            VpnDisconnectReasonPolicy.systemDestroyReason(taskRemoved = true),
        )
    }

    @Test
    fun vpnDisconnectReasonPolicySuppressesSystemDestroyAfterAppStop() {
        assertFalse(
            VpnDisconnectReasonPolicy.shouldReportSystemDestroy(
                hasActiveSession = true,
                stopRequested = true,
            ),
        )
        assertFalse(
            VpnDisconnectReasonPolicy.shouldReportSystemDestroy(
                hasActiveSession = false,
                stopRequested = false,
            ),
        )
        assertTrue(
            VpnDisconnectReasonPolicy.shouldReportSystemDestroy(
                hasActiveSession = true,
                stopRequested = false,
            ),
        )
    }

    @Test
    fun l2tpRootPolicySwitchesToUserspaceQuietlyAndLogsExactInfoWhenNotRooted() {
        val noRoot = L2tpRootPolicy.decideBackend(rootDetected = false, forceUserspaceVpn = false)
        assertFalse(noRoot.useRoot)
        assertEquals(Log.INFO, noRoot.logLevel)
        assertEquals(
            "root not detected, switching to userspace VPN for L2TP (default behavior)",
            noRoot.logMessage,
        )

        val noRootForced = L2tpRootPolicy.decideBackend(rootDetected = false, forceUserspaceVpn = true)
        assertFalse(noRootForced.useRoot)
        assertEquals(Log.INFO, noRootForced.logLevel)
        assertEquals(
            "root not detected, switching to userspace VPN for L2TP (default behavior)",
            noRootForced.logMessage,
        )
    }

    @Test
    fun l2tpRootPolicyUsesRootUnlessProfileForcesUserspace() {
        val rootDefault = L2tpRootPolicy.decideBackend(rootDetected = true, forceUserspaceVpn = false)
        assertTrue(rootDefault.useRoot)
        assertEquals(Log.INFO, rootDefault.logLevel)

        val rootForcedUserspace = L2tpRootPolicy.decideBackend(rootDetected = true, forceUserspaceVpn = true)
        assertFalse(rootForcedUserspace.useRoot)
        assertEquals(Log.INFO, rootForcedUserspace.logLevel)
    }
}
