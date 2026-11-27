// Static evaluation analysis for `unevaluatedProperties` and `unevaluatedItems`.
package check

import "base:runtime"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/schema/rules"

// Which elements and members of a value a node's subschemas evaluate when the node passes.
// `refs` keeps unconditional child `^Evaluates` edges (`$ref`, `$dynamicRef`, `allOf`) so cyclic `$ref`s
// never drop properties and are traversed safely with a visited set at runtime.
@(private)
Evaluates :: struct {
	all_items:   bool,
	items:       int,
	all_members: bool,
	names:       []string,
	patterns:    []^regex.Regex,
	refs:        []^Evaluates,
	inner:       []Inner,
}

@(private)
Inner_Kind :: enum u8 {
	Any,
	One,
	If,
	Dependent,
	Contains,
}

@(private)
Inner :: struct {
	kind:         Inner_Kind,
	arms:         []i32, // record indices (for `.Any`, `.One`)
	test:         i32,   // for `.If`
	then:         i32,   // for `.If`
	other:        i32,   // for `.If`
	name:         string, // for `.Dependent`
	body:         i32,   // for `.Dependent`, `.Contains`
	min_contains: u64,   // for `.Contains` (B-H6: only annotate when contains bounds pass!)
	max_contains: u64,   // for `.Contains`
	evals:        []^Evaluates,
	test_eval:    ^Evaluates,
	then_eval:    ^Evaluates,
	other_eval:   ^Evaluates,
	body_eval:    ^Evaluates,
}

@(private)
Nothing :: enum u8 {
	Unknown,
	Checking,
	Yes,
	No,
}

// Whether `node` accepts every value without restriction.
@(private)
judges_nothing :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index) -> bool {
	if node == rules.NONE { return true }
	if state, seen := b.nothing[node]; seen { return state == .Yes }
	b.nothing[node] = .Checking
	res := false
	defer b.nothing[node] = .Yes if res else .No

	n := &d.nodes[node]
	if n.kinds != rules.EVERY_KIND || n.has_enum || n.const_of != nil || n.not != nil || len(n.one_of) > 0 {
		return false
	}
	r := n.rules
	if r.minimum != "" || r.maximum != "" || r.multiple_of != "" || r.pattern != "" || (r.assert_format && rules.format_of(r.format) != .None) || r.unique || r.min_length > 0 || r.max_length != nil || r.min_items > 0 || r.max_items != nil || r.min_members > 0 || r.max_members != nil {
		return false
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if a.contains != nil || !judges_nothing(b, d, a.items) { return false }
		for p in a.prefix {
			if !judges_nothing(b, d, p) { return false }
		}
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if !judges_nothing(b, d, o.additional) || !judges_nothing(b, d, o.keys) { return false }
		for m in o.members {
			if m.required || m.rules != {} || !judges_nothing(b, d, m.node) { return false }
		}
		for p in o.patterns {
			if !judges_nothing(b, d, p.node) { return false }
		}
		for dep in o.dependents {
			if len(dep.required) > 0 { return false }
			if dn, has := dep.node.?; has && !judges_nothing(b, d, dn) { return false }
		}
	}
	if r_node, has := n.ref.?; has && !judges_nothing(b, d, r_node) { return false }
	if dr, has := n.dynamic_ref.?; has && !judges_nothing(b, d, dynamic_target(b, d, n, dr)) {
		return false
	}
	for a in n.all_of {
		if !judges_nothing(b, d, a) { return false }
	}
	if len(n.any_of) > 0 {
		ok := false
		for a in n.any_of {
			if judges_nothing(b, d, a) {
				ok = true
				break
			}
		}
		if !ok { return false }
	}
	if n.cond.test != nil {
		if th, has := n.cond.then.?; has && !judges_nothing(b, d, th) { return false }
		if ot, has := n.cond.other.?; has && !judges_nothing(b, d, ot) { return false }
	}
	if ui, has := n.unevaluated_items.?; has && !judges_nothing(b, d, ui) { return false }
	if up, has := n.unevaluated_properties.?; has && !judges_nothing(b, d, up) { return false }
	res = true
	return true
}

