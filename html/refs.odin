package html

import "base:intrinsics"
import spell "../core/spell"

// Character references, read once by the tokenizer, which reports their errors, and again by `decode`, which writes
// their values, so both read them alike. The states from the character reference state to the numeric character
// reference end state are `read_ref`.

// A character reference read at its `&`. `n` is 0 when it has no value and the bytes it consumed are its characters.
@(private)
Ref :: struct {
	q:      [^]u8, // one past the bytes it consumed
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
	node, best: u32
	best_q := q
	last: u8
	for q < end {
		c := q[0]
		if c >= 0x80 {
			break
		}
		node = spell.entity_child(node, c)
		if node == 0 {
			break
		}
		q = q[1:]
		if _, named := spell.entity_value(node); named {
			best, best_q, last = node, q, c
		}
	}
	if best == 0 {
		// The ambiguous ampersand state: the letters and digits are characters, and a `;` after them is an error.
		q = p[1:]
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
	if last != ';' {
		if attr && best_q < end && (best_q[0] == '=' || CLASS[best_q[0]] & C_ALNUM != 0) {
			return
		}
		r.errors[0], r.err_at[0] = .Missing_Semicolon_After_Character_Reference, best_q
	}
	text, _ := spell.entity_value(best)
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
		c := q[0]
		d: u32
		if CLASS[c] & C_DIGIT != 0 {
			d = u32(c - '0')
		} else if hex && CLASS[c] & C_HEX != 0 {
			d = u32(c | 0x20) - 'a' + 10
		} else {
			break
		}
		// Saturates past U+10FFFF, so a long run of digits cannot wrap.
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
	r.n = encode(r.value[:], code)
	return
}

// The code points the numeric references to U+0080 to U+009F read as, from windows-1252, 0 for one kept as it is.
@(private, rodata)
C1_REMAP := [32]u16 {
	0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
	0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
}

// Writes `cp` in UTF-8 to `out` and returns its length.
@(private)
encode :: #force_inline proc "contextless" (out: []u8, cp: u32) -> int #no_bounds_check {
	switch {
	case cp < 0x80:
		out[0] = u8(cp)
		return 1
	case cp < 0x800:
		out[0], out[1] = u8(0xC0 | cp >> 6), u8(0x80 | cp & 0x3F)
		return 2
	case cp < 0x10000:
		out[0], out[1], out[2] = u8(0xE0 | cp >> 12), u8(0x80 | cp >> 6 & 0x3F), u8(0x80 | cp & 0x3F)
		return 3
	}
	out[0], out[1], out[2], out[3] = u8(0xF0 | cp >> 18), u8(0x80 | cp >> 12 & 0x3F), u8(0x80 | cp >> 6 & 0x3F), u8(0x80 | cp & 0x3F)
	return 4
}

// Writes the characters span `s` of `src` reads as to `buf` and returns them. A span with no flags is its source
// bytes, returned with no copy and no buffer. Any other span needs `decode_room(s)` bytes of `buf`, and is refused,
// `ok` false, when `buf` is shorter. CR LF and a lone CR read as LF, ill-formed UTF-8 as U+FFFD per maximal subpart,
// U+0000 as `s.mode` says, and character references as the tokenizer read them.
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
			q, kind := spell.utf8_char(p, end)
			if kind != .None {
				out[w], out[w + 1], out[w + 2] = 0xEF, 0xBF, 0xBD
				w += 3
				p = spell.utf8_subpart(p, end)
			} else {
				n := int(intrinsics.ptr_sub(q, p))
				intrinsics.mem_copy_non_overlapping(out[w:], p, n)
				w += n
				p = q
			}
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
