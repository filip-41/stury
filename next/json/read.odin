package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The value of the number node `t` of a JSON document, false for a node that is no number.
node_number :: #force_inline proc(doc: ^tape.Document, t: tape.Node) -> (spell.Number, bool) {
	if t.kind != .Number {
		return {}, false
	}
	lo, hi := t.lo, t.lo + u64(t.n)
	int_digits, frac_digits := tape.number_digits(t.spelling)
	// Bits 9 and up hold the fraction digits and the exponent bit, so 0 there and in the kind is a plain integer.
	if t.spelling & (tape.NUMBER_KIND | ~u16(0x1FF)) == 0 {
		if num, ok := spell.number_int(doc.src, lo, hi, int_digits); ok {
			return num, true
		}
		return number_long(doc.src, lo, hi), true
	}
	if t.spelling & tape.NUMBER_KIND != 0 {
		return number5_value(doc.src, lo, hi, t.spelling), true
	}
	if t.spelling & tape.NUMBER_EXP != 0 {
		return spell.number_exponent(doc.src, lo, hi, int_digits, frac_digits), true
	}
	return spell.number_fraction(doc.src, lo, hi, int_digits, frac_digits), true
}

// The value of an integer past 19 digits or below `i64`'s minimum.
@(private, cold)
number_long :: #force_no_inline proc(src: []u8, lo, hi: u64) -> spell.Number {
	num, _ := spell.number_strict(src, lo, hi)
	return num
}

// The text of the string node `t` of a JSON document: its bytes in the text when it holds no escape, else decoded
// into `buf`. False for a node that is no string, or a `buf` shorter than the node's span.
node_text :: #force_inline proc(doc: ^tape.Document, t: tape.Node, buf: []u8) -> (s: string, ok: bool) #no_bounds_check {
	if t.kind != .String {
		return "", false
	}
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return string(doc.src[t.lo:][:t.n]), true
	}
	// An escape decodes to no more bytes than it spells, so a buffer as long as the span holds the text.
	if int(t.n) > len(buf) {
		return "", false
	}
	if t.spelling & SPELLING_JSON5 != 0 {
		return string(buf[:decode5(buf, doc.src, t.lo, t.lo + u64(t.n))]), true
	}
	if t.n < 256 {
		return string(buf[:decode_bytes(buf, 0, doc.src, t.lo, t.lo + u64(t.n))]), true
	}
	return decode_blocks(doc.src, t, buf)
}

// The end in `dst` of `src[p:end]` decoded from `dst[w]` one byte at a time.
@(private)
decode_bytes :: #force_inline proc(dst: []u8, w: int, src: []u8, p, end: u64) -> int #no_bounds_check {
	base := raw_data(src)
	out := raw_data(dst)
	p, w := p, w
	for p < end {
		c := base[p]
		if c != '\\' {
			out[w] = c
			w += 1
			p += 1
			continue
		}
		if p + 1 >= end {
			out[w] = '\\'
			return w + 1
		}
		if eb := spell.ESCAPED[base[p + 1]]; eb != 0 {
			out[w] = eb
			w += 1
			p += 2
			continue
		}
		w, p = decode_unicode_into(base, p, end, out, w)
	}
	return w
}

// The text of a long string node decoded into `buf` 64 bytes at a time. A block with no escape is stored whole; a
// block with escapes copies the run before each escape and decodes the escape, loading the block once.
@(private)
decode_blocks :: proc(src: []u8, t: tape.Node, buf: []u8) -> (string, bool) #no_bounds_check {
	base := raw_data(src)
	out := raw_data(buf)
	limit := u64(len(src))
	end := t.lo + u64(t.n)
	p := t.lo
	w := 0
	for p < end {
		if p + 64 > limit {
			w = decode_bytes(buf, w, src, p, end)
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
			ep := p + k
			next: u64
			if ep + 1 >= end {
				out[w] = '\\'
				w += 1
				next = ep + 1
			} else if eb := spell.ESCAPED[base[ep + 1]]; eb != 0 {
				out[w] = eb
				w += 1
				next = ep + 2
			} else {
				w, next = decode_unicode_into(base, ep, end, out, w)
			}
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

// The ends in `out` and in `base` of the `\u` escape at `base[p]` decoded into `out[w:]`. The escape's hex digits
// must be valid, as a walk checks them.
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

// `decode_unicode_into` for a surrogate `unit`, which reads a pair as one code point and a lone half as U+FFFD.
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
	// The walk refuses a lone surrogate half, so this is a node no JSON walk made.
	out[w], out[w + 1], out[w + 2] = 0xEF, 0xBF, 0xBD
	return w + 3, p + 6
}

// Copies `n` bytes from `src[p:]` to `dst[w:]`, 16 bytes a store while they fit.
@(private)
copy_run :: #force_inline proc "contextless" (dst: []u8, w: int, src: [^]u8, p, n: int) #no_bounds_check {
	i := 0
	for i + 16 <= n {
		kernel.store16(raw_data(dst)[w + i:], kernel.load16(src[p + i:]))
		i += 16
	}
	copy_short(dst, w + i, src, p + i, n - i)
}

