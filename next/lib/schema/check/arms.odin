// Held-value applicators (`Apply`), `Fork`/`Run`/`Pool` runtime, and `build.Builder` capture
// for `uniqueItems`, container `const`/`enum`, `unevaluatedProperties`, `unevaluatedItems`,
// `dependentSchemas`, `patternProperties`, `contains`, `allOf`, `anyOf`, `oneOf`, `not`, and `if/then/else`.
package check

import "base:runtime"
import "core:mem"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/schema/rules"

// What an `Apply` arm judges on a held value.
@(private)
Apply_Kind :: enum u8 {
	Own,                    // the node's own bare record
	Ref,                    // `$ref` or `$dynamicRef`
	All,                    // `allOf`
	Any,                    // `anyOf`
	One,                    // `oneOf`
	Not,                    // `not`
	If,                     // `if` / `then` / `else`
	Dependent,              // `dependentSchemas` (or Draft 4/7 schema `dependencies`)
	Patterns,               // `patternProperties` (+ optional `additionalProperties`)
	Names,                  // `propertyNames` with arms
	Contains,               // array `contains` (`minContains`..`maxContains`)
	Unique,                 // array `uniqueItems`
	Const,                  // container `const`
	Enum,                   // container `enum`
	Unevaluated_Properties, // `unevaluatedProperties`
	Unevaluated_Items,      // `unevaluatedItems`
}

// One pattern inside an `.Patterns` apply arm.
@(private)
Apply_Pattern :: struct {
	expression: string,
	regex:      ^regex.Regex,
	record:     i32,
}

// One dependent schema inside a `.Dependent` apply arm.
@(private)
Apply_Dependent :: struct {
	name:    string,
	record:  i32,
	keyword: string,
}

// One compiled applicator arm on a held record (`Use.applies` / `Use.verdict`).
@(private)
Apply :: struct {
	kind:          Apply_Kind,
	keyword:       string,
	record:        i32,               // `.Own`, `.Ref`, `.Not`, `.Names`, `.Contains`, `.Unevaluated_*`
	arms:          []i32,             // `.All`, `.Any`, `.One`
	test:          i32,               // `.If`
	then_rec:      i32,               // `.If` (-1 for none)
	else_rec:      i32,               // `.If` (-1 for none)
	patterns:      []Apply_Pattern,   // `.Patterns`
	named:         []string,          // `.Patterns`: named properties already declared on the object
	additional:    i32,               // `.Patterns`: record for non-matching unnamed members (-1 for none)
	dependents:    []Apply_Dependent, // `.Dependent`
	min_contains:  u64,               // `.Contains`
	max_contains:  u64,               // `.Contains`
	eval_contains: bool,              // `.Contains`
	operands:      []rules.Value,     // `.Const` (len 1), `.Enum`
	evals:         ^Evaluates,        // `.Unevaluated_Properties` / `.Unevaluated_Items`
}

// Whether `n` has a container `const` or `enum` operand (which requires holding/building the value).
@(private)
arm_operands :: proc "contextless" (n: ^rules.Node) -> bool {
	if c, has := n.const_of.?; has {
		k := rules.value_kind(c)
		if k == .Object || k == .Array {
			return true
		}
	}
	if n.has_enum {
		for v in n.enum_of {
			k := rules.value_kind(v)
			if k == .Object || k == .Array {
				return true
			}
		}
	}
	return false
}

// Whether a use of `node` with `edge` needs held-value arms (cannot be judged by a single bare record alone).
@(private)
holds :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, edge: rules.Rules) -> bool {
	if node == rules.NONE {
		return false
	}
	n := &d.nodes[node]
	if len(n.all_of) > 0 || len(n.any_of) > 0 || len(n.one_of) > 0 || n.not != nil || (n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil)) || n.ref != nil || n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil {
		return true
	}
	if n.rules.unique || edge.unique || arm_operands(n) {
		return true
	}
	if n.array >= 0 && d.arrays[n.array].contains != nil {
		return true
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if len(o.patterns) > 0 && n.object not_in b.inline {
			return true
		}
		for dep in o.dependents {
			if dep.node != nil {
				return true
			}
		}
		if keys, _ := rules.ref_end(d, o.keys); keys != rules.NONE && holds(b, d, keys, {}) {
			return true
		}
	}
	return false
}

// Hashes `site` steps so distinct keyword sites (`anyOf/0` vs `anyOf/1`) stay distinct while
// cyclic `$ref`s hitting the same `(node, scope, bare, site)` reuse the pre-allocated record (A-C2)!
@(private = "file")
site_hash :: proc "contextless" (site: []tape.Step) -> u64 {
	if len(site) == 0 {
		return 0
	}
	h := u64(0x9E3779B97F4A7C15)
	for s in site {
		#partial switch v in s {
		case tape.Name:
			h = (h ~ u64(tape.text_hash(transmute([]u8)string(v))) ~ 1) * 0xBF58476D1CE4E5B9
		case tape.Index:
			h = (h ~ u64(v) ~ 2) * 0xBF58476D1CE4E5B9
		}
	}
	return h
}

// Allocates (or reuses via `b.arm_cache` for cyclic `$ref`s) a standalone `Checked` record for an arm's subschema.
@(private)
arm_record :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, site: []tape.Step, edge: rules.Rules = {}, bare := false) -> i32 {
	if edge == {} {
		key := Arm_Key{node = node, scope = b.scope, bare = bare, site_tag = site_hash(site)}
		if existing, ok := b.arm_cache[key]; ok {
			return existing
		}
		at, _ := block_of(b, 2, {})
		if at < 0 {
			return 0
		}
		b.arm_cache[key] = at
		never(b, int(at) + 1)
		fill_checked(b, d, arena, int(at), node, "", edge, site, bare = bare)
		return at
	}
	at, _ := block_of(b, 2, {})
	if at < 0 {
		return 0
	}
	never(b, int(at) + 1)
	fill_checked(b, d, arena, int(at), node, "", edge, site, bare = bare)
	return at
}

