package kernel

import "core:simd"

// UTF-8 validation between blocks. `prev` is the last block read, zeros after an ASCII block, and every error is in
// the first register of `err`. The fields are a block wide, not a register: with a register-wide `prev` LLVM does
// not fold `before`'s select at 32 lanes into the rotation of the previous block. A state is zero or updated by
// `utf8_next`: `lead` must match `prev`, and a state made from `prev` alone misreads the next block. A state after
// `utf8_stop` is not read again.
Utf8_State :: struct {
	prev: W,
	err:  W,
	lead: W, // `leads` of `prev`'s last register, the only one read
}
#assert(size_of(Utf8_State) == 192)

// Stores `r` as register `i` of the state field `f`, leaving the field's other registers as they were. Only `prev`'s and
// `lead`'s last register and `err`'s first are read, and `err`'s others stay zero, so a state is not stored whole.
@(private = "file")
put_register :: #force_inline proc "contextless" (f: ^W, $I: int, r: #simd[$N]u8) {
	a := transmute([64 / N]#simd[N]u8)f^
	a[I] = r
	f^ = transmute(W)a
}

// Adds the errors of `b`'s bytes up to byte `last`, read after `s.prev`. The register holding `last` counts only its
// lanes up to it.
@(private = "file")
utf8_head :: #force_inline proc "contextless" ($T: Tier, b: Block, s: ^Utf8_State, last: u64) {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	w := transmute([64 / N]U)b
	prev := (transmute([64 / N]U)s.prev)[64 / N - 1]
	lead := (transmute([64 / N]U)s.lead)[64 / N - 1]
	err := (transmute([64 / N]U)s.err)[0]
	l: [64 / N]U
	#unroll for i in 0 ..< 64 / N {
		if u64(i * N) <= last {
			p1 := before(prev, w[i], 1)
			l[i] = leads(w[i], p1)
			found := errors(T, p1, w[i], before(lead, l[i], 2))
			if live := last - u64(i * N) + 1; live < u64(N) {
				found = simd.bit_and(found, simd.lanes_lt(simd.indices(U), U(u8(live))))
			}
			err = simd.bit_or(err, found)
			prev, lead = w[i], l[i]
		}
	}
	put_register(&s.err, 0, err)
	put_register(&s.lead, 64 / N - 1, l[64 / N - 1])
}

// An all-ASCII block can only fail a sequence the block before left open.
@(private = "file")
utf8_ascii_block :: #force_inline proc "contextless" ($T: Tier, s: ^Utf8_State) {
	N :: VECTOR_BYTES[T]
	U :: #simd[N]u8
	put_register(&s.err, 0, simd.bit_or((transmute([64 / N]U)s.err)[0], open_sequence((transmute([64 / N]U)s.prev)[64 / N - 1])))
	put_register(&s.prev, 64 / N - 1, U(0))
	put_register(&s.lead, 64 / N - 1, U(0))
}

