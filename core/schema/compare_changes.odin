package schema

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"
import "../spell"
import core "../"
import "../rules"

// The changes between two descriptions, found by walking the two together from their roots by place in a value. A
// change names the part of the schema that differs, and its effect on the values taken is what that part alone does.

@(private = "file")
Walk :: struct {
	old, new:  ^Side,
	forward:   Prover,
	backward:  Prover,
	out:       [dynamic]Change,
	path:      [dynamic]core.Step,
	visited:   map[[2]rules.Node_Index]struct{},
	allocator: mem.Allocator,
	steps:     int,
	// The open `walk_nodes` calls, which a chain of references would carry to the stack's end.
	nested:    int,
	truncated: bool,
	// The applicators the walk is inside that the place does not name, as `additionalProperties`, which prefix a keyword.
	via:       [dynamic]string,
}

// The node pairs one walk visits at most. A schema whose references fan out would otherwise be walked once per path.
@(private = "file")
MAX_WALK :: 20_000

@(private)
changes_of :: proc(old, new: ^Side, allocator: mem.Allocator) -> (changes: []Change, truncated: bool) {
	w := Walk {
		old       = old,
		new       = new,
		forward   = {from = old, to = new, running = make(map[string]struct{}, context.temp_allocator)},
		backward  = {from = new, to = old, running = make(map[string]struct{}, context.temp_allocator)},
		out       = make([dynamic]Change, allocator),
		visited   = make(map[[2]rules.Node_Index]struct{}, context.temp_allocator),
		path      = make([dynamic]core.Step, context.temp_allocator),
		via       = make([dynamic]string, context.temp_allocator),
		allocator = allocator,
	}
	walk_nodes(&w, old.d.root, new.d.root)
	return w.out[:], w.truncated || w.forward.exhausted || w.backward.exhausted
}

@(private = "file")
emit :: proc(w: ^Walk, keyword: string, old, new: string, effect: Effect) {
	told := Effect.Unknown if w.forward.exhausted || w.backward.exhausted else effect
	named := keyword
	if len(w.via) > 0 {
		named = strings.join({strings.join(w.via[:], "/", context.temp_allocator), keyword}, "/", context.temp_allocator)
	}
	append(&w.out, Change{path = core.steps_clone(w.path[:], w.allocator), keyword = strings.clone(named, w.allocator), old = strings.clone(old, w.allocator), new = strings.clone(new, w.allocator), effect = told})
}

// What replacing the conjunction `x` of the old description by `y` of the new one does to the values taken.
@(private = "file")
relation :: proc(w: ^Walk, x, y: []rules.Node_Index) -> Effect {
	widens := included(&w.forward, x, y, 0)
	narrows := included(&w.backward, y, x, 0)
	switch {
	case widens && narrows:
		return .None
	case widens:
		return .Widens
	case narrows:
		return .Narrows
	}
	return .Unknown
}

// Walks the nodes `x` of the old description and `y` of the new one, which stand at the same place.
@(private = "file")
walk_nodes :: proc(w: ^Walk, x, y: rules.Node_Index) {
	if x == rules.NONE || y == rules.NONE {
		if x != y {
			emit(w, "schema", "any" if x == rules.NONE else "restricted", "any" if y == rules.NONE else "restricted", relation(w, nodes_or_none(x), nodes_or_none(y)))
		}
		return
	}
	w.steps += 1
	if w.steps > MAX_WALK {
		w.truncated = true
		return
	}
	if w.nested >= MAX_SAME_NESTING {
		w.truncated = true
		return
	}
	w.nested += 1
	defer w.nested -= 1
	pair := [2]rules.Node_Index{x, y}
	if pair in w.visited || len(w.path) > MAX_DEPTH || same_node(&w.forward, x, y) {
		return
	}
	w.visited[pair] = {}
	defer delete_key(&w.visited, pair)
	a, b := &w.old.d.nodes[x], &w.new.d.nodes[y]
	kinds_changed(w, a, b)
	rules_changed(w, a.rules, b.rules)
	enum_changed(w, a, b)
	arms_changed(w, "anyOf", a.any_of, b.any_of, .Narrows, .Widens)
	arms_changed(w, "allOf", a.all_of, b.all_of, .Widens, .Narrows)
	arms_changed(w, "oneOf", a.one_of, b.one_of, .Unknown, .Unknown)
	single_changed(w, "$ref", a.ref, b.ref)
	single_changed(w, "$dynamicRef", a.dynamic_ref, b.dynamic_ref)
	single_changed(w, "not", a.not, b.not)
	single_changed(w, "if", a.cond.test, b.cond.test)
	single_changed(w, "then", a.cond.then, b.cond.then)
	single_changed(w, "else", a.cond.other, b.cond.other)
	single_changed(w, "unevaluatedItems", a.unevaluated_items, b.unevaluated_items)
	single_changed(w, "unevaluatedProperties", a.unevaluated_properties, b.unevaluated_properties)
	array_changed(w, a.array, b.array)
	object_changed(w, a.object, b.object)
}