// Copies `n` bytes, below 16, from `src[p:]` to `dst[w:]` with two overlapping stores where they fit.
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

// The value of a JSON5 number past JSON's grammar: a loose decimal, hex, `Infinity` or `NaN`. `Wide` when memory for a
// long decimal is refused.
@(private, cold)
number5_value :: #force_no_inline proc(src: []u8, lo, hi: u64, spelling: u16) -> spell.Number #no_bounds_check {
	k := Number_Spelling(spelling & tape.NUMBER_KIND)
	neg := src[lo] == '-'
	p := lo + u64(src[lo] == '-' || src[lo] == '+')
	#partial switch k {
	case .Infinity:
		return {0x7ff0_0000_0000_0000 | u64(neg) << 63, .Float}
	case .Nan:
		// A quiet NaN with a zero sign, whatever sign it is written with.
		return {0x7ff8_0000_0000_0000, .Float}
	case .Hex:
		return spell.number_hex(src[p + 2:hi], neg)
	}
	// A decimal JSON refuses for its `+`, or for a point with no digit before or after it, is read as its digits
	// respelled in JSON, at most one byte longer.
	room: [128]u8
	buf := room[:]
	if int(hi - lo) + 1 > len(room) {
		err: runtime.Allocator_Error
		if buf, err = make([]u8, int(hi - lo) + 1); err != nil {
			return {0, .Wide}
		}
	}
	defer if raw_data(buf) != raw_data(room[:]) {
		delete(buf)
	}
	n := 0
	if neg {
		buf[0] = '-'
		n = 1
	}
	if src[p] == '.' {
		buf[n] = '0'
		n += 1
	}
	for i := p; i < hi; i += 1 {
		if src[i] == '.' && (i + 1 == hi || src[i + 1] | 0x20 == 'e') {
			continue
		}
		buf[n] = src[i]
		n += 1
	}
	num, _ := spell.number_strict(buf[:n], 0, u64(n))
	if spelling & tape.NUMBER_POINT != 0 {
		// A trailing point (`5.`) makes a float, and `-0.` keeps its sign.
		if num.kind == .Int {
			num = {transmute(u64)f64(i64(num.bits)) | u64(neg) << 63, .Float}
		} else if num.kind == .Uint {
			num = {transmute(u64)f64(num.bits), .Float}
		}
	}
	return num
}

// The end in `dst` of JSON5's text `src[p:end]` decoded from `dst[0]`. JSON5 adds `\v`, `\0`, `\x` and two hex
// digits, a backslash before a line end, which spells nothing, and a backslash before any other character, which
// spells that character.
@(private, cold)
decode5 :: #force_no_inline proc(dst: []u8, src: []u8, p, end: u64) -> int #no_bounds_check {
	base := raw_data(src)
	out := raw_data(dst)
	p := p
	w := 0
	for p < end {
		c := base[p]
		if c != '\\' || p + 1 >= end {
			out[w] = c
			w += 1
			p += 1
			continue
		}
		e := base[p + 1]
		switch {
		case spell.ESCAPED[e] != 0:
			out[w] = spell.ESCAPED[e]
			w, p = w + 1, p + 2
		case e == 'u':
			w, p = decode_unicode_into(base, p, end, out, w)
		case e == 'x':
			unit := u32(spell.HEX_NIBBLE[base[p + 2]]) << 4 | u32(spell.HEX_NIBBLE[base[p + 3]])
			if unit < 0x80 {
				out[w] = u8(unit)
				w += 1
			} else {
				out[w], out[w + 1] = 0xC0 | u8(unit >> 6), 0x80 | u8(unit & 0x3F)
				w += 2
			}
			p += 4
		case e == 'v':
			out[w] = 0x0B
			w, p = w + 1, p + 2
		case e == '0':
			out[w] = 0
			w, p = w + 1, p + 2
		case e == '\n':
			p += 2
		case e == '\r':
			p += 3 if p + 2 < end && base[p + 2] == '\n' else 2
		case e == 0xE2 && p + 3 < end && base[p + 2] == 0x80 && base[p + 3] | 1 == 0xA9:
			p += 4
		case:
			// The escaped character itself. The other bytes of a UTF-8 character follow as plain bytes.
			out[w] = e
			w, p = w + 1, p + 2
		}
	}
	return w
}
