#+private
package toml

import "base:intrinsics"
import "core:simd"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"

// The spelling of a string or key token. Bit 0 is `core.SPELLING_DECODE`, set on every token written with quotes, whose
// span holds them. Bits 3 and 4 hold the style. A bare key has no bits set.
STYLE_SHIFT :: 3
STYLE_MASK :: u16(3)

Style :: enum u8 {
	Basic,
	Literal,
	Multiline,
	Multiline_Literal,
}

string_spelling :: #force_inline proc "contextless" (style: Style) -> u16 {
	return core.SPELLING_DECODE | u16(style) << STYLE_SHIFT
}

style_of :: #force_inline proc "contextless" (spelling: u16) -> Style {
	return Style(spelling >> STYLE_SHIFT & STYLE_MASK)
}

// A scanner's verdict: the fault's result word, 0 for none.
Verdict :: u64

bad :: #force_inline proc "contextless" (at: int, kind: core.Fault_Kind, detail: Detail) -> Verdict {
	return core.fault_at(u64(at), kind, u8(detail))
}

// Whether `b` is a byte a string or comment may hold as it is: not a control character other than tab, and not DEL.
plain_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= 0x20 && b != 0x7f || b == '\t'
}

// Steps over the UTF-8 character at `i`, whose lead is at least 0x80. Returns the byte past it, or the fault.
utf8_step :: #force_inline proc "contextless" (src: []u8, i: int) -> (next: int, v: Verdict) {
	base := raw_data(src)
	q, kind := spell.utf8_char(base[i:], base[len(src):])
	switch kind {
	case .None:
		return int(uintptr(q) - uintptr(base)), 0
	case .Truncated:
		return len(src), bad(len(src), .Truncated, .Cut_Utf8)
	case .Bad_Char, .Bad_Escape, .Bad_Number, .Too_Deep, .Too_Wide, .No_Memory, .Bad_Option, .Bad_Width, .Duplicate_Key:
	}
	return i, bad(i, .Bad_Char, .Invalid_Utf8)
}

// Scans a comment whose `#` is at `i`. Returns the first byte past its text, the line end, or the fault.
scan_comment :: proc "contextless" (src: []u8, i: int) -> (end: int, v: Verdict) {
	k := i + 1
	for k < len(src) {
		b := src[k]
		if b >= 0x80 {
			k, v = utf8_step(src, k)
			if v != 0 {
				return k, v
			}
			continue
		}
		if plain_byte(b) {
			k += 1
			continue
		}
		if b == '\n' || b == '\r' && k + 1 < len(src) && src[k + 1] == '\n' {
			return k, 0
		}
		return k, bad(k, .Bad_Char, .Lone_Cr if b == '\r' else .Control_Char)
	}
	return k, 0
}

// The value of the hex digits `src[i:i+count]`, or false at a byte that is none.
hex_run :: proc "contextless" (src: []u8, i, count: int) -> (v: u32, at: int, ok: bool) {
	for k in 0 ..< count {
		if i + k >= len(src) {
			return 0, len(src), false
		}
		d := spell.HEX_NIBBLE[src[i + k]]
		if d == 0xff {
			return 0, i + k, false
		}
		v = v << 4 | u32(d)
	}
	return v, i + count, true
}

// Judges the escape whose backslash is at `i` in a basic string. Returns the byte past it.
scan_escape :: proc "contextless" (src: []u8, i: int, v11: bool) -> (next: int, v: Verdict) {
	if i + 1 >= len(src) {
		return len(src), bad(len(src), .Truncated, .Open_String)
	}
	c := src[i + 1]
	count: int
	switch c {
	case 'b', 't', 'n', 'f', 'r', '"', '\\':
		return i + 2, 0
	case 'e':
		if v11 {
			return i + 2, 0
		}
		return i + 1, bad(i + 1, .Bad_Escape, .None)
	case 'x':
		if !v11 {
			return i + 1, bad(i + 1, .Bad_Escape, .None)
		}
		count = 2
	case 'u':
		count = 4
	case 'U':
		count = 8
	case:
		return i + 1, bad(i + 1, .Bad_Escape, .None)
	}
	r, at, ok := hex_run(src, i + 2, count)
	if !ok {
		return at, bad(at, .Bad_Escape, .None) if at < len(src) else bad(at, .Truncated, .Open_String)
	}
	if r > 0x10ffff || r >= 0xd800 && r < 0xe000 {
		return i + 1, bad(i + 1, .Bad_Escape, .Bad_Codepoint)
	}
	return i + 2 + count, 0
}

