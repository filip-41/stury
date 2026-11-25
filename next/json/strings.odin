// `simd` is unused on scalar WebAssembly (`SCALAR_WASM`), where string scans take byte loops.
#+vet !unused-imports
package json

import "base:intrinsics"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

@(private)
V :: #simd[16]u8

@(private = "file")
SCALAR_WASM :: (ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32) && !intrinsics.has_target_feature("simd128")

// Whether the token from `p` to `q` is longer than `Token.n` holds.
@(private, require_results)
too_wide :: #force_inline proc "contextless" (p, q: [^]u8) -> bool {
	return u64(intrinsics.ptr_sub(q, p)) > u64(max(u32))
}

when !SCALAR_WASM {
	// The lanes of `v` holding the closing quote `quote`, `\`, a control byte or a byte past 0x7F.
	@(private = "file", require_results)
	string_stops :: #force_inline proc "contextless" (v: V, $quote: u8) -> V {
		return simd.bit_or(simd.bit_or(simd.lanes_eq(v, V(quote)), simd.lanes_eq(v, V('\\'))), kernel.control_or_high16(v, false))
	}

	@(private = "file", require_results)
	string_stops_block :: #force_inline proc "contextless" (b: kernel.Block, $quote: u8) -> kernel.Block {
		return {string_stops(b[0], quote), string_stops(b[1], quote), string_stops(b[2], quote), string_stops(b[3], quote)}
	}

	@(private = "file", require_results)
	control_or_high_block :: #force_inline proc "contextless" (b: kernel.Block) -> kernel.Block {
		return {
			kernel.control_or_high16(b[0], false),
			kernel.control_or_high16(b[1], false),
			kernel.control_or_high16(b[2], false),
			kernel.control_or_high16(b[3], false),
		}
	}
}

// One past the closing quote of the string at `p`, which closes at `quote`, when it closes within 32 bytes as
// printable ASCII (`ok == true`). Otherwise `escaped` tells whether a backslash came first, with `stop` at it, or else
// `stop` is at the control or non-ASCII byte, or nil when no stop appeared within 32 bytes.
@(private, require_results)
string_short :: #force_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> (q, stop: [^]u8, ok, escaped: bool) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= 32 {
		return nil, nil, false, false
	}
	when SCALAR_WASM {
		for k in 1 ..= 32 {
			c := p[k]
			when quote == '"' {
				if STOP[c] != 0 {
					if c == '"' {
						return p[k + 1:], nil, true, false
					}
					return nil, p[k:], false, c == '\\'
				}
			} else {
				if c == quote || c == '\\' || c < 0x20 || c >= 0x80 {
					if c == quote {
						return p[k + 1:], nil, true, false
					}
					return nil, p[k:], false, c == '\\'
				}
			}
		}
		return nil, nil, false, false
	} else {
		k := kernel.first_lane16(string_stops(kernel.load16(p[1:]), quote))
		if k == 16 {
			k = 16 + kernel.first_lane16(string_stops(kernel.load16(p[17:]), quote))
			if k == 32 {
				return nil, nil, false, false
			}
		}
		if p[1 + k] != quote {
			return nil, p[1 + k:], false, p[1 + k] == '\\'
		}
		return p[2 + k:], nil, true, false
	}
}

