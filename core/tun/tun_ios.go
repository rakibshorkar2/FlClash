//go:build ios && cgo

package tun

import (
	"errors"
	"sync"

	"github.com/metacubex/gvisor/pkg/buffer"
	"github.com/metacubex/gvisor/pkg/tcpip"
	"github.com/metacubex/gvisor/pkg/tcpip/header"
	"github.com/metacubex/gvisor/pkg/tcpip/link/channel"
	"github.com/metacubex/gvisor/pkg/tcpip/link/qdisc/fifo"
	"github.com/metacubex/gvisor/pkg/tcpip/stack"
	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"strings"

	stun "github.com/metacubex/sing-tun"
)

const (
	afInet  = 2
	afInet6 = 30
)

var errInvalidPacket = errors.New("ios tun: invalid packet")

// iosPacket is a single IP packet read from the Network Extension packet flow.
type iosPacket struct {
	family uint8
	data   []byte
}

// iosPacketTun is a sing-tun device backed by NEPacketTunnelProvider's
// packetFlow instead of a real utun interface. It implements stun.GVisorTun so
// the gvisor stack can run entirely in user space inside the Network Extension
// sandbox.
type iosPacketTun struct {
	mtu      uint32
	packets  chan *iosPacket
	closed   chan struct{}
	closeOne sync.Once

	mu       sync.RWMutex
	endpoint *channel.Endpoint
	notify   *channel.NotificationHandle
}

var (
	activeMu sync.RWMutex
	active   *iosPacketTun
)

// IOSInjectPacket is called from the C bridge when Swift reads packets from
// packetFlow.readPackets and hands them to the core. It is safe to call from
// any thread.
func IOSInjectPacket(data []byte, family uint8) {
	activeMu.RLock()
	dev := active
	activeMu.RUnlock()
	if dev == nil {
		return
	}
	dev.inject(data, family)
}

func (t *iosPacketTun) inject(data []byte, family uint8) {
	pkt := &iosPacket{family: family, data: data}
	select {
	case t.packets <- pkt:
	default:
	}
}

func newIOSPacketTun(mtu uint32) *iosPacketTun {
	return &iosPacketTun{
		mtu:     mtu,
		packets: make(chan *iosPacket, 256),
		closed:  make(chan struct{}),
	}
}

// --- stun.Tun interface ---

func (t *iosPacketTun) Read(p []byte) (n int, err error) {
	select {
	case <-t.closed:
		return 0, errors.New("ios tun: closed")
	case pkt := <-t.packets:
		n = copy(p, pkt.data)
		return n, nil
	}
}

func (t *iosPacketTun) Write(p []byte) (n int, err error) {
	// The gvisor stack never calls Write; this path exists only to satisfy the
	// stun.Tun interface. It is kept functional for the darwin-style
	// [4-byte AF prefix][packet] input format.
	payload, family := splitDarwinFrame(p)
	if len(payload) == 0 {
		return 0, nil
	}
	writeToSwift(payload, family)
	return len(payload), nil
}

func (t *iosPacketTun) Close() error {
	t.closeOne.Do(func() {
		activeMu.Lock()
		if active == t {
			active = nil
		}
		activeMu.Unlock()
		close(t.closed)
		t.mu.Lock()
		if t.endpoint != nil {
			t.endpoint.Close()
		}
		t.mu.Unlock()
	})
	return nil
}

// --- stun.GVisorTun interface ---

func (t *iosPacketTun) WritePacket(pkt *stack.PacketBuffer) (int, error) {
	var family uint8
	switch pkt.NetworkProtocolNumber {
	case header.IPv4ProtocolNumber:
		family = afInet
	case header.IPv6ProtocolNumber:
		family = afInet6
	default:
		return 0, errInvalidPacket
	}
	views := pkt.AsSlices()
	if len(views) == 1 {
		v := views[0]
		writeToSwift(v, family)
		return len(v), nil
	}
	var total int
	for _, v := range views {
		total += len(v)
	}
	buf := make([]byte, 0, total)
	for _, v := range views {
		buf = append(buf, v...)
	}
	writeToSwift(buf, family)
	return total, nil
}

