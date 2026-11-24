package json

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The value of the number node `t` of the JSON text `src`.
@(private)
number_value :: #force_inline proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	lo, hi := t.lo, t.lo + u64(t.n)
	int_digits, frac_digits := tape.number_digits(t.spelling)
	// Bits 9 and up hold the fraction digits and the exponent bit, so 0 there and in the kind is a plain integer.
	if t.spelling & (tape.NUMBER_KIND | ~u16(0x1FF)) == 0 {
		if num, ok := spell.number_int(src, lo, hi, int_digits); ok {
			return num
		}
		return number_long(src, lo, hi)
	}
	if t.spelling & tape.NUMBER_KIND != 0 {
		return number5_value(src, lo, hi, t.spelling)
	}
	if t.spelling & tape.NUMBER_EXP != 0 {
		return spell.number_exponent(src, lo, hi, int_digits, frac_digits)
	}
	return spell.number_fraction(src, lo, hi, int_digits, frac_digits)
}

// The value of an integer past 19 digits or below `i64`'s minimum.
@(private, cold)
number_long :: #force_no_inline proc "contextless" (src: []u8, lo, hi: u64) -> spell.Number {
	num, _ := spell.number_strict(src, lo, hi)
	return num
}

// Decodes the text of string node `t` of the JSON text `src`, which holds an escape or a tolerated byte, into `buf`.
// False when `buf` is shorter than `decode_room` gives.
@(private)
text_decoded :: #force_inline proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	// An escape decodes to no more bytes than it spells, so a buffer as long as the span holds the text.
	if int(t.n) > len(buf) {
		return "", false
	}
	if t.spelling & (SPELLING_JSON5 | tape.SPELLING_LAX) != 0 {
		if t.spelling & tape.SPELLING_LAX != 0 {
			return text_lax(src, t, buf)
		}
		return string(buf[:decode5(buf, src, t.lo, t.lo + u64(t.n))]), true
	}
	if t.n < 256 {
		return string(buf[:decode_bytes(buf, 0, src, t.lo, t.lo + u64(t.n), false, false)]), true
	}
	return decode_blocks(src, t, buf)
}

// Decodes the text of a `SPELLING_LAX` string node, reading each maximal subpart of an ill-formed sequence as U+FFFD.
@(private, cold)
text_lax :: #force_no_inline proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (s: string, ok: bool) {
	if decode_room(src, t) > len(buf) {
		return "", false
	}
	lo, hi := t.lo, t.lo + u64(t.n)
	if t.spelling & SPELLING_JSON5 != 0 {
		return string(buf[:decode_bytes(buf, 0, src, lo, hi, true, true)]), true
	}
	return string(buf[:decode_bytes(buf, 0, src, lo, hi, false, true)]), true
}

// Decodes `src[p:end]` into `dst` from `dst[w]` one byte at a time and returns the end offset in `dst`. Reads JSON5
// escapes when `json5` and each maximal subpart of an ill-formed sequence as U+FFFD when `lax`.
@(private)
decode_bytes :: #force_inline proc "contextless" (dst: []u8, w: int, src: []u8, p, end: u64, $json5, $lax: bool) -> int #no_bounds_check {
	base := raw_data(src)
	out := raw_data(dst)
	p, w := p, w
	for p < end {
		c := base[p]
		when lax {
			if c >= 0x80 {
				w, p = decode_lax_char(base, p, end, out, w)
				continue
			}
		}
		if c != '\\' {
			out[w] = c
			w += 1
			p += 1
			continue
		}
		when json5 {
			w, p = decode5_escape(base, p, end, out, w)
		} else {
			w, p = decode_escape(base, p, end, out, w)
		}
	}
	return w
}

// Copies the character whose lead `base[p]` is past ASCII to `out[w:]`, or writes U+FFFD for the maximal subpart of an
// ill-formed sequence, and returns the ends in `out` and in `base`. `out` has room for three bytes per byte of `base`
// read.
@(private, cold)
decode_lax_char :: #force_no_inline proc "contextless" (base: [^]u8, p, end: u64, out: [^]u8, w: int) -> (int, u64) #no_bounds_check {
	n, q := spell.utf8_lax(base[p:], base[end:], out[w:])
	return w + n, u64(intrinsics.ptr_sub(q, base))
}

