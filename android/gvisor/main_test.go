package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"math"
	"net"
	"os"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
)

func TestTunnelLifecycleAndStats(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	local := [4]byte{192, 0, 2, 1}
	address := unsafe.Pointer(&local[0])
	if tf_gvisor_start(nil, 1500) != -1 || tf_gvisor_start(address, 575) != -1 {
		t.Fatal("start accepted an invalid address or MTU")
	}
	if tf_gvisor_inject_inbound(nil, 4) != -1 || tf_gvisor_inject_inbound(address, 4) != -2 {
		t.Fatal("inject accepted an invalid buffer or stopped stack")
	}
	if tf_gvisor_read_outbound(nil, 4, 0) != -1 {
		t.Fatal("read accepted a nil output")
	}
	if tf_gvisor_tcp_open_cancelable(1, address, 0, 0) != -1 ||
		tf_gvisor_tcp_open_cancelable(1, address, 443, 0) != -2 {
		t.Fatal("open accepted an invalid port or stopped stack")
	}
	if tf_gvisor_tcp_cancel_open(0) != -1 || tf_gvisor_tcp_cancel_open(1) != -2 {
		t.Fatal("cancel accepted an invalid or unknown ID")
	}

	if got := tf_gvisor_start(address, 1500); got != 0 {
		t.Fatalf("start: %d", got)
	}
	left, right := net.Pipe()
	defer right.Close()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	state.mu.Lock()
	state.sessions[1] = &tcpSession{conn: left}
	state.pendingOpenCancels[2] = cancel
	state.mu.Unlock()

	var stats [17]int32
	if tf_gvisor_stats(nil, 17) != -1 || tf_gvisor_stats(unsafe.Pointer(&stats[0]), 16) != 16 ||
		stats[0] != 1 || stats[1] != 1 {
		t.Fatalf("unexpected running stats: %v", stats)
	}
	if got := tf_gvisor_read_outbound(address, 4, 15); got != 0 {
		t.Fatalf("empty queue read: %d", got)
	}
	if got := tf_gvisor_start(address, 1500); got != 0 {
		t.Fatalf("restart: %d", got)
	}
	if ctx.Err() != context.Canceled {
		t.Fatal("restarting left a pending open uncanceled")
	}
	if _, err := right.Read(local[:]); err != io.EOF {
		t.Fatalf("restarting left an active session open: %v", err)
	}
	tf_gvisor_stop()
	if tf_gvisor_stats(unsafe.Pointer(&stats[0]), 17) != 17 || stats[0] != 0 || stats[1] != 0 {
		t.Fatalf("unexpected stopped stats: %v", stats)
	}
}

func TestTunnelDiagnosticABIAndHistory(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	finishOpenFailure(1, -3, "fixture")
	var buf [128]byte
	out := unsafe.Pointer(&buf[0])
	if tf_gvisor_last_open_diagnostics(nil, 4) != -1 || tf_gvisor_open_diagnostics(0, out, 4) != -1 {
		t.Fatal("diagnostics accepted invalid output arguments")
	}
	if n := tf_gvisor_last_open_diagnostics(out, 4); n != 3 || !bytes.Equal(buf[:4], []byte("ope\x00")) {
		t.Fatalf("truncated last diagnostic: %d %q", n, buf[:4])
	}
	if n := tf_gvisor_open_diagnostics(1, out, 4); n != 3 || !bytes.Equal(buf[:4], []byte("ope\x00")) {
		t.Fatalf("truncated open diagnostic: %d %q", n, buf[:4])
	}
	n := tf_gvisor_open_diagnostics(1, out, 128)
	if n <= 0 || !strings.Contains(string(buf[:n]), "reason=fixture missing=true") || buf[n] != 0 {
		t.Fatalf("unexpected diagnostic: %d %q", n, buf[:])
	}
	for id := 2; id <= 129; id++ {
		finishOpenFailure(id, -3, "fixture")
	}
	if n := tf_gvisor_open_diagnostics(1, out, 128); n != 0 || buf[0] != 0 {
		t.Fatalf("expired diagnostic: %d %q", n, buf[:])
	}
}

type failingConn struct {
	net.Conn
	err error
}

