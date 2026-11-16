#+private
package regex

// Parses Oniguruma's pattern syntax as jq compiles it (ONIG_SYNTAX_PERL_NT, UTF-8, ONIG_OPTION_CAPTURE_GROUP) into a
// tree. A syntax error is Oniguruma's own message, which jq prints after "Regex failure: ". Under `Flags.ecma` the
// grammar is ECMA-262's with the `u` flag, as a JSON Schema `pattern` uses it, and back references and look-behind are
// refused. Without them the outcome of a program at an instruction and a position does not depend on how the search got
// there, which the linear search relies on (match.odin).

import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import spell "../spell"

MAX_REPEAT :: 100000 // ONIG_MAX_REPEAT_NUM
MAX_BACKREF :: 1000 // ONIG_MAX_BACKREF_NUM
MAX_CAPTURES :: 32767 // ONIG_MAX_CAPTURE_NUM
// The deepest nesting jq's Oniguruma accepts. The whole pattern and each group count two, each quantifier on an atom
// one. It bounds the tree's depth, which compiling and analysing recurse over.
MAX_PARSE_DEPTH :: 1024

Parser :: struct {
	src:    string,
	i:      int,
	flags:  Flags, // flags in force in the current group, which (?i) changes until the group's end
	names:  [dynamic]string, // group n's name at index n, "" for none. Index 0 is the whole match
	groups: [dynamic]^Node,
	open:   [dynamic]int, // numbers of the groups being parsed, innermost last
	refs:   [dynamic]^Node, // backreferences and conditions, resolved once every group is known
	calls:  [dynamic]^Node, // calls, resolved the same way
	tags:   [dynamic]string, // the tags of callouts, written [tag]
	callouts: [dynamic]^Callout,
	err:    string,
	depth:  int, // nesting of the groups being parsed, 2 per group, checked against MAX_PARSE_DEPTH
	syntax_only: bool, // only syntax is judged (`valid`): ECMA back references and look-behind are accepted
	head:   bool, // at the first atom of an absent or condition branch, where `(?:...)` stays a group (group_head)
}

// Returns the pattern's tree, or Oniguruma's message when it does not compile.
parse :: proc(src: string, flags: Flags, syntax_only := false) -> (pat: Pattern, err: string) {
	p := Parser{src = src, flags = flags, syntax_only = syntax_only}
	append(&p.names, "")
	append(&p.groups, nil)
	root := parse_alt(&p)
	if p.err == "" && p.i < len(src) {
		fail(&p, "unmatched close parenthesis")
	}
	referenced := make([]bool, len(p.names))
	if p.err == "" {
		resolve_refs(&p, referenced)
	}
	if p.err == "" {
		resolve_tags(&p)
	}
	if p.err == "" {
		resolve_calls(&p)
	}
	if zero := p.groups[0]; zero != nil {
		append(&zero.kids, root)
		root = zero
	}
	return {root, p.names[:], p.groups[:], referenced, p.callouts[:], len(p.calls) > 0}, p.err
}

fail :: proc(p: ^Parser, msg: string) -> ^Node {
	if p.err == "" {
		p.err = msg
	}
	return nil
}

peek :: proc(p: ^Parser, off := 0) -> byte {
	return p.src[p.i + off] if p.i + off < len(p.src) else 0
}

at_end :: proc(p: ^Parser) -> bool {
	return p.i >= len(p.src)
}

// Returns the rune at `p.i` and moves `p.i` past it.
next_rune :: proc(p: ^Parser) -> rune {
	r, w := utf8.decode_rune_in_string(p.src[p.i:])
	p.i += w
	return r
}

