package spell

import "base:intrinsics"

// The byte each of JSON's one-letter escapes decodes to, by the letter after the backslash. 0 for `u` and any other
// byte.
@(rodata)
ESCAPED: [256]u8 = {
	'"'  = '"',
	'\\' = '\\',
	'/'  = '/',
	'b'  = '\b',
	'f'  = '\f',
	'n'  = '\n',
	'r'  = '\r',
	't'  = '\t',
}

// A hex digit's value, or 0xFF for any other byte.
@(rodata)
HEX_NIBBLE: [256]u8 = {
	0 ..< '0' = 0xFF, ':' ..< 'A' = 0xFF, 'G' ..< 'a' = 0xFF, 'g' ..= 0xFF = 0xFF,
	'0' = 0, '1' = 1, '2' = 2, '3' = 3, '4' = 4, '5' = 5, '6' = 6, '7' = 7, '8' = 8, '9' = 9,
	'A' = 10, 'B' = 11, 'C' = 12, 'D' = 13, 'E' = 14, 'F' = 15,
	'a' = 10, 'b' = 11, 'c' = 12, 'd' = 13, 'e' = 14, 'f' = 15,
}

// The four hex digits at `h` as a 16-bit value, and whether all four are hex digits. Four bytes must be readable;
// `unit` is unspecified when `ok` is false.
@(require_results)
hex4 :: #force_inline proc "contextless" (h: [^]u8) -> (unit: u32, ok: bool) #no_bounds_check {
	a := HEX_NIBBLE[h[0]]
	b := HEX_NIBBLE[h[1]]
	c := HEX_NIBBLE[h[2]]
	d := HEX_NIBBLE[h[3]]
	return u32(a) << 12 | u32(b) << 8 | u32(c) << 4 | u32(d), (a | b | c | d) & 0xf0 == 0
}

// The value of the four hex digits at `h`, which must all be hex digits. Four bytes must be readable.
@(require_results)
hex4_value :: #force_inline proc "contextless" (h: [^]u8) -> u32 {
	w := u32(intrinsics.unaligned_load((^u32be)(h)))
	v := (w & 0x0F0F_0F0F) + ((w >> 6) & 0x0101_0101) * 9
	p := (v | (v >> 4)) & 0x00FF_00FF
	return ((p >> 8) | p) & 0xFFFF
}

// The number of UTF-8 bytes the code point `r` (`0 <= r <= 0x10FFFF`) encodes to.
@(require_results)
rune_len :: #force_inline proc "contextless" (r: rune) -> u32 {
	if r < 0x80 {
		return 1
	}
	if r < 0x800 {
		return 2
	}
	if r < 0x10000 {
		return 3
	}
	return 4
}

// The code point and length of the escape whose backslash is at `e`, `room` bytes before the end. The length is 0 for
// a bad escape.
@(require_results)
string_escape :: #force_inline proc "contextless" (e: [^]u8, room: int) -> (r: rune, n: int) #no_bounds_check {
	if room < 2 {
		return 0, 0
	}
	if b := ESCAPED[e[1]]; b != 0 {
		return rune(b), 2
	}
	if e[1] != 'u' {
		return 0, 0
	}
	return unicode_escape(e, room)
}

// The code point and length of the `\u` escape at `e`, `room` bytes before the end, a surrogate pair read as one.
// The caller has checked `e[0:2] == "\\u"`. The length is 6 or 12, and 0 for a short escape, a bad hex digit or a
// lone half.
@(private = "file", require_results)
unicode_escape :: #force_inline proc "contextless" (e: [^]u8, room: int) -> (r: rune, n: int) #no_bounds_check {
	if room < 6 {
		return 0, 0
	}
	unit, ok := hex4(e[2:])
	if !ok {
		return 0, 0
	}
	// A single range test covers both halves, so a code unit outside them needs one branch.
	if unit - 0xD800 >= 0x800 {
		return rune(unit), 6
	}
	if unit >= 0xDC00 || room < 12 || e[6] != '\\' || e[7] != 'u' {
		return 0, 0
	}
	low, low_ok := hex4(e[8:])
	if !low_ok || !low_surrogate(low) {
		return 0, 0
	}
	return surrogate_pair(unit, low), 12
}

// The code point the UTF-16 surrogate halves `high` and `low` stand for.
@(require_results)
surrogate_pair :: #force_inline proc "contextless" (high, low: u32) -> rune {
	return 0x10000 + rune(high - 0xD800) << 10 + rune(low - 0xDC00)
}

// Whether `unit` is a UTF-16 high surrogate, 0xD800 to 0xDBFF.
@(require_results)
high_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xD800 < 0x400
}

// Whether `unit` is a UTF-16 low surrogate, 0xDC00 to 0xDFFF.
@(require_results)
low_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xDC00 < 0x400
}