func (c failingConn) Read([]byte) (int, error)  { return 0, c.err }
func (c failingConn) Write([]byte) (int, error) { return 0, c.err }

func TestTunnelTCPIOErrorCodes(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	var byteBuffer byte
	out := unsafe.Pointer(&byteBuffer)
	if tf_gvisor_tcp_read(1, nil, 1, 0) != -1 || tf_gvisor_tcp_write(1, nil, 1, 0) != -1 ||
		tf_gvisor_tcp_read(1, out, 1, 0) != -2 || tf_gvisor_tcp_write(1, out, 1, 0) != -2 {
		t.Fatal("I/O accepted an invalid buffer or unknown session")
	}
	for _, row := range []struct {
		name  string
		err   error
		read  int
		write int
	}{
		{"eof", io.EOF, 0, -3},
		{"closed", net.ErrClosed, -2, -2},
		{"timeout", os.ErrDeadlineExceeded, -4, -4},
		{"gvisor_timeout", &net.OpError{Op: "read", Err: errors.New("operation timed out")}, -4, -4},
		{"reset", syscall.ECONNRESET, -5, -5},
		{"gvisor_reset", &net.OpError{Op: "read", Err: errors.New("connection reset by peer")}, -5, -5},
		{"gvisor_aborted", &net.OpError{Op: "read", Err: errors.New("operation aborted")}, -2, -2},
		{"gvisor_closed_for_send", &net.OpError{Op: "write", Err: errors.New("endpoint is closed for send")}, -5, -5},
		{"gvisor_broken_pipe", &net.OpError{Op: "write", Err: errors.New("broken pipe")}, -5, -5},
		{"unexpected", errors.New("fixture"), -3, -3},
	} {
		t.Run(row.name, func(t *testing.T) {
			left, right := net.Pipe()
			defer right.Close()
			state.mu.Lock()
			state.sessions = map[int]*tcpSession{1: {conn: failingConn{Conn: left, err: row.err}}}
			state.mu.Unlock()
			defer tf_gvisor_tcp_close(1)
			if got := tf_gvisor_tcp_read(1, out, 1, 100); int(got) != row.read {
				t.Errorf("read: got %d, want %d", got, row.read)
			}
			if got := tf_gvisor_tcp_write(1, out, 1, 100); int(got) != row.write {
				t.Errorf("write: got %d, want %d", got, row.write)
			}
		})
	}
}

func TestClassifyOpenError(t *testing.T) {
	for _, row := range []struct {
		err    error
		code   int
		reason string
	}{
		{net.ErrClosed, -2, "local-close"},
		{syscall.ECONNRESET, -5, "reset"},
		{syscall.ENETUNREACH, -6, "unreachable"},
		{errors.New("Connection Reset"), -5, "reset"},
		{errors.New("Network Unreachable"), -6, "unreachable"},
		{errors.New("fixture"), -3, "internal"},
	} {
		if code, reason := classifyOpenError(row.err); code != row.code || reason != row.reason {
			t.Errorf("%v: got %d/%s, want %d/%s", row.err, code, reason, row.code, row.reason)
		}
	}
}

