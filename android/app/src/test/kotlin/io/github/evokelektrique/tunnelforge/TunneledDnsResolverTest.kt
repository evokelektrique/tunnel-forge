package io.github.evokelektrique.tunnelforge

import java.net.Socket
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TunneledDnsResolverTest {
    @Test
    fun `handleInboundPacket ignores mismatched TxID and accepts matching TxID`() {
        val resolverRef = AtomicReference<TunneledDnsResolver>()
        var mismatchedAccepted = true
        var matchingAccepted = false
        val bridge =
            ProxyPacketBridge(
                backend =
                    object : ProxyPacketBridgeBackend {
                        override fun isActive(): Boolean = true

                        override fun queueOutboundPacket(packet: ByteArray): Int {
                            val resolver = resolverRef.get() ?: return -1
                            val ipv4 = IpPacketParser.parseIpv4(packet) ?: return -1
                            val udp = IpPacketParser.parseUdp(packet, ipv4) ?: return -1
                            val query = packet.copyOfRange(udp.payloadOffset, udp.payloadOffset + udp.payloadLength)
                            val txId = ((query[0].toInt() and 0xff) shl 8) or (query[1].toInt() and 0xff)
                            val wrongTxId = txId xor 0x00ff

                            val wrongReply =
                                UdpPacketBuilder.buildIpv4UdpPacket(
                                    sourceIp = ipv4.destinationIp,
                                    destinationIp = ipv4.sourceIp,
                                    sourcePort = udp.destinationPort,
                                    destinationPort = udp.sourcePort,
                                    payload = buildDnsAResponse(query, wrongTxId, byteArrayOf(1, 2, 3, 4)),
                                )
                            val wrongIpv4 = IpPacketParser.parseIpv4(wrongReply)!!
                            val wrongUdp = IpPacketParser.parseUdp(wrongReply, wrongIpv4)!!
                            mismatchedAccepted = resolver.handleInboundPacket(wrongIpv4, wrongUdp, wrongReply)

                            val okReply =
                                UdpPacketBuilder.buildIpv4UdpPacket(
                                    sourceIp = ipv4.destinationIp,
                                    destinationIp = ipv4.sourceIp,
                                    sourcePort = udp.destinationPort,
                                    destinationPort = udp.sourcePort,
                                    payload = buildDnsAResponse(query, txId, byteArrayOf(93, 184.toByte(), 216.toByte(), 34)),
                                )
                            val okIpv4 = IpPacketParser.parseIpv4(okReply)!!
                            val okUdp = IpPacketParser.parseUdp(okReply, okIpv4)!!
                            matchingAccepted = resolver.handleInboundPacket(okIpv4, okUdp, okReply)
                            return 0
                        }

                        override fun readInboundPacket(maxLen: Int): ByteArray? = null
                    },
            )
        assertTrue(bridge.waitUntilActive(timeoutMs = 100))

        val resolver =
            TunneledDnsResolver(
                bridge = bridge,
                clientIpv4 = "10.0.0.2",
                dnsServers =
                    listOf(
                        ResolvedDnsServerConfig(
                            host = "1.1.1.1",
                            protocol = DnsProtocol.dnsOverUdp,
                            resolvedIpv4 = "1.1.1.1",
                        ),
                    ),
                openTunneledSocket = { Socket() },
                logger = { _, _ -> },
            )
        resolverRef.set(resolver)

        val resolved = resolver.resolve("example.com")
        assertFalse(mismatchedAccepted)
        assertTrue(matchingAccepted)
        assertEquals("93.184.216.34", resolved)
    }

    private fun buildDnsAResponse(query: ByteArray, txId: Int, ipv4Bytes: ByteArray): ByteArray {
        val questionEnd = findQuestionEnd(query)
        val headerAndQuestion = query.copyOf(questionEnd)
        headerAndQuestion[0] = ((txId ushr 8) and 0xff).toByte()
        headerAndQuestion[1] = (txId and 0xff).toByte()
        headerAndQuestion[2] = 0x81.toByte()
        headerAndQuestion[3] = 0x80.toByte()
        headerAndQuestion[6] = 0x00
        headerAndQuestion[7] = 0x01
        val answer =
            byteArrayOf(
                0xc0.toByte(), 0x0c,
                0x00, 0x01,
                0x00, 0x01,
                0x00, 0x00, 0x00, 0x3c,
                0x00, 0x04,
                ipv4Bytes[0], ipv4Bytes[1], ipv4Bytes[2], ipv4Bytes[3],
            )
        return headerAndQuestion + answer
    }

    private fun findQuestionEnd(query: ByteArray): Int {
        var i = 12
        while (i < query.size) {
            val len = query[i].toInt() and 0xff
            if (len == 0) return i + 5
            i += 1 + len
        }
        return query.size
    }
}
