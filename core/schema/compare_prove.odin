package schema

import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../spell"
import core "../"
import "../rules"

// The proof that every value one description takes, another takes too. A schema is a conjunction of nodes (itself, its
// `$ref` and its `allOf`) and a disjunction of branches (its `anyOf`), and the proof checks each branch of the first
// against some branch of the second, facet by facet. A pair the proof cannot decide is refused, never assumed.

@(private = "file")
MAX_BRANCHES :: 32

@(private)
MAX_DEPTH :: 24

// The values of an enum a proof judges one by one.
@(private = "file")
MAX_FINITE :: 8192

@(private = "file")
STEP_BUDGET :: 40_000

// The two descriptions of a proof: the one whose values must be taken is `from`, the one that must take them `to`.
@(private)
Prover :: struct {
	from, to: ^Side,
	steps:    int,
	// Set once the proof ran past `STEP_BUDGET`, after which no answer it gave is one: what it failed to show it did
	// not refute, and a proof that leaned on a failure is not one.
	exhausted: bool,
	// The keyword of the first facet a refusal named.
	why:      string,
	// The pairs under proof. A pair met again inside its own proof holds, as a recursive schema's proof needs.
	running:  map[string]struct{},
	// How many `same_node` calls are open, which a chain of references would otherwise carry to the stack's end.
	nested:   int,
}

// The deepest `same_node` goes before it says the nodes differ, which is always safe to say.
@(private)
MAX_SAME_NESTING :: 512

// Counts a step of the proof, and reports whether the budget is gone.
@(private)
spent :: proc(p: ^Prover) -> bool {
	p.steps += 1
	if p.steps > STEP_BUDGET {
		p.exhausted = true
		refuse(p, "budget")
	}
	return p.exhausted
}

@(private)
refuse :: proc(p: ^Prover, why: string) -> bool {
	if p.why == "" {
		p.why = why
	}
	return false
}

// Whether every value of the conjunction `a` of nodes of `p.from` is a value of the conjunction `b` of nodes of `p.to`.
@(private)
included :: proc(p: ^Prover, a, b: []rules.Node_Index, depth: int) -> bool {
	if spent(p) {
		return false
	}
	if depth > MAX_DEPTH {
		return refuse(p, "depth")
	}
	if len(a) == 1 && len(b) == 1 && same_node(p, a[0], b[0]) {
		return true
	}
	key := strings.concatenate({conjunction_key(p.from.d, a), "|", conjunction_key(p.to.d, b)}, context.temp_allocator)
	if key in p.running {
		return true
	}
	p.running[key] = {}
	defer delete_key(&p.running, key)
	as, a_fits := branches(p.from.d, a)
	bs, b_fits := branches(p.to.d, b)
	if !a_fits || !b_fits {
		return refuse(p, "anyOf")
	}
	for ab in as {
		covered := false
		for bb in bs {
			if covered = branch_included(p, a, b, ab, bb, depth); covered {
				break
			}
		}
		if !covered {
			return false
		}
	}
	return true
}

// Whether the node says nothing but the node its `$ref` names.
@(private = "file")
ref_only :: proc(n: ^rules.Node) -> bool {
	return n.ref != nil && n.kinds == rules.EVERY_KIND && !n.integer_spelled && n.rules == {} && n.array < 0 && n.object < 0 && len(n.any_of) == 0 && !n.has_enum && n.const_of == nil && len(n.all_of) == 0 && len(n.one_of) == 0 && n.not == nil && n.cond == {} && n.dynamic_ref == nil && n.unevaluated_items == nil && n.unevaluated_properties == nil
}

// The conjunction `ids` as a key, each node replaced by the node a chain of nodes that only name it reaches, in order
// and once, so two spellings of one conjunction share it.
@(private = "file")
conjunction_key :: proc(d: ^rules.Description, ids: []rules.Node_Index) -> string {
	reached := make([dynamic]rules.Node_Index, 0, len(ids), context.temp_allocator)
	for id in ids {
		at := id
		for hops := 0; hops < MAX_DEPTH * 4 && ref_only(&d.nodes[at]); hops += 1 {
			at = d.nodes[at].ref.?
		}
		append(&reached, at)
	}
	slice.sort(reached[:])
	kept := 0
	for id, i in reached {
		if i == 0 || id != reached[i - 1] {
			reached[kept] = id
			kept += 1
		}
	}
	return string(slice.to_bytes(reached[:kept]))
}

