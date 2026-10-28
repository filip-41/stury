package scan

// JSON5 1.0.0's tokens on the dialect walk: its whitespace, its keys, its strings and its numbers. A token
// the walk accepts in JSON's spelling is read by JSON's own leaf, so its row is a JSON row.
//
// Rows: a string or key token counts as plain only when it is double-quoted with no backslash and no raw
// control byte. A single-quoted token, an unquoted key and a token holding an escape or a control byte are escaped rows, which a reader decodes by JSON5's
// escapes (`json5_unescape_into`, `json5_name_equals`, `Key_Bytes`). A number spelled outside JSON's grammar
// carries the digit pack `number.DIALECT_SPELLED`, which sends its readers to `number.json5_number_value`.
//
// Deliberate limits: a lone surrogate escape is refused (it has no UTF-8), an identifier takes the characters
// `unicode.is_letter` knows (Lu, Ll, Lt, Lm, Lo) and not the letter numbers (Nl) that ES5 also allows, and
// after its first character the decimal digits (Nd), the marks Mn and Mc, and the connectors Pc. A comment's
// bytes are checked as JSONC checks them.

import "core:math"
import "core:strconv"
import "core:unicode"
import "core:unicode/utf8"
import core_pkg "../../core"
import "walk"
import lex "lex"
import number "./number"

// Steps over one JSON5 whitespace character JSON does not have: VT, FF, NBSP, BOM, U+2028, U+2029 or a Zs
// space. False, with `s.pos` unmoved, on any other byte.
json5_space :: proc(s: ^Scanner) -> bool {
	n := u64(len(s.src))
	if s.pos >= n {
		return false
	}
	b := s.src[s.pos]
	if b == 0x0B || b == 0x0C {
		s.pos += 1
		return true
	}
	if b < 0x80 {
		return false
	}
	r, w := utf8.decode_rune(s.src[s.pos:])
	switch r {
	case 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		s.pos += u64(w)
		return true
	}
	return false
}

// The value class a JSON5 value's first byte has where JSON gives it none: a single quote opens a string, and
// `+`, `.`, `I` and `N` a number.
json5_class :: #force_inline proc(b: int) -> u8 {
	switch b {
	case '\'':
		return VC_STRING
	case '+', '.', 'I', 'N':
		return VC_NUMBER
	}
	return VC_NONE
}

// The key at `s.pos`: quoted in either quote, or an IdentifierName. An unquoted key is an escaped key token:
// it has no delimiters for a plain compare.
json5_key :: proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, $Q: bit_set[Walk_Kind]) -> Maybe(Error) {
	b := s.src[s.pos]
	if b == '"' || b == '\'' {
		return json5_string(s, q, lo, true, Q)
	}
	if stepped, err := identifier_step(s, true); err != nil {
		return err
	} else if !stepped {
		return Error{offset = s.pos, kind = .Bad_Char}
	}
	for {
		stepped, err := identifier_step(s, false)
		if err != nil {
			return err
		}
		if !stepped {
			break
		}
	}
	when Q & lex.KEY_ESC_KINDS != {} {
		if q.key_esc_live {
			q.key_saw_escape = true
		}
	}
	return nil
}

// One character of an IdentifierName at `s.pos`, stepped over when it may stand there (`start` for the first).
// An escape is `\uXXXX` and must name such a character.
@(private = "file")
identifier_step :: proc(s: ^Scanner, start: bool) -> (stepped: bool, err: Maybe(Error)) {
	n := u64(len(s.src))
	if s.pos >= n {
		return false, nil
	}
	b := s.src[s.pos]
	if b < 0x80 && b != '\\' {
		ok := b == '$' || b == '_' || (b | 0x20 >= 'a' && b | 0x20 <= 'z') || (!start && b >= '0' && b <= '9')
		if ok {
			s.pos += 1
		}
		return ok, nil
	}
	r: rune
	w: u64
	if b == '\\' {
		if s.pos + 6 > n || s.src[s.pos + 1] != 'u' {
			return false, Error{offset = s.pos, kind = .Bad_Escape}
		}
		cp, ok := lex.hex4(s.src, s.pos + 2)
		if !ok {
			return false, Error{offset = s.pos, kind = .Bad_Escape}
		}
		r, w = rune(cp), 6
	} else {
		rr, size := utf8.decode_rune(s.src[s.pos:])
		if rr == utf8.RUNE_ERROR && size <= 1 {
			return false, Error{offset = s.pos, kind = .Bad_Char}
		}
		r, w = rr, u64(size)
	}
	if !identifier_rune(r, start) {
		if b == '\\' {
			return false, Error{offset = s.pos, kind = .Bad_Escape}
		}
		return false, nil
	}
	s.pos += w
	return true, nil
}