// One past the closing quote of the string at `p` when it closes within 32 bytes with no backslash or control byte
// and its bytes are UTF-8 (`ok == true`). The text must hold more than 32 bytes from `p`. The bytes from the quote on
// are zeroed before the UTF-8 check, so a sequence the quote cuts fails on the zeros after it: for `k < 16`, lane 15
// of `w0` is zero so one `utf8_window` catches any sequence truncated at `k - 1` (including `k = 13..15`); for
// `16 <= k < 32`, `w1` holds zeros from `k - 16` on.
@(private, require_results)
string_utf8 :: #force_inline proc "contextless" (p: [^]u8) -> (q: [^]u8, ok: bool) #no_bounds_check {
	when SCALAR_WASM {
		return nil, false
	} else {
		stops :: #force_inline proc "contextless" (v: V) -> V {
			return simd.bit_or(simd.bit_or(simd.lanes_eq(v, V('"')), simd.lanes_eq(v, V('\\'))), simd.lanes_lt(v, V(0x20)))
		}
		v0 := kernel.load16(p[1:])
		k := kernel.first_lane16(stops(v0))
		i := simd.indices(V)
		if k < 16 {
			if p[1 + k] != '"' {
				return nil, false
			}
			w0 := simd.bit_and(v0, simd.lanes_lt(i, V(u8(k))))
			if !kernel.all_zero(kernel.utf8_window(V{}, w0)) {
				return nil, false
			}
			return p[2 + k:], true
		}
		v1 := kernel.load16(p[17:])
		k = 16 + kernel.first_lane16(stops(v1))
		if k == 32 || p[1 + k] != '"' {
			return nil, false
		}
		w1 := simd.bit_and(v1, simd.lanes_lt(i, V(u8(k - 16))))
		err := simd.bit_or(kernel.utf8_window(V{}, v0), kernel.utf8_window(v0, w1))
		if !kernel.all_zero(err) {
			return nil, false
		}
		return p[2 + k:], true
	}
}

// The longest key `string_probe` reads.
@(private)
PROBE_MAX :: 32
#assert(PROBE_MAX >= 32)

// One past the closing quote of the key at `p` when it closes within `PROBE_MAX` bytes as printable ASCII
// (`ok == true`). Otherwise `escaped` and `stop` match `string_short`. Reads byte by byte, as keys are short and a
// vector's mask waits on its reduction.
@(private, require_results)
string_probe :: #force_inline proc "contextless" (p, end: [^]u8) -> (q, stop: [^]u8, ok, escaped: bool) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= PROBE_MAX {
		return nil, nil, false, false
	}
	probe_offset :: #force_inline proc "contextless" (p: [^]u8) -> int #no_bounds_check {
		#unroll for k in 1 ..= PROBE_MAX {
			if intrinsics.expect(STOP[p[k]] != 0, false) {
				return k
			}
		}
		return 0
	}
	k := probe_offset(p)
	if k == 0 {
		return nil, nil, false, false
	}
	if p[k] == '"' {
		return p[k + 1:], nil, true, false
	}
	return nil, p[k:], false, p[k] == '\\'
}

// One past the closing quote of the key read on from the backslash at `bs`, within `PROBE_MAX` bytes (`ok == true`),
// otherwise `ok == false` and `at` is the byte `string_escaped` reads on from. Reads byte by byte, as a key is short
// and `string_escaped` reads a whole block. When the quote is found here, `credit` is the bytes its escapes save.
@(private, require_results)
key_escaped_head :: #force_inline proc "contextless" (bs, end: [^]u8) -> (q, at: [^]u8, credit: u32, ok: bool) #no_bounds_check {
	if intrinsics.ptr_sub(end, bs) <= PROBE_MAX {
		return nil, bs, 0, false
	}
	e := bs
	stop := bs[PROBE_MAX - 12:]
	for intrinsics.ptr_sub(stop, e) > 0 {
		c := e[0]
		if STOP[c] == 0 {
			e = e[1:]
			continue
		}
		if c == '"' {
			return e[1:], nil, credit, true
		}
		if c != '\\' {
			break
		}
		n, add := escape_credit(e, end)
		if n == 0 {
			break
		}
		credit += add
		e = e[n:]
	}
	return nil, e, 0, false
}

// One past the closing quote of the string at `p`, which closes at `quote`, when it is plain ASCII, read 64 bytes a
// step while 64 remain (`ok == true`), otherwise `escaped == true` with `escape` at the backslash, or both false.
@(private, require_results)
string_lean :: #force_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> (q, escape: [^]u8, ok, escaped: bool) #no_bounds_check {
	bs := p[1:]
	when SCALAR_WASM {
		for bs < end {
			c := bs[0]
			when quote == '"' {
				if STOP[c] != 0 {
					if c == '"' {
						return bs[1:], nil, true, false
					}
					if c == '\\' {
						return nil, bs, false, true
					}
					return nil, nil, false, false
				}
			} else {
				if c == quote || c == '\\' || c < 0x20 || c >= 0x80 {
					if c == quote {
						return bs[1:], nil, true, false
					}
					if c == '\\' {
						return nil, bs, false, true
					}
					return nil, nil, false, false
				}
			}
			bs = bs[1:]
		}
		return nil, nil, false, false
	} else {
		for intrinsics.ptr_sub(end, bs) >= 64 {
			sv := string_stops_block(kernel.load(bs), quote)
			if !kernel.any_lane(sv) {
				bs = bs[64:]
				continue
			}
			k := intrinsics.count_trailing_zeros(kernel.pack(sv))
			if bs[k] == quote {
				return bs[k + 1:], nil, true, false
			}
			if bs[k] == '\\' {
				return nil, bs[k:], false, true
			}
			return nil, nil, false, false
		}
		return nil, nil, false, false
	}
}

