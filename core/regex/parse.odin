#+private
package regex

// Oniguruma's pattern syntax as jq compiles it (ONIG_SYNTAX_PERL_NT, UTF-8, ONIG_OPTION_CAPTURE_GROUP),
// parsed into a tree. An error is Oniguruma's own message, which jq prints after "Regex failure: ". Under
// `Flags.ecma` the grammar is ECMA-262's with the `u` flag, as a JSON Schema's `pattern` uses it, and back references
// and look-behind are refused: with neither, a program's outcome at an instruction and a position does not depend on
// the way it got there, which the linear search relies on (match.odin).

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

MAX_REPEAT :: 100000 // ONIG_MAX_REPEAT_NUM
MAX_BACKREF :: 1000 // ONIG_MAX_BACKREF_NUM
MAX_CAPTURES :: 32767 // ONIG_MAX_CAPTURE_NUM
// The nesting jq's Oniguruma refuses past: the pattern and each group count two, each quantifier on an atom one more.
// It bounds the tree's depth, which compiling and analysing recurse over.
MAX_PARSE_DEPTH :: 1024

Node_Kind :: enum u8 {
	Empty,
	Char,
	Str, // a run of two or more plain characters outside (?i), `text`, as written in the pattern
	Any,
	Class,
	Cat,
	Alt,
	Group,
	Repeat,
	Assert,
	Look,
	Backref,
	Keep,
	Cond,
	Linebreak, // \R
	Grapheme, // \X
	Call, // \g<...>, a call of group `group` (-1 for one by name), as written in `name`
	Absent, // (?~...): kids [absent, exp], [absent] for a stopper `(?~|absent)`, none for `(?~|)`
}

Assert_Kind :: enum u8 {
	Begin_Buf, // \A, and ^ outside (?m)
	End_Buf, // \z
	Semi_End_Buf, // \Z, and $ outside (?m): the end, or before a newline that ends the string
	Begin_Line,
	End_Line,
	Word_Boundary,
	Not_Word_Boundary,
	Search_Start, // \G
	Ascii_Boundary, // ECMA's \b: a boundary of ASCII word characters
	Not_Ascii_Boundary,
	// The callouts, last.
	Fail, // (*FAIL)
	Mismatch, // (*MISMATCH): no match at this start
	Skip, // (*SKIP): the search's next start is past where it was reached
	Error, // (*ERROR{n}): the search ends with Oniguruma's error n, or at -1 the match at this start
	Count, // (*COUNT{type}): counts as it is passed (`Callout`)
	Total_Count, // (*TOTAL_COUNT{type}): a count the search keeps over its starts
	Max, // (*MAX{n, type}): counts, and fails once passed n times
	Cmp, // (*CMP{x, op, y}): fails unless the comparison holds
}

// A callout Oniguruma's builtins keep data for, with its arguments as they read them.
Callout :: struct {
	kind:  Assert_Kind,
	tag:   string,
	code:  int, // ERROR's
	// COUNT's, TOTAL_COUNT's and MAX's: '>' counts as it is passed, 'X' also takes it back as the match backs past
	// it, '<' counts only then. Any other ends the search when it is reached.
	type:  rune,
	sides: [2]Operand, // MAX's most in [0]; CMP's two sides
	cmp:   u8, // CMP's operator as the outcomes it holds for: 1 less, 2 equal, 4 greater, 0 for none
	index: int, // its count's slot
}

// A number, or the count of the callout of a tag (`ref`, nil for a number; a tag on a callout that keeps
// no count reads 0).
Operand :: struct {
	n:   int,
	tag: string,
	ref: ^Callout,
}

Look_Kind :: enum u8 {
	Ahead,
	Not_Ahead,
	Behind,
	Not_Behind,
	Atomic, // (?>...) and the possessive quantifiers
}

