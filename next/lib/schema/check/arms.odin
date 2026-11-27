// Held-value applicators (`Apply`), `Pool`/`Held_Capture` runtime, and `build.Builder` capture
// for `uniqueItems`, container `const`/`enum`, `unevaluatedProperties`, `unevaluatedItems`,
// `dependentSchemas`, `patternProperties`, `contains`, `allOf`, `anyOf`, `oneOf`, `not`, and `if/then/else`.
package check

import "base:runtime"
import "core:slice"
import "stury:lib/base/regex"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/schema/rules"

@(private)
Apply_Kind :: enum u8 {
	Own,
	Ref,
	All,
	Any,
	One,
	Not,
	If,
	Dependent,
	Patterns,
	Names,
	Contains,
	Unique,
	Const,
	Enum,
	Unevaluated_Properties,
	Unevaluated_Items,
}

@(private)
Apply_Pattern :: struct {
	expression: string,
	regex:      ^regex.Regex,
	record:     i32,
}

@(private)
Apply_Dependent :: struct {
	name:    string,
	record:  i32,
	keyword: string,
}

@(private)
Apply :: struct {
	kind:          Apply_Kind,
	keyword:       string,
	record:        i32,
	arms:          []i32,
	test:          i32,
	then_rec:      i32,
	else_rec:      i32,
	patterns:      []Apply_Pattern,
	named:         []string,
	additional:    i32,
	dependents:    []Apply_Dependent,
	min_contains:  u64,
	max_contains:  u64,
	eval_contains: bool,
	operands:      []rules.Value,
	evals:         ^Evaluates,
}

@(private)
arm_operands :: proc "contextless" (n: ^rules.Node) -> bool {
	if c, has := n.const_of.?; has {
		if k := rules.value_kind(c); k == .Object || k == .Array { return true }
	}
	if n.has_enum {
		for v in n.enum_of {
			if k := rules.value_kind(v); k == .Object || k == .Array { return true }
		}
	}
	return false
}

@(private)
holds :: proc(b: ^Builder, d: ^rules.Description, node: rules.Node_Index, edge: rules.Rules) -> bool {
	if node == rules.NONE { return false }
	n := &d.nodes[node]
	if len(n.all_of) > 0 || len(n.any_of) > 0 || len(n.one_of) > 0 || n.not != nil || (n.cond.test != nil && (n.cond.then != nil || n.cond.other != nil)) || n.ref != nil || n.dynamic_ref != nil || n.unevaluated_items != nil || n.unevaluated_properties != nil || n.rules.unique || edge.unique || arm_operands(n) {
		return true
	}
	if n.array >= 0 && d.arrays[n.array].contains != nil { return true }
	if n.object >= 0 {
		o := &d.objects[n.object]
		if len(o.patterns) > 0 && n.object not_in b.inline { return true }
		for dep in o.dependents {
			if dep.node != nil { return true }
		}
		saved_ks := b.scope
		keys := resolve_end(b, d, b.arena, o.keys)
		key_held := keys != rules.NONE && holds(b, d, keys, {})
		b.scope = saved_ks
		if key_held { return true }
	}
	return false
}

@(private = "file")
site_hash :: proc "contextless" (site: []tape.Step) -> u64 {
	if len(site) == 0 { return 0 }
	h := u64(0x9E3779B97F4A7C15)
	for s in site {
		#partial switch v in s {
		case tape.Name:  h = (h ~ u64(tape.text_hash(transmute([]u8)string(v))) ~ 1) * 0xBF58476D1CE4E5B9
		case tape.Index: h = (h ~ u64(v) ~ 2) * 0xBF58476D1CE4E5B9
		}
	}
	return h
}

// Allocates (or reuses via `b.arm_cache` for cyclic `$ref`s) a standalone `Checked` record for an arm's subschema.
@(private)
arm_record :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, site: []tape.Step, edge: rules.Rules = {}, bare := false) -> i32 {
	cache_key := Arm_Key{node = node, scope = b.scope, bare = bare, site_tag = site_hash(site)}
	if edge == {} {
		if existing, ok := b.arm_cache[cache_key]; ok { return existing }
	}
	at, _ := block_of(b, 2, {})
	if at < 0 { return 0 }
	if edge == {} { b.arm_cache[cache_key] = at }
	never(b, int(at) + 1)
	fill_checked(b, d, arena, int(at), node, "", edge, site, bare = bare)
	return at
}