// Compiles the `Use.applies` (full errors mode) and `Use.verdict` (optional conjoined fast path for verdict-only mode)
// for held node `node` with `edge`.
@(private)
checked_applies :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> (applies: []Apply, verdict: []Apply) {
	n := &d.nodes[node]
	list := make([dynamic]Apply, arena)

	// 1. Own bare keywords (if any).
	if has_own_keywords(b, d, n, edge) {
		rec := arm_record(b, d, arena, node, nil, edge, bare = true)
		append(&list, Apply{kind = .Own, record = rec})
	}

	// 2. `$ref`
	if r, has := n.ref.?; has {
		kw := rules.ref_keyword(n)
		site := [1]tape.Step{tape.Name(kw)}
		saved := b.scope
		enter_scope(b, d, arena, r)
		rec := arm_record(b, d, arena, r, site[:])
		b.scope = saved
		append(&list, Apply{kind = .Ref, keyword = kw, record = rec})
	}

	// 3. `$dynamicRef`
	if dr, has := n.dynamic_ref.?; has {
		kw := rules.dynamic_keyword(n)
		site := [1]tape.Step{tape.Name(kw)}
		target := dynamic_target(b, d, n, dr)
		saved := b.scope
		enter_scope(b, d, arena, target)
		rec := arm_record(b, d, arena, target, site[:])
		b.scope = saved
		append(&list, Apply{kind = .Ref, keyword = kw, record = rec})
	}

	// 4. `allOf`
	if len(n.all_of) > 0 {
		arms, err := make([]i32, len(n.all_of), arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return nil, nil
		}
		for a, i in n.all_of {
			site := [2]tape.Step{tape.Name("allOf"), tape.Index(i)}
			arms[i] = arm_record(b, d, arena, a, site[:])
		}
		append(&list, Apply{kind = .All, keyword = "allOf", arms = arms})
	}

	// 5. `anyOf`
	if len(n.any_of) > 0 {
		arms, err := make([]i32, len(n.any_of), arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return nil, nil
		}
		for a, i in n.any_of {
			site := [2]tape.Step{tape.Name("anyOf"), tape.Index(i)}
			arms[i] = arm_record(b, d, arena, a, site[:])
		}
		append(&list, Apply{kind = .Any, keyword = "anyOf", arms = arms})
	}

	// 6. `oneOf`
	if len(n.one_of) > 0 {
		arms, err := make([]i32, len(n.one_of), arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return nil, nil
		}
		for a, i in n.one_of {
			site := [2]tape.Step{tape.Name("oneOf"), tape.Index(i)}
			arms[i] = arm_record(b, d, arena, a, site[:])
		}
		append(&list, Apply{kind = .One, keyword = "oneOf", arms = arms})
	}

	// 7. `not`
	if nt, has := n.not.?; has {
		site := [1]tape.Step{tape.Name("not")}
		rec := arm_record(b, d, arena, nt, site[:])
		append(&list, Apply{kind = .Not, keyword = "not", record = rec})
	}

	// 8. `if` / `then` / `else`
	if test, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
		test_site := [1]tape.Step{tape.Name("if")}
		test_rec := arm_record(b, d, arena, test, test_site[:])
		then_rec := i32(-1)
		if th, has_th := n.cond.then.?; has_th {
			th_site := [1]tape.Step{tape.Name("then")}
			then_rec = arm_record(b, d, arena, th, th_site[:])
		}
		else_rec := i32(-1)
		if ot, has_ot := n.cond.other.?; has_ot {
			ot_site := [1]tape.Step{tape.Name("else")}
			else_rec = arm_record(b, d, arena, ot, ot_site[:])
		}
		append(&list, Apply{kind = .If, keyword = "if", test = test_rec, then_rec = then_rec, else_rec = else_rec})
	}

	// 9. Object `patternProperties` (non-inlined), `dependentSchemas`, and held `propertyNames`.
	if n.object >= 0 {
		o := &d.objects[n.object]
		if len(o.patterns) > 0 && n.object not_in b.inline {
			pats, perr := make([]Apply_Pattern, len(o.patterns), arena)
			if perr != nil {
				refuse_plan(b, .No_Memory)
				return nil, nil
			}
			for p, i in o.patterns {
				re, rerr := rules.program_of(&b.programs, p.expression, arena, b.tables)
				if rerr.kind != .None {
					refuse_plan(b, .Unsupported, "patternProperties")
					return nil, nil
				}
				expr := clone_str(b, arena, p.expression)
				site := [2]tape.Step{tape.Name("patternProperties"), tape.Name(expr)}
				rec := arm_record(b, d, arena, p.node, site[:])
				pats[i] = Apply_Pattern{expression = expr, regex = re, record = rec}
			}
			named := make([dynamic]string, arena)
			for m in o.members {
				if !m.only_required {
					append(&named, clone_str(b, arena, m.name))
				}
			}
			add_rec := i32(-1)
			if o.additional != rules.NONE {
				site := UNEVALUATED_PROPERTIES[:] if b.unevaluated[{0, n.object}] else ADDITIONAL[:]
				add_rec = arm_record(b, d, arena, o.additional, site)
			}
			append(&list, Apply{kind = .Patterns, keyword = "patternProperties", patterns = pats, named = named[:], additional = add_rec})
		}
		deps := make([dynamic]Apply_Dependent, arena)
		kw := "dependencies" if o.dependencies else "dependentSchemas"
		for dep in o.dependents {
			if dn, has := dep.node.?; has {
				nm := clone_str(b, arena, dep.name)
				site := [2]tape.Step{tape.Name(kw), tape.Name(nm)}
				rec := arm_record(b, d, arena, dn, site[:])
				append(&deps, Apply_Dependent{name = nm, record = rec, keyword = kw})
			}
		}
		if len(deps) > 0 {
			append(&list, Apply{kind = .Dependent, keyword = kw, dependents = deps[:]})
		}
		if keys, hops := rules.ref_end(d, o.keys); keys != rules.NONE && holds(b, d, keys, {}) {
			site := [1]tape.Step{tape.Name("propertyNames")}
			saved := b.scope
			for y, hop := o.keys, 0; y != rules.NONE && hop <= hops; hop += 1 {
				enter_scope(b, d, arena, y)
				y = d.nodes[y].ref.? or_else keys
			}
			rec := arm_record(b, d, arena, keys, site[:])
			b.scope = saved
			append(&list, Apply{kind = .Names, keyword = "propertyNames", record = rec})
		}
	}

	// 10. Array `contains`.
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if c, has := a.contains.?; has {
			site := [1]tape.Step{tape.Name("contains")}
			rec := arm_record(b, d, arena, c, site[:])
			append(&list, Apply{
				kind = .Contains,
				keyword = "contains",
				record = rec,
				min_contains = a.min_contains.? or_else 1,
				max_contains = a.max_contains.? or_else max(u64),
				eval_contains = a.evaluates_contains,
			})
		}
	}

	// 11. Array `uniqueItems`.
	if n.rules.unique || edge.unique {
		append(&list, Apply{kind = .Unique, keyword = "uniqueItems"})
	}

	// 12. Container `const` / `enum`.
	if arm_operands(n) {
		if c, has := n.const_of.?; has {
			ops, err := make([]rules.Value, 1, arena)
			if err != nil {
				refuse_plan(b, .No_Memory)
				return nil, nil
			}
			ops[0] = clone_value(b, c, arena, b.tables)
			append(&list, Apply{kind = .Const, keyword = "const", operands = ops})
		}
		if n.has_enum {
			ops, err := make([]rules.Value, len(n.enum_of), arena)
			if err != nil {
				refuse_plan(b, .No_Memory)
				return nil, nil
			}
			for v, i in n.enum_of {
				ops[i] = clone_value(b, v, arena, b.tables)
			}
			append(&list, Apply{kind = .Enum, keyword = "enum", operands = ops})
		}
	}

	// 13. `unevaluatedProperties` / `unevaluatedItems` (B-C7: `skip_own_uneval = true` avoids cache aliasing between siblings!).
	if up, has := n.unevaluated_properties.?; has {
		site := UNEVALUATED_PROPERTIES[:]
		rec := arm_record(b, d, arena, up, site)
		ev := evaluates(b, d, arena, node, skip_own_uneval = true)
		append(&list, Apply{kind = .Unevaluated_Properties, keyword = "unevaluatedProperties", record = rec, evals = ev})
	}
	if ui, has := n.unevaluated_items.?; has {
		site := UNEVALUATED_ITEMS[:]
		rec := arm_record(b, d, arena, ui, site)
		ev := evaluates(b, d, arena, node, skip_own_uneval = true)
		append(&list, Apply{kind = .Unevaluated_Items, keyword = "unevaluatedItems", record = rec, evals = ev})
	}

	applies = list[:]

	// Verdict-only fast path: if this is a conjoinable `allOf`+`$ref` chain, compile a single conjoined record!
	if conj := conjoin_verdict(b, d, arena, b.tables, node, edge); conj != rules.NONE {
		v_list, err := make([]Apply, 1, arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return applies, nil
		}
		rec := arm_record(b, d, arena, conj, nil)
		v_list[0] = Apply{kind = .Own, record = rec}
		verdict = v_list
	}
	return applies, verdict
}

