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
	// For the node that asks, the records the set asks the value to pass and those it asks of each element, and what it
	// evaluates of every value that passes it, which its arms judge with no run.
	wholes:   []i32,
	elements: []i32,
	fixed:    ^Evaluates,
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

// What the in-place closure of a node evaluates of every value that passes it, through its own keywords, its `$ref` and
// its `allOf`: the names and patterns, the prefix length, whether every member or element is evaluated, and whether an
// `anyOf`, `oneOf`, `if`, `dependentSchemas` or `$dynamicRef` in it, or a `contains` when `items` asks, makes the whole
// set depend on the value.
@(private)
Static_Set :: struct {
	names:                  [dynamic]string,
	patterns:               [dynamic]rules.Pattern,
	prefix:                 int,
	all_members, all_items: bool,
	varies:                 bool,
}

// Adds to `s` what `node` evaluates through its own keywords, its `$ref` and its `allOf`. `own` leaves out the node's
// own unevaluated keywords.
@(private)
static_set :: proc(d: ^rules.Description, node: rules.Node_Index, s: ^Static_Set, items: bool, own: bool, depth := 0) {
	if node == rules.NONE {
		return
	}
	n := &d.nodes[node]
	if depth == MAX_HELD {
		s.varies = true
		return
	}
	s.varies ||= len(n.any_of) > 0 || len(n.one_of) > 0 || n.cond.test != nil || n.dynamic_ref != nil
	if !own {
		s.all_members ||= n.unevaluated_properties != nil
		s.all_items ||= n.unevaluated_items != nil
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		s.varies ||= dependent_schemas(o)
		for x in o.members {
			if !x.only_required && !named(s.names[:], x.name) {
				append(&s.names, x.name)
			}
		}
		for x in o.patterns {
			pattern_add(&s.patterns, {x.expression, rules.NONE})
		}
		s.all_members ||= o.additional != rules.NONE
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		s.varies ||= items && a.contains != nil
		s.prefix = max(s.prefix, len(a.prefix))
		s.all_items ||= a.items != rules.NONE
	}
	if x, has := n.ref.?; has {
		static_set(d, x, s, items, false, depth + 1)
	}
	for x in n.all_of {
		static_set(d, x, s, items, false, depth + 1)
	}
}

// Adds `p` to `list` unless a pattern of its expression is there.
@(private = "file")
pattern_add :: proc(list: ^[dynamic]rules.Pattern, p: rules.Pattern) {
	for x in list {
		if x.expression == p.expression {
			return
		}
	}
	append(list, p)
}

// What `node` evaluates of every value that passes it, past its own unevaluated keywords, with each pattern compiled.
@(private)
fixed_part :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index) -> ^Evaluates {
	s := Static_Set{names = make([dynamic]string, arena), patterns = make([dynamic]rules.Pattern, arena)}
	static_set(d, node, &s, false, true)
	f := new(Evaluates, arena)
	if f == nil {
		refuse_plan(b, .No_Memory)
		return nil
	}
	patterns := make([]rawptr, len(s.patterns), arena)
	for x, i in s.patterns {
		err: string
		if patterns[i], err = rules.program_of(&b.programs, x.expression, arena); err != "" {
			refuse_plan(b, .Unsupported, text = "patternProperties")
			return f
		}
	}
	f.names, f.patterns, f.prefix, f.members, f.items, f.contains = s.names[:], patterns, s.prefix, s.all_members, s.all_items, -1
	return f
}

// Whether `node` judges nothing: every value passes it, and what it evaluates is all it does. With `required`, the
// node may also require members of an object, whose names it adds there.
@(private)
judges_nothing :: proc(d: ^rules.Description, node: rules.Node_Index, depth := 0, required: ^[dynamic]string = nil) -> bool {
	x, _ := reached(d, node)
	if x == rules.NONE {
		return true
	}
	n := &d.nodes[x]
	if depth == MAX_HELD || n.kinds != rules.EVERY_KIND || n.rules != {} || n.has_enum || n.const_of != nil {
		return false
	}
	if len(n.any_of) > 0 || len(n.one_of) > 0 || n.not != nil || n.cond != {} || n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return false
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if len(o.dependents) > 0 || !judges_nothing(d, o.keys, depth + 1) || !judges_nothing(d, o.additional, depth + 1) {
			return false
		}
		for m in o.members {
			if m.required && (required == nil || depth > 0) || m.rules != {} || !judges_nothing(d, m.node, depth + 1) {
				return false
			}
			if m.required {
				append(required, m.name)
			}
		}
		for p in o.patterns {
			if !judges_nothing(d, p.node, depth + 1) {
				return false
			}
		}
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if a.contains != nil || !judges_nothing(d, a.items, depth + 1) {
			return false
		}
		for p in a.prefix {
			if !judges_nothing(d, p, depth + 1) {
				return false
			}
		}
	}
	if r, has := n.ref.?; has && !judges_nothing(d, r, depth + 1) {
		return false
	}
	for r in n.all_of {
		if !judges_nothing(d, r, depth + 1) {
			return false
		}
	}
	return true
}