@(private)
Static_Set :: struct {
	static:       bool,
	all_items:    bool,
	all_members:  bool,
	has_patterns: bool,
}

@(private = "file")
static_set :: proc(d: ^rules.Description, node: rules.Node_Index, seen: ^map[rules.Node_Index]bool, out: ^Static_Set) {
	if node == rules.NONE || seen[node] || !out.static { return }
	seen[node] = true
	n := &d.nodes[node]
	if len(n.any_of) > 0 || len(n.one_of) > 0 || n.cond.test != nil || n.dynamic_ref != nil {
		out.static = false
		return
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if a.contains != nil && a.evaluates_contains {
			out.static = false
			return
		}
		if a.items != rules.NONE { out.all_items = true }
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		for dep in o.dependents {
			if dep.node != nil {
				out.static = false
				return
			}
		}
		if len(o.patterns) > 0 { out.has_patterns = true }
		if o.additional != rules.NONE { out.all_members = true }
	}
	if n.unevaluated_items != nil { out.all_items = true }
	if n.unevaluated_properties != nil { out.all_members = true }
	if r, has := n.ref.?; has { static_set(d, r, seen, out) }
	for a in n.all_of {
		static_set(d, a, seen, out)
	}
}

@(private = "file")
probe_static :: proc(d: ^rules.Description, node: rules.Node_Index, scratch: runtime.Allocator) -> Static_Set {
	seen := make(map[rules.Node_Index]bool, 16, scratch)
	st := Static_Set{static = true}
	static_set(d, node, &seen, &st)
	return st
}

// Rewrites `unevaluatedProperties` / `unevaluatedItems` directly into `additionalProperties` / `items` when all
// evaluated members/items of `node` are statically known.
@(private)
settle_unevaluated :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, scratch: runtime.Allocator) {
	n := &d.nodes[node]
	if up, has := n.unevaluated_properties.?; has {
		n.unevaluated_properties = nil
		st := probe_static(d, node, scratch)
		n.unevaluated_properties = up
		if st.static {
			if st.all_members {
				n.unevaluated_properties = nil
			} else if !st.has_patterns && len(n.all_of) == 0 && n.ref == nil {
				if n.object < 0 || (d.objects[n.object].additional == rules.NONE && len(d.objects[n.object].patterns) == 0) {
					// Clone a fresh Object entry so sibling nodes sharing `n.object` are never mutated.
					cp := d.objects[n.object] if n.object >= 0 else rules.Object{keys = rules.NONE}
					cp.additional = up
					idx := i32(len(d.objects))
					append(&d.objects, cp)
					n.object = idx
					b.unevaluated[{0, idx}] = true
					n.unevaluated_properties = nil
				}
			}
		}
	}
	if ui, has := n.unevaluated_items.?; has {
		n.unevaluated_items = nil
		st := probe_static(d, node, scratch)
		n.unevaluated_items = ui
		if st.static {
			if st.all_items {
				n.unevaluated_items = nil
			} else if len(n.all_of) == 0 && n.ref == nil {
				if n.array < 0 || d.arrays[n.array].items == rules.NONE {
					// Clone a fresh Array entry so sibling nodes sharing `n.array` are never mutated.
					cp := d.arrays[n.array] if n.array >= 0 else rules.Array{}
					cp.items = ui
					idx := i32(len(d.arrays))
					append(&d.arrays, cp)
					n.array = idx
					b.unevaluated[{1, idx}] = true
					n.unevaluated_items = nil
				}
			}
		}
	}
}

// Builds the runtime `Evaluates` descriptor for `node` in the current dynamic scope.
// Keeps child `^Evaluates` edges in `ev.refs` so cyclic `$ref`s never lose evaluations (A-C3),
// and distinguishes `skip_own_uneval` cache keys so sibling `unevaluated*` never alias (B-C7).
@(private)
evaluates :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, skip_own_uneval := false) -> ^Evaluates {
	if node == rules.NONE { return nil }
	key := block_key(typeid_of(Evaluates), i32(node) * 2 + (1 if skip_own_uneval else 0), b.scope)
	if cached, ok := b.evaluated[key]; ok { return cached }
	ev, err := new(Evaluates, arena)
	if err != nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	b.evaluated[key] = ev
	names := make([dynamic]string, arena)
	patterns := make([dynamic]^regex.Regex, arena)
	refs := make([dynamic]^Evaluates, arena)
	inners := make([dynamic]Inner, arena)
	collect_evaluates(b, d, arena, node, skip_own_uneval, ev, &names, &patterns, &refs, &inners)
	ev.names, ev.patterns, ev.refs, ev.inner = names[:], patterns[:], refs[:], inners[:]
	return ev
}

