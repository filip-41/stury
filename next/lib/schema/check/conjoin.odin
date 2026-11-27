// Conjoins `allOf` and `$ref` chains into single verdict nodes and inlines simple single `patternProperties`.
package check

import "base:runtime"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/schema/rules"

@(private)
Conjoined :: struct {
	node: rules.Node_Index, // conjoined node, or `rules.NONE` if not conjoined
	kept: bool,             // whether remaining non-conjoined arms exist beside `node`
}

// Clones `src` into `tables`, settles statically-known `unevaluatedProperties`/`unevaluatedItems`,
// compiles inline single patterns, and returns the working `rules.Description` (never mutating `src`).
@(private)
conjoin_description :: proc(b: ^Builder, src: ^rules.Description, arena, tables: runtime.Allocator) -> (d: rules.Description) {
	clone_slice :: proc(b: ^Builder, s: []$T, a: runtime.Allocator) -> []T {
		out, err := slice.clone(s, a)
		if err != nil { refuse_plan(b, .No_Memory) }
		return out
	}

	d = {allocator = tables, root = src.root, uri = src.uri}
	e1, e2, e3, e4, e5: runtime.Allocator_Error
	d.nodes, e1 = make([dynamic]rules.Node, len(src.nodes), tables)
	d.arrays, e2 = make([dynamic]rules.Array, len(src.arrays), tables)
	d.objects, e3 = make([dynamic]rules.Object, len(src.objects), tables)
	d.anchors, e4 = slice.clone_to_dynamic(src.anchors[:], tables)
	d.bases, e5 = slice.clone_to_dynamic(src.bases[:], tables)
	if e1 != nil || e2 != nil || e3 != nil || e4 != nil || e5 != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	for n, i in src.nodes {
		cp := n
		cp.any_of = clone_slice(b, n.any_of, tables)
		cp.all_of = clone_slice(b, n.all_of, tables)
		cp.one_of = clone_slice(b, n.one_of, tables)
		cp.enum_of = clone_slice(b, n.enum_of, tables)
		d.nodes[i] = cp
	}
	for a, i in src.arrays {
		cp := a
		cp.prefix = clone_slice(b, a.prefix, tables)
		d.arrays[i] = cp
	}
	for o, i in src.objects {
		cp := o
		cp.members = clone_slice(b, o.members, tables)
		cp.patterns = clone_slice(b, o.patterns, tables)
		deps, derr := make([]rules.Dependent, len(o.dependents), tables)
		if derr != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		for dep, j in o.dependents {
			deps[j] = {name = dep.name, required = clone_slice(b, dep.required, tables), node = dep.node}
		}
		cp.dependents = deps
		d.objects[i] = cp
	}
	if b.err.kind != .None { return }
	for i in 0 ..< len(d.nodes) {
		settle_unevaluated(b, &d, rules.Node_Index(i), tables)
	}
	inline_patterns(b, &d, arena, tables)
	return d
}

// Inlines a single `patternProperties` on an object when it does not collide with any named member.
@(private)
inline_patterns :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator) {
	scratch, serr := regex.scratch_make(tables)
	if serr.kind != .None { return }
	defer regex.scratch_destroy(&scratch)
	for &o, idx in d.objects {
		if len(o.patterns) != 1 { continue }
		p := o.patterns[0]
		re, rerr := rules.program_of(&b.programs, p.expression, arena, tables)
		if rerr.kind != .None {
			refuse_plan(b, .Unsupported, "patternProperties")
			return
		}
		collides := false
		for m in o.members {
			if m.only_required { continue }
			if found, err := regex.search(re, m.name, 0, nil, &scratch); err.kind != .None || found {
				collides = true
				break
			}
		}
		if !collides {
			b.inline[i32(idx)] = {expression = clone_str(b, arena, p.expression), node = p.node, regex = re}
		}
	}
}