@(private = "file")
identifier_rune :: proc(r: rune, start: bool) -> bool {
	if r == '$' || r == '_' || unicode.is_letter(r) {
		return true
	}
	if start {
		return false
	}
	switch r {
	// ZWNJ, ZWJ and the connector punctuation (Pc) besides `_`.
	case 0x200C, 0x200D, 0x203F, 0x2040, 0x2054, 0xFE33, 0xFE34, 0xFE4D ..= 0xFE4F, 0xFF3F:
		return true
	}
	return unicode.is_decimal(r) || unicode.is_nonspacing_mark(r) || unicode.is_spacing_mark(r)
}

// The string at `s.pos` in either quote. Every escape is checked (`json5_escape_unit`), a raw LF or CR is
// `.Bad_Char`, other raw bytes are wire UTF-8. A value string hands `.Dom` its exact decoded length.
json5_string :: proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, key: bool, $Q: bit_set[Walk_Kind]) -> Maybe(Error) {
	src := s.src
	n := u64(len(src))
	quote := src[s.pos]
	s.pos += 1
	escaped := quote != '"'
	first_esc := u64(1)
	dec_len: u64
	for {
		if s.pos >= n {
			return Error{offset = n, kind = .Truncated}
		}
		c := src[s.pos]
		switch {
		case c == quote:
			s.pos += 1
			if key {
				when Q & lex.KEY_ESC_KINDS != {} {
					if escaped && q.key_esc_live {
						q.key_saw_escape = true
					}
				}
			} else {
				when Q & lex.STR_ESC_KINDS != {} {
					q.str_escaped = escaped
					q.str_first_esc = u16(min(first_esc, u64(FIRST_ESC_SATURATED))) if escaped else 0
				}
				walk.emit_dom_string(q, Q, src, lo, s.pos, true, escaped, dec_len)
			}
			return nil
		case c == '\\':
			if !escaped {
				escaped = true
				first_esc = s.pos - lo
			}
			unit: [4]u8
			w, next, ok := json5_escape_unit(src, s.pos, n, unit[:])
			if !ok {
				if s.pos + 1 >= n {
					return Error{offset = n, kind = .Truncated}
				}
				return Error{offset = s.pos, kind = .Bad_Escape}
			}
			dec_len += u64(w)
			s.pos = next
		case c == '\n' || c == '\r':
			return Error{offset = s.pos, kind = .Bad_Char}
		case c < 0x20:
			// A raw control byte is legal JSON5 but not JSON, so its token is an escaped row: a reader that
			// respells it as JSON (`jq_string`) escapes it.
			if !escaped {
				escaped = true
				first_esc = s.pos - lo
			}
			dec_len += 1
			s.pos += 1
		case c < 0x80:
			dec_len += 1
			s.pos += 1
		case:
			at := s.pos
			if err := lex.utf8_step_checked(s); err != nil {
				return err
			}
			dec_len += s.pos - at
		}
	}
}

// One JSON5 escape at `src[p] == '\\'`, decoded into `unit`, as `decode_escape_unit` decodes JSON's: `\'`, `\v`,
// `\0` before no digit, `\xHH`, `\uXXXX` (a surrogate pair is one unit, a lone half is refused), a line
// continuation (no bytes), and any other character that is not a digit or a line break as itself.
json5_escape_unit :: proc(src: []byte, p, end: u64, unit: []u8) -> (n: int, next: u64, ok: bool) {
	if p + 1 >= end {
		return 0, p, false
	}
	e := src[p + 1]
	single: u8
	switch e {
	case 'b': single = 0x08
	case 'f': single = 0x0C
	case 'n': single = '\n'
	case 'r': single = '\r'
	case 't': single = '\t'
	case 'v': single = 0x0B
	case '0':
		if p + 2 < end && src[p + 2] - '0' < 10 {
			return 0, p, false
		}
		unit[0] = 0
		return 1, p + 2, true
	case '1' ..= '9':
		return 0, p, false
	case 'x':
		if p + 4 > end {
			return 0, p, false
		}
		hi, lo := core_pkg.HEX_NIBBLE[src[p + 2]], core_pkg.HEX_NIBBLE[src[p + 3]]
		if hi > 15 || lo > 15 {
			return 0, p, false
		}
		spelled, size := utf8.encode_rune(rune(hi << 4 | lo))
		return copy(unit, spelled[:size]), p + 4, true
	case 'u':
		return decode_escape_unit(src, p, end, unit)
	case '\n':
		return 0, p + 2, true
	case '\r':
		if p + 2 < end && src[p + 2] == '\n' {
			return 0, p + 3, true
		}
		return 0, p + 2, true
	case:
		if e < 0x80 {
			single = e
		} else {
			r, size := utf8.decode_rune(src[p + 1:end])
			if r == utf8.RUNE_ERROR && size <= 1 {
				return 0, p, false
			}
			if r == 0x2028 || r == 0x2029 {
				return 0, p + 1 + u64(size), true
			}
			return copy(unit, src[p + 1:][:size]), p + 1 + u64(size), true
		}
	}
	unit[0] = single
	return 1, p + 2, true
}

