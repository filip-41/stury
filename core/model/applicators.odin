package model

import "base:runtime"
import "core:slice"
import "core:mem/virtual"
import "core:strings"
import core ".."
import rules "../rules"
import typed "../typed"

// A JSON Schema fragment that every value of `type` passes beside what the type reads, in the registry's copy.
@(private)
Schema_Of :: struct {
	type:     typeid,
	fragment: rules.Description,
}

// Adds the JSON Schema `fragment` to the rules of `T`, beside those added before: a load reads a value of `T` and then
// judges its text by the fragment, `validate` judges the text a write of the value gives by it, and `schema` writes it
// in the `allOf` of `T`'s node. The registry keeps a copy of `fragment` and what it borrows. A fragment on a type of a
// format that holds no value alone, a table's, is refused by `compile` as `.Unsupported`, and so is one with
// `patternProperties` on a struct whose `extra` map reads its values as a type other than `core.Value`, since the map
// would judge a member the pattern names by the map's type, which the fragment does not say.
register_schema :: proc(reg: ^Registry, T: typeid, fragment: ^rules.Description) -> runtime.Allocator_Error {
	x := Schema_Of{type = T}
	x.fragment.allocator = virtual.arena_allocator(&reg.loads.constants)
	if _, err := graft(&x.fragment, fragment, true); err != nil {
		return err
	}
	_, err := append(&reg.schemas, x)
	return err
}