// Compiles `Use.applies` (full errors mode) and `Use.verdict` (optional conjoined fast path) for held node `node`.
@(private)
checked_applies :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, node: rules.Node_Index, edge: rules.Rules) -> (applies: []Apply, verdict: []Apply) {
	push_ref :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, list: ^[dynamic]Apply, target: rules.Node_Index, kw: string) {
		site := [1]tape.Step{tape.Name(kw)}
		saved := b.scope
		enter_scope(b, d, arena, target)
		rec := arm_record(b, d, arena, target, site[:])
		b.scope = saved
		append(list, Apply{kind = .Ref, keyword = kw, record = rec})
	}
	push_arms :: proc(b: ^Builder, d: ^rules.Description, arena: runtime.Allocator, list: ^[dynamic]Apply, kind: Apply_Kind, kw: string, nodes: []rules.Node_Index) -> bool {
		if len(nodes) == 0 { return true }
		arms, err := make([]i32, len(nodes), arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return false
		}
		for a, i in nodes {
			site := [2]tape.Step{tape.Name(kw), tape.Index(i)}
			arms[i] = arm_record(b, d, arena, a, site[:])
		}
		append(list, Apply{kind = kind, keyword = kw, arms = arms})
		return true
	}

	n := &d.nodes[node]
	list := make([dynamic]Apply, arena)

	if has_own_keywords(b, d, n, edge) {
		append(&list, Apply{kind = .Own, record = arm_record(b, d, arena, node, nil, edge, bare = true)})
	}
	if r, has := n.ref.?; has { push_ref(b, d, arena, &list, r, rules.ref_keyword(n)) }
	if dr, has := n.dynamic_ref.?; has {
		push_ref(b, d, arena, &list, dynamic_target(b, d, n, dr), rules.dynamic_keyword(n))
	}
	if !push_arms(b, d, arena, &list, .All, "allOf", n.all_of) || !push_arms(b, d, arena, &list, .Any, "anyOf", n.any_of) || !push_arms(b, d, arena, &list, .One, "oneOf", n.one_of) {
		return nil, nil
	}
	if nt, has := n.not.?; has {
		site := [1]tape.Step{tape.Name("not")}
		append(&list, Apply{kind = .Not, keyword = "not", record = arm_record(b, d, arena, nt, site[:])})
	}
	if test, has := n.cond.test.?; has && (n.cond.then != nil || n.cond.other != nil) {
		if_s, th_s, el_s := [1]tape.Step{tape.Name("if")}, [1]tape.Step{tape.Name("then")}, [1]tape.Step{tape.Name("else")}
		then_rec := arm_record(b, d, arena, n.cond.then.?, th_s[:]) if n.cond.then != nil else -1
		else_rec := arm_record(b, d, arena, n.cond.other.?, el_s[:]) if n.cond.other != nil else -1
		append(&list, Apply{kind = .If, keyword = "if", test = arm_record(b, d, arena, test, if_s[:]), then_rec = then_rec, else_rec = else_rec})
	}
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
				pats[i] = {expression = expr, regex = re, record = arm_record(b, d, arena, p.node, site[:])}
			}
			named := make([dynamic]string, arena)
			for m in o.members {
				if !m.only_required { append(&named, clone_str(b, arena, m.name)) }
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
				append(&deps, Apply_Dependent{name = nm, record = arm_record(b, d, arena, dn, site[:]), keyword = kw})
			}
		}
		if len(deps) > 0 {
			append(&list, Apply{kind = .Dependent, keyword = kw, dependents = deps[:]})
		}
		saved_ks := b.scope
		keys := resolve_end(b, d, arena, o.keys)
		b.scope = saved_ks
		if keys != rules.NONE && holds(b, d, keys, {}) {
			site := [1]tape.Step{tape.Name("propertyNames")}
			append(&list, Apply{kind = .Names, keyword = "propertyNames", record = arm_record(b, d, arena, o.keys, site[:])})
		}
	}
	if n.array >= 0 {
		a := &d.arrays[n.array]
		if c, has := a.contains.?; has {
			site := [1]tape.Step{tape.Name("contains")}
			append(&list, Apply{
				kind = .Contains,
				keyword = "contains",
				record = arm_record(b, d, arena, c, site[:]),
				min_contains = a.min_contains.? or_else 1,
				max_contains = a.max_contains.? or_else max(u64),
				eval_contains = a.evaluates_contains,
			})
		}
	}
	if n.rules.unique || edge.unique {
		append(&list, Apply{kind = .Unique, keyword = "uniqueItems"})
	}
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
	if up, has := n.unevaluated_properties.?; has {
		append(&list, Apply{kind = .Unevaluated_Properties, keyword = "unevaluatedProperties", record = arm_record(b, d, arena, up, UNEVALUATED_PROPERTIES[:]), evals = evaluates(b, d, arena, node, skip_own_uneval = true)})
	}
	if ui, has := n.unevaluated_items.?; has {
		append(&list, Apply{kind = .Unevaluated_Items, keyword = "unevaluatedItems", record = arm_record(b, d, arena, ui, UNEVALUATED_ITEMS[:]), evals = evaluates(b, d, arena, node, skip_own_uneval = true)})
	}

	applies = list[:]
	if conj := conjoin_verdict(b, d, arena, b.tables, node, edge); conj != rules.NONE {
		v_list, err := make([]Apply, 1, arena)
		if err != nil {
			refuse_plan(b, .No_Memory)
			return applies, nil
		}
		v_list[0] = Apply{kind = .Own, record = arm_record(b, d, arena, conj, nil)}
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
	if clash != "" || r.minimum != "" || r.maximum != "" || r.multiple_of != "" || r.pattern != "" || (r.assert_format && !r.format_foreign && rules.format_of(r.format) != .None) || (edge.assert_format && !edge.format_foreign && rules.format_of(edge.format) != .None) || r.min_length > 0 || r.max_length != nil || r.min_items > 0 || r.max_items != nil || r.min_members > 0 || r.max_members != nil {
		return true
	}
	if n.array >= 0 && (len(d.arrays[n.array].prefix) > 0 || d.arrays[n.array].items != rules.NONE) {
		return true
	}
	if n.object >= 0 {
		o := &d.objects[n.object]
		if len(o.members) > 0 || o.additional != rules.NONE || o.keys != rules.NONE || n.object in b.inline {
			return true
		}
		for dep in o.dependents {
			if len(dep.required) > 0 { return true }
		}
	}
	return false
}

