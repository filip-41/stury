package kernel

import "core:simd"
import core ".."

// UTF-8 validation of blocks by table lookups, after Keiser and Lemire, "Validating UTF-8 in less than one
// instruction per byte". Three 16-entry tables, indexed by the high and low nibble of the byte before and the high
// nibble of the byte itself, flag every error a pair of bytes shows: an overlong form, a surrogate, a code point
// above U+10FFFF, a lead byte not followed by a continuation, and a continuation byte with no lead. The second and
// third bytes before a byte say whether it must be a continuation. Validation works one vector register of the tier
// at a time, because on 64 lanes the 16-byte tiers keep four registers live at each step and spill.

// State between blocks. `prev` is the block before, with zeros after an ASCII block, and `err` holds the errors found
// so far in its first register. The fields are `#simd[64]u8` rather than `Block`, because LLVM carries a `Block`
// between loop iterations as four 16-byte vectors and rebuilds the wider register from them each time.
Utf8_State :: struct {
	prev: #simd[64]u8,
	err:  #simd[64]u8,
}

// Adds the errors of `b`, read after the bytes in `s.prev`, to `s.err`, and stores `b` in `s.prev`.
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

// Reads a block whose bytes are all below 0x80, as `is_ascii` reports. Its only possible error is a sequence the
// block before left open, so this adds that error to `s.err` and sets `s.prev` to zeros.
utf8_ascii_block :: #force_inline proc "contextless" ($T: Tier, s: ^Utf8_State) #no_bounds_check {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	err: [64 / N]U
	err[0] = simd.bit_or((transmute([64 / N]U)s.err)[0], open_sequence((transmute([64 / N]U)s.prev)[64 / N - 1]))
	s.err = transmute(W)err
	s.prev = {}
}

// Reports whether the blocks given so far hold no error, ignoring a sequence the last block leaves open. For a reader
// that stops inside the last block. An error anywhere in the blocks counts, including in bytes past the stop.
utf8_clean :: #force_inline proc "contextless" ($T: Tier, s: Utf8_State) -> bool {
	N :: VECTOR_BYTES[T]
	return simd.reduce_max((transmute([64 / N]#simd[N]u8)s.err)[0]) == 0
}

// Reports whether every block given was valid UTF-8 and the last block leaves no sequence open. Called once, at the
// end of the input.
utf8_ok :: proc "contextless" (s: Utf8_State) -> bool {
	return simd.reduce_or(simd.bit_or(s.err, open_sequence(s.prev))) == 0
}

@(private = "file", rodata)
BEFORE_HIGH := V{2, 2, 2, 2, 2, 2, 2, 2, 128, 128, 128, 128, 33, 1, 21, 73}
@(private = "file", rodata)
BEFORE_LOW := V{231, 163, 131, 131, 139, 203, 203, 203, 203, 203, 203, 203, 203, 219, 203, 203}
@(private = "file", rodata)
HIGH := V{1, 1, 1, 1, 1, 1, 1, 1, 230, 174, 186, 186, 1, 1, 1, 1}

// Returns a non-zero lane where `v`, read after `prev`, is not UTF-8. The tables leave 0x80 set on a continuation
// byte after a lead, and the 0x80 of `must` cancels it, so either flag alone marks an error.
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

// Returns a vector whose lane i is the byte `K` before byte i of `v`, taken from the end of `prev` for the first `K`
// lanes. LLVM lowers the 16-lane shuffle to one `ext`, and the select of two rotations to an `ext` and a lane insert
// when `prev` comes from the previous block.
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

// Steps over the UTF-8 character whose lead is at `p`, where `p < end` and `*p >= 0x80`. Returns one past the
// character with `.None`, or `p` with `.Bad_Char` for a malformed sequence. A sequence the text cuts short returns
// `end` with `.Truncated` when every byte present could still continue it, else `p` with `.Bad_Char`.
utf8_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	c := p[0]
	if c < 0xc2 || c > 0xf4 {
		return p, .Bad_Char
	}
	need := 2 if c < 0xe0 else 3 if c < 0xf0 else 4
	for i in 1 ..< need {
		if p[i:] >= end {
			return end, .Truncated
		}
		b := p[i]
		bad := b & 0xc0 != 0x80
		if i == 1 {
			bad ||= c == 0xe0 && b < 0xa0 || c == 0xed && b > 0x9f || c == 0xf0 && b < 0x90 || c == 0xf4 && b > 0x8f
		}
		if bad {
			return p, .Bad_Char
		}
	}
	return p[need:], .None
}

// Returns the end of the maximal subpart of an ill-formed sequence at `p`: the longest prefix that could still start
// a well-formed sequence, at least one byte. The caller has already received `.Bad_Char` from `utf8_char`.
utf8_subpart :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	n := 1
	for n < 3 && p[n:] < end {
		if _, k := utf8_char(p, p[n + 1:]); k != .Truncated {
			break
		}
		n += 1
	}
	return p[n:]
}

// Returns a non-zero lane where one of the last bytes of `prev` starts a sequence longer than the bytes left: a
// 4-byte lead in the last 3 bytes, a 3-byte lead in the last 2, a 2-byte lead in the last byte.
@(private = "file")
open_sequence :: #force_inline proc "contextless" (prev: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	i := simd.indices(U)
	limit := simd.select(simd.lanes_eq(i, U(N - 3)), U(0xef), U(255))
	limit = simd.select(simd.lanes_eq(i, U(N - 2)), U(0xdf), limit)
	limit = simd.select(simd.lanes_eq(i, U(N - 1)), U(0xbf), limit)
	return simd.saturating_sub(prev, limit)
}
