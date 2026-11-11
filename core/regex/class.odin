#+private
package regex

// Bracket classes, the character properties they hold, and the POSIX classes inside them.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A bracket class, or one of the escapes \w \d \s \p{...} as a class of one type.
Class :: struct {
	ranges:  [dynamic][2]rune,
	props:   [dynamic]Prop_Item,
	negated: bool,
	fold:    bool,
	ascii:   [2]u64, // the answer for each ASCII rune, filled in by the compiler
}

@(private, rodata)
LINE_TERMINATORS := [?][2]rune{{'\n', '\n'}, {'\r', '\r'}, {0x2028, 0x2029}}
@(private = "file", rodata)
ECMA_DIGIT := [?][2]rune{{'0', '9'}}
@(private = "file", rodata)
ECMA_WORD := [?][2]rune{{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}}
// White space and line terminators: U+0085 is not one, U+FEFF is.
@(private = "file", rodata)
ECMA_SPACE := [?][2]rune {
	{9, 13}, {' ', ' '}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200A}, {0x2028, 0x2029}, {0x202F, 0x202F},
	{0x205F, 0x205F}, {0x3000, 0x3000}, {0xFEFF, 0xFEFF},
}

// ECMA's \d \w \s, which do not read Unicode, and whether the capital letter negates them.
@(private)
escape_set :: proc(c: byte) -> ([][2]rune, bool) {
	switch c | 0x20 {
	case 'd':
		return ECMA_DIGIT[:], c == 'D'
	case 'w':
		return ECMA_WORD[:], c == 'W'
	}
	return ECMA_SPACE[:], c == 'S'
}

@(private)
class_node :: proc(ranges: [][2]rune, negated: bool) -> ^Node {
	n := new_node(.Class)
	n.class = new(Class)
	n.class.negated = negated
	append(&n.class.ranges, ..ranges)
	return n
}

@(private)
escape_prop :: proc(c: byte) -> Prop_Item {
	switch c {
	case 'w', 'W':
		return {table = TABLE_WORD, neg = c == 'W'}
	case 'd', 'D':
		return {table = TABLE_DIGIT, neg = c == 'D'}
	}
	return {table = TABLE_SPACE, neg = c == 'S'}
}

// At `{` after \p or \P, which under ECMA must be there.
@(private)
parse_property :: proc(p: ^Parser, neg: bool) -> (Prop_Item, bool) {
	end := strings.index_byte(p.src[p.i:], '}')
	if p.flags.ecma && (peek(p) != '{' || end < 0) {
		fail(p, "invalid character property name")
		return {}, false
	}
	if end < 0 {
		fail(p, "end pattern with unmatched parenthesis")
		return {}, false
	}
	name := p.src[p.i + 1:p.i + end]
	p.i += end + 1
	inner := name
	caret := !p.flags.ecma && strings.has_prefix(name, "^")
	if caret {
		inner = name[1:]
	}
	lookup := ecma_prop if p.flags.ecma else named_prop
	it, ok := lookup(inner)
	if !ok {
		fail(p, strings.concatenate({"invalid character property name {", name, "}"}))
		return {}, false
	}
	it.neg = neg != caret
	return it, true
}