// ============================================================================
// Runtime `Pool` & `Held_Capture` (captures held values via v2 `build.Builder`)
// ============================================================================

@(private)
Pool :: struct {
	allocator: runtime.Allocator,
	factored:  [dynamic]Factored_Open,
	seen_wide: [dynamic][]u64,
	captures:  [MAX_HELD_CAPTURES]^Held_Capture,
}

@(private)
pool_destroy :: proc(p: ^Pool) {
	if p == nil { return }
	for c in p.captures {
		if c != nil { free(c, p.allocator) }
	}
	for sw in p.seen_wide {
		delete(sw, p.allocator)
	}
	delete(p.seen_wide)
	delete(p.factored)
	p^ = {}
}

@(private)
pool_seen_wide :: proc(h: ^Checker, p: ^Pool, depth, words: int) -> []u64 {
	if depth >= len(p.seen_wide) && resize(&p.seen_wide, depth + 1) != nil {
		h.fatal = .No_Memory
		return nil
	}
	slot := &p.seen_wide[depth]
	if len(slot^) < words {
		delete(slot^, p.allocator)
		buf, err := make([]u64, words, p.allocator)
		if err != nil {
			slot^ = nil
			h.fatal = .No_Memory
			return nil
		}
		slot^ = buf
	} else {
		slice.zero(slot^[:words])
	}
	return slot^[:words]
}

@(private)
pool_capture_slot :: proc(h: ^Checker, idx: int) -> ^Held_Capture {
	pool := pool_ensure(h)
	if pool == nil { return nil }
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
	if h.pool != nil { return h.pool }
	p, err := new(Pool, h.scratch)
	if err != nil {
		h.fatal = .No_Memory
		return nil
	}
	p^ = {allocator = h.scratch}
	p.factored.allocator = h.scratch
	p.seen_wide.allocator = h.scratch
	h.pool, h.owns_pool = p, true
	return p
}

@(private)
Held_Capture :: struct {
	builder:       build.Builder,
	regs:          hook.Regs,
	stack_buf:     [16]u64,
	counts_buf:    [8]tape.Child_Count,
	owner:         ^Record,
	open_at:       u64,
	saved_b:       u64,
	depth:         int,
	for_factor:    bool,
	for_arr_elem:  bool,
	factor_member: ^Factor_Member,
	active:        bool,
}

