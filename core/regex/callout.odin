#+private
package regex

// Callouts, `(*NAME[tag]{args})`, parsed as Oniguruma parses them, their tags resolved once the whole pattern is
// read, and run by the matcher.

import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// A callout Oniguruma's builtins keep data for, with its arguments as they read them.
Callout :: struct {
	kind:  Assert_Kind,
	tag:   string,
	code:  int, // ERROR's
	// COUNT's, TOTAL_COUNT's and MAX's: '>' counts as it is passed, 'X' also takes it back as the match backs past
	// it, '<' counts only then. Any other ends the search when it is reached.
	type:  rune,
	sides: [2]Operand, // MAX's most in [0], CMP's two sides
	cmp:   u8, // CMP's operator as the outcomes it holds for: 1 less, 2 equal, 4 greater, 0 for none
	index: int, // its count's slot
}

// A number, or the count of the callout of a tag (`ref`, nil for a number). A tag on a callout that keeps
// no count reads 0.
Operand :: struct {
	n:   int,
	tag: string,
	ref: ^Callout,
}

// A callout of name at `*`, `(*NAME[tag]{args})`, as Oniguruma parses one: its arguments are split at each
// `,` not escaped by `\`, an empty one dropped, and those of a fixed kind checked here, the rest when the
// callout is reached.
parse_callout :: proc(p: ^Parser) -> ^Node {
	p.i += 1
	if at_end(p) {
		return fail(p, "invalid callout pattern")
	}
	start := p.i
	for !at_end(p) && peek(p) != ')' && peek(p) != '[' && peek(p) != '{' {
		p.i += 1
	}
	name := p.src[start:p.i]
	tag := ""
	if peek(p) == '[' && !at_end(p) {
		p.i += 1
		start = p.i
		for !at_end(p) && peek(p) != ']' {
			p.i += 1
		}
		tag = p.src[start:p.i]
		if at_end(p) || !callout_name(tag) {
			return fail(p, "invalid callout tag name")
		}
		if slice.contains(p.tags[:], tag) {
			return fail(p, strings.concatenate({"multiplex defined name <", tag, ">"}))
		}
		append(&p.tags, tag)
		p.i += 1
	}
	args: [dynamic]string
	if peek(p) == '{' && !at_end(p) {
		p.i += 1
		start = p.i
		from := p.i
		for !at_end(p) && peek(p) != '}' {
			switch peek(p) {
			case '\\':
				p.i += 1
			case ',':
				if p.i > from {
					append(&args, p.src[from:p.i])
				}
				from = p.i + 1
			}
			p.i = min(p.i + 1, len(p.src))
		}
		if at_end(p) {
			return fail(p, "invalid callout pattern" if p.i > start else "end pattern in group")
		}
		if p.i > from {
			append(&args, p.src[from:p.i])
		}
		p.i += 1
		// Oniguruma looks the name up before it reads the `)`, and finds none when it is missing.
		if peek(p) != ')' || at_end(p) {
			return fail(p, "undefined callout name")
		}
	}
	if at_end(p) {
		return fail(p, "end pattern in group")
	}
	if peek(p) != ')' {
		return fail(p, "invalid callout pattern")
	}
	p.i += 1
	if !callout_name(name) {
		return fail(p, "invalid callout name")
	}
	c := Callout{tag = tag, code = -3, type = '>', index = len(p.callouts)} // ERROR's default is ONIG_ABORT
	switch name {
	case "FAIL", "MISMATCH", "SKIP":
		if len(args) > 0 {
			return fail(p, "invalid callout arg")
		}
		return assert_node(.Fail if name == "FAIL" else .Mismatch if name == "MISMATCH" else .Skip)
	case "ERROR":
		c.kind = .Error
		if len(args) > 1 {
			return fail(p, "invalid callout arg")
		}
		if len(args) == 1 {
			ok: bool
			if c.code, ok = callout_number(args[0]); !ok {
				return fail(p, "invalid callout arg")
			}
			c.code = int(i32(c.code)) // Oniguruma's builtin takes it as an int
		}
	case "COUNT", "TOTAL_COUNT", "MAX":
		c.kind = .Count if name == "COUNT" else .Total_Count if name == "TOTAL_COUNT" else .Max
		at := int(c.kind == .Max) // the argument that gives the type, after MAX's most
		if at > 0 {
			if len(args) > 0 && !callout_operand(p, args[0], &c.sides[0]) {
				return nil
			}
			c.type = 'X' // MAX gives back what a failed path counted, where COUNT keeps it
		}
		if len(args) < at || len(args) > at + 1 || len(args) == at + 1 && utf8.rune_count(args[at]) != 1 {
			return fail(p, "invalid callout arg")
		}
		if len(args) == at + 1 {
			c.type, _ = utf8.decode_rune(transmute([]byte)args[at])
		}
	case "CMP":
		c.kind = .Cmp
		for a, i in args {
			if i < 3 && i != 1 && !callout_operand(p, a, &c.sides[i / 2]) {
				return nil
			}
		}
		if len(args) != 3 {
			return fail(p, "invalid callout arg")
		}
		k, _ := slice.linear_search([]string{"<", "==", "<=", ">", "!=", ">="}, args[1])
		c.cmp = u8(k + 1)
	case:
		return fail(p, "undefined callout name")
	}
	n := assert_node(c.kind)
	n.callout = new_clone(c)
	append(&p.callouts, n.callout)
	return n
}

