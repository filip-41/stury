package json

import "base:intrinsics"
import "core:simd"
import core "../core"
import kernel "../core/kernel"

// The leaves the states step over tokens with: one past the token, or the fault's kind and the byte it is at
// (`Truncated` at the end).

// The leaf found no fault.
@(private)
NO_FAULT :: core.Fault_Kind(0)

// Whether the token from `p` to `q` is longer than `Token.n` holds.
@(private)
too_wide :: #force_inline proc "contextless" (p, q: [^]u8) -> bool {
	return u64(intrinsics.ptr_sub(q, p)) > u64(max(u32))
}

// The lanes of `v` that stop a run of plain string bytes: a quote, a backslash, a control byte or a byte past 0x7F.
@(private)
string_stops :: #force_inline proc "contextless" (v: #simd[16]u8) -> #simd[16]u8 {
	V :: #simd[16]u8
	// `v - 0x20 > 0x5f` holds for a control byte and a byte past 0x7F.
	return simd.bit_or(simd.bit_or(simd.lanes_eq(v, V('"')), simd.lanes_eq(v, V('\\'))), simd.lanes_gt(v - 0x20, V(0x5f)))
}

@(private)
load16 :: #force_inline proc "contextless" (p: [^]u8) -> #simd[16]u8 {
	return intrinsics.unaligned_load((^#simd[16]u8)(p))
}

// The string whose opening quote is at `p` when it closes within 32 bytes and they hold only printable ASCII
// before the quote: one past its closing quote, else nil and whether a backslash stopped it.
@(private)
string_short :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, escaped: bool) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= 32 {
		return nil, false
	}
	k := kernel.first_lane(string_stops(load16(p[1:])))
	if k == 16 {
		k = 16 + kernel.first_lane(string_stops(load16(p[17:])))
		if k == 32 {
			return nil, false
		}
	}
	if p[1 + k] != '"' {
		return nil, p[1 + k] == '\\'
	}
	return p[2 + k:], false
}

// The longest key `string_probe` reads.
@(private)
PROBE_MAX :: 32

// `string_short` read byte by byte up to PROBE_MAX bytes: each byte a branch on a table, so the closing quote of a
// key whose length repeats lands on a predicted branch and the next token's address does not wait on the bytes.
@(private)
string_probe :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, escaped: bool) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) <= PROBE_MAX {
		return nil, false
	}
	#unroll for k in 1 ..= PROBE_MAX {
		// The stop is the rare branch, so each byte that goes on falls through rather than jumps.
		if intrinsics.expect(STOP[p[k]] != 0, false) {
			if p[k] == '"' {
				return p[k + 1:], false
			}
			return nil, p[k] == '\\'
		}
	}
	return nil, false
}

// `string_stops` over a 64-byte block, so a block needs no separate test for the bytes past 0x7F or below 0x20:
// both are stops, and the reader that cannot take them answers nil for `string_long` to settle.
@(private)
string_stops_block :: #force_inline proc "contextless" (b: kernel.Block) -> kernel.Block {
	return {string_stops(b[0]), string_stops(b[1]), string_stops(b[2]), string_stops(b[3])}
}

// The string at `p` while it is plain ASCII, 64 bytes a step with no UTF-8 state, within 64 bytes of the text's end:
// one past its closing quote. Else nil, and `escape` the block whose first stop is a backslash, which
// `string_escaped` reads on from, or nil when the string is not this reader's.
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
		return nil, bs if bs[k] == '\\' else nil
	}
	return nil, nil
}

