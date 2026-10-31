package json

import "base:intrinsics"
import "core:simd"
import core "../core"
import kernel "../core/kernel"

// The leaves the states read tokens with each return one past the token, or the fault's kind and the byte it is at
// (`Truncated` at the text's end).

// Whether the token from `p` to `q` is longer than `Token.n`, a `u32`, holds.
@(private)
too_wide :: #force_inline proc "contextless" (p, q: [^]u8) -> bool {
	return u64(intrinsics.ptr_sub(q, p)) > u64(max(u32))
}

// Returns the lanes of `v` that stop a run of plain string bytes: `"`, `\`, a control byte or a byte past 0x7F.
@(private)
string_stops :: #force_inline proc "contextless" (v: #simd[16]u8) -> #simd[16]u8 {
	V :: #simd[16]u8
	// `v - 0x20 > 0x5f` is true for a control byte and a byte past 0x7F.
	return simd.bit_or(simd.bit_or(simd.lanes_eq(v, V('"')), simd.lanes_eq(v, V('\\'))), simd.lanes_gt(v - 0x20, V(0x5f)))
}

@(private)
load16 :: #force_inline proc "contextless" (p: [^]u8) -> #simd[16]u8 {
	return intrinsics.unaligned_load((^#simd[16]u8)(p))
}

// Reads the string whose opening quote is at `p` when its closing quote is one of the next 32 bytes and the bytes
// before it are printable ASCII. Returns one past the closing quote. Else returns nil, whether a backslash came
// first, and the backslash's address.
@(private)
string_short :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, escaped: bool, stop: [^]u8) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= 32 {
		return nil, false, nil
	}
	k := kernel.first_lane(string_stops(load16(p[1:])))
	if k == 16 {
		k = 16 + kernel.first_lane(string_stops(load16(p[17:])))
		if k == 32 {
			return nil, false, nil
		}
	}
	if p[1 + k] != '"' {
		if p[1 + k] == '\\' {
			return nil, true, p[1 + k:]
		}
		return nil, false, nil
	}
	return p[2 + k:], false, nil
}

// The longest key `string_probe` reads, in bytes.
@(private)
PROBE_MAX :: 32

// `string_probe` reads like `string_short`, byte by byte, up to `PROBE_MAX` bytes. Each byte branches on `STOP`, so a
// key whose length repeats reaches a predicted branch at its closing quote and the next token's address does not wait
// on the bytes.
@(private)
string_probe :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, escaped: bool, stop: [^]u8) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= PROBE_MAX {
		return nil, false, nil
	}
	#unroll for k in 1 ..= PROBE_MAX {
		// The stop is the rare branch, so a byte that continues the run falls through rather than jumps.
		if intrinsics.expect(STOP[p[k]] != 0, false) {
			if p[k] == '"' {
				return p[k + 1:], false, nil
			}
			if p[k] == '\\' {
				return nil, true, p[k:]
			}
			return nil, false, nil
		}
	}
	return nil, false, nil
}

// Applies `string_stops` to each 16-byte lane of a 64-byte block. Bytes past 0x7F and below 0x20 are both stops, so a
// block needs no separate test for them, and the reader that cannot take them returns nil for `string_long` to settle.
@(private)
string_stops_block :: #force_inline proc "contextless" (b: kernel.Block) -> kernel.Block {
	return {string_stops(b[0]), string_stops(b[1]), string_stops(b[2]), string_stops(b[3])}
}

// Reads the string at `p` while it is plain ASCII, 64 bytes a step and with no UTF-8 state, while at least 64 bytes
// remain before `end`. Returns one past its closing quote. Else returns nil and, when the first stop is a backslash,
// the address of that backslash, which `string_escaped` reads on from.
@(private)
string_lean :: #force_inline proc "contextless" (p, end: [^]u8) -> (q, escape: [^]u8) #no_bounds_check {
	bs := p[1:]
	for intrinsics.ptr_sub(end, bs) >= 64 {
		b := kernel.load(bs)
		sv := string_stops_block(b)
		if !kernel.any_lane(sv) {
			bs = bs[64:]
			continue
		}
		k := intrinsics.count_trailing_zeros(kernel.pack(sv))
		if bs[k] == '"' {
			return bs[k + 1:], nil
		}
		return nil, bs[k:] if bs[k] == '\\' else nil
	}
	return nil, nil
}