// Copies the nodes and blocks of `from` into `into` past those it holds, and answers where `from`'s root went. The copy
// borrows what `from` borrows, unless `own` copies its texts and values with `into`'s allocator, which then is an arena,
// since a value built has no destructor.
@(private)
graft :: proc(into, from: ^rules.Description, own: bool) -> (root: rules.Node_Index, err: runtime.Allocator_Error) {
	context.allocator = into.allocator
	nodes, arrays, objects := rules.Node_Index(len(into.nodes)), i32(len(into.arrays)), i32(len(into.objects))
	at :: proc(i, by: rules.Node_Index) -> rules.Node_Index {
		return i if i == rules.NONE else i + by
	}
	maybe_at :: proc(i: Maybe(rules.Node_Index), by: rules.Node_Index) -> Maybe(rules.Node_Index) {
		x, has := i.?
		return x + by if has else nil
	}
	list_at :: proc(xs: []rules.Node_Index, by: rules.Node_Index) -> (out: []rules.Node_Index, err: runtime.Allocator_Error) {
		if len(xs) == 0 {
			return
		}
		out = make([]rules.Node_Index, len(xs)) or_return
		for x, i in xs {
			out[i] = at(x, by)
		}
		return
	}
	text :: proc(s: string, own: bool) -> string {
		if !own || s == "" {
			return s
		}
		return strings.clone(s) or_else ""
	}
	rules_of :: proc(r: rules.Rules, own: bool) -> rules.Rules {
		r := r
		for t in ([5]^string{&r.minimum, &r.maximum, &r.multiple_of, &r.pattern, &r.format}) {
			t^ = text(t^, own)
		}
		return r
	}
	values :: proc(xs: []core.Value, own: bool) -> (out: []core.Value, err: runtime.Allocator_Error) {
		if len(xs) == 0 {
			return
		}
		out = make([]core.Value, len(xs)) or_return
		for x, i in xs {
			out[i] = value_kept(x) if own else x
		}
		return
	}
	for n in from.nodes {
		x := n
		x.array = n.array + arrays if n.array >= 0 else -1
		x.object = n.object + objects if n.object >= 0 else -1
		x.any_of = list_at(n.any_of, nodes) or_return
		x.all_of = list_at(n.all_of, nodes) or_return
		x.one_of = list_at(n.one_of, nodes) or_return
		x.enum_of = values(n.enum_of, own) or_return
		x.examples = values(n.examples, own) or_return
		x.not, x.ref, x.dynamic_ref = maybe_at(n.not, nodes), maybe_at(n.ref, nodes), maybe_at(n.dynamic_ref, nodes)
		x.cond = {maybe_at(n.cond.test, nodes), maybe_at(n.cond.then, nodes), maybe_at(n.cond.other, nodes)}
		x.unevaluated_items, x.unevaluated_properties = maybe_at(n.unevaluated_items, nodes), maybe_at(n.unevaluated_properties, nodes)
		x.resource = at(n.resource, nodes)
		x.rules = rules_of(n.rules, own)
		x.description, x.title = text(n.description, own), text(n.title, own)
		x.content_encoding, x.content_media_type = text(n.content_encoding, own), text(n.content_media_type, own)
		if c, has := n.const_of.?; has && own {
			x.const_of = value_kept(c)
		}
		if d, has := n.default_of.?; has && own {
			x.default_of = value_kept(d)
		}
		append(&into.nodes, x) or_return
	}
	for a in from.arrays {
		x := a
		x.prefix = list_at(a.prefix, nodes) or_return
		x.items, x.contains = at(a.items, nodes), maybe_at(a.contains, nodes)
		append(&into.arrays, x) or_return
	}
	for o in from.objects {
		x := o
		x.additional, x.keys = at(o.additional, nodes), at(o.keys, nodes)
		x.members = make([]rules.Member, len(o.members)) or_return
		for m, i in o.members {
			x.members[i] = m
			x.members[i].name, x.members[i].node, x.members[i].rules = text(m.name, own), at(m.node, nodes), rules_of(m.rules, own)
		}
		x.patterns = make([]rules.Pattern, len(o.patterns)) or_return
		for p, i in o.patterns {
			x.patterns[i] = {text(p.expression, own), at(p.node, nodes)}
		}
		x.dependents = make([]rules.Dependent, len(o.dependents)) or_return
		for d, i in o.dependents {
			required := make([]string, len(d.required)) or_return
			for r, k in d.required {
				required[k] = text(r, own)
			}
			x.dependents[i] = {text(d.name, own), required, maybe_at(d.node, nodes)}
		}
		append(&into.objects, x) or_return
	}
	for a in from.anchors {
		append(&into.anchors, rules.Anchor{text(a.name, own), at(a.resource, nodes), at(a.node, nodes)}) or_return
	}
	if into.names == nil {
		into.names = make(map[rules.Node_Index]string)
	}
	for k, v in from.names {
		map_insert(&into.names, at(k, nodes), text(v, own)) or_return
	}
	return at(from.root, nodes), nil
}

// A copy of `v` built in the context allocator, with its texts, which outlives the document a node of it is in.
@(private)
value_kept :: proc(v: core.Value) -> core.Value {
	#partial switch x in v {
	case core.Node_Ref:
		return core.built_value(x, .All)
	case string:
		return strings.clone(x) or_else ""
	case ^core.Number_Text:
		return core.number_text(strings.clone(x.text) or_else "")
	case ^core.Array:
		out := core.new_array(len(x.items))
		for item in x.items {
			core.array_append(out, value_kept(item))
		}
		return out
	case ^core.Object:
		out := core.new_object()
		for k, i in x.keys {
			core.object_put(out, strings.clone(k) or_else "", value_kept(x.vals[i]))
		}
		return out
	}
	return v
}

// What a model judges past its read: the types that a fragment, `unique` or a `.One_Match` union judges, each with the
// check plan that judges its values' text, and the plan of each, which `validate` writes its values by and a
// `.One_Match` union's `oneOf` describes its arms by. It keeps its own copy of the fragments, which `schema` reads.
@(private)
Applied :: struct {
	schemas: []Schema_Of, // copies of the registry's, in `kept`
	unions:  []typeid, // the `.One_Match` unions
	judged:  [dynamic]^Judged,
	plans:   [dynamic]Own_Plan,
	kept:    virtual.Arena,
}

