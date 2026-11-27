// Iterative tandem walker over two `rules.Description`s emitting structured `Change` entries.
// Zero native recursion (safe on 10k-deep schemas in 1 MiB stack), zero `core:mem/virtual`, WASM-clean.
package schema

import "base:runtime"
import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private = "file")
Walk_Op_Kind :: enum u8 { Visit, Push_Step, Pop_Step, Unvisit }

@(private = "file")
Walk_Op :: struct {
	kind:    Walk_Op_Kind,
	x, y:    rules.Node_Index,
	step:    tape.Step,
	via:     string,
	has_via: bool,
}

@(private = "file")
Walk :: struct {
	old, new:  ^Side,
	forward:   Prover,
	backward:  Prover,
	out:       [dynamic]Change,
	path:      [dynamic]tape.Step,
	visited:   map[[2]rules.Node_Index]struct{},
	ops:       [dynamic]Walk_Op,
	allocator: runtime.Allocator,
	scratch:   runtime.Allocator,
	steps:     int,
	truncated: bool,
	via:       [dynamic]string,
}

@(private = "file")
MAX_WALK :: 20_000

@(private)
changes_of :: proc(old, new: ^Side, allocator, scratch, backing: runtime.Allocator) -> ([]Change, bool) {
	w := Walk {
		old       = old,
		new       = new,
		forward   = prover_of(old, new, scratch, backing),
		backward  = prover_of(new, old, scratch, backing),
		out       = make([dynamic]Change, allocator),
		visited   = make(map[[2]rules.Node_Index]struct{}, 32, scratch),
		path      = make([dynamic]tape.Step, scratch),
		via       = make([dynamic]string, scratch),
		ops       = make([dynamic]Walk_Op, 0, 32, scratch),
		allocator = allocator,
		scratch   = scratch,
	}
	defer {
		prover_destroy(&w.forward)
		prover_destroy(&w.backward)
	}
	append(&w.ops, Walk_Op{kind = .Visit, x = old.d.root, y = new.d.root})
	for len(w.ops) > 0 {
		op := pop(&w.ops)
		switch op.kind {
		case .Push_Step:
			append(&w.path, op.step)
			if op.has_via { append(&w.via, op.via) }
		case .Pop_Step:
			if op.has_via { pop(&w.via) }
			pop(&w.path)
		case .Unvisit:
			delete_key(&w.visited, [2]rules.Node_Index{op.x, op.y})
		case .Visit:
			visit_nodes(&w, op.x, op.y)
		}
	}
	return w.out[:], w.truncated || w.forward.exhausted || w.backward.exhausted
}

@(private = "file")
emit :: proc(w: ^Walk, keyword, old, new: string, effect: Effect) {
	ov: Maybe(rules.Value) = rules.Value(strings.clone(old, w.allocator)) if old != "" else nil
	nv: Maybe(rules.Value) = rules.Value(strings.clone(new, w.allocator)) if new != "" else nil
	emit_values(w, keyword, ov, nv, effect)
}

@(private = "file")
emit_numbers :: proc(w: ^Walk, keyword, old, new: string, effect: Effect) {
	ov: Maybe(rules.Value) = rules.Value(rules.Number_Text{text = strings.clone(old, w.allocator)}) if old != "" else nil
	nv: Maybe(rules.Value) = rules.Value(rules.Number_Text{text = strings.clone(new, w.allocator)}) if new != "" else nil
	emit_values(w, keyword, ov, nv, effect)
}

@(private = "file")
emit_values :: proc(w: ^Walk, keyword: string, old, new: Maybe(rules.Value), effect: Effect) {
	told := Effect.Unknown if w.forward.exhausted || w.backward.exhausted else effect
	named := keyword
	if len(w.via) > 0 {
		named = strings.join({strings.join(w.via[:], "/", w.scratch), keyword}, "/", w.scratch)
	}
	append(&w.out, Change{path = steps_clone(w.path[:], w.allocator), keyword = strings.clone(named, w.allocator), old = old, new = new, effect = told})
}

