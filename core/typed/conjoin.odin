package typed

import "base:runtime"
import regex "../regex"
import rules "../rules"
import "core:mem"

// The verdict-only reading of the `allOf` and `$ref` arms of a description: the nodes those arms and their holder's
// own keywords conjoin into one node, which a check with no sink reads as one arm. A failure then has no single
// keyword path, so a check with a sink reads the arms one by one.
@(private)
Conjoined :: struct {
	// The node the plain parts conjoin into, the targets that judge by arms of their own, and the targets whose `not`
	// and `if` arms the holder takes as its own.
	node:   rules.Node_Index,
	held:   []rules.Node_Index,
	lifted: []rules.Node_Index,
	// The holder's `anyOf` or `oneOf` arms, each conjoined with `node`, which the holder then reads in its place.
	arms:   []rules.Node_Index,
}

// The description `d` with the conjoined node of each holder whose arms conjoin, in `arena`, recorded in `b.conjoined`.
// `d` itself is returned unchanged when a node judges by a dynamic scope or by what was evaluated, which conjoining
// would move.
@(private)
conjoin_description :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator) -> rules.Description {
	if len(d.anchors) > 0 {
		return d^
	}
	for &n in d.nodes {
		if n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil {
			return d^
		}
	}
	x := d^
	x.nodes, x.objects, x.arrays = make([dynamic]rules.Node, arena), make([dynamic]rules.Object, arena), make([dynamic]rules.Array, arena)
	append(&x.nodes, ..d.nodes[:])
	append(&x.objects, ..d.objects[:])
	append(&x.arrays, ..d.arrays[:])
	x.allocator = arena
	b.conjoined.allocator, b.pairs.allocator, b.inline.allocator = arena, arena, arena
	inline_patterns(b, &x, arena)
	// Conjoining appends the nodes that two members' values make, which the loop reaches in turn.
	for i := 0; i < len(x.nodes); i += 1 {
		n := x.nodes[i]
		// A value passes the parts and one arm of a run exactly when it passes one arm conjoined with the parts.
		group := n.any_of if len(n.one_of) == 0 else n.one_of if len(n.any_of) == 0 else nil
		spread := len(group) > 0 && n.not == nil && n.cond == {}
		if n.ref == nil && len(n.all_of) == 0 && !spread || !own_plain(b, &x, &n) {
			continue
		}
		c := Conjoining{make([dynamic]rules.Node_Index, arena), make([dynamic]rules.Node_Index, arena), make([dynamic]rules.Node_Index, arena)}
		conjoin_into(b, &x, n, &c, 0)
		spread &&= len(c.held) == 0 && len(c.lifted) == 0 && len(c.parts) > 0
		if !spread && (len(c.parts) < 2 && len(c.lifted) == 0 || len(c.parts) == 0) {
			continue
		}
		node, ok := conjoin_nodes(b, &x, c.parts[:], arena)
		if !ok {
			continue
		}
		arms: []rules.Node_Index
		if spread {
			arms = make([]rules.Node_Index, len(group), arena)
			for &a, j in arms {
				a = conjoin_pair(b, &x, node, group[j])
			}
		}
		b.conjoined[rules.Node_Index(i)] = Conjoined{node, c.held[:], c.lifted[:], arms}
	}
	return x
}

// The record of an arm that judges by `node` in a check with no sink: that of its conjoined node when it has one and
// nothing else, which reads with no arms.
@(private)
verdict_record :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index) -> i32 {
	if c, ok := b.conjoined[node]; ok && len(c.held) == 0 && len(c.lifted) == 0 && c.arms == nil {
		return arm_record(b, d, arena, c.node)
	}
	return arm_record(b, d, arena, node)
}

@(private = "file")
Conjoining :: struct {
	parts, held, lifted: [dynamic]rules.Node_Index,
}

// Adds the node `n` to `c`: its own keywords past its arms as a part, and the targets of its `$ref` and `allOf`.
// `depth` bounds the targets passed through.
@(private = "file")
conjoin_into :: proc(b: ^Builder, d: ^rules.Description, n: rules.Node, c: ^Conjoining, depth: int) {
	n := n
	if bare_judges(b, d, &n, {}) {
		stripped := n
		stripped.ref, stripped.all_of, stripped.any_of, stripped.one_of, stripped.not, stripped.cond = nil, nil, nil, nil, nil, {}
		append(&d.nodes, stripped)
		append(&c.parts, rules.Node_Index(len(d.nodes) - 1))
	}
	if r, has := n.ref.?; has {
		conjoin_part(b, d, r, c, depth)
	}
	for r in n.all_of {
		conjoin_part(b, d, r, c, depth)
	}
}