// Adds the errors of `b`, which `is_ascii` reports as `ascii`. `high` says the block before had a byte past 0x7F, and
// is updated for `b`. Returns whether `s.err` may have grown: an ASCII block after an ASCII block adds nothing.
// On amd64, callers must carry `@(enable_target_feature = FEATURES[T])` so `lookup` inlines as `pshufb`/`vpshufb`.
utf8_next :: #force_inline proc "contextless" ($T: Tier, b: Block, ascii: bool, s: ^Utf8_State, high: ^bool) -> bool {
	if !ascii {
		utf8_head(T, b, s, 63)
		N :: VECTOR_BYTES[T]
		put_register(&s.prev, 64 / N - 1, (transmute([64 / N]#simd[N]u8)b)[64 / N - 1])
	} else if high^ {
		utf8_ascii_block(T, s)
	} else {
		return false
	}
	high^ = !ascii
	return true
}

// Adds the errors of `b`'s bytes up to `last` (for `0 <= last < 64`), masking out bytes past `last` in the same
// register, and returns `utf8_clean`. Because it does not check for a sequence left open at `last`, the caller must
// stop at an ASCII delimiter (`b[last] < 0x80`) to catch a sequence truncated right before `last`. `s` is not read
// again after this call. On amd64, callers must carry `@(enable_target_feature = FEATURES[T])` so `lookup` inlines as
// `pshufb`/`vpshufb`.
@(require_results)
utf8_stop :: #force_inline proc "contextless" ($T: Tier, b: Block, ascii: bool, s: ^Utf8_State, high: bool, last: u64) -> bool {
	if !ascii {
		utf8_head(T, b, s, last)
	} else if high {
		utf8_ascii_block(T, s)
	}
	return utf8_clean(T, s^)
}

// Whether the blocks so far hold no error, ignoring a sequence the last one leaves open. A lead byte that ends the
// last block is judged only beside the byte after it, so even one no byte completes is not an error yet.
// On amd64, callers must carry `@(enable_target_feature = FEATURES[T])` so `all_zero` uses the tier's test.
@(require_results)
utf8_clean :: #force_inline proc "contextless" ($T: Tier, s: Utf8_State) -> bool {
	N :: VECTOR_BYTES[T]
	return all_zero((transmute([64 / N]#simd[N]u8)s.err)[0])
}

// Whether every block was UTF-8 and the last leaves no sequence open. Called once, at the end of the input.
@(require_results)
utf8_ok :: proc "contextless" (s: Utf8_State) -> bool {
	when ODIN_ARCH == .amd64 {
		#assert(len(Tier) == 2 && VECTOR_BYTES[.V2] <= 32 && VECTOR_BYTES[.V3] <= 32)
	} else {
		#assert(len(Tier) == 1 && VECTOR_BYTES[.Base] <= 16)
	}
	err := transmute([4]V)s.err
	prev := transmute([4]V)s.prev
	bad := simd.bit_or(err[0], open_sequence(prev[3]))
	when ODIN_ARCH == .amd64 {
		bad = simd.bit_or(bad, err[1])
	}
	return all_zero(bad)
}

// Whether `text` is valid UTF-8.
@(require_results)
utf8_valid :: #force_inline proc "contextless" (text: []u8) -> bool {
	return scan(text, 0, .Utf8) != 0
}

// Byte-at-a-time RFC 3629 UTF-8 validator for scalar WebAssembly, where emulating 16-lane shuffles explodes code size.
// `#no_bounds_check` relies on `n - i >= 8`, `i < n`, and `n - i < 2/3/4` checks dominating every load.
@(private = "file")
utf8_valid_scalar :: proc "contextless" (text: []u8) -> bool #no_bounds_check {
	p := raw_data(text)
	n := len(text)
	i := 0
	for i < n {
		for n - i >= 8 && load8(p[i:]) & 0x8080_8080_8080_8080 == 0 {
			i += 8
		}
		if i >= n {
			return true
		}
		c := p[i]
		if c < 0x80 {
			i += 1
			continue
		}
		if c < 0xc2 || c > 0xf4 {
			return false
		}
		if c < 0xe0 {
			if n - i < 2 || p[i + 1] & 0xc0 != 0x80 {
				return false
			}
			i += 2
		} else if c < 0xf0 {
			if n - i < 3 {
				return false
			}
			b1, b2 := p[i + 1], p[i + 2]
			if b1 & 0xc0 != 0x80 || b2 & 0xc0 != 0x80 {
				return false
			}
			if c == 0xe0 && b1 < 0xa0 || c == 0xed && b1 > 0x9f {
				return false
			}
			i += 3
		} else {
			if n - i < 4 {
				return false
			}
			b1, b2, b3 := p[i + 1], p[i + 2], p[i + 3]
			if b1 & 0xc0 != 0x80 || b2 & 0xc0 != 0x80 || b3 & 0xc0 != 0x80 {
				return false
			}
			if c == 0xf0 && b1 < 0x90 || c == 0xf4 && b1 > 0x8f {
				return false
			}
			i += 4
		}
	}
	return true
}

// Whole-text UTF-8 validation for `scan`. `#no_bounds_check` relies on `whole <= len(text)` and `j >= 64` inside the
// `N == 16` loop keeping `p[j:]`, `p[j + i * N - 3:]`, `p[j - 64:]`, and `p[j - N - 1:]` in bounds.
@(private)
utf8_blocks :: #force_inline proc "contextless" ($T: Tier, text: []u8) -> bool #no_bounds_check {
	when SCALAR_WASM {
		return utf8_valid_scalar(text)
	} else {
		N :: VECTOR_BYTES[T]
		U :: #simd[N]u8
		u: Utf8_State
		high: bool
		p := raw_data(text)
		whole := len(text) &~ 63
		j := 0
		// The overlapping loads read faster than the shifts on arm64 and at V2. At V3 LLVM rebuilds them through general
		// registers, so V3 keeps the shifts.
		when N == 16 {
			if whole > 0 {
				b := load(p)
				utf8_next(T, b, is_ascii(b), &u, &high)
				// Past the first block the bytes one to three back of each register are loads at those offsets, not shifts.
				err := (transmute([64 / N]U)u.err)[0]
				for j = 64; j < whole; j += 64 {
					b = load(p[j:])
					if is_ascii(b) {
						if high {
							err = simd.bit_or(err, open_sequence(load16(p[j - N:])))
						}
						high = false
						continue
					}
					#unroll for i in 0 ..< 64 / N {
						q := p[j + i * N - 3:]
						must := leads(load16(q[1:]), load16(q))
						err = simd.bit_or(err, errors(T, load16(q[2:]), load16(q[3:]), must))
					}
					high = true
				}
				// The state the last block reads after this loop.
				e, l: [64 / N]U
				e[0] = err
				u.err = transmute(W)e
				u.prev, u.lead = {}, {}
				if high {
					u.prev = transmute(W)load(p[j - 64:])
					l[64 / N - 1] = leads(load16(p[j - N:]), load16(p[j - N - 1:]))
					u.lead = transmute(W)l
				}
			}
		} else {
			for ; j < whole; j += 64 {
				b := load(p[j:])
				utf8_next(T, b, is_ascii(b), &u, &high)
			}
		}
		if j < len(text) {
			b := load_padded(text, j)
			utf8_next(T, b, is_ascii(b), &u, &high)
		}
		return utf8_ok(u)
	}
}