Node :: struct {
	kind:       Node_Kind,
	fold:       bool, // Char, Class, Backref: under (?i)
	dotall:     bool, // Any: also matches "\n"
	greedy:     bool,
	possessive: bool,
	assert:     Assert_Kind,
	look:       Look_Kind,
	bag:        bool, // the body of an option group `(?i:...)`, which Oniguruma keeps as a group of its own
	r:          rune, // Char, and Str's first character
	recursion:  bool, // Backref: within a group it names
	used:       bool, // Group: a backreference, condition or call reads it, so a look-behind is not cut to nothing
	text:       string, // Str
	class:      ^Class,
	kids:       [dynamic]^Node, // Cat, Alt; Group, Repeat and Look have one; Cond its yes and no
	min, max:   int, // Repeat; max -1 for no bound
	group:      int, // Group's capture number (0 for none), Cond's group
	refs:       [dynamic]int, // Backref's groups, which a name may give several of
	name:       string, // Backref or Cond by name, until resolved
	callout:    ^Callout, // a callout of data
	target:     ^Node, // Call's group, once resolved (`resolve_calls`)
}

// A pattern's tree with what the parser learns of it on the way.
Pattern :: struct {
	root:       ^Node, // under group 0 when a call names the whole pattern
	names:      []string, // group n's name at n, "" for none; [0] is the whole match
	groups:     []^Node, // group n's node at n; [0] only under a call of the whole pattern
	referenced: []bool, // by group number: a backreference or condition reads it
	callouts:   []^Callout, // those that keep data, each at its index
	has_calls:  bool,
}

@(private)
Parser :: struct {
	src:    string,
	i:      int,
	flags:  Flags, // the current group's, which (?i) changes to the group's end
	names:  [dynamic]string, // group n's name at n, "" for none; [0] is the whole match
	groups: [dynamic]^Node,
	open:   [dynamic]int, // the groups being parsed
	refs:   [dynamic]^Node, // backreferences and conditions, resolved once every group is known
	calls:  [dynamic]^Node, // the same for calls
	tags:   [dynamic]string, // callouts' [tag]s
	callouts: [dynamic]^Callout,
	err:    string,
	depth:  int, // the groups being parsed and the quantifiers on the atom, as MAX_PARSE_DEPTH counts them
	head:   bool, // at an absent's first atom, where Oniguruma keeps a `(?:...)` as a group of its own (group_head)
}

// The pattern's tree, or Oniguruma's message when it does not compile.
parse :: proc(src: string, flags: Flags) -> (pat: Pattern, err: string) {
	p := Parser{src = src, flags = flags}
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

@(private)
fail :: proc(p: ^Parser, msg: string) -> ^Node {
	if p.err == "" {
		p.err = msg
	}
	return nil
}

new_node :: proc(kind: Node_Kind, kids: ..^Node) -> ^Node {
	n := new(Node)
	n.kind = kind
	append(&n.kids, ..kids)
	return n
}

@(private)
peek :: proc(p: ^Parser, off := 0) -> byte {
	return p.src[p.i + off] if p.i + off < len(p.src) else 0
}

@(private)
at_end :: proc(p: ^Parser) -> bool {
	return p.i >= len(p.src)
}

// Alternatives up to the group's `)` or the pattern's end. (?i) holds to the group's end, past `|`.
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
	// The Cat is made at the second element, so a lone one takes no node.
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
		// ECMA repeats any group, whatever it holds.
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
			atom.bag = true // so a repeat of it is valid, whatever it holds
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

// The plain characters from here, and the escaped ASCII punctuation, as one Str node, short of one a quantifier
// follows, which repeats it alone. Nil for fewer than two, under (?i) or (?x), where each character is its own node.
// The text is the pattern's own bytes until an escape, then a copy.
@(private = "file")
plain_run :: proc(p: ^Parser) -> ^Node {
	if p.flags.fold || p.flags.extend {
		return nil
	}
	copied: [dynamic]byte
	owned := false
	seg, end, runes := p.i, p.i, 0
	last, last_len := p.i, 0 // where the last character starts in the pattern, and the text's length before it
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

// Whether `\c` is the character c itself, as an escaped ASCII character other than a letter or digit is, and under
// ECMA an ASCII punctuation character, as Annex B's identity escapes take.
@(private)
escaped_punctuation :: proc(c: byte, ecma: bool) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		return false
	}
	return c > ' ' && c < 0x7F if ecma else c < 0x80
}

