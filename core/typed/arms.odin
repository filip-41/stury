package typed

import "base:runtime"
import regex "../regex"
import core ".."
import rules "../rules"
import build "../build"

// A held record judges its value by its arms, each a record of the plan read as a check of the value's node in the
// document the check reads. Its first arm is the record of its node without the arms, which judges the rest.
Apply :: struct {
	kind:     Apply_Kind,
	// The arm's record, -1 for an arm that reads none.
	rec:      i32,
	// The member name a `.Dependent` or `.Requires` arm is keyed by, or a `.Pattern`'s expression.
	name:     string,
	// A `.Pattern`'s compiled `^regex.Regex`.
	pattern:  rawptr,
	// The names a `.Requires` arm wants, and the names an `.Additional` arm leaves to the named members' records.
	names:    []string,
	// The operands an `.Equal` arm takes, a `const` when `constant` says so, which may be containers.
	values:   []core.Value,
	constant: bool,
	// The elements a `.Contains` arm wants to pass.
	min, max: u64,
}

Apply_Kind :: enum u8 {
	All, // the value passes the record, whose failures it reports
	Any, // one arm of a run of them passes
	One, // exactly one arm of a run of them passes
	Not, // the value fails the record
	If, // picks the `.Then` that follows when the value passes, else the `.Else`
	Then,
	Else,
	Dependent, // an object with the member `name` passes the record
	Requires, // an object with the member `name` has the members `names`
	Pattern, // each member whose name the pattern matches passes the record
	Additional, // each member no name of `names` and no pattern matches passes the record
	Contains, // between `min` and `max` of an array's elements pass the record
	Unique, // no two of an array's elements are equal
	Equal, // the value equals one of `values`
}

// Whether a use of `n` with `edge` judges by arms.
@(private)
holds :: proc(d: ^rules.Description, node: rules.Node_Index, edge: rules.Rules) -> bool {
	n := &d.nodes[node]
	if len(n.any_of) > 0 || len(n.all_of) > 0 || len(n.one_of) > 0 || n.not != nil || n.ref != nil || n.rules.unique || edge.unique || container_operands(n) {
		return true
	}
	if n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil) {
		return true
	}
	if n.object >= 0 && (len(d.objects[n.object].patterns) > 0 || len(d.objects[n.object].dependents) > 0) {
		return true
	}
	return n.array >= 0 && d.arrays[n.array].contains != nil
}

// Whether `n`'s `const` or `enum` holds a container, which an arm compares, as a leaf compares only scalars.
@(private)
container_operands :: proc(n: ^rules.Node) -> bool {
	if c, has := n.const_of.?; has && core.value_kind(c) >= .Array {
		return true
	}
	for v in n.enum_of {
		if core.value_kind(v) >= .Array {
			return true
		}
	}
	return false
}