// A MAX's or CMP's side `a`: a number, or else a tag, resolved once every tag is known (`resolve_tags`).
@(private = "file")
callout_operand :: proc(p: ^Parser, a: string, o: ^Operand) -> bool {
	ok: bool
	if o.n, ok = callout_number(a); ok {
		return true
	}
	if !callout_name(a) {
		fail(p, "invalid callout tag name")
		return false
	}
	o.tag = a
	return true
}

// Oniguruma's parse_long: an optional sign and decimal digits, none read as 0, of a size a long holds.
@(private = "file")
callout_number :: proc(s: string) -> (int, bool) {
	digits := s[1:] if s[0] == '-' || s[0] == '+' else s
	n := 0
	for c in transmute([]byte)digits {
		if c < '0' || c > '9' || n > (max(int) - int(c - '0')) / 10 {
			return 0, false
		}
		n = 10 * n + int(c - '0')
	}
	return -n if s[0] == '-' else n, true
}

// Oniguruma's callout names and tags: an ASCII letter or `_`, then letters, digits and `_`.
@(private = "file")
callout_name :: proc(s: string) -> bool {
	for c, i in transmute([]byte)s {
		if !(c == '_' || c | 0x20 >= 'a' && c | 0x20 <= 'z' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return s != ""
}

// Each tag a MAX or CMP reads, which a callout anywhere in the pattern must have.
resolve_tags :: proc(p: ^Parser) {
	for c in p.callouts {
		for &o in c.sides {
			if o.tag == "" {
				continue
			}
			if !slice.contains(p.tags[:], o.tag) {
				fail(p, "invalid callout tag name")
				return
			}
			for d in p.callouts {
				if d.tag == o.tag && (d.kind == .Count || d.kind == .Total_Count || d.kind == .Max) {
					o.ref = d
				}
			}
		}
	}
}

// The callout of data `i` run as the match passes it, as Oniguruma's builtin is: false to fail here, `end` when it
// ends the match at this start, or the search with its error in m.err.
callout :: proc(m: ^Matcher, i: int) -> (ok: bool, end: bool) {
	c := m.re.callouts[i]
	count := &m.counts[i]
	switch c.kind {
	case .Error:
		if c.code != -1 { // ONIG_MISMATCH
			m.err = error_message(c.code)
		}
		return false, true
	case .Count, .Total_Count, .Max:
		if c.type != '>' && c.type != 'X' && c.type != '<' {
			m.err = "invalid callout arg"
			return false, true
		}
		if c.type != '<' {
			if c.kind == .Max && count^ >= operand(m, c.sides[0]) {
				return false, false
			}
			count^ += 1
		}
		if c.type != '>' {
			if !push_branch(m, {kind = .Retract, a = i}, false) {
				return false, true
			}
		}
		return true, false
	case .Cmp:
		if c.cmp == 0 {
			m.err = "invalid callout arg"
			return false, true
		}
		x, y := operand(m, c.sides[0]), operand(m, c.sides[1])
		return c.cmp & (1 if x < y else 2 if x == y else 4) != 0, false
	case .Begin_Buf, .End_Buf, .Semi_End_Buf, .Begin_Line, .End_Line, .Word_Boundary, .Not_Word_Boundary,
	     .Search_Start, .Ascii_Boundary, .Not_Ascii_Boundary, .Fail, .Mismatch, .Skip:
	}
	return true, false
}

// The callout of data `i` as the match backs past it: '<' counts up to its most, 'X' takes back its count.
retract :: proc(m: ^Matcher, i: int) {
	c := m.re.callouts[i]
	switch {
	case c.type == 'X':
		m.counts[i] -= 1
	case c.kind != .Max || m.counts[i] < operand(m, c.sides[0]):
		m.counts[i] += 1
	}
}

@(private = "file")
operand :: #force_inline proc(m: ^Matcher, o: Operand) -> int {
	if o.ref == nil {
		return o.n
	}
	return m.counts[o.ref.index]
}

// Oniguruma's message for its error `code`, as onig_error_code_to_str gives it with no details: a code whose
// message names a detail is taken as one (*ERROR) may not give.
@(private = "file")
error_message :: proc(code: int) -> string {
	if code >= 0 {
		return "invalid callout body"
	}
	messages := ERROR_MESSAGES
	for each in strings.split_iterator(&messages, "\x00") {
		at := strings.index_byte(each, ' ')
		if n, _ := strconv.parse_int(each[:at]); n == code {
			return each[at + 1:]
		}
	}
	return "undefined error code"
}