// Under (?x), white space and `#` comments between tokens.
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
		if peek(p) == '?' && !at_end(p) {
			rep.greedy = false
			p.i += 1
		} else if p.flags.ecma { // one quantifier, which a second one after it cannot repeat
			return rep
		} else if peek(p) == '+' && !at_end(p) { // PERL_NT's PLUS_POSSESSIVE_INTERVAL too: `a{1,2}+`
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
	// The inner repeat's body under the outer repeat made the simple repeat of simple_repeat's number.
	Q,
	A, // *
	P, // +
	QQ, // ??
	AQ, // *?
	PQ,
	Asis, // as it is
	Del, // the inner repeat alone
	P_QQ, // (?:a+)??
}

// Oniguruma's ReduceTypeTable, [inner][outer] for each of ? * + ?? *? +?, with `(?:a+?)*` and `(?:a+?)+` as jq
// 1.8.2 matches them: as `a*` and `a+`, in linear time.
@(private = "file", rodata)
REDUCE_NESTED := [6][6]Nested {
	{.Del, .A, .A, .QQ, .AQ, .Asis},
	{.Del, .Del, .Del, .P_QQ, .P_QQ, .Del},
	{.A, .A, .Del, .Asis, .P_QQ, .Del},
	{.Del, .AQ, .AQ, .Del, .AQ, .AQ},
	{.Del, .Del, .Del, .Del, .Del, .Del},
	{.Asis, .A, .P, .AQ, .AQ, .Del},
}

// Oniguruma's onig_reduce_nested_quantifier, and its cut of `(?:a*){n,m}` to `(?:a*){n}`: a repeat of a
// repeat taken as the one repeat that matches the same, so `(?:a+)+$` backtracks as `a+$` does.
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

// Oniguruma's quantifier_type_num: 0-5 for ? * + ?? *? +?, -1 for another repeat.
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

// Oniguruma's is_invalid_quantifier_target: an anchor, a lookaround or \K, or alternatives one of which is. A group
// other than `(?:...)` or a sequence is a valid target whatever it holds.
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

// The digits of `base` at s[j^:], at most `most` of them, read past: their value capped at `cap`, and how many.
@(private)
number :: proc(s: string, j: ^int, cap: int, base := 10, most := max(int)) -> (n: int, digits: int) {
	for ; digits < most && j^ < len(s) && digit(s[j^]) < base; digits += 1 {
		n = min(n * base + digit(s[j^]), cap)
		j^ += 1
	}
	return
}

@(private)
digit :: proc(c: byte) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return 16
}

// `{n}`, `{n,}` or `{n,m}` at `{`, read past when it is one. Anything else leaves `{` a literal, and is an error under
// ECMA, whose counts have no bound: a count past an i32 is taken as the most an i32 holds.
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

@(private)
char_node :: proc(p: ^Parser, r: rune) -> ^Node {
	n := new_node(.Char)
	n.r, n.fold = r, p.flags.fold
	return n
}

// Outside a bracket \w and \W are Oniguruma's word type, and the other escapes and \p{...} classes that \D,
// \S, \H and \P{...} negate whole, which tells at a lone continuation byte.
@(private)
prop_node :: proc(it: Prop_Item) -> ^Node {
	n := new_node(.Class)
	n.class = new(Class)
	if it.table == TABLE_WORD {
		append(&n.class.props, it)
	} else {
		append(&n.class.props, Prop_Item{table = it.table})
		n.class.negated = it.neg
	}
	return n
}

@(private)
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
	r, w := utf8.decode_rune_in_string(p.src[p.i:])
	p.i += w
	return char_node(p, r)
}

