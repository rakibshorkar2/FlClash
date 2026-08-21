package tun

import (
	"net"
	"net/netip"
	"strings"

	"github.com/metacubex/mihomo/log"
)

func parseTunArgs(address, dns string) (prefix4, prefix6 []netip.Prefix, dnsHijack []string, err error) {
	for _, a := range strings.Split(address, ",") {
		a = strings.TrimSpace(a)
		if len(a) == 0 {
			continue
		}
		prefix, parseErr := netip.ParsePrefix(a)
		if parseErr != nil {
			log.Errorln("TUN:", parseErr)
			return nil, nil, nil, parseErr
		}
		if prefix.Addr().Is4() {
			prefix4 = append(prefix4, prefix)
		} else {
			prefix6 = append(prefix6, prefix)
		}
	}
	for _, d := range strings.Split(dns, ",") {
		d = strings.TrimSpace(d)
		if len(d) == 0 {
			continue
		}
		dnsHijack = append(dnsHijack, net.JoinHostPort(d, "53"))
	}
	return
}
