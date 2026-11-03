package regex

// Oniguruma's pattern syntax as jq compiles it (ONIG_SYNTAX_PERL_NT, UTF-8, ONIG_OPTION_CAPTURE_GROUP),
// parsed into a tree. An error is Oniguruma's own message, which jq prints after "Regex failure: ".

import "core:strings"
import "core:unicode/utf8"

MAX_REPEAT :: 100000 // ONIG_MAX_REPEAT_NUM
MAX_BACKREF :: 1000 // ONIG_MAX_BACKREF_NUM

Node_Kind :: enum u8 {
	Empty,
	Char,
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
	op:    string, // CMP's, read when it is reached
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
	r:          rune, // Char
	class:      ^Class,
	kids:       [dynamic]^Node, // Cat, Alt; Group, Repeat and Look have one; Cond its yes and no
	min, max:   int, // Repeat; max -1 for no bound
	greedy:     bool,
	possessive: bool,
	group:      int, // Group's capture number (0 for none), Cond's group
	refs:       [dynamic]int, // Backref's groups, which a name may give several of
	name:       string, // Backref or Cond by name, until resolved
	assert:     Assert_Kind,
	callout:    ^Callout, // a callout of data
	look:       Look_Kind,
	bag:        bool, // the body of an option group `(?i:...)`, which Oniguruma keeps as a group of its own
	target:     ^Node, // Call's group, once resolved (`resolve_calls`)
	recursion:  bool, // Backref: within a group it names
	used:       bool, // Group: a backreference, condition or call reads it, so a look-behind is not cut to nothing
}

