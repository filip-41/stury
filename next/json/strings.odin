package json

import "base:intrinsics"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

@(private)
V :: #simd[16]u8

// Whether the token from `p` to `q` is longer than `Token.n` holds.
@(private)
too_wide :: #force_inline proc "contextless" (p, q: [^]u8) -> bool {
	return u64(intrinsics.ptr_sub(q, p)) > u64(max(u32))
}

// The lanes of `v` holding the closing quote `quote`, `\`, a control byte or a byte past 0x7F.
@(private)
string_stops :: #force_inline proc "contextless" (v: V, $quote: u8) -> V {
	return simd.bit_or(simd.bit_or(simd.lanes_eq(v, V(quote)), simd.lanes_eq(v, V('\\'))), kernel.control_or_high16(v, false))
}

@(private)
string_stops_block :: #force_inline proc "contextless" (b: kernel.Block, $quote: u8) -> kernel.Block {
	return {string_stops(b[0], quote), string_stops(b[1], quote), string_stops(b[2], quote), string_stops(b[3], quote)}
}

// One past the closing quote of the string at `p`, which closes at `quote`, when it closes within 32 bytes as
// printable ASCII. Otherwise nil, whether a backslash came first, and the first byte that is neither printable ASCII
// nor a quote, nil when none is within 32 bytes.
@(private)
string_short :: #force_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> (q: [^]u8, escaped: bool, stop: [^]u8) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= 32 {
		return nil, false, nil
	}
	k := kernel.first_lane16(string_stops(kernel.load16(p[1:]), quote))
	if k == 16 {
		k = 16 + kernel.first_lane16(string_stops(kernel.load16(p[17:]), quote))
		if k == 32 {
			return nil, false, nil
		}
	}
	if p[1 + k] != quote {
		if p[1 + k] == '\\' {
			return nil, true, p[1 + k:]
		}
		return nil, false, p[1 + k:]
	}
	return p[2 + k:], false, nil
}

// One past the closing quote of the string at `p` when it closes within 32 bytes with no backslash or control byte
// and its bytes are UTF-8, else nil. The text must hold more than 32 bytes from `p`. The bytes from the quote on
// are zeroed before the UTF-8 check, so a sequence the quote cuts fails on the zeros after it, which a quote at lane 31
// or before leaves in `w1`.
@(private)
string_utf8 :: #force_inline proc "contextless" (p: [^]u8) -> [^]u8 #no_bounds_check {
	v0, v1 := kernel.load16(p[1:]), kernel.load16(p[17:])
	stops :: #force_inline proc "contextless" (v: V) -> V {
		return simd.bit_or(simd.bit_or(simd.lanes_eq(v, V('"')), simd.lanes_eq(v, V('\\'))), simd.lanes_lt(v, V(0x20)))
	}
	k := kernel.first_lane16(stops(v0))
	if k == 16 {
		k = 16 + kernel.first_lane16(stops(v1))
		if k == 32 {
			return nil
		}
	}
	if p[1 + k] != '"' {
		return nil
	}
	i := simd.indices(V)
	w0 := simd.bit_and(v0, simd.lanes_lt(i, V(u8(k))))
	w1 := simd.bit_and(v1, simd.lanes_lt(i + 16, V(u8(k))))
	err := simd.bit_or(kernel.utf8_window(V{}, w0), kernel.utf8_window(w0, w1))
	if !kernel.all_zero(err) {
		return nil
	}
	return p[2 + k:]
}

// The longest key `string_probe` reads.
@(private)
PROBE_MAX :: 32

// One past the closing quote of the key at `p` when it closes within `PROBE_MAX` bytes as printable ASCII. Otherwise
// nil, whether a backslash came first, and the first byte that is neither printable ASCII nor a quote, nil when none is
// within `PROBE_MAX` bytes. Reads byte by byte, as keys are short and a vector's mask waits on its reduction.
@(private)
string_probe :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, escaped: bool, stop: [^]u8) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= PROBE_MAX {
		return nil, false, nil
	}
	#unroll for k in 1 ..= PROBE_MAX {
		if intrinsics.expect(STOP[p[k]] != 0, false) {
			if p[k] == '"' {
				return p[k + 1:], false, nil
			}
			return nil, p[k] == '\\', p[k:]
		}
	}
	return nil, false, nil
}