// The conjunctions that `nodes` alternate between: each `anyOf` splits a conjunction by its arms, and a `$ref` and an
// `allOf` join their targets to it. False when there are too many to follow.
@(private)
branches :: proc(d: ^rules.Description, nodes: []rules.Node_Index) -> (out: [][dynamic]rules.Node_Index, fits: bool) {
	Open :: struct {
		nodes: [dynamic]rules.Node_Index,
		next:  int,
	}
	work := make([dynamic]Open, context.temp_allocator)
	first := Open{nodes = make([dynamic]rules.Node_Index, context.temp_allocator)}
	append(&first.nodes, ..nodes)
	append(&work, first)
	done := make([dynamic][dynamic]rules.Node_Index, context.temp_allocator)
	for len(work) > 0 {
		if len(work) + len(done) > MAX_BRANCHES {
			return nil, false
		}
		cur := pop(&work)
		forked := false
		for cur.next < len(cur.nodes) && !forked {
			n := &d.nodes[cur.nodes[cur.next]]
			cur.next += 1
			if target, has := n.ref.?; has && !slice.contains(cur.nodes[:], target) {
				append(&cur.nodes, target)
			}
			for m in n.all_of {
				if !slice.contains(cur.nodes[:], m) {
					append(&cur.nodes, m)
				}
			}
			if len(n.any_of) > 0 {
				forked = true
				for arm in n.any_of {
					fork := Open{nodes = slice.clone_to_dynamic(cur.nodes[:], context.temp_allocator), next = cur.next}
					if !slice.contains(fork.nodes[:], arm) {
						append(&fork.nodes, arm)
					}
					append(&work, fork)
				}
			}
		}
		if !forked {
			append(&done, cur.nodes)
		}
	}
	return done[:], true
}

@(private)
nodes_of :: proc(d: ^rules.Description, ids: []rules.Node_Index) -> []^rules.Node {
	out := make([]^rules.Node, len(ids), context.temp_allocator)
	for id, i in ids {
		out[i] = &d.nodes[id]
	}
	return out
}

// The kinds that a conjunction takes, `Number` counting its integers.
@(private)
kinds_of :: proc(ns: []^rules.Node) -> rules.Kinds {
	k := rules.EVERY_KIND
	for n in ns {
		k &= n.kinds + (rules.Kinds{.Integer} if .Number in n.kinds else {})
	}
	return k
}

@(private = "file")
exotic :: proc(n: ^rules.Node) -> bool {
	return len(n.one_of) > 0 || n.not != nil || n.cond != {} || n.unevaluated_items != nil || n.unevaluated_properties != nil || n.dynamic_ref != nil
}

@(private = "file")
branch_included :: proc(p: ^Prover, a, b: []rules.Node_Index, ab, bb: [dynamic]rules.Node_Index, depth: int) -> bool {
	an, bn := nodes_of(p.from.d, ab[:]), nodes_of(p.to.d, bb[:])
	ka, kb := kinds_of(an), kinds_of(bn)
	if ka == {} {
		return true
	}
	for n in slice.concatenate([][]^rules.Node{an, bn}, context.temp_allocator) {
		if has_enum(n) {
			return finite_included(p, an, a, b, ka)
		}
	}
	if ka - kb != {} {
		return refuse(p, "type")
	}
	for n, i in bn {
		if !exotic(n) {
			continue
		}
		matched := false
		for m in ab {
			matched ||= same_node(p, m, bb[i])
		}
		if negated, has := n.not.?; has && !matched {
			matched = ka & kinds_of(nodes_of(p.to.d, {negated})) == {}
		}
		if !matched {
			return refuse(p, "$dynamicRef" if n.dynamic_ref != nil else "applicator")
		}
	}
	return facets_included(p, an, bn, ka, depth)
}

@(private = "file")
has_enum :: proc(n: ^rules.Node) -> bool {
	return n.has_enum || n.const_of != nil
}