// The arms of a held use of `node` with `edge`, in `arena`.
@(private)
checked_applies :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> []Apply {
	n := d.nodes[node]
	out := make([dynamic]Apply, arena)
	arm :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, out: ^[dynamic]Apply, kind: Apply_Kind, node: rules.Node_Index, site: ..core.Step) -> ^Apply {
		steps := make([]core.Step, len(site), arena)
		copy(steps, site)
		if _, failed := append(out, Apply{kind = kind, rec = arm_record(b, d, arena, node, steps)}); failed != nil {
			refuse_plan(b, .No_Memory)
			return nil
		}
		return &out[len(out) - 1]
	}
	// The record of the node without its arms, which only its uses with no rules of their own share.
	key := Block_Key{typeid_of(rules.Rules), i32(node)} if edge == {} else Block_Key{typeid_of(Use), i32(len(b.fields))}
	base, known := b.blocks[key]
	if !known {
		if base = reserve_block(b, 1, key); base >= 0 {
			fill_checked(b, d, arena, int(base), node, "", edge, nil, true)
		}
	}
	append(&out, Apply{kind = .All, rec = base})
	if x, has := n.ref.?; has {
		arm(b, d, arena, &out, .All, x, core.Name("$ref"))
	}
	for x, i in n.all_of {
		arm(b, d, arena, &out, .All, x, core.Name("allOf"), core.Index(i))
	}
	for x, i in n.any_of {
		arm(b, d, arena, &out, .Any, x, core.Name("anyOf"), core.Index(i))
	}
	for x, i in n.one_of {
		arm(b, d, arena, &out, .One, x, core.Name("oneOf"), core.Index(i))
	}
	if x, has := n.not.?; has {
		arm(b, d, arena, &out, .Not, x, core.Name("not"))
	}
	if x, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
		arm(b, d, arena, &out, .If, x, core.Name("if"))
		if y, then := n.cond.then.?; then {
			arm(b, d, arena, &out, .Then, y, core.Name("then"))
		}
		if y, other := n.cond.other.?; other {
			arm(b, d, arena, &out, .Else, y, core.Name("else"))
		}
	}
	if container_operands(&n) {
		if c, has := n.const_of.?; has {
			values := make([]core.Value, 1, arena)
			values[0] = c
			append(&out, Apply{kind = .Equal, rec = -1, values = values, constant = true})
		}
		if n.has_enum {
			append(&out, Apply{kind = .Equal, rec = -1, values = n.enum_of})
		}
	}
	if n.rules.unique || edge.unique {
		append(&out, Apply{kind = .Unique, rec = -1})
	}
	if n.object >= 0 {
		o := d.objects[n.object]
		for x in o.patterns {
			re, err := regex.compile(x.expression, {ecma = true}, arena)
			if err != "" {
				refuse_plan(b, .Unsupported, text = "patternProperties")
				return out[:]
			}
			if a := arm(b, d, arena, &out, .Pattern, x.node, core.Name("patternProperties"), core.Name(x.expression)); a != nil {
				a.name, a.pattern = x.expression, new_clone(re, arena)
			}
		}
		if len(o.patterns) > 0 && o.additional != rules.NONE {
			names := make([dynamic]string, arena)
			for x in o.members {
				if !x.only_required {
					append(&names, x.name)
				}
			}
			if a := arm(b, d, arena, &out, .Additional, o.additional, core.Name("additionalProperties")); a != nil {
				a.names = names[:]
			}
		}
		for x in o.dependents {
			if y, has := x.node.?; has {
				if a := arm(b, d, arena, &out, .Dependent, y, core.Name("dependentSchemas"), core.Name(x.name)); a != nil {
					a.name = x.name
				}
			}
			if len(x.required) > 0 {
				append(&out, Apply{kind = .Requires, rec = -1, name = x.name, names = x.required})
			}
		}
	}
	if n.array >= 0 {
		a := d.arrays[n.array]
		if x, has := a.contains.?; has {
			if c := arm(b, d, arena, &out, .Contains, x, core.Name("contains")); c != nil {
				c.min, c.max = a.min_contains.? or_else 1, a.max_contains.? or_else max(u64)
			}
		}
	}
	return out[:]
}

// The record of an arm that judges by `node` under the keyword steps `site`, which each use of the node by an arm shares.
@(private)
arm_record :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, site: []core.Step) -> i32 {
	key := Block_Key{typeid_of(Apply), i32(node)}
	if at, ok := b.blocks[key]; ok {
		return at
	}
	at := reserve_block(b, 1, key)
	if at >= 0 {
		fill_checked(b, d, arena, int(at), node, "", {}, site)
	}
	return at
}

// Judges the value at the held record `u` by its arms, from the node the document read stands at, and reports each
// failure as the value's. Returns `.Stop` for a read with no sink that the value fails.
@(cold)
@(private)
check_held :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, u: ^Use, t: core.Token) -> core.Action {
	context = h.ctx
	// Only a read of a document reaches its nodes, and a check of a text of a held plan reads the document it builds.
	if h.find_tag != document_tag {
		note(h, regs, {kind = .Unsupported}, t.lo)
		return .Stop
	}
	d := (^Document_Read(Check))(h.format)
	doc, at := d.doc, d.at
	lo, hi := core.scalar_ends(t)
	if t.kind == .Array || t.kind == .Object {
		lo, hi = t.lo, doc.readers.close_end(doc, at)
	}
	held := Held{h = h, regs = regs, doc = doc}
	any, any_passed, one, if_passed := false, false, 0, false
	ones := false
	for &a in u.applies {
		switch a.kind {
		case .All:
			held_report(&held, at, a.rec, nil)
		case .Any:
			any = true
			any_passed = any_passed || held_passes(&held, at, a.rec)
		case .One:
			ones = true
			if one < 2 && held_passes(&held, at, a.rec) {
				one += 1
			}
		case .Not:
			if held_passes(&held, at, a.rec) {
				held_note(&held, .Matches_Not, lo, hi, "not")
			}
		case .If:
			if_passed = held_passes(&held, at, a.rec)
		case .Then:
			if if_passed {
				held_report(&held, at, a.rec, nil)
			}
		case .Else:
			if !if_passed {
				held_report(&held, at, a.rec, nil)
			}
		case .Equal:
			if !held_equal(doc, at, a.values) {
				held_note(&held, .Not_A_Member, lo, hi, "const" if a.constant else "enum")
			}
		case .Unique:
			if t.kind == .Array && !held_unique(doc, at) {
				held_note(&held, .Not_Unique, lo, hi, "uniqueItems")
			}
		case .Contains:
			if t.kind == .Array {
				held_contains(&held, at, &a, lo, hi)
			}
		case .Dependent, .Requires, .Pattern, .Additional:
			if t.kind == .Object {
				held_members(&held, at, &a, lo, hi)
			}
		}
		if held.stop {
			return .Stop
		}
	}
	if any && !any_passed {
		held_note(&held, .No_Arm, lo, hi, "anyOf")
	}
	if ones && one != 1 {
		held_note(&held, .No_Arm if one == 0 else .Many_Arms, lo, hi, "oneOf")
	}
	return .Stop if held.stop else .Next
}

