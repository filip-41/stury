// Seeded JSON texts for the walk's tests: valid documents that touch every token, escape and UTF-8 width, and
// mutations of them that break at a random byte.
package json_gen

import "core:math/rand"

// A valid document of at most `depth` levels, with whitespace of every kind between its tokens.
text :: proc(out: ^[dynamic]u8, depth: int) {
	ws(out)
	value(out, depth)
	ws(out)
}

// A valid document of at most `depth` levels laid out as a pretty printer lays it out: each member on a line of its
// own, indented a step of 1 to 8 spaces per level, so indents run past the 32 the walk predicts.
pretty :: proc(out: ^[dynamic]u8, depth: int) {
	pretty_value(out, depth, 0, 1 + rand.int_max(8))
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
SHARP :: "\"\\/{}[]:,0123456789-+.eEtrufalsn \t\r\nxu\x00\x1f\x7f\x80\xbf\xc0\xc2\xe0\xed\xf0\xf4\xf5\xff"

@(private)
pick :: proc(s: string) -> u8 {
	return s[rand.int_max(len(s))]
}

@(private)
ws :: proc(out: ^[dynamic]u8) {
	for _ in 0 ..< rand.int_max(4) {
		append(out, pick(" \t\r\n"))
	}
}

@(private)
value :: proc(out: ^[dynamic]u8, depth: int) {
	switch rand.int_max(depth > 0 ? 7 : 5) {
	case 0:
		str(out)
	case 1:
		num(out)
	case 2:
		append(out, rand.choice([]string{"true", "false", "null"}))
	case 3, 4:
		// Scalars weigh more at the leaves, so documents stay small.
		if rand.int_max(2) == 0 {
			str(out)
		} else {
			num(out)
		}
	case 5:
		append(out, '[')
		for i in 0 ..< rand.int_max(5) {
			if i > 0 {
				append(out, ',')
			}
			ws(out)
			value(out, depth - 1)
			ws(out)
		}
		append(out, ']')
	case:
		append(out, '{')
		for i in 0 ..< rand.int_max(5) {
			if i > 0 {
				append(out, ',')
			}
			ws(out)
			str(out)
			ws(out)
			append(out, ':')
			ws(out)
			value(out, depth - 1)
			ws(out)
		}
		append(out, '}')
	}
}

@(private)
pretty_value :: proc(out: ^[dynamic]u8, depth, indent, step: int) {
	if depth == 0 || rand.int_max(4) == 0 {
		value(out, 0)
		return
	}
	object := rand.int_max(2) == 0
	append(out, '{' if object else '[')
	n := rand.int_max(5)
	for i in 0 ..< n {
		if i > 0 {
			append(out, ',')
		}
		line(out, indent + step)
		if object {
			str(out)
			append(out, ": ")
		}
		pretty_value(out, depth - 1, indent + step, step)
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

@(private)
str :: proc(out: ^[dynamic]u8) {
	PIECES :: []string{"a", "Z", "~", " ", "\\\"", "\\\\", "\\/", "\\b", "\\f", "\\n", "\\r", "\\t", "\\u00e9", "\\uFFFF", "\\ud83d\\ude00", "é", "中", "😀", "߿", "￿"}
	append(out, '"')
	// Now and then a run of plain bytes, so strings cross the 16- and 64-byte blocks the readers load.
	for _ in 0 ..< rand.int_max(12) {
		if rand.int_max(8) == 0 {
			for _ in 0 ..< rand.int_max(150) {
				append(out, 'a')
			}
		}
		append(out, rand.choice(PIECES))
	}
	append(out, '"')
}

@(private)
num :: proc(out: ^[dynamic]u8) {
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