// Whether the values that `an` is finite in, an enum, a constant or the null and booleans, are all values of `b`, which
// the check of each value decides. A value `a` refuses is no concern.
@(private = "file")
finite_included :: proc(p: ^Prover, an: []^rules.Node, a, b: []rules.Node_Index, ka: rules.Kinds) -> bool {
	values := make([dynamic]core.Value, context.temp_allocator)
	finite := false
	for n in an {
		if has_enum(n) {
			finite = true
			append(&values, ..n.enum_of)
			if c, has := n.const_of.?; has {
				append(&values, c)
			}
			break
		}
	}
	if !finite && ka - {.Null, .Bool} == {} {
		append(&values, nil, false, true)
		finite = true
	}
	if !finite {
		return refuse(p, "enum")
	}
	if len(values) > MAX_FINITE {
		return refuse(p, "enum")
	}
	// The scratch arena of the compare in progress, whose texts are freed after each value.
	scratch := (^virtual.Arena)(context.temp_allocator.data)
	for v in values {
		mark := virtual.arena_temp_begin(scratch)
		defer virtual.arena_temp_end(mark)
		text, written := text_of(p.from, v)
		if !written {
			return refuse(p, "enum")
		}
		taken, known := accepts(p.from, a, text)
		if !known {
			return refuse(p, "enum")
		}
		if taken {
			if fits, decided := accepts(p.to, b, text); !fits || !decided {
				return refuse(p, "enum")
			}
		}
	}
	return true
}

// Whether some node of `an` makes a facet of `b` certain.
@(private = "file")
some :: proc(an: []^rules.Node, b: ^rules.Node, covers: proc(a, b: ^rules.Node) -> bool) -> bool {
	for a in an {
		if covers(a, b) {
			return true
		}
	}
	return false
}

@(private = "file")
at_least :: proc(x, y: string, strict_x, strict_y, lower: bool) -> bool {
	order := spell.decimal_compare(spell.decimal_of(x), spell.decimal_of(y))
	order = order if lower else -order
	return order > 0 || order == 0 && (strict_x || !strict_y)
}

@(private = "file")
facets_included :: proc(p: ^Prover, an, bn: []^rules.Node, ka: rules.Kinds, depth: int) -> bool {
	for b in bn {
		r := &b.rules
		if ka & {.Integer, .Number} != {} {
			ok := !b.integer_spelled || .Integer not_in ka || some(an, b, proc(a, _: ^rules.Node) -> bool {return a.integer_spelled})
			if !ok {
				return refuse(p, "type")
			}
			if r.minimum != "" && !some(an, b, proc(a, b: ^rules.Node) -> bool {
					return a.rules.minimum != "" && at_least(a.rules.minimum, b.rules.minimum, a.rules.exclusive_minimum, b.rules.exclusive_minimum, true)
				}) {
				return refuse(p, "minimum")
			}
			if r.maximum != "" && !some(an, b, proc(a, b: ^rules.Node) -> bool {
					return a.rules.maximum != "" && at_least(a.rules.maximum, b.rules.maximum, a.rules.exclusive_maximum, b.rules.exclusive_maximum, false)
				}) {
				return refuse(p, "maximum")
			}
			if r.multiple_of != "" {
				order := spell.decimal_compare(spell.decimal_of(r.multiple_of), spell.decimal_of("1"))
				whole := .Number not_in ka && order == 0
				if !whole && !some(an, b, proc(a, b: ^rules.Node) -> bool {
						multiple, exact := spell.decimal_multiple_of(spell.decimal_of(a.rules.multiple_of), spell.decimal_of(b.rules.multiple_of))
						return a.rules.multiple_of != "" && multiple && exact
					}) {
					return refuse(p, "multipleOf")
				}
			}
		}
		if .String in ka {
			if r.min_length > 0 && !some(an, b, proc(a, b: ^rules.Node) -> bool {return a.rules.min_length >= b.rules.min_length}) {
				return refuse(p, "minLength")
			}
			if !at_most(an, b, proc(r: ^rules.Rules) -> Maybe(u64) {return r.max_length}) {
				return refuse(p, "maxLength")
			}
			if r.pattern != "" && !some(an, b, proc(a, b: ^rules.Node) -> bool {return a.rules.pattern == b.rules.pattern}) {
				return refuse(p, "pattern")
			}
			asserted := r.format != "" && r.assert_format
			if asserted && !some(an, b, proc(a, b: ^rules.Node) -> bool {return a.rules.format == b.rules.format && a.rules.assert_format}) {
				return refuse(p, "format")
			}
		}
		if .Array in ka && !array_included(p, an, b, depth) {
			return false
		}
		if .Object in ka && !object_included(p, an, b, depth) {
			return false
		}
	}
	return true
}