// The count of bytes from `k` that a string closed by `quote` holds as they are, up to 16, and 0 within 16 bytes of the
// text's end: printable ASCII but `quote` and, in a basic string, `\`. A tab, which a string holds too, ends the run,
// and the scan judges it apart. A count below 16 stops at a byte of the text.
plain_run :: #force_inline proc "contextless" (src: []u8, k: int, $quote: u8) -> int #no_bounds_check {
	if k + 16 > len(src) {
		return 0
	}
	V :: #simd[16]u8
	v := intrinsics.unaligned_load((^V)(raw_data(src)[k:]))
	// `v - 0x20 > 0x5e` holds for a control byte, DEL and a byte past 0x7F.
	stops := simd.bit_or(simd.lanes_eq(v, V(quote)), simd.lanes_gt(v - 0x20, V(0x5e)))
	when quote == '"' {
		stops = simd.bit_or(stops, simd.lanes_eq(v, V('\\')))
	}
	return int(kernel.first_lane(stops))
}

// Scans a basic string whose opening quote is at `i`. Returns the byte past its closing quote.
scan_basic :: proc "contextless" (src: []u8, i: int, v11: bool) -> (end: int, v: Verdict) {
	k := i + 1
	for k < len(src) {
		run := plain_run(src, k, '"')
		k += run
		if run == 16 {
			continue
		}
		b := src[k]
		switch {
		case b == '"':
			return k + 1, 0
		case b == '\\':
			k, v = scan_escape(src, k, v11)
			if v != 0 {
				return k, v
			}
		case b >= 0x80:
			k, v = utf8_step(src, k)
			if v != 0 {
				return k, v
			}
		case plain_byte(b):
			k += 1
		case b == '\n' || b == '\r':
			return k, bad(k, .Bad_Char, .Line_End_In_String)
		case:
			return k, bad(k, .Bad_Char, .Control_Char)
		}
	}
	return k, bad(k, .Truncated, .Open_String)
}

// Scans a literal string whose opening quote is at `i`. Returns the byte past its closing quote.
scan_literal :: proc "contextless" (src: []u8, i: int) -> (end: int, v: Verdict) {
	k := i + 1
	for k < len(src) {
		run := plain_run(src, k, '\'')
		k += run
		if run == 16 {
			continue
		}
		b := src[k]
		switch {
		case b == '\'':
			return k + 1, 0
		case b >= 0x80:
			k, v = utf8_step(src, k)
			if v != 0 {
				return k, v
			}
		case plain_byte(b):
			k += 1
		case b == '\n' || b == '\r':
			return k, bad(k, .Bad_Char, .Line_End_In_String)
		case:
			return k, bad(k, .Bad_Char, .Control_Char)
		}
	}
	return k, bad(k, .Truncated, .Open_String)
}

// The length of the run of byte `q` at `i`.
quote_run :: #force_inline proc "contextless" (src: []u8, i: int, q: u8) -> int {
	k := i
	for k < len(src) && src[k] == q {
		k += 1
	}
	return k - i
}

// Judges the line end at `i`, LF or CR LF. Returns the byte past it, or the fault for a CR no LF follows.
line_end :: #force_inline proc "contextless" (src: []u8, i: int) -> (next: int, v: Verdict) {
	if src[i] == '\r' {
		if i + 1 < len(src) && src[i + 1] == '\n' {
			return i + 2, 0
		}
		return i, bad(i, .Bad_Char, .Lone_Cr)
	}
	return i + 1, 0
}