// Reads the string on from `bs`, where no escape runs into the first block, while the bytes are ASCII and every escape
// is one `escape_len` accepts within a block. Returns one past its closing quote, else nil. It judges each block in
// masks with no branch per escape: the escaped lanes, their letters, a `\u` escape's four digits, and the first quote
// that no escape covers.
@(private)
string_escaped :: #force_inline proc "contextless" (bs, end: [^]u8) -> [^]u8 #no_bounds_check {
	bs := bs
	// 1 when an odd run of backslashes ends the previous block, escaping the first byte of this one.
	odd: u64
	for intrinsics.ptr_sub(end, bs) >= 64 {
		b := kernel.load(bs)
		sv := string_stops_block(b)
		if odd == 0 && !kernel.any_lane(sv) {
			bs = bs[64:]
			continue
		}
		// A byte past 0x7F is a stop the mask paths below do not read, so `string_long` validates it.
		if !kernel.is_ascii(b) {
			return nil
		}
		m := kernel.pack_n([3]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, '\\'), kernel.below(b, 0x20)})
		quote, slash, ctl := m[0], m[1], m[2]
		// A block with at most one backslash and no escape running into it reads that escape one byte at a time and
		// skips the class masks. Sparse escapes are the common case.
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
			real := quote &~ covered
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
		real := quote &~ escaped &~ digits
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

// The class bits `string_escaped` reads an escape by: one-letter escapes, `u`, hex digits, and `d` or `D`.
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

// Classes for the second digit of a surrogate half's `\u`: 8 to B for a high half, C to F for a low half.
@(private, rodata)
SURROGATE_CLASSES := kernel.Nibble_Table {
	lo = {0x00, 0x02, 0x02, 0x04, 0x04, 0x04, 0x04, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	hi = {0x00, 0x00, 0x00, 0x01, 0x06, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
}

// Reads the string whose opening quote is at `p`. Returns one past its closing quote, whether it holds an escape and
// whether `Invalid_Utf8` accepted a sequence, or the fault. Uses this CPU's block reader first, then `string_exact`, or
// `string5` in JSON5, which read the walk's tolerances.
@(private)
string_long :: #force_inline proc "contextless" (w: ^Walk($S, $H), p, end: [^]u8) -> (q: [^]u8, esc, lax: bool, kind: core.Fault_Kind) {
	when ODIN_ARCH == .amd64 {
		switch w.tier {
		case .V4:
			q, esc = string_span_v4(p, end, S)
		case .V3:
			q, esc = string_span_v3(p, end, S)
		case .V2:
			q, esc = string_span_v2(p, end, S)
		}
	} else {
		q, esc = string_span_base(p, end, S)
	}
	if q == nil {
		when .Es5 in FEATURES[S] {
			return string5(p, end, w.tolerate)
		} else {
			return string_exact(p, end, w.tolerate)
		}
	}
	return q, esc, false, .None
}

// The spelling bits of a string the walk read: bit 0 when it holds an escape or an ill-formed sequence
// `Invalid_Utf8` accepted, and bit 2 when it holds the latter.
@(private)
string_spelling :: #force_inline proc "contextless" (esc, lax: bool) -> u16 {
	return (core.SPELLING_DECODE if esc || lax else 0) | (core.SPELLING_LAX if lax else 0)
}

// `string_span` has a copy per tier, each out of line with its tier's target features, since the states are built for a
// single tier.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	string_span_v2 :: #force_no_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> ([^]u8, bool) {
		return string_span(.V2, p, end, S)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	string_span_v3 :: #force_no_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> ([^]u8, bool) {
		return string_span(.V3, p, end, S)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	string_span_v4 :: #force_no_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> ([^]u8, bool) {
		return string_span(.V4, p, end, S)
	}
} else {
	@(private)
	string_span_base :: #force_no_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> ([^]u8, bool) {
		return string_span(.Base, p, end, S)
	}
}

