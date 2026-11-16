package spell

// JSON's backslash escapes, which JSON's walk and decoder, core's path text and the jq lexer all read.

// The byte each of JSON's one-letter escapes decodes to, indexed by the letter after the backslash. 0 for `u` and for
// every byte that is no one-letter escape.
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

// Decodes the escape whose backslash is at `e`, with `room` bytes from `e` to the end: a one-letter escape, or a `\u`
// escape as `unicode_escape` reads it. Returns its rune and its length, and a length of 0 for a bad escape.
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

// Decodes the `\u` escape whose backslash is at `e`, with `room` bytes from `e` to the end: a code unit outside the
// surrogates, or a high half and the low half's `\u` right after it. Returns its rune and its length, 6 or 12, and a
// length of 0 for a short escape, a bad hex digit or a lone half. The caller has read `\u` at `e`.
unicode_escape :: #force_inline proc "contextless" (e: [^]u8, room: int) -> (r: rune, n: int) #no_bounds_check {
	if room < 6 {
		return 0, 0
	}
	unit, ok := hex4(e[2:])
	if !ok {
		return 0, 0
	}
	// One range test covers both halves, so a code unit outside them takes one branch.
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
surrogate_pair :: #force_inline proc "contextless" (high, low: u32) -> rune {
	return 0x10000 + rune(high - 0xD800) << 10 + rune(low - 0xDC00)
}

// Whether `unit` is a UTF-16 high surrogate, 0xD800 to 0xDBFF.
high_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xD800 < 0x400
}

// Whether `unit` is a UTF-16 low surrogate, 0xDC00 to 0xDFFF.
low_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xDC00 < 0x400
}
