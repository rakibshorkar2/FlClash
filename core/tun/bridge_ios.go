//go:build ios && cgo

package tun

/*
#include "../ios/flclash_ios.h"
*/
import "C"

import "unsafe"

// flclashWritePacket forwards an outbound IP packet to the C bridge, which
// hands it to the Swift extension for packetFlow.writePackets.
func flclashWritePacket(payload []byte, family int) {
	if len(payload) == 0 {
		return
	}
	C.flclash_ios_write_packet(
		(*C.uint8_t)(unsafe.Pointer(&payload[0])),
		C.size_t(len(payload)),
		C.int(family),
	)
}
