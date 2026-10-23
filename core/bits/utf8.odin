package bits

import "core:simd"

// The utf8_lookup4 algorithm in portable core:simd: a nibble lookup through `simd.runtime_swizzle` (`tbl` on
// ARM, `pshufb` on x86, from one source), then the multibyte length check. Error bits: 0 too-short, 1 too-long,
// 2 overlong-3, 3 too-large, 4 surrogate, 5 overlong-2, 6 too-large-1000/overlong-4, 7 two-continuations.
@(rodata) UTF8_TBL_A: #simd[16]u8 = {2,2,2,2,2,2,2,2, 128,128,128,128, 33,1,21,73}
@(rodata) UTF8_TBL_B: #simd[16]u8 = {231,163,131,131, 139,203,203,203, 203,203,203,203, 203,219,203,203}
@(rodata) UTF8_TBL_C: #simd[16]u8 = {1,1,1,1,1,1,1,1, 230,174,186,186, 1,1,1,1}

// Returns the part of `utf8_err` that checks each byte against the one before it. It is the whole result when no
// byte of `v` and none of the last three bytes of `prev` is 0xE0 or more, because only a three- or four-byte
// lead affects the bytes two and three positions later.
utf8_pairs_err :: #force_inline proc(prev, v: #simd[16]u8) -> #simd[16]u8 {
	m0f : #simd[16]u8 = 0x0f
	p1 := simd.shuffle(prev, v, 15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30)
	return simd.runtime_swizzle(UTF8_TBL_A, simd.shr(p1, 4)) &
		simd.runtime_swizzle(UTF8_TBL_B, simd.bit_and(p1, m0f)) &
		simd.runtime_swizzle(UTF8_TBL_C, simd.shr(v, 4))
}

// Returns the RFC 3629 faults of the window `v`, whose first byte the caller guarantees is a character
// boundary. A nonzero result only flags the window; the byte loop finds the fault from the same bytes.
utf8_err :: #force_inline proc(prev, v: #simd[16]u8) -> #simd[16]u8 {
	b80 : #simd[16]u8 = 0x80
	s60 : #simd[16]u8 = 0x60
	s70 : #simd[16]u8 = 0x70
	p2 := simd.shuffle(prev, v, 14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29)
	p3 := simd.shuffle(prev, v, 13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28)
	must23 := simd.saturating_sub(p2, s60) | simd.saturating_sub(p3, s70)
	return simd.bit_and(must23, b80) ~ utf8_pairs_err(prev, v)
}

// Returns the UTF-8 faults of a block whose first window continues `prev`. It is out of line so its tables do
// not occupy the ASCII loop's registers.
utf8_block :: #force_no_inline proc(prev: V, v: [4]V) -> V {
	return utf8_err(prev, v[0]) | utf8_err(v[0], v[1]) | utf8_err(v[1], v[2]) | utf8_err(v[2], v[3])
}