// Whether some node of `an` bounds the count that `limit` reads at least as tightly as `b`, which a `b` with no bound
// leaves to any.
@(private = "file")
at_most :: proc(an: []^rules.Node, b: ^rules.Node, limit: proc(r: ^rules.Rules) -> Maybe(u64)) -> bool {
	want, bounded := limit(&b.rules).?
	if !bounded {
		return true
	}
	for a in an {
		if have, has := limit(&a.rules).?; has && have <= want {
			return true
		}
	}
	return false
}

@(private = "file")
array_included :: proc(p: ^Prover, an: []^rules.Node, b: ^rules.Node, depth: int) -> bool {
	r := &b.rules
	if r.min_items > 0 && !some(an, b, proc(a, b: ^rules.Node) -> bool {return a.rules.min_items >= b.rules.min_items}) {
		return refuse(p, "minItems")
	}
	if !at_most(an, b, proc(r: ^rules.Rules) -> Maybe(u64) {return r.max_items}) {
		return refuse(p, "maxItems")
	}
	if r.unique && !some(an, b, proc(a, _: ^rules.Node) -> bool {return a.rules.unique}) {
		return refuse(p, "uniqueItems")
	}
	if b.array < 0 {
		return true
	}
	blocks := make([dynamic]^rules.Array, context.temp_allocator)
	longest := len(p.to.d.arrays[b.array].prefix)
	for a in an {
		if a.array >= 0 {
			append(&blocks, &p.from.d.arrays[a.array])
			longest = max(longest, len(p.from.d.arrays[a.array].prefix))
		}
	}
	want := &p.to.d.arrays[b.array]
	for i in 0 ..= longest {
		target := want.prefix[i] if i < len(want.prefix) else want.items
		if target == rules.NONE {
			continue
		}
		have := make([dynamic]rules.Node_Index, context.temp_allocator)
		for blk in blocks {
			if e := blk.prefix[i] if i < len(blk.prefix) else blk.items; e != rules.NONE {
				append(&have, e)
			}
		}
		if !included(p, have[:], {target}, depth + 1) {
			return false
		}
	}
	need, wanted := want.contains.?
	needed := want.min_contains.? or_else 1
	if !wanted || needed == 0 && want.max_contains == nil {
		return true
	}
	for blk in blocks {
		c, has := blk.contains.?
		if has && want.max_contains == nil && (blk.min_contains.? or_else 1) >= needed && included(p, {c}, {need}, depth + 1) {
			return true
		}
	}
	return refuse(p, "contains")
}

// The nodes that judge the member `name` in the object blocks `blocks`: its own where a block names it, and the block's
// other members' otherwise.
@(private)
member_nodes :: proc(blocks: []^rules.Object, name: string) -> []rules.Node_Index {
	out := make([dynamic]rules.Node_Index, context.temp_allocator)
	for blk in blocks {
		node := blk.additional
		for m in blk.members {
			if m.name == name && !m.only_required {
				node = m.node
			}
		}
		if node != rules.NONE {
			append(&out, node)
		}
	}
	return out[:]
}

@(private)
required_in :: proc(blocks: []^rules.Object, name: string) -> bool {
	for blk in blocks {
		for m in blk.members {
			if m.name == name && m.required {
				return true
			}
		}
	}
	return false
}