// Adds the target of `node` to `c`: as a part when it judges by no arm, by its own parts when its arms are only
// `allOf`, `$ref`, `not` and `if`, which the holder then takes, and else held apart.
@(private = "file")
conjoin_part :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, c: ^Conjoining, depth: int) {
	x, _ := reached(d, node)
	if x == rules.NONE {
		return
	}
	n := d.nodes[x]
	switch {
	case !holds(b, d, x, {}):
		append(&c.parts, x)
	case depth < MAX_HELD && own_plain(b, d, &n) && len(n.any_of) == 0 && len(n.one_of) == 0:
		conjoin_into(b, d, n, c, depth + 1)
		if n.not != nil || n.cond.test != nil {
			append(&c.lifted, x)
		}
	case:
		append(&c.held, x)
	}
}

// Whether `n`'s own keywords, past its `allOf` and `$ref`, are ones a conjoined node keeps: none an arm of the holder
// judges beside them.
@(private = "file")
own_plain :: proc(b: ^Builder, d: ^rules.Description, n: ^rules.Node) -> bool {
	if n.rules.unique || container_operands(n) {
		return false
	}
	if n.object >= 0 && (len(d.objects[n.object].patterns) > 0 && n.object not_in b.inline || dependent_schemas(&d.objects[n.object])) {
		return false
	}
	return n.array < 0 || d.arrays[n.array].contains == nil
}

// The node that takes what each of the plain nodes `parts` takes, appended to `d`. Fails when two parts have rules,
// an enum or a spelling of integers the node cannot hold both of.
@(private = "file")
conjoin_nodes :: proc(b: ^Builder, d: ^rules.Description, parts: []rules.Node_Index, arena: runtime.Allocator) -> (rules.Node_Index, bool) {
	out := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, resource = d.nodes[parts[0]].resource}
	ruled, listed := false, false
	objects, arrays := false, false
	for p in parts {
		n := d.nodes[p]
		if n.integer_spelled != d.nodes[parts[0]].integer_spelled || n.resource != out.resource {
			return 0, false
		}
		out.integer_spelled = n.integer_spelled
		out.kinds = widened(out.kinds) & widened(n.kinds)
		if n.rules != {} {
			if ruled {
				return 0, false
			}
			out.rules, ruled = n.rules, true
		}
		if n.has_enum || n.const_of != nil {
			if listed {
				return 0, false
			}
			out.has_enum, out.enum_of, out.const_of, listed = n.has_enum, n.enum_of, n.const_of, true
		}
		if n.object >= 0 && len(d.objects[n.object].patterns) > 0 {
			return 0, false
		}
		objects ||= n.object >= 0
		arrays ||= n.array >= 0
	}
	if objects {
		o, ok := conjoin_objects(b, d, parts, arena)
		if !ok {
			return 0, false
		}
		out.object = i32(len(d.objects))
		append(&d.objects, o)
	}
	if arrays {
		out.array = i32(len(d.arrays))
		append(&d.arrays, conjoin_arrays(b, d, parts, arena))
	}
	append(&d.nodes, out)
	return rules.Node_Index(len(d.nodes) - 1), true
}

// The kinds with `.Integer` beside `.Number`, which takes every integer.
@(private = "file")
widened :: proc(k: rules.Kinds) -> rules.Kinds {
	return k + {.Integer} if .Number in k else k
}