@(private = "file")
relation :: proc(w: ^Walk, x, y: []rules.Node_Index) -> Effect {
	widens := included(&w.forward, x, y, 0)
	narrows := included(&w.backward, y, x, 0)
	if widens && narrows { return .None }
	if widens { return .Widens }
	if narrows { return .Narrows }
	return .Unknown
}

@(private = "file")
queue_step :: proc(w: ^Walk, step: tape.Step, x, y: rules.Node_Index, via := "") {
	has_via := via != ""
	append(&w.ops, Walk_Op{kind = .Push_Step, step = step, via = via, has_via = has_via})
	append(&w.ops, Walk_Op{kind = .Visit, x = x, y = y})
	append(&w.ops, Walk_Op{kind = .Pop_Step, has_via = has_via})
}

@(private = "file")
visit_nodes :: proc(w: ^Walk, x, y: rules.Node_Index) {
	if x == rules.NONE || y == rules.NONE {
		if x != y {
			emit(w, "schema", "any" if x == rules.NONE else "restricted", "any" if y == rules.NONE else "restricted", relation(w, nodes_or_none(x, w.scratch), nodes_or_none(y, w.scratch)))
		}
		return
	}
	w.steps += 1
	if w.steps > MAX_WALK {
		w.truncated = true
		return
	}
	pair := [2]rules.Node_Index{x, y}
	if pair in w.visited || len(w.path) > MAX_DEPTH || same_node(&w.forward, x, y) {
		return
	}
	w.visited[pair] = {}
	append(&w.ops, Walk_Op{kind = .Unvisit, x = x, y = y})

	a, b := &w.old.d.nodes[x], &w.new.d.nodes[y]
	kinds_changed(w, a, b)
	rules_changed(w, a.rules, b.rules)
	enum_changed(w, a, b)

	mark := len(w.ops)
	arms_changed(w, "anyOf", a.any_of, b.any_of, .Narrows, .Widens)
	arms_changed(w, "allOf", a.all_of, b.all_of, .Widens, .Narrows)
	arms_changed(w, "oneOf", a.one_of, b.one_of, .Unknown, .Unknown)
	for s in ([?]struct { kw: string, a, b: Maybe(rules.Node_Index) }{
		{"$ref", a.ref, b.ref}, {"$dynamicRef", a.dynamic_ref, b.dynamic_ref},
		{"not", a.not, b.not}, {"if", a.cond.test, b.cond.test}, {"then", a.cond.then, b.cond.then}, {"else", a.cond.other, b.cond.other},
		{"unevaluatedItems", a.unevaluated_items, b.unevaluated_items}, {"unevaluatedProperties", a.unevaluated_properties, b.unevaluated_properties},
	}) {
		single_changed(w, s.kw, s.a, s.b)
	}
	array_changed(w, a.array, b.array)
	object_changed(w, a.object, b.object)
	slice.reverse(w.ops[mark:])
}

@(private = "file")
kinds_text :: proc(k: rules.Kinds, scratch: runtime.Allocator) -> string {
	names := make([dynamic]string, scratch)
	for t in TYPE_KINDS {
		if t.kinds <= k { append(&names, t.name) }
	}
	return strings.join(names[:], "|", scratch)
}

@(private = "file")
kinds_changed :: proc(w: ^Walk, a, b: ^rules.Node) {
	ka := a.kinds + ({.Integer} if .Number in a.kinds else {})
	kb := b.kinds + ({.Integer} if .Number in b.kinds else {})
	if ka == kb && a.integer_spelled == b.integer_spelled {
		return
	}
	effect := Effect.Both
	if ka < kb || (ka == kb && a.integer_spelled && !b.integer_spelled) {
		effect = .Widens
	} else if kb < ka || (ka == kb && b.integer_spelled && !a.integer_spelled) {
		effect = .Narrows
	}
	emit(w, "type", kinds_text(a.kinds, w.scratch), kinds_text(b.kinds, w.scratch), effect)
}