func TestStackSetupFailureClosesTheEndpoint(t *testing.T) {
	t.Cleanup(tf_gvisor_stop)
	ip := tcpip.AddrFrom4([4]byte{192, 0, 2, 1})
	s := stack.New(stack.Options{})
	existing := channel.New(1, 1500, "")
	if err := s.CreateNIC(nicID, existing); err != nil {
		t.Fatal(err)
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if got := startStackLocked(s, channel.New(1, 1500, ""), ip); got != -2 {
		t.Fatalf("duplicate NIC: %d", got)
	}
	if got := startStackLocked(stack.New(stack.Options{}), channel.New(1, 1500, ""), ip); got != -3 {
		t.Fatalf("missing IPv4 protocol: %d", got)
	}
	if state.running || state.linkEP != nil {
		t.Fatal("failed setup published a running stack")
	}
}

func TestOpenFailureDiagnosticsAndCounters(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	local := [4]byte{192, 0, 2, 1}
	remote := [4]byte{192, 0, 2, 2}
	if got := tf_gvisor_start(unsafe.Pointer(&local[0]), 1500); got != 0 {
		t.Fatalf("start: %d", got)
	}
	state.mu.Lock()
	beginOpenLocked(1, remote[:], 443)
	state.mu.Unlock()
	if got := tf_gvisor_tcp_open_cancelable(1, unsafe.Pointer(&remote[0]), 443, 0); got != -1 {
		t.Fatalf("duplicate open: %d", got)
	}
	if got := tf_gvisor_tcp_open_cancelable(2, unsafe.Pointer(&remote[0]), 443, 15); got != -4 {
		t.Fatalf("open without a peer: %d", got)
	}
	for _, row := range []struct {
		contextErr error
		err        error
		code       int
		reason     string
	}{
		{context.Canceled, nil, -7, "client-aborted"},
		{nil, syscall.ECONNRESET, -5, "reset"},
		{nil, syscall.EHOSTUNREACH, -6, "unreachable"},
		{nil, errors.New("fixture"), -3, "internal"},
	} {
		if got := recordDialFailure(1, row.contextErr, row.err); got != row.code {
			t.Errorf("%s code: %d", row.reason, got)
		}
		var message [128]byte
		n := tf_gvisor_open_diagnostics(1, unsafe.Pointer(&message[0]), 128)
		if !strings.Contains(string(message[:n]), "reason="+row.reason) {
			t.Errorf("%s missing from %q", row.reason, message[:n])
		}
	}
	if state.openFailed.Load() != 6 || state.openTimeouts.Load() != 1 ||
		state.openCanceled.Load() != 1 || state.openResets.Load() != 1 ||
		state.openImmediate.Load() != 2 || state.openInternal.Load() != 1 {
		t.Fatal("failure counts do not match the observed outcomes")
	}
}

func TestTunnelPacketRoundTrip(t *testing.T) {
	const mtu = 1500
	const packetSize = header.IPv4MinimumSize + header.ICMPv4MinimumSize
	local := [4]byte{192, 0, 2, 1}
	peer := [4]byte{192, 0, 2, 2}
	if got := tf_gvisor_start(unsafe.Pointer(&local[0]), mtu); got != 0 {
		t.Fatalf("start returned %d", got)
	}
	t.Cleanup(tf_gvisor_stop)

	var packet [packetSize]byte
	ip := header.IPv4(packet[:])
	ip.Encode(&header.IPv4Fields{
		TotalLength: uint16(len(packet)),
		TTL:         64,
		Protocol:    uint8(header.ICMPv4ProtocolNumber),
		SrcAddr:     tcpip.AddrFrom4(peer),
		DstAddr:     tcpip.AddrFrom4(local),
	})
	ip.SetChecksum(^ip.CalculateChecksum())
	echo := header.ICMPv4(ip.Payload())
	echo.SetType(header.ICMPv4Echo)
	echo.SetIdent(42)
	echo.SetChecksum(header.ICMPv4Checksum(echo, 0))

	if got := tf_gvisor_inject_inbound(unsafe.Pointer(&packet[0]), packetSize); got != 0 {
		t.Fatalf("inject returned %d", got)
	}
	var reply [mtu]byte
	if got := tf_gvisor_read_outbound(unsafe.Pointer(&reply[0]), 4, 1000); got != -3 {
		t.Fatalf("read into undersized output: %d", got)
	}
	if got := tf_gvisor_inject_inbound(unsafe.Pointer(&packet[0]), packetSize); got != 0 {
		t.Fatalf("inject after short read: %d", got)
	}
	n := tf_gvisor_read_outbound(unsafe.Pointer(&reply[0]), mtu, 1000)
	if n != packetSize {
		t.Fatalf("read returned %d, want %d", n, len(packet))
	}
	response := header.IPv4(reply[:n])
	if response.SourceAddress() != tcpip.AddrFrom4(local) || response.DestinationAddress() != tcpip.AddrFrom4(peer) {
		t.Fatalf("unexpected reply addresses: %s to %s", response.SourceAddress(), response.DestinationAddress())
	}
	echoReply := header.ICMPv4(response.Payload())
	if echoReply.Type() != header.ICMPv4EchoReply || echoReply.Ident() != 42 {
		t.Fatalf("unexpected ICMP reply: %x", echoReply)
	}

	tf_gvisor_stop()
	if got := tf_gvisor_read_outbound(unsafe.Pointer(&reply[0]), mtu, 0); got != -2 {
		t.Fatalf("read after stop returned %d, want -2", got)
	}
}

func TestIDsWrapAtTheCIntBoundary(t *testing.T) {
	next := math.MaxInt32
	if got := takeNextID(&next); got != math.MaxInt32 || next != 1 {
		t.Fatalf("ID wrapping: got %d, next %d", got, next)
	}
}

func TestDiagnosticsIgnoreUnrelatedTrafficAndTrackFinish(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	local := [4]byte{192, 0, 2, 1}
	remote := [4]byte{192, 0, 2, 2}
	unrelated := [4]byte{192, 0, 2, 3}
	syn := buildTCPPacket(local, remote, 42000, 443, tcpFlagSyn)
	fin := buildTCPPacket(remote, local, 443, 42000, tcpFlagFin)
	noteOutboundPacket(syn)
	noteInboundPacket(fin)
	state.mu.Lock()
	finishOpenSuccessLocked(999, 1)
	beginOpenLocked(1, remote[:], 443)
	beginOpenLocked(2, unrelated[:], 443)
	beginOpenLocked(3, remote[:], 443)
	state.pendingOpens[3].localPort = 42001
	state.mu.Unlock()
	noteOutboundPacket(syn)
	noteInboundPacket(fin)
	state.mu.Lock()
	defer state.mu.Unlock()
	if got := state.pendingOpens[1]; got.localPort != 42000 || got.synCount != 1 || got.finCount != 1 {
		t.Fatalf("incorrect diagnostics: %+v", got)
	}
	if state.pendingOpens[2].synCount != 0 || state.pendingOpens[3].synCount != 0 {
		t.Fatal("the SYN was associated with a different open")
	}
}

func TestTCPDiagnosticsValidateHeaderSizes(t *testing.T) {
	local := [4]byte{192, 0, 2, 1}
	remote := [4]byte{192, 0, 2, 2}
	packet := buildTCPPacket(local, remote, 42000, 443, tcpFlagSyn)
	packet[0] = 0x44
	if _, ok := parseIPv4TCPPacket(packet); ok {
		t.Fatal("accepted a short IPv4 header")
	}
	packet[0] = 0x45
	packet[32] = 0x40
	if _, ok := parseIPv4TCPPacket(packet); ok {
		t.Fatal("accepted a short TCP header")
	}
}

func TestLibraryEntryPointLeavesStackStopped(t *testing.T) {
	tf_gvisor_stop()
	main()
	var stats [17]int32
	if tf_gvisor_stats(unsafe.Pointer(&stats[0]), 17) != 17 || stats[0] != 0 {
		t.Fatalf("library entry point changed running state: %v", stats)
	}
}

func TestTunnelTCPSessionRoundTrip(t *testing.T) {
	const mtu = 1500
	local := [4]byte{192, 0, 2, 1}
	remote := [4]byte{192, 0, 2, 2}
	if got := tf_gvisor_start(unsafe.Pointer(&local[0]), mtu); got != 0 {
		t.Fatalf("start returned %d", got)
	}
	t.Cleanup(tf_gvisor_stop)
	peer := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol},
	})
	defer peer.Close()
	peerLink := channel.New(16, mtu, "")
	defer peerLink.Close()
	if err := peer.CreateNIC(nicID, peerLink); err != nil {
		t.Fatal(err)
	}
	peerAddr := tcpip.AddrFrom4(remote)
	if err := peer.AddProtocolAddress(nicID, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddressWithPrefix{Address: peerAddr, PrefixLen: 32},
	}, stack.AddressProperties{}); err != nil {
		t.Fatal(err)
	}
	peer.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: nicID}})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go forwardTestPackets(ctx, state.linkEP, peerLink)
	go forwardTestPackets(ctx, peerLink, state.linkEP)

	const port = 8080
	listener, err := gonet.ListenTCP(peer, tcpip.FullAddress{
		NIC: nicID, Addr: peerAddr, Port: port,
	}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()

	session := tf_gvisor_tcp_open(unsafe.Pointer(&remote[0]), port, 2000)
	if session <= 0 {
		t.Fatalf("open returned %d", session)
	}
	defer tf_gvisor_tcp_close(session)
	conn, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}

	const messageSize = 4
	request := [messageSize]byte{'p', 'i', 'n', 'g'}
	if got := tf_gvisor_tcp_write(session, unsafe.Pointer(&request[0]), messageSize, 1000); got != messageSize {
		t.Fatalf("write returned %d", got)
	}
	var buffer [messageSize]byte
	if _, err := io.ReadFull(conn, buffer[:]); err != nil || buffer != request {
		t.Fatalf("peer received %q, error %v", buffer, err)
	}
	response := [messageSize]byte{'p', 'o', 'n', 'g'}
	if _, err := conn.Write(response[:]); err != nil {
		t.Fatal(err)
	}
	if got := tf_gvisor_tcp_read(session, unsafe.Pointer(&buffer[0]), messageSize, 1000); got != messageSize || buffer != response {
		t.Fatalf("read returned %d with %q", got, buffer)
	}

	tf_gvisor_tcp_close(session)
	if got := tf_gvisor_tcp_read(session, unsafe.Pointer(&buffer[0]), messageSize, 0); got != -2 {
		t.Fatalf("read after close returned %d, want -2", got)
	}
}