// Parses alternatives up to the group's `)` or the pattern's end. A (?i) lasts to the group's end, across `|`.
@(private = "file")
parse_alt :: proc(p: ^Parser) -> ^Node {
	saved := p.flags
	defer p.flags = saved
	p.depth += 2
	defer p.depth -= 2
	if p.depth > MAX_PARSE_DEPTH {
		return fail(p, "parse depth limit over")
	}
	first := parse_cat(p)
	if p.err != "" || at_end(p) || peek(p) != '|' {
		return first
	}
	alt := new_node(.Alt, first)
	for !at_end(p) && peek(p) == '|' {
		p.i += 1
		append(&alt.kids, parse_cat(p))
		if p.err != "" {
			return nil
		}
	}
	return alt
}

@(private = "file")
parse_cat :: proc(p: ^Parser) -> ^Node {
	// A Cat node is made at the second element, so a single element has no Cat around it.
	first, cat: ^Node
	add :: proc(first, cat: ^^Node, n: ^Node) {
		switch {
		case first^ == nil:
			first^ = n
		case cat^ == nil:
			cat^ = new_node(.Cat, first^, n)
		case:
			append(&cat^.kids, n)
		}
	}
	for {
		skip_extended(p)
		if at_end(p) || peek(p) == '|' || peek(p) == ')' {
			break
		}
		if run := plain_run(p); run != nil {
			p.head = false
			add(&first, &cat, run)
			continue
		}
		// Under ECMA any `(?:...)` group may be repeated, whatever it holds.
		head := (p.head || p.flags.ecma) && strings.has_prefix(p.src[p.i:], "(?:")
		quoted := strings.has_prefix(p.src[p.i:], `\Q`)
		p.head = false
		atom := parse_atom(p)
		if p.err != "" {
			return nil
		}
		if quoted && len(atom.kids) > 1 { // a quantifier after \Q...\E repeats its last character
			for k in atom.kids[:len(atom.kids) - 1] {
				add(&first, &cat, k)
			}
			atom = atom.kids[len(atom.kids) - 1]
		}
		if head && atom != nil {
			atom.bag = true // makes a repeat of it valid, whatever it holds
		}
		if atom == nil { // a comment or an option change
			continue
		}
		atom = parse_quantifiers(p, atom)
		if p.err != "" {
			return nil
		}
		add(&first, &cat, atom)
	}
	if cat != nil {
		return cat
	}
	return first if first != nil else new_node(.Empty)
}

// Takes the plain characters from here and the escaped ASCII punctuation as a Str node, stopping short of a character
// that a quantifier follows, which repeats it alone. Returns nil for fewer than two characters, and under (?i) or (?x),
// where each character is its own node. The text is a slice of the pattern until an escape is met, then a copy.
@(private = "file")
plain_run :: proc(p: ^Parser) -> ^Node {
	if p.flags.fold || p.flags.extend {
		return nil
	}
	copied: [dynamic]byte
	owned := false
	seg, end, runes := p.i, p.i, 0
	last, last_len := p.i, 0 // pattern offset where the last character starts, and the length of the text before it
	scan: for end < len(p.src) {
		w := 0
		switch c := p.src[end]; c {
		case '\\':
			if end + 1 >= len(p.src) || !escaped_punctuation(p.src[end + 1], p.flags.ecma) {
				break scan
			}
			w = 2
		case '(', ')', '[', '.', '^', '$', '|', '*', '+', '?', '{':
			break scan
		case ']', '}':
			if p.flags.ecma {
				break scan
			}
			fallthrough
		case:
			r: rune
			if r, w = utf8.decode_rune_in_string(p.src[end:]); r == utf8.RUNE_ERROR {
				break scan
			}
		}
		last, last_len = end, len(copied) + end - seg
		if w == 2 && p.src[end] == '\\' {
			append(&copied, p.src[seg:end])
			append(&copied, p.src[end + 1])
			owned, seg = true, end + 2
		}
		end += w
		runes += 1
	}
	repeated := false
	if end < len(p.src) {
		switch p.src[end] {
		case '*', '+', '?', '{':
			repeated = true
			runes -= 1
		}
	}
	if runes < 2 {
		delete(copied)
		return nil
	}
	n := new_node(.Str)
	if owned {
		append(&copied, p.src[seg:end])
		if repeated {
			resize(&copied, last_len)
		}
		n.text = string(copied[:])
	} else {
		n.text = p.src[p.i:last if repeated else end]
	}
	p.i = last if repeated else end
	n.r, _ = utf8.decode_rune_in_string(n.text)
	return n
}