// One past the closing quote `quote` of the string read on from `bs`, while its bytes are ASCII and each escape is one
// `escape_len` accepts within a block (`ok == true`). No escape may run into the first block.
@(private, require_results)
string_escaped :: #force_inline proc "contextless" (bs, end: [^]u8, $quote: u8) -> (q: [^]u8, ok: bool) #no_bounds_check {
	when SCALAR_WASM {
		return nil, false
	} else {
		bs := bs
		// 1 when an odd run of backslashes ends the previous block, escaping the first byte of this one.
		odd: u64
		for intrinsics.ptr_sub(end, bs) >= 64 {
			b := kernel.load(bs)
			if odd == 0 && !kernel.any_lane(string_stops_block(b, quote)) {
				bs = bs[64:]
				continue
			}
			// `ctl` holds both control bytes (< 0x20) and non-ASCII bytes (>= 0x80), so non-ASCII bytes after the closing
			// quote are masked out instead of rejecting the whole block.
			m := kernel.pack_n([3]kernel.Block{kernel.eq(b, quote), kernel.eq(b, '\\'), control_or_high_block(b)})
			quotes, slash, ctl := m[0], m[1], m[2]
			// A block with at most one backslash and no escape running into it reads that escape alone and skips the
			// class masks. Sparse escapes are the common case.
			if odd == 0 && slash & (slash - 1) == 0 {
				covered: u64
				if slash != 0 {
					k := intrinsics.count_trailing_zeros(slash)
					n := escape_len(bs[k:], end)
					if n == 0 || k + n > 64 {
						return nil, false
					}
					covered = (u64(1) << n - 1) << k
				}
				real := quotes &~ covered
				if real == 0 {
					if ctl != 0 {
						return nil, false
					}
					bs = bs[64:]
					continue
				}
				kq := intrinsics.count_trailing_zeros(real)
				if ctl & (u64(1) << kq - 1) != 0 {
					return nil, false
				}
				return bs[kq + 1:], true
			}
			escaped := kernel.escaped(slash, &odd)
			c := kernel.classes(STATE_TIER, b, ESCAPE_CLASSES)
			n := kernel.pack_n([4]kernel.Block{kernel.has(c, ESC_LETTER | ESC_U), kernel.has(c, ESC_U), kernel.has(c, ESC_HEX), kernel.has(c, ESC_D)})
			letter, u, hex, d := n[0], n[1], n[2], n[3]
			u &= escaped
			digits := u << 1 | u << 2 | u << 3 | u << 4
			// A surrogate half's `\u` has `d` then a digit of 8 to B (high half) or C to F (low half), and a high half's
			// `\u` is six lanes before its low half's.
			half := u & (d >> 1)
			high, low: u64
			if half != 0 {
				c2 := kernel.classes(STATE_TIER, b, SURROGATE_CLASSES)
				h2 := kernel.pack_n([2]kernel.Block{kernel.has(c2, SUR_HIGH), kernel.has(c2, SUR_LOW)})
				high, low = half & (h2[0] >> 2), half & (h2[1] >> 2)
			}
			// A `\u` escape whose digits run past the block returns false, for the byte reader to settle.
			bad := escaped &~ letter | digits &~ hex | high &~ (low >> 6) | low &~ (high << 6) | u >> 60 << 60 | ctl
			real := quotes &~ escaped &~ digits
			if real == 0 {
				if bad != 0 {
					return nil, false
				}
				bs = bs[64:]
				continue
			}
			k := intrinsics.count_trailing_zeros(real)
			if bad & (u64(1) << k - 1) != 0 {
				return nil, false
			}
			return bs[k + 1:], true
		}
		return nil, false
	}
}