@(private)
capture_start :: proc(h: ^Checker, owner: ^Record, at: u64, saved_b: u64, for_factor := false, fm: ^Factor_Member = nil, for_arr_elem := false) -> bool {
	if h.capture_depth >= MAX_HELD_CAPTURES {
		h.fatal = .Exceeded
		return false
	}
	cap_slot := pool_capture_slot(h, h.capture_depth)
	if cap_slot == nil { return false }
	cap_slot^ = {owner = owner, open_at = at, saved_b = saved_b, for_factor = for_factor, for_arr_elem = for_arr_elem, factor_member = fm, active = true}
	most := int(max(u32) / 4)
	if h.budget.nodes > 0 {
		if h.nodes_seen >= u64(h.budget.nodes) {
			h.fatal = .Exceeded
			return false
		}
		most = max(1, int(u64(h.budget.nodes) - h.nodes_seen))
	}
	build.builder_start(&cap_slot.builder, h.src, h.format, nodes = 16, most = most, frames = cap_slot.stack_buf[:], allocator = h.scratch, budget = h.mem_budget, counts_buf = cap_slot.counts_buf[:], scratch = h.scratch)
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
	if t.role == .Value {
		if t.kind == .Object || t.kind == .Array {
			c.depth += 1
		} else if t.kind == .End {
			c.depth -= 1
		}
	}
	if t.role <= .Key && t.kind != .End {
		if uintptr(c.regs.a) == hook.rooms_end(&c.builder) && !hook.rooms_grow(&c.builder, &c.regs, t.lo) {
			h.fatal = .Exceeded if c.builder.full != 0 else .No_Memory
			capture_abort(h)
			return true, false
		}
		if t.kind > .Plain && int(c.regs.c) >= hook.levels_held(&c.builder) && !hook.levels_grow(&c.builder, int(c.regs.c) + 1, &c.regs, t.lo) {
			h.fatal = .No_Memory
			capture_abort(h)
			return true, false
		}
	}
	act: hook.Action
	c.regs, act = build.builder_hook_kept(&c.builder, c.regs, t)
	if act == .Stop || c.builder.err != nil {
		h.fatal = .Exceeded if c.builder.full != 0 else .No_Memory
		capture_abort(h)
		return true, false
	}
	return c.depth == 0, true
}

@(private)
capture_abort :: proc(h: ^Checker) {
	if h.capture_depth <= 0 { return }
	h.capture_depth -= 1
	c := h.pool.captures[h.capture_depth]
	doc, _ := build.builder_end(&c.builder, c.regs, 0, nil)
	tape.destroy(&doc)
	c.active = false
}

// Evaluates a multi-choice factored container member (`fm.leaves` + `fm.choices`) on `doc` at `node`.
@(private)
eval_factored_fork_node :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, fo_idx: int, fm: ^Factor_Member) -> (doomed: bool) {
	fo := factored_at(h, fo_idx)
	fo.active_member, fo.active_choice = nil, -1
	if fm != nil {
		root_k := doc.nodes[node].kind
		cnt_i, _, _ := tape.length(tape.Reader{doc = doc}, node, h.scratch)
		cnt := u64(max(cnt_i, 0))
		collect := fo.collect_errors
		at := doc.nodes[node].lo
		is_obj := fo.factor.arr == nil
		cur_key := h.frames[h.sp - 1].key_name if (is_obj && h.sp > 0) else ""
		cur_owned := h.frames[h.sp - 1].key_owned if (is_obj && h.sp > 0) else false
		elem_idx := fo.seen_count - 1 if !is_obj else 0
		rec_first := !collect && factored_can_record_first(h, fo)

		for fl in fm.leaves {
			if !charge_step_one(h) { return true }
			l := &h.plan.leaves[fl.leaf - 1]
			fails: rules.Failures
			if root_k == .Object || root_k == .Array {
				want := rules.Kind.Object if root_k == .Object else rules.Kind.Array
				if want not_in l.kinds || l.has_enum {
					fails += {.Wrong_Kind} if want not_in l.kinds else {.Not_A_Member}
				}
				fails += rules.judge_count(cnt, l.min_members, l.max_members) if root_k == .Object else rules.judge_count(cnt, l.min_items, l.max_items)
			}
			if fails != {} {
				fo.failed |= fl.parts
				if (fl.parts & ~fo.factor.no_emit_mask) != 0 {
					factored_note_leaf_fails(h, fo, l, fails, at, root_k == .Object, fl.sites, 0, cur_key, cur_owned, elem_idx, true, &rec_first)
					if h.fatal != .None { return true }
					fo = factored_at(h, fo_idx)
				}
			}
		}

		for ch in fm.choices {
			if !charge_step_one(h) { return true }
			fo = factored_at(h, fo_idx)
			if !collect && fo.factor.monotone && (ch.parts & ~fo.failed) == 0 { continue }
			guard: Choice_Sink_Guard
			mark, outer_kw_len: int
			if collect { guard, mark, outer_kw_len = choice_sink_enter(h, fo, fo_idx) }
			passed := subcheck_node(h, doc, node, ch.record, nil, fo.owner if collect else nil, quiet = !collect)
			if collect { choice_sink_leave(h, guard) }
			fo = factored_at(h, fo_idx)
			if !passed {
				fo.failed |= ch.parts
				if collect {
					if end := len(fo.choice_sink.entries); end > mark {
						factored_buf_err(h, fo, Factored_Err{
							kind = .Choice_Span,
							no_emit_mask = fo.factor.no_emit_mask,
							choice_from = mark,
							choice_to = end,
							base_kw_len = outer_kw_len,
							sites = ch.sites,
						})
					}
				}
			}
			if h.fatal != .None { return true }
		}
	}
	fo = factored_at(h, fo_idx)
	return can_doom_factored(h, fo.factor, fo.failed)
}