@(private = "file")
has_own_keywords :: proc(b: ^Builder, d: ^rules.Description, n: ^rules.Node, edge: rules.Rules) -> bool {
	if n.kinds != rules.EVERY_KIND || n.integer_spelled || (!arm_operands(n) && (n.has_enum || n.const_of != nil)) {
		return true
	}
	r, clash := rules.merged(n, edge)
	if clash != "" {
		return true
	}
	if r.minimum != "" || r.maximum != "" || r.multiple_of != "" || r.pattern != "" || (r.assert_format && !r.format_foreign && rules.format_of(r.format) != .None) || (edge.assert_format && !edge.format_foreign && rules.format_of(edge.format) != .None) || r.min_length > 0 || r.max_length != nil || r.min_items > 0 || r.max_items != nil || r.min_members > 0 || r.max_members != nil {
		return true
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if len(a.prefix) > 0 || a.items != rules.NONE {
			return true
		}
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if len(o.members) > 0 || o.additional != rules.NONE || o.keys != rules.NONE || n.object in b.inline {
			return true
		}
		for dep in o.dependents {
			if len(dep.required) > 0 {
				return true
			}
		}
	}
	return false
}

// ============================================================================
// Runtime `Pool` & `Held_Capture` (captures held values via v2 `build.Builder` when needed)
// ============================================================================

@(private)
Pool :: struct {
	allocator:      runtime.Allocator,
	arena:          mem.Dynamic_Arena,
	arena_ready:    bool,
	factored:       [dynamic]Factored_Open,
	captures:       [MAX_HELD_CAPTURES]^Held_Capture,
}

@(private)
pool_init :: proc(p: ^Pool, allocator: runtime.Allocator) {
	p^ = {allocator = allocator}
	p.factored.allocator = allocator
}

@(private)
pool_destroy :: proc(p: ^Pool) {
	if p == nil {
		return
	}
	for c in p.captures {
		if c != nil {
			free(c, p.allocator)
		}
	}
	delete(p.factored)
	if p.arena_ready {
		mem.dynamic_arena_destroy(&p.arena)
	}
	p^ = {}
}

@(private)
pool_allocator :: proc(p: ^Pool) -> runtime.Allocator {
	if !p.arena_ready {
		mem.dynamic_arena_init(&p.arena, p.allocator, p.allocator, block_size = 4096)
		p.arena_ready = true
	}
	return mem.dynamic_arena_allocator(&p.arena)
}

@(private)
pool_capture_slot :: proc(h: ^Checker, idx: int) -> ^Held_Capture {
	pool := pool_ensure(h)
	if pool == nil {
		return nil
	}
	if pool.captures[idx] == nil {
		c, err := new(Held_Capture, pool.allocator)
		if err != nil {
			h.fatal = .No_Memory
			return nil
		}
		pool.captures[idx] = c
	}
	return pool.captures[idx]
}

