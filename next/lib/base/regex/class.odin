#+private
package regex

// Bracket classes: parsing them with the character properties and POSIX classes inside them, matching a rune against
// one, and the range helpers they use.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A bracket class, or one of the escapes \w \d \s \p{...} as a class of one property.
Class :: struct {
	ascii:   [2]u64, // bit r is set when the class matches ASCII rune r, filled in by the compiler
	ranges:  [dynamic][2]rune,
	props:   [dynamic]Prop_Item,
	negated: bool,
	fold:    bool,
	slot:    int, // 1 + the index the compiler last gave it among its classes, 0 before
}

@(rodata)
LINE_TERMINATORS := [?][2]rune{{'\n', '\n'}, {'\r', '\r'}, {0x2028, 0x2029}}
@(private = "file", rodata)
ECMA_DIGIT := [?][2]rune{{'0', '9'}}
@(private = "file", rodata)
ECMA_WORD := [?][2]rune{{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}}
// ECMA white space and line terminators. U+0085 is not one, U+FEFF is.
@(private = "file", rodata)
ECMA_SPACE := [?][2]rune {
	{9, 13}, {' ', ' '}, {0xA0, 0xA0}, {0x1680, 0x1680}, {0x2000, 0x200A}, {0x2028, 0x2029}, {0x202F, 0x202F},
	{0x205F, 0x205F}, {0x3000, 0x3000}, {0xFEFF, 0xFEFF},
}

// Returns the ranges of ECMA's \d \w or \s, which are fixed tables and not Unicode properties, and whether `c` is the
// capital letter that negates them.
escape_set :: proc(c: byte) -> ([][2]rune, bool) {
	switch c | 0x20 {
	case 'd':
		return ECMA_DIGIT[:], c == 'D'
	case 'w':
		return ECMA_WORD[:], c == 'W'
	}
	return ECMA_SPACE[:], c == 'S'
}

class_node :: proc(ranges: [][2]rune, negated: bool) -> ^Node {
	n := new_node(.Class)
	n.class = new(Class)
	n.class.negated = negated
	append(&n.class.ranges, ..ranges)
	return n
}

escape_prop :: proc(c: byte) -> Prop_Item {
	switch c {
	case 'w', 'W':
		return {table = TABLE_WORD, neg = c == 'W'}
	case 'd', 'D':
		return {table = TABLE_DIGIT, neg = c == 'D'}
	}
	return {table = TABLE_SPACE, neg = c == 'S'}
}

// Parses the property name at `{` after \p or \P. Under ECMA the `{` must be there.
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

// Parses the bracket class at `[`. Classes do not nest and `&&` is literal, as under ONIG_SYNTAX_PERL_NT and ECMA's
// `u`.
parse_class :: proc(p: ^Parser) -> ^Node {
	p.i += 1
	n := new_node(.Class)
	cls := new(Class)
	n.class = cls
	cls.fold = p.flags.fold
	if peek(p) == '^' {
		cls.negated = true
		p.i += 1
	}
	// A leading `]` is a character that may start a range (`[]-a]`). Under ECMA it ends an empty class.
	leading := peek(p) == ']' && !p.flags.ecma
	if leading && strings.index_byte(p.src[p.i + 1:], ']') < 0 {
		return fail(p, "empty char-class")
	}
	for {
		if at_end(p) {
			return fail(p, "premature end of char-class")
		}
		if gate_failed(context.allocator) {
			return fail(p, MEMORY_ERROR)
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
		}
		// A lone byte against a character past ASCII keeps the range (`[\x80-\x{10ffff}]`), as Oniguruma reads it.
		// A range whose ends are each ASCII or a lone byte is cut at 0x7F, since a lone byte matches no character of
		// the text.
		if (lo_lone || hi_lone) && (lo_lone || lo < 0x80) && (hi_lone || hi < 0x80) {
			hi = min(hi, 0x7F)
		}
		if lo <= hi {
			append(&cls.ranges, [2]rune{lo, hi})
		}
	}
}

