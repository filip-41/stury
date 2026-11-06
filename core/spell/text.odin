package spell

import "base:intrinsics"

// The byte helpers the readers and decoders share: a decode into a caller's buffer, and a byte-for-byte compare.

// Decodes a node's bytes into `buf`: `d` is the decoder's initial state and `next` returns one byte at a time. It
// returns false as soon as `buf` is full while the decoder has more, and `buf`'s content is then unspecified.
decode_text :: proc(buf: []u8, d: $D, $next: proc "contextless" (^D) -> (u8, bool)) -> (s: string, ok: bool) {
	c := d
	w := 0
	for {
		b, more := next(&c)
		if !more {
			return string(buf[:w]), true
		}
		if w == len(buf) {
			return "", false
		}
		buf[w] = b
		w += 1
	}
}

// Returns whether the bytes `next` returns from `d` are `name`, with no allocation.
decoded_equals :: proc "contextless" (d: $D, $next: proc "contextless" (^D) -> (u8, bool), name: string) -> bool {
	d := d
	at := 0
	for {
		b, more := next(&d)
		if !more {
			return at == len(name)
		}
		if at >= len(name) || name[at] != b {
			return false
		}
		at += 1
	}
}

// The bytes of a decoded character that a decoder has returned the first of. `n` of them remain from `at`.
Pending :: struct {
	buf: [4]u8,
	n:   u8,
	at:  u8,
}

// Returns the next byte of the character `pending_give` left, or false when none remain.
pending_next :: #force_inline proc "contextless" (p: ^Pending) -> (b: u8, ok: bool) {
	if p.n == 0 {
		return 0, false
	}
	b = p.buf[p.at]
	p.at += 1
	p.n -= 1
	return b, true
}

// Leaves the `size` bytes of `spelled` in `p` and returns the first, which the decoder returns now.
pending_give :: #force_inline proc "contextless" (p: ^Pending, spelled: [4]u8, size: int) -> u8 {
	p.buf = spelled
	p.n = u8(size - 1)
	p.at = 1
	return spelled[0]
}

// Returns the four hex digits at `h` as a 16-bit value, and whether all four are hex digits. The caller must ensure
// four bytes are readable at `h`.
hex4 :: #force_inline proc "contextless" (h: [^]u8) -> (unit: u32, ok: bool) {
	#no_bounds_check {
		a := HEX_NIBBLE[h[0]]
		b := HEX_NIBBLE[h[1]]
		c := HEX_NIBBLE[h[2]]
		d := HEX_NIBBLE[h[3]]
		return u32(a) << 12 | u32(b) << 8 | u32(c) << 4 | u32(d), (a | b | c | d) & 0xf0 == 0
	}
}

// Decodes the `\u` escape whose backslash is at `e`, with `room` bytes from `e` to the end: a code unit outside the
// surrogates, or a high half and the low half's `\u` right after it. Returns its rune and its length, 6 or 12, and a
// length of 0 for a short escape, a bad hex digit or a lone half. The caller has read `\u` at `e`.
unicode_escape :: #force_inline proc "contextless" (e: [^]u8, room: int) -> (r: rune, n: int) #no_bounds_check {
	if room < 6 {
		return 0, 0
	}
	unit, ok := hex4(e[2:])
	if !ok || low_surrogate(unit) {
		return 0, 0
	}
	if !high_surrogate(unit) {
		return rune(unit), 6
	}
	if room < 12 || e[6] != '\\' || e[7] != 'u' {
		return 0, 0
	}
	low, low_ok := hex4(e[8:])
	if !low_ok || !low_surrogate(low) {
		return 0, 0
	}
	return 0x10000 + rune(unit - 0xD800) << 10 + rune(low - 0xDC00), 12
}

// Reports whether `unit` is a UTF-16 high surrogate, 0xD800 to 0xDBFF.
high_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xD800 < 0x400
}

// Reports whether `unit` is a UTF-16 low surrogate, 0xDC00 to 0xDFFF.
low_surrogate :: #force_inline proc "contextless" (unit: u32) -> bool {
	return unit - 0xDC00 < 0x400
}

// Whether byte strings `a` and `b` are equal. A length test comes first, then below 8 bytes a byte at a time, at
// most 16 bytes two overlapping 8-byte loads that stay inside both strings, and past that 8-byte words then the
// tail.
bytes_equal :: #force_inline proc "contextless" (a, b: []u8) -> bool {
	if len(a) != len(b) {
		return false
	}
	n := len(a)
	#no_bounds_check {
		if n < 8 {
			for i in 0 ..< n {
				if a[i] != b[i] {
					return false
				}
			}
			return true
		}
		if n <= 16 {
			return intrinsics.unaligned_load((^u64)(raw_data(a))) == intrinsics.unaligned_load((^u64)(raw_data(b))) &&
				intrinsics.unaligned_load((^u64)(raw_data(a)[n - 8:])) == intrinsics.unaligned_load((^u64)(raw_data(b)[n - 8:]))
		}
		i := 0
		for i + 8 <= n {
			if intrinsics.unaligned_load((^u64)(raw_data(a)[i:])) != intrinsics.unaligned_load((^u64)(raw_data(b)[i:])) {
				return false
			}
			i += 8
		}
		for i < n {
			if a[i] != b[i] {
				return false
			}
			i += 1
		}
		return true
	}
}
