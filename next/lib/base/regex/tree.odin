#+private
package regex

// The tree a pattern parses to.

import "core:unicode/utf8"

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
	kids:       [dynamic]^Node, // Cat and Alt. Group, Repeat and Look have one, Cond its yes and no
	min, max:   int, // Repeat, max -1 for no bound
	group:      int, // Group's capture number (0 for none), Cond's group
	refs:       [dynamic]int, // Backref's groups, which a name may give several of
	name:       string, // Backref or Cond by name, until resolved
	callout:    ^Callout, // a callout of data
	target:     ^Node, // Call's group, once resolved (`resolve_calls`)
}

// A pattern's tree with what the parser learns of it on the way.
Pattern :: struct {
	root:       ^Node, // under group 0 when a call names the whole pattern
	names:      []string, // group n's name at n, "" for none. Index 0 is the whole match
	groups:     []^Node, // group n's node at n, [0] only under a call of the whole pattern
	referenced: []bool, // by group number: a backreference or condition reads it
	callouts:   []^Callout, // those that keep data, each at its index
	has_calls:  bool,
}

new_node :: proc(kind: Node_Kind, kids: ..^Node) -> ^Node {
	n := new(Node)
	if n == nil {
		return nil
	}
	n.kind = kind
	append(&n.kids, ..kids)
	return n
}

// A character a fold-insensitive comparison sees as only itself.
literal :: proc(n: ^Node) -> bool {
	return n.kind == .Str || n.kind == .Char && utf8.valid_rune(n.r) && (!n.fold || fold_next(n.r) == n.r)
}

// Returns the index past the run of `literal` nodes of `kids` that starts at `i`, `i` itself when `kids[i]` is not one.
literal_run_end :: proc(kids: []^Node, i: int) -> int {
	j := i
	for j < len(kids) && literal(kids[j]) {
		j += 1
	}
	return j
}

// The bytes of a `literal` node, a Char's written into `buf`.
literal_text :: proc(n: ^Node, buf: ^[4]byte) -> string {
	if n.kind == .Str {
		return n.text
	}
	w: int
	buf^, w = utf8.encode_rune(n.r)
	return string(buf[:w])
}
