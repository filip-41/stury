package core

// The double of a number and the digits it keeps, from a value or a number's text.

import "core:strconv"
import "core:strings"
import "spell"

// The room `double_of` needs in `buf` to give a prefixed integer's digits: a sign and the 39 digits of 2^128 - 1.
HEX_ROOM :: 40

// The double of number `v` and the digits it keeps: a `Number_View`'s or a number node's text, none for a double or a
// number whose text is no decimal. A decimal a format spells with a sign, a point of its own, leading zeros or
// underscores (`+1e400`, `.5`, `1_000`) keeps the JSON number it spells, written in `buf` when that holds the text and
// one byte more, and else its text, or none when the text holds an underscore. A hex, octal or binary integer of any
// size (`0x10`, `0o17`) keeps its decimal digits in `buf` when that holds them, and has none without room. A number of a
// format whose span is not its text, which has a `number_text`, keeps the digits that spells when they lie in the
// source or `buf` holds them, and is its double otherwise.
double_of :: proc(v: Value, buf: []u8 = nil) -> (f: f64, digits: string, ok: bool) {
	#partial switch x in plain(v) {
	case f64:
		return x, "", true
	case Number_View:
		return view_f64(x), view_text(x), true
	case Node_Ref:
		if int(x.node) >= len(x.doc.nodes) {
			return 0, "", false
		}
		node := x.doc.nodes[x.node]
		if node.kind != .Number && doc_kind(x.doc, x.node) != .Number {
			return 0, "", false
		}
		if x.doc.readers.number_text != nil {
			return spelled_double(x.doc, x.node, buf)
		}
		text := string(span(x.doc, x.node))
		n, _ := doc_number(x.doc, x.node)
		f = number_f64(n, text)
		// The `NUMBER_*` layout holds only for a `.Number` token.
		kind := node.spelling & NUMBER_KIND_MASK if node.kind == .Number else 0
		switch {
		case kind == NUMBER_DECIMAL:
			if json, fits := json_decimal(text, buf); fits {
				return f, json, true
			}
			return f, "" if strings.index_byte(text, '_') >= 0 else text, true
		case kind > NUMBER_DECIMAL:
			decimal, _ := prefixed_decimal(text, buf)
			return f, decimal, true
		}
		return f, text, true
	}
	return 0, "", false
}

// The room in which `spelled_double` reads a number's digits before it grows: every format's integer, float and hex
// integer fits.
@(private = "file")
SPELLED_ROOM :: 64

// The most digits `spelled_double` reads to round a number no binary64 holds.
@(private = "file")
SPELLED_MAX :: 1 << 26

// Whether `s` lies in the source text of `doc`.
@(private)
lies_in_source :: proc(doc: ^Document, s: string) -> bool {
	lo, at := uintptr(raw_data(doc.src)), uintptr(raw_data(s))
	return at >= lo && at + uintptr(len(s)) <= lo + uintptr(len(doc.src))
}

// `double_of` of number node `i` of a document whose format spells its digits with `number_text`. The digits are kept
// when they are a decimal that lies in the source or fits `buf`. A number too wide for binary64 is rounded from its
// digits, read into the temp allocator past `SPELLED_ROOM` bytes, and `ok` is false when they cannot be read.
@(private = "file")
spelled_double :: proc(doc: ^Document, i: Node_Index, buf: []u8) -> (f: f64, digits: string, ok: bool) {
	n, _ := doc_number(doc, i)
	room: [SPELLED_ROOM]u8
	text, fit := doc_number_text(doc, i, room[:])
	for size := 4 * SPELLED_ROOM; !fit && n.kind == .Wide && size <= SPELLED_MAX; size *= 4 {
		grown, err := make([]u8, size, context.temp_allocator)
		if err != nil {
			return 0, "", false
		}
		text, fit = doc_number_text(doc, i, grown)
	}
	if !fit || len(text) == 0 {
		// An integer or a binary64 is its bits, and a number with no digits is the infinity or NaN its bits hold.
		return number_f64(n, "0"), "", n.kind != .Wide
	}
	f = number_f64(n, text)
	if c := text[1] if text[0] == '-' && len(text) > 1 else text[0]; c < '0' || c > '9' {
		return f, "", true
	}
	switch {
	case lies_in_source(doc, text):
		digits = text
	case len(text) <= len(buf):
		digits = string(buf[:copy(buf, text)])
	}
	return f, digits, true
}

