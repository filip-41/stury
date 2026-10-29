package kernel

import "core:simd"

// UTF-8 validation of blocks by table lookups (Keiser and Lemire, "Validating UTF-8 in less than one instruction per
// byte"). Three 16-entry tables, indexed by the high and low nibble of the byte before and the high nibble of the
// byte itself, flag every error a pair of bytes shows: an overlong form, a surrogate, a code point above U+10FFFF, a
// lead byte not followed by a continuation, a continuation byte with no lead. The second and third bytes before a
// byte say whether it must be a continuation. The work is one vector register of the tier at a time: written on all
// 64 lanes, the 16-byte tiers keep every step's four registers live at once and spill.

// The block before, zeros after an ASCII block, and the errors found so far, which only the first register holds.
// Vectors, not blocks: LLVM carries a block from one iteration to the next as four 16-byte vectors, and rebuilds the
// wider register from them each time.
Utf8_State :: struct {
	prev: #simd[64]u8,
	err:  #simd[64]u8,
}

// The errors of a block, after the bytes in `s.prev`.
utf8_block :: #force_inline proc "contextless" ($T: Tier, b: Block, s: ^Utf8_State) #no_bounds_check {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	prev := (transmute([64 / N]U)s.prev)[64 / N - 1]
	err: [64 / N]U
	err[0] = (transmute([64 / N]U)s.err)[0]
	#unroll for i in 0 ..< 64 / N {
		err[0] = simd.bit_or(err[0], errors(T, prev, w[i]))
		prev = w[i]
	}
	s.err = transmute(W)err
	s.prev = transmute(W)b
}

// A block whose bytes are all below 0x80, as `is_ascii` reports: its only possible error is a sequence that the
// block before left open. After it, `utf8_block` on a later block and `utf8_ascii_block` on the ones between cost
// nothing to skip.
utf8_ascii_block :: #force_inline proc "contextless" ($T: Tier, s: ^Utf8_State) #no_bounds_check {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	err: [64 / N]U
	err[0] = simd.bit_or((transmute([64 / N]U)s.err)[0], open_sequence((transmute([64 / N]U)s.prev)[64 / N - 1]))
	s.err = transmute(W)err
	s.prev = {}
}

// Whether the blocks given so far hold no error, a sequence the last one leaves open allowed: for a reader that stops
// inside the last block. Errors anywhere in the blocks count, the bytes past its stop included.
utf8_clean :: #force_inline proc "contextless" ($T: Tier, s: Utf8_State) -> bool {
	N :: VECTOR_BYTES[T]
	return simd.reduce_max((transmute([64 / N]#simd[N]u8)s.err)[0]) == 0
}

// Whether the blocks given were valid UTF-8, the last one leaving no sequence open: called once, at the end of input.
utf8_ok :: proc "contextless" (s: Utf8_State) -> bool {
	return simd.reduce_or(simd.bit_or(s.err, open_sequence(s.prev))) == 0
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
errors :: #force_inline proc "contextless" ($T: Tier, prev, v: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	p1, p2, p3 := before(prev, v, 1), before(prev, v, 2), before(prev, v, 3)
	pairs := simd.bit_and(
		simd.bit_and(lookup(T, BEFORE_HIGH, simd.shr(p1, U(4))), lookup(T, BEFORE_LOW, simd.bit_and(p1, U(0x0f)))),
		lookup(T, HIGH, simd.shr(v, U(4))),
	)
	// A byte two after a lead of three or four bytes, or three after a lead of four, must be a continuation.
	must := simd.bit_or(simd.saturating_sub(p2, U(0xe0 - 0x80)), simd.saturating_sub(p3, U(0xf0 - 0x80)))
	return simd.bit_xor(simd.bit_and(must, U(0x80)), pairs)
}

// Lane i is the byte `K` before byte i of `v`, taken from the end of `prev` for the first `K` lanes. On 16-lane
// registers LLVM lowers the select of two rotations to an `ext` and a lane insert where `prev` comes from the block
// before, and the shuffle to one `ext`.
@(private = "file")
before :: #force_inline proc "contextless" (prev, v: #simd[$N]u8, $K: int) -> #simd[N]u8 where 0 < K && K < N {
	when N == 16 {
		return simd.shuffle(
			prev, v,
			16 - K, 17 - K, 18 - K, 19 - K, 20 - K, 21 - K, 22 - K, 23 - K, 24 - K, 25 - K, 26 - K, 27 - K, 28 - K, 29 - K, 30 - K, 31 - K,
		)
	} else {
		U :: #simd[N]u8
		return simd.select(simd.lanes_lt(simd.indices(U), U(K)), simd.lanes_rotate_right(prev, K), simd.lanes_rotate_right(v, K))
	}
}

// Non-zero lanes where the last bytes of `prev` start a sequence that needs more bytes than are left: a lead of four
// in the last three, of three in the last two, of two in the last one.
@(private = "file")
open_sequence :: #force_inline proc "contextless" (prev: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	i := simd.indices(U)
	limit := simd.select(simd.lanes_eq(i, U(N - 3)), U(0xef), U(255))
	limit = simd.select(simd.lanes_eq(i, U(N - 2)), U(0xdf), limit)
	limit = simd.select(simd.lanes_eq(i, U(N - 1)), U(0xbf), limit)
	return simd.saturating_sub(prev, limit)
}