// Rewrites in `d` each `unevaluatedProperties` and `unevaluatedItems` whose evaluated set is fixed by the schema alone
// as the `additionalProperties` or `items` of its node, with each name, pattern and place the set holds added to the
// node as one that takes any value, so the node's record judges it with no arm. A set that holds every member or
// element drops the keyword. The node then evaluates every member or element, as it did, and the `$ref` and `allOf`
// targets that judge nothing past what they evaluate are dropped, the places of the `allOf` members kept recorded in
// `b.all_of_at`. The objects and arrays rewritten are recorded in `b.unevaluated`, whose records spell the keyword. A
// node whose kinds leave out objects or arrays keeps its keyword, which reports beside the kind.
@(private)
settle_unevaluated :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator) {
	b.unevaluated.allocator, b.all_of_at.allocator = arena, arena
	for i in 0 ..< len(d.nodes) {
		n := &d.nodes[i]
		settled := false
		if u, has := n.unevaluated_properties.?; has && .Object in n.kinds {
			s := Static_Set{names = make([dynamic]string, arena), patterns = make([dynamic]rules.Pattern, arena)}
			if static_set(d, rules.Node_Index(i), &s, false, true); !s.varies {
				n.unevaluated_properties, settled = nil, true
				if !s.all_members {
					o := d.objects[n.object] if n.object >= 0 else rules.Object{additional = rules.NONE, keys = rules.NONE}
					members := make([dynamic]rules.Member, arena)
					append(&members, ..o.members)
					names: for name in s.names {
						for &x in members {
							if x.name == name {
								if x.only_required {
									x.only_required, x.node = false, rules.NONE
								}
								continue names
							}
						}
						append(&members, rules.Member{name = name, node = rules.NONE})
					}
					patterns := make([dynamic]rules.Pattern, arena)
					append(&patterns, ..o.patterns)
					for x in s.patterns {
						pattern_add(&patterns, x)
					}
					o.members, o.patterns, o.additional = members[:], patterns[:], u
					n.object = i32(len(d.objects))
					append(&d.objects, o)
					b.unevaluated[{0, n.object}] = true
				}
			}
		}
		if u, has := n.unevaluated_items.?; has && .Array in n.kinds {
			s := Static_Set{names = make([dynamic]string, arena), patterns = make([dynamic]rules.Pattern, arena)}
			if static_set(d, rules.Node_Index(i), &s, true, true); !s.varies {
				n.unevaluated_items, settled = nil, true
				if !s.all_items {
					a := d.arrays[n.array] if n.array >= 0 else rules.Array{items = rules.NONE}
					prefix := make([]rules.Node_Index, max(s.prefix, len(a.prefix)), arena)
					copy(prefix, a.prefix)
					for &x in prefix[len(a.prefix):] {
						x = rules.NONE
					}
					a.prefix, a.items = prefix, u
					n.array = i32(len(d.arrays))
					append(&d.arrays, a)
					b.unevaluated[{1, n.array}] = true
				}
			}
		}
		if !settled || n.unevaluated_items != nil || n.unevaluated_properties != nil {
			continue
		}
		if r, has := n.ref.?; has && covered(d, n, r, arena) {
			n.ref = nil
		}
		kept, at := make([dynamic]rules.Node_Index, arena), make([dynamic]int, arena)
		for r, j in n.all_of {
			if !covered(d, n, r, arena) {
				append(&kept, r)
				append(&at, j)
			}
		}
		if len(kept) < len(n.all_of) {
			n.all_of = kept[:]
			b.all_of_at[rules.Node_Index(i)] = at[:]
		}
	}
}

// Whether the in-place target `r` of `n` judges nothing and evaluates nothing `n` does not evaluate itself.
@(private = "file")
covered :: proc(d: ^rules.Description, n: ^rules.Node, r: rules.Node_Index, arena: runtime.Allocator) -> bool {
	if !judges_nothing(d, r) {
		return false
	}
	members := n.object >= 0 && d.objects[n.object].additional != rules.NONE
	items := n.array >= 0 && d.arrays[n.array].items != rules.NONE
	s := Static_Set{names = make([dynamic]string, arena), patterns = make([dynamic]rules.Pattern, arena)}
	static_set(d, r, &s, true, false)
	return !s.varies && (members || len(s.names) == 0 && len(s.patterns) == 0 && !s.all_members) && (items || s.prefix == 0 && !s.all_items)
}
