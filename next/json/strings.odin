package json

import "base:intrinsics"
import core "../core"

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

// The string whose opening quote is at `p`, read byte by byte: one past its closing quote and whether it holds an
// escape, or the fault at the first byte that breaks it.
@(private)
string_exact :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, esc: bool, kind: core.Fault_Kind) #no_bounds_check {
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