// Whether `\c` is the character c itself: an escaped ASCII character other than a letter or digit, and under ECMA's
// `u` flag only a syntax character or `/`. Outside a class no other escape uses these characters. `-` is escaped only
// in a class, whose parse handles it first.
escaped_punctuation :: proc(c: byte, ecma: bool) -> bool {
	if ecma {
		return c == '/' || strings.index_byte("^$\\.*+?()[]{}|", c) >= 0
	}
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return false
	}
	return c < 0x80
}

// Under (?x), skips white space and `#` comments between tokens.
@(private = "file")
skip_extended :: proc(p: ^Parser) {
	for p.flags.extend && !at_end(p) {
		switch peek(p) {
		case ' ', '\t', '\n', '\r', '\f', '\v':
			p.i += 1
		case '#':
			for !at_end(p) && peek(p) != '\n' {
				p.i += 1
			}
		case:
			return
		}
	}
}

@(private = "file")
parse_quantifiers :: proc(p: ^Parser, atom: ^Node) -> ^Node {
	atom := atom
	quantifiers := 0
	for {
		skip_extended(p)
		if at_end(p) {
			return atom
		}
		c := peek(p)
		lo, hi: int
		switch c {
		case '*', '+', '?':
			lo, hi = int(c == '+'), 1 if c == '?' else -1
			p.i += 1
		case '{':
			ok: bool
			if lo, hi, ok = parse_interval(p); !ok {
				return atom
			}
		case:
			return atom
		}
		if p.err != "" {
			return nil
		}
		if invalid_repeat_target(atom) {
			return fail(p, "target of repeat operator is invalid")
		}
		if quantifiers += 1; p.depth + quantifiers > MAX_PARSE_DEPTH {
			return fail(p, "parse depth limit over")
		}
		rep := new_node(.Repeat, atom)
		rep.min, rep.max, rep.greedy = lo, hi, true
		if peek(p) == '?' {
			rep.greedy = false
			p.i += 1
		} else if p.flags.ecma { // ECMA takes one quantifier per atom, a second one is not a repeat of the first
			return rep
		} else if peek(p) == '+' { // also after an interval: `a{1,2}+` (PLUS_POSSESSIVE_INTERVAL)
			rep.possessive = true
			p.i += 1
		}
		if p.flags.ecma {
			return rep
		}
		if atom.kind == .Repeat && !atom.bag && !atom.possessive {
			reduce_nested(rep)
		}
		atom = rep
	}
}

@(private = "file")
Nested :: enum u8 {
	// The outer repeat becomes a repeat of the inner repeat's body, of the kind simple_repeat numbers 0 to 5.
	Q, // ?
	A, // *
	P, // +
	QQ, // ??
	AQ, // *?
	PQ, // +?
	Asis, // both repeats stay as written
	Del, // the inner repeat replaces the outer one
	P_QQ, // kept as `(?:a+)??`
}

// Oniguruma's ReduceTypeTable, indexed [inner][outer] by the numbers of ? * + ?? *? +?. `(?:a+?)*` and `(?:a+?)+`
// reduce to `a*` and `a+`, as jq 1.8.2 matches them, in linear time.
@(private = "file", rodata)
REDUCE_NESTED := [6][6]Nested {
	{.Del, .A, .A, .QQ, .AQ, .Asis},
	{.Del, .Del, .Del, .P_QQ, .P_QQ, .Del},
	{.A, .A, .Del, .Asis, .P_QQ, .Del},
	{.Del, .AQ, .AQ, .Del, .AQ, .AQ},
	{.Del, .Del, .Del, .Del, .Del, .Del},
	{.Asis, .A, .P, .AQ, .AQ, .Del},
}