when !SCALAR_WASM {
	// Bits of `ESCAPE_CLASSES`, the byte classes `string_escaped` tells escapes apart by.
	@(private = "file")
	ESC_LETTER :: 0x0f
	@(private = "file")
	ESC_U :: 0x10
	@(private = "file")
	ESC_HEX :: 0x60
	@(private = "file")
	ESC_D :: 0x80

	@(private = "file", rodata)
	ESCAPE_CLASSES := kernel.Nibble_Table {
		lo = {0x20, 0x60, 0x6d, 0x60, 0xe8, 0x70, 0x64, 0x20, 0x20, 0x20, 0x00, 0x00, 0x02, 0x00, 0x04, 0x01},
		hi = {0x00, 0x00, 0x01, 0x20, 0xc0, 0x02, 0xc4, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	}

	@(private = "file")
	SUR_HIGH :: 0x03
	@(private = "file")
	SUR_LOW :: 0x04

	// The classes of a surrogate half's second hex digit, `SUR_HIGH` for 8 to B and `SUR_LOW` for C to F.
	@(private = "file", rodata)
	SURROGATE_CLASSES := kernel.Nibble_Table {
		lo = {0x00, 0x02, 0x02, 0x04, 0x04, 0x04, 0x04, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
		hi = {0x00, 0x00, 0x00, 0x01, 0x06, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	}
}

// One past the closing quote of the string at `p` and its spelling, or the fault. The CPU's block reader tries first,
// and `string_exact` settles what it refuses. A string the block reader accepts is a JSON5 string of the same span.
@(private, require_results)
string_long :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	when SCALAR_WASM {
		return string_exact_in(w, p, end)
	} else {
		when S == .Json5 {
			if w.refused >= BLOCK_RETIRE {
				w.refused = w.refused + 1 if w.refused < BLOCK_RETIRE + BLOCK_RETRY else BLOCK_RETIRE - 1
				return string_exact_in(w, p, end)
			}
		}
		ok: bool
		q, spelling, ok = string_block(w, p, end, '"')
		if !ok {
			when S == .Json5 {
				w.refused += 1
			}
			return string_exact_in(w, p, end)
		}
		when S == .Json5 {
			if w.refused != 0 {
				w.refused -= 1
			}
		}
		return q, spelling, .None
	}
}

// `Walk.refused` counts the strings the block reader of `string_long` refused, less the strings it read. A JSON or
// JSONC text is refused only at a fault or a tolerated byte, so only a JSON5 walk keeps the count, raised by JSON5's
// own escapes. From `BLOCK_RETIRE` on, `string_long` and `st_string_escaped` leave double-quoted value strings to the
// byte reader (single-quoted JSON5 strings and escaped keys do not consult `w.refused`), and each such string counts
// on, until `BLOCK_RETRY` of them have passed and the next string tries the block reader again.
@(private)
BLOCK_RETIRE :: 16
@(private = "file")
BLOCK_RETRY :: 64

// `string_exact` for the walk `w`, which marks the walk when its tolerances took a byte of the string.
@(private, require_results)
string_exact_in :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	q, spelling, kind = string_exact(S == .Json5, p, end, w.tolerate)
	w.tolerated ||= spelling & tape.SPELLING_LAX != 0
	when LAX {
		if kind == .Truncated && piece_more(w) {
			piece_cut_string(w, p, end)
		}
	}
	return
}

// The `string_span` of the CPU's tier, for a string closed by `quote`.
@(private, require_results)
string_block :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8, $quote: u8) -> ([^]u8, u16, bool) {
	when SCALAR_WASM {
		return nil, 0, false
	} else when ODIN_ARCH == .amd64 {
		switch w.tier {
		case .V3:
			return string_span_v3(p, end, quote)
		case .V2:
			return string_span_v2(p, end, quote)
		}
		return nil, 0, false
	} else {
		return string_span_base(p, end, quote)
	}
}