// A held value's judging: the reader and registers it was met at, the document, the path and keyword path to it, which
// the first arm that reports builds, and whether a read with no sink must stop.
@(private)
Held :: struct {
	h:     ^Check,
	regs:  core.Hook_Regs,
	doc:   ^core.Document,
	outer: Outer,
	built: bool,
	stop:  bool,
}

// Adds a failure of kind `kind` under the keyword `word` of the held record to the sink.
@(private)
held_note :: proc(held: ^Held, kind: core.Typed_Error_Kind, lo, hi: u64, word: string, operand := "") {
	e := core.Typed_Error{kind = kind, at = lo}
	if operand != "" {
		e.want.text = operand
	}
	note(held.h, held.regs, e, hi, word)
	held.stop ||= held.h.sink == nil
}

// Whether node `at` passes record `rec`, judged with no sink.
@(private)
held_passes :: proc(held: ^Held, at: core.Node_Index, rec: i32) -> bool {
	passed, _ := held_check(held, at, rec, nil, nil)
	return passed
}

// Judges node `at` by record `rec`, reporting to the sink with the held value's path and keyword path, and `step`
// after the path when it names a member of the value. A failure is the read's first when it has none.
@(private)
held_report :: proc(held: ^Held, at: core.Node_Index, rec: i32, step: Maybe(core.Step)) {
	h := held.h
	outer: ^Outer
	if h.sink != nil {
		if !held.built {
			held.outer, held.built = held_outer(h, held.regs), true
		}
		outer = new_clone(held.outer, context.temp_allocator)
		if s, named := step.?; named {
			path := make([]core.Step, len(outer.path) + 1, context.temp_allocator)
			copy(path, outer.path)
			path[len(outer.path)] = s
			outer.path = path
		}
	}
	passed, first := held_check(held, at, rec, h.sink, outer)
	if !passed {
		held.stop ||= h.sink == nil
		if h.first.kind == .None {
			h.first = first
		}
	}
}

// The path to the value at `regs` and the keyword path to its record, outermost first, after the check's own outer ones.
@(private)
held_outer :: proc(h: ^Check, regs: core.Hook_Regs) -> Outer {
	steps := make([dynamic]core.Step, context.temp_allocator)
	steps_of(h, regs, false, &steps)
	words := make([dynamic]core.Step, context.temp_allocator)
	path := make([dynamic]core.Step, context.temp_allocator)
	if h.outer != nil {
		append(&path, ..h.outer.path)
		append(&words, ..h.outer.words)
	}
	#reverse for s in steps {
		append(&path, s)
	}
	for i in 1 ..< h.sp {
		append(&words, ..h.plan.uses[field_at(h.frames[i].b).meta].site)
	}
	append(&words, ..h.plan.uses[field_at(regs.b).meta].site)
	return {path[:], words[:]}
}

// Checks node `at` of the held value's document by record `rec` of the plan, with `sink`, under `outer`. Says whether
// it passed, with its first failure.
@(private)
held_check :: proc(held: ^Held, at: core.Node_Index, rec: i32, sink: ^Sink, outer: ^Outer) -> (bool, core.Typed_Error) {
	h := held.h
	if rec < 0 {
		return true, {}
	}
	if h.nest == MAX_HELD {
		return false, {kind = .Too_Deep}
	}
	frames: [8]Frame = ---
	ends: [16]u32 = ---
	d := Document_Read(Check){doc = held.doc, room = len(frames)}
	c := (^Check)(uintptr(&d.reader))
	c.ctx, c.view, c.plan, c.sink, c.wide, c.outer, c.nest = h.ctx, h.view, h.plan, sink, true, outer, h.nest + 1
	frames[0].seen = 0
	c.frames, c.sp, c.format, c.find_tag = raw_data(frames[:]), 1, &d, document_tag
	// One past the record, which may be the plan's last.
	regs := core.Hook_Regs{NO_LIMIT, u64(uintptr(&([^]Field)(raw_data(h.plan.fields))[rec + 1])), 0}
	n := held.doc.nodes[at]
	to := u32(at) + (n.n if n.kind > .Plain else 1)
	fed := build.feed_nodes(held.doc, u32(at), to, &d, &regs, ends[:], document_step, document_keyed, document_deepen, true)
	read_release(c, frames[:])
	if !fed && c.first.kind == .None {
		c.first = {kind = .No_Memory}
	}
	return c.first.kind == .None, c.first
}