// Reads the string whose opening quote is at `p`. Returns one past its closing quote and whether it holds an escape,
// or nil when the block reading cannot vouch for it: a control byte, an escape it does not accept, invalid UTF-8 in a
// block it loaded, or the text's end. `string_exact` settles those. Blocks are loaded 64 bytes on from `p + 1`, so
// they are contiguous and UTF-8 state carries between them. An escape is stepped over inside the block's stop mask,
// so a block is loaded once. In JSON5 the quote is `"` or `'`, every escape `escape5` accepts is stepped over, and a
// control byte other than CR and LF is a character of the string.
@(private)
string_span :: #force_inline proc "contextless" ($T: kernel.Tier, p, end: [^]u8, $S: Spec) -> (q: [^]u8, esc: bool) #no_bounds_check {
	when .Es5 in FEATURES[S] {
		quote := p[0]
	} else {
		quote :: '"'
	}
	bs := p[1:]
	skip: u64
	u: kernel.Utf8_State
	// Whether any block had a byte past 0x7F, and whether the last block did. An ASCII block after one closes the
	// UTF-8 state.
	high, last_high: bool
	for {
		live := u64(intrinsics.ptr_sub(end, bs))
		b: kernel.Block
		if live >= 64 {
			b = kernel.load(bs)
		} else if live > 0 {
			// Zeros past `live` are ASCII to the UTF-8 state, and `k >= live` ends the string before a stop past the
			// end is read.
			b = kernel.load_padded(T, bs[:live], 0)
		} else {
			return nil, false
		}
		sv := kernel.either(kernel.either(kernel.eq(b, quote), kernel.eq(b, '\\')), kernel.below(b, 0x20))
		if !kernel.is_ascii(b) {
			kernel.utf8_block(T, b, &u)
			high, last_high = true, true
		} else if last_high {
			kernel.utf8_ascii_block(T, &u)
			last_high = false
		}
		// A block with no stop is skipped without packing its mask, unless an escape ran into it.
		if skip == 0 && !kernel.any_lane(sv) {
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
				if high && !kernel.utf8_clean(T, u) {
					return nil, false
				}
				return bs[k + 1:], esc
			}
			when .Es5 in FEATURES[S] {
				if c == '\n' || c == '\r' {
					return nil, false
				}
				n := u64(1)
				if c == '\\' {
					r, kind := escape5(bs[k:], end, {})
					if kind != .None {
						return nil, false
					}
					n = u64(intrinsics.ptr_sub(r, bs[k:]))
					esc = true
				}
			} else {
				if c != '\\' {
					return nil, false
				}
				n := escape_len(bs[k:], end)
				if n == 0 {
					return nil, false
				}
				esc = true
			}
			k += n
			if k >= 64 {
				skip = k - 64
				break
			}
			stop &= max(u64) << k
		}
		bs = bs[64:]
	}
}

// The length in bytes of the escape at the backslash `e` when the block reading accepts it: a one-letter escape, a
// `\u` escape outside the surrogates, or a high half followed by a low half. Returns 0 for anything else.
@(private)
escape_len :: #force_inline proc "contextless" (e, end: [^]u8) -> u64 #no_bounds_check {
	room := intrinsics.ptr_sub(end, e)
	if room < 2 {
		return 0
	}
	if core.ESC_WORD[e[1]] != 0 {
		return 2
	}
	if e[1] != 'u' || room < 6 {
		return 0
	}
	unit, ok := core.hex4(e[2:])
	if !ok {
		return 0
	}
	if core.low_surrogate(unit) {
		return 0
	}
	if !core.high_surrogate(unit) {
		return 6
	}
	if room < 12 || e[6] != '\\' || e[7] != 'u' {
		return 0
	}
	low, low_ok := core.hex4(e[8:])
	return 12 if low_ok && core.low_surrogate(low) else 0
}