@(private)
Judged :: struct {
	type:   typeid,
	unique: bool,
	d:      rules.Description,
	plan:   typed.Plan,
}

@(private)
Own_Plan :: struct {
	type: typeid,
	plan: ^typed.Plan,
}

// The judging of the model whose plan is `whole`, nil when no value of it is judged past its read.
@(private)
judging_of :: proc(reg: ^Registry, whole: ^typed.Plan, reads: ^typed.Format_Reads, allocator: runtime.Allocator, layout: Maybe(core.As), hooks: []typed.Type_Hook) -> (j: ^Applied, err: core.Error) {
	if reg == nil {
		return
	}
	context.allocator = allocator
	unions := make([dynamic]typeid, context.temp_allocator)
	for x in reg.unions {
		if x.mode == .One_Match {
			append(&unions, x.type)
		}
	}
	probe := Applied{schemas = reg.schemas[:], unions = unions[:]}
	keys := judged_keys(&probe, whole, context.temp_allocator)
	if len(keys) == 0 {
		return
	}
	j = new(Applied) or_return
	defer if err != nil {
		judging_destroy(j)
		j = nil
	}
	j.judged.allocator, j.plans.allocator = allocator, allocator
	j.unions = slice.clone(unions[:]) or_return
	j.schemas = make([]Schema_Of, len(reg.schemas)) or_return
	for &x, i in reg.schemas {
		j.schemas[i].type = x.type
		j.schemas[i].fragment.allocator = virtual.arena_allocator(&j.kept)
		graft(&j.schemas[i].fragment, &x.fragment, true) or_return
	}
	for k in keys {
		if refused := pattern_beside_extra(j, whole, k.type); refused.kind != .None {
			return j, core.error_of(refused)
		}
		if own_plan(j, k.type) == nil {
			p := new(typed.Plan) or_return
			append(&j.plans, Own_Plan{k.type, p}) or_return
			p^ = plan_of(reg, k.type, reads, allocator, nil, nil, layout, hooks) or_return
		}
		x := new(Judged) or_return
		append(&j.judged, x) or_return
		x.type, x.unique = k.type, k.unique
		fragment(j, x, allocator) or_return
		x.plan = typed.plan_of(&x.d, whole.as, reads, {checking = true}, allocator) or_return
	}
	for &m in whole.meta {
		m.judged = m.type != nil && judged_of(j, m.type, m.rule_set > 0 && whole.rule_sets[m.rule_set - 1].unique) != nil
	}
	return
}

// Refuses a fragment with `patternProperties` on struct `type` of `whole` beside an `extra` map whose values a load
// reads as a type other than `core.Value`, since the map reads a member the pattern names as its own type, which the
// fragment's `patternProperties` does not judge.
@(private)
pattern_beside_extra :: proc(j: ^Applied, whole: ^typed.Plan, type: typeid) -> core.Typed_Refusal {
	value: typeid
	for m in whole.meta {
		if m.type == type && m.block >= 0 {
			if _, is_struct := runtime.type_info_base(type_info_of(type)).variant.(runtime.Type_Info_Struct); is_struct {
				if at := whole.meta[m.block + m.members].capture; at >= 0 {
					value = runtime.type_info_base(type_info_of(whole.meta[at].type)).variant.(runtime.Type_Info_Map).value.id
				}
			}
			break
		}
	}
	if value == nil || runtime.type_info_base(type_info_of(value)) == runtime.type_info_base(type_info_of(core.Value)) {
		return {}
	}
	for &x in j.schemas {
		if x.type != type {
			continue
		}
		ways, _ := rules.branches(&x.fragment, {x.fragment.root}, false, 64)
		for way in ways {
			for i in way {
				if o := x.fragment.nodes[i].object; o >= 0 && len(x.fragment.objects[o].patterns) > 0 {
					return {kind = .Unsupported, want = {type, "patternProperties"}}
				}
			}
		}
	}
	return {}
}

