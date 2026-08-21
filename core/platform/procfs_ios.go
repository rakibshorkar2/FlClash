//go:build ios

package platform

import "net"

// QuerySocketUidFromProcFs returns -1 on iOS: there is no procfs, and the
// Network Extension sandbox exempts the extension's own sockets from the
// tunnel, so no uid lookup is needed.
func QuerySocketUidFromProcFs(_, _ net.Addr) int {
	return -1
}