// Attempts to conjoin a plain `allOf` + `$ref` node into a single combined `rules.Node_Index` for verdict-only mode.
@(private)
conjoin_verdict :: proc(b: ^Builder, d: ^rules.Description, arena, tables: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> rules.Node_Index {
	if edge != {} { return rules.NONE }
	ck := block_key(nil, i32(node), b.scope)
	if cached, seen := b.conjoined[ck]; seen { return cached.node }
	b.conjoined[ck] = {node = rules.NONE}
	n := &d.nodes[node]
	if (len(n.all_of) == 0 && n.ref == nil && n.dynamic_ref == nil) || !conjoinable_node(n) {
		return rules.NONE
	}
	Stack_Item :: struct {
		node:  rules.Node_Index,
		scope: i32,
	}
	push_scoped :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, stack: ^[dynamic]Stack_Item, base_scope: i32, target: rules.Node_Index) {
		sv := b.scope
		b.scope = base_scope
		enter_scope(b, d, arena, target)
		ts := b.scope
		b.scope = sv
		append(stack, Stack_Item{target, ts})
	}
	parts := make([dynamic]rules.Node_Index, tables)
	vis := make(map[Block_Key]bool, 16, tables)
	stack := make([dynamic]Stack_Item, tables)
	push_scoped(b, d, arena, &stack, b.scope, node)
	for len(stack) > 0 {
		it := pop(&stack)
		cur := it.node
		cur_vk := block_key(nil, i32(cur), it.scope)
		if cur == rules.NONE || vis[cur_vk] { continue }
		vis[cur_vk] = true
		cn := &d.nodes[cur]
		// Do not flatten across distinct schema resources when dynamic anchors exist (A-C4).
		if (len(d.anchors) > 0 && cn.resource != n.resource) || !conjoinable_node(cn) { return rules.NONE }
		if cn.object >= 0 {
			o := &d.objects[cn.object]
			if len(o.patterns) > 0 { return rules.NONE }
			for dep in o.dependents {
				if dep.node != nil { return rules.NONE }
			}
		}
		if cn.array >= 0 && d.arrays[cn.array].contains != nil { return rules.NONE }
		append(&parts, cur)
		if r, has := cn.ref.?; has { push_scoped(b, d, arena, &stack, it.scope, r) }
		if dr, has := cn.dynamic_ref.?; has {
			sv := b.scope
			b.scope = it.scope
			target := dynamic_target(b, d, cn, dr)
			b.scope = sv
			push_scoped(b, d, arena, &stack, it.scope, target)
		}
		for a in cn.all_of {
			append(&stack, Stack_Item{a, it.scope})
		}
	}
	if len(parts) <= 1 { return rules.NONE }
	merged := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, resource = n.resource}
	obj_parts := make([dynamic]i32, tables)
	arr_parts := make([dynamic]i32, tables)
	for pid in parts {
		pn := &d.nodes[pid]
		merged.kinds &= pn.kinds + ({.Integer} if .Number in pn.kinds else {})
		merged.integer_spelled ||= pn.integer_spelled
		r, clash := rules.merged(&merged, pn.rules)
		if clash != "" { return rules.NONE }
		merged.rules = r
		if pn.has_enum || pn.const_of != nil {
			if merged.has_enum || merged.const_of != nil { return rules.NONE }
			merged.has_enum, merged.enum_of, merged.const_of = pn.has_enum, pn.enum_of, pn.const_of
		}
		if pn.object >= 0 { append(&obj_parts, pn.object) }
		if pn.array >= 0 { append(&arr_parts, pn.array) }
	}
	if len(obj_parts) > 0 {
		obj_idx, ok := conjoin_objects(b, d, tables, obj_parts[:])
		if !ok { return rules.NONE }
		merged.object = obj_idx
	}
	if len(arr_parts) > 0 {
		arr_idx, ok := conjoin_arrays(b, d, tables, arr_parts[:])
		if !ok { return rules.NONE }
		merged.array = arr_idx
	}
	new_idx := rules.Node_Index(len(d.nodes))
	append(&d.nodes, merged)
	b.conjoined[ck] = {node = new_idx}
	return new_idx
}

@(private = "file")
conjoinable_node :: proc "contextless" (n: ^rules.Node) -> bool {
	return len(n.any_of) == 0 && len(n.one_of) == 0 && n.not == nil && n.cond == {} && n.unevaluated_items == nil && n.unevaluated_properties == nil && !n.rules.unique && !arm_operands(n)
}