@(private = "file")
bound_changed :: proc(w: ^Walk, keyword, x, y: string, strict_x, strict_y, lower: bool) {
	if x == y && strict_x == strict_y { return }
	if x == "" { emit_numbers(w, keyword, "", y, .Narrows); return }
	if y == "" { emit_numbers(w, keyword, x, "", .Widens); return }
	if order := rules.tighter(y, x, strict_y, strict_x, lower); order != 0 {
		emit_numbers(w, keyword, x, y, .Narrows if order > 0 else .Widens)
	}
}

@(private = "file")
count_changed :: proc(w: ^Walk, keyword: string, x, y: u64) {
	if x != y {
		bx, by: [24]u8 = ---, ---
		emit_numbers(w, keyword, strconv.write_uint(bx[:], x, 10), strconv.write_uint(by[:], y, 10), .Narrows if y > x else .Widens)
	}
}

@(private = "file")
limit_changed :: proc(w: ^Walk, keyword: string, x, y: Maybe(u64)) {
	if x == y { return }
	bx, by: [24]u8 = ---, ---
	xs := strconv.write_uint(bx[:], x.?, 10) if x != nil else ""
	ys := strconv.write_uint(by[:], y.?, 10) if y != nil else ""
	effect: Effect = .Narrows if x == nil else (.Widens if y == nil else (.Narrows if y.? < x.? else .Widens))
	emit_numbers(w, keyword, xs, ys, effect)
}

@(private = "file")
text_changed :: proc(w: ^Walk, keyword, x, y: string, asserts := true) {
	if x == y { return }
	effect: Effect = .Narrows if x == "" else (.Widens if y == "" else .Unknown)
	emit(w, keyword, x, y, effect if asserts else .None)
}

@(private = "file")
rules_changed :: proc(w: ^Walk, x, y: rules.Rules) {
	bound_changed(w, "minimum", x.minimum, y.minimum, x.exclusive_minimum, y.exclusive_minimum, true)
	bound_changed(w, "maximum", x.maximum, y.maximum, x.exclusive_maximum, y.exclusive_maximum, false)
	if x.multiple_of != y.multiple_of && !(x.multiple_of != "" && y.multiple_of != "" && rules.decimal_compare(rules.decimal_of(x.multiple_of), rules.decimal_of(y.multiple_of)) == 0) {
		effect := Effect.Unknown
		if x.multiple_of == "" {
			effect = .Narrows
		} else if y.multiple_of == "" {
			effect = .Widens
		} else if m, exact := rules.decimal_multiple_of(rules.decimal_of(y.multiple_of), rules.decimal_of(x.multiple_of)); exact && m {
			effect = .Narrows
		} else if m2, exact2 := rules.decimal_multiple_of(rules.decimal_of(x.multiple_of), rules.decimal_of(y.multiple_of)); exact2 && m2 {
			effect = .Widens
		}
		emit_numbers(w, "multipleOf", x.multiple_of, y.multiple_of, effect)
	}
	count_changed(w, "minLength", x.min_length, y.min_length)
	limit_changed(w, "maxLength", x.max_length, y.max_length)
	text_changed(w, "pattern", x.pattern, y.pattern)
	text_changed(w, "format", x.format, y.format, x.assert_format || y.assert_format)
	count_changed(w, "minItems", x.min_items, y.min_items)
	limit_changed(w, "maxItems", x.max_items, y.max_items)
	count_changed(w, "minProperties", x.min_members, y.min_members)
	limit_changed(w, "maxProperties", x.max_members, y.max_members)
	if x.unique != y.unique {
		emit_values(w, "uniqueItems", rules.Value(x.unique), rules.Value(y.unique), .Narrows if y.unique else .Widens)
	}
}