func forwardTestPackets(ctx context.Context, from, to *channel.Endpoint) {
	for packet := from.ReadContext(ctx); packet != nil; packet = from.ReadContext(ctx) {
		inbound := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: packet.ToBuffer()})
		to.InjectInbound(ipv4.ProtocolNumber, inbound)
		inbound.DecRef()
		packet.DecRef()
	}
}

func TestParseIPv4TCPPacketExtractsFlowAndFlags(t *testing.T) {
	packet := buildTCPPacket([4]byte{10, 0, 0, 2}, [4]byte{203, 0, 113, 10}, 42000, 443, tcpFlagSyn)

	parsed, ok := parseIPv4TCPPacket(packet)
	if !ok {
		t.Fatal("parseIPv4TCPPacket returned false")
	}
	if parsed.flow.src != [4]byte{10, 0, 0, 2} || parsed.flow.dst != [4]byte{203, 0, 113, 10} {
		t.Fatalf("unexpected flow addresses: %+v", parsed.flow)
	}
	if parsed.flow.sport != 42000 || parsed.flow.dport != 443 {
		t.Fatalf("unexpected ports: %+v", parsed.flow)
	}
	if parsed.flags != tcpFlagSyn {
		t.Fatalf("unexpected flags: 0x%x", parsed.flags)
	}
}