@(private)
capture_finish :: proc(h: ^Checker) -> bool {
	h.capture_depth -= 1
	c := h.pool.captures[h.capture_depth]
	doc, berr := build.builder_end(&c.builder, c.regs, 0, nil)
	saved_ext := doc.ext
	if h.xml_ext != nil && saved_ext == nil { doc.ext = h.xml_ext }
	adopted := false
	defer if !adopted {
		if saved_ext == nil && doc.ext == h.xml_ext { doc.ext = nil }
		tape.destroy(&doc)
	}
	c.active = false
	if berr != nil {
		_, is_ex := berr.(tape.Exceeded)
		h.fatal = .Exceeded if is_ex else .No_Memory
		return false
	}
	if c.for_arr_elem {
		ok: bool
		ok, adopted = factored_arr_finish_elem_capture(h, doc, c.owner, h.nf - 1, c.factor_member, c.open_at)
		return ok
	}
	if c.for_factor { return !eval_factored_fork_node(h, &doc, 0, h.nf - 1, c.factor_member) }
	return eval_held_node(h, &doc, 0, c.owner, c.open_at)
}

@(private)
eval_held_node :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, at: u64) -> bool {
	if h.fatal != .None || !charge_step_one(h) { return false }
	u := &h.plan.uses[owner.meta]
	applies := u.verdict if (h.sink == nil || h.quiet) && len(u.verdict) > 0 else u.applies
	all_ok := true
	emit := h.sink != nil && !h.quiet

	for &ap in applies {
		if h.fatal != .None { return false }
		if !eval_apply(h, doc, node, owner, &ap, at, emit) {
			all_ok = false
			if !emit { return false }
		}
	}
	return all_ok
}

@(private = "file")
child_key_text :: proc(h: ^Checker, doc: ^tape.Document, r: tape.Reader, it: tape.Children, kn: tape.Node_Index) -> (string, bool, bool) {
	kt := tape.cell_key(r, it) if (kn == tape.NO_NODE && it.keys_n != 0) else doc.nodes[kn]
	ks, owned, ok := doc_token_text(doc, kt, h.scratch)
	if !ok { h.fatal = .No_Memory }
	return ks, owned, ok
}