// The held values a check judges one inside the other, past which a schema that applies itself to the same value
// without end fails as `.Too_Deep`.
@(private)
MAX_HELD :: 256

// Whether node `at` equals one of `values`.
@(private)
held_equal :: proc(doc: ^core.Document, at: core.Node_Index, values: []core.Value) -> bool {
	for v in values {
		if core.equal(core.Node_Ref{doc, at}, v) {
			return true
		}
	}
	return false
}

// Whether no two elements of the array at node `at` are equal.
@(private)
held_unique :: proc(doc: ^core.Document, at: core.Node_Index) -> bool {
	it := core.doc_children(doc, at)
	for x in core.doc_child_next(&it) {
		rest := it
		for y in core.doc_child_next(&rest) {
			if core.equal(core.Node_Ref{doc, x}, core.Node_Ref{doc, y}) {
				return false
			}
		}
	}
	return true
}

// Judges the count of the array at node `at`'s elements that pass the `.Contains` arm `a`.
@(private)
held_contains :: proc(held: ^Held, at: core.Node_Index, a: ^Apply, lo, hi: u64) {
	count: u64
	it := core.doc_children(held.doc, at)
	for x in core.doc_child_next(&it) {
		if held_passes(held, x, a.rec) {
			count += 1
		}
	}
	switch {
	case count < a.min:
		held_note(held, .Too_Few, lo, hi, "contains" if a.min == 1 else "minContains")
	case count > a.max:
		held_note(held, .Too_Many, lo, hi, "maxContains")
	}
}

// Judges the members of the object at node `at` by the arm `a`.
@(private)
held_members :: proc(held: ^Held, at: core.Node_Index, a: ^Apply, lo, hi: u64) {
	context.allocator = context.temp_allocator
	it := core.doc_pairs(held.doc, at)
	scratch: regex.Scratch
	scratch.stack.allocator, scratch.slots.allocator, scratch.counts.allocator = context.temp_allocator, context.temp_allocator, context.temp_allocator
	scratch.seen.allocator, scratch.good.allocator, scratch.log.allocator = context.temp_allocator, context.temp_allocator, context.temp_allocator
	for key, value in core.doc_pair_next(&it) {
		name := core.node_string(held.doc, key)
		switch a.kind {
		case .Dependent:
			if name == a.name {
				held_report(held, at, a.rec, nil)
				return
			}
		case .Requires:
			if name == a.name {
				for want in a.names {
					if !has_member(held.doc, at, want) {
						held_note(held, .Missing_Field, lo, hi, "dependentRequired", want)
					}
				}
				return
			}
		case .Pattern:
			caps: [2]int
			if found, err := regex.search((^regex.Regex)(a.pattern), name, 0, caps[:], &scratch); found && err == "" {
				held_report(held, value, a.rec, core.Name(name))
			}
		case .Additional:
			if !additional(held.h, at, a, name, &scratch) {
				break
			}
			held_report(held, value, a.rec, core.Name(name))
		case .All, .Any, .One, .Not, .If, .Then, .Else, .Contains, .Unique, .Equal:
		}
		if held.stop {
			return
		}
	}
}

// Whether the member `name` of a held object is one no name of `a.names` and no pattern of the held record matches.
@(private)
additional :: proc(h: ^Check, at: core.Node_Index, a: ^Apply, name: string, scratch: ^regex.Scratch) -> bool {
	for x in a.names {
		if x == name {
			return false
		}
	}
	// The patterns are the arms before this one.
	for p := ([^]Apply)(a)[-1:]; p[0].kind == .Pattern; p = p[-1:] {
		caps: [2]int
		if found, err := regex.search((^regex.Regex)(p[0].pattern), name, 0, caps[:], scratch); found && err == "" {
			return false
		}
	}
	return true
}

// Whether the object at node `at` has a member `name`.
@(private)
has_member :: proc(doc: ^core.Document, at: core.Node_Index, name: string) -> bool {
	context.allocator = context.temp_allocator
	it := core.doc_pairs(doc, at)
	for key in core.doc_pair_next(&it) {
		if core.node_string(doc, key) == name {
			return true
		}
	}
	return false
}