@(private)
pool_ensure :: proc(h: ^Checker) -> ^Pool {
	if h.pool != nil {
		return h.pool
	}
	// Allocate a local pool in `h.scratch`.
	p, err := new(Pool, h.scratch)
	if err != nil {
		h.fatal = .No_Memory
		return nil
	}
	pool_init(p, h.scratch)
	h.pool = p
	h.owns_pool = true
	return p
}

// A held value currently being captured (as a mini `tape.Document` via `build.Builder`) for evaluation at `.End`.
@(private)
Held_Capture :: struct {
	builder:        build.Builder,
	regs:           hook.Regs,
	stack_buf:      [16]u64,
	counts_buf:     [8]tape.Child_Count,
	owner:          ^Record,
	open_at:        u64,
	saved_b:        u64,
	depth:          int,
	for_factor:     bool,           // true if capturing a multi-choice factored member!
	factor_member:  ^Factor_Member, // active factored member when `for_factor == true`
	active:         bool,
}

@(private)
capture_start :: proc(h: ^Checker, owner: ^Record, at: u64, saved_b: u64, for_factor := false, fm: ^Factor_Member = nil) -> bool {
	if h.capture_depth >= MAX_HELD_CAPTURES {
		h.fatal = .Exceeded
		return false
	}
	cap_slot := pool_capture_slot(h, h.capture_depth)
	if cap_slot == nil {
		return false
	}
	cap_slot^ = {
		owner = owner,
		open_at = at,
		saved_b = saved_b,
		depth = 0,
		for_factor = for_factor,
		factor_member = fm,
		active = true,
	}
	most := int(max(u32) / 4)
	if h.budget.nodes > 0 {
		if h.nodes_seen >= u64(h.budget.nodes) {
			h.fatal = .Exceeded
			return false
		}
		most = max(1, int(u64(h.budget.nodes) - h.nodes_seen))
	}
	build.builder_start(
		&cap_slot.builder,
		h.src,
		h.format,
		nodes = 16,
		most = most,
		frames = cap_slot.stack_buf[:],
		allocator = h.scratch,
		budget = h.mem_budget,
		counts_buf = cap_slot.counts_buf[:],
		scratch = h.scratch,
	)
	if cap_slot.builder.err != nil {
		h.fatal = .No_Memory
		return false
	}
	cap_slot.regs = build.builder_regs(&cap_slot.builder)
	h.capture_depth += 1
	return true
}

@(private)
capture_feed :: proc(h: ^Checker, t: tape.Token) -> (done: bool, ok: bool) {
	c := h.pool.captures[h.capture_depth - 1]
	// Track container nesting depth inside the captured value.
	if t.role == .Value {
		if t.kind == .Object || t.kind == .Array {
			c.depth += 1
		} else if t.kind == .End {
			c.depth -= 1
		}
	}
	// Honor `hook.Rooms` and `hook.Levels` protocols before calling public `build.builder_hook_kept`.
	if t.role <= .Key && t.kind != .End {
		if uintptr(c.regs.a) == hook.rooms_end(&c.builder) {
			if !hook.rooms_grow(&c.builder, &c.regs, t.lo) {
				h.fatal = .Exceeded if c.builder.full != 0 else .No_Memory
				capture_abort(h)
				return true, false
			}
		}
		if t.kind > .Plain && int(c.regs.c) >= hook.levels_held(&c.builder) {
			if !hook.levels_grow(&c.builder, int(c.regs.c) + 1, &c.regs, t.lo) {
				h.fatal = .No_Memory
				capture_abort(h)
				return true, false
			}
		}
	}
	act: hook.Action
	c.regs, act = build.builder_hook_kept(&c.builder, c.regs, t)
	if act == .Stop || c.builder.err != nil {
		if c.builder.full != 0 {
			h.fatal = .Exceeded
		} else {
			h.fatal = .No_Memory
		}
		capture_abort(h)
		return true, false
	}
	if c.depth == 0 {
		return true, true
	}
	return false, true
}

@(private)
capture_abort :: proc(h: ^Checker) {
	if h.capture_depth <= 0 {
		return
	}
	h.capture_depth -= 1
	c := h.pool.captures[h.capture_depth]
	doc, _ := build.builder_end(&c.builder, c.regs, 0, nil)
	tape.destroy(&doc)
	c.active = false
}

// Finishes the innermost `Held_Capture`, runs all `Apply` arms (or factored multi-choices) against the
// captured mini `tape.Document`, and frees the mini document immediately!
@(private)
capture_finish :: proc(h: ^Checker) -> bool {
	h.capture_depth -= 1
	c := h.pool.captures[h.capture_depth]
	doc, berr := build.builder_end(&c.builder, c.regs, 0, nil)
	// Preserve DTD/entity extension temporarily for XML decoding, clearing before destroy so we don't double-free `h.xml_ext`!
	saved_ext := doc.ext
	if h.xml_ext != nil && saved_ext == nil {
		doc.ext = h.xml_ext
	}
	defer {
		if saved_ext == nil && doc.ext == h.xml_ext {
			doc.ext = nil
		}
		tape.destroy(&doc)
	}
	c.active = false
	if berr != nil {
		if _, is_ex := berr.(tape.Exceeded); is_ex {
			h.fatal = .Exceeded
		} else {
			h.fatal = .No_Memory
		}
		return false
	}
	if c.for_factor {
		// Multi-choice member inside an open factored object!
		// Re-fetch `fo` via `fo_idx` after `subcheck_node` because nested factored objects can grow `h.pool.factored`!
		fo_idx := h.nf - 1
		fo := factored_at(h, fo_idx)
		fm := c.factor_member
		fo.active_member = nil
		fo.active_choice = -1
		if fm != nil {
			root_k := doc.nodes[0].kind
			cnt_i, _, _ := tape.length(tape.Reader{doc = &doc}, 0, h.scratch)
			cnt := u64(max(cnt_i, 0))
			for fl in fm.leaves {
				l := &h.plan.leaves[fl.leaf - 1]
				if root_k == .Object {
					if .Object not_in l.kinds || cnt < l.min_members || cnt > l.max_members {
						fo.failed |= fl.parts
					}
				} else if root_k == .Array {
					if .Array not_in l.kinds || cnt < l.min_items || cnt > l.max_items {
						fo.failed |= fl.parts
					}
				}
			}
			for ch in fm.choices {
				fo = factored_at(h, fo_idx)
				if fo.factor.monotone && (ch.parts & ~fo.failed) == 0 {
					continue
				}
				passed := subcheck_node(h, &doc, 0, ch.record, nil, nil, quiet = true)
				fo = factored_at(h, fo_idx)
				if !passed {
					fo.failed |= ch.parts
				}
				if h.fatal != .None {
					return false
				}
			}
		}
		fo = factored_at(h, fo_idx)
		if can_doom_factored(h, fo.factor, fo.failed) {
			return false
		}
		return true
	}
	// Normal held value: evaluate all `Apply` arms of `c.owner` on `doc` node 0!
	return eval_held_node(h, &doc, 0, c.owner, c.open_at)
}

