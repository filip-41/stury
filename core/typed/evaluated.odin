package typed

import "base:runtime"
import regex "../regex"
import rules "../rules"

// What a node evaluates of a value that passes it, which `unevaluatedProperties` and `unevaluatedItems` leave to their
// own subschema: the members `names` name and `patterns` match, every member under `members`, the first `prefix`
// elements, every element under `items`, the elements that pass record `contains`, and what the in-place subschemas
// of `inner` evaluate when they count.
@(private)
Evaluates :: struct {
	names:    []string,
	// Each a compiled `^regex.Regex`.
	patterns: []rawptr,
	members:  bool,
	items:    bool,
	prefix:   int,
	contains: i32,
	inner:    []Inner,
	// For the node that asks, the records the set asks the value to pass and those it asks of each element.
	wholes:   []i32,
	elements: []i32,
}

// An in-place subschema whose evaluation counts when the value passes record `rec`, has the member `name` when one is
// set, and passes record `test` exactly when `on` (the `if` a `then` or `else` waits on), -1 for none. An `always` one,
// a `$ref`, `$dynamicRef` or `allOf` member, counts whenever the node that holds it does, since that node fails without it.
@(private)
Inner :: struct {
	rec, test: i32,
	on:        bool,
	always:    bool,
	name:      Maybe(string),
	eval:      ^Evaluates,
}

// What a use of `node` evaluates, a node's own unevaluated keywords included unless `own` says the node is the one that
// asks. Each in-place subschema gets the record that judges it.
@(private)
evaluates :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, own := false) -> ^Evaluates {
	scope := b.scope
	defer b.scope = scope
	enter_scope(b, d, arena, node)
	key := Block_Key{typeid_of(Evaluates), i32(node), b.scope}
	if e, made := b.evaluated[key]; made && !own {
		return e
	}
	e := new(Evaluates, arena)
	if e == nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	if !own {
		if b.evaluated == nil {
			b.evaluated = make(map[Block_Key]^Evaluates, arena)
		}
		b.evaluated[key] = e
	}
	n := &d.nodes[node]
	e.contains = -1
	e.members, e.items = !own && n.unevaluated_properties != nil, !own && n.unevaluated_items != nil
	if n.object >= 0 {
		o := d.objects[n.object]
		names := make([dynamic]string, arena)
		for x in o.members {
			if !x.only_required {
				append(&names, x.name)
			}
		}
		patterns := make([]rawptr, len(o.patterns), arena)
		for x, i in o.patterns {
			err: string
			if patterns[i], err = rules.program_of(&b.programs, x.expression, arena); err != "" {
				refuse_plan(b, .Unsupported, text = "patternProperties")
				return e
			}
		}
		e.names, e.patterns = names[:], patterns
		e.members ||= o.additional != rules.NONE
	}
	if n.array >= 0 {
		a := d.arrays[n.array]
		e.prefix, e.items = len(a.prefix), e.items || a.items != rules.NONE
		if x, has := a.contains.?; has {
			e.contains = arm_record(b, d, arena, x)
		}
	}
	inner := make([dynamic]Inner, arena)
	add :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, inner: ^[dynamic]Inner, x: rules.Node_Index, test: i32 = -1, on := false, name: Maybe(string) = nil, always := false) -> i32 {
		rec := arm_record(b, d, arena, x)
		append(inner, Inner{rec = rec, test = test, on = on, always = always, name = name, eval = evaluates(b, d, arena, x)})
		return rec
	}
	if x, has := n.ref.?; has {
		add(b, d, arena, &inner, x, always = true)
	}
	if x, has := n.dynamic_ref.?; has {
		add(b, d, arena, &inner, dynamic_target(b, d, x), always = true)
	}
	for x in n.all_of {
		add(b, d, arena, &inner, x, always = true)
	}
	for list in ([?][]rules.Node_Index{n.any_of, n.one_of}) {
		for x in list {
			add(b, d, arena, &inner, x)
		}
	}
	if x, has := n.cond.test.?; has {
		test := add(b, d, arena, &inner, x)
		if y, then := n.cond.then.?; then {
			add(b, d, arena, &inner, y, test, true)
		}
		if y, other := n.cond.other.?; other {
			add(b, d, arena, &inner, y, test, false)
		}
	}
	if n.object >= 0 {
		for x in d.objects[n.object].dependents {
			if y, has := x.node.?; has {
				add(b, d, arena, &inner, y, name = x.name)
			}
		}
	}
	e.inner = inner[:]
	return e
}

