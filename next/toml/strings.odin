package toml

import "core:simd"
import "core:unicode/utf8"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The strings, keys and comments of a TOML text: their scanners, which judge every byte, and the decoding of their
// text. A string's or quoted key's span holds its text without its quotes, and a multi-line string's without the line
// end right after its opening quotes, which `bounds` gives back.

// How a string or quoted key is written, in bits 11 and 12 of its spelling, which also has `SPELLING_QUOTED`. A bare
// key has neither.
@(private)
Style :: enum u8 {
	Basic,
	Literal,
	Multiline,
	Multiline_Literal,
}

@(private)
STYLE_SHIFT :: 11

#assert(1 << STYLE_SHIFT > tape.SPELLING_CREDIT && u32(max(Style)) << STYLE_SHIFT < 1 << DATE_SHIFT)

// The spelling of a quoted text of `style`, with `SPELLING_DECODE` when its text is not its bytes.
@(private)
string_spelling :: #force_inline proc "contextless" (style: Style, decodes: bool) -> u16 {
	return tape.SPELLING_QUOTED | u16(style) << STYLE_SHIFT | (tape.SPELLING_DECODE if decodes else 0)
}

@(private)
style_of :: #force_inline proc "contextless" (spelling: u16) -> Style {
	return Style(spelling >> STYLE_SHIFT & 3)
}

// Whether `b` is a byte a string or comment may hold as it is: not a control character other than tab, and not DEL.
@(private)
plain_byte :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= 0x20 && b != 0x7f || b == '\t'
}

// Steps over the UTF-8 character at `i`, whose lead is at least 0x80. Returns the byte past it, or the fault.
@(private)
utf8_step :: #force_inline proc "contextless" (src: []u8, i: int) -> (next: int, v: Verdict) {
	base := raw_data(src)
	q, kind := spell.utf8_char(base[i:], base[len(src):])
	#partial switch kind {
	case .None:
		return int(uintptr(q) - uintptr(base)), 0
	case .Truncated:
		return len(src), bad(len(src), .Truncated, .Cut_Utf8)
	}
	return i, bad(i, .Bad_Char, .Invalid_Utf8)
}

// Scans a comment whose `#` is at `i`. Returns the first byte past its text, the line end, or the fault.
@(private)
scan_comment :: proc "contextless" (src: []u8, i: int) -> (end: int, v: Verdict) #no_bounds_check {
	k := i + 1
	for k < len(src) {
		run := plain_run(src, k, 0)
		k += run
		if run == 16 {
			continue
		}
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

// The value of the `count` hex digits at `i`, false at the first byte that is none, which `at` names.
@(private)
hex_run :: #force_inline proc "contextless" (src: []u8, i, count: int) -> (r: u32, at: int, ok: bool) #no_bounds_check {
	for k in i ..< i + count {
		if k >= len(src) {
			return 0, k, false
		}
		d := spell.HEX_NIBBLE[src[k]]
		if d == 0xff {
			return 0, k, false
		}
		r = r << 4 | u32(d)
	}
	return r, i + count, true
}

// Judges the escape whose backslash is at `i` in a basic string. Returns the byte past it.
@(private)
scan_escape :: proc "contextless" (src: []u8, i: int, v11: bool) -> (next: int, v: Verdict) #no_bounds_check {
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
@(private)
plain_run :: #force_inline proc "contextless" (src: []u8, k: int, $quote: u8) -> int #no_bounds_check {
	if k + 16 > len(src) {
		return 0
	}
	V :: #simd[16]u8
	v := kernel.load16(raw_data(src)[k:])
	stops := simd.bit_or(simd.lanes_eq(v, V(quote)), kernel.control_or_high16(v, true))
	when quote == '"' {
		stops = simd.bit_or(stops, simd.lanes_eq(v, V('\\')))
	}
	return int(kernel.first_lane16(stops))
}

// Scans a string on one line whose opening quote is at `i`, a literal one under `LITERAL` and else a basic one.
// Returns the byte past its closing quote and whether it holds an escape, which a literal string has none of.
@(private)
scan_string :: proc "contextless" (src: []u8, i: int, v11: bool, $LITERAL: bool) -> (end: int, escaped: bool, v: Verdict) #no_bounds_check {
	Q :: u8('\'') when LITERAL else u8('"')
	k := i + 1
	for k < len(src) {
		run := plain_run(src, k, Q)
		k += run
		if run == 16 {
			continue
		}
		if src[k] == Q {
			return k + 1, escaped, 0
		}
		again: bool
		k, again, v = string_step(src, k, v11, LITERAL)
		escaped ||= again
		if v != 0 {
			return k, escaped, v
		}
	}
	return k, escaped, bad(k, .Truncated, .Open_String)
}