func TestParseIPv4TCPPacketIgnoresMalformedAndNonTCP(t *testing.T) {
	if _, ok := parseIPv4TCPPacket([]byte{0x45}); ok {
		t.Fatal("short packet parsed")
	}
	packet := buildTCPPacket([4]byte{10, 0, 0, 2}, [4]byte{203, 0, 113, 10}, 42000, 443, tcpFlagSyn)
	packet[9] = 17
	if _, ok := parseIPv4TCPPacket(packet); ok {
		t.Fatal("non-TCP packet parsed")
	}
	packet[9] = tcpProtocol
	packet[3] = 39
	if _, ok := parseIPv4TCPPacket(packet); ok {
		t.Fatal("malformed total length parsed")
	}
}

func TestOpenDiagnosticsMatchSynSynAckAndRst(t *testing.T) {
	resetGvisorDiagnosticsForTest()
	state.mu.Lock()
	attempt := beginOpenLocked(1, []byte{203, 0, 113, 10}, 443)
	state.mu.Unlock()

	outbound := buildTCPPacket([4]byte{10, 0, 0, 2}, [4]byte{203, 0, 113, 10}, 42000, 443, tcpFlagSyn)
	noteOutboundPacket(outbound)
	noteOutboundPacket(outbound)
	inboundSynAck := buildTCPPacket([4]byte{203, 0, 113, 10}, [4]byte{10, 0, 0, 2}, 443, 42000, tcpFlagSyn|tcpFlagAck)
	inboundRst := buildTCPPacket([4]byte{203, 0, 113, 10}, [4]byte{10, 0, 0, 2}, 443, 42000, tcpFlagRst|tcpFlagAck)
	noteInboundPacket(inboundSynAck)
	noteInboundPacket(inboundRst)

	state.mu.Lock()
	diag := state.pendingOpens[attempt]
	state.mu.Unlock()
	if diag == nil {
		t.Fatal("missing pending open diagnostics")
	}
	if diag.localPort != 42000 || diag.synCount != 2 || diag.synAckCount != 1 || diag.rstCount != 1 {
		t.Fatalf("unexpected diagnostics: %+v", diag)
	}
	if state.openSynOut.Load() != 2 || state.openSynAckIn.Load() != 1 || state.openRstIn.Load() != 1 {
		t.Fatalf(
			"unexpected counters syn=%d synAck=%d rst=%d",
			state.openSynOut.Load(),
			state.openSynAckIn.Load(),
			state.openRstIn.Load(),
		)
	}
}

