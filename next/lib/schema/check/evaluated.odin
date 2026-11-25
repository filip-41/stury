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

// Whether a node is known to judge nothing (always passes for every value).
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
	if node == rules.NONE {
		return true
	}
	if state, seen := b.nothing[node]; seen {
		return state == .Yes
	}
	b.nothing[node] = .Checking
	n := &d.nodes[node]
	if n.kinds != rules.EVERY_KIND || n.has_enum || n.const_of != nil || n.not != nil {
		b.nothing[node] = .No
		return false
	}
	if n.rules.minimum != "" || n.rules.maximum != "" || n.rules.multiple_of != "" || n.rules.pattern != "" || (n.rules.assert_format && rules.format_of(n.rules.format) != .None) || n.rules.unique || n.rules.min_length > 0 || n.rules.max_length != nil || n.rules.min_items > 0 || n.rules.max_items != nil || n.rules.min_members > 0 || n.rules.max_members != nil {
		b.nothing[node] = .No
		return false
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if a.contains != nil {
			b.nothing[node] = .No
			return false
		}
		for p in a.prefix {
			if !judges_nothing(b, d, p) {
				b.nothing[node] = .No
				return false
			}
		}
		if !judges_nothing(b, d, a.items) {
			b.nothing[node] = .No
			return false
		}
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if !judges_nothing(b, d, o.additional) || !judges_nothing(b, d, o.keys) {
			b.nothing[node] = .No
			return false
		}
		for m in o.members {
			if m.required || m.rules != {} || !judges_nothing(b, d, m.node) {
				b.nothing[node] = .No
				return false
			}
		}
		for p in o.patterns {
			if !judges_nothing(b, d, p.node) {
				b.nothing[node] = .No
				return false
			}
		}
		for dep in o.dependents {
			if len(dep.required) > 0 {
				b.nothing[node] = .No
				return false
			}
			if dn, has := dep.node.?; has && !judges_nothing(b, d, dn) {
				b.nothing[node] = .No
				return false
			}
		}
	}
	if r, has := n.ref.?; has && !judges_nothing(b, d, r) {
		b.nothing[node] = .No
		return false
	}
	if dr, has := n.dynamic_ref.?; has {
		target := dynamic_target(b, d, n, dr)
		if !judges_nothing(b, d, target) {
			b.nothing[node] = .No
			return false
		}
	}
	for a in n.all_of {
		if !judges_nothing(b, d, a) {
			b.nothing[node] = .No
			return false
		}
	}
	if len(n.any_of) > 0 {
		ok := false
		for a in n.any_of {
			if judges_nothing(b, d, a) {
				ok = true
				break
			}
		}
		if !ok {
			b.nothing[node] = .No
			return false
		}
	}
	if len(n.one_of) > 0 {
		b.nothing[node] = .No
		return false
	}
	if n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil) {
		if th, has := n.cond.then.?; has && !judges_nothing(b, d, th) {
			b.nothing[node] = .No
			return false
		}
		if ot, has := n.cond.other.?; has && !judges_nothing(b, d, ot) {
			b.nothing[node] = .No
			return false
		}
	}
	if ui, has := n.unevaluated_items.?; has && !judges_nothing(b, d, ui) {
		b.nothing[node] = .No
		return false
	}
	if up, has := n.unevaluated_properties.?; has && !judges_nothing(b, d, up) {
		b.nothing[node] = .No
		return false
	}
	b.nothing[node] = .Yes
	return true
}

// Static evaluation summary for a node with no runtime-dynamic inner branches.
@(private)
Static_Set :: struct {
	static:      bool,
	all_items:   bool,
	items:       int,
	all_members: bool,
	names:       [dynamic]string,
	patterns:    [dynamic]string,
}