// Evaluates all `Apply` arms of held record `owner` on `doc` node `node`.
@(private)
eval_held_node :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, at: u64) -> bool {
	if h.fatal != .None {
		return false
	}
	if !charge_step_one(h) {
		return false
	}
	u := &h.plan.uses[owner.meta]
	applies := u.verdict if (h.sink == nil || h.quiet) && len(u.verdict) > 0 else u.applies
	all_ok := true
	emit := h.sink != nil && !h.quiet

	for &ap in applies {
		if h.fatal != .None {
			return false
		}
		ok := eval_apply(h, doc, node, owner, &ap, at, emit)
		if !ok {
			all_ok = false
			if !emit {
				return false
			}
		}
	}
	return all_ok
}

@(private = "file")
eval_apply :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, ap: ^Apply, at: u64, emit: bool) -> bool {
	k := doc.nodes[node].kind
	r := tape.Reader{doc = doc}
	switch ap.kind {
	case .Own:
		return subcheck_node(h, doc, node, ap.record, nil, owner, quiet = !emit)
	case .Ref:
		return subcheck_node(h, doc, node, ap.record, nil, owner, quiet = !emit)
	case .All:
		ok := true
		for rec in ap.arms {
			if !charge_step_one(h) {
				return false
			}
			if !subcheck_node(h, doc, node, rec, nil, owner, quiet = !emit) {
				ok = false
				if !emit {
					return false
				}
			}
		}
		return ok
	case .Any:
		mark := sink_mark(h.sink) if emit else Sink_Mark{}
		for rec in ap.arms {
			if !charge_step_one(h) {
				return false
			}
			if subcheck_node(h, doc, node, rec, nil, owner, quiet = true) {
				if emit {
					sink_restore(h.sink, mark)
				}
				return true
			}
			if h.fatal != .None {
				return false
			}
		}
		if emit {
			for rec in ap.arms {
				subcheck_node(h, doc, node, rec, nil, owner, quiet = false)
			}
			record_failure(h, .No_Arm, at, "anyOf", "", owner)
		} else {
			record_first_failure(h, .No_Arm, at, "anyOf", "", owner)
		}
		return false
	case .One:
		hits := 0
		for rec in ap.arms {
			if !charge_step_one(h) {
				return false
			}
			if subcheck_node(h, doc, node, rec, nil, owner, quiet = true) {
				hits += 1
				if hits > 1 && !emit {
					record_first_failure(h, .Many_Arms, at, "oneOf", "", owner)
					return false
				}
			}
			if h.fatal != .None {
				return false
			}
		}
		if hits == 1 {
			return true
		}
		kind := Error_Kind.No_Arm if hits == 0 else Error_Kind.Many_Arms
		if emit {
			if hits == 0 {
				for rec in ap.arms {
					subcheck_node(h, doc, node, rec, nil, owner, quiet = false)
				}
			}
			record_failure(h, kind, at, "oneOf", "", owner)
		} else {
			record_first_failure(h, kind, at, "oneOf", "", owner)
		}
		return false
	case .Not:
		passed := subcheck_node(h, doc, node, ap.record, nil, owner, quiet = true)
		if h.fatal != .None {
			return false
		}
		if passed {
			if emit {
				record_failure(h, .Not_Allowed, at, "not", "", owner)
			} else {
				record_first_failure(h, .Not_Allowed, at, "not", "", owner)
			}
			return false
		}
		return true
	case .If:
		cond_ok := subcheck_node(h, doc, node, ap.test, nil, owner, quiet = true)
		if h.fatal != .None {
			return false
		}
		if cond_ok {
			if ap.then_rec >= 0 {
				return subcheck_node(h, doc, node, ap.then_rec, nil, owner, quiet = !emit)
			}
			return true
		}
		if ap.else_rec >= 0 {
			return subcheck_node(h, doc, node, ap.else_rec, nil, owner, quiet = !emit)
		}
		return true
	case .Dependent:
		if k != .Object {
			return true
		}
		ok := true
		for dep in ap.dependents {
			if object_has_key(h, doc, node, dep.name) {
				if !subcheck_node(h, doc, node, dep.record, nil, owner, quiet = !emit) {
					ok = false
					if !emit {
						return false
					}
				}
			}
		}
		return ok
	case .Patterns:
		if k != .Object {
			return true
		}
		ok := true
		it, p, cerr := tape.children(r, node, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return false
		}
		defer tape.destroy_children(&it)
		if p != .Found {
			return true
		}
		for {
			kn, vn, cp := tape.next_child(r, &it, h.dups)
			if cp != .Found {
				break
			}
			if !charge_step_one(h) {
				return false
			}
			kt := tape.cell_key(r, it) if (kn == tape.NO_NODE && it.keys_n != 0) else doc.nodes[kn]
			key_str, key_owned, kok := doc_token_text(doc, kt, h.scratch)
			if !kok {
				h.fatal = .No_Memory
				return false
			}
			matched := slice.contains(ap.named, key_str)
			for pat in ap.patterns {
				found, rok := run_regex_search(h, pat.regex, key_str)
				if !rok {
					if key_owned {
						delete(key_str, h.scratch)
					}
					return false
				}
				if found {
					matched = true
					step := [1]tape.Step{tape.Name(key_str)}
					if !subcheck_node(h, doc, vn, pat.record, step[:], owner, quiet = !emit) {
						ok = false
						if !emit {
							if key_owned {
								delete(key_str, h.scratch)
							}
							return false
						}
					}
				}
			}
			if !matched && ap.additional >= 0 {
				step := [1]tape.Step{tape.Name(key_str)}
				if !subcheck_node(h, doc, vn, ap.additional, step[:], owner, quiet = !emit) {
					ok = false
					if !emit {
						if key_owned {
							delete(key_str, h.scratch)
						}
						return false
					}
				}
			}
			if key_owned {
				delete(key_str, h.scratch)
			}
		}
		return ok
	case .Names:
		if k != .Object {
			return true
		}
		ok := true
		it, p, cerr := tape.children(r, node, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return false
		}
		defer tape.destroy_children(&it)
		if p != .Found {
			return true
		}
		for {
			kn, _, cp := tape.next_child(r, &it, h.dups)
			if cp != .Found {
				break
			}
			if !charge_step_one(h) {
				return false
			}
			kt := tape.cell_key(r, it) if (kn == tape.NO_NODE && it.keys_n != 0) else doc.nodes[kn]
			key_str, key_owned, kok := doc_token_text(doc, kt, h.scratch)
			if !kok {
				h.fatal = .No_Memory
				return false
			}
			res := subcheck_key_string(h, key_str, doc, ap.record, owner, quiet = !emit)
			if key_owned {
				delete(key_str, h.scratch)
			}
			if !res {
				ok = false
				if !emit {
					return false
				}
			}
		}
		return ok
	case .Contains:
		if k != .Array {
			return true
		}
		hits := u64(0)
		it, p, cerr := tape.children(r, node, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return false
		}
		defer tape.destroy_children(&it)
		if p == .Found {
			for {
				_, ch, cp := tape.next_child(r, &it)
				if cp != .Found {
					break
				}
				if !charge_step_one(h) {
					return false
				}
				if subcheck_node(h, doc, ch, ap.record, nil, owner, quiet = true) {
					hits += 1
				}
				if h.fatal != .None {
					return false
				}
			}
		}
		if hits < ap.min_contains {
			kw := "minContains" if ap.min_contains > 1 else "contains"
			if emit {
				record_failure(h, .Too_Few, at, kw, "", owner)
			} else {
				record_first_failure(h, .Too_Few, at, kw, "", owner)
			}
			return false
		}
		if hits > ap.max_contains {
			if emit {
				record_failure(h, .Too_Many, at, "maxContains", "", owner)
			} else {
				record_first_failure(h, .Too_Many, at, "maxContains", "", owner)
			}
			return false
		}
		return true
	case .Unique:
		if k != .Array {
			return true
		}
		return check_unique_items(h, doc, node, owner, at, emit)
	case .Const:
		val := rules.Value(rules.Node_Ref{doc = doc, node = node})
		eq, eerr := rules.value_equal(val, ap.operands[0], h.dups, h.scratch)
		if eerr != nil {
			h.fatal = .No_Memory
			return false
		}
		if !eq {
			if emit {
				record_failure(h, .Not_A_Member, at, "const", "", owner)
			} else {
				record_first_failure(h, .Not_A_Member, at, "const", "", owner)
			}
			return false
		}
		return true
	case .Enum:
		val := rules.Value(rules.Node_Ref{doc = doc, node = node})
		for op_v in ap.operands {
			eq, eerr := rules.value_equal(val, op_v, h.dups, h.scratch)
			if eerr != nil {
				h.fatal = .No_Memory
				return false
			}
			if eq {
				return true
			}
		}
		if emit {
			record_failure(h, .Not_A_Member, at, "enum", "", owner)
		} else {
			record_first_failure(h, .Not_A_Member, at, "enum", "", owner)
		}
		return false
	case .Unevaluated_Properties:
		if k != .Object {
			return true
		}
		return eval_unevaluated_properties(h, doc, node, owner, ap, emit)
	case .Unevaluated_Items:
		if k != .Array {
			return true
		}
		return eval_unevaluated_items(h, doc, node, owner, ap, emit)
	}
	return true
}