// At `[`: a bracket class. Classes do not nest and `&&` is literal, as under ONIG_SYNTAX_PERL_NT and ECMA's `u`.
@(private)
parse_class :: proc(p: ^Parser) -> ^Node {
	p.i += 1
	n := new_node(.Class)
	cls := new(Class)
	n.class = cls
	cls.fold = p.flags.fold
	if peek(p) == '^' && !at_end(p) {
		cls.negated = true
		p.i += 1
	}
	// A `]` first is a character, which may start a range (`[]-a]`), but under ECMA ends an empty class.
	leading := peek(p) == ']' && !at_end(p) && !p.flags.ecma
	if leading && strings.index_byte(p.src[p.i + 1:], ']') < 0 {
		return fail(p, "empty char-class")
	}
	for {
		if at_end(p) {
			return fail(p, "premature end of char-class")
		}
		c := peek(p)
		if c == ']' && !leading {
			p.i += 1
			return n
		}
		leading = false
		lo, is_set, lo_lone, ok := class_item(p, cls)
		ranged := peek(p) == '-' && p.i + 1 < len(p.src) && peek(p, 1) != ']'
		if !ok {
			return nil
		}
		if is_set && ranged && p.flags.ecma {
			return fail(p, "char-class value at end of range")
		}
		if is_set {
			continue
		}
		hi, hi_lone := lo, lo_lone
		if ranged {
			p.i += 1
			hi_r, hi_set, hi_r_lone, hi_ok := class_item(p, cls)
			if !hi_ok {
				return nil
			}
			if hi_set {
				return fail(p, "char-class value at end of range")
			}
			if hi_r < lo {
				return fail(p, "empty range in char class")
			}
			hi, hi_lone = hi_r, hi_r_lone
		} else if peek(p) == '-' && p.i + 1 >= len(p.src) {
			return fail(p, "premature end of char-class")
		}
		// A lone byte is a range's end against a character past ASCII (`[\x80-\x{10ffff}]`), as Oniguruma reads it,
		// with ASCII or another lone byte it is a byte, which no character of the text is.
		if (lo_lone || hi_lone) && (lo_lone || lo < 0x80) && (hi_lone || hi < 0x80) {
			hi = min(hi, 0x7F)
		}
		if lo <= hi {
			append(&cls.ranges, [2]rune{lo, hi})
		}
	}
}

// At `[:`: a POSIX bracket `[:name:]` or `[:^name:]`. Not one when no `:]` closes a plain name.
@(private = "file")
parse_posix :: proc(p: ^Parser) -> (it: Prop_Item, matched: bool) {
	j := p.i + 2
	neg := j < len(p.src) && p.src[j] == '^'
	if neg {
		j += 1
	}
	start := j
	for j < len(p.src) && (p.src[j] | 0x20) >= 'a' && (p.src[j] | 0x20) <= 'z' {
		j += 1
	}
	if !strings.has_prefix(p.src[j:], ":]") {
		return {}, false
	}
	k, found := slice.linear_search(POSIX_NAMES[:], p.src[start:j])
	if !found {
		fail(p, "invalid POSIX bracket type")
		return {}, true
	}
	p.i = j + 2
	return {table = POSIX_TABLES[k], neg = neg}, true
}

// One member of a class: a character, a byte that starts none (`lone`), or a set added to `cls` (`is_set`): a type
// (\w, \p{...}, [:name:]), where a word is a POSIX word, or under ECMA \w \d \s as ranges.
@(private = "file")
class_item :: proc(p: ^Parser, cls: ^Class) -> (r: rune, is_set: bool, lone: bool, ok: bool) {
	if peek(p) == '[' && peek(p, 1) == ':' && !p.flags.ecma {
		if posix, matched := parse_posix(p); matched {
			append(&cls.props, posix)
			return 0, true, false, p.err == ""
		}
	}
	if peek(p) == '\\' && p.i + 1 < len(p.src) {
		c := peek(p, 1)
		p.i += 2
		switch c {
		case 'w', 'W', 'd', 'D', 's', 'S':
			if p.flags.ecma {
				add_ecma_set(&cls.ranges, c)
			} else {
				append(&cls.props, class_word(escape_prop(c)))
			}
			return 0, true, false, true
		case 'p', 'P':
			if peek(p) == '{' || p.flags.ecma {
				it: Prop_Item
				it, ok = parse_property(p, c == 'P')
				append(&cls.props, class_word(it))
				return 0, true, false, ok
			}
		case 'b':
			return 0x08, false, false, true
		case '-':
			if p.flags.ecma {
				return '-', false, false, true
			}
		}
		if p.flags.ecma {
			r, ok = ecma_char(p, c)
			return
		}
		p.i -= 2
	}
	r, lone, ok = parse_char_escape(p, true)
	return
}

// ECMA's \d \w \s or a capital in a class, as ranges.
@(private = "file")
add_ecma_set :: proc(ranges: ^[dynamic][2]rune, c: byte) {
	set, negated := escape_set(c)
	if !negated {
		append(ranges, ..set)
		return
	}
	next := rune(0)
	for g in set {
		if g[0] > next {
			append(ranges, [2]rune{next, g[0] - 1})
		}
		next = g[1] + 1
	}
	append(ranges, [2]rune{next, utf8.MAX_RUNE})
}

@(private = "file")
class_word :: proc(it: Prop_Item) -> Prop_Item {
	return {table = TABLE_CLASS_WORD, neg = it.neg} if it.table == TABLE_WORD else it
}