Flags :: struct {
	fold, extend, dotall, multiline: bool,
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

new_node :: proc(kind: Node_Kind) -> ^Node {
	n := new(Node)
	n.kind = kind
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
	first := parse_cat(p)
	if p.err != "" || at_end(p) || peek(p) != '|' {
		return first
	}
	alt := new_node(.Alt)
	append(&alt.kids, first)
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
	cat := new_node(.Cat)
	for {
		skip_extended(p)
		if at_end(p) || peek(p) == '|' || peek(p) == ')' {
			break
		}
		head := p.head && strings.has_prefix(p.src[p.i:], "(?:")
		p.head = false
		atom := parse_atom(p)
		if p.err != "" {
			return nil
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
		append(&cat.kids, atom)
	}
	switch len(cat.kids) {
	case 0:
		cat.kind = .Empty
	case 1:
		return cat.kids[0]
	}
	return cat
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
	for {
		skip_extended(p)
		if at_end(p) {
			return atom
		}
		c := peek(p)
		lo, hi: int
		switch c {
		case '*':
			lo, hi = 0, -1
			p.i += 1
		case '+':
			lo, hi = 1, -1
			p.i += 1
		case '?':
			lo, hi = 0, 1
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
		rep := new_node(.Repeat)
		rep.min, rep.max, rep.greedy = lo, hi, true
		append(&rep.kids, atom)
		if peek(p) == '?' && !at_end(p) {
			rep.greedy = false
			p.i += 1
		} else if peek(p) == '+' && !at_end(p) { // PERL_NT's PLUS_POSSESSIVE_INTERVAL too: `a{1,2}+`
			rep.possessive = true
			p.i += 1
		}
		if atom.kind == .Repeat && !atom.bag && !atom.possessive {
			reduce_nested(rep)
		}
		atom = rep
	}
}

@(private = "file")
Nested :: enum u8 {
	Asis, // as it is
	Del, // the inner repeat alone
	A, // *
	AQ, // *?
	QQ, // ??
	P, // +
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
	switch REDUCE_NESTED[i][o] {
	case .Asis:
	case .Del:
		possessive := outer.possessive
		outer^ = inner^
		outer.possessive = possessive
	case .A:
		outer.kids[0] = inner.kids[0]
		outer.min, outer.max, outer.greedy = 0, -1, true
	case .AQ:
		outer.kids[0] = inner.kids[0]
		outer.min, outer.max, outer.greedy = 0, -1, false
	case .QQ:
		outer.kids[0] = inner.kids[0]
		outer.min, outer.max, outer.greedy = 0, 1, false
	case .P:
		outer.kids[0] = inner.kids[0]
		outer.min, outer.max, outer.greedy = 1, -1, true
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

// The decimal digits at s[j^:], read past, their value capped at `cap`.
@(private)
number :: proc(s: string, j: ^int, cap: int) -> (n: int, digits: bool) {
	for j^ < len(s) && s[j^] >= '0' && s[j^] <= '9' {
		n = min(n * 10 + int(s[j^] - '0'), cap)
		j^ += 1
		digits = true
	}
	return
}

// `{n}`, `{n,}` or `{n,m}` at `{`, read past when it is one. Anything else leaves `{` a literal.
@(private = "file")
parse_interval :: proc(p: ^Parser) -> (lo, hi: int, ok: bool) {
	j := p.i + 1
	got: bool
	if lo, got = number(p.src, &j, MAX_REPEAT + 1); !got {
		return
	}
	hi = lo
	if j < len(p.src) && p.src[j] == ',' {
		j += 1
		if hi, got = number(p.src, &j, MAX_REPEAT + 1); !got {
			hi = -1
		}
	}
	if j >= len(p.src) || p.src[j] != '}' {
		return
	}
	p.i = j + 1
	switch {
	case lo > MAX_REPEAT || hi > MAX_REPEAT:
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
		n := new_node(.Any)
		n.dotall = p.flags.dotall
		return n
	case '^':
		p.i += 1
		return assert_node(.Begin_Line if p.flags.multiline else .Begin_Buf)
	case '$':
		p.i += 1
		return assert_node(.End_Line if p.flags.multiline else .Semi_End_Buf)
	case '\\':
		return parse_escape(p)
	case '*', '+', '?':
		return fail(p, "target of repeat operator is not specified")
	case '{':
		save := p.i
		if _, _, ok := parse_interval(p); ok {
			return fail(p, "target of repeat operator is not specified")
		}
		p.i = save + 1
		return char_node(p, '{')
	}
	r, w := utf8.decode_rune_in_string(p.src[p.i:])
	p.i += w
	return char_node(p, r)
}

@(private = "file")
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
	n := new_node(.Look)
	n.look = kind
	body := parse_alt(p)
	append(&n.kids, body)
	return expect_close(p, n)
}

@(private = "file")
capture_node :: proc(p: ^Parser, name: string) -> ^Node {
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
	if peek(p) == '*' && !at_end(p) {
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

// A group's name up to `close`, which must not be empty or start with a digit.
@(private = "file")
group_name :: proc(p: ^Parser, close: byte) -> (string, bool) {
	name, ok := read_name(p, close)
	if ok && name[0] >= '0' && name[0] <= '9' {
		fail(p, strings.concatenate({"invalid group name <", name, ">"}))
		return "", false
	}
	return name, ok
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
		rest := new_node(.Repeat)
		rest.min, rest.max, rest.greedy = 0, -1, true
		append(&rest.kids, any)
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
	exp := body.kids[1]
	if len(body.kids) > 2 {
		exp = new_node(.Alt)
		append(&exp.kids, ..body.kids[1:])
	}
	append(&n.kids, body.kids[0], exp)
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
	atomic, absent := new_node(.Look), new_node(.Look)
	atomic.look, absent.look = .Atomic, .Not_Ahead
	append(&atomic.kids, cond)
	append(&absent.kids, cond)
	yes, no := new_node(.Cat), new_node(.Cat)
	append(&yes.kids, atomic, branches.kids[0])
	append(&no.kids, absent, branches.kids[1])
	n := new_node(.Alt)
	append(&n.kids, yes, no)
	return expect_close(p, n)
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
		append(&n.kids, body.kids[0])
		if len(body.kids) == 2 {
			append(&n.kids, body.kids[1])
		} else {
			rest := new_node(.Alt)
			append(&rest.kids, ..body.kids[1:])
			append(&n.kids, rest)
		}
	} else {
		append(&n.kids, body, new_node(.Empty))
	}
	return true
}