// The string read on from the block `bs`, which no escape runs into, while it is ASCII and its escapes are ones
// `escape_len` takes, each within one block: one past its closing quote, else nil. A block is judged in masks, with
// no branch per escape: the escaped lanes, their letters, a `\u` escape's four digits, and the first quote no escape
// covers.
@(private)
string_escaped :: #force_inline proc "contextless" (bs, end: [^]u8) -> [^]u8 #no_bounds_check {
	bs := bs
	// 1 when an odd run of backslashes ends the block before, escaping the first byte of this one.
	odd: u64
	for intrinsics.ptr_sub(end, bs) >= 64 {
		b := kernel.load(bs)
		sv := string_stops_block(b)
		if odd == 0 && !kernel.any_lane(sv) {
			bs = bs[64:]
			continue
		}
		// A stop the mask paths below do not read: a byte past 0x7F, which `string_long` validates.
		if !kernel.is_ascii(b) {
			return nil
		}
		m := kernel.pack_n([3]kernel.Block{kernel.eq(b, '"'), kernel.eq(b, '\\'), kernel.below(b, 0x20)})
		quote, slash, ctl := m[0], m[1], m[2]
		// A block with at most one backslash and no escape running into it, the common case of sparse escapes,
		// reads that escape in scalar and skips the class masks.
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
		// A surrogate half's `\u` has `d` then a digit of 8 to B (high) or C to F (low): a high half's `\u` sits six
		// lanes before a low half's.
		half := u & (d >> 1)
		high, low: u64
		if half != 0 {
			c2 := kernel.classes(STATE_TIER, b, SURROGATE_CLASSES)
			h2 := kernel.pack_n([2]kernel.Block{kernel.has(c2, SUR_HIGH), kernel.has(c2, SUR_LOW)})
			high, low = half & (h2[0] >> 2), half & (h2[1] >> 2)
		}
		// A `\u` escape whose digits leave the block is the block reader's.
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

// The classes `string_escaped` reads an escape by: the one-letter escapes, `u`, the hex digits, and `d` or `D`.
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

// The second digit of a surrogate half's `\u`: 8 to B for a high half, C to F for a low one.
@(private, rodata)
SURROGATE_CLASSES := kernel.Nibble_Table {
	lo = {0x00, 0x02, 0x02, 0x04, 0x04, 0x04, 0x04, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
	hi = {0x00, 0x00, 0x00, 0x01, 0x06, 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},
}

// The string at `p`: one past its closing quote and whether it holds an escape, or the fault. The block reader of
// this CPU's tier first, then `string_exact` for a string it does not vouch for.
@(private)
string_long :: #force_inline proc "contextless" (tier: kernel.Tier, p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) {
	when ODIN_ARCH == .amd64 {
		switch tier {
		case .V4:
			q, esc = string_span_v4(p, end)
		case .V3:
			q, esc = string_span_v3(p, end)
		case .V2:
			q, esc = string_span_v2(p, end)
		}
	} else {
		q, esc = string_span_base(p, end)
	}
	if q == nil {
		return string_exact(p, end)
	}
	return q, esc, NO_FAULT
}

// `string_span` per tier, each out of line with its tier's features, since the states are built once for the floor.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	string_span_v2 :: #force_no_inline proc "contextless" (p, end: [^]u8) -> ([^]u8, bool) {
		return string_span(.V2, p, end)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	string_span_v3 :: #force_no_inline proc "contextless" (p, end: [^]u8) -> ([^]u8, bool) {
		return string_span(.V3, p, end)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	string_span_v4 :: #force_no_inline proc "contextless" (p, end: [^]u8) -> ([^]u8, bool) {
		return string_span(.V4, p, end)
	}
} else {
	@(private)
	string_span_base :: #force_no_inline proc "contextless" (p, end: [^]u8) -> ([^]u8, bool) {
		return string_span(.Base, p, end)
	}
}

// The string whose opening quote is at `p`: one past its closing quote and whether it holds an escape, or nil when
// the block reading cannot vouch for it (a control byte, an escape it does not take, invalid UTF-8 anywhere in a
// block it loaded, or the end of the text), which `string_exact` then settles. Blocks are loaded 64 bytes on from
// `p + 1`, so they are contiguous and UTF-8 state carries from one to the next. An escape is stepped over inside the
// block's stop mask, so escape-dense text loads each block once.
@(private)
string_span :: #force_inline proc "contextless" ($T: kernel.Tier, p, end: [^]u8) -> (q: [^]u8, esc: bool) #no_bounds_check {
	bs := p[1:]
	skip: u64
	u: kernel.Utf8_State
	// Whether a block had a byte past 0x7F, and whether the last one did: an ASCII block after one closes it.
	high, last_high: bool
	for {
		live := u64(intrinsics.ptr_sub(end, bs))
		b: kernel.Block
		if live >= 64 {
			b = kernel.load(bs)
		} else if live > 0 {
			// Zeros past the end are ASCII to UTF-8, and a stop at `live` at the latest, which ends the string.
			b = kernel.load_padded(T, bs[:live], 0)
		} else {
			return nil, false
		}
		sv := kernel.either(kernel.either(kernel.eq(b, '"'), kernel.eq(b, '\\')), kernel.below(b, 0x20))
		if !kernel.is_ascii(b) {
			kernel.utf8_block(T, b, &u)
			high, last_high = true, true
		} else if last_high {
			kernel.utf8_ascii_block(T, &u)
			last_high = false
		}
		// A block with no stop is passed without packing its mask, unless an escape ran into it.
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
			if c == '"' {
				if high && !kernel.utf8_clean(T, u) {
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
		bs = bs[64:]
	}
}

// The length of the escape at the backslash `e` when it is one the block reading takes: a one-letter escape, a
// `\u` escape outside the surrogates, or a high half followed by a low half. 0 for anything else.
@(private)
escape_len :: #force_inline proc "contextless" (e, end: [^]u8) -> u64 #no_bounds_check {
	room := intrinsics.ptr_sub(end, e)
	if room < 2 {
		return 0
	}
	if ESC_BYTE[e[1]] != 0 {
		return 2
	}
	if e[1] != 'u' || room < 6 {
		return 0
	}
	unit, ok := hex4(e[2:])
	if !ok {
		return 0
	}
	if unit - 0xd800 >= 0x800 {
		return 6
	}
	if unit >= 0xdc00 || room < 12 || e[6] != '\\' || e[7] != 'u' {
		return 0
	}
	low, low_ok := hex4(e[8:])
	return 12 if low_ok && low - 0xdc00 < 0x400 else 0
}