// Oniguruma's onig_reduce_nested_quantifier. Replaces a repeat of a repeat by the single repeat that matches the same,
// so `(?:a+)+$` backtracks as `a+$` does. Also cuts the maximum of a greedy counted repeat of `a*` or `a+` to
// max(min, 1).
@(private = "file")
reduce_nested :: proc(outer: ^Node) {
	inner := outer.kids[0]
	o, i := simple_repeat(outer), simple_repeat(inner)
	if o < 0 || i < 0 {
		if (i == 1 || i == 2) && outer.greedy && outer.max > 1 {
			outer.max = max(outer.min, 1)
		}
		return
	}
	switch r := REDUCE_NESTED[i][o]; r {
	case .Asis:
	case .Del:
		possessive := outer.possessive
		outer^ = inner^
		outer.possessive = possessive
	case .Q, .A, .P, .QQ, .AQ, .PQ:
		s := int(r)
		outer.kids[0] = inner.kids[0]
		outer.min, outer.max, outer.greedy = int(s % 3 == 2), 1 if s % 3 == 0 else -1, s < 3
	case .P_QQ:
		outer.min, outer.max, outer.greedy = 0, 1, false
		inner.min, inner.max, inner.greedy = 1, -1, true
	}
}

// Oniguruma's quantifier_type_num: returns 0-5 for ? * + ?? *? +?, -1 for any other repeat.
@(private = "file")
simple_repeat :: proc(n: ^Node) -> int {
	lazy := 0 if n.greedy else 3
	switch {
	case n.min == 0 && n.max == 1:
		return lazy
	case n.min == 0 && n.max < 0:
		return lazy + 1
	case n.min == 1 && n.max < 0:
		return lazy + 2
	}
	return -1
}

// Oniguruma's is_invalid_quantifier_target: whether `n` is an anchor, a look-around other than an atomic group, \K, or
// alternatives one of which is. A group other than `(?:...)` or a sequence is a valid target whatever it holds.
@(private = "file")
invalid_repeat_target :: proc(n: ^Node) -> bool {
	if n.bag {
		return false
	}
	#partial switch n.kind {
	case .Assert, .Keep:
		return true
	case .Look:
		return n.look != .Atomic
	case .Alt:
		for k in n.kids {
			if invalid_repeat_target(k) {
				return true
			}
		}
	}
	return false
}

// Reads at most `most` digits of `base` at s[j^:] and advances `j^` past them. Returns their value capped at `cap`,
// and how many.
number :: proc(s: string, j: ^int, cap: int, base := 10, most := max(int)) -> (n: int, digits: int) {
	for ; digits < most && j^ < len(s) && int(spell.HEX_NIBBLE[s[j^]]) < base; digits += 1 {
		n = min(n * base + int(spell.HEX_NIBBLE[s[j^]]), cap)
		j^ += 1
	}
	return
}

// Reads `{n}`, `{n,}` or `{n,m}` at `{` and moves past it. Anything else returns ok false, and `{` is a literal, or an
// error under ECMA. Oniguruma limits counts to MAX_REPEAT. ECMA counts have no limit, and one past an i32 is read as
// the largest i32.
@(private = "file")
parse_interval :: proc(p: ^Parser) -> (lo, hi: int, ok: bool) {
	j := p.i + 1
	digits: int
	most := int(max(i32)) if p.flags.ecma else MAX_REPEAT + 1
	if lo, digits = number(p.src, &j, most); digits == 0 {
		return
	}
	hi = lo
	if j < len(p.src) && p.src[j] == ',' {
		j += 1
		if hi, digits = number(p.src, &j, most); digits == 0 {
			hi = -1
		}
	}
	if j >= len(p.src) || p.src[j] != '}' {
		return
	}
	p.i = j + 1
	switch {
	case !p.flags.ecma && (lo > MAX_REPEAT || hi > MAX_REPEAT):
		fail(p, "too big number for repeat range")
	case hi >= 0 && hi < lo:
		fail(p, "upper is smaller than lower in repeat range")
	}
	return lo, hi, true
}