// One past the closing quote of the key read on from the backslash at `bs`, within `PROBE_MAX` bytes; otherwise nil and
// the byte `string_escaped` reads on from. Reads byte by byte, as a key is short and `string_escaped` pays for a whole
// block.
@(private)
key_escaped_head :: #force_inline proc "contextless" (bs, end: [^]u8) -> (q, at: [^]u8) #no_bounds_check {
	if intrinsics.ptr_sub(end, bs) <= PROBE_MAX {
		return nil, bs
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
			return e[1:], nil
		}
		if c != '\\' {
			break
		}
		n := escape_len(e, end)
		if n == 0 {
			break
		}
		e = e[n:]
	}
	return nil, e
}

// One past the closing quote of the string at `p`, which closes at `quote`, when it is plain ASCII, read 64 bytes a
// step while 64 remain; otherwise nil and, when the first stop is a backslash, that backslash.
@(private)
string_lean :: #force_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> (q, escape: [^]u8) #no_bounds_check {
	bs := p[1:]
	for intrinsics.ptr_sub(end, bs) >= 64 {
		sv := string_stops_block(kernel.load(bs), quote)
		if !kernel.any_lane(sv) {
			bs = bs[64:]
			continue
		}
		k := intrinsics.count_trailing_zeros(kernel.pack(sv))
		if bs[k] == quote {
			return bs[k + 1:], nil
		}
		return nil, bs[k:] if bs[k] == '\\' else nil
	}
	return nil, nil
}

// One past the closing quote `quote` of the string read on from `bs`, while its bytes are ASCII and each escape is one
// `escape_len` accepts within a block; otherwise nil. No escape may run into the first block.
@(private)
string_escaped :: #force_inline proc "contextless" (bs, end: [^]u8, $quote: u8) -> [^]u8 #no_bounds_check {
	bs := bs
	// 1 when an odd run of backslashes ends the previous block, escaping the first byte of this one.
	odd: u64
	for intrinsics.ptr_sub(end, bs) >= 64 {
		b := kernel.load(bs)
		sv := string_stops_block(b, quote)
		if odd == 0 && !kernel.any_lane(sv) {
			bs = bs[64:]
			continue
		}
		// A byte past 0x7F is a stop the mask paths below do not read, so `string_long` validates it.
		if !kernel.is_ascii(b) {
			return nil
		}
		m := kernel.pack_n([3]kernel.Block{kernel.eq(b, quote), kernel.eq(b, '\\'), kernel.below(b, 0x20)})
		quotes, slash, ctl := m[0], m[1], m[2]
		// A block with at most one backslash and no escape running into it reads that escape alone and skips the
		// class masks. Sparse escapes are the common case.
		if odd == 0 && slash & (slash - 1) == 0 {
			covered: u64
			if slash != 0 {
				k := intrinsics.count_trailing_zeros(slash)
				n := escape_len(bs[k:], end)
				if n == 0 || k + n > 64 {
					return nil
				}
				covered = (u64(1) << n - 1) << k
			}
			real := quotes &~ covered
			if real == 0 {
				if ctl != 0 {
					return nil
				}
				bs = bs[64:]
				continue
			}
			kq := intrinsics.count_trailing_zeros(real)
			if ctl & (u64(1) << kq - 1) != 0 {
				return nil
			}
			return bs[kq + 1:]
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
		// A `\u` escape whose digits run past the block returns nil, for the byte reader to settle.
		bad := escaped &~ letter | digits &~ hex | high &~ (low >> 6) | low &~ (high << 6) | u >> 60 << 60 | ctl
		real := quotes &~ escaped &~ digits
		if real == 0 {
			if bad != 0 {
				return nil
			}
			bs = bs[64:]
			continue
		}
		k := intrinsics.count_trailing_zeros(real)
		if bad & (u64(1) << k - 1) != 0 {
			return nil
		}
		return bs[k + 1:]
	}
	return nil
}

// Bits of `ESCAPE_CLASSES`, the byte classes `string_escaped` tells escapes apart by.
@(private)
ESC_LETTER :: 0x0f
@(private)
ESC_U :: 0x10
@(private)
ESC_HEX :: 0x60
@(private)
ESC_D :: 0x80