when !SCALAR_WASM {
	// `string_span` has a copy per tier, each out of line with its tier's target features, since the states are built
	// for the floor tier.
	when ODIN_ARCH == .amd64 {
		@(private = "file", require_results, enable_target_feature = kernel.FEATURES[.V2])
		string_span_v2 :: #force_no_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> ([^]u8, u16, bool) {
			return string_span(.V2, p, end, quote)
		}
		@(private = "file", require_results, enable_target_feature = kernel.FEATURES[.V3])
		string_span_v3 :: #force_no_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> ([^]u8, u16, bool) {
			return string_span(.V3, p, end, quote)
		}
	} else {
		@(private = "file", require_results)
		string_span_base :: #force_no_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> ([^]u8, u16, bool) {
			return string_span(.Base, p, end, quote)
		}
	}

	// One past the closing quote `quote` of the string at `p` and its spelling, `SPELLING_DECODE` or `SPELLING_ASCII`,
	// with `ok == true`, or `ok == false` when the block reader cannot vouch for it (a control byte, an escape it does
	// not accept, invalid UTF-8, a non-over-readable `< 64`-byte tail, or the text's end), which `string_exact`
	// settles. Blocks are read back to back from `p + 1`, so the UTF-8 state carries from one to the next. Kept leaf
	// (no calls) by bailing page-boundary `< 64`-byte tails to `string_exact`.
	@(private = "file", require_results)
	string_span :: #force_inline proc "contextless" ($T: kernel.Tier, p, end: [^]u8, $quote: u8) -> (q: [^]u8, spelling: u16, ok: bool) #no_bounds_check {
		bs := p[1:]
		skip: u64
		// Cleared by an escape or a block with a byte past 0x7F. A block with a stop before the last holds an escape.
		spelling = tape.SPELLING_ASCII
		u: kernel.Utf8_State
		// Whether the last block had a byte past 0x7F. An ASCII block after one closes the UTF-8 state.
		high: bool
		for {
			live := u64(intrinsics.ptr_sub(end, bs))
			b: kernel.Block
			if live >= 64 {
				b = kernel.load(bs)
			} else if live > 0 {
				when ODIN_SANITIZER_FLAGS != {} {
					return nil, 0, false
				} else {
					if uintptr(bs) & 4095 > 4096 - 64 {
						return nil, 0, false
					}
					// Safe to over-read 64 bytes within `bs`'s 4 KiB page. Zeroing lanes `live ..< 64` does double
					// duty: zeros are ASCII to the UTF-8 state, and `0x00 < 0x20` guarantees a stop past `live` (since
					// `escape_len` bounds `k + n <= live`), so `k >= live` always terminates before `bs = bs[64:]` can
					// advance past `end`.
					W :: #simd[64]u8
					when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32 {
						raw := kernel.load(bs)
						i := simd.indices(V)
						lv := V(u8(live))
						b = {
							simd.bit_and(raw[0], simd.lanes_lt(i, lv)),
							simd.bit_and(raw[1], simd.lanes_lt(i + V(16), lv)),
							simd.bit_and(raw[2], simd.lanes_lt(i + V(32), lv)),
							simd.bit_and(raw[3], simd.lanes_lt(i + V(48), lv)),
						}
					} else {
						b = transmute(kernel.Block)simd.bit_and(transmute(W)kernel.load(bs), simd.lanes_lt(simd.indices(W), W(u8(live))))
					}
				}
			} else {
				return nil, 0, false
			}
			sv := kernel.either(kernel.either(kernel.eq(b, quote), kernel.eq(b, '\\')), kernel.below(b, 0x20))
			ascii := kernel.is_ascii(b)
			has_stop: bool
			stop: u64
			when ODIN_ARCH == .amd64 {
				// Pack before the branch so LLVM does not keep a 64-lane predicate live across the CFG edge and scalarize it.
				stop = kernel.pack(sv)
				has_stop = skip != 0 || stop != 0
			} else {
				// A block with no stop is skipped without packing its mask, unless an escape ran into it.
				has_stop = skip != 0 || kernel.any_lane(sv)
			}
			if has_stop {
				when ODIN_ARCH == .amd64 {
					stop &= max(u64) << skip
				} else {
					stop = kernel.pack(sv) & (max(u64) << skip)
				}
				skip = 0
				for stop != 0 {
					k := intrinsics.count_trailing_zeros(stop)
					if k >= live {
						return nil, 0, false
					}
					c := bs[k]
					if c == quote {
						// The string ends in this block, so `utf8_stop` judges its bytes up to the quote and none past it.
						if !kernel.utf8_stop(T, b, ascii, &u, high, k) {
							return nil, 0, false
						}
						if intrinsics.expect(spelling == tape.SPELLING_ASCII && !ascii, false) {
							if ~kernel.pack(kernel.below(b, 0x80)) & (u64(1) << k - 1) != 0 {
								spelling = 0
							}
						}
						return bs[k + 1:], spelling, true
					}
					if c != '\\' {
						return nil, 0, false
					}
					n := escape_len(bs[k:], end)
					if n == 0 {
						return nil, 0, false
					}
					spelling = tape.SPELLING_DECODE
					k += n
					if k >= 64 {
						skip = k - 64
						break
					}
					stop &= max(u64) << k
				}
			} else if !ascii {
				spelling &~= tape.SPELLING_ASCII
			}
			kernel.utf8_next(T, b, ascii, &u, &high)
			bs = bs[64:]
		}
	}

	// The length of the escape at the backslash `e` that the block reader accepts, a one-letter escape, a `\u` escape
	// outside the surrogates or a surrogate pair, and 0 for any other.
	@(private = "file", require_results)
	escape_len :: #force_inline proc "contextless" (e, end: [^]u8) -> u64 {
		_, n := spell.string_escape(e, intrinsics.ptr_sub(end, e))
		return u64(n)
	}
}