func TestFinishOpenFailureStoresDiagnosticSummary(t *testing.T) {
	resetGvisorDiagnosticsForTest()
	state.mu.Lock()
	attempt := beginOpenLocked(1, []byte{203, 0, 113, 10}, 443)
	state.mu.Unlock()

	noteOutboundPacket(buildTCPPacket([4]byte{10, 0, 0, 2}, [4]byte{203, 0, 113, 10}, 42000, 443, tcpFlagSyn))
	finishOpenFailure(attempt, -4, "timeout")

	state.mu.Lock()
	summary := state.completedOpenDiags[attempt]
	_, pending := state.pendingOpens[attempt]
	state.mu.Unlock()
	if pending {
		t.Fatal("pending open was not removed after failure")
	}
	if summary == "" {
		t.Fatal("last open diagnostics was empty")
	}
	for _, want := range []string{"openId=1", "sessionId=0", "code=-4", "reason=timeout", "remotePort=443", "localPort=42000", "syn=1"} {
		if !strings.Contains(summary, want) {
			t.Fatalf("diagnostics %q missing %q", summary, want)
		}
	}
}

func TestCancelPendingOpenInvokesRegisteredCancel(t *testing.T) {
	resetGvisorDiagnosticsForTest()
	called := false
	state.mu.Lock()
	state.pendingOpenCancels[7] = func() { called = true }
	state.mu.Unlock()

	if got := tf_gvisor_tcp_cancel_open(7); got != 0 {
		t.Fatalf("cancel result=%d, want 0", got)
	}
	if !called {
		t.Fatal("registered cancel was not called")
	}
}

func TestCompletedDiagnosticsArePerOpen(t *testing.T) {
	resetGvisorDiagnosticsForTest()
	state.mu.Lock()
	first := beginOpenLocked(101, []byte{203, 0, 113, 10}, 443)
	second := beginOpenLocked(202, []byte{198, 51, 100, 20}, 8443)
	state.mu.Unlock()

	finishOpenFailure(first, -4, "timeout")
	finishOpenFailure(second, -7, "client-aborted")

	state.mu.Lock()
	firstDiag := state.completedOpenDiags[first]
	secondDiag := state.completedOpenDiags[second]
	state.mu.Unlock()
	if !strings.Contains(firstDiag, "openId=101") || !strings.Contains(firstDiag, "code=-4") || !strings.Contains(firstDiag, "remotePort=443") {
		t.Fatalf("unexpected first diagnostics: %q", firstDiag)
	}
	if !strings.Contains(secondDiag, "openId=202") || !strings.Contains(secondDiag, "code=-7") || !strings.Contains(secondDiag, "remotePort=8443") {
		t.Fatalf("unexpected second diagnostics: %q", secondDiag)
	}
}

func resetGvisorDiagnosticsForTest() {
	state.mu.Lock()
	defer state.mu.Unlock()
	state.pendingOpens = make(map[int]*tcpOpenDiag)
	state.pendingOpenCancels = make(map[int]context.CancelFunc)
	state.flowToOpenAttemptID = make(map[tcpFlowKey]int)
	state.completedOpenDiags = make(map[int]string)
	state.completedOpenOrder = nil
	state.nextOpenAttemptID = 1
	state.lastOpenDiagnostics = ""
	state.openCanceled.Store(0)
	state.openSynOut.Store(0)
	state.openSynAckIn.Store(0)
	state.openRstIn.Store(0)
}

