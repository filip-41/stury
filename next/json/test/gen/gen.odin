// Seeded texts of each spec for the walk's tests: valid documents that touch every token, escape and UTF-8 width, and
// mutations of them that break at a random byte. In a spec with comments a document also holds them wherever
// whitespace may stand and now and then a comma before a close bracket, and in JSON5 its own numbers, strings, keys
// and whitespace.
package json_gen

import "core:math/rand"
import json "../.."

// A valid document of at most `depth` levels, with whitespace of every kind between its tokens.
text :: proc(out: ^[dynamic]u8, depth: int, spec: json.Spec) {
	ws(out, spec)
	value(out, depth, spec)
	ws(out, spec)
}

// A valid document of at most `depth` levels laid out as a pretty printer lays it out: each member on a line of its
// own, indented a step of 1 to 8 spaces per level, so indents run past the 32 the walk predicts.
pretty :: proc(out: ^[dynamic]u8, depth: int, spec: json.Spec) {
	pretty_value(out, depth, 0, 1 + rand.int_max(8), spec)
}

// `src` with one random edit: a byte replaced, deleted or inserted, or the text cut short.
mutate :: proc(out: ^[dynamic]u8, src: []u8) {
	clear(out)
	append(out, ..src)
	if len(src) == 0 {
		append(out, pick(SHARP))
		return
	}
	i := rand.int_max(len(src))
	switch rand.int_max(4) {
	case 0:
		out[i] = pick(SHARP)
	case 1:
		ordered_remove(out, i)
	case 2:
		inject_at(out, i, pick(SHARP))
	case:
		resize(out, i)
	}
}

// The bytes a mutation writes: every byte the grammar branches on, and bytes no state takes.
@(private)
SHARP :: "\"'\\/*{}[]:,0123456789-+.eEtrufalsnINx$_ \t\r\n\v\xa0\xa8u\x00\x1f\x7f\x80\xbf\xc0\xc2\xe0\xe2\xed\xf0\xf4\xf5\xff"

@(private)
pick :: proc(s: string) -> u8 {
	return s[rand.int_max(len(s))]
}

@(private)
ws :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	for _ in 0 ..< rand.int_max(4) {
		if spec != .Json && rand.int_max(3) == 0 {
			comment(out, spec)
		} else if spec == .Json5 && rand.int_max(3) == 0 {
			append(out, rand.choice(WS5))
		} else {
			append(out, pick(" \t\r\n"))
		}
	}
}

// JSON5's whitespace past JSON's: VT, FF, U+00A0, U+1680, U+2000, U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and
// U+FEFF.
@(private)
WS5 :: []string{"\v", "\f", "\u00a0", "\u1680", "\u2000", "\u200a", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000", "\ufeff"}

// A `//` comment and the line end after it, or a `/* */` comment across lines, either one of a few bytes or past the
// 64-byte blocks the readers load.
@(private)
comment :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	PIECES :: []string{"c", " ", "*", "\"", "é", "😀", "\t", "\x01", "\x7f"}
	block := rand.int_max(2) == 0
	append(out, "/*" if block else "//")
	for _ in 0 ..< rand.int_max(8) {
		if rand.int_max(8) == 0 {
			for _ in 0 ..< rand.int_max(150) {
				append(out, 'c')
			}
		}
		// A `/` that follows `*` would end a block comment early.
		// JSON5 takes any control byte in a comment.
		pieces := PIECES
		piece := rand.choice(pieces[:7 if spec != .Json5 else len(pieces)])
		append(out, piece if block || rand.int_max(3) != 0 else rand.choice([]string{"/", "//", "/*", "*/"}))
		if block && rand.int_max(6) == 0 {
			append(out, pick("\r\n"))
		}
	}
	ends := []string{"\n", "\r", "\r\n", "\u2028", "\u2029"}
	append(out, "*/" if block else rand.choice(ends[:3 if spec != .Json5 else 5]))
}

// A comma before the close bracket of a container that holds a value.
@(private)
trailing_comma :: proc(out: ^[dynamic]u8, n: int, spec: json.Spec) {
	if spec != .Json && n > 0 && rand.int_max(3) == 0 {
		append(out, ',')
		ws(out, spec)
	}
}

@(private)
value :: proc(out: ^[dynamic]u8, depth: int, spec: json.Spec) {
	switch rand.int_max(depth > 0 ? 7 : 5) {
	case 0:
		str(out, spec)
	case 1:
		num(out, spec)
	case 2:
		append(out, rand.choice([]string{"true", "false", "null"}))
	case 3, 4:
		// Scalars weigh more at the leaves, so documents stay small.
		if rand.int_max(2) == 0 {
			str(out, spec)
		} else {
			num(out, spec)
		}
	case 5:
		append(out, '[')
		n := rand.int_max(5)
		for i in 0 ..< n {
			if i > 0 {
				append(out, ',')
			}
			ws(out, spec)
			value(out, depth - 1, spec)
			ws(out, spec)
		}
		trailing_comma(out, n, spec)
		append(out, ']')
	case:
		append(out, '{')
		n := rand.int_max(5)
		for i in 0 ..< n {
			if i > 0 {
				append(out, ',')
			}
			ws(out, spec)
			key(out, spec)
			ws(out, spec)
			append(out, ':')
			ws(out, spec)
			value(out, depth - 1, spec)
			ws(out, spec)
		}
		trailing_comma(out, n, spec)
		append(out, '}')
	}
}