@(private = "file")
eval_apply :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, ap: ^Apply, at: u64, emit: bool) -> bool {
	k := doc.nodes[node].kind
	r := tape.Reader{doc = doc}
	switch ap.kind {
	case .Own, .Ref:
		return subcheck_node(h, doc, node, ap.record, nil, owner, quiet = h.quiet)
	case .All:
		ok := true
		for rec in ap.arms {
			if !charge_step_one(h) { return false }
			if !subcheck_node(h, doc, node, rec, nil, owner, quiet = h.quiet) {
				ok = false
				if !emit { return false }
			}
		}
		return ok
	case .Any, .One:
		is_one := ap.kind == .One
		hits := 0
		for rec in ap.arms {
			if !charge_step_one(h) { return false }
			if subcheck_node(h, doc, node, rec, nil, owner, quiet = true) {
				hits += 1
				if !is_one { return true }
				if hits > 1 && !emit {
					record_first_failure(h, .Many_Arms, at, "oneOf", "", owner)
					return false
				}
			}
			if h.fatal != .None { return false }
		}
		if is_one && hits == 1 { return true }
		kind := Error_Kind.No_Arm if hits == 0 else Error_Kind.Many_Arms
		kw := "oneOf" if is_one else "anyOf"
		if emit && hits == 0 {
			for rec in ap.arms {
				subcheck_node(h, doc, node, rec, nil, owner, quiet = false)
			}
		}
		emit_or_first(h, kind, at, kw, "", owner)
		return false
	case .Not:
		passed := subcheck_node(h, doc, node, ap.record, nil, owner, quiet = true)
		if h.fatal != .None { return false }
		if passed {
			emit_or_first(h, .Not_Allowed, at, "not", "", owner)
			return false
		}
		return true
	case .If:
		cond_ok := subcheck_node(h, doc, node, ap.test, nil, owner, quiet = true)
		if h.fatal != .None { return false }
		branch := ap.then_rec if cond_ok else ap.else_rec
		return true if branch < 0 else subcheck_node(h, doc, node, branch, nil, owner, quiet = h.quiet)
	case .Dependent:
		if k != .Object { return true }
		ok := true
		for dep in ap.dependents {
			if object_has_key(h, doc, node, dep.name) && !subcheck_node(h, doc, node, dep.record, nil, owner, quiet = h.quiet) {
				ok = false
				if !emit { return false }
			}
		}
		return ok
	case .Patterns:
		if k != .Object { return true }
		ok := true
		it, p, cerr := tape.children(r, node, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return false
		}
		defer tape.destroy_children(&it)
		if p != .Found { return true }
		for {
			kn, vn, cp := tape.next_child(r, &it, h.dups)
			if cp != .Found { break }
			if !charge_step_one(h) { return false }
			key_str, key_owned, kok := child_key_text(h, doc, r, it, kn)
			if !kok { return false }
			matched := slice.contains(ap.named, key_str)
			step := [1]tape.Step{tape.Name(key_str)}
			stop := false
			for pat in ap.patterns {
				found, rok := run_regex_search(h, pat.regex, key_str)
				if !rok {
					stop = true
					break
				}
				if found {
					matched = true
					if !subcheck_node(h, doc, vn, pat.record, step[:], owner, quiet = h.quiet) {
						ok = false
						if !emit {
							stop = true
							break
						}
					}
				}
			}
			if !stop && !matched && ap.additional >= 0 {
				if !subcheck_node(h, doc, vn, ap.additional, step[:], owner, quiet = h.quiet) {
					ok = false
					if !emit { stop = true }
				}
			}
			if key_owned { delete(key_str, h.scratch) }
			if stop { return false }
		}
		return ok
	case .Names:
		if k != .Object { return true }
		ok := true
		it, p, cerr := tape.children(r, node, h.scratch)
		if cerr != nil {
			h.fatal = .No_Memory
			return false
		}
		defer tape.destroy_children(&it)
		if p != .Found { return true }
		for {
			kn, _, cp := tape.next_child(r, &it, h.dups)
			if cp != .Found { break }
			if !charge_step_one(h) { return false }
			key_str, key_owned, kok := child_key_text(h, doc, r, it, kn)
			if !kok { return false }
			res := subcheck_key_string(h, key_str, doc, ap.record, owner, quiet = h.quiet)
			if key_owned { delete(key_str, h.scratch) }
			if !res {
				ok = false
				if !emit { return false }
			}
		}
		return ok
	case .Contains:
		if k != .Array { return true }
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
				if cp != .Found { break }
				if !charge_step_one(h) { return false }
				if subcheck_node(h, doc, ch, ap.record, nil, owner, quiet = true) { hits += 1 }
				if h.fatal != .None { return false }
			}
		}
		ok := true
		if hits < ap.min_contains {
			emit_or_first(h, .Too_Few, at, "minContains" if ap.min_contains > 1 else "contains", "", owner)
			ok = false
			if !emit { return false }
		}
		if hits > ap.max_contains {
			emit_or_first(h, .Too_Many, at, "maxContains", "", owner)
			ok = false
		}
		return ok
	case .Unique:
		return true if k != .Array else check_unique_items(h, doc, node, owner, at)
	case .Const, .Enum:
		val := rules.Value(rules.Node_Ref{doc = doc, node = node})
		for op_v in ap.operands {
			eq, eerr := rules.value_equal(val, op_v, h.dups, h.scratch)
			if eerr != nil {
				h.fatal = .No_Memory
				return false
			}
			if eq { return true }
		}
		emit_or_first(h, .Not_A_Member, at, "const" if ap.kind == .Const else "enum", "", owner)
		return false
	case .Unevaluated_Properties:
		return true if k != .Object else eval_unevaluated_properties(h, doc, node, owner, ap, emit)
	case .Unevaluated_Items:
		return true if k != .Array else eval_unevaluated_items(h, doc, node, owner, ap, emit)
	}
	return true
}

