#+private
package regex

// Group syntax at `(`: captures, look-arounds, group names, inline options, absent operators, and conditionals.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

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
parse_group :: proc(p: ^Parser) -> ^Node {
	p.i += 1
	if peek(p) == '*' && !p.flags.ecma {
		return parse_callout(p)
	}
	if peek(p) != '?' {
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
			p.i += 1
			return look_node(p, .Behind if p.src[p.i - 1] == '=' else .Not_Behind)
		}
		name, ok := group_name(p, '>' if c == '<' else '\'')
		return capture_node(p, name) if ok else nil
	case '#': // skip_ignored took every closed comment
		return fail(p, "end pattern in group")
	case '(':
		return parse_cond(p)
	case '~':
		return parse_absent(p)
	case '&':
		if c = peek(p); c >= '0' && c <= '9' || c == '-' || c == '+' {
			return refuse_name(p, p.i, ')', "invalid group name <")
		}
		return parse_call(p, ')')
	case 'R':
		// Oniguruma leaves the `)` of (?R) unread, so it closes an outer group or is unmatched.
		if peek(p) == ')' {
			n := new_node(.Call)
			append(&p.calls, n)
			return n
		}
	case '0' ..= '9', '-', '+':
		if c >= '0' || peek(p) >= '0' && peek(p) <= '9' {
			p.i -= 1
			return parse_call(p, ')')
		}
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
	for !at_end(p) && peek(p) != close && (p.flags.ecma || peek(p) != ')') {
		if !p.flags.ecma || p.src[p.i] != '\\' {
			strings.write_byte(&b, p.src[p.i])
			p.i += 1
		} else if peek(p, 1) != 'u' {
			fail(p, "invalid group name")
			return "", false
		} else {
			p.i += 2
			r, ok := ecma_char(p, 'u')
			if !ok {
				return "", false
			}
			strings.write_rune(&b, r)
		}
		if gate_failed(context.allocator) {
			fail(p, MEMORY_ERROR)
			return "", false
		}
	}
	name := strings.to_string(b)
	if peek(p) != close {
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
	first, rest := parse_split(p)
	if first == nil {
		return nil
	}
	append(&n.kids, first)
	if rest != nil {
		append(&n.kids, rest)
	}
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
	c := peek(p)
	if c != '<' && c != '\'' && (c < '0' || c > '9') {
		return parse_cond_expr(p)
	}
	n := new_node(.Cond)
	if c == '<' || c == '\'' {
		p.i += 1
		ok: bool
		if n.name, ok = group_name(p, '>' if c == '<' else '\''); !ok || !resolve_name(p, n) {
			return nil
		}
	} else {
		n.group, _ = number(p.src, &p.i, MAX_CAPTURES + 1)
	}
	if peek(p) != ')' {
		return fail(p, "invalid conditional pattern")
	}
	p.i += 1
	add_ref(p, n)
	yes, no := parse_split(p)
	if yes == nil {
		return nil
	}
	append(&n.kids, yes, no if no != nil else new_node(.Empty))
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
	yes, no := parse_split(p)
	if yes == nil {
		return nil
	}
	atomic, absent := new_node(.Look, cond), new_node(.Look, cond)
	atomic.look, absent.look = .Atomic, .Not_Ahead
	return expect_close(
		p,
		new_node(.Alt, new_node(.Cat, atomic, yes), new_node(.Cat, absent, no if no != nil else new_node(.Empty))),
	)
}

// Parses an absent or condition body and splits its first alternative from the rest (`rest` nil when none). The
// alternatives of a group, `(?(1)(?i:x|y))` or `(?(1)(?:x|y))`, belong to the group, which is the first branch.
@(private = "file")
parse_split :: proc(p: ^Parser) -> (first, rest: ^Node) {
	p.head = true
	body := parse_alt(p)
	if p.err != "" {
		return nil, nil
	}
	if body.kind == .Alt && !body.bag {
		return body.kids[0], body.kids[1] if len(body.kids) == 2 else new_node(.Alt, ..body.kids[1:])
	}
	return body, nil
}