char_node :: proc(p: ^Parser, r: rune) -> ^Node {
	n := new_node(.Char)
	n.r, n.fold = r, p.flags.fold
	return n
}

assert_node :: proc(kind: Assert_Kind) -> ^Node {
	n := new_node(.Assert)
	n.assert = kind
	return n
}

@(private = "file")
parse_atom :: proc(p: ^Parser) -> ^Node {
	c := peek(p)
	switch c {
	case '(':
		return parse_group(p)
	case '[':
		return parse_class(p)
	case '.':
		p.i += 1
		if p.flags.ecma {
			return class_node(LINE_TERMINATORS[:], true)
		}
		n := new_node(.Any)
		n.dotall = p.flags.dotall
		return n
	case '^':
		p.i += 1
		return assert_node(.Begin_Line if p.flags.multiline else .Begin_Buf)
	case '$':
		p.i += 1
		return assert_node(.End_Line if p.flags.multiline else .End_Buf if p.flags.ecma else .Semi_End_Buf)
	case '\\':
		return parse_escape(p)
	case '*', '+', '?':
		return fail(p, "target of repeat operator is not specified")
	case '{':
		save := p.i
		if _, _, ok := parse_interval(p); ok {
			return fail(p, "target of repeat operator is not specified")
		}
		if p.flags.ecma {
			return fail(p, "invalid pattern character")
		}
		p.i = save + 1
		return char_node(p, '{')
	case '}', ']':
		if p.flags.ecma {
			return fail(p, "invalid pattern character")
		}
	}
	return char_node(p, next_rune(p))
}

expect_close :: proc(p: ^Parser, body: ^Node) -> ^Node {
	if p.err != "" {
		return nil
	}
	if at_end(p) {
		return fail(p, "end pattern with unmatched parenthesis")
	}
	p.i += 1
	return body
}

@(private = "file")
look_node :: proc(p: ^Parser, kind: Look_Kind) -> ^Node {
	n := new_node(.Look, parse_alt(p))
	n.look = kind
	return expect_close(p, n)
}

@(private = "file")
capture_node :: proc(p: ^Parser, name: string) -> ^Node {
	if len(p.names) > MAX_CAPTURES {
		return fail(p, "too many captures")
	}
	n := new_node(.Group)
	append(&p.names, name)
	append(&p.groups, n)
	n.group = len(p.names) - 1
	append(&p.open, n.group)
	append(&n.kids, parse_alt(p))
	pop(&p.open)
	return expect_close(p, n)
}

// Parses the group at `(`, of any form. Returns nil for a comment or an option change.
@(private = "file")
parse_group :: proc(p: ^Parser) -> ^Node {
	p.i += 1
	if peek(p) == '*' && !p.flags.ecma {
		return parse_callout(p)
	}
	if peek(p) != '?' || at_end(p) {
		return capture_node(p, "")
	}
	p.i += 1
	if at_end(p) {
		return fail(p, "end pattern in group")
	}
	c := peek(p)
	p.i += 1
	if p.flags.ecma && strings.index_byte(":=!<", c) < 0 {
		return fail(p, "inline flags are not supported" if strings.index_byte("imsxu-", c) >= 0 else "invalid group")
	}
	switch c {
	case ':':
		return expect_close(p, parse_alt(p))
	case '=':
		return look_node(p, .Ahead)
	case '!':
		return look_node(p, .Not_Ahead)
	case '>':
		return look_node(p, .Atomic)
	case '<', '\'':
		if c == '<' && (peek(p) == '=' || peek(p) == '!') {
			if p.flags.ecma && !p.syntax_only {
				return fail(p, "look-behind is not supported")
			}
			p.i += 1
			return look_node(p, .Behind if p.src[p.i - 1] == '=' else .Not_Behind)
		}
		name, ok := group_name(p, '>' if c == '<' else '\'')
		return capture_node(p, name) if ok else nil
	case '#':
		for !at_end(p) && peek(p) != ')' {
			p.i += 1
		}
		if at_end(p) {
			return fail(p, "end pattern in group")
		}
		p.i += 1
		return nil
	case '(':
		return parse_cond(p)
	case '~':
		return parse_absent(p)
	}
	p.i -= 1
	return parse_options(p)
}