// Judges the byte at `k` of a string on one line, which is no closing quote and which a run of plain bytes stopped at,
// or a text's last bytes. Returns the byte past it, and whether it began an escape, which a literal string reads as a
// plain byte.
@(private)
string_step :: #force_no_inline proc "contextless" (src: []u8, k: int, v11: bool, $LITERAL: bool) -> (next: int, escaped: bool, v: Verdict) #no_bounds_check {
	b := src[k]
	switch {
	case b == '\\' && !LITERAL:
		next, v = scan_escape(src, k, v11)
		return next, true, v
	case b >= 0x80:
		next, v = utf8_step(src, k)
		return next, false, v
	case plain_byte(b):
		return k + 1, false, 0
	case b == '\n' || b == '\r':
		return k, false, bad(k, .Bad_Char, .Line_End_In_String)
	}
	return k, false, bad(k, .Bad_Char, .Control_Char)
}

// The length of the run of byte `q` at `i`.
@(private)
quote_run :: #force_inline proc "contextless" (src: []u8, i: int, q: u8) -> int {
	k := i
	for k < len(src) && src[k] == q {
		k += 1
	}
	return k - i
}

// Judges the line end at `i`, LF or CR LF. Returns the byte past it, or the fault for a CR no LF follows.
@(private)
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
// before the last three belong to the text. Returns the byte past it and whether it holds a backslash.
@(private)
scan_multiline :: proc "contextless" (src: []u8, i: int, $LITERAL: bool, v11: bool) -> (end: int, escaped: bool, v: Verdict) {
	q :: u8('\'') when LITERAL else u8('"')
	k := i + 3
	for k < len(src) {
		b := src[k]
		switch {
		case b == q:
			run := quote_run(src, k, q)
			if run >= 3 {
				if run > 5 {
					return k + 5, escaped, bad(k + 5, .Bad_Char, .Bad_Quotes)
				}
				return k + run, escaped, 0
			}
			k += run
		case b == '\\' && !LITERAL:
			escaped = true
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
							return k, escaped, v
						}
					case:
						break trim
					}
				}
				continue
			}
			k, v = scan_escape(src, k, v11)
			if v != 0 {
				return k, escaped, v
			}
		case b >= 0x80:
			k, v = utf8_step(src, k)
			if v != 0 {
				return k, escaped, v
			}
		case plain_byte(b):
			k += 1
		case b == '\n' || b == '\r':
			k, v = line_end(src, k)
			if v != 0 {
				return k, escaped, v
			}
		case:
			return k, escaped, bad(k, .Bad_Char, .Control_Char)
		}
	}
	return k, escaped, bad(k, .Truncated, .Open_String)
}

// The span of the text of the string whose quotes run from `lo` to `end`: past its opening quotes and, for a multi-line
// string, the line end right after them, and before its closing quotes.
@(private)
string_text :: #force_inline proc "contextless" (src: []u8, lo, end: int, multi: bool) -> (text_lo, text_hi: int) #no_bounds_check {
	if !multi {
		return lo + 1, end - 1
	}
	text_lo, text_hi = lo + 3, end - 3
	if text_lo < text_hi && src[text_lo] == '\n' {
		text_lo += 1
	} else if text_lo + 1 < text_hi && src[text_lo] == '\r' && src[text_lo + 1] == '\n' {
		text_lo += 2
	}
	return
}

// The quote bytes before and after the span of string or quoted key `t`, and before them a multi-line string's line
// end that its text leaves out. A bare key and a date-time have none.
@(private)
bounds :: proc "contextless" (src: []u8, t: tape.Token) -> (head, tail: u8) #no_bounds_check {
	if t.kind != .String || t.spelling & tape.SPELLING_QUOTED == 0 {
		return 0, 0
	}
	if style_of(t.spelling) < .Multiline {
		return 1, 1
	}
	head = 3
	if src[t.lo - 1] == '\n' {
		head += 1 + u8(src[t.lo - 2] == '\r')
	}
	return head, 3
}