@(private = "file")
kinds_text :: proc(k: rules.Kinds) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for kind in k {
		append(&names, "boolean" if kind == .Bool else strings.to_lower(fmt.tprint(kind), context.temp_allocator))
	}
	return strings.join(names[:], "|", context.temp_allocator)
}

@(private = "file")
kinds_changed :: proc(w: ^Walk, a, b: ^rules.Node) {
	ka, kb := a.kinds + ({.Integer} if .Number in a.kinds else {}), b.kinds + ({.Integer} if .Number in b.kinds else {})
	if ka == kb && a.integer_spelled == b.integer_spelled {
		return
	}
	effect := Effect.Both
	switch {
	case ka < kb || ka == kb && a.integer_spelled && !b.integer_spelled:
		effect = .Widens
	case kb < ka || ka == kb && b.integer_spelled && !a.integer_spelled:
		effect = .Narrows
	}
	emit(w, "type", kinds_text(a.kinds), kinds_text(b.kinds), effect)
}

// A bound moving from `x` to `y`, as a lower limit or an upper one, tightens the values taken or loosens them.
@(private = "file")
bound_changed :: proc(w: ^Walk, keyword: string, x, y: string, strict_x, strict_y, lower: bool) {
	switch {
	case x == y && strict_x == strict_y:
	case x == "":
		emit(w, keyword, "", y, .Narrows)
	case y == "":
		emit(w, keyword, x, "", .Widens)
	case:
		effect := Effect.Unknown
		switch order := rules.tighter(y, x, strict_y, strict_x, lower); {
		case order > 0:
			effect = .Narrows
		case order < 0:
			effect = .Widens
		}
		emit(w, keyword, x, y, effect)
	}
}

@(private = "file")
count_changed :: proc(w: ^Walk, keyword: string, x, y: u64, lower: bool) {
	if x != y {
		emit(w, keyword, fmt.tprint(x), fmt.tprint(y), .Narrows if (y > x) == lower else .Widens)
	}
}

@(private = "file")
limit_changed :: proc(w: ^Walk, keyword: string, x, y: Maybe(u64)) {
	switch {
	case x == y:
	case x == nil:
		emit(w, keyword, "", fmt.tprint(y.?), .Narrows)
	case y == nil:
		emit(w, keyword, fmt.tprint(x.?), "", .Widens)
	case:
		emit(w, keyword, fmt.tprint(x.?), fmt.tprint(y.?), .Narrows if y.? < x.? else .Widens)
	}
}

@(private = "file")
text_changed :: proc(w: ^Walk, keyword: string, x, y: string, asserts := true) {
	effect := Effect.Unknown
	switch {
	case x == y:
		return
	case x == "":
		effect = .Narrows
	case y == "":
		effect = .Widens
	}
	emit(w, keyword, x, y, effect if asserts else .None)
}