@(private = "file")
object_included :: proc(p: ^Prover, an: []^rules.Node, b: ^rules.Node, depth: int) -> bool {
	r := &b.rules
	if r.min_members > 0 && !some(an, b, proc(a, b: ^rules.Node) -> bool {return a.rules.min_members >= b.rules.min_members}) {
		return refuse(p, "minProperties")
	}
	if !at_most(an, b, proc(r: ^rules.Rules) -> Maybe(u64) {return r.max_members}) {
		return refuse(p, "maxProperties")
	}
	if b.object < 0 {
		return true
	}
	want := &p.to.d.objects[b.object]
	blocks := make([dynamic]^rules.Object, context.temp_allocator)
	for a in an {
		if a.object >= 0 {
			append(&blocks, &p.from.d.objects[a.object])
		}
	}
	patterned := len(want.patterns) > 0
	for blk in blocks {
		patterned ||= len(blk.patterns) > 0
	}
	if patterned {
		for blk in blocks {
			if same_object(p, blk, want) {
				return true
			}
		}
		return refuse(p, "patternProperties")
	}
	named := make(map[string]struct{}, context.temp_allocator)
	for blk in blocks {
		for m in blk.members {
			named[m.name] = {}
		}
	}
	for m in want.members {
		named[m.name] = {}
		if m.required && !required_in(blocks[:], m.name) {
			return refuse(p, "required")
		}
		target := want.additional if m.only_required else m.node
		have := member_nodes(blocks[:], m.name)
		if m.rules != {} && !member_rules_kept(blocks[:], m) {
			return refuse(p, m.name)
		}
		if target != rules.NONE && !included(p, have, {target}, depth + 1) {
			return false
		}
	}
	if want.additional != rules.NONE {
		for name in named {
			if !slice.contains(want_names(want), name) && !included(p, member_nodes(blocks[:], name), {want.additional}, depth + 1) {
				return false
			}
		}
		others := make([dynamic]rules.Node_Index, context.temp_allocator)
		for blk in blocks {
			if blk.additional != rules.NONE {
				append(&others, blk.additional)
			}
		}
		if !included(p, others[:], {want.additional}, depth + 1) {
			return false
		}
	}
	if want.keys != rules.NONE {
		have := make([dynamic]rules.Node_Index, context.temp_allocator)
		for blk in blocks {
			if blk.keys != rules.NONE {
				append(&have, blk.keys)
			}
		}
		if !included(p, have[:], {want.keys}, depth + 1) {
			return false
		}
	}
	for dep in want.dependents {
		if !dependent_kept(p, blocks[:], dep, depth) {
			return refuse(p, "dependentRequired")
		}
	}
	return true
}

@(private = "file")
want_names :: proc(o: ^rules.Object) -> []string {
	out := make([]string, len(o.members), context.temp_allocator)
	for m, i in o.members {
		out[i] = m.name
	}
	return out
}

@(private = "file")
member_rules_kept :: proc(blocks: []^rules.Object, want: rules.Member) -> bool {
	for blk in blocks {
		for m in blk.members {
			if m.name == want.name && m.rules == want.rules {
				return true
			}
		}
	}
	return false
}

@(private = "file")
dependent_kept :: proc(p: ^Prover, blocks: []^rules.Object, want: rules.Dependent, depth: int) -> bool {
	for blk in blocks {
		for have in blk.dependents {
			if have.name != want.name {
				continue
			}
			names_kept := true
			for n in want.required {
				names_kept &&= slice.contains(have.required, n)
			}
			node_kept := true
			if w, wanted := want.node.?; wanted {
				h, has := have.node.?
				node_kept = has && included(p, {h}, {w}, depth + 1)
			}
			if names_kept && node_kept {
				return true
			}
		}
	}
	return false
}

