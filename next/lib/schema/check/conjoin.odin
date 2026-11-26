// Conjoins `allOf` and `$ref` chains into single verdict nodes and inlines simple single `patternProperties`.
package check

import "base:runtime"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/schema/rules"

// Result of attempting to conjoin a holder node's `allOf` + `$ref` arms for verdict-only evaluation.
@(private)
Conjoined :: struct {
	node: rules.Node_Index, // conjoined node, or `rules.NONE` if not conjoined
	kept: bool,             // whether remaining non-conjoined arms exist beside `node`
}

// Clones `src` into `tables`, settles statically-known `unevaluatedProperties`/`unevaluatedItems`,
// compiles inline single patterns, and returns the working `rules.Description` (never mutating `src`).
@(private)
conjoin_description :: proc(b: ^Builder, src: ^rules.Description, arena, tables: runtime.Allocator) -> (d: rules.Description) {
	d.allocator = tables
	d.root = src.root
	d.uri = src.uri
	err: runtime.Allocator_Error
	if d.nodes, err = make([dynamic]rules.Node, len(src.nodes), tables); err != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	for n, i in src.nodes {
		cp := n
		e1, e2, e3, e4: runtime.Allocator_Error
		cp.any_of, e1 = slice.clone(n.any_of, tables)
		cp.all_of, e2 = slice.clone(n.all_of, tables)
		cp.one_of, e3 = slice.clone(n.one_of, tables)
		cp.enum_of, e4 = slice.clone(n.enum_of, tables)
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		d.nodes[i] = cp
	}
	if d.arrays, err = make([dynamic]rules.Array, len(src.arrays), tables); err != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	for a, i in src.arrays {
		cp := a
		if cp.prefix, err = slice.clone(a.prefix, tables); err != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		d.arrays[i] = cp
	}
	if d.objects, err = make([dynamic]rules.Object, len(src.objects), tables); err != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	for o, i in src.objects {
		cp := o
		e1, e2, e3: runtime.Allocator_Error
		cp.members, e1 = slice.clone(o.members, tables)
		cp.patterns, e2 = slice.clone(o.patterns, tables)
		cp.dependents, e3 = make([]rules.Dependent, len(o.dependents), tables)
		if e1 != nil || e2 != nil || e3 != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		for dep, j in o.dependents {
			req, rerr := slice.clone(dep.required, tables)
			if rerr != nil {
				refuse_plan(b, .No_Memory)
				return
			}
			cp.dependents[j] = {name = dep.name, required = req, node = dep.node}
		}
		d.objects[i] = cp
	}
	e_a, e_b: runtime.Allocator_Error
	d.anchors, e_a = slice.clone_to_dynamic(src.anchors[:], tables)
	d.bases, e_b = slice.clone_to_dynamic(src.bases[:], tables)
	if e_a != nil || e_b != nil {
		refuse_plan(b, .No_Memory)
		return
	}

	// Settle statically-known `unevaluatedProperties` / `unevaluatedItems` first.
	for i in 0 ..< len(d.nodes) {
		settle_unevaluated(b, &d, rules.Node_Index(i), tables)
	}
	// Inline single `patternProperties` that do not collide with any named property.
	inline_patterns(b, &d, arena, tables)
	return d
}

// Inlines a single `patternProperties` on an object when it does not match any named member
// (so named members stay pure and non-named members test the one inline regex directly without forking).
@(private)
inline_patterns :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator) {
	scratch, serr := regex.scratch_make(tables)
	if serr.kind != .None {
		return
	}
	defer regex.scratch_destroy(&scratch)
	for &o, idx in d.objects {
		if len(o.patterns) != 1 {
			continue
		}
		p := o.patterns[0]
		re, rerr := rules.program_of(&b.programs, p.expression, arena, tables)
		if rerr.kind != .None {
			refuse_plan(b, .Unsupported, "patternProperties")
			return
		}
		collides := false
		for m in o.members {
			if m.only_required {
				continue
			}
			found, err := regex.search(re, m.name, 0, nil, &scratch)
			if err.kind != .None || found {
				collides = true
				break
			}
		}
		if !collides {
			b.inline[i32(idx)] = Inline_Pattern{
				expression = clone_str(b, arena, p.expression),
				node = p.node,
				regex = re,
			}
		}
	}
}