@(private = "file")
conjoin_objects :: proc(b: ^Builder, d: ^rules.Description, tables: runtime.Allocator, ids: []i32) -> (i32, bool) {
	if len(ids) == 1 { return ids[0], true }
	by_name := make(map[string]int, 16, tables)
	members := make([dynamic]rules.Member, tables)
	deps := make([dynamic]rules.Dependent, tables)
	additional, keys := rules.Node_Index(rules.NONE), rules.Node_Index(rules.NONE)
	for id in ids {
		o := &d.objects[id]
		ok: bool
		if additional, ok = conjoin_pair(b, d, tables, additional, o.additional); !ok { return -1, false }
		if keys, ok = conjoin_pair(b, d, tables, keys, o.keys); !ok { return -1, false }
		for dep in o.dependents {
			if len(dep.required) > 0 { append(&deps, dep) }
		}
		for m in o.members {
			if idx, exists := by_name[m.name]; exists {
				existing := &members[idx]
				existing.required ||= m.required
				if m.only_required { continue }
				if existing.only_required {
					existing.node, existing.rules, existing.only_required = m.node, m.rules, false
				} else {
					pair, pok := conjoin_pair(b, d, tables, existing.node, m.node)
					r, clash := rules.merged(&rules.Node{rules = existing.rules}, m.rules)
					if !pok || clash != "" { return -1, false }
					existing.node, existing.rules = pair, r
				}
			} else {
				by_name[m.name] = len(members)
				append(&members, m)
			}
		}
	}
	// Apply each object's `additionalProperties` to any member not explicitly declared in THAT object.
	for id in ids {
		o := &d.objects[id]
		if o.additional == rules.NONE { continue }
		for &m in members {
			if m.only_required { continue }
			in_o := false
			for om in o.members {
				if om.name == m.name && !om.only_required {
					in_o = true
					break
				}
			}
			if !in_o {
				pair, ok := conjoin_pair(b, d, tables, m.node, o.additional)
				if !ok { return -1, false }
				m.node = pair
			}
		}
	}
	idx := i32(len(d.objects))
	append(&d.objects, rules.Object{members = members[:], additional = additional, keys = keys, dependents = deps[:]})
	return idx, true
}

@(private = "file")
conjoin_arrays :: proc(b: ^Builder, d: ^rules.Description, tables: runtime.Allocator, ids: []i32) -> (i32, bool) {
	if len(ids) == 1 { return ids[0], true }
	max_prefix := 0
	for id in ids {
		max_prefix = max(max_prefix, len(d.arrays[id].prefix))
	}
	prefix := make([]rules.Node_Index, max_prefix, tables)
	for i in 0 ..< max_prefix {
		acc := rules.Node_Index(rules.NONE)
		for id in ids {
			a := &d.arrays[id]
			sub := a.prefix[i] if i < len(a.prefix) else a.items
			ok: bool
			if acc, ok = conjoin_pair(b, d, tables, acc, sub); !ok { return -1, false }
		}
		prefix[i] = acc
	}
	items := rules.Node_Index(rules.NONE)
	for id in ids {
		ok: bool
		if items, ok = conjoin_pair(b, d, tables, items, d.arrays[id].items); !ok { return -1, false }
	}
	idx := i32(len(d.arrays))
	append(&d.arrays, rules.Array{prefix = prefix, items = items})
	return idx, true
}

@(private)
conjoin_pair :: proc(b: ^Builder, d: ^rules.Description, tables: runtime.Allocator, a, c: rules.Node_Index) -> (rules.Node_Index, bool) {
	if a == rules.NONE || judges_nothing(b, d, a) { return c, true }
	if c == rules.NONE || judges_nothing(b, d, c) { return a, true }
	if a == c { return a, true }
	if len(d.anchors) > 0 && d.nodes[a].resource != d.nodes[c].resource { return rules.NONE, false }
	key := [2]rules.Node_Index{min(a, c), max(a, c)}
	if cached, ok := b.pairs[key]; ok { return cached, true }
	all_of := make([]rules.Node_Index, 2, tables)
	all_of[0], all_of[1] = a, c
	idx := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1, all_of = all_of, resource = d.nodes[a].resource})
	b.pairs[key] = idx
	return idx, true
}