// Decodes the escape at `base[p]` into `out[w:]` and returns the ends in `out` and in `base`. A backslash that ends
// the text spells itself.
@(private)
decode_escape :: #force_inline proc "contextless" (base: [^]u8, p, end: u64, out: [^]u8, w: int) -> (int, u64) #no_bounds_check {
	if p + 1 >= end {
		out[w] = '\\'
		return w + 1, p + 1
	}
	if eb := spell.ESCAPED[base[p + 1]]; eb != 0 {
		out[w] = eb
		return w + 1, p + 2
	}
	return decode_unicode_into(base, p, end, out, w)
}

// Decodes the text of a long string node into `buf` 64 bytes at a time. A block with no escape is stored whole. A
// block with escapes copies the run before each escape and decodes the escape, loading the block once.
@(private)
decode_blocks :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8) -> (string, bool) #no_bounds_check {
	base := raw_data(src)
	out := raw_data(buf)
	limit := u64(len(src))
	end := t.lo + u64(t.n)
	p := t.lo
	w := 0
	for p < end {
		if p + 64 > limit {
			w = decode_bytes(buf, w, src, p, end, false, false)
			break
		}
		b := kernel.load(base[p:])
		m := kernel.pack(kernel.eq(b, '\\'))
		rem := end - p
		if m == 0 {
			if rem < 64 {
				copy_run(buf, w, base, int(p), int(rem))
				w += int(rem)
				break
			}
			#unroll for k in 0 ..< 4 {
				kernel.store16(out[w + k * 16:], b[k])
			}
			p += 64
			w += 64
			continue
		}
		cur := u64(0)
		crossed := false
		for m != 0 {
			k := u64(intrinsics.count_trailing_zeros(m))
			if k >= rem {
				break
			}
			if k > cur {
				copy_run(buf, w, base, int(p + cur), int(k - cur))
				w += int(k - cur)
			}
			next: u64
			w, next = decode_escape(base, p + k, end, out, w)
			cur = next - p
			if cur >= 64 {
				// The escape runs past this block, so the next block starts after it.
				crossed = true
				break
			}
			m &= max(u64) << cur
		}
		if crossed {
			p += cur
			continue
		}
		take := min(u64(64), rem)
		if cur < take {
			copy_run(buf, w, base, int(p + cur), int(take - cur))
			w += int(take - cur)
		}
		p += take
	}
	return string(buf[:w]), true
}

// Decodes the `\u` escape at `base[p]` into `out[w:]` and returns the ends in `out` and in `base`. The escape's hex
// digits must be valid, as a walk checks them.
@(private)
decode_unicode_into :: #force_inline proc "contextless" (base: [^]u8, p, end: u64, out: [^]u8, w: int) -> (int, u64) #no_bounds_check {
	if p + 6 > end || base[p + 1] != 'u' {
		out[w] = '\\'
		return w + 1, p + 1
	}
	unit := spell.hex4_value(base[p + 2:])
	if unit < 0x80 {
		out[w] = u8(unit)
		return w + 1, p + 6
	}
	if unit < 0x800 {
		out[w] = 0xC0 | u8(unit >> 6)
		out[w + 1] = 0x80 | u8(unit & 0x3F)
		return w + 2, p + 6
	}
	if unit - 0xD800 >= 0x800 {
		out[w] = 0xE0 | u8(unit >> 12)
		out[w + 1] = 0x80 | u8(unit >> 6 & 0x3F)
		out[w + 2] = 0x80 | u8(unit & 0x3F)
		return w + 3, p + 6
	}
	return decode_surrogate_into(base, p, end, unit, out, w)
}

