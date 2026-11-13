package typed

import "base:runtime"
import rules "../rules"
import "core:mem"

// A check with no sink reads a holder's `allOf` and `$ref` targets, with the holder's own keywords, as one conjoined
// node. A failure in that node has no single keyword path, so a check with a sink reads the arms one by one.
@(private)
Conjoined :: struct {
	// `node` conjoins the plain parts. `held` are the targets that keep arms of their own. `lifted` are the targets
	// whose `not` and `if` arms the holder takes over.
	node:   rules.Node_Index,
	held:   []rules.Node_Index,
	lifted: []rules.Node_Index,
	// The holder's `anyOf` or `oneOf` arms, each conjoined with `node`. The holder reads these instead of `node`.
	arms:   []rules.Node_Index,
}

// A copy of `d` in `arena` with its fixed evaluated sets settled and a conjoined node added for each holder whose arms
// conjoin, recorded in `b.conjoined`. Nodes that `kept_apart` marks are not conjoined.
@(private)
conjoin_description :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator) -> rules.Description {
	x := d^
	x.nodes, x.objects, x.arrays = make([dynamic]rules.Node, arena), make([dynamic]rules.Object, arena), make([dynamic]rules.Array, arena)
	append(&x.nodes, ..d.nodes[:])
	append(&x.objects, ..d.objects[:])
	append(&x.arrays, ..d.arrays[:])
	x.allocator = arena
	b.conjoined.allocator, b.pairs.allocator, b.inline.allocator, b.stripped.allocator, b.chain_ends.allocator = arena, arena, arena, arena, arena
	b.nothing.allocator = arena
	settle_unevaluated(b, &x, arena)
	inline_patterns(b, &x, arena)
	kept := kept_apart(&x, arena)
	// Conjoining appends nodes for pairs of member values, and the loop visits those too.
	for i := 0; i < len(x.nodes); i += 1 {
		if i < len(kept) && kept[i] {
			continue
		}
		n := x.nodes[i]
		// A value passes the parts and one arm of a run exactly when it passes one arm conjoined with the parts.
		group := n.any_of if len(n.one_of) == 0 else n.one_of if len(n.any_of) == 0 else nil
		spread := len(group) > 0 && n.not == nil && n.cond == {}
		if n.ref == nil && len(n.all_of) == 0 && !spread || !own_plain(b, &x, &n) {
			continue
		}
		c := Conjoining{parts = make([dynamic]rules.Node_Index, arena), held = make([dynamic]rules.Node_Index, arena), lifted = make([dynamic]rules.Node_Index, arena), seen = make(map[rules.Node_Index]struct{}, arena)}
		conjoin_into(b, &x, rules.Node_Index(i), &c, 0)
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

// The nodes of `d` that must not be conjoined, because conjoining them would change a dynamic scope or an evaluated
// set: every node that reaches a `$dynamicRef` or an unevaluated keyword through any keyword, and every node that the
// holder of an unevaluated keyword reaches in place.
@(private = "file")
kept_apart :: proc(d: ^rules.Description, arena: runtime.Allocator) -> []bool {
	kept := make([]bool, len(d.nodes), arena)
	next := make([dynamic]rules.Node_Index, arena)
	for &n, i in d.nodes {
		kept[i] = n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil
	}
	// A node that reaches a kept node is kept, so walk the edges backwards from the kept nodes. The parents of node x
	// are `parents[starts[x]:starts[x + 1]]`.
	count := len(d.nodes)
	starts := make([]int, count + 2, arena)
	for &n in d.nodes {
		clear(&next)
		rules.node_children(d, &n, &next, false)
		for x in next {
			if x != rules.NONE {
				starts[x + 2] += 1
			}
		}
	}
	for i in 2 ..< len(starts) {
		starts[i] += starts[i - 1]
	}
	parents := make([]rules.Node_Index, starts[count + 1], arena)
	for &n, i in d.nodes {
		clear(&next)
		rules.node_children(d, &n, &next, false)
		for x in next {
			if x != rules.NONE {
				parents[starts[x + 1]] = rules.Node_Index(i)
				starts[x + 1] += 1
			}
		}
	}
	work := make([dynamic]rules.Node_Index, arena)
	for k, i in kept {
		if k {
			append(&work, rules.Node_Index(i))
		}
	}
	for len(work) > 0 {
		x := pop(&work)
		for y in parents[starts[x]:starts[x + 1]] {
			if !kept[y] {
				kept[y] = true
				append(&work, y)
			}
		}
	}
	reached := make([]bool, len(d.nodes), arena)
	clear(&next)
	for &n, i in d.nodes {
		if n.unevaluated_items != nil || n.unevaluated_properties != nil {
			append(&next, rules.Node_Index(i))
		}
	}
	for len(next) > 0 {
		x := pop(&next)
		if x == rules.NONE || reached[x] {
			continue
		}
		reached[x], kept[x] = true, true
		rules.node_children(d, &d.nodes[x], &next, true)
	}
	return kept
}

// The record a check with no sink uses for an arm on `node`: the record of its conjoined node when that node has no
// held, lifted or spread arms and so reads with no arms, else `node`'s own record.
@(private)
verdict_record :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index) -> i32 {
	if c, ok := b.conjoined[node]; ok && len(c.held) == 0 && len(c.lifted) == 0 && c.arms == nil {
		return arm_record(b, d, arena, c.node)
	}
	return arm_record(b, d, arena, node)
}

// `seen` holds the targets already joined. `allOf` is idempotent, so each target joins once.
@(private = "file")
Conjoining :: struct {
	parts, held, lifted: [dynamic]rules.Node_Index,
	seen:                map[rules.Node_Index]struct{},
}

// Adds node `at` to `c`: its own keywords without its arms as one part, then the targets of its `$ref` and `allOf`.
// `depth` bounds how deep the targets nest.
@(private = "file")
conjoin_into :: proc(b: ^Builder, d: ^rules.Description, at: rules.Node_Index, c: ^Conjoining, depth: int) {
	n := d.nodes[at]
	if part, judges := stripped_part(b, d, at, &n); judges {
		append(&c.parts, part)
	}
	if r, has := n.ref.?; has {
		conjoin_part(b, d, r, c, depth)
	}
	for r in n.all_of {
		conjoin_part(b, d, r, c, depth)
	}
}

// A copy of node `at` (`n`) without its arms, appended to `d` once however many holders conjoin `at`. `judges` is false
// when the copy would judge nothing.
@(private = "file")
stripped_part :: proc(b: ^Builder, d: ^rules.Description, at: rules.Node_Index, n: ^rules.Node) -> (part: rules.Node_Index, judges: bool) {
	if part, judges = b.stripped[at]; judges {
		return part, part != rules.NONE
	}
	part = rules.NONE
	if bare_judges(b, d, n, {}) {
		stripped := n^
		stripped.ref, stripped.all_of, stripped.any_of, stripped.one_of, stripped.not, stripped.cond = nil, nil, nil, nil, nil, {}
		append(&d.nodes, stripped)
		part = rules.Node_Index(len(d.nodes) - 1)
	}
	b.stripped[at] = part
	return part, part != rules.NONE
}

// The node reached from `node` by following each `$ref` that holds nothing else, `NONE` for a loop. Every node on the
// chain caches the end, so a chain of n references costs n steps in total however many of its nodes are asked.
@(private = "file")
chain_end :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index) -> rules.Node_Index {
	if node == rules.NONE || !rules.ref_only(&d.nodes[node]) {
		return node
	}
	if end, known := b.chain_ends[node]; known {
		return end
	}
	path := make([dynamic]rules.Node_Index, context.temp_allocator)
	x := node
	for x != rules.NONE && rules.ref_only(&d.nodes[x]) {
		if end, known := b.chain_ends[x]; known {
			x = end
			break
		}
		if len(path) == len(d.nodes) {
			x = rules.NONE
			break
		}
		append(&path, x)
		x = d.nodes[x].ref.?
	}
	for p in path {
		b.chain_ends[p] = x
	}
	return x
}