// Whether the value being judged, or under `index` its member or element of that place, passes record `rec`, which
// the evaluated set asks of the runs.
@(private)
Passes :: #type proc(data: rawptr, index: int, rec: i32) -> bool

// The evaluated set's view of a value: its member names in order or its element count, how it asks whether the value or
// a member passes a record, and a search's scratch.
@(private)
Evaluating :: struct {
	names:   []string,
	count:   int,
	passes:  Passes,
	data:    rawptr,
	scratch: ^regex.Scratch,
}

// Marks in `marks` the members, in the object's order, or under `items` the elements of the value that `e` evaluates.
@(private)
mark_evaluated :: proc(ev: ^Evaluating, e: ^Evaluates, marks: []bool, items: bool, depth := 0) {
	if depth == MAX_HELD {
		return
	}
	if e.items if items else e.members {
		for &m in marks {
			m = true
		}
		return
	}
	if items {
		for i in 0 ..< min(e.prefix, len(marks)) {
			marks[i] = true
		}
		for i in 0 ..< len(marks) {
			marks[i] ||= e.contains >= 0 && ev.passes(ev.data, i, e.contains)
		}
	} else if len(e.names) + len(e.patterns) > 0 {
		for name, i in ev.names {
			marks[i] ||= evaluates_name(e, name, ev.scratch)
		}
	}
	for &x in e.inner {
		if counts(ev, &x) {
			mark_evaluated(ev, x.eval, marks, items, depth + 1)
		}
	}
}

// Whether `e` names the member `name` or a pattern of it matches it.
@(private)
evaluates_name :: proc(e: ^Evaluates, name: string, scratch: ^regex.Scratch) -> bool {
	for x in e.names {
		if x == name {
			return true
		}
	}
	for p in e.patterns {
		if matches(p, name, scratch) {
			return true
		}
	}
	return false
}

// Whether the in-place subschema `x` counts for the value.
@(private)
counts :: proc(ev: ^Evaluating, x: ^Inner) -> bool {
	if name, keyed := x.name.?; keyed && !named(ev.names, name) {
		return false
	}
	if x.test >= 0 && ev.passes(ev.data, -1, x.test) != x.on {
		return false
	}
	return x.always || ev.passes(ev.data, -1, x.rec)
}

// The records the evaluated set of `e` asks the value to be judged by, and those it asks of each element, each once.
@(private)
evaluated_records :: proc(e: ^Evaluates, arena: runtime.Allocator) -> (wholes, elements: []i32) {
	seen := make(map[^Evaluates]bool, context.temp_allocator)
	whole, each := make([dynamic]i32, arena), make([dynamic]i32, arena)
	add :: proc(list: ^[dynamic]i32, rec: i32) {
		for x in list {
			if x == rec {
				return
			}
		}
		append(list, rec)
	}
	walk :: proc(e: ^Evaluates, seen: ^map[^Evaluates]bool, whole, each: ^[dynamic]i32) {
		if e == nil || e in seen {
			return
		}
		seen[e] = true
		if e.contains >= 0 {
			add(each, e.contains)
		}
		for x in e.inner {
			if !x.always {
				add(whole, x.rec)
			}
			if x.test >= 0 {
				add(whole, x.test)
			}
			walk(x.eval, seen, whole, each)
		}
	}
	walk(e, &seen, &whole, &each)
	return whole[:], each[:]
}