// Attempts to conjoin a plain `allOf` + `$ref` node into a single combined `rules.Node_Index` for
// the verdict-only path (no error sink), when every branch is a plain node (no `anyOf`, `oneOf`, `not`, `if`,
// `$dynamicRef`, `unevaluated*`, `contains`, `unique`, container `const`/`enum`, or `dependentSchemas`).
// Returns `rules.NONE` if not conjoinable.
@(private)
conjoin_verdict :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> rules.Node_Index {
	if edge != {} {
		return rules.NONE
	}
	ck := block_key(nil, i32(node), b.scope)
	if cached, seen := b.conjoined[ck]; seen {
		return cached.node
	}
	// Guard against cycles during conjoining.
	b.conjoined[ck] = {node = rules.NONE}
	n := &d.nodes[node]
	if len(n.all_of) == 0 && n.ref == nil && n.dynamic_ref == nil {
		return rules.NONE
	}
	// Must have no non-conjoinable keywords on the outer node itself.
	if !conjoinable_node(n) {
		return rules.NONE
	}
	// Collect flat list of all nodes reachable via `allOf`, `$ref`, and `$dynamicRef`.
	Stack_Item :: struct {
		node:  rules.Node_Index,
		scope: i32,
	}
	parts := make([dynamic]rules.Node_Index, tables)
	vis := make(map[Block_Key]bool, 16, tables)
	stack := make([dynamic]Stack_Item, tables)
	saved_top := b.scope
	enter_scope(b, d, arena, node)
	append(&stack, Stack_Item{node, b.scope})
	b.scope = saved_top
	for len(stack) > 0 {
		it := pop(&stack)
		cur := it.node
		cur_vk := block_key(nil, i32(cur), it.scope)
		if cur == rules.NONE || vis[cur_vk] {
			continue
		}
		vis[cur_vk] = true
		cn := &d.nodes[cur]
		// Do not flatten across distinct schema resources when dynamic anchors exist (A-C4)!
		if len(d.anchors) > 0 && cn.resource != n.resource {
			return rules.NONE
		}
		if !conjoinable_node(cn) {
			return rules.NONE
		}
		// Only conjoin if there are no un-inlined patterns or dependentSchemas.
		if cn.object >= 0 {
			o := &d.objects[cn.object]
			if len(o.patterns) > 0 {
				return rules.NONE
			}
			for dep in o.dependents {
				if dep.node != nil {
					return rules.NONE
				}
			}
		}
		if cn.array >= 0 {
			a := &d.arrays[cn.array]
			if a.contains != nil {
				return rules.NONE
			}
		}
		append(&parts, cur)
		if r, has := cn.ref.?; has {
			sv := b.scope
			b.scope = it.scope
			enter_scope(b, d, arena, r)
			rs := b.scope
			b.scope = sv
			append(&stack, Stack_Item{r, rs})
		}
		if dr, has := cn.dynamic_ref.?; has {
			sv := b.scope
			b.scope = it.scope
			target := dynamic_target(b, d, cn, dr)
			enter_scope(b, d, arena, target)
			ts := b.scope
			b.scope = sv
			append(&stack, Stack_Item{target, ts})
		}
		for a in cn.all_of {
			append(&stack, Stack_Item{a, it.scope})
		}
	}
	if len(parts) <= 1 {
		return rules.NONE
	}
	// Merge all parts into one node in `d`.
	merged := rules.Node{
		kinds = rules.EVERY_KIND,
		array = -1,
		object = -1,
		resource = n.resource,
	}
	// Intersect kinds and merge scalar rules.
	for pid in parts {
		pn := &d.nodes[pid]
		pk := pn.kinds + ({.Integer} if .Number in pn.kinds else {})
		merged.kinds &= pk
		merged.integer_spelled ||= pn.integer_spelled
		r, clash := rules.merged(&merged, pn.rules)
		if clash != "" {
			return rules.NONE
		}
		merged.rules = r
		// Merge enum/const only if at most one part sets them.
		if pn.has_enum || pn.const_of != nil {
			if merged.has_enum || merged.const_of != nil {
				return rules.NONE
			}
			merged.has_enum = pn.has_enum
			merged.enum_of = pn.enum_of
			merged.const_of = pn.const_of
		}
	}
	// Merge object shapes if any part has one.
	obj_parts := make([dynamic]i32, tables)
	arr_parts := make([dynamic]i32, tables)
	for pid in parts {
		pn := &d.nodes[pid]
		if pn.object >= 0 {
			append(&obj_parts, pn.object)
		}
		if pn.array >= 0 {
			append(&arr_parts, pn.array)
		}
	}
	if len(obj_parts) > 0 {
		obj_idx, ok := conjoin_objects(b, d, arena, tables, obj_parts[:])
		if !ok {
			return rules.NONE
		}
		merged.object = obj_idx
	}
	if len(arr_parts) > 0 {
		arr_idx, ok := conjoin_arrays(b, d, arena, tables, arr_parts[:])
		if !ok {
			return rules.NONE
		}
		merged.array = arr_idx
	}
	new_idx := rules.Node_Index(len(d.nodes))
	append(&d.nodes, merged)
	b.conjoined[ck] = {node = new_idx}
	return new_idx
}

@(private = "file")
conjoinable_node :: proc "contextless" (n: ^rules.Node) -> bool {
	if len(n.any_of) > 0 || len(n.one_of) > 0 || n.not != nil || n.cond != {} || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return false
	}
	if n.rules.unique {
		return false
	}
	if arm_operands(n) {
		return false
	}
	return true
}