// The object block of the conjoined parts: each name any part gives, valued by what every part takes for it.
@(private = "file")
conjoin_objects :: proc(b: ^Builder, d: ^rules.Description, parts: []rules.Node_Index, arena: runtime.Allocator) -> (rules.Object, bool) {
	ANY :: rules.Object{additional = rules.NONE, keys = rules.NONE}
	out := ANY
	members, dependents := make([dynamic]rules.Member, arena), make([dynamic]rules.Dependent, arena)
	for p in parts {
		o := d.objects[d.nodes[p].object] if d.nodes[p].object >= 0 else ANY
		out.additional = conjoin_pair(b, d, out.additional, o.additional)
		out.keys = conjoin_pair(b, d, out.keys, o.keys)
		append(&dependents, ..o.dependents)
		for m in o.members {
			if !has_member(members[:], m.name) {
				append(&members, rules.Member{name = m.name, node = rules.NONE, only_required = true})
			}
		}
	}
	for &m in members {
		for p in parts {
			o := d.objects[d.nodes[p].object] if d.nodes[p].object >= 0 else ANY
			value := o.additional
			for x in o.members {
				if x.name != m.name {
					continue
				}
				m.required ||= x.required
				value = o.additional if x.only_required else x.node
				if x.rules != {} {
					if m.rules != {} {
						return {}, false
					}
					m.rules = x.rules
				}
				if !x.only_required {
					m.only_required = false
				}
			}
			if value != rules.NONE {
				m.node, m.only_required = conjoin_pair(b, d, m.node, value), false
			}
		}
	}
	out.members, out.dependents = members[:], dependents[:]
	return out, true
}

// Whether `members` names `name`.
@(private = "file")
has_member :: proc(members: []rules.Member, name: string) -> bool {
	for m in members {
		if m.name == name {
			return true
		}
	}
	return false
}

// The array block of the conjoined parts: each place valued by what every part takes there.
@(private = "file")
conjoin_arrays :: proc(b: ^Builder, d: ^rules.Description, parts: []rules.Node_Index, arena: runtime.Allocator) -> rules.Array {
	ANY :: rules.Array{items = rules.NONE}
	places := 0
	for p in parts {
		if d.nodes[p].array >= 0 {
			places = max(places, len(d.arrays[d.nodes[p].array].prefix))
		}
	}
	out := ANY
	prefix := make([]rules.Node_Index, places, arena)
	for &x in prefix {
		x = rules.NONE
	}
	for p in parts {
		a := d.arrays[d.nodes[p].array] if d.nodes[p].array >= 0 else ANY
		for &x, i in prefix {
			x = conjoin_pair(b, d, x, a.prefix[i] if i < len(a.prefix) else a.items)
		}
		out.items = conjoin_pair(b, d, out.items, a.items)
	}
	out.prefix = prefix
	return out
}

// The node that takes what both `x` and `y` take: one of them when the other takes anything or they are one node,
// else an `allOf` of both, made once per pair.
@(private = "file")
conjoin_pair :: proc(b: ^Builder, d: ^rules.Description, x, y: rules.Node_Index) -> rules.Node_Index {
	switch {
	case x == rules.NONE || x == y:
		return y
	case y == rules.NONE:
		return x
	case takes_all(b, d, x):
		return y
	case takes_all(b, d, y):
		return x
	}
	key := [2]rules.Node_Index{min(x, y), max(x, y)}
	if at, ok := b.pairs[key]; ok {
		return at
	}
	both := make([]rules.Node_Index, 2, d.allocator)
	both[0], both[1] = x, y
	append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, all_of = both, resource = d.nodes[x].resource})
	at := rules.Node_Index(len(d.nodes) - 1)
	b.pairs[key] = at
	return at
}

// Whether `node` takes every value.
@(private = "file")
takes_all :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index) -> bool {
	x, _ := reached(d, node)
	if x == rules.NONE {
		return true
	}
	n := &d.nodes[x]
	return n.kinds == rules.EVERY_KIND && n.object < 0 && n.array < 0 && !bare_judges(b, d, n, {}) && !holds(b, d, x, {})
}

// Records in `b.inline` each object of `d` with one pattern that names none of its members, which its record then reads
// as it reads its other members, with no arm.
@(private = "file")
inline_patterns :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator) {
	room: [SCRATCH_ROOM]u8 = ---
	stack: mem.Arena
	scratch := stack_scratch(&stack, room[:])
	objects: for o, i in d.objects {
		if len(o.patterns) != 1 {
			continue
		}
		p := o.patterns[0]
		re, err := regex.compile(p.expression, {ecma = true}, arena)
		if err != "" {
			continue
		}
		for m in o.members {
			if matches(&re, m.name, &scratch) {
				continue objects
			}
		}
		b.inline[i32(i)] = Inline_Pattern{p.expression, p.node, new_clone(re, arena)}
	}
}
