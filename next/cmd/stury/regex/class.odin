package regex

// Bracket classes, the character properties they hold, and the POSIX classes inside them.

import "core:slice"
import "core:strings"

// A bracket class, or one of the escapes \w \d \s \p{...} as a class of one type.
Class :: struct {
	ranges:  [dynamic][2]rune,
	props:   [dynamic]Prop_Item,
	negated: bool,
	fold:    bool,
	ascii:   [2]u64, // the answer for each ASCII rune, filled in by the compiler
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

// At `{` after \p or \P.
@(private)
parse_property :: proc(p: ^Parser, neg: bool) -> (Prop_Item, bool) {
	end := strings.index_byte(p.src[p.i:], '}')
	if end < 0 {
		fail(p, "end pattern with unmatched parenthesis")
		return {}, false
	}
	name := p.src[p.i + 1:p.i + end]
	p.i += end + 1
	inner := name
	caret := strings.has_prefix(name, "^")
	if caret {
		inner = name[1:]
	}
	it, ok := named_prop(inner)
	if !ok {
		fail(p, strings.concatenate({"invalid character property name {", name, "}"}))
		return {}, false
	}
	it.neg = neg != caret
	return it, true
}

// At `[`: a bracket class. Classes do not nest and `&&` is literal, as under ONIG_SYNTAX_PERL_NT.
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
	// A `]` first is a character, which may start a range (`[]-a]`).
	leading := peek(p) == ']' && !at_end(p)
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
		if c == '[' && peek(p, 1) == ':' {
			if it, matched := parse_posix(p); matched {
				if p.err != "" {
					return nil
				}
				append(&cls.props, it)
				continue
			}
		}
		lo, it, is_prop, lo_lone, ok := class_item(p)
		if !ok {
			return nil
		}
		if is_prop {
			append(&cls.props, it)
			continue
		}
		hi, hi_lone := lo, lo_lone
		if peek(p) == '-' && p.i + 1 < len(p.src) && peek(p, 1) != ']' {
			p.i += 1
			if peek(p) == '[' && peek(p, 1) == ':' {
				if _, matched := parse_posix(p); matched {
					return nil if p.err != "" else fail(p, "char-class value at end of range")
				}
			}
			hi_r, _, hi_prop, hi_r_lone, hi_ok := class_item(p)
			if !hi_ok {
				return nil
			}
			if hi_prop {
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

// One member of a class: a character, a byte that starts none (`lone`), or a type (\w, \p{...}), where a
// word is a POSIX word.
@(private = "file")
class_item :: proc(p: ^Parser) -> (r: rune, it: Prop_Item, is_prop: bool, lone: bool, ok: bool) {
	if peek(p) == '\\' && p.i + 1 < len(p.src) {
		switch c := peek(p, 1); c {
		case 'w', 'W', 'd', 'D', 's', 'S':
			p.i += 2
			return 0, class_word(escape_prop(c)), true, false, true
		case 'p', 'P':
			if peek(p, 2) == '{' {
				p.i += 2
				it, ok = parse_property(p, c == 'P')
				return 0, class_word(it), true, false, ok
			}
		case 'b':
			p.i += 2
			return 0x08, {}, false, false, true
		}
	}
	r, lone, ok = parse_char_escape(p, true)
	return r, {}, false, lone, ok
}

@(private = "file")
class_word :: proc(it: Prop_Item) -> Prop_Item {
	return {table = TABLE_CLASS_WORD, neg = it.neg} if it.table == TABLE_WORD else it
}