@(private = "file")
object_has_key :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, want: string) -> bool {
	_, p := tape.member(tape.Reader{doc = doc}, node, want, h.dups)
	return p == .Found
}

// Checks `uniqueItems` on array `node`: zero-alloc stack hash table fast path for `<= 32` unescaped strings,
// falling back to exact `rules.value_hash` + `rules.value_equal` for general / larger arrays.
@(private = "file")
check_unique_items :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, at: u64, emit: bool) -> bool #no_bounds_check {
	r := tape.Reader{doc = doc}
	// Fast zero-alloc path for small plain-string arrays (e.g. `deno` `lint`/`fmt`, `draft-04` `required`/`enum`)!
	if h.budget.steps == 0 && doc.format != nil && .Binary not_in doc.format.caps {
		it0, p0, cerr0 := tape.children(r, node, h.scratch)
		if cerr0 != nil {
			h.fatal = .No_Memory
			return false
		}
		if p0 != .Found {
			tape.destroy_children(&it0)
			return true
		}
		slots: [64]u32 // zero-initialized: 0 = empty, 1 + i = index into `items`
		items: [32]string = ---
		n := 0
		fast_ok := true
		for {
			_, ch, cp := tape.next_child(r, &it0)
			if cp != .Found {
				break
			}
			tok := doc.nodes[ch]
			if tok.kind != .String || (tok.spelling & tape.SPELLING_DECODE != 0) || n >= 32 {
				fast_ok = false
				break
			}
			s := string(doc.src[tok.lo:][:tok.n])
			hv := member_hash(s) & 63
			for {
				slot := slots[hv]
				if slot == 0 {
					slots[hv] = u32(n + 1)
					items[n] = s
					n += 1
					break
				}
				if items[slot - 1] == s {
					tape.destroy_children(&it0)
					if emit {
						record_failure(h, .Not_Unique, at, "uniqueItems", "", owner)
					} else {
						record_first_failure(h, .Not_Unique, at, "uniqueItems", "", owner)
					}
					return false
				}
				hv = (hv + 1) & 63
			}
		}
		tape.destroy_children(&it0)
		if fast_ok {
			return true
		}
	}

	cnt, _, lerr := tape.length(r, node, h.scratch)
	if lerr != nil {
		h.fatal = .No_Memory
		return false
	}
	if cnt <= 1 {
		return true
	}
	buckets, berr := make(map[u64][dynamic]tape.Node_Index, cnt, h.scratch)
	if berr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer {
		for _, list in buckets {
			delete(list)
		}
		delete(buckets)
	}
	it, p, cerr := tape.children(r, node, h.scratch)
	if cerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer tape.destroy_children(&it)
	if p != .Found {
		return true
	}
	for {
		_, ch, cp := tape.next_child(r, &it)
		if cp != .Found {
			break
		}
		if !charge_step_one(h) {
			return false
		}
		val := rules.Value(rules.Node_Ref{doc = doc, node = ch})
		hv, herr := rules.value_hash(val, h.dups, h.scratch)
		if herr != nil {
			h.fatal = .No_Memory
			return false
		}
		if prevs, exists := &buckets[hv]; exists {
			for pnode in prevs^ {
				eq, eerr := rules.value_equal(val, rules.Value(rules.Node_Ref{doc = doc, node = pnode}), h.dups, h.scratch)
				if eerr != nil {
					h.fatal = .No_Memory
					return false
				}
				if eq {
					if emit {
						record_failure(h, .Not_Unique, at, "uniqueItems", "", owner)
					} else {
						record_first_failure(h, .Not_Unique, at, "uniqueItems", "", owner)
					}
					return false
				}
			}
			if _, aerr := append(prevs, ch); aerr != nil {
				h.fatal = .No_Memory
				return false
			}
		} else {
			list, lerr2 := make([dynamic]tape.Node_Index, 0, 2, h.scratch)
			if lerr2 != nil {
				h.fatal = .No_Memory
				return false
			}
			if _, aerr := append(&list, ch); aerr != nil {
				delete(list)
				h.fatal = .No_Memory
				return false
			}
			if _, _, _, merr := map_entry(&buckets, hv); merr != nil {
				delete(list)
				h.fatal = .No_Memory
				return false
			}
			buckets[hv] = list
		}
	}
	return true
}