// As `escape_len`, with the credit the escape saves: its source bytes less the bytes its code point decodes to. Only
// a short escaped key asks for it, so no other string pays for the code point's length.
@(private = "file", require_results)
escape_credit :: #force_inline proc "contextless" (e, end: [^]u8) -> (n: u64, credit: u32) {
	r, m := spell.string_escape(e, intrinsics.ptr_sub(end, e))
	if m == 0 {
		return 0, 0
	}
	return u64(m), u32(m) - spell.rune_len(r)
}

// One past the closing quote of the string at `p` and its spelling, or the fault at the first byte that breaks it, read
// one byte at a time. JSON's string closes at `"`, holds no control byte and uses the escapes of `escape_exact`. A JSON5
// string closes at its own quote, `"` or `'`, uses the escapes of `escape5` and holds any byte but CR and LF. With
// `.Invalid_Utf8` in `tol` an ill-formed sequence is passed by its maximal subpart and the string is
// `SPELLING_LAX`, while a sequence the text's end cuts short leaves the string open, `Truncated`. With
// `.Lone_Surrogate` an escape of a surrogate half with no partner is passed and the string is `SPELLING_LAX` as well.
@(private, cold, require_results)
string_exact :: #force_no_inline proc "contextless" ($json5: bool, p, end: [^]u8, tol: tape.Tolerances) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	q, spelling, kind = string_exact_on(json5, p[0] if json5 else '"', p[1:], end, tol, tape.SPELLING_ASCII)
	if kind == .Truncated {
		return end, 0, .Truncated
	}
	return
}

