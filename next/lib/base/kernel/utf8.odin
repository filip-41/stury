package kernel

import "core:simd"

// UTF-8 validation between blocks. `prev` is the last block read, zeros after an ASCII block, and every error is in
// the first register of `err`. The fields are a block wide, not a register: with a register-wide `prev` LLVM no
// longer folds `before`'s select at 32 lanes into the rotation of the previous block.
Utf8_State :: struct {
	prev: W,
	err:  W,
}

// Adds the errors of `b`'s registers up to the one holding byte `last`, read after `s.prev`.
@(private)
utf8_head :: #force_inline proc "contextless" ($T: Tier, b: Block, s: ^Utf8_State, last: u64) {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	prev := (transmute([64 / N]U)s.prev)[64 / N - 1]
	err := (transmute([64 / N]U)s.err)[0]
	#unroll for i in 0 ..< 64 / N {
		if u64(i * N) <= last {
			err = simd.bit_or(err, errors(T, prev, w[i]))
			prev = w[i]
		}
	}
	e: [64 / N]U
	e[0] = err
	s.err = transmute(W)e
}

// An all-ASCII block can only fail a sequence the block before left open.
@(private)
utf8_ascii_block :: #force_inline proc "contextless" ($T: Tier, s: ^Utf8_State) {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	e: [64 / N]U
	e[0] = simd.bit_or((transmute([64 / N]U)s.err)[0], open_sequence((transmute([64 / N]U)s.prev)[64 / N - 1]))
	s.err = transmute(W)e
	s.prev = {}
}

// Adds the errors of `b`, which `is_ascii` reports as `ascii`. `high` says the block before had a byte past 0x7F, and
// is updated for `b`. Returns whether `s.err` may have grown: an ASCII block after an ASCII block adds nothing.
utf8_next :: #force_inline proc "contextless" ($T: Tier, b: Block, ascii: bool, s: ^Utf8_State, high: ^bool) -> bool {
	if !ascii {
		utf8_head(T, b, s, 63)
		s.prev = transmute(W)b
	} else if high^ {
		utf8_ascii_block(T, s)
	} else {
		return false
	}
	high^ = !ascii
	return true
}

// Adds the errors of `b` up to the register holding byte `last`, for a reader that stops there, and returns
// `utf8_clean`.
utf8_stop :: #force_inline proc "contextless" ($T: Tier, b: Block, ascii: bool, s: ^Utf8_State, high: bool, last: u64) -> bool {
	if !ascii {
		utf8_head(T, b, s, last)
	} else if high {
		utf8_ascii_block(T, s)
	}
	return utf8_clean(T, s^)
}

// Whether the blocks so far hold no error, ignoring a sequence the last one leaves open. Bytes past a stop count.
utf8_clean :: #force_inline proc "contextless" ($T: Tier, s: Utf8_State) -> bool {
	N :: VECTOR_BYTES[T]
	return all_zero((transmute([64 / N]#simd[N]u8)s.err)[0])
}

// Whether every block was UTF-8 and the last leaves no sequence open. Called once, at the end of the input.
utf8_ok :: proc "contextless" (s: Utf8_State) -> bool {
	return simd.reduce_or(simd.bit_or(s.err, open_sequence(s.prev))) == 0
}

utf8_valid :: #force_inline proc "contextless" (text: []u8) -> bool {
	return scan(text, 0, nil, .Utf8) != 0
}

@(private)
utf8_blocks :: #force_inline proc "contextless" ($T: Tier, text: []u8) -> bool {
	u: Utf8_State
	high: bool
	j := 0
	for ; j + 64 <= len(text); j += 64 {
		b := load(raw_data(text)[j:])
		utf8_next(T, b, is_ascii(b), &u, &high)
	}
	if j < len(text) {
		b := load_padded(T, text, j)
		utf8_next(T, b, is_ascii(b), &u, &high)
	}
	return utf8_ok(u)
}

// A non-zero lane where the 16 bytes `v`, read after `prev` (zeros before the first), are not UTF-8. Uses the floor
// tier's lookups, so any tier's procedure may call it. A sequence the last vector leaves open shows once an ASCII
// vector follows.
utf8_window :: #force_inline proc "contextless" (prev, v: V) -> V {
	return errors(Tier(0), prev, v)
}

@(private = "file", rodata)
BEFORE_HIGH := V{2, 2, 2, 2, 2, 2, 2, 2, 128, 128, 128, 128, 33, 1, 21, 73}
@(private = "file", rodata)
BEFORE_LOW := V{231, 163, 131, 131, 139, 203, 203, 203, 203, 203, 203, 203, 203, 219, 203, 203}
@(private = "file", rodata)
OWN_HIGH := V{1, 1, 1, 1, 1, 1, 1, 1, 230, 174, 186, 186, 1, 1, 1, 1}

// A non-zero lane where `v`, read after `prev`, is not UTF-8, after Keiser and Lemire, "Validating UTF-8 in less than
// one instruction per byte". Three nibble tables flag the errors a pair of bytes shows; the bytes two and three back
// say whether a byte must be a continuation. The tables leave 0x80 on a continuation after a lead and `must`'s 0x80
// cancels it, so either flag alone is an error.
@(private = "file")
errors :: #force_inline proc "contextless" ($T: Tier, prev, v: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	p1, p2, p3 := before(prev, v, 1), before(prev, v, 2), before(prev, v, 3)
	pairs := simd.bit_and(
		simd.bit_and(lookup(T, BEFORE_HIGH, simd.shr(p1, U(4))), lookup(T, BEFORE_LOW, simd.bit_and(p1, U(0x0f)))),
		lookup(T, OWN_HIGH, simd.shr(v, U(4))),
	)
	must := simd.bit_or(simd.saturating_sub(p2, U(0xe0 - 0x80)), simd.saturating_sub(p3, U(0xf0 - 0x80)))
	return simd.bit_xor(simd.bit_and(must, U(0x80)), pairs)
}

// Lane i is the byte `K` before byte i of `v`, taken from the end of `prev` for the first `K` lanes. One `ext` at 16
// lanes; at 32, a select of two rotations.
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

// A non-zero lane where one of `prev`'s last bytes starts a sequence longer than the bytes left: a 4-byte lead in the
// last 3, a 3-byte lead in the last 2, a 2-byte lead in the last 1.
@(private = "file")
open_sequence :: #force_inline proc "contextless" (prev: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	i := simd.indices(U)
	limit := simd.select(simd.lanes_eq(i, U(N - 3)), U(0xef), U(255))
	limit = simd.select(simd.lanes_eq(i, U(N - 2)), U(0xdf), limit)
	limit = simd.select(simd.lanes_eq(i, U(N - 1)), U(0xbf), limit)
	return simd.saturating_sub(prev, limit)
}