// Reads a group's name up to `close`. Under Oniguruma it must not be empty, start with a digit or `-`, or start with a
// character that is not a word character, and a backslash in it is literal. Under ECMA it must be an identifier that no
// other group has, whose characters may be written as `\uXXXX` or `\u{...}`.
@(private = "file")
group_name :: proc(p: ^Parser, close: byte) -> (name: string, ok: bool) {
	message := "invalid group name <"
	name = read_name(p, close) or_return
	if p.flags.ecma {
		ok = ecma_identifier(name) && !slice.contains(p.names[:], name)
	} else {
		first, _ := utf8.decode_rune_in_string(name)
		numbered := first >= '0' && first <= '9' || first == '-'
		ok = !numbered && is_word(first)
		if !numbered {
			message = "invalid char in group name <"
		}
	}
	if !ok {
		fail(p, strings.concatenate({message, name, ">"}))
		return "", false
	}
	return
}

// Reads a name up to `close`. An empty name is an error. Under ECMA its `\u` escapes are decoded.
read_name :: proc(p: ^Parser, close: byte) -> (string, bool) {
	b := strings.builder_make()
	for !at_end(p) && peek(p) != close {
		if !p.flags.ecma || p.src[p.i] != '\\' {
			strings.write_byte(&b, p.src[p.i])
			p.i += 1
			continue
		}
		if peek(p, 1) != 'u' {
			fail(p, "invalid group name")
			return "", false
		}
		p.i += 2
		r, ok := ecma_char(p, 'u')
		if !ok {
			return "", false
		}
		strings.write_rune(&b, r)
	}
	name := strings.to_string(b)
	if at_end(p) {
		fail(p, "invalid group name" if p.flags.ecma else strings.concatenate({"invalid group name <", name, ">"}))
		return "", false
	}
	p.i += 1
	if name == "" {
		fail(p, "group name is empty")
		return "", false
	}
	return name, true
}

// Parses past `(?~`. `(?~absent)` is the absent repeater, the same as `(?~|absent|\O*)`. `(?~|absent|exp)` is the
// absent expression, which matches exp short of where absent first matches from here. `(?~|absent)` is the stopper,
// which ends the text there for what follows, and `(?~|)` ends a stopper.
@(private = "file")
parse_absent :: proc(p: ^Parser) -> ^Node {
	n := new_node(.Absent)
	if at_end(p) {
		return fail(p, "end pattern in group")
	}
	if peek(p) != '|' {
		any := new_node(.Any)
		any.dotall = true
		rest := new_node(.Repeat, any)
		rest.min, rest.max, rest.greedy = 0, -1, true
		p.head = true
		append(&n.kids, parse_alt(p), rest)
		return expect_close(p, n)
	}
	p.i += 1
	if at_end(p) {
		return fail(p, "end pattern in group")
	}
	if peek(p) == ')' {
		p.i += 1
		return n
	}
	p.head = true
	body := parse_alt(p)
	if p.err != "" {
		return nil
	}
	if body.kind != .Alt || body.bag {
		append(&n.kids, body)
		return expect_close(p, n)
	}
	append(&n.kids, body.kids[0], alt_rest(body))
	return expect_close(p, n)
}

