package spell

import "base:intrinsics"

when ODIN_ENDIAN != .Little {
	#panic("spell: the digit readers require a little-endian target")
}

// One past the UTF-8 character whose lead is at `p`, where `p < end` and `p[0] >= 0x80`, or `p` with `.Bad_Char` for a
// malformed sequence. A sequence the text cuts short gives `end` with `.Truncated` when every byte present could still
// continue it.
utf8_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: Fault_Kind) #no_bounds_check {
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

// One past the maximal subpart of the ill-formed UTF-8 sequence at `p`, where `p < end`: its longest start that some
// well-formed sequence starts with, or its first byte when none does. A decoder that replaces each such subpart with
// U+FFFD reads ill-formed text as Unicode's "substitution of maximal subparts" does.
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

// The UTF-8 of U+FFFD, the replacement character.
REPLACEMENT :: [3]u8{0xEF, 0xBF, 0xBD}

// Copies the UTF-8 character whose lead `p[0]` is past ASCII to `out`, or writes U+FFFD there for the maximal subpart
// of an ill-formed sequence, and returns the bytes written, at most 4, and one past the bytes read. `p < end`.
utf8_lax :: #force_inline proc "contextless" (p, end, out: [^]u8) -> (n: int, q: [^]u8) #no_bounds_check {
	kind: Fault_Kind
	if q, kind = utf8_char(p, end); kind != .None {
		out[0], out[1], out[2] = REPLACEMENT[0], REPLACEMENT[1], REPLACEMENT[2]
		return 3, utf8_subpart(p, end)
	}
	n = intrinsics.ptr_sub(q, p)
	for i in 0 ..< n {
		out[i] = p[i]
	}
	return
}

// The length of the UTF-8 byte order mark that starts `src`, 0 for none.
bom_length :: #force_inline proc "contextless" (src: []u8) -> int {
	return 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
}

// The end of the run of decimal digits at `p`.
digit_end :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for intrinsics.ptr_sub(end, q) >= 8 {
		w := u64(intrinsics.unaligned_load((^u64le)(q)))
		// The first byte below '0' or above '9' sets its high bit in one of the two.
		m := ((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
		if m != 0 {
			return q[intrinsics.count_trailing_zeros(m) >> 3:]
		}
		q = q[8:]
	}
	for q < end && q[0] - '0' < 10 {
		q = q[1:]
	}
	return q
}

// The end of the run of hex digits at `p`.
hex_digit_end :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for q < end && HEX_NIBBLE[q[0]] != 0xff {
		q = q[1:]
	}
	return q
}

// Whether byte `b` continues a UTF-8 character, which a character's lead byte does not.
is_continuation :: #force_inline proc "contextless" (b: byte) -> bool {
	return b & 0xC0 == 0x80
}

// The bytes a walk by character steps over from the byte `b` to the next place it tries: the width a lead byte gives.
// A continuation byte, where a search can start inside a character, and a byte no UTF-8 sequence starts with, give 1.
lead_width :: #force_inline proc "contextless" (b: byte) -> int {
	switch {
	case b < 0xC0:
		return 1
	case b < 0xE0:
		return 2
	case b < 0xF0:
		return 3
	case b < 0xF8:
		return 4
	}
	return 1
}

// The index of the first byte of the character that holds byte `i` of `s`, or 0 when none starts at or before it.
char_start :: #force_inline proc "contextless" (s: string, i: int) -> int {
	i := i
	for i > 0 && is_continuation(s[i]) {
		i -= 1
	}
	return i
}

// The index of the first byte at or after `i` that is not a continuation byte, or `len(s)`.
skip_continuations :: #force_inline proc "contextless" (s: string, i: int) -> int {
	i := i
	for i < len(s) && is_continuation(s[i]) {
		i += 1
	}
	return i
}
