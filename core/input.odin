package core

// Word loads in every format's scan are little-endian, and the frames and contexts are laid out for 8-byte
// words. Refused here, the package every format is built on, before a layout assert fails less clearly.
when ODIN_ENDIAN != .Little || size_of(uintptr) != 8 {
	#panic("stury: a 64-bit little-endian target is required")
}

// The SIMD loops are written for SSSE3, SSE4.1 and POPCNT on amd64 (x86-64-v2, odin's default). The bare
// x86-64 baseline scalarizes every byte shuffle and builds a CLI past its size cap.
when ODIN_ARCH == .amd64 && ODIN_MICROARCH_STRING == "x86-64" {
	#panic("stury: amd64 needs -microarch:x86-64-v2 or newer (SSSE3, SSE4.1, POPCNT)")
}

// One leading UTF-8 BOM is the input's, not content: tolerated at offset 0 and nowhere else, and offsets stay
// absolute in `src`. Its length: 3, or 0 for none.
bom_len :: #force_inline proc(src: []byte) -> int {
	return 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
}