// `decode_unicode_into` for a surrogate `unit`. Reads a pair as one code point and a lone half as U+FFFD.
@(private)
decode_surrogate_into :: #force_no_inline proc "contextless" (base: [^]u8, p, end: u64, unit: u32, out: [^]u8, w: int) -> (int, u64) #no_bounds_check {
	if unit < 0xDC00 && p + 12 <= end && base[p + 6] == '\\' && base[p + 7] == 'u' {
		low := spell.hex4_value(base[p + 8:])
		if spell.low_surrogate(low) {
			cp := u32(spell.surrogate_pair(unit, low))
			u := (0xF0 | (cp >> 18)) |
				(0x80 | (cp >> 12 & 0x3F)) << 8 |
				(0x80 | (cp >> 6 & 0x3F)) << 16 |
				(0x80 | (cp & 0x3F)) << 24
			intrinsics.unaligned_store((^u32le)(out[w:]), u32le(u))
			return w + 4, p + 12
		}
	}
	// A walk passes a lone surrogate half only under `.Lone_Surrogate`, which marks the string `SPELLING_LAX`.
	out[w], out[w + 1], out[w + 2] = spell.REPLACEMENT[0], spell.REPLACEMENT[1], spell.REPLACEMENT[2]
	return w + 3, p + 6
}

// Copies `n` bytes from `src[p:]` to `dst[w:]`, 16 bytes per store while they fit.
@(private)
copy_run :: #force_inline proc "contextless" (dst: []u8, w: int, src: [^]u8, p, n: int) #no_bounds_check {
	i := 0
	for i + 16 <= n {
		kernel.store16(raw_data(dst)[w + i:], kernel.load16(src[p + i:]))
		i += 16
	}
	copy_short(dst, w + i, src, p + i, n - i)
}

// Copies `n` bytes, fewer than 16, from `src[p:]` to `dst[w:]` with two overlapping stores where `n` is at least 2.
@(private)
copy_short :: #force_inline proc "contextless" (dst: []u8, w: int, src: [^]u8, p, n: int) #no_bounds_check {
	switch {
	case n >= 8:
		intrinsics.unaligned_store((^u64)(&dst[w]), intrinsics.unaligned_load((^u64)(&src[p])))
		intrinsics.unaligned_store((^u64)(&dst[w + n - 8]), intrinsics.unaligned_load((^u64)(&src[p + n - 8])))
	case n >= 4:
		intrinsics.unaligned_store((^u32)(&dst[w]), intrinsics.unaligned_load((^u32)(&src[p])))
		intrinsics.unaligned_store((^u32)(&dst[w + n - 4]), intrinsics.unaligned_load((^u32)(&src[p + n - 4])))
	case n >= 2:
		intrinsics.unaligned_store((^u16)(&dst[w]), intrinsics.unaligned_load((^u16)(&src[p])))
		intrinsics.unaligned_store((^u16)(&dst[w + n - 2]), intrinsics.unaligned_load((^u16)(&src[p + n - 2])))
	case n == 1:
		dst[w] = src[p]
	}
}

// The value of a JSON5 number outside JSON's grammar: a loose decimal, hex, `Infinity` or `NaN`.
@(private, cold)
number5_value :: #force_no_inline proc "contextless" (src: []u8, lo, hi: u64, spelling: u16) -> spell.Number #no_bounds_check {
	k := Number_Spelling(spelling & tape.NUMBER_KIND)
	neg := src[lo] == '-'
	p := lo + u64(src[lo] == '-' || src[lo] == '+')
	#partial switch k {
	case .Infinity:
		return {0x7ff0_0000_0000_0000 | u64(neg) << 63, .Float}
	case .Nan:
		// A quiet NaN with the sign it is written with.
		return {0x7ff8_0000_0000_0000 | u64(neg) << 63, .Float}
	case .Hex:
		return spell.number_hex(src[p + 2:hi], neg)
	}
	num, _ := spell.number_loose(src, lo, hi)
	return num
}

// Decodes the JSON5 text `src[p:end]` into `dst` from `dst[0]` and returns the end offset in `dst`.
@(private, cold)
decode5 :: #force_no_inline proc "contextless" (dst: []u8, src: []u8, p, end: u64) -> int {
	return decode_bytes(dst, 0, src, p, end, true, false)
}

