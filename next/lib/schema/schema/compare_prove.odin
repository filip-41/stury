// Structural subset / inclusion prover over `rules.Description` conjunctions and disjunctions.
// Deterministic member iteration order, iterative `same_node`, strictly depth-bounded `included`,
// zero `core:mem/virtual`, zero `context.temp_allocator`, WASM-clean.
package schema

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/rules"

@(private) MAX_BRANCHES :: 32
@(private) MAX_DEPTH :: 24

@(private = "file") MAX_FINITE :: 8192
@(private = "file") STEP_BUDGET :: 40_000
@(private = "file") MAX_FOCI :: 8
@(private = "file") MAX_EVALUATING :: 256

@(private)
Prover :: struct {
	from, to:      ^Side,
	steps:         int,
	exhausted:     bool,
	why:           string,
	running:       map[string]int,
	patterns:      rules.Programs,
	re_scratch:    regex.Scratch,
	re_scratch_ok: bool,
	path:          [dynamic]tape.Step,
	frames:        [dynamic][2][]rules.Node_Index,
	foci:          [dynamic]Focus,
	scratch:       runtime.Allocator,
	backing:       runtime.Allocator,
}

@(private)
Focus :: struct {
	path: []tape.Step,
	a, b: []rules.Node_Index,
}

@(private)
prover_of :: proc(from, to: ^Side, scratch, backing: runtime.Allocator) -> Prover {
	rs, rerr := regex.scratch_make(backing)
	return {
		from          = from,
		to            = to,
		running       = make(map[string]int, 32, scratch),
		patterns      = make(rules.Programs, 8, scratch),
		re_scratch    = rs,
		re_scratch_ok = rerr.kind == .None,
		path          = make([dynamic]tape.Step, scratch),
		frames        = make([dynamic][2][]rules.Node_Index, scratch),
		foci          = make([dynamic]Focus, scratch),
		scratch       = scratch,
		backing       = backing,
	}
}

@(private)
prover_destroy :: proc(p: ^Prover) {
	if p != nil && p.re_scratch_ok {
		regex.scratch_destroy(&p.re_scratch)
		p.re_scratch_ok = false
	}
}

@(private)
spent :: proc(p: ^Prover) -> bool {
	p.steps += 1
	if p.steps > STEP_BUDGET {
		p.exhausted = true
		prover_refuse(p, "budget")
	}
	return p.exhausted
}

@(private)
prover_refuse :: proc(p: ^Prover, why: string) -> bool {
	if p.why == "" {
		p.why = why
	}
	if len(p.frames) > 0 && len(p.foci) < MAX_FOCI {
		top := p.frames[len(p.frames) - 1]
		if n := len(p.foci); n > 0 && slice.equal(p.foci[n - 1].a, top[0]) && slice.equal(p.foci[n - 1].b, top[1]) {
			return false
		}
		append(&p.foci, Focus{path = slice.clone(p.path[:], p.scratch), a = slice.clone(top[0], p.scratch), b = slice.clone(top[1], p.scratch)})
	}
	return false
}

@(private)
included_at :: proc(p: ^Prover, step: tape.Step, a, b: []rules.Node_Index, depth: int) -> bool {
	append(&p.path, step)
	defer pop(&p.path)
	return included(p, a, b, depth + 1)
}