// The decoded text of the JSON5 string or key token `src[lo:hi]` a dialect walk accepted, written to `dst`:
// the `.Dom` hook. -1 when `dst` is short.
json5_unescape_into :: proc(dst: []byte, src: []byte, lo, hi: u64, _: u64) -> int {
	it := key_bytes_of(src, lo, hi, true)
	w := 0
	for b in key_bytes_next(src, &it) {
		if w >= len(dst) {
			return -1
		}
		dst[w] = b
		w += 1
	}
	return w
}

// Whether the JSON5 key token `src[lo:hi]` decodes to `name`: the path hook.
json5_name_equals :: proc(src: []byte, lo, hi: u64, name: string) -> bool {
	it := key_bytes_of(src, lo, hi, true)
	at := 0
	for b in key_bytes_next(src, &it) {
		if at >= len(name) || name[at] != b {
			return false
		}
		at += 1
	}
	return at == len(name)
}

// The decoded text of an escaped JSON5 token, unescaped into `arena` (its spelling's `decode`).
json5_span_text :: proc(src: []byte, arena: ^Name_Arena, lo, hi: u64) -> (s: []u8, ok: bool) {
	if hi <= lo || hi > u64(len(src)) {
		return nil, false
	}
	slot, reserved := name_arena_reserve(arena, int(hi - lo))
	if !reserved {
		return nil, false
	}
	w := json5_unescape_into(slot, src, lo, hi, 0)
	if w < 0 {
		return nil, false
	}
	name_arena_unreserve(arena, len(slot) - w)
	return slot[:w], true
}

// The number at `s.pos`. A token in JSON's spelling is read by JSON's leaf, so its row is JSON's. Any other
// (a sign `+`, a leading or trailing point, hex, `Infinity`, `NaN`) is checked here and its row carries
// `number.DIALECT_SPELLED`. Leading zeros are refused as in JSON.
json5_number :: proc(s: ^Scanner, q: ^Query_Ctx, lo: u64, $Q: bit_set[Walk_Kind]) -> Maybe(Error) {
	src := s.src
	n := u64(len(src))
	p := s.pos
	plus := src[p] == '+'
	if plus || src[p] == '-' {
		p += 1
	}
	if p >= n {
		return Error{offset = n, kind = .Truncated}
	}
	switch src[p] {
	case 'I', 'N':
		word := "Infinity" if src[p] == 'I' else "NaN"
		if n - p < u64(len(word)) {
			if string(src[p:]) == word[:n - p] {
				return Error{offset = n, kind = .Truncated}
			}
			return Error{offset = p, kind = KIND_LITERAL}
		}
		if string(src[p:][:len(word)]) != word {
			return Error{offset = p, kind = KIND_LITERAL}
		}
		s.pos = p + u64(len(word))
		walk.emit_number(q, Q, lo, s.pos, number.DIALECT_SPELLED)
		return nil
	case '0':
		if p + 1 < n && src[p + 1] | 0x20 == 'x' {
			at := p + 2
			p = at
			for p < n && core_pkg.HEX_NIBBLE[src[p]] < 16 {
				p += 1
			}
			if p == at {
				return Error{offset = p, kind = .Bad_Number} if p < n else Error{offset = n, kind = .Truncated}
			}
			if p - at > s.limits.max_scalar_digits {
				return Error{offset = lo, kind = .Limit_Digits}
			}
			s.pos = p
			walk.emit_number(q, Q, lo, s.pos, number.DIALECT_SPELLED)
			return nil
		}
	}
	int_at := p
	p = digits_end(src, p)
	int_digits := p - int_at
	if int_digits > 1 && src[int_at] == '0' {
		return Error{offset = int_at + 1, kind = .Bad_Number}
	}
	point := p < n && src[p] == '.'
	frac_digits: u64
	if point {
		p += 1
		at := p
		p = digits_end(src, p)
		frac_digits = p - at
	}
	if int_digits + frac_digits == 0 {
		return Error{offset = p, kind = .Bad_Number} if p < n else Error{offset = n, kind = .Truncated}
	}
	if !plus && int_digits > 0 && (!point || frac_digits > 0) {
		// JSON's spelling, exponent or not: JSON's leaf reads it.
		return number.parse_number_q(s, q, lo, Q)
	}
	if int_digits + frac_digits > s.limits.max_scalar_digits {
		return Error{offset = lo, kind = .Limit_Digits}
	}
	if p < n && src[p] | 0x20 == 'e' {
		p += 1
		if p < n && (src[p] == '+' || src[p] == '-') {
			p += 1
		}
		at := p
		p = digits_end(src, p)
		if p == at {
			return Error{offset = p, kind = .Bad_Number} if p < n else Error{offset = n, kind = .Truncated}
		}
		if p - at > 20 || number_exponent(src, at, p) > s.limits.max_scalar_scale {
			return Error{offset = lo, kind = .Limit_Scale}
		}
	}
	s.pos = p
	walk.emit_number(q, Q, lo, s.pos, number.DIALECT_SPELLED)
	return nil
}