func (t *iosPacketTun) NewEndpoint() (stack.LinkEndpoint, stack.NICOptions, error) {
	ep := channel.New(1024, t.mtu, "")
	t.mu.Lock()
	t.endpoint = ep
	t.notify = ep.AddNotify(&packetNotify{t: t})
	t.mu.Unlock()
	go t.run()
	return ep, stack.NICOptions{
		QDisc: fifo.New(ep, 1, 1000),
	}, nil
}

// --- internals ---

func (t *iosPacketTun) run() {
	for {
		select {
		case <-t.closed:
			return
		case pkt := <-t.packets:
			t.injectInbound(pkt)
		}
	}
}

func (t *iosPacketTun) injectInbound(pkt *iosPacket) {
	var proto tcpip.NetworkProtocolNumber
	switch pkt.family {
	case afInet:
		proto = header.IPv4ProtocolNumber
	case afInet6:
		proto = header.IPv6ProtocolNumber
	default:
		return
	}
	t.mu.RLock()
	ep := t.endpoint
	t.mu.RUnlock()
	if ep == nil {
		return
	}
	view := stack.NewPacketBuffer(stack.PacketBufferOptions{
		Payload: buffer.MakeWithData(pkt.data),
	})
	ep.InjectInbound(proto, view)
}

type packetNotify struct {
	t *iosPacketTun
}

func (n *packetNotify) WriteNotify() {
	n.t.drainOutbound()
}

func (t *iosPacketTun) drainOutbound() {
	t.mu.RLock()
	ep := t.endpoint
	t.mu.RUnlock()
	if ep == nil {
		return
	}
	for {
		pkt := ep.Read()
		if pkt == nil {
			return
		}
		_, _ = t.WritePacket(pkt)
		pkt.DecRef()
	}
}

// splitDarwinFrame strips the 4-byte darwin utun protocol prefix when present
// and returns the payload and protocol family.
func splitDarwinFrame(p []byte) ([]byte, uint8) {
	if len(p) >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 {
		switch p[3] {
		case afInet, afInet6:
			return p[4:], p[3]
		}
	}
	if len(p) >= 1 {
		switch p[0] >> 4 {
		case 4:
			return p, afInet
		case 6:
			return p, afInet6
		}
	}
	return p, 0
}

// writeToSwift hands an outbound IP packet to the C bridge, which forwards it
// to the Swift extension for packetFlow.writePackets.
func writeToSwift(payload []byte, family uint8) {
	if len(payload) == 0 || family == 0 {
		return
	}
	flclashWritePacket(payload, int(family))
}

// Start creates the iOS TUN listener. The fd argument is ignored on iOS: the
// packet flow device is used instead of a real utun interface, and only the
// gvisor stack is supported inside the Network Extension sandbox.
func Start(fd int, stack string, address, dns string) *sing_tun.Listener {
	prefix4, prefix6, dnsHijack, err := parseTunArgs(address, dns)
	if err != nil {
		return nil
	}

	var tunStack constant.TUNStack
	if s, ok := constant.StackTypeMapping[strings.ToLower(stack)]; ok {
		tunStack = s
	}
	if tunStack != constant.TunGvisor {
		log.Warnln("TUN: iOS only supports the gvisor stack, forcing gvisor (requested %s)", stack)
		tunStack = constant.TunGvisor
	}

	options := LC.Tun{
		Enable:              true,
		Device:              "FlClash",
		Stack:               tunStack,
		DNSHijack:           dnsHijack,
		AutoRoute:           false,
		AutoDetectInterface: false,
		Inet4Address:        prefix4,
		Inet6Address:        prefix6,
		MTU:                 9000,
	}

	sing_tun.IOSDeviceFactory = func(stunOptions stun.Options) (stun.Tun, error) {
		dev := newIOSPacketTun(stunOptions.MTU)
		activeMu.Lock()
		active = dev
		activeMu.Unlock()
		return dev, nil
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		log.Errorln("TUN:", err)
		return nil
	}
	return listener
}