@(private = "file")
rules_changed :: proc(w: ^Walk, x, y: rules.Rules) {
	bound_changed(w, "minimum", x.minimum, y.minimum, x.exclusive_minimum, y.exclusive_minimum, true)
	bound_changed(w, "maximum", x.maximum, y.maximum, x.exclusive_maximum, y.exclusive_maximum, false)
	if x.multiple_of != y.multiple_of {
		effect := Effect.Unknown
		switch {
		case x.multiple_of == "":
			effect = .Narrows
		case y.multiple_of == "":
			effect = .Widens
		case:
			if m, exact := spell.decimal_multiple_of(spell.decimal_of(y.multiple_of), spell.decimal_of(x.multiple_of)); exact && m {
				effect = .Narrows
			} else if m, exact = spell.decimal_multiple_of(spell.decimal_of(x.multiple_of), spell.decimal_of(y.multiple_of)); exact && m {
				effect = .Widens
			}
		}
		emit(w, "multipleOf", x.multiple_of, y.multiple_of, effect)
	}
	count_changed(w, "minLength", x.min_length, y.min_length, true)
	limit_changed(w, "maxLength", x.max_length, y.max_length)
	text_changed(w, "pattern", x.pattern, y.pattern)
	text_changed(w, "format", x.format, y.format, x.assert_format || y.assert_format)
	count_changed(w, "minItems", x.min_items, y.min_items, true)
	limit_changed(w, "maxItems", x.max_items, y.max_items)
	count_changed(w, "minProperties", x.min_members, y.min_members, true)
	limit_changed(w, "maxProperties", x.max_members, y.max_members)
	if x.unique != y.unique {
		emit(w, "uniqueItems", fmt.tprint(x.unique), fmt.tprint(y.unique), .Narrows if y.unique else .Widens)
	}
}

@(private = "file")
value_text :: proc(w: ^Walk, v: core.Value) -> string {
	text, ok := text_of(w.old, v)
	return string(text) if ok else "?"
}

@(private = "file")
enum_changed :: proc(w: ^Walk, a, b: ^rules.Node) {
	if a.has_enum != b.has_enum {
		emit(w, "enum", "set" if a.has_enum else "", "set" if b.has_enum else "", .Narrows if b.has_enum else .Widens)
	} else {
		in_a, in_b := value_index(a.enum_of), value_index(b.enum_of)
		for v in a.enum_of {
			if !has_value(in_b, v) {
				emit(w, "enum", value_text(w, v), "", .Narrows)
			}
		}
		for v in b.enum_of {
			if !has_value(in_a, v) {
				emit(w, "enum", "", value_text(w, v), .Widens)
			}
		}
	}
	x, y := a.const_of, b.const_of
	if (x == nil) != (y == nil) || x != nil && !core.equal(x.?, y.?) {
		emit(w, "const", "" if x == nil else value_text(w, x.?), "" if y == nil else value_text(w, y.?), .Both if x != nil && y != nil else (.Narrows if y != nil else .Widens))
	}
}

@(private = "file")
value_index :: proc(vs: []core.Value) -> (index: map[u64][dynamic]core.Value) {
	index = make(map[u64][dynamic]core.Value, len(vs), context.temp_allocator)
	for v in vs {
		h := core.hash(v)
		same := index[h]
		if same == nil {
			same = make([dynamic]core.Value, context.temp_allocator)
		}
		append(&same, v)
		index[h] = same
	}
	return
}

@(private = "file")
has_value :: proc(index: map[u64][dynamic]core.Value, v: core.Value) -> bool {
	for x in index[core.hash(v)] {
		if core.equal(x, v) {
			return true
		}
	}
	return false
}