// Runtime evaluation of `unevaluatedProperties` using `ap.evals` (`Evaluates`).
@(private = "file")
eval_unevaluated_properties :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, ap: ^Apply, emit: bool) -> bool {
	ev_names, nerr := make(map[string]bool, 16, h.scratch)
	if nerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer delete(ev_names)
	ev_pats := make([dynamic]^regex.Regex, h.scratch)
	defer delete(ev_pats)
	vis, verr := make(map[^Evaluates]bool, 16, h.scratch)
	if verr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer delete(vis)
	all_eval := false
	gather_runtime_eval_props(h, doc, node, ap.evals, &vis, &all_eval, &ev_names, &ev_pats)
	if h.fatal != .None {
		return false
	}
	if all_eval {
		return true
	}
	ok := true
	r := tape.Reader{doc = doc}
	it, p, cerr := tape.children(r, node, h.scratch)
	if cerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer tape.destroy_children(&it)
	if p != .Found {
		return true
	}
	for {
		kn, vn, cp := tape.next_child(r, &it, h.dups)
		if cp != .Found {
			break
		}
		if !charge_step_one(h) {
			return false
		}
		kt := tape.cell_key(r, it) if (kn == tape.NO_NODE && it.keys_n != 0) else doc.nodes[kn]
		key_str, key_owned, kok := doc_token_text(doc, kt, h.scratch)
		if !kok {
			h.fatal = .No_Memory
			return false
		}
		evaluated := ev_names[key_str]
		if !evaluated {
			for re in ev_pats {
				found, rok := run_regex_search(h, re, key_str)
				if !rok {
					if key_owned {
						delete(key_str, h.scratch)
					}
					return false
				}
				if found {
					evaluated = true
					break
				}
			}
		}
		if !evaluated {
			step := [1]tape.Step{tape.Name(key_str)}
			res := subcheck_node(h, doc, vn, ap.record, step[:], owner, quiet = !emit)
			if key_owned {
				delete(key_str, h.scratch)
			}
			if !res {
				ok = false
				if !emit {
					return false
				}
			}
		} else if key_owned {
			delete(key_str, h.scratch)
		}
	}
	return ok
}

@(private = "file")
gather_runtime_eval_props :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, ev: ^Evaluates, vis: ^map[^Evaluates]bool, all_eval: ^bool, names: ^map[string]bool, pats: ^[dynamic]^regex.Regex) {
	if ev == nil || all_eval^ || h.fatal != .None || vis[ev] {
		return
	}
	vis[ev] = true
	if ev.all_members {
		all_eval^ = true
		return
	}
	for nm in ev.names {
		names[nm] = true
	}
	for re in ev.patterns {
		append(pats, re)
	}
	for sub in ev.refs {
		gather_runtime_eval_props(h, doc, node, sub, vis, all_eval, names, pats)
	}
	for inn in ev.inner {
		if all_eval^ || h.fatal != .None {
			return
		}
		switch inn.kind {
		case .Any:
			for arm_rec, i in inn.arms {
				if subcheck_node(h, doc, node, arm_rec, nil, nil, quiet = true) {
					gather_runtime_eval_props(h, doc, node, inn.evals[i], vis, all_eval, names, pats)
				}
				if h.fatal != .None {
					return
				}
			}
		case .One:
			// B-H6: `oneOf` ONLY exports annotations when EXACTLY ONE arm passes!
			hits := 0
			hit_idx := -1
			for arm_rec, i in inn.arms {
				if subcheck_node(h, doc, node, arm_rec, nil, nil, quiet = true) {
					hits += 1
					hit_idx = i
				}
				if h.fatal != .None {
					return
				}
			}
			if hits == 1 {
				gather_runtime_eval_props(h, doc, node, inn.evals[hit_idx], vis, all_eval, names, pats)
			}
		case .If:
			cond_ok := subcheck_node(h, doc, node, inn.test, nil, nil, quiet = true)
			if h.fatal != .None {
				return
			}
			if cond_ok {
				gather_runtime_eval_props(h, doc, node, inn.test_eval, vis, all_eval, names, pats)
				if inn.then >= 0 && subcheck_node(h, doc, node, inn.then, nil, nil, quiet = true) {
					gather_runtime_eval_props(h, doc, node, inn.then_eval, vis, all_eval, names, pats)
				}
			} else if inn.other >= 0 && subcheck_node(h, doc, node, inn.other, nil, nil, quiet = true) {
				gather_runtime_eval_props(h, doc, node, inn.other_eval, vis, all_eval, names, pats)
			}
		case .Dependent:
			if object_has_key(h, doc, node, inn.name) {
				if subcheck_node(h, doc, node, inn.body, nil, nil, quiet = true) {
					gather_runtime_eval_props(h, doc, node, inn.body_eval, vis, all_eval, names, pats)
				}
			}
		case .Contains:
			// Does not apply to object properties.
		}
	}
}

