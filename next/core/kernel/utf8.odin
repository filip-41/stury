package kernel

import "core:simd"

// UTF-8 validation of blocks by table lookups (Keiser and Lemire, "Validating UTF-8 in less than one instruction per
// byte"). Three 16-entry tables, indexed by the high and low nibble of the byte before and the high nibble of the
// byte itself, flag every error a pair of bytes shows: an overlong form, a surrogate, a code point above U+10FFFF, a
// lead byte not followed by a continuation, a continuation byte with no lead. The second and third bytes before a
// byte say whether it must be a continuation. The work is per 16 bytes, so a block is four windows on every target.

@(private = "file")
V :: #simd[16]u8

// The last 16 bytes of the block before, zeros after an ASCII block, and the errors found so far.
Utf8_State :: struct {
	prev: #simd[16]u8,
	err:  #simd[16]u8,
}

// The errors of a block, after the bytes in `s.prev`.
utf8_block :: #force_inline proc "contextless" (b: Block, s: ^Utf8_State) {
	s.err |= errors(s.prev, b[0]) | errors(b[0], b[1]) | errors(b[1], b[2]) | errors(b[2], b[3])
	s.prev = b[3]
}

// A block whose bytes are all below 0x80, as `is_ascii` reports: its only possible error is a sequence that the
// block before left open. After it, `utf8_block` on a later block and `utf8_ascii_block` on the ones between cost
// nothing to skip.
utf8_ascii_block :: #force_inline proc "contextless" (s: ^Utf8_State) {
	s.err |= open_sequence(s.prev)
	s.prev = 0
}

// Whether the blocks given were valid UTF-8, the last one leaving no sequence open: called once, at the end of input.
utf8_ok :: proc "contextless" (s: Utf8_State) -> bool {
	return simd.reduce_or(s.err | open_sequence(s.prev)) == 0
}

@(private = "file", rodata)
BEFORE_HIGH := V{2, 2, 2, 2, 2, 2, 2, 2, 128, 128, 128, 128, 33, 1, 21, 73}
@(private = "file", rodata)
BEFORE_LOW := V{231, 163, 131, 131, 139, 203, 203, 203, 203, 203, 203, 203, 203, 219, 203, 203}
@(private = "file", rodata)
HIGH := V{1, 1, 1, 1, 1, 1, 1, 1, 230, 174, 186, 186, 1, 1, 1, 1}

// Non-zero lanes where `v`, after `prev`, is not UTF-8. The tables leave 0x80 set on a continuation byte after a lead,
// and the 0x80 of "must be a continuation" cancels it, so either alone is an error.
@(private = "file")
errors :: #force_inline proc "contextless" (prev, v: V) -> V {
	p1 := simd.shuffle(prev, v, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30)
	p2 := simd.shuffle(prev, v, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29)
	p3 := simd.shuffle(prev, v, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28)
	pairs := simd.bit_and(
		simd.bit_and(simd.runtime_swizzle(BEFORE_HIGH, simd.shr(p1, V(4))), simd.runtime_swizzle(BEFORE_LOW, simd.bit_and(p1, V(0x0f)))),
		simd.runtime_swizzle(HIGH, simd.shr(v, V(4))),
	)
	// A byte two after a lead of three or four bytes, or three after a lead of four, must be a continuation.
	must := simd.bit_or(simd.saturating_sub(p2, V(0xe0 - 0x80)), simd.saturating_sub(p3, V(0xf0 - 0x80)))
	return simd.bit_xor(simd.bit_and(must, V(0x80)), pairs)
}

// Non-zero lanes where the last bytes of `prev` start a sequence that needs more bytes than are left: a lead of four
// in the last three, of three in the last two, of two in the last one.
@(private = "file")
open_sequence :: #force_inline proc "contextless" (prev: V) -> V {
	return simd.saturating_sub(prev, V{255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0xef, 0xdf, 0xbf})
}
