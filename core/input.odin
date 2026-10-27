package core

// Every format's scan uses little-endian word loads, and its frames and contexts assume 8-byte words. Other
// targets are refused here, in the package every format imports, before a less clear layout assert fails.
when ODIN_ENDIAN != .Little || size_of(uintptr) != 8 {
	#panic("stury: a 64-bit little-endian target is required")
}

// The SIMD loops on amd64 require SSSE3, SSE4.1 and POPCNT (x86-64-v2, Odin's default). The bare x86-64
// baseline scalarizes every byte shuffle and builds a CLI over its size cap.
when ODIN_ARCH == .amd64 && ODIN_MICROARCH_STRING == "x86-64" {
	#panic("stury: amd64 needs -microarch:x86-64-v2 or newer (SSSE3, SSE4.1, POPCNT)")
}

// Returns the length of a leading UTF-8 BOM in `src`: 3, or 0 for none. A BOM is accepted at offset 0 only and
// is not content. Offsets stay absolute in `src`.
bom_len :: #force_inline proc(src: []byte) -> int {
	return 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
}

// JSON's whitespace, which the path syntax, jq's lexer and the CLI share.
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// The index of the first byte of `src` at or past `pos` that is not `is_space`, or `len(src)`.
skip_space :: #force_inline proc(src: $S, pos: int) -> int {
	i := pos
	for i < len(src) && is_space(src[i]) {
		i += 1
	}
	return i
}

// The end of `src[lo:hi]` with its trailing `is_space` bytes cut, never below `lo`.
skip_space_back :: #force_inline proc(src: []byte, lo, hi: int) -> int {
	i := hi
	for i > lo && is_space(src[i - 1]) {
		i -= 1
	}
	return i
}