@(private)
hex4 :: #force_inline proc "contextless" (h: [^]u8) -> (unit: u32, ok: bool) #no_bounds_check {
	a, b, c, d := HEX[h[0]], HEX[h[1]], HEX[h[2]], HEX[h[3]]
	return u32(a) << 12 | u32(b) << 8 | u32(c) << 4 | u32(d), (a | b | c | d) & 0xf0 == 0
}

// The string whose opening quote is at `p`, read byte by byte: one past its closing quote and whether it holds an
// escape, or the fault at the first byte that breaks it.
@(private, cold)
string_exact :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
	q = p[1:]
	for {
		if q >= end {
			return end, false, .Truncated
		}
		c := q[0]
		switch {
		case c == '"':
			return q[1:], esc, NO_FAULT
		case c == '\\':
			esc = true
			if q, kind = escape_exact(q, end); kind != NO_FAULT {
				return q, false, kind
			}
		case c < 0x20:
			return q, false, .Bad_Char
		case c < 0x80:
			q = q[1:]
		case:
			if q, kind = utf8_char(q, end); kind != NO_FAULT {
				return q, false, kind
			}
		}
	}
}

// The escape at the backslash `e`, stepped over. A bad letter or hex digit is `Bad_Escape` at that byte, a lone
// surrogate half `Bad_Escape` at its backslash, and input that ends first `Truncated`.
@(private)
escape_exact :: proc "contextless" (e, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	q = e[1:]
	if q >= end {
		return end, .Truncated
	}
	if ESC_BYTE[q[0]] != 0 {
		return q[1:], NO_FAULT
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
		h := HEX[q[0]]
		if h == 0xff {
			return q, .Bad_Escape
		}
		unit = unit << 4 | u32(h)
		q = q[1:]
	}
	if unit - 0xd800 < 0x800 {
		if unit >= 0xdc00 {
			return e, .Bad_Escape
		}
		// `\`, `u`, then a low half's four digits, each refused where it stands, so a text cut inside them is told
		// apart from one that breaks them.
		for i in 0 ..< 6 {
			if q[i:] >= end {
				return end, .Truncated
			}
			c := q[i]
			h := HEX[c]
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
				return e, .Bad_Escape
			}
		}
		q = q[6:]
	}
	return q, NO_FAULT
}

// The UTF-8 character whose lead is at `p` (at least 0x80), stepped over. A malformed one is `Bad_Char` at its
// lead. One the text cuts short is `Truncated` while every byte present could still continue it, else `Bad_Char`.
@(private)
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
	return p[need:], NO_FAULT
}

// The byte a one-letter escape writes, or 0 for a letter that is not one.
@(private, rodata)
ESC_BYTE := [256]u8 {
	'"'  = '"',
	'\\' = '\\',
	'/'  = '/',
	'b'  = 0x08,
	'f'  = 0x0c,
	'n'  = '\n',
	'r'  = '\r',
	't'  = '\t',
}

// 1 for the bytes that stop a run of plain string bytes: the quote, the backslash, control bytes and bytes past 0x7F.
@(private, rodata)
STOP := [256]u8 {
	0 ..< 0x20 = 1,
	'"' = 1,
	'\\' = 1,
	0x80 ..= 0xff = 1,
}

// The value of a hex digit, or 0xFF for a byte that is not one.
@(private, rodata)
HEX := [256]u8 {
	0 ..< '0' = 0xff,
	'0' = 0, '1' = 1, '2' = 2, '3' = 3, '4' = 4, '5' = 5, '6' = 6, '7' = 7, '8' = 8, '9' = 9,
	':' ..< 'A' = 0xff,
	'A' = 10, 'B' = 11, 'C' = 12, 'D' = 13, 'E' = 14, 'F' = 15,
	'G' ..< 'a' = 0xff,
	'a' = 10, 'b' = 11, 'c' = 12, 'd' = 13, 'e' = 14, 'f' = 15,
	'g' ..= 0xff = 0xff,
}