@(private = "file")
object_has_key :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, want: string) -> bool {
	_, p := tape.member(tape.Reader{doc = doc}, node, want, h.dups)
	return p == .Found
}

@(private = "file")
check_unique_items :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, at: u64) -> bool #no_bounds_check {
	r := tape.Reader{doc = doc}
	// Fast zero-alloc path for <= 32 plain unescaped strings.
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
		slots: [64]u32
		items: [32]string = ---
		n := 0
		fast_ok := true
		for {
			_, ch, cp := tape.next_child(r, &it0)
			if cp != .Found { break }
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
					emit_or_first(h, .Not_Unique, at, "uniqueItems", "", owner)
					return false
				}
				hv = (hv + 1) & 63
			}
		}
		tape.destroy_children(&it0)
		if fast_ok { return true }
	}

	cnt, _, lerr := tape.length(r, node, h.scratch)
	if lerr != nil {
		h.fatal = .No_Memory
		return false
	}
	if cnt <= 1 { return true }
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
	if p != .Found { return true }
	for {
		_, ch, cp := tape.next_child(r, &it)
		if cp != .Found { break }
		if !charge_step_one(h) { return false }
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
					emit_or_first(h, .Not_Unique, at, "uniqueItems", "", owner)
					return false
				}
			}
			if _, aerr := append(prevs, ch); aerr != nil {
				h.fatal = .No_Memory
				return false
			}
		} else {
			list, lerr2 := make([dynamic]tape.Node_Index, 0, 2, h.scratch)
			_, aerr := append(&list, ch)
			_, _, _, merr := map_entry(&buckets, hv)
			if lerr2 != nil || aerr != nil || merr != nil {
				delete(list)
				h.fatal = .No_Memory
				return false
			}
			buckets[hv] = list
		}
	}
	return true
}

@(private = "file")
Eval_Collector :: struct {
	is_items:   bool,
	all_eval:   bool,
	vis:        map[^Evaluates]bool,
	names:      map[string]bool,
	pats:       [dynamic]^regex.Regex,
	prefix_max: int,
	eval_bits:  []bool,
}

@(private = "file")
gather_runtime_eval :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, ev: ^Evaluates, c: ^Eval_Collector) {
	if ev == nil || c.all_eval || h.fatal != .None || c.vis[ev] { return }
	c.vis[ev] = true
	if c.is_items {
		if ev.all_items {
			c.all_eval = true
			return
		}
		c.prefix_max = max(c.prefix_max, ev.items)
	} else {
		if ev.all_members {
			c.all_eval = true
			return
		}
		for nm in ev.names {
			c.names[nm] = true
		}
		for re in ev.patterns {
			append(&c.pats, re)
		}
	}
	for sub in ev.refs {
		gather_runtime_eval(h, doc, node, sub, c)
	}
	for inn in ev.inner {
		if c.all_eval || h.fatal != .None { return }
		switch inn.kind {
		case .Any:
			for arm_rec, i in inn.arms {
				if subcheck_node(h, doc, node, arm_rec, nil, nil, quiet = true) {
					gather_runtime_eval(h, doc, node, inn.evals[i], c)
				}
				if h.fatal != .None { return }
			}
		case .One:
			hits, hit_idx := 0, -1
			for arm_rec, i in inn.arms {
				if subcheck_node(h, doc, node, arm_rec, nil, nil, quiet = true) {
					hits, hit_idx = hits + 1, i
				}
				if h.fatal != .None { return }
			}
			if hits == 1 { gather_runtime_eval(h, doc, node, inn.evals[hit_idx], c) }
		case .If:
			cond_ok := subcheck_node(h, doc, node, inn.test, nil, nil, quiet = true)
			if h.fatal != .None { return }
			if cond_ok {
				gather_runtime_eval(h, doc, node, inn.test_eval, c)
				if inn.then >= 0 && subcheck_node(h, doc, node, inn.then, nil, nil, quiet = true) {
					gather_runtime_eval(h, doc, node, inn.then_eval, c)
				}
			} else if inn.other >= 0 && subcheck_node(h, doc, node, inn.other, nil, nil, quiet = true) {
				gather_runtime_eval(h, doc, node, inn.other_eval, c)
			}
		case .Dependent:
			if !c.is_items && object_has_key(h, doc, node, inn.name) && subcheck_node(h, doc, node, inn.body, nil, nil, quiet = true) {
				gather_runtime_eval(h, doc, node, inn.body_eval, c)
			}
		case .Contains:
			if c.is_items {
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
					for idx := 0; ; idx += 1 {
						_, ch, cp := tape.next_child(r, &it)
						if cp != .Found { break }
						if subcheck_node(h, doc, ch, inn.body, nil, nil, quiet = true) {
							append(&matched, idx)
						}
						if h.fatal != .None { return }
					}
					if hits := u64(len(matched)); hits >= inn.min_contains && hits <= inn.max_contains {
						for m_idx in matched {
							if m_idx < len(c.eval_bits) { c.eval_bits[m_idx] = true }
						}
					}
				}
			}
		}
	}
}