// Runtime evaluation of `unevaluatedItems` using `ap.evals` (`Evaluates`).
@(private = "file")
eval_unevaluated_items :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, ap: ^Apply, emit: bool) -> bool {
	r := tape.Reader{doc = doc}
	cnt, _, lerr := tape.length(r, node, h.scratch)
	if lerr != nil {
		h.fatal = .No_Memory
		return false
	}
	if cnt <= 0 {
		return true
	}
	all_eval := false
	prefix_max := 0
	eval_bits, eerr := make([]bool, cnt, h.scratch)
	if eerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer delete(eval_bits, h.scratch)
	vis, verr := make(map[^Evaluates]bool, 16, h.scratch)
	if verr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer delete(vis)
	gather_runtime_eval_items(h, doc, node, ap.evals, &vis, &all_eval, &prefix_max, eval_bits)
	if h.fatal != .None {
		return false
	}
	if all_eval || prefix_max >= cnt {
		return true
	}
	ok := true
	it, p, cerr := tape.children(r, node, h.scratch)
	if cerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer tape.destroy_children(&it)
	if p != .Found {
		return true
	}
	idx := 0
	for {
		_, ch, cp := tape.next_child(r, &it)
		if cp != .Found {
			break
		}
		if !charge_step_one(h) {
			return false
		}
		if idx >= prefix_max && !eval_bits[idx] {
			step := [1]tape.Step{tape.Index(idx)}
			if !subcheck_node(h, doc, ch, ap.record, step[:], owner, quiet = !emit) {
				ok = false
				if !emit {
					return false
				}
			}
		}
		idx += 1
	}
	return ok
}

@(private = "file")
gather_runtime_eval_items :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, ev: ^Evaluates, vis: ^map[^Evaluates]bool, all_eval: ^bool, prefix_max: ^int, eval_bits: []bool) {
	if ev == nil || all_eval^ || h.fatal != .None || vis[ev] {
		return
	}
	vis[ev] = true
	if ev.all_items {
		all_eval^ = true
		return
	}
	if ev.items > prefix_max^ {
		prefix_max^ = ev.items
	}
	for sub in ev.refs {
		gather_runtime_eval_items(h, doc, node, sub, vis, all_eval, prefix_max, eval_bits)
	}
	for inn in ev.inner {
		if all_eval^ || h.fatal != .None {
			return
		}
		switch inn.kind {
		case .Any:
			for arm_rec, i in inn.arms {
				if subcheck_node(h, doc, node, arm_rec, nil, nil, quiet = true) {
					gather_runtime_eval_items(h, doc, node, inn.evals[i], vis, all_eval, prefix_max, eval_bits)
				}
				if h.fatal != .None {
					return
				}
			}
		case .One:
			// B-H6: `oneOf` ONLY exports annotations when EXACTLY ONE arm passes!
			hits := 0
			hit_idx := -1
			for arm_rec, i in inn.arms {
				if subcheck_node(h, doc, node, arm_rec, nil, nil, quiet = true) {
					hits += 1
					hit_idx = i
				}
				if h.fatal != .None {
					return
				}
			}
			if hits == 1 {
				gather_runtime_eval_items(h, doc, node, inn.evals[hit_idx], vis, all_eval, prefix_max, eval_bits)
			}
		case .If:
			cond_ok := subcheck_node(h, doc, node, inn.test, nil, nil, quiet = true)
			if h.fatal != .None {
				return
			}
			if cond_ok {
				gather_runtime_eval_items(h, doc, node, inn.test_eval, vis, all_eval, prefix_max, eval_bits)
				if inn.then >= 0 && subcheck_node(h, doc, node, inn.then, nil, nil, quiet = true) {
					gather_runtime_eval_items(h, doc, node, inn.then_eval, vis, all_eval, prefix_max, eval_bits)
				}
			} else if inn.other >= 0 && subcheck_node(h, doc, node, inn.other, nil, nil, quiet = true) {
				gather_runtime_eval_items(h, doc, node, inn.other_eval, vis, all_eval, prefix_max, eval_bits)
			}
		case .Contains:
			// B-H6: `contains` ONLY exports evaluated item annotations when `minContains <= hits <= maxContains`!
			r := tape.Reader{doc = doc}
			it, p, cerr := tape.children(r, node, h.scratch)
			if cerr != nil {
				h.fatal = .No_Memory
				return
			}
			defer tape.destroy_children(&it)
			if p == .Found {
				matched := make([dynamic]int, h.scratch)
				defer delete(matched)
				idx := 0
				for {
					_, ch, cp := tape.next_child(r, &it)
					if cp != .Found {
						break
					}
					if subcheck_node(h, doc, ch, inn.body, nil, nil, quiet = true) {
						append(&matched, idx)
					}
					if h.fatal != .None {
						return
					}
					idx += 1
				}
				hits := u64(len(matched))
				if hits >= inn.min_contains && hits <= inn.max_contains {
					for m_idx in matched {
						if m_idx < len(eval_bits) {
							eval_bits[m_idx] = true
						}
					}
				}
			}
		case .Dependent:
			// Does not apply to array items.
		}
	}
}