// Parses `(?imsx-imsx)`, whose flags last to the group's end, or `(?imsx-imsx:...)`.
@(private = "file")
parse_options :: proc(p: ^Parser) -> ^Node {
	flags := p.flags
	neg := false
	opened := p.i
	for {
		if at_end(p) {
			return fail(p, "end pattern in group")
		}
		c := peek(p)
		p.i += 1
		switch c {
		case '-':
			neg = true
		case 'i':
			flags.fold = !neg
		case 'x':
			flags.extend = !neg
		case 's':
			flags.dotall = !neg
		case 'm':
			flags.multiline = !neg
		case ')':
			if p.i - 1 == opened {
				return fail(p, "undefined group option")
			}
			p.flags = flags
			return nil
		case ':':
			saved := p.flags
			p.flags = flags
			body := parse_alt(p)
			p.flags = saved
			if body != nil {
				body.bag = true
			}
			return expect_close(p, body)
		case:
			return fail(p, "undefined group option")
		}
	}
}

// Parses the condition at `(?(`: `(?(n)yes|no)`, `(?(<name>)yes|no)` or `(?('name')yes|no)`.
@(private = "file")
parse_cond :: proc(p: ^Parser) -> ^Node {
	n := new_node(.Cond)
	switch peek(p) {
	case '<', '\'':
		close: byte = '>' if peek(p) == '<' else '\''
		p.i += 1
		ok: bool
		if n.name, ok = group_name(p, close); !ok || !resolve_name(p, n) {
			return nil
		}
	case '0' ..= '9':
		n.group, _ = number(p.src, &p.i, MAX_BACKREF + 1)
	case:
		return parse_cond_expr(p)
	}
	if at_end(p) || peek(p) != ')' {
		return fail(p, "invalid conditional pattern")
	}
	p.i += 1
	add_ref(p, n)
	if !cond_branches(p, n) {
		return nil
	}
	return expect_close(p, n)
}

// Parses `(?(cond)yes|no)` where cond is an expression. Oniguruma matches cond atomically and continues with yes, or
// with no when cond cannot match. This builds `(?>cond)yes|(?!cond)no`.
@(private = "file")
parse_cond_expr :: proc(p: ^Parser) -> ^Node {
	cond := parse_alt(p)
	if p.err != "" {
		return nil
	}
	if at_end(p) {
		return fail(p, "end pattern with unmatched parenthesis" if cond.kind == .Alt else "end pattern in group")
	}
	p.i += 1
	if at_end(p) {
		return fail(p, "end pattern in group")
	}
	branches := new_node(.Cond)
	if !cond_branches(p, branches) {
		return nil
	}
	atomic, absent := new_node(.Look, cond), new_node(.Look, cond)
	atomic.look, absent.look = .Atomic, .Not_Ahead
	return expect_close(p, new_node(.Alt, new_node(.Cat, atomic, branches.kids[0]), new_node(.Cat, absent, branches.kids[1])))
}

// Parses a condition's yes and no branches into n.kids[0] and [1]. Alternatives past the first are the no branch. The
// alternatives of a group, `(?(1)(?i:x|y))` or `(?(1)(?:x|y))`, belong to the group, which is the yes branch.
@(private = "file")
cond_branches :: proc(p: ^Parser, n: ^Node) -> bool {
	p.head = true
	body := parse_alt(p)
	if p.err != "" {
		return false
	}
	if body.kind == .Alt && !body.bag {
		append(&n.kids, body.kids[0], alt_rest(body))
	} else {
		append(&n.kids, body, new_node(.Empty))
	}
	return true
}

// Returns the alternatives of `alt` past its first, as one node.
@(private = "file")
alt_rest :: proc(alt: ^Node) -> ^Node {
	return alt.kids[1] if len(alt.kids) == 2 else new_node(.Alt, ..alt.kids[1:])
}