func buildTCPPacket(src, dst [4]byte, sport, dport uint16, flags byte) []byte {
	packet := make([]byte, 40)
	packet[0] = 0x45
	packet[2] = 0
	packet[3] = 40
	packet[8] = 64
	packet[9] = tcpProtocol
	copy(packet[12:16], src[:])
	copy(packet[16:20], dst[:])
	packet[20] = byte(sport >> 8)
	packet[21] = byte(sport)
	packet[22] = byte(dport >> 8)
	packet[23] = byte(dport)
	packet[32] = 0x50
	packet[33] = flags
	return packet
}

func TestLastPacketAgeIsMinusOneWhenNoPacketsObserved(t *testing.T) {
	diag := &tcpOpenDiag{startedAt: time.Now()}
	if got := lastPacketAgeMs(diag); got != -1 {
		t.Fatalf("lastPacketAgeMs=%d, want -1", got)
	}
}

func TestConcurrentStopClosesStackAndGuardsNilMaps(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	runtime.GC()
	baseline := runtime.NumGoroutine()
	local := [4]byte{192, 0, 2, 1}
	for i := 0; i < 20; i++ {
		if got := tf_gvisor_start(unsafe.Pointer(&local[0]), 1500); got != 0 {
			t.Fatalf("cycle %d start=%d", i, got)
		}
		tf_gvisor_stop()
	}
	deadline := time.Now().Add(2 * time.Second)
	for runtime.NumGoroutine() > baseline+2 && time.Now().Before(deadline) {
		runtime.Gosched()
		time.Sleep(10 * time.Millisecond)
	}
	if after := runtime.NumGoroutine(); after > baseline+2 {
		t.Fatalf("goroutines leaked across 20 start/stop cycles: baseline=%d after=%d", baseline, after)
	}

	// Race concurrent tcp_open against stop across 20 cycles.
	remote := [4]byte{192, 0, 2, 2}
	for i := 0; i < 20; i++ {
		if got := tf_gvisor_start(unsafe.Pointer(&local[0]), 1500); got != 0 {
			t.Fatalf("race cycle %d start=%d", i, got)
		}
		done := make(chan int, 1)
		go func() {
			done <- int(tf_gvisor_tcp_open(unsafe.Pointer(&remote[0]), 443, 500))
		}()
		time.Sleep(time.Millisecond)
		tf_gvisor_stop()
		if got := <-done; got >= 0 {
			t.Fatalf("race cycle %d expected failure after stop, got session=%d", i, got)
		}
	}
}

func TestGvisorReadOutboundWakesWithout5msSleep(t *testing.T) {
	tf_gvisor_stop()
	t.Cleanup(tf_gvisor_stop)
	local := [4]byte{192, 0, 2, 1}
	remote := [4]byte{192, 0, 2, 2}
	if got := tf_gvisor_start(unsafe.Pointer(&local[0]), 1500); got != 0 {
		t.Fatalf("start=%d", got)
	}
	var out [2048]byte
	// Measure across 3 cycles so OS scheduler jitter cannot spoof < 3ms median wakeup.
	var totalAfterInject time.Duration
	const cycles = 3
	for i := 0; i < cycles; i++ {
		readDone := make(chan time.Time, 1)
		go func() {
			n := tf_gvisor_read_outbound(unsafe.Pointer(&out[0]), 2048, 200)
			if n <= 0 {
				t.Errorf("cycle %d read_outbound=%d", i, n)
			}
			readDone <- time.Now()
		}()
		time.Sleep(500 * time.Microsecond)
		injectAt := time.Now()
		go func() {
			_ = tf_gvisor_tcp_open(unsafe.Pointer(&remote[0]), 443, 50)
		}()
		finishedAt := <-readDone
		totalAfterInject += finishedAt.Sub(injectAt)
	}
	avg := totalAfterInject / cycles
	if avg >= 3*time.Millisecond {
		t.Fatalf("tf_gvisor_read_outbound avg latency after inject=%v (expected < 3ms without 5ms poll sleep)", avg)
	}
}