@(private, rodata)
ESCAPE_CLASSES := kernel.Nibble_Table {
	lo = {0x20, 0x60, 0x6d, 0x60, 0xe8, 0x70, 0x64, 0x20, 0x20, 0x20, 0x00, 0x00, 0x02, 0x00, 0x04, 0x01},
	hi = {0x00, 0x00, 0x01, 0x20, 0xc0, 0x02, 0xc4, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
}

@(private)
SUR_HIGH :: 0x03
@(private)
SUR_LOW :: 0x04

// The classes of a surrogate half's second hex digit, `SUR_HIGH` for 8 to B and `SUR_LOW` for C to F.
@(private, rodata)
SURROGATE_CLASSES := kernel.Nibble_Table {
	lo = {0x00, 0x02, 0x02, 0x04, 0x04, 0x04, 0x04, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	hi = {0x00, 0x00, 0x00, 0x01, 0x06, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
}

// One past the closing quote of the string at `p` and its spelling, or the fault. The CPU's block reader tries first,
// and `string_exact` settles what it refuses. A string the block reader accepts is a JSON5 string of the same span.
// The tier switch is `string_block`'s written out, because a call through `string_block` leaves a dead fault test on
// the block reader's path.
@(private)
string_long :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	esc: bool
	when ODIN_ARCH == .amd64 {
		switch w.tier {
		case .V3:
			q, esc = string_span_v3(p, end, '"')
		case .V2:
			q, esc = string_span_v2(p, end, '"')
		}
	} else {
		q, esc = string_span_base(p, end, '"')
	}
	if q == nil {
		return string_exact_in(w, p, end)
	}
	return q, tape.SPELLING_DECODE if esc else 0, .None
}

// `string_exact` for the walk `w`, which marks the walk when its tolerances took a byte of the string.
@(private)
string_exact_in :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	q, spelling, kind = string_exact(S == .Json5, LAX, p, end, w.tolerate when LAX else {})
	when LAX {
		w.tolerated ||= spelling & tape.SPELLING_LAX != 0
		if kind == .Truncated && piece_more(w) {
			piece_cut_string(w, p, end)
		}
	}
	return
}

// The `string_span` of the CPU's tier, for a string closed by `quote`.
@(private)
string_block :: #force_inline proc "contextless" (w: ^Walk($S, $H, $LAX, $C), p, end: [^]u8, $quote: u8) -> ([^]u8, bool) {
	when ODIN_ARCH == .amd64 {
		switch w.tier {
		case .V3:
			return string_span_v3(p, end, quote)
		case .V2:
			return string_span_v2(p, end, quote)
		}
		return nil, false
	} else {
		return string_span_base(p, end, quote)
	}
}

// `string_span` has a copy per tier, each out of line with its tier's target features, since the states are built for
// the floor tier.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	string_span_v2 :: #force_no_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> ([^]u8, bool) {
		return string_span(.V2, p, end, quote)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	string_span_v3 :: #force_no_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> ([^]u8, bool) {
		return string_span(.V3, p, end, quote)
	}
} else {
	@(private)
	string_span_base :: #force_no_inline proc "contextless" (p, end: [^]u8, $quote: u8) -> ([^]u8, bool) {
		return string_span(.Base, p, end, quote)
	}
}

// One past the closing quote `quote` of the string at `p` and whether it holds an escape; nil when the block reader
// cannot vouch for it (a control byte, an escape it does not accept, invalid UTF-8, the text's end), which
// `string_exact` settles. Blocks are read back to back from `p + 1`, so the UTF-8 state carries from one to the next.
@(private)
string_span :: #force_inline proc "contextless" ($T: kernel.Tier, p, end: [^]u8, $quote: u8) -> (q: [^]u8, esc: bool) #no_bounds_check {
	bs := p[1:]
	skip: u64
	u: kernel.Utf8_State
	// Whether the last block had a byte past 0x7F. An ASCII block after one closes the UTF-8 state.
	high: bool
	for {
		live := u64(intrinsics.ptr_sub(end, bs))
		b: kernel.Block
		if live >= 64 {
			b = kernel.load(bs)
		} else if live > 0 {
			// Zeros past `live` are ASCII to the UTF-8 state, and `k >= live` ends the string before a stop past the
			// end is read.
			b = kernel.load_padded(bs[:live], 0)
		} else {
			return nil, false
		}
		sv := kernel.either(kernel.either(kernel.eq(b, quote), kernel.eq(b, '\\')), kernel.below(b, 0x20))
		ascii := kernel.is_ascii(b)
		// A block with no stop is skipped without packing its mask, unless an escape ran into it.
		if skip == 0 && !kernel.any_lane(sv) {
			kernel.utf8_next(T, b, ascii, &u, &high)
			bs = bs[64:]
			continue
		}
		stop := kernel.pack(sv) & (max(u64) << skip)
		skip = 0
		for stop != 0 {
			k := intrinsics.count_trailing_zeros(stop)
			if k >= live {
				return nil, false
			}
			c := bs[k]
			if c == quote {
				// The string ends in this block, so `utf8_stop` judges its bytes up to the quote and none past it.
				if !kernel.utf8_stop(T, b, ascii, &u, high, k) {
					return nil, false
				}
				return bs[k + 1:], esc
			}
			if c != '\\' {
				return nil, false
			}
			n := escape_len(bs[k:], end)
			if n == 0 {
				return nil, false
			}
			esc = true
			k += n
			if k >= 64 {
				skip = k - 64
				break
			}
			stop &= max(u64) << k
		}
		kernel.utf8_next(T, b, ascii, &u, &high)
		bs = bs[64:]
	}
}