// Whether node `a` of `p.from` and node `b` of `p.to` say the same, every applicator and reference among them included.
@(private)
same_node :: proc(p: ^Prover, a, b: rules.Node_Index) -> bool {
	if a == rules.NONE || b == rules.NONE {
		return a == b
	}
	if p.nested >= MAX_SAME_NESTING {
		return false
	}
	p.nested += 1
	defer p.nested -= 1
	key := strings.concatenate({"=", string(slice.to_bytes([]rules.Node_Index{a, b}))}, context.temp_allocator)
	if key in p.running {
		return true
	}
	p.running[key] = {}
	defer delete_key(&p.running, key)
	if spent(p) {
		return false
	}
	x, y := &p.from.d.nodes[a], &p.to.d.nodes[b]
	// A dynamic reference reaches the anchor of the outermost resource that has one, which a pair of nodes alone does not
	// say, so two descriptions with anchors never agree on a node that holds one.
	if (x.dynamic_ref != nil || y.dynamic_ref != nil) && (len(p.from.d.anchors) > 0 || len(p.to.d.anchors) > 0) {
		return false
	}
	if x.kinds != y.kinds || x.integer_spelled != y.integer_spelled || x.rules != y.rules || x.has_enum != y.has_enum || len(x.enum_of) != len(y.enum_of) {
		return false
	}
	for v, i in x.enum_of {
		if !core.equal(v, y.enum_of[i]) {
			return false
		}
	}
	if (x.const_of == nil) != (y.const_of == nil) || x.const_of != nil && !core.equal(x.const_of.?, y.const_of.?) {
		return false
	}
	lists := [3][2][]rules.Node_Index{{x.any_of, y.any_of}, {x.all_of, y.all_of}, {x.one_of, y.one_of}}
	for l in lists {
		if !same_nodes(p, l[0], l[1]) {
			return false
		}
	}
	singles := [?][2]Maybe(rules.Node_Index){{x.not, y.not}, {x.cond.test, y.cond.test}, {x.cond.then, y.cond.then}, {x.cond.other, y.cond.other}, {x.ref, y.ref}, {x.dynamic_ref, y.dynamic_ref}, {x.unevaluated_items, y.unevaluated_items}, {x.unevaluated_properties, y.unevaluated_properties}}
	for s in singles {
		if !same_nodes(p, maybe_slice(s[0]), maybe_slice(s[1])) {
			return false
		}
	}
	return same_array(p, x.array, y.array) && same_object_at(p, x.object, y.object)
}

@(private)
nodes_or_none :: proc(n: rules.Node_Index) -> []rules.Node_Index {
	if n == rules.NONE {
		return nil
	}
	out := make([]rules.Node_Index, 1, context.temp_allocator)
	out[0] = n
	return out
}

@(private = "file")
maybe_slice :: proc(m: Maybe(rules.Node_Index)) -> []rules.Node_Index {
	return nodes_or_none(m.? or_else rules.NONE)
}

@(private = "file")
same_nodes :: proc(p: ^Prover, a, b: []rules.Node_Index) -> bool {
	if len(a) != len(b) {
		return false
	}
	for x, i in a {
		if !same_node(p, x, b[i]) {
			return false
		}
	}
	return true
}

@(private = "file")
same_array :: proc(p: ^Prover, a, b: i32) -> bool {
	if a < 0 || b < 0 {
		return a == b
	}
	x, y := &p.from.d.arrays[a], &p.to.d.arrays[b]
	return same_nodes(p, x.prefix, y.prefix) && same_nodes(p, {x.items}, {y.items}) && x.min_contains == y.min_contains && x.max_contains == y.max_contains && same_nodes(p, maybe_slice(x.contains), maybe_slice(y.contains))
}

@(private = "file")
same_object_at :: proc(p: ^Prover, a, b: i32) -> bool {
	if a < 0 || b < 0 {
		return a == b
	}
	return same_object(p, &p.from.d.objects[a], &p.to.d.objects[b])
}

@(private)
same_object :: proc(p: ^Prover, x, y: ^rules.Object) -> bool {
	if len(x.members) != len(y.members) || len(x.patterns) != len(y.patterns) || len(x.dependents) != len(y.dependents) {
		return false
	}
	for m in x.members {
		found := false
		for n in y.members {
			if n.name == m.name {
				found = n.rules == m.rules && n.required == m.required && n.only_required == m.only_required && same_nodes(p, {m.node}, {n.node})
			}
		}
		if !found {
			return false
		}
	}
	for pat, i in x.patterns {
		if pat.expression != y.patterns[i].expression || !same_nodes(p, {pat.node}, {y.patterns[i].node}) {
			return false
		}
	}
	for dep, i in x.dependents {
		o := y.dependents[i]
		if dep.name != o.name || !slice.equal(dep.required, o.required) || !same_nodes(p, maybe_slice(dep.node), maybe_slice(o.node)) {
			return false
		}
	}
	return same_nodes(p, {x.additional}, {y.additional}) && same_nodes(p, {x.keys}, {y.keys})
}