@(private)
included :: proc(p: ^Prover, a, b: []rules.Node_Index, depth: int) -> bool {
	if spent(p) {
		return false
	}
	if depth > MAX_DEPTH {
		return prover_refuse(p, "depth")
	}
	if len(a) == 1 && len(b) == 1 && same_node(p, a[0], b[0]) {
		return true
	}
	key := strings.concatenate({conjunction_key(p.from.d, a, p.scratch), "|", conjunction_key(p.to.d, b, p.scratch)}, p.scratch)
	if at, held := p.running[key]; held {
		return at < depth || prover_refuse(p, "$ref")
	}
	p.running[key] = depth
	defer delete_key(&p.running, key)
	append(&p.frames, [2][]rules.Node_Index{a, b})
	defer pop(&p.frames)

	as, a_fits := rules.branches(p.from.d, a, true, MAX_BRANCHES, p.scratch, p.scratch)
	if !a_fits {
		as, a_fits = rules.branches(p.from.d, a, false, MAX_BRANCHES, p.scratch, p.scratch)
	}
	bs, b_fits := rules.branches(p.to.d, b, false, MAX_BRANCHES, p.scratch, p.scratch)
	if !a_fits || !b_fits {
		return prover_refuse(p, "anyOf")
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

@(private = "file")
conjunction_key :: proc(d: ^rules.Description, ids: []rules.Node_Index, scratch: runtime.Allocator) -> string {
	reached := make([dynamic]rules.Node_Index, 0, len(ids), scratch)
	for id in ids {
		at := id
		for hops := 0; hops < MAX_DEPTH * 4 && rules.ref_only(&d.nodes[at]) && !d.nodes[at].integer_spelled; hops += 1 {
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

@(private)
nodes_of :: proc(d: ^rules.Description, ids: []rules.Node_Index, scratch: runtime.Allocator) -> []^rules.Node {
	out := make([]^rules.Node, len(ids), scratch)
	for id, i in ids {
		out[i] = &d.nodes[id]
	}
	return out
}

@(private = "file")
exotic :: proc "contextless" (n: ^rules.Node) -> bool {
	return len(n.one_of) > 0 || n.not != nil || n.cond != {} || n.unevaluated_items != nil || n.unevaluated_properties != nil || n.dynamic_ref != nil
}

@(private = "file")
branch_included :: proc(p: ^Prover, a, b: []rules.Node_Index, ab, bb: [dynamic]rules.Node_Index, depth: int) -> bool {
	an := nodes_of(p.from.d, ab[:], p.scratch)
	bn := nodes_of(p.to.d, bb[:], p.scratch)
	ka := rules.kinds_of(p.from.d, ab[:])
	kb := rules.kinds_of(p.to.d, bb[:])
	if ka == {} {
		return true
	}
	for list in ([2][]^rules.Node{an, bn}) {
		for n in list {
			if n.has_enum || n.const_of != nil {
				return finite_included(p, ab[:], a, b, ka)
			}
		}
	}
	if ka - kb != {} {
		return prover_refuse(p, "type")
	}
	for n, i in bn {
		if !exotic(n) {
			continue
		}
		matched := false
		for m in ab {
			matched ||= same_node(p, m, bb[i])
		}
		if matched {
			continue
		}
		_, _, lowered := unevaluated_block(p.to.d, n, p.scratch)
		if n.dynamic_ref != nil || n.unevaluated_items != nil || (n.unevaluated_properties != nil && !lowered) {
			return prover_refuse(p, "$dynamicRef" if n.dynamic_ref != nil else "applicator")
		}
		if !applicators_hold(p, ab[:], ka, n, depth) {
			return false
		}
	}
	return facets_included(p, an, bn, ka, depth)
}

@(private = "file")
applicators_hold :: proc(p: ^Prover, ab: []rules.Node_Index, ka: rules.Kinds, n: ^rules.Node, depth: int) -> bool {
	if negated, has := n.not.?; has && ka & rules.kinds_of(p.to.d, {negated}) != {} {
		return prover_refuse(p, "not")
	}
	why := p.why
	one_holds := len(n.one_of) == 0
	for arm, i in n.one_of {
		if !included(p, ab, nodes_or_none(arm, p.scratch), depth + 1) {
			continue
		}
		one_holds = true
		for other, j in n.one_of {
			one_holds &&= i == j || disjoint(p, p.to.d, arm, other)
		}
		break
	}
	test, has_test := n.cond.test.?
	cond_holds := !has_test || !one_holds
	if !cond_holds {
		cond_holds = included(p, ab, nodes_or_none(n.cond.then.? or_else rules.NONE, p.scratch), depth + 1) &&
			(included(p, ab, nodes_or_none(n.cond.other.? or_else rules.NONE, p.scratch), depth + 1) || included(p, ab, nodes_or_none(test, p.scratch), depth + 1))
	}
	if !p.exhausted {
		p.why = why
	}
	if !one_holds {
		return prover_refuse(p, "oneOf")
	}
	return cond_holds || prover_refuse(p, "if")
}

@(private = "file")
disjoint :: proc(p: ^Prover, d: ^rules.Description, x, y: rules.Node_Index) -> bool {
	xs, x_fits := rules.branches(d, {x}, true, MAX_BRANCHES, p.scratch, p.scratch)
	ys, y_fits := rules.branches(d, {y}, true, MAX_BRANCHES, p.scratch, p.scratch)
	if !x_fits || !y_fits {
		return false
	}
	for bx in xs {
		for by in ys {
			if spent(p) || !branches_disjoint(p, d, bx[:], by[:]) {
				return false
			}
		}
	}
	return true
}

@(private = "file")
branches_disjoint :: proc(p: ^Prover, d: ^rules.Description, x, y: []rules.Node_Index) -> bool {
	shared := rules.kinds_of(d, x) & rules.kinds_of(d, y)
	if shared == {} || finite_apart(d, x, y, p.scratch) {
		return true
	}
	if shared - {.Object} != {} {
		return false
	}
	xb := object_blocks(d, nodes_of(d, x, p.scratch), p.scratch)
	yb := object_blocks(d, nodes_of(d, y, p.scratch), p.scratch)
	xn := names_of_blocks(xb[:], p.scratch)
	yn := names_of_blocks(yb[:], p.scratch)
	for blk in xb {
		for m in blk.members {
			if m.required && required_in(yb[:], yn, m.name) {
				x_nodes, _ := judging_nodes(p, xb[:], xn, m.name)
				y_nodes, _ := judging_nodes(p, yb[:], yn, m.name)
				if finite_apart(d, x_nodes, y_nodes, p.scratch) {
					return true
				}
			}
		}
	}
	return false
}

@(private = "file")
finite_of :: proc(d: ^rules.Description, ids: []rules.Node_Index, scratch: runtime.Allocator) -> ([]rules.Value, bool) {
	for id in ids {
		if at, _ := rules.ref_end(d, id); at != rules.NONE {
			n := &d.nodes[at]
			if c, has := n.const_of.?; has {
				return slice.clone([]rules.Value{c}, scratch), true
			}
			if n.has_enum {
				return n.enum_of, true
			}
		}
	}
	return nil, false
}

@(private = "file")
finite_apart :: proc(d: ^rules.Description, x_ids, y_ids: []rules.Node_Index, scratch: runtime.Allocator) -> bool {
	x, x_finite := finite_of(d, x_ids, scratch)
	y, y_finite := finite_of(d, y_ids, scratch)
	if !x_finite || !y_finite {
		return false
	}
	for a in x {
		for b in y {
			if eq, err := rules.value_equal(a, b, .Last, scratch); err != nil || eq {
				return false
			}
		}
	}
	return true
}

@(private)
object_blocks :: proc(d: ^rules.Description, nodes: []^rules.Node, scratch: runtime.Allocator) -> [dynamic]^rules.Object {
	blocks := make([dynamic]^rules.Object, scratch)
	for n in nodes {
		if n.object >= 0 {
			append(&blocks, &d.objects[n.object])
		}
	}
	return blocks
}

@(private = "file")
finite_included :: proc(p: ^Prover, ab, a, b: []rules.Node_Index, ka: rules.Kinds) -> bool {
	values, finite := finite_of(p.from.d, ab, p.scratch)
	if !finite && ka - {.Null, .Bool} == {} {
		values, finite = []rules.Value{rules.Null{}, false, true}, true
	}
	if !finite || len(values) > MAX_FINITE {
		return prover_refuse(p, "enum")
	}
	eval_arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&eval_arena, p.backing, p.backing)
	defer mem.dynamic_arena_destroy(&eval_arena)
	eval_alloc := mem.dynamic_arena_allocator(&eval_arena)

	held := true
	for v in values {
		mem.dynamic_arena_reset(&eval_arena)
		tt: write.Token_Tape
		doc, tok := value_to_tape(v, &tt, eval_alloc)
		if !tok {
			held = false
			break
		}
		taken, known := accepts_doc(p.from, a, &doc, eval_alloc)
		held = known
		if held && taken {
			fits, decided := accepts_doc(p.to, b, &doc, eval_alloc)
			held &&= fits && decided
		}
		write.token_tape_drop(&tt)
		if !held {
			break
		}
	}
	return held || prover_refuse(p, "enum")
}

@(private = "file")
some_node :: proc(an: []^rules.Node, b: ^rules.Node, covers: proc(a, b: ^rules.Node) -> bool) -> bool {
	for a in an {
		if covers(a, b) {
			return true
		}
	}
	return false
}

@(private = "file")
as_tight :: proc "contextless" (x, y: string, strict_x, strict_y, lower: bool) -> bool {
	return y == "" || (x != "" && rules.tighter(x, y, strict_x, strict_y, lower) >= 0)
}

@(private = "file")
at_most :: proc "contextless" (have, want: Maybe(u64)) -> bool {
	limit, bounded := want.?
	if !bounded {
		return true
	}
	h, has := have.?
	return has && h <= limit
}

@(private = "file")
facets_included :: proc(p: ^Prover, an, bn: []^rules.Node, ka: rules.Kinds, depth: int) -> bool {
	have: rules.Rules
	for a in an {
		edge := a.rules
		edge.multiple_of, edge.pattern = "", ""
		tmp := rules.Node{rules = have}
		have, _ = rules.merged(&tmp, edge)
	}
	for b in bn {
		r := &b.rules
		if ka & {.Integer, .Number} != {} {
			if b.integer_spelled && .Integer in ka && !some_node(an, b, proc(a, _: ^rules.Node) -> bool { return a.integer_spelled }) {
				return prover_refuse(p, "type")
			}
			if !as_tight(have.minimum, r.minimum, have.exclusive_minimum, r.exclusive_minimum, true) {
				return prover_refuse(p, "minimum")
			}
			if !as_tight(have.maximum, r.maximum, have.exclusive_maximum, r.exclusive_maximum, false) {
				return prover_refuse(p, "maximum")
			}
			if r.multiple_of != "" {
				whole := .Number not_in ka && rules.decimal_compare(rules.decimal_of(r.multiple_of), rules.decimal_of("1")) == 0
				if !whole && !some_node(an, b, proc(a, b: ^rules.Node) -> bool {
					if a.rules.multiple_of == "" {
						return false
					}
					multiple, exact := rules.decimal_multiple_of(rules.decimal_of(a.rules.multiple_of), rules.decimal_of(b.rules.multiple_of))
					return multiple && exact
				}) {
					return prover_refuse(p, "multipleOf")
				}
			}
		}
		if .String in ka {
			if have.min_length < r.min_length { return prover_refuse(p, "minLength") }
			if !at_most(have.max_length, r.max_length) { return prover_refuse(p, "maxLength") }
			if r.pattern != "" && !some_node(an, b, proc(a, b: ^rules.Node) -> bool { return a.rules.pattern == b.rules.pattern }) {
				return prover_refuse(p, "pattern")
			}
			if r.format != "" && r.assert_format && !some_node(an, b, proc(a, b: ^rules.Node) -> bool { return a.rules.format == b.rules.format && a.rules.assert_format }) {
				return prover_refuse(p, "format")
			}
		}
		if .Array in ka && !array_included(p, an, &have, b, depth) { return false }
		if .Object in ka && !object_included(p, an, &have, b, depth) { return false }
	}
	return true
}

@(private = "file")
array_included :: proc(p: ^Prover, an: []^rules.Node, have: ^rules.Rules, b: ^rules.Node, depth: int) -> bool {
	r := &b.rules
	if have.min_items < r.min_items { return prover_refuse(p, "minItems") }
	if !at_most(have.max_items, r.max_items) { return prover_refuse(p, "maxItems") }
	if r.unique && !have.unique { return prover_refuse(p, "uniqueItems") }
	if b.array < 0 {
		return true
	}
	blocks := make([dynamic]^rules.Array, p.scratch)
	want := &p.to.d.arrays[b.array]
	longest := len(want.prefix)
	for a in an {
		if a.array >= 0 {
			append(&blocks, &p.from.d.arrays[a.array])
			longest = max(longest, len(p.from.d.arrays[a.array].prefix))
		}
	}
	for i in 0 ..= longest {
		target := want.prefix[i] if i < len(want.prefix) else want.items
		if target == rules.NONE {
			continue
		}
		hnodes := make([dynamic]rules.Node_Index, p.scratch)
		for blk in blocks {
			if e := blk.prefix[i] if i < len(blk.prefix) else blk.items; e != rules.NONE {
				append(&hnodes, e)
			}
		}
		if !included_at(p, tape.Index(i), hnodes[:], nodes_or_none(target, p.scratch), depth) {
			return false
		}
	}
	need, wanted := want.contains.?
	needed := want.min_contains.? or_else 1
	if !wanted || (needed == 0 && want.max_contains == nil) {
		return true
	}
	for blk in blocks {
		if c, has := blk.contains.?; has && want.max_contains == nil && (blk.min_contains.? or_else 1) >= needed &&
			included(p, nodes_or_none(c, p.scratch), nodes_or_none(need, p.scratch), depth + 1) {
			return true
		}
	}
	return prover_refuse(p, "contains")
}

@(private)
member_nodes :: proc(blocks: []^rules.Object, names: []Member_Names, name: string, scratch: runtime.Allocator) -> []rules.Node_Index {
	out := make([dynamic]rules.Node_Index, scratch)
	for blk, j in blocks {
		node := blk.additional
		for k := first_named(&names[j], name); k >= 0; k = next_named(&names[j], k) {
			if !blk.members[k].only_required {
				node = blk.members[k].node
			}
		}
		if node != rules.NONE {
			append(&out, node)
		}
	}
	return out[:]
}

@(private)
required_in :: proc(blocks: []^rules.Object, names: []Member_Names, name: string) -> bool {
	for blk, j in blocks {
		for k := first_named(&names[j], name); k >= 0; k = next_named(&names[j], k) {
			if blk.members[k].required {
				return true
			}
		}
	}
	return false
}

@(private)
names_of_blocks :: proc(blocks: []^rules.Object, scratch: runtime.Allocator) -> []Member_Names {
	names := make([]Member_Names, len(blocks), scratch)
	for blk, j in blocks {
		names[j] = member_names(blk.members, scratch)
	}
	return names
}

@(private = "file")
object_included :: proc(p: ^Prover, an: []^rules.Node, have: ^rules.Rules, b: ^rules.Node, depth: int) -> bool {
	r := &b.rules
	if have.min_members < r.min_members { return prover_refuse(p, "minProperties") }
	if !at_most(have.max_members, r.max_members) { return prover_refuse(p, "maxProperties") }
	blocks := object_blocks(p.from.d, an, p.scratch)
	for a in an {
		if block, exact, has := unevaluated_block(p.from.d, a, p.scratch); has && exact {
			if cp, _ := new_clone(block, p.scratch); cp != nil {
				append(&blocks, cp)
			}
		}
	}
	if b.object >= 0 && !members_included(p, blocks[:], &p.to.d.objects[b.object], depth) {
		return false
	}
	if block, _, has := unevaluated_block(p.to.d, b, p.scratch); has && !members_included(p, blocks[:], &block, depth) {
		return false
	}
	return true
}

@(private = "file")
unevaluated_block :: proc(d: ^rules.Description, n: ^rules.Node, scratch: runtime.Allocator) -> (rules.Object, bool, bool) {
	others, holds := n.unevaluated_properties.?
	if !holds {
		return {}, false, false
	}
	members := make([dynamic]rules.Member, scratch)
	patterns := make([dynamic]rules.Pattern, scratch)
	reached := make([dynamic]^rules.Node, scratch)
	append(&reached, n)
	exact := true
	for i := 0; i < len(reached); i += 1 {
		if len(reached) > MAX_EVALUATING {
			return {}, false, false
		}
		x := reached[i]
		exact &&= len(x.any_of) == 0 && len(x.one_of) == 0 && x.cond == {} && x.dynamic_ref == nil && (i == 0 || x.unevaluated_properties == nil)
		if x.object >= 0 {
			o := &d.objects[x.object]
			if o.additional != rules.NONE {
				return {additional = rules.NONE, keys = rules.NONE}, true, true
			}
			for m in o.members {
				if !m.only_required {
					append(&members, rules.Member{name = m.name, node = rules.NONE})
				}
			}
			for q in o.patterns {
				append(&patterns, rules.Pattern{expression = q.expression, node = rules.NONE})
			}
			for dep in o.dependents {
				exact &&= dep.node == nil
			}
		}
		if id, is := x.ref.?; is && !slice.contains(reached[:], &d.nodes[id]) {
			append(&reached, &d.nodes[id])
		}
		for id in x.all_of {
			if !slice.contains(reached[:], &d.nodes[id]) {
				append(&reached, &d.nodes[id])
			}
		}
	}
	return {members = members[:], patterns = patterns[:], additional = others, keys = rules.NONE}, exact, true
}

@(private = "file")
members_included :: proc(p: ^Prover, blocks: []^rules.Object, want: ^rules.Object, depth: int) -> bool {
	named := make(map[string]struct{}, 16, p.scratch)
	order := make([dynamic]string, p.scratch)
	for blk in blocks {
		for m in blk.members {
			if m.name not_in named {
				named[m.name] = {}
				append(&order, m.name)
			}
		}
	}
	names := names_of_blocks(blocks, p.scratch)
	for m in want.members {
		if m.name not_in named {
			named[m.name] = {}
			append(&order, m.name)
		}
		if m.required && !required_in(blocks, names, m.name) { return prover_refuse(p, "required") }
		if m.rules != {} && !member_rules_kept(blocks, names, m) { return prover_refuse(p, m.name) }
	}
	wanted := names_of_blocks({want}, p.scratch)
	for name in order {
		targets, decided := judging_nodes(p, {want}, wanted, name)
		if !decided { return prover_refuse(p, "patternProperties") }
		if len(targets) > 0 {
			have, _ := judging_nodes(p, blocks, names, name)
			if !included_at(p, tape.Name(name), have, targets, depth) { return false }
		}
	}
	for pat in want.patterns {
		have := make([dynamic]rules.Node_Index, p.scratch)
		for blk in blocks {
			if twin, has := pattern_node(blk.patterns, pat.expression); has {
				if twin != rules.NONE { append(&have, twin) }
			} else if len(blk.patterns) == 0 && blk.additional != rules.NONE {
				append(&have, blk.additional)
			}
		}
		if pat.node != rules.NONE && !included_at(p, tape.Name(name_of_pattern(pat.expression, p.scratch, p.backing)), have[:], nodes_or_none(pat.node, p.scratch), depth) {
			return false
		}
	}
	if want.additional != rules.NONE {
		others := make([dynamic]rules.Node_Index, p.scratch)
		for blk in blocks {
			apart := blk.additional != rules.NONE
			for q in blk.patterns {
				_, shared := pattern_node(want.patterns, q.expression)
				apart &&= shared
			}
			if apart { append(&others, blk.additional) }
		}
		if !included_at(p, tape.Name(OTHER_NAME), others[:], nodes_or_none(want.additional, p.scratch), depth) {
			return false
		}
	}
	if want.keys != rules.NONE {
		have := make([dynamic]rules.Node_Index, p.scratch)
		for blk in blocks {
			if blk.keys != rules.NONE { append(&have, blk.keys) }
		}
		if !included(p, have[:], nodes_or_none(want.keys, p.scratch), depth + 1) { return false }
	}
	for dep in want.dependents {
		if !dependent_kept(p, blocks, dep, depth) { return prover_refuse(p, "dependentRequired") }
	}
	return true
}

@(private = "file")
pattern_node :: proc(patterns: []rules.Pattern, expression: string) -> (rules.Node_Index, bool) {
	for q in patterns {
		if q.expression == expression { return q.node, true }
	}
	return rules.NONE, false
}

@(private)
judging_nodes :: proc(p: ^Prover, blocks: []^rules.Object, names: []Member_Names, name: string) -> ([]rules.Node_Index, bool) {
	nodes := make([dynamic]rules.Node_Index, p.scratch)
	decided := true
	for blk, j in blocks {
		own, is_named := rules.NONE, false
		for k := first_named(&names[j], name); k >= 0; k = next_named(&names[j], k) {
			if !blk.members[k].only_required {
				own, is_named = blk.members[k].node, true
			}
		}
		matched, known := false, true
		for q in blk.patterns {
			hit, judged := name_matches(p, q.expression, name)
			known &&= judged
			if hit && judged {
				matched = true
				if q.node != rules.NONE { append(&nodes, q.node) }
			}
		}
		decided &&= known
		if !is_named && !matched && known { own = blk.additional }
		if own != rules.NONE { append(&nodes, own) }
	}
	return nodes[:], decided
}

@(private = "file")
name_matches :: proc(p: ^Prover, expression, name: string) -> (bool, bool) {
	if !p.re_scratch_ok { return false, false }
	re, cerr := rules.program_of(&p.patterns, expression, p.scratch, p.backing)
	if cerr.kind != .None { return false, false }
	found, err := regex.search(re, name, 0, nil, &p.re_scratch)
	return found, err.kind == .None
}

@(private = "file")
member_rules_kept :: proc(blocks: []^rules.Object, names: []Member_Names, want: rules.Member) -> bool {
	for blk, j in blocks {
		for k := first_named(&names[j], want.name); k >= 0; k = next_named(&names[j], k) {
			if blk.members[k].rules == want.rules { return true }
		}
	}
	return false
}

@(private = "file")
dependent_kept :: proc(p: ^Prover, blocks: []^rules.Object, want: rules.Dependent, depth: int) -> bool {
	for blk in blocks {
		for have in blk.dependents {
			if have.name != want.name { continue }
			names_kept := true
			for n in want.required { names_kept &&= slice.contains(have.required, n) }
			node_kept := true
			if w, wanted := want.node.?; wanted {
				h, has := have.node.?
				node_kept = has && included(p, nodes_or_none(h, p.scratch), nodes_or_none(w, p.scratch), depth + 1)
			}
			if names_kept && node_kept { return true }
		}
	}
	return false
}

// Iterative coinductive structural equality check over two `rules.Node` graphs (O(1) native stack).
@(private)
same_node :: proc(p: ^Prover, root_a, root_b: rules.Node_Index) -> bool {
	if root_a == rules.NONE || root_b == rules.NONE {
		return root_a == root_b
	}
	if p.exhausted {
		return false
	}
	work := make([dynamic][2]rules.Node_Index, 0, 16, p.scratch)
	seen := make(map[[2]rules.Node_Index]struct{}, 16, p.scratch)
	append(&work, [2]rules.Node_Index{root_a, root_b})
	return drain_same_work(p, &work, &seen, 0)
}

@(private)
same_object :: proc(p: ^Prover, x, y: ^rules.Object) -> bool {
	if p.exhausted {
		return false
	}
	work := make([dynamic][2]rules.Node_Index, 0, 16, p.scratch)
	seen := make(map[[2]rules.Node_Index]struct{}, 16, p.scratch)
	return queue_same_object(p, x, y, &work, 0) && drain_same_work(p, &work, &seen, 0)
}

@(private = "file")
queue_pair :: proc(work: ^[dynamic][2]rules.Node_Index, a, b: rules.Node_Index) -> bool {
	if a == rules.NONE || b == rules.NONE { return a == b }
	append(work, [2]rules.Node_Index{a, b})
	return true
}

@(private = "file")
queue_maybe :: proc(work: ^[dynamic][2]rules.Node_Index, a, b: Maybe(rules.Node_Index)) -> bool {
	return queue_pair(work, a.? or_else rules.NONE, b.? or_else rules.NONE)
}

@(private = "file")
queue_slice :: proc(work: ^[dynamic][2]rules.Node_Index, a, b: []rules.Node_Index) -> bool {
	if len(a) != len(b) { return false }
	for x, i in a {
		if !queue_pair(work, x, b[i]) { return false }
	}
	return true
}

@(private = "file")
queue_same_object :: proc(p: ^Prover, x, y: ^rules.Object, work: ^[dynamic][2]rules.Node_Index, dup_depth: int) -> bool {
	if len(x.members) != len(y.members) || len(x.patterns) != len(y.patterns) || len(x.dependents) != len(y.dependents) {
		return false
	}
	names := member_names(y.members, p.scratch)
	for m in x.members {
		first_match, match_count := -1, 0
		for k := first_named(&names, m.name); k >= 0; k = next_named(&names, k) {
			n := y.members[k]
			if n.rules == m.rules && n.required == m.required && n.only_required == m.only_required {
				if first_match < 0 { first_match = k }
				match_count += 1
			}
		}
		if match_count == 0 {
			return false
		}
		if match_count == 1 {
			if !queue_pair(work, m.node, y.members[first_match].node) { return false }
		} else {
			if dup_depth >= 8 { return false }
			found := false
			for k := first_named(&names, m.name); k >= 0; k = next_named(&names, k) {
				n := y.members[k]
				if n.rules == m.rules && n.required == m.required && n.only_required == m.only_required {
					sub_work := make([dynamic][2]rules.Node_Index, 0, 8, p.scratch)
					sub_seen := make(map[[2]rules.Node_Index]struct{}, 8, p.scratch)
					if queue_pair(&sub_work, m.node, n.node) && drain_same_work(p, &sub_work, &sub_seen, dup_depth + 1) {
						found = true
						break
					}
				}
			}
			if !found { return false }
		}
	}
	for pat, i in x.patterns {
		if pat.expression != y.patterns[i].expression || !queue_pair(work, pat.node, y.patterns[i].node) {
			return false
		}
	}
	for dep, i in x.dependents {
		o := y.dependents[i]
		if dep.name != o.name || !slice.equal(dep.required, o.required) || !queue_maybe(work, dep.node, o.node) {
			return false
		}
	}
	return queue_pair(work, x.additional, y.additional) && queue_pair(work, x.keys, y.keys)
}

@(private = "file")
drain_same_work :: proc(p: ^Prover, work: ^[dynamic][2]rules.Node_Index, seen: ^map[[2]rules.Node_Index]struct{}, dup_depth: int) -> bool {
	for len(work) > 0 {
		pair := pop(work)
		a, b := pair[0], pair[1]
		if a == rules.NONE || b == rules.NONE {
			if a != b { return false }
			continue
		}
		if pair in seen^ {
			continue
		}
		seen[pair] = {}
		if spent(p) {
			return false
		}
		x, y := &p.from.d.nodes[a], &p.to.d.nodes[b]
		if (x.dynamic_ref != nil || y.dynamic_ref != nil) && (len(p.from.d.anchors) > 0 || len(p.to.d.anchors) > 0) {
			return false
		}
		if x.kinds != y.kinds || x.integer_spelled != y.integer_spelled || x.rules != y.rules || x.has_enum != y.has_enum || len(x.enum_of) != len(y.enum_of) {
			return false
		}
		for v, i in x.enum_of {
			if eq, err := rules.value_equal(v, y.enum_of[i], .Last, p.scratch); err != nil || !eq { return false }
		}
		if (x.const_of == nil) != (y.const_of == nil) { return false }
		if x.const_of != nil {
			if eq, err := rules.value_equal(x.const_of.?, y.const_of.?, .Last, p.scratch); err != nil || !eq { return false }
		}
		for l in ([3][2][]rules.Node_Index{{x.any_of, y.any_of}, {x.all_of, y.all_of}, {x.one_of, y.one_of}}) {
			if !queue_slice(work, l[0], l[1]) { return false }
		}
		for s in ([?][2]Maybe(rules.Node_Index){
			{x.not, y.not}, {x.cond.test, y.cond.test}, {x.cond.then, y.cond.then}, {x.cond.other, y.cond.other},
			{x.ref, y.ref}, {x.dynamic_ref, y.dynamic_ref}, {x.unevaluated_items, y.unevaluated_items}, {x.unevaluated_properties, y.unevaluated_properties},
		}) {
			if !queue_maybe(work, s[0], s[1]) { return false }
		}
		if x.array < 0 || y.array < 0 {
			if x.array != y.array { return false }
		} else {
			ax, ay := &p.from.d.arrays[x.array], &p.to.d.arrays[y.array]
			if !queue_slice(work, ax.prefix, ay.prefix) || !queue_pair(work, ax.items, ay.items) ||
				ax.min_contains != ay.min_contains || ax.max_contains != ay.max_contains ||
				(ax.contains != nil && ax.evaluates_contains != ay.evaluates_contains) || !queue_maybe(work, ax.contains, ay.contains) {
				return false
			}
		}
		if x.object < 0 || y.object < 0 {
			if x.object != y.object { return false }
		} else if !queue_same_object(p, &p.from.d.objects[x.object], &p.to.d.objects[y.object], work, dup_depth) {
			return false
		}
	}
	return true
}

@(private)
nodes_or_none :: proc(n: rules.Node_Index, scratch: runtime.Allocator) -> []rules.Node_Index {
	if n == rules.NONE { return nil }
	out := make([]rules.Node_Index, 1, scratch)
	out[0] = n
	return out
}