@(private = "file")
conjoin_objects :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator, ids: []i32) -> (i32, bool) {
	if len(ids) == 1 {
		return ids[0], true
	}
	// Collect all named members across all objects.
	by_name := make(map[string]int, 16, tables)
	members := make([dynamic]rules.Member, tables)
	deps := make([dynamic]rules.Dependent, tables)
	add_nodes := make([dynamic]rules.Node_Index, tables)
	key_nodes := make([dynamic]rules.Node_Index, tables)
	for id in ids {
		o := &d.objects[id]
		if o.additional != rules.NONE {
			append(&add_nodes, o.additional)
		}
		if o.keys != rules.NONE {
			append(&key_nodes, o.keys)
		}
		for dep in o.dependents {
			if len(dep.required) > 0 {
				append(&deps, dep)
			}
		}
		for m in o.members {
			if idx, exists := by_name[m.name]; exists {
				existing := &members[idx]
				existing.required ||= m.required
				if m.only_required {
					continue
				}
				if existing.only_required {
					existing.node = m.node
					existing.rules = m.rules
					existing.only_required = false
				} else {
					pair, ok := conjoin_pair(b, d, tables, existing.node, m.node)
					if !ok {
						return -1, false
					}
					existing.node = pair
					r, clash := rules.merged(&rules.Node{rules = existing.rules}, m.rules)
					if clash != "" {
						return -1, false
					}
					existing.rules = r
				}
			} else {
				by_name[m.name] = len(members)
				append(&members, m)
			}
		}
	}
	// For each object that had an `additionalProperties` schema, apply it to any member that wasn't
	// explicitly declared in THAT object!
	for id in ids {
		o := &d.objects[id]
		if o.additional == rules.NONE {
			continue
		}
		for &m in members {
			if m.only_required {
				continue
			}
			in_o := false
			for om in o.members {
				if om.name == m.name && !om.only_required {
					in_o = true
					break
				}
			}
			if !in_o {
				pair, ok := conjoin_pair(b, d, tables, m.node, o.additional)
				if !ok {
					return -1, false
				}
				m.node = pair
			}
		}
	}
	additional := rules.NONE
	for an in add_nodes {
		pair, ok := conjoin_pair(b, d, tables, additional, an)
		if !ok {
			return -1, false
		}
		additional = pair
	}
	keys := rules.NONE
	for kn in key_nodes {
		pair, ok := conjoin_pair(b, d, tables, keys, kn)
		if !ok {
			return -1, false
		}
		keys = pair
	}
	idx := i32(len(d.objects))
	append(&d.objects, rules.Object{
		members = members[:],
		additional = additional,
		keys = keys,
		dependents = deps[:],
	})
	return idx, true
}

@(private = "file")
conjoin_arrays :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator, ids: []i32) -> (i32, bool) {
	if len(ids) == 1 {
		return ids[0], true
	}
	max_prefix := 0
	for id in ids {
		max_prefix = max(max_prefix, len(d.arrays[id].prefix))
	}
	prefix := make([]rules.Node_Index, max_prefix, tables)
	for i in 0 ..< max_prefix {
		acc := rules.NONE
		for id in ids {
			a := &d.arrays[id]
			sub := a.prefix[i] if i < len(a.prefix) else a.items
			pair, ok := conjoin_pair(b, d, tables, acc, sub)
			if !ok {
				return -1, false
			}
			acc = pair
		}
		prefix[i] = acc
	}
	items := rules.NONE
	for id in ids {
		pair, ok := conjoin_pair(b, d, tables, items, d.arrays[id].items)
		if !ok {
			return -1, false
		}
		items = pair
	}
	idx := i32(len(d.arrays))
	append(&d.arrays, rules.Array{prefix = prefix, items = items})
	return idx, true
}

@(private)
conjoin_pair :: proc(b: ^Builder, d: ^rules.Description, tables: runtime.Allocator, a, c: rules.Node_Index) -> (rules.Node_Index, bool) {
	if a == rules.NONE || judges_nothing(b, d, a) {
		return c, true
	}
	if c == rules.NONE || judges_nothing(b, d, c) {
		return a, true
	}
	if a == c {
		return a, true
	}
	// Do not synthesize a single-resource `allOf` node across distinct resources when dynamic anchors exist (A-C4).
	if len(d.anchors) > 0 && d.nodes[a].resource != d.nodes[c].resource {
		return rules.NONE, false
	}
	key := [2]rules.Node_Index{min(a, c), max(a, c)}
	if cached, ok := b.pairs[key]; ok {
		return cached, true
	}
	// Create an `allOf: [a, c]` synthetic node in `d`.
	all_of := make([]rules.Node_Index, 2, tables)
	all_of[0], all_of[1] = a, c
	idx := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{
		kinds = rules.EVERY_KIND,
		array = -1,
		object = -1,
		all_of = all_of,
		resource = d.nodes[a].resource,
	})
	b.pairs[key] = idx
	return idx, true
}