@(private = "file")
eval_unevaluated_properties :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, ap: ^Apply, emit: bool) -> bool {
	c: Eval_Collector
	nerr, verr: runtime.Allocator_Error
	c.names, nerr = make(map[string]bool, 16, h.scratch)
	c.vis, verr = make(map[^Evaluates]bool, 16, h.scratch)
	c.pats.allocator = h.scratch
	defer {
		delete(c.names)
		delete(c.pats)
		delete(c.vis)
	}
	if nerr != nil || verr != nil {
		h.fatal = .No_Memory
		return false
	}
	gather_runtime_eval(h, doc, node, ap.evals, &c)
	if h.fatal != .None { return false }
	if c.all_eval { return true }
	ok := true
	r := tape.Reader{doc = doc}
	it, p, cerr := tape.children(r, node, h.scratch)
	if cerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer tape.destroy_children(&it)
	if p != .Found { return true }
	for {
		kn, vn, cp := tape.next_child(r, &it, h.dups)
		if cp != .Found { break }
		if !charge_step_one(h) { return false }
		key_str, key_owned, kok := child_key_text(h, doc, r, it, kn)
		if !kok { return false }
		evaluated := c.names[key_str]
		re_ok := true
		if !evaluated {
			for re in c.pats {
				found, rok := run_regex_search(h, re, key_str)
				if !rok {
					re_ok = false
					break
				}
				if found {
					evaluated = true
					break
				}
			}
		}
		res := true
		if re_ok && !evaluated {
			step := [1]tape.Step{tape.Name(key_str)}
			res = subcheck_node(h, doc, vn, ap.record, step[:], owner, quiet = h.quiet)
		}
		if key_owned { delete(key_str, h.scratch) }
		if !re_ok { return false }
		if !res {
			ok = false
			if !emit { return false }
		}
	}
	return ok
}

@(private = "file")
eval_unevaluated_items :: proc(h: ^Checker, doc: ^tape.Document, node: tape.Node_Index, owner: ^Record, ap: ^Apply, emit: bool) -> bool {
	r := tape.Reader{doc = doc}
	cnt, _, lerr := tape.length(r, node, h.scratch)
	if lerr != nil {
		h.fatal = .No_Memory
		return false
	}
	if cnt <= 0 { return true }
	c := Eval_Collector{is_items = true}
	eerr, verr: runtime.Allocator_Error
	c.eval_bits, eerr = make([]bool, cnt, h.scratch)
	c.vis, verr = make(map[^Evaluates]bool, 16, h.scratch)
	defer {
		delete(c.eval_bits, h.scratch)
		delete(c.vis)
	}
	if eerr != nil || verr != nil {
		h.fatal = .No_Memory
		return false
	}
	gather_runtime_eval(h, doc, node, ap.evals, &c)
	if h.fatal != .None { return false }
	if c.all_eval || c.prefix_max >= cnt { return true }
	ok := true
	it, p, cerr := tape.children(r, node, h.scratch)
	if cerr != nil {
		h.fatal = .No_Memory
		return false
	}
	defer tape.destroy_children(&it)
	if p != .Found { return true }
	for idx := 0; ; idx += 1 {
		_, ch, cp := tape.next_child(r, &it)
		if cp != .Found { break }
		if !charge_step_one(h) { return false }
		if idx >= c.prefix_max && !c.eval_bits[idx] {
			step := [1]tape.Step{tape.Index(idx)}
			if !subcheck_node(h, doc, ch, ap.record, step[:], owner, quiet = h.quiet) {
				ok = false
				if !emit { return false }
			}
		}
	}
	return ok
}
