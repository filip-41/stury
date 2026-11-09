package spell

import "base:intrinsics"

// The byte helpers the readers and decoders share: a decode into a caller's buffer, a byte-for-byte compare, and
// stepping over a UTF-8 character.

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

// Decodes the JSON escape whose backslash is at `e`, with `room` bytes from `e` to the end: a one-letter escape, or a
// `\u` escape as `unicode_escape` reads it. Returns its rune and its length, and a length of 0 for a bad escape.
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

// The kinds of fault a walk raises, shared by every format. Each member's comment names the formats that raise it
// and the byte `at` names.
Fault_Kind :: enum u8 {
	None, // no fault
	Truncated, // json, dsv: the input ended inside a construct, at `len(src)`, or dsv's quoted cell never closed, at its opening quote
	Bad_Char, // json, dsv: the first byte that cannot extend the construct or the text, or that is not UTF-8
	Bad_Escape, // json: at the escape's letter or its first bad digit, at the backslash for a lone surrogate half or a JSON5 identifier escape of no identifier character, dsv (TSV): at the backslash
	Bad_Number, // json: at the byte that breaks the number
	Too_Deep, // json: at the bracket past the depth limit
	Too_Wide, // json, dsv: the first byte of a token longer than `Token.n` holds, records: of a record past `max_bytes`
	No_Memory, // json (depth stack past `MAX_DEPTH`), dsv (header's keys, a reader's batch), records (window, pieces): a scratch allocation failed, no byte
	Bad_Option, // json, dsv, records: a spec, option or framing the format does not take, or a handle with no format, found before any byte is read
	Bad_Width, // dsv: a record wider than the first, at the delimiter that starts its extra cell, or narrower, at its line end
	Duplicate_Key, // json, dsv: a build, a read or a scan under `.Refuse` met a key that repeats one of its object's, at the second key's first byte. No walk raises it: the library makes it from the refusal
}

// Steps over the UTF-8 character whose lead is at `p`, where `p < end` and `*p >= 0x80`. Returns one past the
// character with `.None`, or `p` with `.Bad_Char` for a malformed sequence. A sequence the text cuts short returns
// `end` with `.Truncated` when every byte present could still continue it, else `p` with `.Bad_Char`.
utf8_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: Fault_Kind) {
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

// Returns the end of the maximal subpart of an ill-formed sequence at `p`: the longest prefix that could still start
// a well-formed sequence, at least one byte. The caller has already received `.Bad_Char` from `utf8_char`.
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

// U+FFFD in UTF-8, the character a tolerated ill-formed sequence or lone surrogate half reads as.
REPLACEMENT :: [4]u8{0xEF, 0xBF, 0xBD, 0}

// Reads the character whose lead is at `p`, where `p < end` and `*p >= 0x80`, as a decoder that tolerates ill-formed
// UTF-8 reads it. Returns its bytes, their count and one past it, or U+FFFD over the maximal subpart of a sequence that
// is ill-formed or that `end` cuts short.
utf8_lax_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (spelled: [4]u8, size: int, q: [^]u8) {
	kind: Fault_Kind
	q, kind = utf8_char(p, end)
	if kind != .None {
		return REPLACEMENT, 3, utf8_subpart(p, end)
	}
	size = int(uintptr(q) - uintptr(p))
	#unroll for i in 0 ..< 4 {
		if i < size {
			spelled[i] = p[i]
		}
	}
	return spelled, size, q
}
