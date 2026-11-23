package io.github.evokelektrique.tunnelforge

import androidx.annotation.Keep

/** JNI `tunnel_engine`. TUN fd owned by [TunnelVpnService] (do not close from native). UDP: [TunnelVpnService.protectSocketFd] before I/O. */
@Keep
object VpnBridge {
    const val PROTOCOL_L2TP = 0
    const val PROTOCOL_PPTP = 1

    const val EXIT_OK = 0
    const val EXIT_IKE_FAILED = 1
    const val EXIT_L2TP_FAILED = 2
    const val EXIT_PPP_FAILED = 3
    const val EXIT_POLL_ERROR = 4
    const val EXIT_PPTP_FAILED = 5
    const val EXIT_ROOT_UNAVAILABLE = 6
    const val EXIT_ROOT_DENIED = 7
    const val EXIT_GRE_SOCKET_FAILED = 8
    const val EXIT_MPPE_FAILED = 9
    const val EXIT_BAD_ARGS = 10
    const val EXIT_PROXY_NOT_IMPLEMENTED = 11
    const val EXIT_STOPPED = 12
    const val EXIT_NETWORK_LOST = 13
    const val EXIT_PEER_UNREACHABLE = 14
    const val EXIT_PEER_CLOSED = 15

    fun protocolCode(protocol: String): Int =
        if (protocol == VpnContract.PROTOCOL_PPTP) PROTOCOL_PPTP else PROTOCOL_L2TP

    init {
        System.loadLibrary("tunnel_engine")
    }

    /**
     * On success, fills [outClientIpv4] with four octets 0–255 (PPP IPCP local IPv4) when non-null and length ≥ 4.
     */
    @JvmStatic
    external fun nativeNegotiate(
        server: String,
        user: String,
        password: String,
        psk: String,
        tunMtu: Int,
        protocol: Int,
        outClientIpv4: IntArray?,
        outPrimaryDnsIpv4: IntArray?,
        outSecondaryDnsIpv4: IntArray?,
    ): Int

    @JvmStatic
    external fun nativeSetSocketProtectionEnabled(enabled: Boolean)

    @JvmStatic
    external fun nativeSetPptpRuntimeConfig(helperPath: String, bindInterface: String)

    @JvmStatic
    external fun nativeFailure(): IntArray

    /** Read on the same worker that negotiated/ran the native tunnel. */
    fun failure(exitCode: Int? = null): Map<String, Any>? {
        val values = nativeFailure()
        val namespace = when (values[0]) {
            1 -> "mschap"
            2 -> "l2tp-stopccn"
            3 -> "l2tp-cdn"
            4 -> "chap"
            5 -> "pap"
            6 -> "pptp-ctrl"
            7 -> "pptp-call"
            8 -> "pptp-cdn"
            else -> if (exitCode != null) "engine" else return null
        }
        return mapOf(
            "namespace" to namespace,
            "code" to (if (namespace == "engine") exitCode!! else values[1]),
            "generalError" to values[2],
        )
    }

    @JvmStatic
    external fun nativeStartLoop(tunFd: Int): Int

    @JvmStatic
    external fun nativeStartProxyLoop(): Int

    /*
     * gVisor bridge calls are used only by proxy-only mode. Packet direction is relative to
     * gVisor: inbound packets are injected from PPP, outbound packets are read for PPP send.
     */
    @JvmStatic
    external fun nativeGvisorStart(clientIpv4: IntArray, mtu: Int): Int

    @JvmStatic
    external fun nativeGvisorStop()

    @JvmStatic
    external fun nativeGvisorInjectInbound(packet: ByteArray): Int

    @JvmStatic
    external fun nativeGvisorReadOutbound(maxLen: Int, timeoutMs: Int): ByteArray?

    @JvmStatic
    external fun nativeGvisorTcpOpenCancelable(openId: Int, remoteIpv4: IntArray, port: Int, timeoutMs: Int): Int

    @JvmStatic
    external fun nativeGvisorTcpCancelOpen(openId: Int): Int

    @JvmStatic
    external fun nativeGvisorTcpRead(sessionId: Int, maxLen: Int, timeoutMs: Int): ByteArray?

    @JvmStatic
    external fun nativeGvisorTcpWrite(sessionId: Int, bytes: ByteArray, timeoutMs: Int): Int

    @JvmStatic
    external fun nativeGvisorTcpClose(sessionId: Int)

    @JvmStatic
    external fun nativeGvisorStats(): IntArray

    @JvmStatic
    external fun nativeGvisorOpenDiagnostics(openId: Int): String

    @JvmStatic
    external fun nativeIsProxyPacketBridgeActive(): Boolean

    @JvmStatic
    external fun nativeQueueProxyOutboundPacket(packet: ByteArray): Int

    @JvmStatic
    external fun nativeReadProxyInboundPacket(maxLen: Int): ByteArray?

    @JvmStatic
    external fun nativeSetVpnDnsInterceptIpv4(ipv4: String?): Int

    @JvmStatic
    external fun nativeReadVpnDnsQuery(maxLen: Int): ByteArray?

    @JvmStatic
    external fun nativeQueueVpnDnsResponse(packet: ByteArray): Int

    @JvmStatic
    external fun nativeStopTunnel()

    @androidx.annotation.VisibleForTesting
    @JvmStatic
    external fun nativeRunAuditCheck(itemId: Int): String?
}