@(private = "file")
digits_end :: #force_inline proc(src: []byte, p: u64) -> u64 {
	p := p
	for p < u64(len(src)) && src[p] - '0' < 10 {
		p += 1
	}
	return p
}

@(private = "file")
number_exponent :: proc(src: []byte, lo, hi: u64) -> (e: u64) {
	for p in lo ..< hi {
		e = e * 10 + u64(src[p] - '0')
	}
	return
}

// The `i64` the JSON5 number row's token `src[lo:hi]` writes (`dom_int`'s arm for a `DIALECT_SPELLED` row): a
// hex integer or a `+`-signed decimal integer. A fraction, a point, an exponent, `Infinity` and `NaN` are no
// `i64`.
json5_int :: proc(src: []byte, lo, hi: u64) -> (v: i64, ok: bool) {
	p := lo
	neg := src[p] == '-'
	if neg || src[p] == '+' {
		p += 1
	}
	if hi - p > 2 && src[p] == '0' && src[p + 1] | 0x20 == 'x' {
		mag, _, over := number.json5_hex(src, p + 2, hi)
		if over {
			return 0, false
		}
		if neg {
			if mag > u64(max(i64)) + 1 {
				return 0, false
			}
			return i64(0 - mag), true
		}
		if mag > u64(max(i64)) {
			return 0, false
		}
		return i64(mag), true
	}
	if neg {
		return 0, false
	}
	return decode_int(src, p, hi)
}

// The JSON5 number token `lit`, spelled outside JSON's grammar (`DIALECT_SPELLED`), appended to `out` in JSON's
// spelling: a hex integer as the exact decimal integer, a decimal without its `+`, with a `0` before a leading
// point and without a trailing point. False, with `out` as it was, for a value JSON cannot spell (`Infinity`,
// `NaN`).
json5_number_json :: proc(lit: string, out: ^[dynamic]byte) -> bool {
	p := 0
	if lit[0] == '+' || lit[0] == '-' {
		p = 1
	}
	hex := len(lit) > p + 1 && lit[p + 1] | 0x20 == 'x'
	if !hex {
		v := number.json5_number_value(transmute([]byte)lit, 0, u64(len(lit)))
		if math.is_nan(v.value) || math.is_inf(v.value) {
			return false
		}
	}
	// A decimal grows by a `0`; a hex integer has at most 1.21 decimal digits per hex digit, plus one.
	reserve(out, len(out) + len(lit) + len(lit) / 4 + 2)
	if lit[0] == '-' {
		append(out, '-')
	}
	if hex {
		hex_decimal(lit[p + 2:], out)
		return true
	}
	if lit[p] == '.' {
		append(out, '0')
	}
	for i in p ..< len(lit) {
		if lit[i] == '.' && (i + 1 == len(lit) || lit[i + 1] - '0' >= 10) {
			continue
		}
		append(out, lit[i])
	}
	return true
}

// Append the hex digits `hex` as the exact decimal integer they write, at any length. The value is kept in base
// 10^9 words, least significant first, in `out`'s allocator.
@(private = "file")
hex_decimal :: proc(hex: string, out: ^[dynamic]byte) {
	BASE :: 1_000_000_000
	// ponytail: quadratic in the digit count; the scalar length cap bounds it.
	words := make([dynamic]u32, 0, len(hex) / 7 + 1, out.allocator)
	defer delete(words)
	for c in transmute([]byte)hex {
		carry := u64(core_pkg.HEX_NIBBLE[c])
		for &w in words {
			x := u64(w) * 16 + carry
			w, carry = u32(x % BASE), x / BASE
		}
		if carry > 0 {
			append(&words, u32(carry))
		}
	}
	if len(words) == 0 {
		append(out, '0')
		return
	}
	buf: [16]u8
	append(out, strconv.write_uint(buf[:], u64(words[len(words) - 1]), 10))
	#reverse for w in words[:len(words) - 1] {
		s := strconv.write_uint(buf[:], u64(w), 10)
		for _ in len(s) ..< 9 {
			append(out, '0')
		}
		append(out, s)
	}
}