// A non-zero lane where the 16 bytes `v`, read after `prev` (zeros before the first), are not UTF-8. Uses the floor
// tier's lookups, so any tier's procedure may call it. A sequence the last vector leaves open shows once an ASCII
// vector follows. On amd64, callers must carry `@(enable_target_feature = FEATURES[.V2])` (or `.V3`) so `lookup`
// inlines as `pshufb`/`vpshufb`.
@(require_results)
utf8_window :: #force_inline proc "contextless" (prev, v: V) -> V {
	return errors(Tier(0), before(prev, v, 1), v, leads(before(prev, v, 2), before(prev, v, 3)))
}

@(private = "file", rodata)
BEFORE_HIGH := V{2, 2, 2, 2, 2, 2, 2, 2, 128, 128, 128, 128, 33, 1, 21, 73}
@(private = "file", rodata)
BEFORE_LOW := V{231, 163, 131, 131, 139, 203, 203, 203, 203, 203, 203, 203, 203, 219, 203, 203}
@(private = "file", rodata)
OWN_HIGH := V{1, 1, 1, 1, 1, 1, 1, 1, 230, 174, 186, 186, 1, 1, 1, 1}

// A non-zero lane where `v`, with the byte before each of its bytes in `p1`, is not UTF-8, after Keiser and Lemire,
// "Validating UTF-8 in less than one instruction per byte". Three nibble tables flag the errors a pair of bytes shows.
// Bit 7 of `must`, the `leads` of the bytes two back, says a byte must be a continuation. The tables leave 0x80 on a
// continuation after a lead and `must`'s 0x80 cancels it, so either flag alone is an error.
@(private = "file")
errors :: #force_inline proc "contextless" ($T: Tier, p1, v, must: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	pairs := simd.bit_and(
		simd.bit_and(lookup(T, BEFORE_HIGH, simd.shr(p1, U(4))), lookup(T, BEFORE_LOW, simd.bit_and(p1, U(0x0f)))),
		lookup(T, OWN_HIGH, simd.shr(v, U(4))),
	)
	return simd.bit_xor(simd.bit_and(must, U(0x80)), pairs)
}

// Bit 7 of lane i set where byte i of `v` leads a sequence of 3 or 4 bytes, or the byte before it, in `p1`, leads one
// of 4. Shifted on by 2 lanes it marks the bytes that must be continuations: one shift for the bytes two and three
// back.
@(private = "file")
leads :: #force_inline proc "contextless" (v, p1: #simd[$N]u8) -> #simd[N]u8 {
	U :: #simd[N]u8
	return simd.bit_or(simd.saturating_sub(v, U(0xe0 - 0x80)), simd.saturating_sub(p1, U(0xf0 - 0x80)))
}

// Lane i is the byte `K` before byte i of `v`, taken from the end of `prev` for the first `K` lanes. One `ext` at 16
// lanes, a select of two rotations at 32.
@(private = "file")
before :: #force_inline proc "contextless" (prev, v: #simd[$N]u8, $K: int) -> #simd[N]u8 where 0 < K, K < N {
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
