package jq

import "core:fmt"
import "stury:lib/query"

// A binding whose object pattern has a key expression that may give several outputs, such as `. as {("a", "b"): $x}`,
// written as nested bindings of one variable each. Each key then runs as a binding's source, the body once for each of
// its outputs, and a later key reads the variables bound before it.

// Whether key expression `key` gives exactly one output on any input: made only of what has one, with no call.
@(private)
key_is_plain :: proc(key: ^Node) -> bool {
	stack := make([dynamic]^Node, 0, 8)
	defer delete(stack)
	append(&stack, key)
	for len(stack) > 0 {
		n := pop(&stack)
		if n == nil {
			continue
		}
		#partial switch n.kind {
		case .Identity, .Literal, .Var, .Array:
		case .Field, .Neg, .Format:
			append(&stack, n.a)
		case .Index, .Pipe, .Binary, .And, .Or:
			append(&stack, n.a, n.b)
		case .Slice:
			append(&stack, n.a, n.b, n.c)
		case .String, .Object:
			append(&stack, ..n.args)
		case:
			return false
		}
	}
	return true
}

@(private)
Binding_Step :: struct {
	source: ^Node,
	name:   string,
}

@(private)
Pattern_Cursor :: struct {
	pattern: ^Pattern,
	from:    string, // the variable holding the value it destructures
	next:    int, // the next element or member
}

// `src as pat | body` as bindings of one variable each, taking the pattern's members in the order a binding does.
@(private)
bind_by_steps :: proc(p: ^Parser, src: ^Node, pat: ^Pattern, body: ^Node, at: Loc) -> ^Node {
	unit_mark := len(p.unit.order)
	made := 0
	fresh :: proc(mark: int, made: ^int) -> string {
		made^ += 1
		return fmt.aprintf("#%d.%d", mark, made^)
	}
	ref :: proc(p: ^Parser, name: string, at: Loc) -> ^Node {
		return mk(p, Node{kind = .Var, name = name, loc = at})
	}
	steps := make([dynamic]Binding_Step, 0, 8)
	defer delete(steps)
	stack := make([dynamic]Pattern_Cursor, 0, 8)
	defer delete(stack)
	root := fresh(unit_mark, &made)
	append(&steps, Binding_Step{src, root})
	append(&stack, Pattern_Cursor{pat, root, 0})
	for len(stack) > 0 {
		c := pop(&stack)
		sub: ^Pattern
		held: string
		switch c.pattern.kind {
		case .Var:
			append(&steps, Binding_Step{ref(p, c.from, at), c.pattern.name})
			continue
		case .Array:
			if c.next >= len(c.pattern.elems) {
				continue
			}
			held = fresh(unit_mark, &made)
			index := mk(p, Node{kind = .Literal, value = query.int_value(i64(c.next)), loc = at})
			append(&steps, Binding_Step{mk(p, Node{kind = .Index, a = ref(p, c.from, at), b = index, loc = at}), held})
			sub = c.pattern.elems[c.next]
		case .Object:
			if c.next >= len(c.pattern.members) {
				continue
			}
			mem := c.pattern.members[c.next]
			key := fresh(unit_mark, &made)
			held = fresh(unit_mark, &made)
			append(&steps, Binding_Step{mem.key, key})
			append(&steps, Binding_Step{mk(p, Node{kind = .Index, a = ref(p, c.from, at), b = ref(p, key, at), loc = at}), held})
			if mem.var != "" {
				append(&steps, Binding_Step{ref(p, held, at), mem.var})
			}
			sub = mem.pattern
		}
		c.next += 1
		append(&stack, c)
		if sub != nil {
			append(&stack, Pattern_Cursor{sub, held, 0})
		}
	}
	out := body
	#reverse for s in steps {
		pats := make([]^Pattern, 1)
		pats[0] = new_clone(Pattern{kind = .Var, name = s.name})
		out = mk(p, Node{kind = .Bind, a = s.source, b = out, patterns = pats, loc = at})
	}
	return out
}