// The decimal digits of the hex, octal or binary integer `text`, `0x`, `0o` or `0b` and digits an underscore may
// separate, with a sign when it is negative and not zero, written at the end of `buf`, which needs about 1.21 bytes per
// digit and two more. `ok` is false for any other text, when `buf` is too small and when the work words cannot be held.
prefixed_decimal :: proc(text: string, buf: []u8) -> (digits: string, ok: bool) {
	WORD :: 1_000_000_000
	s, neg := text, false
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		neg, s = s[0] == '-', s[1:]
	}
	if len(s) < 3 || s[0] != '0' {
		return
	}
	base: u64
	switch s[1] | 0x20 {
	case 'x': base = 16
	case 'o': base = 8
	case 'b': base = 2
	case: return
	}
	// Least significant word first, each word nine decimal digits.
	stack: [16]u32
	words := stack[:]
	if len(s) / 7 + 1 > len(stack) {
		made, err := make([]u32, len(s) / 7 + 1)
		if err != nil {
			return
		}
		words = made
	}
	defer if raw_data(words) != raw_data(stack[:]) {
		delete(words)
	}
	n := 0
	for c in transmute([]u8)s[2:] {
		if c == '_' {
			continue
		}
		d := u64(spell.HEX_NIBBLE[c])
		if d >= base {
			return
		}
		for &w in words[:n] {
			x := u64(w) * base + d
			w, d = u32(x % WORD), x / WORD
		}
		if d > 0 {
			words[n] = u32(d)
			n += 1
		}
	}
	at := len(buf)
	for k in 0 ..< n {
		w := words[k]
		for _ in 0 ..< 9 {
			if k + 1 == n && w == 0 {
				break
			}
			if at == 0 {
				return
			}
			at -= 1
			buf[at], w = u8('0' + w % 10), w / 10
		}
	}
	if n == 0 || neg {
		if at == 0 {
			return
		}
		at -= 1
		buf[at] = '0' if n == 0 else '-'
	}
	return string(buf[at:]), true
}

// The JSON number that `lit`, a decimal a format spells with a sign, a point of its own, leading zeros or underscores,
// spells, written in `buf`: `+1` as `1`, `.5` as `0.5`, `5.` as `5.0`, `007` as `7`, `1_0` as `10`, and `-0` as `0` when
// it is an integer. `ok` is false when `buf` holds fewer bytes than `lit` and one more.
json_decimal :: proc(lit: string, buf: []u8) -> (json: string, ok: bool) {
	if len(lit) == 0 || len(buf) <= len(lit) {
		return
	}
	n := 0
	p := 1 if lit[0] == '+' || lit[0] == '-' else 0
	if lit[0] == '-' && !integer_zero(lit[p:]) {
		buf[n] = '-'
		n += 1
	}
	if p < len(lit) && lit[p] == '.' {
		buf[n] = '0'
		n += 1
	}
	leading := true
	for k in p ..< len(lit) {
		if lit[k] == '_' {
			continue
		}
		// A zero is leading while a digit follows it, past any underscores.
		next := k + 1
		for next < len(lit) && lit[next] == '_' {
			next += 1
		}
		if leading && lit[k] == '0' && next < len(lit) && lit[next] - '0' < 10 {
			continue
		}
		leading = false
		buf[n] = lit[k]
		n += 1
		// A point with no digit after it still makes a float, so it keeps a zero.
		if lit[k] == '.' && (k + 1 == len(lit) || lit[k + 1] - '0' >= 10) {
			buf[n] = '0'
			n += 1
		}
	}
	return string(buf[:n]), true
}

// Whether `digits` is an integer zero: zeros and underscores, which a sign does not make negative.
@(private = "file")
integer_zero :: proc(digits: string) -> bool {
	for c in transmute([]u8)digits {
		if c != '0' && c != '_' {
			return false
		}
	}
	return len(digits) > 0
}

// The binary64 of `n`, a number spelled `text`.
number_f64 :: proc(n: Number, text: string) -> f64 {
	switch n.kind {
	case .Int:
		// `-0` is an integer whose bits carry no sign
		return -0.0 if n.bits == 0 && text[0] == '-' else f64(i64(n.bits))
	case .Uint:
		return f64(n.bits)
	case .Float:
		return transmute(f64)n.bits
	case .Wide:
	}
	// past binary64's digits or range, `1e400` among them, which strconv reads as infinity
	f, _ := strconv.parse_f64(text)
	return f
}

// The double of `text`, a JSON number.
text_f64 :: proc(text: string) -> f64 {
	// A number of at most 15 digits and no exponent, a program's `1` or `2.5` mostly, is read here, as arithmetic reads
	// a literal at each use: its digits and a power of ten are exact doubles, so one division rounds it correctly.
	if len(text) <= 17 {
		s := text
		neg := len(s) > 0 && s[0] == '-'
		if neg {
			s = s[1:]
		}
		m: u64
		point := -1
		for c, i in transmute([]byte)s {
			switch {
			case '0' <= c && c <= '9':
				m = m * 10 + u64(c - '0')
			case c == '.' && point < 0:
				point = i
			case:
				return text_f64_slow(text)
			}
		}
		if len(s) - int(point >= 0) > 15 {
			return text_f64_slow(text)
		}
		f := f64(m)
		if point >= 0 {
			f /= POW10_EXACT[len(s) - 1 - point]
		}
		return -f if neg else f
	}
	return text_f64_slow(text)
}

@(private = "file", rodata)
POW10_EXACT := [16]f64{1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15}

@(private = "file")
text_f64_slow :: #force_no_inline proc(text: string) -> f64 {
	n, _ := spell.number_strict(transmute([]byte)text, 0, u64(len(text)))
	return number_f64(n, text)
}