@(private = "file")
collect_evaluates :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, skip_own_uneval: bool, ev: ^Evaluates, names: ^[dynamic]string, patterns: ^[dynamic]^regex.Regex, refs: ^[dynamic]^Evaluates, inners: ^[dynamic]Inner) {
	push_scoped_ref :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, target: rules.Node_Index, refs: ^[dynamic]^Evaluates) {
		saved := b.scope
		enter_scope(b, d, arena, target)
		sub := evaluates(b, d, arena, target)
		b.scope = saved
		if sub != nil { append(refs, sub) }
	}
	push_arms :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, kind: Inner_Kind, nodes: []rules.Node_Index, inners: ^[dynamic]Inner) {
		if len(nodes) == 0 { return }
		arms, aerr := make([]i32, len(nodes), arena)
		evals, eerr := make([]^Evaluates, len(nodes), arena)
		if aerr != nil || eerr != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		for a, i in nodes {
			arms[i] = arm_record(b, d, arena, a, nil)
			evals[i] = evaluates(b, d, arena, a)
		}
		append(inners, Inner{kind = kind, arms = arms, evals = evals})
	}

	if node == rules.NONE { return }
	n := &d.nodes[node]
	if n.array >= 0 {
		a := &d.arrays[n.array]
		ev.items = max(ev.items, len(a.prefix))
		if a.items != rules.NONE { ev.all_items = true }
		if c, has := a.contains.?; has && a.evaluates_contains {
			append(inners, Inner{
				kind = .Contains,
				body = arm_record(b, d, arena, c, nil),
				min_contains = a.min_contains.? or_else 1,
				max_contains = a.max_contains.? or_else max(u64),
			})
		}
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		for m in o.members {
			if !m.only_required && !slice.contains(names[:], m.name) {
				append(names, clone_str(b, arena, m.name))
			}
		}
		for p in o.patterns {
			re, rerr := rules.program_of(&b.programs, p.expression, arena, b.tables)
			if rerr.kind == .None && !slice.contains(patterns[:], re) { append(patterns, re) }
		}
		if o.additional != rules.NONE { ev.all_members = true }
		for dep in o.dependents {
			if dn, has := dep.node.?; has {
				append(inners, Inner{
					kind = .Dependent,
					name = clone_str(b, arena, dep.name),
					body = arm_record(b, d, arena, dn, nil),
					body_eval = evaluates(b, d, arena, dn),
				})
			}
		}
	}
	if !skip_own_uneval {
		ev.all_items ||= n.unevaluated_items != nil
		ev.all_members ||= n.unevaluated_properties != nil
	}
	if r, has := n.ref.?; has { push_scoped_ref(b, d, arena, r, refs) }
	if dr, has := n.dynamic_ref.?; has { push_scoped_ref(b, d, arena, dynamic_target(b, d, n, dr), refs) }
	for a in n.all_of {
		if sub := evaluates(b, d, arena, a); sub != nil { append(refs, sub) }
	}
	push_arms(b, d, arena, .Any, n.any_of, inners)
	push_arms(b, d, arena, .One, n.one_of, inners)
	if test, has := n.cond.test.?; has {
		inn := Inner{kind = .If, test = arm_record(b, d, arena, test, nil), then = -1, other = -1, test_eval = evaluates(b, d, arena, test)}
		if th, has_th := n.cond.then.?; has_th {
			inn.then = arm_record(b, d, arena, th, nil)
			inn.then_eval = evaluates(b, d, arena, th)
		}
		if ot, has_ot := n.cond.other.?; has_ot {
			inn.other = arm_record(b, d, arena, ot, nil)
			inn.other_eval = evaluates(b, d, arena, ot)
		}
		append(inners, inn)
	}
}