@(private = "file")
enum_changed :: proc(w: ^Walk, a, b: ^rules.Node) {
	if a.has_enum != b.has_enum {
		emit(w, "enum", "set" if a.has_enum else "", "set" if b.has_enum else "", .Narrows if b.has_enum else .Widens)
	} else if a.has_enum {
		in_a := value_index(a.enum_of, w.scratch)
		in_b := value_index(b.enum_of, w.scratch)
		for v in a.enum_of {
			if !has_value(in_b, v, w.scratch) { emit_values(w, "enum", v, nil, .Narrows) }
		}
		for v in b.enum_of {
			if !has_value(in_a, v, w.scratch) { emit_values(w, "enum", nil, v, .Widens) }
		}
	}
	x, y := a.const_of, b.const_of
	same := false
	if x != nil && y != nil {
		eq, err := rules.value_equal(x.?, y.?, .Last, w.scratch)
		same = err == nil && eq
	}
	if (x == nil) != (y == nil) || (x != nil && !same) {
		emit_values(w, "const", x, y, .Both if x != nil && y != nil else (.Narrows if y != nil else .Widens))
	}
}

@(private = "file")
value_index :: proc(vs: []rules.Value, scratch: runtime.Allocator) -> (index: map[u64][dynamic]rules.Value) {
	index = make(map[u64][dynamic]rules.Value, len(vs), scratch)
	for v in vs {
		h, _ := rules.value_hash(v, .Last, scratch)
		same := index[h]
		if same == nil { same = make([dynamic]rules.Value, scratch) }
		append(&same, v)
		index[h] = same
	}
	return
}

@(private = "file")
has_value :: proc(index: map[u64][dynamic]rules.Value, v: rules.Value, scratch: runtime.Allocator) -> bool {
	h, _ := rules.value_hash(v, .Last, scratch)
	for x in index[h] {
		if eq, err := rules.value_equal(x, v, .Last, scratch); err == nil && eq { return true }
	}
	return false
}

@(private = "file")
arms_changed :: proc(w: ^Walk, keyword: string, xs, ys: []rules.Node_Index, removed, added: Effect) {
	left := make([dynamic]rules.Node_Index, w.scratch)
	right := slice.clone_to_dynamic(ys, w.scratch)
	for x in xs {
		found := -1
		for y, i in right {
			if w.forward.exhausted { break }
			if same_node(&w.forward, x, y) { found = i; break }
		}
		if found >= 0 { ordered_remove(&right, found) } else { append(&left, x) }
	}
	for x, i in left {
		if i < len(right) {
			append(&w.ops, Walk_Op{kind = .Visit, x = x, y = right[i]})
		} else {
			emit(w, keyword, "arm", "", removed)
		}
	}
	for _ in len(left) ..< len(right) {
		emit(w, keyword, "", "arm", added)
	}
}

@(private = "file")
single_changed :: proc(w: ^Walk, keyword: string, x, y: Maybe(rules.Node_Index)) {
	if x == nil && y == nil { return }
	if x == nil || y == nil {
		effect := (.Narrows if x == nil else Effect.Widens) if keyword == "$ref" else Effect.Unknown
		emit(w, keyword, "" if x == nil else "set", "" if y == nil else "set", effect)
	} else if keyword == "$ref" {
		append(&w.ops, Walk_Op{kind = .Visit, x = x.?, y = y.?})
	} else if !same_node(&w.forward, x.?, y.?) {
		emit(w, keyword, "set", "set", .Unknown)
	}
}

@(private = "file")
array_changed :: proc(w: ^Walk, x, y: i32) {
	if x < 0 || y < 0 {
		if x != y { emit(w, "items", "shaped" if x >= 0 else "", "shaped" if y >= 0 else "", .Narrows if y >= 0 else .Widens) }
		return
	}
	a, b := &w.old.d.arrays[x], &w.new.d.arrays[y]
	for i in 0 ..< max(len(a.prefix), len(b.prefix)) {
		queue_step(w, tape.Index(i), a.prefix[i] if i < len(a.prefix) else a.items, b.prefix[i] if i < len(b.prefix) else b.items)
	}
	queue_step(w, tape.All{}, a.items, b.items)
	if (a.contains == nil) != (b.contains == nil) {
		emit(w, "contains", "" if a.contains == nil else "set", "" if b.contains == nil else "set", .Narrows if a.contains == nil else .Widens)
	} else if a.contains != nil {
		queue_step(w, tape.All{}, a.contains.?, b.contains.?, "contains")
	}
	if a.min_contains != b.min_contains {
		ba, bb: [24]u8 = ---, ---
		emit_numbers(w, "minContains", strconv.write_uint(ba[:], a.min_contains.? or_else 1, 10), strconv.write_uint(bb[:], b.min_contains.? or_else 1, 10), .Unknown)
	}
	limit_changed(w, "maxContains", a.max_contains, b.max_contains)
}