// `string_exact` read on from `q` inside a string closed by `quote`, outside an escape and a UTF-8 sequence, with the
// spelling so far, which is `SPELLING_ASCII` at the string's start. A string the text's end cuts short gives
// `Truncated` and the spelling so far at the place it can be read on from: the escape or sequence the end cuts, or else
// the last character, as a JSON5 escape is judged by the byte after it.
@(private, require_results)
string_exact_on :: #force_inline proc "contextless" ($json5: bool, quote: u8, q, end: [^]u8, tol: tape.Tolerances, spelling: u16) -> ([^]u8, u16, tape.Fault_Kind) #no_bounds_check {
	q, spelling := q, spelling
	last := q
	for {
		if q >= end {
			return last, spelling, .Truncated
		}
		last = q
		c := q[0]
		switch {
		case c == quote:
			return q[1:], spelling, .None
		case c == '\\':
			r: [^]u8
			k: tape.Fault_Kind
			lone: bool
			when json5 {
				r, k, lone = escape5(q, end, tol)
			} else {
				r, k, lone = escape_exact(q, end, tol)
			}
			if k == .Truncated {
				return q, spelling, k
			}
			if k != .None {
				return r, 0, k
			}
			spelling = spelling &~ tape.SPELLING_ASCII | tape.SPELLING_DECODE
			if lone {
				spelling |= tape.SPELLING_LAX
			}
			when json5 {
				spelling |= 0 if spell.ESCAPED[q[1]] != 0 || q[1] == 'u' else SPELLING_JSON5
			}
			q = r
		case (c == '\n' || c == '\r') if json5 else c < 0x20:
			return q, 0, .Bad_Char
		case c < 0x80:
			q = q[1:]
		case:
			spelling &~= tape.SPELLING_ASCII
			r, k := spell.utf8_char(q, end)
			if k == .Bad_Char && .Invalid_Utf8 in tol {
				spelling |= tape.SPELLING_DECODE | tape.SPELLING_LAX
				r, k = spell.utf8_subpart(q, end), .None
			}
			if k == .Truncated {
				return q, spelling, k
			}
			if k != .None {
				return r, 0, k
			}
			q = r
		}
	}
}

// One past the escape at the backslash `e`, or `Bad_Escape` at a bad letter or hex digit or at the backslash of a lone
// surrogate half, or `Truncated` when the text ends first. With `.Lone_Surrogate` in `tol` a lone half is passed, one
// past its four digits, and `lone` says so.
@(private, require_results)
escape_exact :: #force_inline proc "contextless" (e, end: [^]u8, tol: tape.Tolerances) -> (q: [^]u8, kind: tape.Fault_Kind, lone: bool) #no_bounds_check {
	q = e[1:]
	if q >= end {
		return end, .Truncated, false
	}
	if spell.ESCAPED[q[0]] != 0 {
		return q[1:], .None, false
	}
	if q[0] != 'u' {
		return q, .Bad_Escape, false
	}
	unit: u32
	if unit, q, kind = escape_digits(q[1:], end, 4); kind != .None {
		return q, kind, false
	}
	if spell.low_surrogate(unit) {
		if .Lone_Surrogate in tol {
			return q, .None, true
		}
		return e, .Bad_Escape, false
	}
	if spell.high_surrogate(unit) {
		// `\`, `u` and a low half's four digits in turn, each refused at its own byte, so a text cut inside them gives
		// `Truncated` where a wrong byte gives `Bad_Escape`.
		for i in 0 ..< 6 {
			if q[i:] >= end {
				return end, .Truncated, false
			}
			h := spell.HEX_NIBBLE[q[i]]
			ok := q[i] == ('\\' if i == 0 else 'u') if i < 2 else (h == 0xd if i == 2 else (h - 0xc < 4 if i == 3 else h != 0xff))
			if !ok {
				if .Lone_Surrogate in tol {
					return q, .None, true
				}
				return e, .Bad_Escape, false
			}
		}
		q = q[6:]
	}
	return q, .None, false
}

// The value of the `n` hex digits at `q` and one past them, or `Bad_Escape` at the first that is no hex digit, or
// `Truncated` when the text ends first.
@(private, require_results)
escape_digits :: #force_inline proc "contextless" (q, end: [^]u8, $n: int) -> (unit: u32, r: [^]u8, kind: tape.Fault_Kind) #no_bounds_check {
	r = q
	for _ in 0 ..< n {
		if r >= end {
			return unit, end, .Truncated
		}
		h := spell.HEX_NIBBLE[r[0]]
		if h == 0xff {
			return unit, r, .Bad_Escape
		}
		unit = unit << 4 | u32(h)
		r = r[1:]
	}
	return
}

// The bytes that end a run of plain string bytes, 1 for `"`, `\`, control bytes and bytes past 0x7F.
@(private = "file", rodata)
STOP := [256]u8 {
	0 ..< 0x20 = 1,
	'"' = 1,
	'\\' = 1,
	0x80 ..= 0xff = 1,
}
