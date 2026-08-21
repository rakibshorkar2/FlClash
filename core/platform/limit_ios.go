//go:build ios

package platform

// ShouldBlockConnection reports whether the process is running low on file
// descriptors. iOS does not expose RLIMIT_NOFILE the way Android does, and
// the Network Extension sandbox exempts the extension's own sockets from the
// tunnel, so connections are never blocked here.
func ShouldBlockConnection() bool {
	return false
}
