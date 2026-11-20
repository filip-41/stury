#+private
package regex

// Group references and calls, read with the pattern and resolved once all of it is read.

import "core:slice"
import "core:strings"

// A named reference's groups: those of its name so far, as Oniguruma looks a name up where it meets it.
resolve_name :: proc(p: ^Parser, n: ^Node) -> bool {
	for name, g in p.names {
		if g > 0 && name == n.name {
			if n.kind == .Cond {
				n.group = g
			} else {
				append(&n.refs, g)
			}
		}
	}
	if len(n.refs) == 0 && n.group == 0 {
		fail(p, strings.concatenate({"undefined name <", n.name, "> reference"}))
		return false
	}
	return true
}

// A backreference or condition, checked once every group is known (`resolve_refs`). A backreference within a
// group it names is marked, as Oniguruma's parser marks one to a group not yet closed.
add_ref :: proc(p: ^Parser, n: ^Node) {
	for g in n.refs {
		n.recursion ||= slice.contains(p.open[:], g)
	}
	append(&p.refs, n)
}

// Numbered backreferences and conditions may name groups that come later, so they are checked at the end,
// and the groups they read marked.
resolve_refs :: proc(p: ^Parser, referenced: []bool) {
	for n in p.refs {
		if n.name == "" {
			g := n.group if n.kind == .Cond else n.refs[0]
			if g <= 0 || g >= len(p.names) {
				fail(p, "invalid backref number/name")
				return
			}
		} else if p.flags.ecma {
			g, found := slice.linear_search(p.names[1:], n.name)
			if !found {
				fail(p, "invalid named reference")
				return
			}
			append(&n.refs, g + 1)
		}
		if n.kind == .Cond {
			referenced[n.group] = true
		}
		for g in n.refs {
			referenced[g] = true
		}
	}
}

// Each call's group (check_call_reference). A call of the whole pattern puts it under a group 0 of its own.
resolve_calls :: proc(p: ^Parser) {
	for n in p.calls {
		g := n.group
		if g < 0 {
			for name, k in p.names {
				if k > 0 && name == n.name {
					if g >= 0 {
						fail(p, strings.concatenate({"multiplex definition name <", n.name, "> call"}))
						return
					}
					g = k
				}
			}
			if g < 0 {
				fail(p, strings.concatenate({"undefined name <", n.name, "> reference"}))
				return
			}
		} else if g >= len(p.names) {
			fail(p, strings.concatenate({"undefined group <", n.name, "> reference"}))
			return
		}
		if g == 0 && p.groups[0] == nil {
			p.groups[0] = new_node(.Group)
		}
		n.target = p.groups[g]
	}
}

// At `<` or `'` after \k: `\k<name>`, `\k<n>` or `\k<-n>`.
parse_backref_name :: proc(p: ^Parser) -> ^Node {
	close: byte = '>' if peek(p) == '<' else '\''
	p.i += 1
	name, named := read_name(p, close)
	if !named {
		return nil
	}
	n := new_node(.Backref)
	n.fold = p.flags.fold
	switch name[0] {
	case '0' ..= '9', '-', '+':
		num, rel := 0, name[0] == '-'
		digits := name[1:] if name[0] == '-' || name[0] == '+' else name
		if name[0] == '+' || digits == "" {
			return fail(p, "invalid backref number/name")
		}
		j := 0
		if num, _ = number(digits, &j, MAX_BACKREF + 1); j < len(digits) {
			return fail(p, "invalid backref number/name")
		}
		if rel {
			num = len(p.names) - num
		}
		if num <= 0 {
			return fail(p, "invalid backref number/name")
		}
		append(&n.refs, num)
	case:
		n.name = name
		if !resolve_name(p, n) {
			return nil
		}
	}
	add_ref(p, n)
	return n
}

// A call's name up to `close`, after `\g<`, `\g'` or `(?&`, or at the number of `(?1)`: a group by number, by
// number relative to the groups opened so far (`-1` the last, `+1` the next), or by name, read as Oniguruma's
// fetch_name reads one, with its messages. A name of odd characters is still a name, which no group has.
parse_call :: proc(p: ^Parser, close: rune) -> ^Node {
	start := p.i
	if at_end(p) || rune(peek(p)) == close {
		return fail(p, "group name is empty")
	}
	c := next_rune(p)
	numeric, sign := c >= '0' && c <= '9', c == '-' || c == '+'
	if !numeric && !sign && !is_word(c) {
		return refuse_name(p, start, close, "invalid char in group name <")
	}
	numeric ||= sign
	name_end := len(p.src)
	for !at_end(p) {
		name_end = p.i
		if c = next_rune(p); c == close || c == ')' {
			break
		}
		numeric &&= c >= '0' && c <= '9'
	}
	name := p.src[start:name_end]
	if c != close {
		return fail(p, strings.concatenate({"invalid group name <", name, ">"}))
	}
	if close == ')' && !numeric && name[0] <= '9' {
		return fail(p, "invalid group name <>") // `(?1x)`, a number of (?n) that runs on, as Oniguruma words it
	}
	n := new_node(.Call)
	n.name, n.group = name, -1
	append(&p.calls, n)
	if !numeric {
		return n
	}
	j := int(sign)
	num, _ := number(name, &j, int(max(i32)) + 1)
	if num > int(max(i32)) {
		return fail(p, "too big number")
	}
	if sign && num == 0 {
		return fail(p, strings.concatenate({"invalid group name <", name, ">"}))
	}
	opened := len(p.names) - 1
	switch name[0] {
	case '-':
		n.group = opened + 1 - num
	case '+':
		n.group = opened + num if num <= int(max(i32)) - opened else -1
	case:
		n.group = num
	}
	if n.group < 0 {
		return fail(p, strings.concatenate({"undefined group <", name, "> reference"}))
	}
	return n
}

// Fails with `msg` and the name from `start`, read up to `close` or `)`, or to the pattern's end when that comes
// first or right after, as Oniguruma words a name it refuses.
refuse_name :: proc(p: ^Parser, start: int, close: rune, msg: string) -> ^Node {
	name_end := len(p.src)
	for !at_end(p) {
		name_end = p.i
		if c := next_rune(p); c == close || c == ')' {
			break
		}
	}
	if at_end(p) {
		name_end = len(p.src)
	}
	return fail(p, strings.concatenate({msg, p.src[start:name_end], ">"}))
}