// Parses the POSIX bracket `[:name:]` or `[:^name:]` at `[:`. Returns matched false when no `:]` closes a name of
// letters.
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
	if (!neg && j == start) || !strings.has_prefix(p.src[j:], ":]") {
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

// Parses one member of a class. Returns a character, or `lone` for a byte that starts no character, or `is_set` after
// adding a set to `cls`. The set is a property (\w, \p{...}, [:name:]) where \w is the POSIX word, or under ECMA the
// ranges of \w \d \s.
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

// Adds the ranges of ECMA's \d \w \s, or of the negation for a capital letter `c`, to `ranges`.
@(private = "file")
add_ecma_set :: proc(ranges: ^[dynamic][2]rune, c: byte) {
	set, negated := escape_set(c)
	if !negated {
		append(ranges, ..set)
		return
	}
	rest := complement_runs(set, 0)
	defer delete(rest)
	append(ranges, ..rest[:])
}

@(private = "file")
class_word :: proc(it: Prop_Item) -> Prop_Item {
	return {table = TABLE_CLASS_WORD, neg = it.neg} if it.table == TABLE_WORD else it
}

// Tests `r`, then each character of its case fold orbit when the class folds.
class_match_slow :: proc(cls: ^Class, r: rune) -> bool {
	x := r
	for {
		for g in cls.ranges {
			if x >= g[0] && x <= g[1] {
				return !cls.negated
			}
		}
		for it in cls.props {
			if in_table(int(it.table), x) != it.neg {
				return !cls.negated
			}
		}
		if !cls.fold {
			return cls.negated
		}
		x = fold_next(x)
		if x == r {
			return cls.negated
		}
	}
}

// The ASCII runes `cls` matches, bit r for rune r. A class of ranges alone is read off them, any other tests each rune.
ascii_bits :: proc(cls: ^Class) -> (bits: [2]u64) {
	if len(cls.props) == 0 && !cls.fold {
		for g in cls.ranges {
			for r in max(g[0], 0) ..= min(g[1], 0x7f) {
				add_bit(bits[:], int(r))
			}
		}
		if cls.negated {
			bits = {~bits[0], ~bits[1]}
		}
		return
	}
	for r in rune(0) ..< 0x80 {
		if class_match_slow(cls, r) {
			add_bit(bits[:], int(r))
		}
	}
	return
}

// Bit `i` of a set of bits held in 64-bit words.
has_bit :: #force_inline proc(words: []u64, i: int) -> bool {
	return words[i >> 6] & (1 << (u64(i) & 63)) != 0
}

// Sets bit `i` of a set of bits held in 64-bit words, which `has_bit` reads.
add_bit :: #force_inline proc(words: []u64, i: int) {
	words[i >> 6] |= 1 << (u64(i) & 63)
}

class_match :: #force_inline proc(cls: ^Class, r: rune) -> bool {
	if r >= 0 && r < 0x80 {
		return has_bit(cls.ascii[:], int(r))
	}
	return class_match_slow(cls, r)
}

word_type :: proc(cls: ^Class) -> bool {
	return !cls.negated && len(cls.ranges) == 0 && len(cls.props) == 1 && cls.props[0].table == TABLE_WORD
}

ascii_only :: proc(cls: ^Class) -> bool {
	if cls.negated || len(cls.props) > 0 {
		return false
	}
	for x in cls.ranges {
		if x[1] >= 0x80 {
			return false
		}
	}
	return true
}

// Whether a rune below 0x80 in the ranges of `cls` folds under (?i) to a non-ASCII rune, as k to the Kelvin sign and s
// to the long s.
folds_out_of_ascii :: proc(cls: ^Class) -> bool {
	if !cls.fold {
		return false
	}
	for x in cls.ranges {
		for r in x[0] ..= min(x[1], 0x7F) {
			if folds_outside(r) {
				return true
			}
		}
	}
	return false
}

// Sorts `runs` and joins the runs that overlap or touch, in place. Returns the shortened slice.
merge_runs :: proc(runs: [][2]rune) -> [][2]rune {
	keys := make([]u64, len(runs))
	if len(keys) != len(runs) {
		return nil
	}
	for g, i in runs {
		keys[i] = u64(g[0]) << 32 | u64(g[1])
	}
	slice.sort(keys)
	for k, i in keys {
		runs[i] = {rune(k >> 32), rune(u32(k))}
	}
	n := 0
	for g in runs {
		if n > 0 && (runs[n - 1][1] == max(rune) || g[0] <= runs[n - 1][1] + 1) {
			runs[n - 1][1] = max(runs[n - 1][1], g[1])
			continue
		}
		runs[n] = g
		n += 1
	}
	return runs[:n]
}

// Returns, as runs, the characters from `floor` up that the sorted runs `runs` leave out.
complement_runs :: proc(runs: [][2]rune, floor: rune) -> [dynamic][2]rune {
	out := make([dynamic][2]rune, 0, len(runs) + 1)
	lo := floor
	for g in runs {
		if g[0] > utf8.MAX_RUNE {
			break
		}
		if g[0] > lo {
			append(&out, [2]rune{lo, g[0] - 1})
		}
		if g[1] >= utf8.MAX_RUNE {
			return out
		}
		lo = max(lo, g[1] + 1)
	}
	if lo <= utf8.MAX_RUNE {
		append(&out, [2]rune{lo, utf8.MAX_RUNE})
	}
	return out
}