// The length of the escape at the backslash `e` that the block reader accepts, a one-letter escape, a `\u` escape
// outside the surrogates or a surrogate pair; 0 for any other.
@(private)
escape_len :: #force_inline proc "contextless" (e, end: [^]u8) -> u64 {
	_, n := spell.string_escape(e, intrinsics.ptr_sub(end, e))
	return u64(n)
}

// One past the closing quote of the string at `p` and its spelling, or the fault at the first byte that breaks it, read
// one byte at a time. JSON's string closes at `"`, holds no control byte and uses the escapes of `escape_exact`. A JSON5
// string closes at its own quote, `"` or `'`, uses the escapes of `escape5` and holds any byte but CR and LF. With
// `LAX` and `.Invalid_Utf8` in `tol` an ill-formed sequence is passed by its maximal subpart and the string is
// `SPELLING_LAX`, while a sequence the text's end cuts short leaves the string open, `Truncated`. With
// `.Lone_Surrogate` an escape of a surrogate half with no partner is passed and the string is `SPELLING_LAX` as well.
// Without `LAX`, `tol` is not read.
@(private, cold)
string_exact :: #force_no_inline proc "contextless" ($json5, $LAX: bool, p, end: [^]u8, tol: tape.Tolerances) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	q, spelling, kind = string_exact_on(json5, LAX, p[0] if json5 else '"', p[1:], end, tol, 0)
	if kind == .Truncated {
		return end, 0, .Truncated
	}
	return
}

// `string_exact` read on from `q` inside a string closed by `quote`, outside an escape and a UTF-8 sequence, with the
// spelling so far. A string the text's end cuts short gives `Truncated` and the spelling so far at the place it can be
// read on from: the escape or sequence the end cuts, or else the last character, as a JSON5 escape is judged by the
// byte after it.
@(private)
string_exact_on :: #force_inline proc "contextless" ($json5, $LAX: bool, quote: u8, q, end: [^]u8, tol: tape.Tolerances, spelling: u16) -> ([^]u8, u16, tape.Fault_Kind) #no_bounds_check {
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
				r, k, lone = escape5(q, end, LAX, tol)
			} else {
				r, k, lone = escape_exact(q, end, LAX, tol)
			}
			if k == .Truncated {
				return q, spelling, k
			}
			if k != .None {
				return r, 0, k
			}
			spelling |= tape.SPELLING_DECODE
			when LAX {
				spelling |= tape.SPELLING_LAX if lone else 0
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
			r, k := spell.utf8_char(q, end)
			when LAX {
				if k == .Bad_Char && .Invalid_Utf8 in tol {
					spelling |= tape.SPELLING_DECODE | tape.SPELLING_LAX
					r, k = spell.utf8_subpart(q, end), .None
				}
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
// surrogate half, or `Truncated` when the text ends first. With `LAX` and `.Lone_Surrogate` in `tol` a lone half is
// passed, one past its four digits, and `lone` says so. Without `LAX`, `tol` is not read.
@(private)
escape_exact :: #force_inline proc "contextless" (e, end: [^]u8, $LAX: bool, tol: tape.Tolerances) -> (q: [^]u8, kind: tape.Fault_Kind, lone: bool) #no_bounds_check {
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
		when LAX {
			if .Lone_Surrogate in tol {
				return q, .None, true
			}
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
				when LAX {
					if .Lone_Surrogate in tol {
						return q, .None, true
					}
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
@(private)
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
@(private, rodata)
STOP := [256]u8 {
	0 ..< 0x20 = 1,
	'"' = 1,
	'\\' = 1,
	0x80 ..= 0xff = 1,
}