// Adds the target of `node` to `c`. A target with no arms becomes a part. A target whose arms are only `allOf`, `$ref`,
// `not` and `if` is split into its own parts, and the holder takes its `not` and `if`. Any other target is held apart.
@(private = "file")
conjoin_part :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, c: ^Conjoining, depth: int) {
	x := chain_end(b, d, node)
	if x == rules.NONE {
		return
	}
	if x in c.seen {
		return
	}
	c.seen[x] = {}
	n := d.nodes[x]
	switch {
	case !holds(b, d, x, {}):
		append(&c.parts, x)
	case depth < MAX_HELD && own_plain(b, d, &n) && len(n.any_of) == 0 && len(n.one_of) == 0:
		conjoin_into(b, d, x, c, depth + 1)
		if n.not != nil || n.cond.test != nil {
			append(&c.lifted, x)
		}
	case:
		append(&c.held, x)
	}
}

// Whether a conjoined node can hold `n`'s own keywords, apart from its `allOf` and `$ref`: none of them may need an
// arm of the holder.
@(private = "file")
own_plain :: proc(b: ^Builder, d: ^rules.Description, n: ^rules.Node) -> bool {
	if n.rules.unique || arm_operands(n) {
		return false
	}
	if n.object >= 0 && (len(d.objects[n.object].patterns) > 0 && n.object not_in b.inline || dependent_schemas(&d.objects[n.object])) {
		return false
	}
	return n.array < 0 || d.arrays[n.array].contains == nil
}