// The code point of the escape whose backslash is at `i` of `s`, which a scan judged, and the byte past it, or false
// for a backslash before a line end, which spells nothing and whose white space and line ends end at `next`.
@(private)
escape_at :: #force_inline proc "contextless" (s: []u8, i, hi: int) -> (r: rune, next: int, spells: bool) {
	c := s[i + 1]
	switch c {
	case 'b':
		return 8, i + 2, true
	case 't':
		return '\t', i + 2, true
	case 'n':
		return '\n', i + 2, true
	case 'f':
		return 12, i + 2, true
	case 'r':
		return '\r', i + 2, true
	case 'e':
		return 0x1b, i + 2, true
	case '"':
		return '"', i + 2, true
	case '\\':
		return '\\', i + 2, true
	case 'x', 'u', 'U':
		count := 2 if c == 'x' else 4 if c == 'u' else 8
		u, _, _ := hex_run(s, i + 2, count)
		return rune(u), i + 2 + count, true
	}
	k := i + 1
	for k < hi && kernel.is_ws(s[k]) {
		k += 1
	}
	return 0, k, false
}

// The text of string or key node `t` of `src`, whose spelling has `SPELLING_DECODE`, in `buf`. An escape decodes to
// fewer bytes than it spells, so a `buf` as long as the span holds it.
@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, _: ^tape.Format_Ext) -> (s: string, ok: bool) {
	lo, hi := int(t.lo), int(t.lo) + int(t.n)
	if len(buf) < hi - lo {
		return "", false
	}
	w := 0
	i := lo
	for i < hi {
		k := kernel.index_byte(src[i:hi], '\\')
		if k < 0 {
			w += copy(buf[w:], src[i:hi])
			break
		}
		w += copy(buf[w:], src[i:i + k])
		r, next, spells := escape_at(src, i + k, hi)
		i = next
		if spells {
			b, n := utf8.encode_rune(r)
			w += copy(buf[w:], b[:n])
		}
	}
	return string(buf[:w]), true
}

// The bytes of a buffer that hold the text of scalar `t`: its span, as no escape decodes to more bytes than it spells.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int {
	return int(t.n)
}

// The read position in the text a string or key token reads as, for `text_byte`.
@(private)
Text_Reader :: struct {
	src:    []u8,
	p, end: int,
	decode: bool,
	one:    [4]u8, // the bytes of the escape last decoded
	at, n:  int,
}

@(private)
text_reader :: #force_inline proc "contextless" (src: []u8, t: tape.Token) -> Text_Reader {
	return {src = src, p = int(t.lo), end = int(t.lo) + int(t.n), decode = t.spelling & tape.SPELLING_DECODE != 0}
}

// The next byte of the text `r` reads, false at its end.
@(private)
text_byte :: proc "contextless" (r: ^Text_Reader) -> (b: u8, more: bool) {
	for {
		if r.at < r.n {
			r.at += 1
			return r.one[r.at - 1], true
		}
		if r.p >= r.end {
			return 0, false
		}
		c := r.src[r.p]
		if !r.decode || c != '\\' {
			r.p += 1
			return c, true
		}
		e, next, spells := escape_at(r.src, r.p, r.end)
		r.p = next
		if spells {
			r.one, r.n = utf8.encode_rune(e)
			r.at = 0
		}
	}
}

// Whether scalar `t` of `src` and scalar `o` of `other` read as the same text.
@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	if (t.spelling | o.spelling) & tape.SPELLING_DECODE == 0 {
		return string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
	}
	a, b := text_reader(src, t), text_reader(other, o)
	for {
		x, more := text_byte(&a)
		y, other_more := text_byte(&b)
		if more != other_more || x != y {
			return false
		}
		if !more {
			return true
		}
	}
}

// `tape.text_hash` of the text scalar `t` of `src` reads as, decoding an escape at a time.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	if t.spelling & tape.SPELLING_DECODE == 0 {
		return tape.text_hash(src[t.lo:][:t.n])
	}
	x := tape.text_hasher()
	r := text_reader(src, t)
	for {
		b, more := text_byte(&r)
		if !more {
			return tape.text_hasher_end(&x)
		}
		tape.text_hash_byte(&x, b)
	}
}
