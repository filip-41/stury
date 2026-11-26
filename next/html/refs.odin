package html

import "base:intrinsics"
import "stury:lib/base/spell"

// Character references, read once by the tokenizer (reporting errors) and again by `decode` (writing values).

@(private = "file")
utf8_encode_rune :: proc "contextless" (dst: []u8, r: rune) -> int #no_bounds_check {
	c := u32(r)
	switch {
	case c <= 0x7F:
		dst[0] = u8(c)
		return 1
	case c <= 0x7FF:
		dst[0] = 0xC0 | u8(c >> 6)
		dst[1] = 0x80 | u8(c & 0x3F)
		return 2
	case c <= 0xFFFF:
		dst[0] = 0xE0 | u8(c >> 12)
		dst[1] = 0x80 | u8((c >> 6) & 0x3F)
		dst[2] = 0x80 | u8(c & 0x3F)
		return 3
	case:
		dst[0] = 0xF0 | u8(c >> 18)
		dst[1] = 0x80 | u8((c >> 12) & 0x3F)
		dst[2] = 0x80 | u8((c >> 6) & 0x3F)
		dst[3] = 0x80 | u8(c & 0x3F)
		return 4
	}
}

@(private)
Ref :: struct {
	q:      [^]u8,
	value:  [8]u8,
	n:      int,
	errors: [2]Detail,
	err_at: [2][^]u8,
}

// Reads the character reference whose `&` is at `p`, as in an attribute value when `attr` is set.
@(private)
read_ref :: proc "contextless" (p, end: [^]u8, attr: bool) -> (r: Ref) #no_bounds_check {
	q := p[1:]
	r.q = q
	if q >= end {
		return
	}
	if q[0] == '#' {
		return read_numeric(q[1:], end)
	}
	if CLASS[q[0]] & C_ALNUM == 0 {
		return
	}
	text, best_q := spell.entity_prefix(q, end)
	if len(text) == 0 {
		for q < end && CLASS[q[0]] & C_ALNUM != 0 {
			q = q[1:]
		}
		r.q = q
		if q < end && q[0] == ';' {
			r.errors[0], r.err_at[0] = .Unknown_Named_Character_Reference, q
		}
		return
	}
	r.q = best_q
	if q[intrinsics.ptr_sub(best_q, q) - 1] != ';' {
		if attr && best_q < end && (best_q[0] == '=' || CLASS[best_q[0]] & C_ALNUM != 0) {
			return
		}
		r.errors[0], r.err_at[0] = .Missing_Semicolon_After_Character_Reference, best_q
	}
	copy(r.value[:], text)
	r.n = len(text)
	return
}

// Reads a numeric character reference from `p`, past its `&#`.
@(private)
read_numeric :: proc "contextless" (p, end: [^]u8) -> (r: Ref) {
	q := p
	hex := q < end && q[0] | 0x20 == 'x'
	if hex {
		q = q[1:]
	}
	digits := q
	code: u32
	for q < end {
		d := u32(spell.HEX_NIBBLE[q[0]])
		if d >= (16 if hex else 10) {
			break
		}
		code = min(code * (16 if hex else 10) + d, 0x110000)
		q = q[1:]
	}
	r.q = q
	if q == digits {
		r.errors[0], r.err_at[0] = .Absence_Of_Digits_In_Numeric_Character_Reference, q
		return
	}
	k := 0
	if q < end && q[0] == ';' {
		q = q[1:]
	} else {
		r.errors[0], r.err_at[0] = .Missing_Semicolon_After_Character_Reference, q
		k = 1
	}
	r.q = q
	d := Detail.None
	switch {
	case code == 0:
		d, code = .Null_Character_Reference, 0xFFFD
	case code > 0x10FFFF:
		d, code = .Character_Reference_Outside_Unicode_Range, 0xFFFD
	case code >= 0xD800 && code <= 0xDFFF:
		d, code = .Surrogate_Character_Reference, 0xFFFD
	case code >= 0xFDD0 && code <= 0xFDEF || code & 0xFFFE == 0xFFFE:
		d = .Noncharacter_Character_Reference
	case code == 0x0D || (code < 0x20 || code >= 0x7F && code <= 0x9F) && CLASS[code] & C_WS == 0:
		d = .Control_Character_Reference
		if code >= 0x80 && C1_REMAP[code - 0x80] != 0 {
			code = u32(C1_REMAP[code - 0x80])
		}
	}
	if d != .None {
		r.errors[k], r.err_at[k] = d, q
	}
	r.n = utf8_encode_rune(r.value[:], rune(code))
	return
}

@(private, rodata)
C1_REMAP := [32]u16 {
	0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
	0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
}

// Writes the characters span `s` of `src` reads as to `buf` and returns them.
@(private)
decode :: proc "contextless" (src: []u8, s: Span, buf: []u8) -> (text: string, ok: bool) #optional_ok #no_bounds_check {
	p := raw_data(src)[s.lo:]
	if s.flags & ~{.Missing} == {} {
		return string(p[:s.n]), true
	}
	if len(buf) < decode_room(s) {
		return "", false
	}
	end := p[s.n:]
	out := raw_data(buf)
	w := 0
	refs := .Ref in s.flags && (s.mode == .Data || s.mode == .Text || s.mode == .Rcdata || s.mode == .Value)
	keep_nul := s.mode == .Data || s.mode == .Verbatim
	for p < end {
		c := p[0]
		switch {
		case c == '\r':
			out[w] = '\n'
			w += 1
			p = p[1:]
			if p < end && p[0] == '\n' {
				p = p[1:]
			}
			continue
		case c == 0 && s.mode == .Text:
			p = p[1:]
			continue
		case c == 0 && !keep_nul:
			out[w], out[w + 1], out[w + 2] = 0xEF, 0xBF, 0xBD
			w += 3
			p = p[1:]
			continue
		case c == '&' && refs:
			r := read_ref(p, end, s.mode == .Value)
			if r.n > 0 {
				intrinsics.mem_copy_non_overlapping(out[w:], &r.value, r.n)
				w += r.n
			} else {
				n := int(intrinsics.ptr_sub(r.q, p))
				intrinsics.mem_copy_non_overlapping(out[w:], p, n)
				w += n
			}
			p = r.q
			continue
		case c >= 0x80:
			n, next := spell.utf8_lax(p, end, out[w:])
			w += n
			p = next
			continue
		case s.mode == .Name && CLASS[c] & C_UPPER != 0:
			c |= 0x20
		}
		out[w] = c
		w += 1
		p = p[1:]
	}
	return string(out[:w]), true
}