// Appends to `d` a node that takes exactly what every one of the plain nodes `parts` takes. Fails when two parts both
// have rules or both an enum, when their integer spellings or resources differ, or when a part has patterns.
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

// `k` with `.Integer` added when it has `.Number`, since a number kind takes every integer.
@(private = "file")
widened :: proc(k: rules.Kinds) -> rules.Kinds {
	return k + {.Integer} if .Number in k else k
}

// The object block of the conjoined parts: every member name any part has, valued by what all parts take for it.
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

@(private = "file")
has_member :: proc(members: []rules.Member, name: string) -> bool {
	for m in members {
		if m.name == name {
			return true
		}
	}
	return false
}

// The array block of the conjoined parts: each position valued by what all parts take there.
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

// A node that takes what both `x` and `y` take: one of them when the other takes anything or both are the same node,
// otherwise an `allOf` of the two, made once per pair.
@(private = "file")
conjoin_pair :: proc(b: ^Builder, d: ^rules.Description, x, y: rules.Node_Index) -> rules.Node_Index {
	switch {
	case x == rules.NONE || x == y:
		return y
	case y == rules.NONE:
		return x
	case judges_nothing(d, x, &b.nothing):
		return y
	case judges_nothing(d, y, &b.nothing):
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

// Records in `b.inline` each object of `d` whose single pattern matches none of its member names. Its record then reads
// the pattern's members like its other members, with no arm.
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
		re, err := rules.program_of(&b.programs, p.expression, arena)
		if err != "" {
			continue
		}
		for m in o.members {
			if hit, gave_up := matches(re, m.name, &scratch); hit || gave_up {
				continue objects
			}
		}
		// The names `dependentRequired` lists are members of the record too.
		for x in o.dependents {
			if hit, gave_up := matches(re, x.name, &scratch); hit || gave_up {
				continue objects
			}
			for name in x.required {
				if hit, gave_up := matches(re, name, &scratch); hit || gave_up {
					continue objects
				}
			}
		}
		b.inline[i32(i)] = Inline_Pattern{p.expression, p.node, re}
	}
}