@(private)
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

// At `(`: a group of any form, or nil for a comment or an option change.
@(private = "file")
parse_group :: proc(p: ^Parser) -> ^Node {
	p.i += 1
	if peek(p) == '*' && !at_end(p) && !p.flags.ecma {
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
		return fail(p, "invalid group")
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
			if p.flags.ecma {
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

// A group's name up to `close`. Under Oniguruma it must not be empty, start with a digit or `-`, or start with a
// character that is no word character, and a backslash in it is a backslash. Under ECMA it is an identifier no other
// group has, whose characters may be written as `\uXXXX` or `\u{...}`.
@(private = "file")
group_name :: proc(p: ^Parser, close: byte) -> (string, bool) {
	name: string
	ok: bool
	if p.flags.ecma {
		name, ok = ecma_name(p, close)
	} else {
		name, ok = read_name(p, close)
	}
	if !ok {
		return "", false
	}
	if p.flags.ecma {
		if !ecma_identifier(name) || slice.contains(p.names[:], name) {
			fail(p, strings.concatenate({"invalid group name <", name, ">"}))
			return "", false
		}
		return name, true
	}
	first, _ := utf8.decode_rune_in_string(name)
	switch {
	case first >= '0' && first <= '9' || first == '-':
		fail(p, strings.concatenate({"invalid group name <", name, ">"}))
		return "", false
	case !is_word(first):
		fail(p, strings.concatenate({"invalid char in group name <", name, ">"}))
		return "", false
	}
	return name, true
}

// An ECMA group name up to `close`, with its `\u` escapes decoded.
@(private = "file")
ecma_name :: proc(p: ^Parser, close: byte) -> (string, bool) {
	b := strings.builder_make()
	for !at_end(p) && peek(p) != close {
		if p.src[p.i] != '\\' {
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
	if at_end(p) {
		fail(p, "invalid group name")
		return "", false
	}
	p.i += 1
	if strings.builder_len(b) == 0 {
		fail(p, "group name is empty")
		return "", false
	}
	return strings.to_string(b), true
}

// A name up to `close`, which must not be empty.
@(private)
read_name :: proc(p: ^Parser, close: byte) -> (string, bool) {
	start := p.i
	for !at_end(p) && peek(p) != close {
		p.i += 1
	}
	name := p.src[start:p.i]
	if at_end(p) {
		fail(p, strings.concatenate({"invalid group name <", name, ">"}))
		return "", false
	}
	p.i += 1
	if name == "" {
		fail(p, "group name is empty")
		return "", false
	}
	return name, true
}

// Past `(?~`: the absent repeater `(?~absent)`, which is `(?~|absent|\O*)`. The expression `(?~|absent|exp)`, which
// matches exp short of where absent first matches from here. The stopper `(?~|absent)`, which ends the text there for
// what follows, or `(?~|)`, which ends a stopper.
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

// `(?imsx-imsx)`, which holds to the group's end, or `(?imsx-imsx:...)`.
@(private = "file")
parse_options :: proc(p: ^Parser) -> ^Node {
	flags := p.flags
	neg := false
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

// At `(?(`: `(?(n)yes|no)`, `(?(<name>)yes|no)` or `(?('name')yes|no)`.
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

// `(?(cond)yes|no)` where cond is an expression: Oniguruma matches cond atomically and goes on with yes, or
// takes no when cond cannot match, which is `(?>cond)yes|(?!cond)no`.
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

// A condition's yes and no branches, as n.kids[0] and [1]: alternatives past the first are no's. A group's
// alternatives, `(?(1)(?i:x|y))` or `(?(1)(?:x|y))`, are its own: the group is the yes branch.
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

// The alternatives of `alt` past its first, as one node.
@(private = "file")
alt_rest :: proc(alt: ^Node) -> ^Node {
	return alt.kids[1] if len(alt.kids) == 2 else new_node(.Alt, ..alt.kids[1:])
}