@(private)
Judged_Key :: struct {
	type:   typeid,
	unique: bool,
}

// The types of `plan`'s records that `j` judges, each with whether its rules say `unique`. A pointer or a `Maybe` whose
// rules say `unique` shares them with the list it holds, which alone is judged, so its value is judged once.
@(private)
judged_keys :: proc(j: ^Applied, plan: ^typed.Plan, allocator: runtime.Allocator) -> []Judged_Key {
	keys := make([dynamic]Judged_Key, allocator)
	for m in plan.meta {
		if m.type == nil {
			continue
		}
		k := Judged_Key{m.type, m.rule_set > 0 && plan.rule_sets[m.rule_set - 1].unique}
		if (k.unique && held(type_info_of(m.type)) == nil || judges(j, m.type)) && !slice.contains(keys[:], k) {
			append(&keys, k)
		}
	}
	return keys[:]
}

// Whether `j` judges values of `type` by a fragment or as a `.One_Match` union.
@(private)
judges :: proc(j: ^Applied, type: typeid) -> bool {
	for x in j.schemas {
		if x.type == type {
			return true
		}
	}
	return one_match(j, type)
}

@(private)
one_match :: proc(j: ^Applied, type: typeid) -> bool {
	return j != nil && slice.contains(j.unions, type)
}

// Fills `x.d` with the description its check judges by: a root of any value holding `x`'s `unique`, for a `.One_Match`
// union the `oneOf` of its arms, and the fragments of its type. The root is a copy of the first fragment's where that
// holds no `oneOf` of its own, so a lone fragment is judged as it stands, and the other fragments are in its `allOf`.
@(private)
fragment :: proc(j: ^Applied, x: ^Judged, allocator: runtime.Allocator) -> core.Error {
	x.d.allocator = allocator
	x.d.names = make(map[rules.Node_Index]string)
	root := rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1}
	root.rules.unique = x.unique
	append(&x.d.nodes, root) or_return
	if one_match(j, x.type) {
		sub := Reading{plan = own_plan(j, x.type), d = &x.d}
		at := node_of(&sub, 0)
		arms := x.d.nodes[at].any_of
		delete(sub.nodes)
		delete(sub.shapes)
		if sub.failed {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		root.one_of = slice.clone(arms) or_return
	}
	fragments := fragments_of(j, &x.d, x.type) or_return
	if len(fragments) > 0 && (len(root.one_of) == 0 || len(x.d.nodes[fragments[0]].one_of) == 0) {
		// The copy owns its lists, as the fragment's root keeps its own for a `$ref` inside the fragment that reaches it.
		first := x.d.nodes[fragments[0]]
		first.rules.unique ||= root.rules.unique
		first.any_of = slice.clone(first.any_of) or_return
		first.enum_of = slice.clone(first.enum_of) or_return
		first.examples = slice.clone(first.examples) or_return
		first.one_of = root.one_of if len(root.one_of) > 0 else slice.clone(first.one_of) or_return
		all_of := make([]rules.Node_Index, len(first.all_of) + len(fragments) - 1) or_return
		copy(all_of, first.all_of)
		copy(all_of[len(first.all_of):], fragments[1:])
		first.all_of = all_of
		root = first
	} else {
		root.all_of = fragments
	}
	x.d.nodes[0] = root
	return nil
}

// The roots of the fragments on `type`, each grafted into `d`, nil for none.
@(private)
fragments_of :: proc(j: ^Applied, d: ^rules.Description, type: typeid) -> (roots: []rules.Node_Index, err: runtime.Allocator_Error) {
	count := 0
	for x in j.schemas {
		count += int(x.type == type)
	}
	if count == 0 {
		return
	}
	roots = make([]rules.Node_Index, count, d.allocator) or_return
	count = 0
	for &x in j.schemas {
		if x.type == type {
			roots[count] = graft(d, &x.fragment, false) or_return
			count += 1
		}
	}
	return
}