// Reads the string whose opening quote is at `p` one byte at a time. Returns one past its closing quote, whether it
// holds an escape and whether `tol` accepted an ill-formed sequence, or the fault at the first byte that breaks it.
@(private, cold)
string_exact :: #force_no_inline proc "contextless" (p, end: [^]u8, tol: bit_set[Tolerance; u8]) -> (q: [^]u8, esc, lax: bool, kind: core.Fault_Kind) #no_bounds_check {
	q = p[1:]
	for {
		if q >= end {
			return end, false, false, .Truncated
		}
		c := q[0]
		switch {
		case c == '"':
			return q[1:], esc, lax, .None
		case c == '\\':
			esc = true
			if q, kind = escape_exact(q, end, tol); kind != .None {
				return q, false, false, kind
			}
		case c < 0x20:
			return q, false, false, .Bad_Char
		case c < 0x80:
			q = q[1:]
		case:
			if utf8_taken(q, end, tol) {
				lax = true
			}
			if q, kind = utf8_lax(q, end, tol); kind != .None {
				return q, false, false, kind
			}
		}
	}
}

// Steps over the escape at the backslash `e`. Returns one past it, or `Bad_Escape` at a bad letter or hex digit,
// `Bad_Escape` at the backslash for a lone surrogate half unless `tol` accepts it, or `Truncated` when the text ends
// first.
@(private)
escape_exact :: proc "contextless" (e, end: [^]u8, tol: bit_set[Tolerance; u8]) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	q = e[1:]
	if q >= end {
		return end, .Truncated
	}
	if core.ESC_WORD[q[0]] != 0 {
		return q[1:], .None
	}
	if q[0] != 'u' {
		return q, .Bad_Escape
	}
	q = q[1:]
	unit: u32
	for _ in 0 ..< 4 {
		if q >= end {
			return end, .Truncated
		}
		h := core.HEX_NIBBLE[q[0]]
		if h == 0xff {
			return q, .Bad_Escape
		}
		unit = unit << 4 | u32(h)
		q = q[1:]
	}
	if core.low_surrogate(unit) {
		if .Lone_Surrogate in tol {
			return q, .None
		}
		return e, .Bad_Escape
	}
	if core.high_surrogate(unit) {
		// Checks `\`, `u` and a low half's four digits in turn, each refused at its own byte, so a text cut inside them
		// gives `Truncated` where a wrong byte gives `Bad_Escape`.
		for i in 0 ..< 6 {
			if q[i:] >= end {
				return end, .Truncated
			}
			c := q[i]
			h := core.HEX_NIBBLE[c]
			ok: bool
			switch i {
			case 0:
				ok = c == '\\'
			case 1:
				ok = c == 'u'
			case 2:
				ok = h == 0xd
			case 3:
				ok = h >= 0xc && h <= 0xf
			case:
				ok = h != 0xff
			}
			if !ok {
				if .Lone_Surrogate in tol {
					return q, .None
				}
				return e, .Bad_Escape
			}
		}
		q = q[6:]
	}
	return q, .None
}

// Whether `.Invalid_Utf8` is in `tol` and `kernel.utf8_char` answers `Bad_Char` at `p`, so `utf8_lax` will step over
// the maximal subpart. A sequence the text cuts short is still `Truncated`, since the string it is in cannot close.
@(private)
utf8_taken :: #force_inline proc "contextless" (p, end: [^]u8, tol: bit_set[Tolerance; u8]) -> bool {
	if .Invalid_Utf8 not_in tol {
		return false
	}
	_, kind := kernel.utf8_char(p, end)
	return kind == .Bad_Char
}

utf8_lax :: #force_inline proc "contextless" (p, end: [^]u8, tol: bit_set[Tolerance; u8]) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	q, kind = kernel.utf8_char(p, end)
	if kind != .Bad_Char || .Invalid_Utf8 not_in tol {
		return
	}
	return kernel.utf8_subpart(p, end), .None
}

// 1 for the bytes that stop a run of plain string bytes: `"`, `\`, control bytes and bytes past 0x7F.
@(private, rodata)
STOP := [256]u8 {
	0 ..< 0x20 = 1,
	'"' = 1,
	'\\' = 1,
	0x80 ..= 0xff = 1,
}