// Scans a multi-line string whose opening quotes are at `i`. A run of three to five quotes ends it, and the quotes
// before the last three belong to the text.
scan_multiline :: proc "contextless" (src: []u8, i: int, $LITERAL: bool, v11: bool) -> (end: int, v: Verdict) {
	q :: u8('\'') when LITERAL else u8('"')
	k := i + 3
	for k < len(src) {
		b := src[k]
		switch {
		case b == q:
			run := quote_run(src, k, q)
			if run >= 3 {
				if run > 5 {
					return k + 5, bad(k + 5, .Bad_Char, .Bad_Quotes)
				}
				return k + run, 0
			}
			k += run
		case b == '\\' && !LITERAL:
			// A backslash before a line end trims the white space and line ends after it.
			j := k + 1
			for j < len(src) && (src[j] == ' ' || src[j] == '\t') {
				j += 1
			}
			if j < len(src) && (src[j] == '\n' || src[j] == '\r') {
				k = j
				trim: for k < len(src) {
					switch src[k] {
					case ' ', '\t':
						k += 1
					case '\n', '\r':
						k, v = line_end(src, k)
						if v != 0 {
							return k, v
						}
					case:
						break trim
					}
				}
				continue
			}
			k, v = scan_escape(src, k, v11)
			if v != 0 {
				return k, v
			}
		case b >= 0x80:
			k, v = utf8_step(src, k)
			if v != 0 {
				return k, v
			}
		case plain_byte(b):
			k += 1
		case b == '\n' || b == '\r':
			k, v = line_end(src, k)
			if v != 0 {
				return k, v
			}
		case:
			return k, bad(k, .Bad_Char, .Control_Char)
		}
	}
	return k, bad(k, .Truncated, .Open_String)
}

// Writes the code point `r` as UTF-8 at `buf[w:]`. Returns the new length.
put_rune :: #force_inline proc "contextless" (buf: []u8, w: int, r: u32) -> int {
	switch {
	case r < 0x80:
		buf[w] = u8(r)
		return w + 1
	case r < 0x800:
		buf[w] = 0xc0 | u8(r >> 6)
		buf[w + 1] = 0x80 | u8(r & 0x3f)
		return w + 2
	case r < 0x10000:
		buf[w] = 0xe0 | u8(r >> 12)
		buf[w + 1] = 0x80 | u8(r >> 6 & 0x3f)
		buf[w + 2] = 0x80 | u8(r & 0x3f)
		return w + 3
	}
	buf[w] = 0xf0 | u8(r >> 18)
	buf[w + 1] = 0x80 | u8(r >> 12 & 0x3f)
	buf[w + 2] = 0x80 | u8(r >> 6 & 0x3f)
	buf[w + 3] = 0x80 | u8(r & 0x3f)
	return w + 4
}

// The text of a string or quoted key token whose span `s` holds its quotes, in `buf`, which is as long as the span at
// least. A bare key is its span.
decode :: proc "contextless" (s: []u8, spelling: u16, buf: []u8) -> (text: string, ok: bool) {
	if spelling & core.SPELLING_DECODE == 0 {
		return string(s), true
	}
	style := style_of(spelling)
	lo, hi := 1, len(s) - 1
	if style >= .Multiline {
		lo, hi = 3, len(s) - 3
		// The extra quotes the closing run holds are text, so the end is the span's.
		if lo < hi && s[lo] == '\n' {
			lo += 1
		} else if lo + 1 < hi && s[lo] == '\r' && s[lo + 1] == '\n' {
			lo += 2
		}
	}
	if len(buf) < hi - lo {
		return "", false
	}
	w := 0
	if style == .Literal || style == .Multiline_Literal {
		w = copy(buf, s[lo:hi])
		return string(buf[:w]), true
	}
	i := lo
	for i < hi {
		b := s[i]
		if b != '\\' {
			buf[w] = b
			w += 1
			i += 1
			continue
		}
		c := s[i + 1]
		i += 2
		r: u32
		switch c {
		case 'b':
			r = 8
		case 't':
			r = '\t'
		case 'n':
			r = '\n'
		case 'f':
			r = 12
		case 'r':
			r = '\r'
		case 'e':
			r = 0x1b
		case '"':
			r = '"'
		case '\\':
			r = '\\'
		case 'x', 'u', 'U':
			count := 2 if c == 'x' else 4 if c == 'u' else 8
			for k in 0 ..< count {
				r = r << 4 | u32(spell.HEX_NIBBLE[s[i + k]])
			}
			i += count
		case:
			// A backslash before a line end drops itself and the white space and line ends after it.
			for i < hi && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') {
				i += 1
			}
			continue
		}
		w = put_rune(buf, w, r)
	}
	return string(buf[:w]), true
}