// The plan of judged type `t`.
@(private)
own_plan :: proc(j: ^Applied, t: typeid) -> ^typed.Plan {
	for x in j.plans {
		if x.type == t {
			return x.plan
		}
	}
	return nil
}

// The check plan that judges values of `type`, of `unique` rules when they say so, after a load read them.
@(private)
judge_plan :: proc(h: ^typed.Model_Rules, type: typeid, unique: bool) -> ^typed.Plan {
	if x := judged_of((^Compiling)(h).judging, type, unique); x != nil {
		return &x.plan
	}
	return nil
}

// The refusal of a load plan `p` whose format holds no value alone, a table's, and so reads no text whole, for a member
// read by its first matching arm or judged by applicators.
@(private)
judged_refused :: proc(p: ^typed.Plan) -> core.Typed_Refusal {
	if p.value_text != nil {
		return {}
	}
	for &m in p.meta {
		if m.before != nil && (m.before.first_match || m.before.judge != nil) {
			return {kind = .Unsupported, want = {m.type, "first match" if m.before.first_match else "applicator"}}
		}
	}
	return {}
}

@(private)
judged_of :: proc(j: ^Applied, type: typeid, unique: bool) -> ^Judged {
	for x in j.judged {
		if x.type == type && x.unique == unique {
			return x
		}
	}
	return nil
}

// Judges the value at `at` of record `m`, a judged type's, as a load judges its text, by the check plan of its type on
// the text a write of it gives, and reports what it fails under the value's path. Says whether the walk goes on. A
// value a write refuses is not judged, as the visit reports the refusal.
@(private)
judge_written :: proc(j: ^Judging, m: ^typed.Meta, at: uintptr) -> bool {
	x := judged_of(j.judging, m.type, m.rule_set > 0 && j.plan.rule_sets[m.rule_set - 1].unique)
	w := own_plan(j.judging, m.type)
	// What the write and the judge take of the temporary allocator is given back, unless the call or sink keeps what it
	// reports there, or the first refusal this call sets names its path there.
	keep := context.allocator == context.temp_allocator || j.sink != nil && j.sink.entries.allocator == context.temp_allocator
	first_open := j.first.kind == .None
	guard := runtime.default_temp_allocator_temp_begin()
	defer if !keep && !(first_open && j.first.kind != .None) {
		runtime.default_temp_allocator_temp_end(guard)
	}
	text, refused := w.marshal(w, rawptr(at), {}, {}, context.temp_allocator, nil)
	if refused.kind != .None {
		return true
	}
	sub := typed.Sink{max_errors = j.sink.max_errors if j.sink != nil else 1}
	sub.entries.allocator = context.temp_allocator
	target: u8
	if typed.check_text(text, &target, nil, &x.plan, {sink = &sub, repeats = .Ignore}, context.temp_allocator) == nil {
		return true
	}
	if len(sub.entries) == 0 {
		return report(j, sub.fatal.kind if sub.fatal.kind != .None else .Wrong_Kind)
	}
	for e in sub.entries {
		operand, _ := e.operand.(string)
		if !report(j, e.kind, e.path, operand) {
			return false
		}
	}
	return true
}

@(private)
judging_destroy :: proc(j: ^Applied) {
	if j == nil {
		return
	}
	allocator := j.judged.allocator
	for x in j.judged {
		typed.plan_destroy(&x.plan)
		rules.description_destroy(&x.d)
		free(x, allocator)
	}
	for x in j.plans {
		typed.plan_destroy(x.plan)
		free(x.plan, allocator)
	}
	delete(j.schemas, allocator)
	delete(j.judged)
	delete(j.plans)
	delete(j.unions, allocator)
	virtual.arena_destroy(&j.kept)
	free(j, allocator)
}
