package xml

import "base:intrinsics"
import spell "../core/spell"

// XML 1.0 Fifth Edition names. A byte below 0x80 is classed by `NAME_BYTE`, and a character past it by the ranges of
// `name_start_rune` and `name_rune`.

@(private)
Name_Byte :: enum u8 {
	No   = 0, // no byte of a name
	Start = 1, // starts a name and continues it
	Rest = 2, // continues a name only: a digit, `-` or `.`
	Colon = 4, // starts a name and continues it, and separates a prefix from a local name
	High = 8, // a UTF-8 lead byte, whose character `name_rune` judges
}

// The classes of an ASCII byte that belong to a name, as bits: `Start`, `Rest` and `Colon`.
@(private)
NAME_ASCII :: 7

@(private, rodata)
NAME_BYTE := [256]Name_Byte {
	':'         = .Colon,
	'_'         = .Start,
	'A' ..= 'Z' = .Start,
	'a' ..= 'z' = .Start,
	'-'         = .Rest,
	'.'         = .Rest,
	'0' ..= '9' = .Rest,
	0xc2 ..= 0xf4 = .High,
}

// The fault `name_end` returns: none, the text's end, a byte that is no name character, or a character that is
// ill-formed UTF-8.
@(private)
Name_Fault :: enum u8 {
	None,
	Truncated,
	Not_Name,
	Bad_Utf8,
}

// Reads the name at `p` and returns one past its last character. When `p` starts no name, `fault` is `.Not_Name`
// and `q` is `p`. An ill-formed UTF-8 sequence faults `.Bad_Utf8` at `q`, and a name that runs to the text's end
// is `.None`: the caller judges what the end means.
@(private)
name_end :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, fault: Name_Fault) {
	q, fault, _ = name_end_colon(p, end)
	return
}

// `name_end`, and whether the name holds a colon, so a start tag learns that it has a prefix to resolve in the pass that
// reads the name.
@(private)
name_end_colon :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, fault: Name_Fault, colon: bool) #no_bounds_check {
	q = p
	if q >= end {
		return q, .Truncated, false
	}
	first := NAME_BYTE[q[0]]
	if first == .Start || first == .Colon {
		q = q[1:]
		colon = first == .Colon
	} else if first == .High {
		q, fault = name_end_high(p, p, end)
		return q, fault, has_colon(p, intrinsics.ptr_sub(q, p))
	} else {
		return q, .Not_Name, false
	}
	seen: u8
	for q < end {
		c := u8(NAME_BYTE[q[0]])
		if c & NAME_ASCII != 0 {
			seen |= c
			q = q[1:]
			continue
		}
		if c == u8(Name_Byte.High) {
			q, fault = name_end_high(p, q, end)
			return q, fault, colon || seen & u8(Name_Byte.Colon) != 0 || has_colon(p, intrinsics.ptr_sub(q, p))
		}
		break
	}
	return q, .None, colon || seen & u8(Name_Byte.Colon) != 0
}

// `name_end` from the character at `q` on, where `q` holds a UTF-8 lead byte, for a name that began at `p`.
@(private, cold)
name_end_high :: #force_no_inline proc "contextless" (p, q, end: [^]u8) -> ([^]u8, Name_Fault) #no_bounds_check {
	q := q
	for q < end {
		c := q[0]
		if u8(NAME_BYTE[c]) & NAME_ASCII != 0 {
			q = q[1:]
			continue
		}
		if NAME_BYTE[c] != .High {
			break
		}
		r, kind := spell.utf8_char(q, end)
		if kind == .Truncated {
			return end, .Truncated
		}
		if kind != .None {
			return q, .Bad_Utf8
		}
		cp := rune_at(q, r)
		if !(name_start_rune(cp) if q == p else name_rune(cp)) {
			return q, .Not_Name if q == p else .None
		}
		q = r
	}
	return q, .None
}

// The code point of the UTF-8 character from `q` to `r`, which `spell.utf8_char` has judged well formed.
@(private)
rune_at :: #force_inline proc "contextless" (q, r: [^]u8) -> u32 #no_bounds_check {
	switch uintptr(r) - uintptr(q) {
	case 2:
		return u32(q[0] & 0x1f) << 6 | u32(q[1] & 0x3f)
	case 3:
		return u32(q[0] & 0x0f) << 12 | u32(q[1] & 0x3f) << 6 | u32(q[2] & 0x3f)
	}
	return u32(q[0] & 0x07) << 18 | u32(q[1] & 0x3f) << 12 | u32(q[2] & 0x3f) << 6 | u32(q[3] & 0x3f)
}

@(private)
name_start_rune :: proc "contextless" (c: u32) -> bool {
	switch {
	case c < 0xc0:
		return false
	case c <= 0xd6, 0xd8 <= c && c <= 0xf6, 0xf8 <= c && c <= 0x2ff, 0x370 <= c && c <= 0x37d, 0x37f <= c && c <= 0x1fff:
		return true
	case 0x200c <= c && c <= 0x200d, 0x2070 <= c && c <= 0x218f, 0x2c00 <= c && c <= 0x2fef, 0x3001 <= c && c <= 0xd7ff:
		return true
	case 0xf900 <= c && c <= 0xfdcf, 0xfdf0 <= c && c <= 0xfffd, 0x10000 <= c && c <= 0xeffff:
		return true
	}
	return false
}

@(private)
name_rune :: proc "contextless" (c: u32) -> bool {
	return name_start_rune(c) || c == 0xb7 || 0x300 <= c && c <= 0x36f || 0x203f <= c && c <= 0x2040
}