// The arms of an applicator: those that are in only one description are added or removed, with `removed` the effect of
// a removal and `added` of an addition, and the ones left over on both sides stand at the same place and are walked.
@(private = "file")
arms_changed :: proc(w: ^Walk, keyword: string, xs, ys: []rules.Node_Index, removed, added: Effect) {
	left, right := make([dynamic]rules.Node_Index, context.temp_allocator), slice.clone_to_dynamic(ys, context.temp_allocator)
	for x in xs {
		found := -1
		for y, i in right {
			if same_node(&w.forward, x, y) {
				found = i
				break
			}
		}
		if found >= 0 {
			ordered_remove(&right, found)
		} else {
			append(&left, x)
		}
	}
	for x, i in left {
		if i < len(right) {
			walk_nodes(w, x, right[i])
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
	switch {
	case x == nil && y == nil:
	case x == nil || y == nil:
		effect := Effect.Unknown
		if keyword == "$ref" {
			effect = .Narrows if x == nil else .Widens
		}
		emit(w, keyword, "" if x == nil else "set", "" if y == nil else "set", effect)
	case keyword == "$ref":
		walk_nodes(w, x.?, y.?)
	case:
		if !same_node(&w.forward, x.?, y.?) {
			emit(w, keyword, "set", "set", .Unknown)
		}
	}
}

@(private = "file")
step_into :: proc(w: ^Walk, step: core.Step, x, y: rules.Node_Index, via := "") {
	append(&w.path, step)
	if via != "" {
		append(&w.via, via)
	}
	walk_nodes(w, x, y)
	if via != "" {
		pop(&w.via)
	}
	pop(&w.path)
}

@(private = "file")
array_changed :: proc(w: ^Walk, x, y: i32) {
	if x < 0 || y < 0 {
		if x != y {
			emit(w, "items", "shaped" if x >= 0 else "", "shaped" if y >= 0 else "", .Narrows if y >= 0 else .Widens)
		}
		return
	}
	a, b := &w.old.d.arrays[x], &w.new.d.arrays[y]
	for i in 0 ..< max(len(a.prefix), len(b.prefix)) {
		left := a.prefix[i] if i < len(a.prefix) else a.items
		right := b.prefix[i] if i < len(b.prefix) else b.items
		step_into(w, core.Index(i), left, right)
	}
	step_into(w, core.All{}, a.items, b.items)
	switch {
	case a.contains == nil && b.contains == nil:
	case a.contains == nil || b.contains == nil:
		emit(w, "contains", "" if a.contains == nil else "set", "" if b.contains == nil else "set", .Narrows if a.contains == nil else .Widens)
	case:
		step_into(w, core.All{}, a.contains.?, b.contains.?, "contains")
	}
	if a.min_contains != b.min_contains {
		emit(w, "minContains", fmt.tprint(a.min_contains.? or_else 1), fmt.tprint(b.min_contains.? or_else 1), .Unknown)
	}
	limit_changed(w, "maxContains", a.max_contains, b.max_contains)
}

@(private = "file")
object_changed :: proc(w: ^Walk, x, y: i32) {
	if x < 0 || y < 0 {
		if x != y {
			emit(w, "properties", "shaped" if x >= 0 else "", "shaped" if y >= 0 else "", .Narrows if y >= 0 else .Widens)
		}
		return
	}
	a, b := &w.old.d.objects[x], &w.new.d.objects[y]
	for m in a.members {
		if n, found := find_member(b, m.name); found {
			member_changed(w, m, n)
		} else {
			append(&w.path, core.Name(m.name))
			// A pattern may describe the name, which the comparison cannot tell without matching it.
			effect := relation(w, nodes_or_none(m.node if !m.only_required else a.additional), nodes_or_none(b.additional)) if len(b.patterns) == 0 else Effect.Unknown
			emit(w, "properties", "defined", "", effect)
			if m.required {
				emit(w, "required", "required", "", .Widens)
			}
			pop(&w.path)
		}
	}
	for n in b.members {
		if _, found := find_member(a, n.name); !found {
			append(&w.path, core.Name(n.name))
			effect := relation(w, nodes_or_none(a.additional), nodes_or_none(n.node if !n.only_required else b.additional)) if len(a.patterns) == 0 else Effect.Unknown
			emit(w, "properties", "", "defined", effect)
			if n.required {
				emit(w, "required", "", "required", .Narrows)
			}
			pop(&w.path)
		}
	}
	step_into(w, core.All{}, a.additional, b.additional, "additionalProperties")
	if a.keys != b.keys {
		emit(w, "propertyNames", "set" if a.keys != rules.NONE else "", "set" if b.keys != rules.NONE else "", relation(w, nodes_or_none(a.keys), nodes_or_none(b.keys)))
	}
	if len(a.patterns) + len(b.patterns) > 0 && !same_object(&w.forward, a, b) {
		emit(w, "patternProperties", fmt.tprint(len(a.patterns)), fmt.tprint(len(b.patterns)), .Unknown)
	}
	if len(a.dependents) + len(b.dependents) > 0 && !same_object(&w.forward, a, b) {
		emit(w, "dependentRequired", fmt.tprint(len(a.dependents)), fmt.tprint(len(b.dependents)), .Unknown)
	}
}

@(private = "file")
find_member :: proc(o: ^rules.Object, name: string) -> (m: rules.Member, found: bool) {
	for n in o.members {
		if n.name == name {
			return n, true
		}
	}
	return
}

@(private = "file")
member_changed :: proc(w: ^Walk, a, b: rules.Member) {
	append(&w.path, core.Name(a.name))
	defer pop(&w.path)
	if a.required != b.required {
		emit(w, "required", "required" if a.required else "optional", "required" if b.required else "optional", .Narrows if b.required else .Widens)
	}
	if a.rules != b.rules {
		rules_changed(w, a.rules, b.rules)
	}
	walk_nodes(w, a.node, b.node)
}
