//go:build ios && cgo

package main

/*
#include "bride.h"
*/
import "C"

import (
	t "core/tun"
	"unsafe"
)

func protect(callback unsafe.Pointer, fd int) {
	C.protect(callback, C.int(fd))
}

func resolveProcess(callback unsafe.Pointer, protocol int, source, target string, uid int) string {
	s := C.CString(source)
	defer C.free(unsafe.Pointer(s))
	tgt := C.CString(target)
	defer C.free(unsafe.Pointer(tgt))
	res := C.resolve_process(callback, C.int(protocol), s, tgt, C.int(uid))
	return takeCString(res)
}

func invokeResult(callback unsafe.Pointer, data string) {
	s := C.CString(data)
	defer C.free(unsafe.Pointer(s))
	C.result(callback, s)
}

func releaseObject(callback unsafe.Pointer) {
	C.release_object(callback)
}

func takeCString(s *C.char) string {
	defer C.free_string(s)
	return C.GoString(s)
}

//export flclash_iosPacketFromSwift
func flclash_iosPacketFromSwift(data unsafe.Pointer, length C.int, family C.int) {
	t.IOSInjectPacket(C.GoBytes(data, length), uint8(family))
}
