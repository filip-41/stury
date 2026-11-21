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