// Computes the static set of items/properties evaluated by `node` when there are no runtime-dependent branches
// (`anyOf`, `oneOf`, `if`, `dependentSchemas`, `contains`, `$dynamicRef`).
@(private)
static_set :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, seen: ^map[rules.Node_Index]bool, out: ^Static_Set) {
	if node == rules.NONE {
		return
	}
	if seen[node] {
		return
	}
	seen[node] = true
	n := &d.nodes[node]
	if len(n.any_of) > 0 || len(n.one_of) > 0 || (n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil)) || n.dynamic_ref != nil {
		out.static = false
		return
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if a.contains != nil && a.evaluates_contains {
			out.static = false
			return
		}
		if len(a.prefix) > out.items {
			out.items = len(a.prefix)
		}
		if a.items != rules.NONE {
			out.all_items = true
		}
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		for dep in o.dependents {
			if dep.node != nil {
				out.static = false
				return
			}
		}
		for m in o.members {
			if !m.only_required && !slice.contains(out.names[:], m.name) {
				append(&out.names, m.name)
			}
		}
		for p in o.patterns {
			if !slice.contains(out.patterns[:], p.expression) {
				append(&out.patterns, p.expression)
			}
		}
		if o.additional != rules.NONE {
			out.all_members = true
		}
	}
	if n.unevaluated_items != nil {
		out.all_items = true
	}
	if n.unevaluated_properties != nil {
		out.all_members = true
	}
	if r, has := n.ref.?; has {
		static_set(b, d, r, seen, out)
	}
	for a in n.all_of {
		static_set(b, d, a, seen, out)
	}
}