@(private = "file")
object_changed :: proc(w: ^Walk, x, y: i32) {
	if x < 0 || y < 0 {
		if x != y { emit(w, "properties", "shaped" if x >= 0 else "", "shaped" if y >= 0 else "", .Narrows if y >= 0 else .Widens) }
		return
	}
	a, b := &w.old.d.objects[x], &w.new.d.objects[y]
	in_a := member_names(a.members, w.scratch)
	in_b := member_names(b.members, w.scratch)
	for m in a.members {
		append(&w.path, tape.Name(m.name))
		if k := first_named(&in_b, m.name); k >= 0 {
			n := b.members[k]
			if m.required != n.required {
				emit(w, "required", "required" if m.required else "optional", "required" if n.required else "optional", .Narrows if n.required else .Widens)
			}
			rules_changed(w, m.rules, n.rules)
			pop(&w.path)
			queue_step(w, tape.Name(m.name), m.node, n.node)
		} else {
			effect := relation(w, nodes_or_none(m.node if !m.only_required else a.additional, w.scratch), nodes_or_none(b.additional, w.scratch)) if len(b.patterns) == 0 else Effect.Unknown
			emit(w, "properties", "defined", "", effect)
			if m.required { emit(w, "required", "required", "", .Widens) }
			pop(&w.path)
		}
	}
	for n in b.members {
		if first_named(&in_a, n.name) < 0 {
			append(&w.path, tape.Name(n.name))
			effect := relation(w, nodes_or_none(a.additional, w.scratch), nodes_or_none(n.node if !n.only_required else b.additional, w.scratch)) if len(a.patterns) == 0 else Effect.Unknown
			emit(w, "properties", "", "defined", effect)
			if n.required { emit(w, "required", "", "required", .Narrows) }
			pop(&w.path)
		}
	}
	queue_step(w, tape.All{}, a.additional, b.additional, "additionalProperties")
	if a.keys != b.keys {
		emit(w, "propertyNames", "set" if a.keys != rules.NONE else "", "set" if b.keys != rules.NONE else "", relation(w, nodes_or_none(a.keys, w.scratch), nodes_or_none(b.keys, w.scratch)))
	}
	ba, bb: [24]u8 = ---, ---
	if len(a.patterns) + len(b.patterns) > 0 && !same_object(&w.forward, a, b) {
		emit_numbers(w, "patternProperties", strconv.write_int(ba[:], i64(len(a.patterns)), 10), strconv.write_int(bb[:], i64(len(b.patterns)), 10), .Unknown)
	}
	if len(a.dependents) + len(b.dependents) > 0 && !same_object(&w.forward, a, b) {
		a_req, b_req, a_sch, b_sch := 0, 0, 0, 0
		for d in a.dependents { if d.node != nil { a_sch += 1 } else { a_req += 1 } }
		for d in b.dependents { if d.node != nil { b_sch += 1 } else { b_req += 1 } }
		if a_req + b_req > 0 { emit_numbers(w, "dependentRequired", strconv.write_int(ba[:], i64(a_req), 10), strconv.write_int(bb[:], i64(b_req), 10), .Unknown) }
		if a_sch + b_sch > 0 { emit_numbers(w, "dependentSchemas", strconv.write_int(ba[:], i64(a_sch), 10), strconv.write_int(bb[:], i64(b_sch), 10), .Unknown) }
	}
}