// `decode_escape` for JSON5. It adds `\v`, `\0`, `\x` with two hex digits, a backslash before a line end (which
// spells nothing), and a backslash before any other character (which spells that character).
@(private)
decode5_escape :: proc "contextless" (base: [^]u8, p, end: u64, out: [^]u8, w: int) -> (int, u64) #no_bounds_check {
	if p + 1 >= end {
		out[w] = '\\'
		return w + 1, p + 1
	}
	e := base[p + 1]
	switch {
	case spell.ESCAPED[e] != 0:
		out[w] = spell.ESCAPED[e]
		return w + 1, p + 2
	case e == 'u':
		return decode_unicode_into(base, p, end, out, w)
	case e == 'x' && p + 4 <= end:
		unit := u32(spell.HEX_NIBBLE[base[p + 2]]) << 4 | u32(spell.HEX_NIBBLE[base[p + 3]])
		if unit < 0x80 {
			out[w] = u8(unit)
			return w + 1, p + 4
		}
		out[w], out[w + 1] = 0xC0 | u8(unit >> 6), 0x80 | u8(unit & 0x3F)
		return w + 2, p + 4
	case e == 'v':
		out[w] = 0x0B
		return w + 1, p + 2
	case e == '0':
		out[w] = 0
		return w + 1, p + 2
	case e == '\n':
		return w, p + 2
	case e == '\r':
		return w, p + 3 if p + 2 < end && base[p + 2] == '\n' else p + 2
	case e == 0xE2 && p + 3 < end && base[p + 2] == 0x80 && base[p + 3] | 1 == 0xA9:
		return w, p + 4
	}
	// The escaped character itself. A character past ASCII is read from its lead on, as a lax read judges it whole.
	if e >= 0x80 {
		return w, p + 1
	}
	out[w] = e
	return w + 1, p + 2
}

// Whether string `t` of `src` and string `o` of `other` read as the same text, decoding an escape at a time.
@(private)
same_text :: proc
 "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	a, b := key_reader(src, t), key_reader(other, o)
	for {
		x, more := key_byte(&a)
		y, other_more := key_byte(&b)
		if more != other_more || x != y {
			return false
		}
		if !more {
			return true
		}
	}
}

// `tape.text_hash` of the text that string `t` of `src` reads as, decoding an escape at a time.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return tape.text_hash(src[t.lo:][:t.n])
	}
	x := tape.text_hasher()
	k := key_reader(src, t)
	for {
		b, more := key_byte(&k)
		if !more {
			return tape.text_hasher_end(&x)
		}
		tape.text_hash_byte(&x, b)
	}
}

// The read position in the bytes a key token reads as, for `key_byte`.
@(private)
Key_Reader :: struct {
	base:   [^]u8,
	p, end: u64,
	json5:  bool,
	decode: bool,
	lax:    bool,
	one:    [4]u8, // the bytes of the escape or character last decoded, at most four
	at, n:  int,
}

@(private)
key_reader :: #force_inline proc "contextless" (src: []u8, t: tape.Token) -> Key_Reader {
	return {base = raw_data(src), p = t.lo, end = t.lo + u64(t.n), json5 = t.spelling & SPELLING_JSON5 != 0, decode = t.spelling & tape.SPELLING_DECODE != 0, lax = t.spelling & tape.SPELLING_LAX != 0}
}

// The next byte key `k` reads as, false past its end. A JSON5 line continuation reads as no byte.
@(private)
key_byte :: proc "contextless" (k: ^Key_Reader) -> (u8, bool) #no_bounds_check {
	for k.at == k.n {
		if k.p >= k.end {
			return 0, false
		}
		c := k.base[k.p]
		if !k.decode || c != '\\' && (c < 0x80 || !k.lax) {
			k.p += 1
			return c, true
		}
		k.at = 0
		if c != '\\' {
			k.n, k.p = decode_lax_char(k.base, k.p, k.end, raw_data(k.one[:]), 0)
		} else if k.json5 {
			k.n, k.p = decode5_escape(k.base, k.p, k.end, raw_data(k.one[:]), 0)
		} else {
			k.n, k.p = decode_escape(k.base, k.p, k.end, raw_data(k.one[:]), 0)
		}
	}
	k.at += 1
	return k.one[k.at - 1], true
}