// Rewrites `unevaluatedProperties` / `unevaluatedItems` directly into `additionalProperties` / `items` when all
// evaluated members/items of `node` are statically known (e.g., no branching subschemas or already completely covered).
@(private)
settle_unevaluated :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, scratch: runtime.Allocator) {
	n := &d.nodes[node]
	if n.unevaluated_properties == nil && n.unevaluated_items == nil {
		return
	}
	// If unevaluated subschema judges nothing, it still evaluates everything (for outer unevaluated),
	// but imposes no constraint on this node itself.
	if up, has := n.unevaluated_properties.?; has {
		seen := make(map[rules.Node_Index]bool, 16, scratch)
		st := Static_Set{static = true, names = make([dynamic]string, scratch), patterns = make([dynamic]string, scratch)}
		saved_up := n.unevaluated_properties
		n.unevaluated_properties = nil
		static_set(b, d, node, &seen, &st)
		n.unevaluated_properties = saved_up
		if st.static {
			if st.all_members {
				n.unevaluated_properties = nil
			} else if len(st.patterns) == 0 && len(n.all_of) == 0 && n.ref == nil {
				if n.object < 0 {
					idx := i32(len(d.objects))
					append(&d.objects, rules.Object{additional = up, keys = rules.NONE})
					n.object = idx
					b.unevaluated[{0, idx}] = true
					n.unevaluated_properties = nil
				} else if d.objects[n.object].additional == rules.NONE && len(d.objects[n.object].patterns) == 0 {
					// Clone a fresh Object entry so sibling nodes sharing `n.object` are never mutated!
					cp := d.objects[n.object]
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
		seen := make(map[rules.Node_Index]bool, 16, scratch)
		st := Static_Set{static = true, names = make([dynamic]string, scratch), patterns = make([dynamic]string, scratch)}
		saved_ui := n.unevaluated_items
		n.unevaluated_items = nil
		static_set(b, d, node, &seen, &st)
		n.unevaluated_items = saved_ui
		if st.static {
			if st.all_items {
				n.unevaluated_items = nil
			} else if len(n.all_of) == 0 && n.ref == nil {
				if n.array < 0 {
					idx := i32(len(d.arrays))
					append(&d.arrays, rules.Array{items = ui})
					n.array = idx
					b.unevaluated[{1, idx}] = true
					n.unevaluated_items = nil
				} else if d.arrays[n.array].items == rules.NONE {
					// Clone a fresh Array entry so sibling nodes sharing `n.array` are never mutated!
					cp := d.arrays[n.array]
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
// and distinguishes `clear_own_uneval` cache keys so sibling `unevaluatedProperties`/`unevaluatedItems`
// never alias each other (B-C7).
@(private)
evaluates :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, skip_own_uneval := false) -> ^Evaluates {
	if node == rules.NONE {
		return nil
	}
	key := block_key(typeid_of(Evaluates), i32(node) * 2 + (1 if skip_own_uneval else 0), b.scope)
	if cached, ok := b.evaluated[key]; ok {
		return cached
	}
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
	ev.names = names[:]
	ev.patterns = patterns[:]
	ev.refs = refs[:]
	ev.inner = inners[:]
	return ev
}

@(private = "file")
collect_evaluates :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, skip_own_uneval: bool, ev: ^Evaluates, names: ^[dynamic]string, patterns: ^[dynamic]^regex.Regex, refs: ^[dynamic]^Evaluates, inners: ^[dynamic]Inner) {
	if node == rules.NONE {
		return
	}
	n := &d.nodes[node]
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if len(a.prefix) > ev.items {
			ev.items = len(a.prefix)
		}
		if a.items != rules.NONE {
			ev.all_items = true
		}
		if c, has := a.contains.?; has && a.evaluates_contains {
			rec := arm_record(b, d, arena, c, nil)
			append(inners, Inner{
				kind = .Contains,
				body = rec,
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
			if rerr.kind == .None && !slice.contains(patterns[:], re) {
				append(patterns, re)
			}
		}
		if o.additional != rules.NONE {
			ev.all_members = true
		}
		for dep in o.dependents {
			if dn, has := dep.node.?; has {
				rec := arm_record(b, d, arena, dn, nil)
				sub := evaluates(b, d, arena, dn)
				append(inners, Inner{kind = .Dependent, name = clone_str(b, arena, dep.name), body = rec, body_eval = sub})
			}
		}
	}
	if !skip_own_uneval {
		if n.unevaluated_items != nil {
			ev.all_items = true
		}
		if n.unevaluated_properties != nil {
			ev.all_members = true
		}
	}
	if r, has := n.ref.?; has {
		saved := b.scope
		enter_scope(b, d, arena, r)
		sub := evaluates(b, d, arena, r)
		b.scope = saved
		if sub != nil {
			append(refs, sub)
		}
	}
	if dr, has := n.dynamic_ref.?; has {
		target := dynamic_target(b, d, n, dr)
		saved := b.scope
		enter_scope(b, d, arena, target)
		sub := evaluates(b, d, arena, target)
		b.scope = saved
		if sub != nil {
			append(refs, sub)
		}
	}
	for a in n.all_of {
		if sub := evaluates(b, d, arena, a); sub != nil {
			append(refs, sub)
		}
	}
	if len(n.any_of) > 0 {
		arms, aerr := make([]i32, len(n.any_of), arena)
		evals, eerr := make([]^Evaluates, len(n.any_of), arena)
		if aerr != nil || eerr != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		for a, i in n.any_of {
			arms[i] = arm_record(b, d, arena, a, nil)
			evals[i] = evaluates(b, d, arena, a)
		}
		append(inners, Inner{kind = .Any, arms = arms, evals = evals})
	}
	if len(n.one_of) > 0 {
		arms, aerr := make([]i32, len(n.one_of), arena)
		evals, eerr := make([]^Evaluates, len(n.one_of), arena)
		if aerr != nil || eerr != nil {
			refuse_plan(b, .No_Memory)
			return
		}
		for a, i in n.one_of {
			arms[i] = arm_record(b, d, arena, a, nil)
			evals[i] = evaluates(b, d, arena, a)
		}
		append(inners, Inner{kind = .One, arms = arms, evals = evals})
	}
	if test, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
		inn := Inner{
			kind = .If,
			test = arm_record(b, d, arena, test, nil),
			test_eval = evaluates(b, d, arena, test),
		}
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
