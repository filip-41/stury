// Seeded texts of each spec for the walk's tests: valid documents holding every token kind, escape and UTF-8 width,
// and `SHARP`, the bytes a mutation writes. In JSONC and JSON5 a document holds comments wherever whitespace may stand
// and sometimes a comma before a close bracket. In JSON5 it holds JSON5's numbers, strings, keys and whitespace.
package json_gen

import "core:math/rand"
import json "../.."
import walktest "../../../walktest"

// Writes a valid document of at most `depth` levels, with up to 3 whitespace runs between its tokens.
text :: proc(out: ^[dynamic]u8, depth: int, spec: json.Spec) {
	ws(out, spec)
	value(out, depth, spec)
	ws(out, spec)
}

// Writes a valid document of at most `depth` levels as a pretty printer lays it out: each member on its own line,
// indented by a step of 1 to 8 spaces per level, so indents run past the 32 the walk predicts.
pretty :: proc(out: ^[dynamic]u8, depth: int, spec: json.Spec) {
	pretty_value(out, depth, 0, 1 + rand.int_max(8), spec)
}

// Holds the bytes `walktest.mutate` writes: every byte the grammar branches on, and bytes no state accepts.
SHARP :: "\"'\\/*{}[]:,0123456789-+.eEtrufalsnINx$_ \t\r\n\v\xa0\xa8u\x00\x1f\x7f\x80\xbf\xc0\xc2\xe0\xe2\xed\xf0\xf4\xf5\xff"

@(private)
ws :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	for _ in 0 ..< rand.int_max(4) {
		if spec != .Json && rand.int_max(3) == 0 {
			comment(out, spec)
		} else if spec == .Json5 && rand.int_max(3) == 0 {
			append(out, rand.choice(WS5))
		} else {
			append(out, walktest.pick(" \t\r\n"))
		}
	}
}

// Holds JSON5's whitespace beyond JSON's: VT, FF, U+00A0, U+1680, U+2000, U+200A, U+2028, U+2029, U+202F, U+205F,
// U+3000 and U+FEFF.
@(private)
WS5 :: []string{"\v", "\f", "\u00a0", "\u1680", "\u2000", "\u200a", "\u2028", "\u2029", "\u202f", "\u205f", "\u3000", "\ufeff"}

// Writes a `//` comment and the line end after it, or a `/* */` comment that may span lines. A run of up to 149 `c`
// bytes puts it past the 64-byte blocks the readers load.
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
		// A `/` after `*` would close a block comment early, so a block comment writes no `/` piece.
		// JSON5 accepts any control byte in a comment, so only JSON and JSONC skip the control pieces.
		pieces := PIECES
		piece := rand.choice(pieces[:7 if spec != .Json5 else len(pieces)])
		append(out, piece if block || rand.int_max(3) != 0 else rand.choice([]string{"/", "//", "/*", "*/"}))
		if block && rand.int_max(6) == 0 {
			append(out, walktest.pick("\r\n"))
		}
	}
	ends := []string{"\n", "\r", "\r\n", "\u2028", "\u2029"}
	append(out, "*/" if block else rand.choice(ends[:3 if spec != .Json5 else 5]))
}

// Writes a comma before a close bracket in JSONC and JSON5 when the container holds a value, a third of the time.
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
		// A leaf chooses a scalar in 2 of 5 cases, an inner node in 2 of 7, which keeps documents small.
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
		// Sometimes a comment at the end of the previous line, and sometimes one on its own line above the member.
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

// Writes an object's key: a string, and in JSON5 an identifier half the time.
@(private)
key :: proc(out: ^[dynamic]u8, spec: json.Spec) {
	if spec != .Json5 || rand.int_max(2) == 0 {
		str(out, spec)
		return
	}
	// `START` holds one letter of each class an identifier may start with (Lu, Ll, Lt, Lm, Lo, Nl), `PART` a mark, digit
	// or connector it may continue with.
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
	// Holds JSON5's escapes, and the characters it accepts raw in a string.
	PIECES5 :: []string{"\\x4A", "\\0", "\\v", "\\q", "\\'", "\\\n", "\\\r\n", "\\\u2028", "\\é", "\t", "\x01", "\u2028", "\u2029"}
	quote: u8 = '"'
	if spec == .Json5 && rand.int_max(3) == 0 {
		quote = '\''
	}
	append(out, quote)
	// Sometimes a run of up to 149 `a` bytes, so a string crosses the 16- and 64-byte blocks the readers load.
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
		// In a single-quoted string `\"` is written as a bare `"`.
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
		append(out, walktest.pick("123456789"))
		digits(out)
	}
	if rand.int_max(3) == 0 {
		append(out, '.')
		append(out, walktest.pick("0123456789"))
		digits(out)
	}
	if rand.int_max(3) == 0 {
		append(out, walktest.pick("eE"))
		if rand.int_max(2) == 0 {
			append(out, walktest.pick("+-"))
		}
		// Up to 11 leading zeros make a long exponent with a small value, which the current tree caps.
		for _ in 0 ..< rand.int_max(12) {
			append(out, '0')
		}
		for _ in 0 ..< 1 + rand.int_max(3) {
			append(out, walktest.pick("0123456789"))
		}
	}
}

// Writes up to 19 more digits, which carries a run across the eight-byte words the number reader steps by.
@(private)
digits :: proc(out: ^[dynamic]u8) {
	for _ in 0 ..< rand.int_max(20) {
		append(out, walktest.pick("0123456789"))
	}
}

// Writes a number JSON does not: an optional sign, then a hexadecimal integer, `Infinity`, `NaN`, or a decimal with an
// empty integer or fraction part.
@(private)
num5 :: proc(out: ^[dynamic]u8) {
	if rand.int_max(2) == 0 {
		append(out, walktest.pick("+-"))
	}
	switch rand.int_max(5) {
	case 0:
		append(out, rand.choice([]string{"0x", "0X"}))
		for _ in 0 ..< 1 + rand.int_max(17) {
			append(out, walktest.pick("0123456789abcdefABCDEF"))
		}
	case 1:
		append(out, rand.choice([]string{"Infinity", "NaN"}))
	case 2:
		append(out, '.')
		append(out, walktest.pick("0123456789"))
		digits(out)
	case:
		append(out, walktest.pick("0123456789"))
		append(out, '.')
	}
	if rand.int_max(4) == 0 && out[len(out) - 1] - '0' < 10 || out[len(out) - 1] == '.' {
		append(out, walktest.pick("eE"))
		append(out, walktest.pick("123456789"))
	}
}
