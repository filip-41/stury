package regex

// Callouts in a pattern, `(*NAME[tag]{args})`, as Oniguruma parses them.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A callout of name at `*`, `(*NAME[tag]{args})`, as Oniguruma parses one: its arguments are split at each
// `,` not escaped by `\`, an empty one dropped, and those of a fixed kind checked here, the rest when the
// callout is reached.
@(private)
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
	case "COUNT", "TOTAL_COUNT":
		c.kind = .Count if name == "COUNT" else .Total_Count
		if len(args) > 1 || len(args) == 1 && utf8.rune_count(args[0]) != 1 {
			return fail(p, "invalid callout arg")
		}
		if len(args) == 1 {
			c.type, _ = utf8.decode_rune(transmute([]byte)args[0])
		}
	case "MAX":
		c.kind = .Max
		if len(args) > 0 && !callout_operand(p, args[0], &c.sides[0]) {
			return nil
		}
		if len(args) < 1 || len(args) > 2 || len(args) == 2 && utf8.rune_count(args[1]) != 1 {
			return fail(p, "invalid callout arg")
		}
		c.type = 'X' // MAX gives back what a failed path counted, where COUNT keeps it
		if len(args) == 2 {
			c.type, _ = utf8.decode_rune(transmute([]byte)args[1])
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
		c.op = args[1]
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