@(private)
pretty_value :: proc(out: ^[dynamic]u8, depth, indent, step: int, spec: json.Spec) {
	if depth == 0 || rand.int_max(4) == 0 {
		value(out, 0, spec)
		return
	}
	object := rand.int_max(2) == 0
	append(out, '{' if object else '[')
	n := rand.int_max(5)
	for i in 0 ..< n {
		if i > 0 {
			append(out, ',')
		}
		// A comment at the end of the line before the member and one on a line of its own above it.
		if spec != .Json && rand.int_max(3) == 0 {
			append(out, ' ')
			comment(out, spec)
		}
		line(out, indent + step)
		if spec != .Json && rand.int_max(3) == 0 {
			comment(out, spec)
			line(out, indent + step)
		}
		if object {
			key(out, spec)
			append(out, ": ")
		}
		pretty_value(out, depth - 1, indent + step, step, spec)
	}
	if spec != .Json && n > 0 && rand.int_max(3) == 0 {
		append(out, ',')
	}
	if n > 0 {
		line(out, indent)
	}
	append(out, '}' if object else ']')
}

@(private)
line :: proc(out: ^[dynamic]u8, indent: int) {
	append(out, '\n')
	for _ in 0 ..< indent {
		append(out, ' ')
	}
}

// An object's key: a string, and in JSON5 now and then an identifier.
@(private)
key :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	if spec != .Json5 || rand.int_max(2) == 0 {
		str(out, spec)
		return
	}
	// Letters of each class an identifier starts with (Lu, Ll, Lt, Lm, Lo, Nl), then the marks, digits and connectors
	// it may go on with.
	START :: []string{"a", "Z", "$", "_", "\\u0061", "é", "ǅ", "ʰ", "中", "Ⅻ"}
	PART :: []string{"0", "9", "\u0301", "\u0903", "٣", "‿", "\u200c", "\u200d", "\\u0030"}
	append(out, rand.choice(START))
	for _ in 0 ..< rand.int_max(6) {
		append(out, rand.choice(START) if rand.int_max(2) == 0 else rand.choice(PART))
	}
}

@(private)
str :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	PIECES :: []string{"a", "Z", "~", " ", "\\\"", "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t", "\\u00e9", "\\uFFFF", "\\ud83d\\ude00", "é", "中", "😀", "߿", "￿"}
	// JSON5's escapes and the characters it takes raw in a string.
	PIECES5 :: []string{"\\x4A", "\\0", "\\v", "\\q", "\\'", "\\\n", "\\\r\n", "\\\u2028", "\\é", "\t", "\x01", "\u2028", "\u2029"}
	quote: u8 = '"'
	if spec == .Json5 && rand.int_max(3) == 0 {
		quote = '\''
	}
	append(out, quote)
	// Now and then a run of plain bytes, so strings cross the 16- and 64-byte blocks the readers load.
	for _ in 0 ..< rand.int_max(12) {
		if rand.int_max(8) == 0 {
			for _ in 0 ..< rand.int_max(150) {
				append(out, 'a')
			}
		}
		piece := rand.choice(PIECES)
		if spec == .Json5 && rand.int_max(3) == 0 {
			piece = rand.choice(PIECES5)
		}
		// A quote of the other kind stands for itself.
		if piece == "\\\"" && quote == '\'' {
			piece = "\""
		}
		append(out, piece)
	}
	append(out, quote)
}

@(private)
num :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	if spec == .Json5 && rand.int_max(3) == 0 {
		num5(out)
		return
	}
	if rand.int_max(3) == 0 {
		append(out, '-')
	}
	if rand.int_max(4) == 0 {
		append(out, '0')
	} else {
		append(out, pick("123456789"))
		digits(out)
	}
	if rand.int_max(3) == 0 {
		append(out, '.')
		append(out, pick("0123456789"))
		digits(out)
	}
	if rand.int_max(3) == 0 {
		append(out, pick("eE"))
		if rand.int_max(2) == 0 {
			append(out, pick("+-"))
		}
		// Leading zeros make a long run with a small value: the current tree caps an exponent's value.
		for _ in 0 ..< rand.int_max(12) {
			append(out, '0')
		}
		for _ in 0 ..< 1 + rand.int_max(3) {
			append(out, pick("0123456789"))
		}
	}
}

// Up to 19 more digits, so a run crosses the eight-byte words the number reader steps by.
@(private)
digits :: proc(out: ^[dynamic]u8) {
	for _ in 0 ..< rand.int_max(20) {
		append(out, pick("0123456789"))
	}
}

// A number JSON does not write: a sign of either kind, then a hexadecimal integer, `Infinity`, `NaN`, or a decimal
// with an empty integer or fraction part.
@(private)
num5 :: proc(out: ^[dynamic]u8) {
	if rand.int_max(2) == 0 {
		append(out, pick("+-"))
	}
	switch rand.int_max(5) {
	case 0:
		append(out, rand.choice([]string{"0x", "0X"}))
		for _ in 0 ..< 1 + rand.int_max(17) {
			append(out, pick("0123456789abcdefABCDEF"))
		}
	case 1:
		append(out, rand.choice([]string{"Infinity", "NaN"}))
	case 2:
		append(out, '.')
		append(out, pick("0123456789"))
		digits(out)
	case:
		append(out, pick("0123456789"))
		append(out, '.')
	}
	if rand.int_max(4) == 0 && out[len(out) - 1] - '0' < 10 || out[len(out) - 1] == '.' {
		append(out, pick("eE"))
		append(out, pick("123456789"))
	}
}
