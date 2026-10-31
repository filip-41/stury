package json

import spell "../core/spell"

// Tables the JSON walk and its value layer share: the byte a one-letter escape produces, and a hex digit's value. The
// walk reads them to measure and check an escape, and the value layer reads them while decoding a string's text.

// The bytes a one-letter escape decodes to, packed little-endian in the low 24 bits, and the byte count 1 in bits 24
// to 31. 0 for `u` and for every byte that is not a one-letter escape.
@(private, rodata)
ESC_WORD: [256]u32 = {
	'"'  = 0x0100_0022,
	'\\' = 0x0100_005C,
	'/'  = 0x0100_002F,
	'b'  = 0x0100_0008,
	'f'  = 0x0100_000C,
	'n'  = 0x0100_000A,
	'r'  = 0x0100_000D,
	't'  = 0x0100_0009,
}

// Returns the four hex digits at `h` as a 16-bit value, and whether all four are hex digits. The caller must ensure
// four bytes are readable at `h`.
@(private)
hex4 :: #force_inline proc "contextless" (h: [^]u8) -> (unit: u32, ok: bool) {
	#no_bounds_check {
		a := spell.HEX_NIBBLE[h[0]]
		b := spell.HEX_NIBBLE[h[1]]
		c := spell.HEX_NIBBLE[h[2]]
		d := spell.HEX_NIBBLE[h[3]]
		return u32(a) << 12 | u32(b) << 8 | u32(c) << 4 | u32(d), (a | b | c | d) & 0xf0 == 0
	}
}

// Reports whether `unit` is a UTF-16 high surrogate, 0xD800 to 0xDBFF.
@(private)
high_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xD800 < 0x400
}

// Reports whether `unit` is a UTF-16 low surrogate, 0xDC00 to 0xDFFF.
@(private)
low_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xDC00 < 0x400
}
