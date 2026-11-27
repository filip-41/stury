package jq

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"
import "stury:lib/query"

// Query planning for compiled jq programs:
// 1. Backward demand analysis per input source (`.`, `inputs`, slurped records, raw lines).
// 2. Non-data serial flags (`Inputs`, `Position`, `Messages`, `Halts`, `Recurses`).
// 3. Execution hints (`Per_Element_Split`, `Projection_Template`, `Conditional_Whole`).

Analyze_Options :: struct {
	null_input:       bool,
	slurp:            bool,
	raw_input:        bool,
	stream:           bool,
	materialize_each: bool,
}

Plan :: struct {
	using contract: query.Plan,
	each_body:      ^Node,
	tail_body:      ^Node,
	pred_body:      ^Node,
	owned_nodes:    [dynamic]^Node,
}

@(private = "file") MAX_ANALYSIS_DEPTH :: 32
@(private = "file") MAX_MEMO_ENTRIES   :: 256
@(private = "file") MAX_CALL_DEPTH     :: 64

@(private = "file")
Need :: struct {
	whole, facts: bool,
	reason:       query.Whole_Reason,
	paths:        []query.Demand_Path,
}

@(private = "file")
Var_Frame :: struct {
	parent: ^Var_Frame,
	slots:  []Need,
	args:   []Arg_Binding,
}

@(private = "file")
Arg_Binding :: struct {
	node: ^Node,
	env:  ^Var_Frame,
}

@(private = "file")
Memo_Key :: struct {
	fn:  ^Func,
	sig: u64,
}

@(private = "file")
Memo_Entry :: struct {
	key:    Memo_Key,
	out:    Need,
	result: Need,
}

@(private = "file")
Analyzer :: struct {
	prog:              ^Program,
	arena:             mem.Dynamic_Arena,
	scratch:           runtime.Allocator,
	serial:            query.Serial_Flags,
	inputs_need:       Need,
	ext_names:         []string,
	global_to_ext:     []int,
	ext_needs:         []Need,
	ext_reachable:     []bool,
	has_reachable_ext: bool,
	active_fns:        [dynamic]^Func,
	memo:              [dynamic]Memo_Entry,
	call_depth:        int,
}

analyze :: proc(prog: ^Program, opts := Analyze_Options{}, allocator := context.allocator) -> Plan {
	plan, _ := analyze_plan_with_vars(prog, nil, opts, allocator)
	return plan
}

is_identity :: proc "contextless" (prog: ^Program) -> bool {
	return prog != nil && prog.body != nil && prog.body.kind == .Identity
}

analyze_with_vars :: proc(prog: ^Program, ext_vars: []string, allocator := context.allocator, opts := Analyze_Options{}) -> (plan: query.Plan, ok: bool) {
	jq_plan := analyze_plan_with_vars(prog, ext_vars, opts, allocator) or_return
	destroy_jq_extras(&jq_plan)
	return jq_plan.contract, true
}

analyze_plan_with_vars :: proc(prog: ^Program, ext_vars: []string, opts := Analyze_Options{}, allocator := context.allocator) -> (plan: Plan, ok: bool) {
	if prog == nil {
		return {}, false
	}
	a: Analyzer
	mem.dynamic_arena_init(&a.arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&a.arena)
	a.prog, a.scratch = prog, mem.dynamic_arena_allocator(&a.arena)
	a.active_fns = make([dynamic]^Func, 0, 16, a.scratch)
	a.memo = make([dynamic]Memo_Entry, 0, 32, a.scratch)

	init_ext_vars(&a, ext_vars)
	a.serial = collect_serial(prog, a.scratch)
	if len(a.ext_names) > 0 {
		collect_ext_reachable(&a)
	}

	plan = Plan{contract = {allocator = allocator, serial = a.serial}}
	if opts.stream {
		stream_facts := needs_facts(prog, a.scratch)
		plan.sources[.Main] = query.whole_demand(stream_facts, .Stream_Mode)
		for ext_i in 0 ..< len(a.ext_names) {
			if a.ext_reachable[ext_i] {
				a.ext_needs[ext_i] = whole_need(.Stream_Mode, stream_facts)
			}
		}
		finalize_ext_aux(&a, &plan.contract, allocator)
		return plan, true
	}

	root_need := demand_node(&a, prog.body, whole_need(.Identity), nil)
	plan.serial |= a.serial
	switch {
	case opts.null_input:
		plan.sources[.Main] = {mode = .None, allocator = allocator}
	case opts.raw_input:
		plan.sources[.Raw] = finalize_need(&a, root_need, allocator)
	case opts.slurp:
		plan.sources[.Slurp] = finalize_need(&a, unwrap_container_need(&a, root_need, false, ""), allocator)
		plan.sources[.Main] = finalize_need(&a, root_need, allocator)
	case:
		plan.sources[.Main] = finalize_need(&a, root_need, allocator)
	}
	if !need_is_empty(a.inputs_need) {
		plan.sources[.Inputs] = finalize_need(&a, a.inputs_need, allocator)
	}
	finalize_ext_aux(&a, &plan.contract, allocator)
	if !opts.null_input && !opts.slurp && !opts.raw_input {
		extract_hints(&a, prog.body, &plan, opts.materialize_each, allocator)
	}
	return plan, true
}

@(private = "file")
init_ext_vars :: proc(a: ^Analyzer, ext_vars: []string) {
	if len(ext_vars) == 0 {
		return
	}
	names := make([dynamic]string, 0, len(ext_vars), a.scratch)
	for name in ext_vars {
		if name != "" && !slice.contains(names[:], name) {
			append(&names, name)
		}
	}
	if len(names) == 0 {
		return
	}
	a.ext_names = names[:]
	a.ext_needs = make([]Need, len(names), a.scratch)
	a.ext_reachable = make([]bool, len(names), a.scratch)
	a.global_to_ext = make([]int, len(a.prog.globals), a.scratch)
	for &m, gi in a.global_to_ext {
		ei, found := slice.linear_search(names[:], a.prog.globals[gi])
		m = ei if found else -1
	}
}

@(private = "file")
finalize_ext_aux :: proc(a: ^Analyzer, contract: ^query.Plan, allocator: runtime.Allocator) {
	if len(a.ext_names) == 0 {
		return
	}
	entries := make([]query.Named_Demand, len(a.ext_names), a.scratch)
	for name, i in a.ext_names {
		entries[i] = {name = name, demand = finalize_need(a, a.ext_needs[i], allocator)}
	}
	if query.set_aux_demands(contract, entries) != nil {
		for &e in entries {
			query.destroy_source_demand(&e.demand)
		}
	}
}

@(private = "file")
destroy_jq_extras :: proc(p: ^Plan) {
	if p == nil {
		return
	}
	for n in p.owned_nodes {
		free(n, p.allocator)
	}
	delete(p.owned_nodes)
	p.owned_nodes = nil
}

destroy_plan :: proc(p: ^Plan) {
	destroy_jq_extras(p)
	query.destroy_plan(&p.contract)
	p^ = {}
}

explain_plan :: proc(p: ^Plan, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	query.format_plan(&b, &p.contract)
	return strings.to_string(b)
}

// ---- Need algebra

@(private = "file")
whole_need :: #force_inline proc "contextless" (reason: query.Whole_Reason, facts := false) -> Need {
	return {whole = true, facts = facts, reason = reason}
}

@(private = "file")
grain_need :: proc(a: ^Analyzer, grain: tape.Grain, facts := false) -> Need {
	if grain == .Whole {
		return whole_need(.Identity, facts)
	}
	ps := make([]query.Demand_Path, 1, a.scratch)
	ps[0] = {grain = grain}
	return {facts = facts, paths = ps}
}

@(private = "file")
need_is_empty :: #force_inline proc "contextless" (n: Need) -> bool {
	return !n.whole && len(n.paths) == 0 && !n.facts
}

@(private = "file")
need_join :: proc(a: ^Analyzer, x, y: Need) -> Need {
	facts := x.facts || y.facts
	if x.whole || y.whole {
		r := x.reason if (x.whole && x.reason != .None) else (y.reason if y.whole && y.reason != .None else (x.reason if x.reason != .None else y.reason))
		return {whole = true, facts = facts, reason = r}
	}
	if len(x.paths) == 0 || len(y.paths) == 0 {
		out := y if len(x.paths) == 0 else x
		out.facts = facts
		return out
	}
	out := make([dynamic]query.Demand_Path, 0, len(x.paths) + len(y.paths), a.scratch)
	append(&out, ..x.paths)
	for p in y.paths {
		merged := false
		for &k in out {
			if query.steps_equal(k.steps, p.steps) {
				k.grain, k.limit, merged = query.broader_grain(k.grain, p.grain), query.merge_limit(k.limit, p.limit), true
				break
			}
		}
		if !merged {
			if len(out) >= query.MAX_DEMAND_PATHS {
				return whole_need(.Analysis_Cap, facts)
			}
			append(&out, p)
		}
	}
	return {facts = facts, paths = out[:]}
}

@(private = "file")
need_equal :: proc "contextless" (x, y: Need) -> bool {
	if x.whole != y.whole || x.facts != y.facts || len(x.paths) != len(y.paths) {
		return false
	}
	if x.whole {
		return true
	}
	for p, i in x.paths {
		q := y.paths[i]
		if p.grain != q.grain || p.limit != q.limit || !query.steps_equal(p.steps, q.steps) {
			return false
		}
	}
	return true
}

@(private = "file")
need_hash :: proc "contextless" (n: Need) -> u64 {
	mix :: #force_inline proc "contextless" (h, v: u64) -> u64 { return (h ~ v) * 0x100000001B3 }
	h := mix(0xCBF29CE484222325, u64(n.whole) | u64(n.facts) << 1)
	if n.whole {
		return h
	}
	h = mix(h, u64(len(n.paths)))
	for p in n.paths {
		h = mix(h, u64(p.grain) | u64(p.limit) << 8)
		for s in p.steps {
			switch step in s {
			case tape.Name:
				h = mix(h, 1)
				for c in transmute([]u8)string(step) {
					h = mix(h, u64(c))
				}
			case tape.Index:   h = mix(mix(h, 2), u64(i64(step)))
			case tape.All:     h = mix(mix(h, 3), u64(step.limit))
			case tape.Slice:
				h = mix(mix(h, 4), u64(i64(step.lo)))
				if hi, ok := step.hi.?; ok {
					h = mix(h, u64(i64(hi)))
				}
			case tape.Descend: h = mix(h, 5)
			}
		}
	}
	return h
}

@(private = "file")
need_prepend :: proc(a: ^Analyzer, step: tape.Step, child: Need, min_grain := tape.Grain.Exists) -> Need {
	if child.whole || len(child.paths) == 0 {
		steps := make([]tape.Step, 1, a.scratch)
		steps[0] = step
		ps := make([]query.Demand_Path, 1, a.scratch)
		ps[0] = {steps = steps, grain = .Whole if child.whole else min_grain}
		return {facts = child.facts, paths = ps}
	}
	ps := make([]query.Demand_Path, len(child.paths), a.scratch)
	for p, i in child.paths {
		if len(p.steps) + 1 > MAX_ANALYSIS_DEPTH {
			return whole_need(.Analysis_Cap, child.facts)
		}
		steps := make([]tape.Step, len(p.steps) + 1, a.scratch)
		steps[0] = step
		copy(steps[1:], p.steps)
		ps[i] = {steps = steps, grain = p.grain, limit = p.limit}
	}
	return {facts = child.facts, paths = ps}
}

@(private = "file")
out_safe_for_limit :: proc "contextless" (out: Need) -> bool {
	if out.whole {
		return true
	}
	for p in out.paths {
		if p.grain == .Keys {
			return false
		}
		for s in p.steps {
			#partial switch step in s {
			case tape.All, tape.Slice, tape.Descend: return false
			case tape.Index:
				if step < 0 {
					return false
				}
			}
		}
	}
	return true
}

@(private = "file")
taint_outer_env :: proc(a: ^Analyzer, env: ^Var_Frame, reason: query.Whole_Reason, facts := false) {
	for f := env; f != nil; f = f.parent {
		for &slot in f.slots {
			slot = whole_need(reason, slot.facts || facts)
		}
	}
	if .Inputs in a.serial {
		a.inputs_need = whole_need(reason, a.inputs_need.facts || facts)
	}
	for &en, i in a.ext_needs {
		if a.ext_reachable[i] {
			en = whole_need(reason, en.facts || facts)
		}
	}
}

@(private = "file")
need_limit :: proc(a: ^Analyzer, n: Need, limit: int) -> Need {
	if n.whole || len(n.paths) == 0 || limit <= 0 {
		return n
	}
	ps := make([]query.Demand_Path, len(n.paths), a.scratch)
	for p, i in n.paths {
		ps[i] = p
		lim := limit if p.limit == 0 else min(p.limit, limit)
		ps[i].limit = lim
		last_all := -1
		for s, j in p.steps {
			if _, ok := s.(tape.All); ok {
				last_all = j
			}
		}
		if last_all >= 0 && lim <= int(max(i32)) {
			cur := p.steps[last_all].(tape.All)
			step_lim := i32(lim) if cur.limit <= 0 else min(cur.limit, i32(lim))
			if step_lim != cur.limit {
				cloned := slice.clone(p.steps, a.scratch)
				cloned[last_all] = tape.All{limit = step_lim}
				ps[i].steps = cloned
			}
		}
	}
	return {facts = n.facts, paths = ps}
}

@(private = "file")
unwrap_container_need :: proc(a: ^Analyzer, out: Need, is_object: bool, key_name: string) -> Need {
	if out.whole {
		return whole_need(out.reason, out.facts)
	}
	acc: Need
	for p in out.paths {
		if len(p.steps) == 0 {
			if p.grain == .Whole {
				return whole_need(.Identity, out.facts)
			}
			continue
		}
		matched := false
		switch step in p.steps[0] {
		case tape.Descend:            return whole_need(.Whole_Op, out.facts)
		case tape.All:                matched = true
		case tape.Index, tape.Slice:  matched = !is_object
		case tape.Name:               matched = is_object && string(step) == key_name
		}
		if !matched {
			continue
		}
		rest := p.steps[1:]
		if len(rest) == 0 && p.grain == .Whole {
			return whole_need(.Identity, out.facts)
		}
		sub := make([]query.Demand_Path, 1, a.scratch)
		sub[0] = {steps = rest, grain = p.grain}
		acc = need_join(a, acc, {facts = out.facts, paths = sub})
	}
	return acc
}

@(private = "file")
finalize_need :: proc(a: ^Analyzer, n: Need, allocator: runtime.Allocator) -> query.Source_Demand {
	if n.whole {
		return query.whole_demand(n.facts, n.reason if n.reason != .None else .Identity)
	}
	if len(n.paths) == 0 {
		return query.whole_demand(true, .Whole_Op) if n.facts else {mode = .None, allocator = allocator}
	}
	return query.finalize_source_demand(n.paths, n.facts, allocator)
}

// ---- Backward demand transfer

@(private = "file")
demand_all_whole :: proc(a: ^Analyzer, nodes: []^Node, env: ^Var_Frame, reason := query.Whole_Reason.Whole_Op) -> (acc: Need) {
	for x in nodes {
		acc = need_join(a, acc, demand_node(a, x, whole_need(reason), env))
	}
	return
}

@(private = "file")
demand_node :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	if n == nil {
		return {}
	}
	if a.call_depth > MAX_CALL_DEPTH {
		taint_outer_env(a, env, .Analysis_Cap, out.facts)
		return whole_need(.Analysis_Cap, out.facts)
	}
	a.call_depth += 1
	defer a.call_depth -= 1

	switch n.kind {
	case .Identity:       return out
	case .Literal, .Break: return {}
	case .Var:
		if n.ref.kind == .Var {
			if f := var_frame_up(env, n.ref.hops); f != nil && int(n.ref.slot) < len(f.slots) {
				f.slots[n.ref.slot] = need_join(a, f.slots[n.ref.slot], out)
			}
		} else if n.ref.kind == .Global && int(n.ref.slot) < len(a.global_to_ext) {
			if ext_i := a.global_to_ext[n.ref.slot]; ext_i >= 0 {
				a.ext_needs[ext_i] = need_join(a, a.ext_needs[ext_i], out)
			}
		}
		return {}
	case .Field:   return demand_node(a, n.a, need_prepend(a, tape.Name(n.name), out), env)
	case .Index:   return demand_index(a, n, out, env)
	case .Slice:   return demand_slice(a, n, out, env)
	case .Iterate: return demand_node(a, n.a, need_prepend(a, tape.All{}, out), env)
	case .String:  return demand_all_whole(a, n.args, env)
	case .Format:  return whole_need(.Whole_Op) if n.a == nil else demand_node(a, n.a, whole_need(.Whole_Op), env)
	case .Array:   return {} if n.a == nil else demand_node(a, n.a, unwrap_container_need(a, out, false, ""), env)
	case .Object:
		acc: Need
		for i := 0; i < len(n.args); i += 2 {
			k, v := n.args[i], n.args[i + 1]
			if k.kind == .Literal && k.value.kind == .String {
				if v != nil {
					acc = need_join(a, acc, demand_node(a, v, unwrap_container_need(a, out, true, query.text_of(k.value)), env))
				}
			} else {
				acc = need_join(a, acc, demand_node(a, k, whole_need(.Dynamic_Step), env))
				if v == nil {
					acc = need_join(a, acc, whole_need(.Dynamic_Step, out.facts))
				} else {
					val_out := whole_need(.Dynamic_Step, out.facts) if out.whole || has_non_shallow_path(out) else Need{}
					acc = need_join(a, acc, demand_node(a, v, val_out, env))
				}
			}
		}
		return acc
	case .Neg:    return demand_node(a, n.a, whole_need(.Whole_Op), env)
	case .Pipe:   return demand_node(a, n.a, demand_node(a, n.b, out, env), env)
	case .Comma:  return need_join(a, demand_node(a, n.a, out, env), demand_node(a, n.b, out, env))
	case .Binary: return need_join(a, demand_node(a, n.a, whole_need(.Whole_Op), env), demand_node(a, n.b, whole_need(.Whole_Op), env))
	case .And, .Or:
		g := grain_need(a, .Exists)
		return need_join(a, demand_node(a, n.a, g, env), demand_node(a, n.b, g, env))
	case .Alt:
		return need_join(a, demand_node(a, n.a, need_join(a, out, grain_need(a, .Exists)), env), demand_node(a, n.b, out, env))
	case .If:
		dc := demand_node(a, n.a, grain_need(a, .Exists), env)
		dt := demand_node(a, n.b, out, env)
		de := demand_node(a, n.c, out, env) if n.c != nil else out
		return need_join(a, need_join(a, dc, dt), de)
	case .Try:
		da := demand_node(a, n.a, out, env)
		if n.b != nil {
			da.facts = demand_node(a, n.b, out, env).facts || da.facts
		}
		return da
	case .Bind:             return demand_bind(a, n, out, env)
	case .Reduce, .Foreach: return demand_fold(a, n, out, env)
	case .Def:              return demand_node(a, n.a, out, env)
	case .Label:
		frame := Var_Frame{parent = env}
		return demand_node(a, n.a, out, &frame)
	case .Update:
		da := demand_node(a, n.a, whole_need(.Whole_Op), env)
		db := demand_node(a, n.b, whole_need(.Whole_Op), env)
		return whole_need(.Whole_Op, out.facts || da.facts || db.facts)
	case .Call: return demand_call(a, n, out, env)
	}
	return whole_need(.Whole_Op, out.facts)
}

@(private = "file")
has_non_shallow_path :: proc "contextless" (n: Need) -> bool {
	for p in n.paths {
		if len(p.steps) > 0 || p.grain == .Whole {
			return true
		}
	}
	return false
}

@(private = "file")
demand_index :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	b := n.b
	if b.kind == .Literal {
		if kind, _, is_fact := query.fact_step_literal(b.value); is_fact {
			return demand_node(a, n.a, whole_need(.Whole_Op, true) if kind == .Content else grain_need(a, .Exists, true), env)
		}
		if query.is_unknown_fact_step_literal(b.value) {
			return demand_node(a, n.a, grain_need(a, .Exists, true), env)
		}
		if b.value.kind == .String {
			return demand_node(a, n.a, need_prepend(a, tape.Name(query.text_of(b.value)), out), env)
		}
		if i, ok := query.as_i64(b.value); ok && i >= -(1 << 30) && i <= (1 << 30) {
			return demand_node(a, n.a, need_prepend(a, tape.Index(int(i)), out), env)
		}
		return demand_node(a, n.a, whole_need(.Dynamic_Step, out.facts), env)
	}
	if b.kind == .Call && b.builtin != nil && (b.builtin.fn == v_fact_step || b.builtin.fn == v_attribute_step) {
		return need_join(a, demand_node(a, b.args[0], whole_need(.Whole_Op), env), demand_node(a, n.a, whole_need(.Dynamic_Step, true), env))
	}
	dk := demand_node(a, b, whole_need(.Whole_Op), env)
	elem_need := need_prepend(a, tape.All{}, out) if !out.whole && len(out.paths) > 0 && all_paths_start_with_name(out) && b.kind != .Array && b.kind != .Object else whole_need(.Dynamic_Step, out.facts)
	return need_join(a, dk, demand_node(a, n.a, elem_need, env))
}

@(private = "file")
all_paths_start_with_name :: proc "contextless" (n: Need) -> bool {
	if n.whole || len(n.paths) == 0 {
		return false
	}
	for p in n.paths {
		if len(p.steps) == 0 {
			return false
		}
		if _, ok := p.steps[0].(tape.Name); !ok {
			return false
		}
	}
	return true
}

@(private = "file")
demand_slice :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	bounds_need := need_join(a, demand_node(a, n.b, whole_need(.Whole_Op), env), demand_node(a, n.c, whole_need(.Whole_Op), env))
	lo, hi, static := i32(0), Maybe(i32)(nil), true
	if n.b != nil {
		lo, static = literal_exact_i32(n.b)
	}
	if static && n.c != nil {
		v, ok := literal_exact_i32(n.c)
		hi, static = v, ok
	}
	if !static {
		return need_join(a, bounds_need, demand_node(a, n.a, whole_need(.Dynamic_Step, out.facts), env))
	}
	elem_out := unwrap_container_need(a, out, false, "")
	if need_is_empty(elem_out) {
		elem_out = grain_need(a, .Exists, out.facts)
	}
	slice_need := need_join(a, grain_need(a, .Keys, out.facts), need_prepend(a, tape.Slice{lo = lo, hi = hi}, elem_out))
	return need_join(a, bounds_need, demand_node(a, n.a, slice_need, env))
}

@(private = "file")
literal_exact_i32 :: proc(n: ^Node) -> (i32, bool) {
	if n.kind != .Literal || n.value.kind != .Int || n.value.i < -(1 << 30) || n.value.i > (1 << 30) {
		return 0, false
	}
	return i32(n.value.i), true
}

@(private = "file")
demand_bind :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	frame := Var_Frame{parent = env, slots = make([]Need, int(n.slots), a.scratch)}
	dot_need := demand_node(a, n.b, out, &frame)
	key_need, pat_need := lift_patterns(a, n.patterns, frame.slots, &frame if len(n.patterns) > 1 else env)
	return need_join(a, need_join(a, dot_need, key_need), demand_node(a, n.a, pat_need, env))
}

@(private = "file")
demand_fold :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	frame := Var_Frame{parent = env, slots = make([]Need, int(n.slots), a.scratch)}
	acc_need := demand_node(a, n.d, out, &frame) if n.kind == .Foreach && n.d != nil else out
	upd_dot := demand_node(a, n.c, acc_need, &frame)
	acc_need.facts ||= upd_dot.facts
	if !acc_need.whole && !need_equal(need_join(a, acc_need, upd_dot), acc_need) {
		acc_need = whole_need(.Whole_Op, acc_need.facts)
		frame.slots = make([]Need, int(n.slots), a.scratch)
		if n.kind == .Foreach && n.d != nil {
			_ = demand_node(a, n.d, out, &frame)
		}
		acc_need.facts = demand_node(a, n.c, acc_need, &frame).facts || acc_need.facts
	}
	key_need, pat_need := lift_patterns(a, n.patterns, frame.slots, &frame if len(n.patterns) > 1 else env)
	return need_join(a, need_join(a, demand_node(a, n.b, acc_need, env), key_need), demand_node(a, n.a, pat_need, env))
}

// Lifts variable demands in `slots` back through `patterns` iteratively (no unbounded recursion).
@(private = "file")
lift_patterns :: proc(a: ^Analyzer, patterns: []^Pattern, slots: []Need, env: ^Var_Frame) -> (key_need, val_need: Need) {
	for pat in patterns {
		kn, vn := lift_pattern(a, pat, slots, env)
		key_need, val_need = need_join(a, key_need, kn), need_join(a, val_need, vn)
	}
	if len(patterns) > 1 && need_is_empty(val_need) {
		val_need = grain_need(a, .Exists)
	}
	return
}

@(private = "file")
lift_pattern :: proc(a: ^Analyzer, root: ^Pattern, slots: []Need, env: ^Var_Frame) -> (key_need, val_need: Need) {
	if root == nil {
		return
	}
	Lift_Frame :: struct {
		pat:                ^Pattern,
		idx:                int,
		val_need, child_vn: Need,
		waiting:            bool,
	}
	stack := make([dynamic]Lift_Frame, 0, 8, a.scratch)
	push_pat :: proc(a: ^Analyzer, stack: ^[dynamic]Lift_Frame, pat: ^Pattern) {
		append(stack, Lift_Frame{pat = pat, idx = len(pat.members) - 1 if pat.kind == .Object else 0, val_need = grain_need(a, .Exists) if pat.kind != .Var else Need{}})
	}
	push_pat(a, &stack, root)
	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		pat := f.pat
		done, res_vn := false, Need{}
		switch pat.kind {
		case .Var:
			if int(pat.slot) < len(slots) {
				res_vn = slots[pat.slot]
			}
			done = true
		case .Array:
			if f.waiting {
				f.val_need = need_join(a, f.val_need, need_prepend(a, tape.Index(f.idx), f.child_vn))
				f.waiting, f.idx = false, f.idx + 1
			}
			for f.idx < len(pat.elems) {
				if elem := pat.elems[f.idx]; elem != nil {
					f.waiting = true
					push_pat(a, &stack, elem)
					break
				}
				f.val_need = need_join(a, f.val_need, need_prepend(a, tape.Index(f.idx), Need{}))
				f.idx += 1
			}
			if !f.waiting {
				res_vn, done = f.val_need, true
			}
		case .Object:
			for f.idx >= 0 {
				m := pat.members[f.idx]
				if m.pattern != nil && !f.waiting {
					f.waiting = true
					push_pat(a, &stack, m.pattern)
					break
				}
				member_need := f.child_vn if f.waiting else Need{}
				f.waiting, f.child_vn = false, {}
				if m.var != "" && int(m.slot) < len(slots) {
					member_need = need_join(a, member_need, slots[m.slot])
				}
				if m.key != nil && m.key.kind == .Literal && m.key.value.kind == .String {
					f.val_need = need_join(a, f.val_need, need_prepend(a, tape.Name(query.text_of(m.key.value)), member_need))
				} else {
					if m.key != nil {
						key_need = need_join(a, key_need, demand_node(a, m.key, whole_need(.Dynamic_Step), env))
					}
					f.val_need = need_join(a, f.val_need, whole_need(.Dynamic_Step, member_need.facts))
				}
				f.idx -= 1
			}
			if !f.waiting {
				res_vn, done = f.val_need, true
			}
		}
		if done {
			pop(&stack)
			if len(stack) == 0 {
				val_need = res_vn
			} else {
				stack[len(stack) - 1].child_vn = res_vn
			}
		}
	}
	return
}

@(private = "file")
var_frame_up :: #force_inline proc "contextless" (env: ^Var_Frame, hops: u32) -> ^Var_Frame {
	e := env
	for _ in 0 ..< hops {
		if e == nil {
			return nil
		}
		e = e.parent
	}
	return e
}

@(private = "file")
demand_call :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	#partial switch n.ref.kind {
	case .Param:
		if f := var_frame_up(env, n.ref.hops); f != nil && int(n.ref.slot) < len(f.args) {
			arg := f.args[n.ref.slot]
			return demand_node(a, arg.node, out, arg.env)
		}
		return whole_need(.Dynamic_Call, out.facts)
	case .Def:
		fn := n.callee
		if fn == nil {
			return whole_need(.Dynamic_Call, out.facts)
		}
		if fn.prelude && fn.name == "tostream" && len(fn.params) == 0 {
			return whole_need(.Stream_Mode, out.facts)
		}
		if slice.contains(a.active_fns[:], fn) {
			a.serial += {.Recurses}
			facts := out.facts || demand_all_whole(a, n.args, env, .Dynamic_Call).facts
			taint_outer_env(a, env, .Dynamic_Call, facts)
			return whole_need(.Dynamic_Call, facts)
		}
		memo_key: Memo_Key
		can_memo := len(fn.params) == 0 && len(n.args) == 0 && env == nil && !a.has_reachable_ext
		if can_memo {
			memo_key = {fn, need_hash(out)}
			for e in a.memo {
				if e.key == memo_key && need_equal(e.out, out) {
					return e.result
				}
			}
			if len(a.memo) >= MAX_MEMO_ENTRIES {
				taint_outer_env(a, env, .Analysis_Cap, out.facts)
				return whole_need(.Analysis_Cap, out.facts)
			}
		}
		append(&a.active_fns, fn)
		base := var_frame_up(env, n.ref.hops)
		res: Need
		if len(fn.params) == 0 {
			res = demand_node(a, fn.body, out, base)
		} else {
			frame := Var_Frame{parent = base, args = make([]Arg_Binding, len(n.args), a.scratch)}
			for arg, i in n.args {
				frame.args[i] = {arg, env}
			}
			res = demand_node(a, fn.body, out, &frame)
		}
		pop(&a.active_fns)
		if can_memo {
			append(&a.memo, Memo_Entry{key = memo_key, out = out, result = res})
		}
		return res
	}
	return whole_need(.Dynamic_Call, out.facts) if n.builtin == nil else demand_builtin(a, n, n.builtin, out, env)
}

@(private = "file")
demand_builtin :: proc(a: ^Analyzer, n: ^Node, b: ^Builtin, out: Need, env: ^Var_Frame) -> Need {
	switch b.op {
	case .Empty:       return {}
	case .Select:      return need_join(a, out, demand_node(a, n.args[0], grain_need(a, .Exists), env))
	case .Kind_Filter: return need_join(a, out, grain_need(a, .Exists))
	case .Error:       return demand_node(a, n.args[0], whole_need(.Whole_Op), env) if len(n.args) > 0 else whole_need(.Whole_Op)
	case .Path:        return demand_node(a, n.args[0], Need{} if is_pure_path_expr(a, n.args[0]) else whole_need(.Whole_Op), env)
	case .Getpath:     return demand_getpath(a, n.args[0], out, env)
	case .First, .Limit:
		lim, body := 1, n.args[0]
		if b.op == .Limit {
			k, ok := literal_nonneg_int(n.args[0])
			if !ok {
				return need_join(a, demand_node(a, n.args[0], whole_need(.Whole_Op), env), demand_node(a, n.args[1], out, env))
			}
			if k == 0 {
				return {}
			}
			lim, body = k, n.args[1]
		}
		df := demand_node(a, body, out, env)
		return need_limit(a, df, lim) if is_non_filtering(a, body) && out_safe_for_limit(out) else df
	case .Skip:    return need_join(a, demand_node(a, n.args[0], whole_need(.Whole_Op), env), demand_node(a, n.args[1], out, env))
	case .Last:    return demand_node(a, n.args[0], out, env)
	case .Isempty: return demand_node(a, n.args[0], {}, env)
	case .Range:   return demand_all_whole(a, n.args, env)
	case .Input, .Inputs:
		a.serial += {.Inputs}
		a.inputs_need = need_join(a, a.inputs_need, out)
		return {}
	case .Debug, .Stderr:
		a.serial += {.Messages}
		return whole_need(.Whole_Op, out.facts)
	case .Halt:
		a.serial += {.Halts}
		return {}
	case .Halt_Error:
		a.serial += {.Halts}
		return need_join(a, demand_node(a, n.args[0], whole_need(.Whole_Op), env), whole_need(.Whole_Op))
	case .Css:
		return need_join(a, demand_node(a, n.args[0], whole_need(.Whole_Op), env), whole_need(.Whole_Op, true))
	case .None:
		args_need := demand_all_whole(a, n.args, env)
		switch b.name {
		case "not", "type", "where":
			return need_join(a, args_need, grain_need(a, .Exists))
		case "length", "keys", "keys_unsorted":
			return need_join(a, args_need, grain_need(a, .Keys))
		case "has":
			if len(n.args) == 1 && n.args[0].kind == .Literal && n.args[0].value.kind == .String {
				return need_join(a, args_need, need_prepend(a, tape.Name(query.text_of(n.args[0].value)), {}, .Exists))
			}
			return need_join(a, args_need, grain_need(a, .Keys))
		case "input_filename", "input_line_number":
			a.serial += {.Position}
			return args_need
		case "now", "builtins", "have_literal_numbers", "have_decnum", "infinite", "nan",
		     "uuid_v4", "uuid_v7", "get_search_list", "get_jq_origin", "get_prog_origin",
		     "_fact_step", "_attribute_step":
			return args_need
		}
		return need_join(a, args_need, whole_need(.Whole_Op, out.facts))
	}
	return whole_need(.Whole_Op, out.facts)
}

@(private = "file")
prepend_all_steps :: proc(a: ^Analyzer, steps: []tape.Step, base: Need) -> Need {
	res := base
	#reverse for s in steps {
		res = need_prepend(a, s, res)
	}
	return res
}

@(private = "file")
demand_getpath :: proc(a: ^Analyzer, arg: ^Node, out: Need, env: ^Var_Frame) -> Need {
	if arg.kind == .Literal && arg.value.kind == .Array {
		items := query.items_of(arg.value)
		steps := make([dynamic]tape.Step, 0, len(items), a.scratch)
		static := true
		for item, i in items {
			if kind, _, is_fact := query.fact_step_literal(item); is_fact {
				if i + 1 == len(items) && kind != .Content {
					return prepend_all_steps(a, steps[:], grain_need(a, .Exists, true))
				}
				return whole_need(.Whole_Op, true)
			}
			if item.kind == .String {
				append(&steps, tape.Name(query.text_of(item)))
			} else if idx, ok := query.as_i64(item); ok && idx >= -(1 << 30) && idx <= (1 << 30) {
				append(&steps, tape.Index(int(idx)))
			} else {
				static = false
				break
			}
		}
		if static {
			return prepend_all_steps(a, steps[:], out)
		}
	}
	return need_join(a, demand_node(a, arg, whole_need(.Whole_Op), env), whole_need(.Dynamic_Step, out.facts))
}

@(private = "file")
literal_nonneg_int :: proc(n: ^Node) -> (int, bool) {
	if n.kind != .Literal || n.value.kind != .Int || n.value.i < 0 || n.value.i > (1 << 30) {
		return 0, false
	}
	return int(n.value.i), true
}

@(private = "file")
is_pure_path_expr :: proc(a: ^Analyzer, root: ^Node) -> bool {
	stack := make([dynamic]^Node, 0, 8, a.scratch)
	append(&stack, root)
	for len(stack) > 0 {
		n := pop(&stack)
		if n == nil {
			return false
		}
		#partial switch n.kind {
		case .Identity:
		case .Field, .Iterate, .Index, .Slice: append(&stack, n.a)
		case .Pipe, .Comma:                    append(&stack, n.b, n.a)
		case .Call:
			if n.builtin == nil || n.builtin.op != .Select {
				return false
			}
		case: return false
		}
	}
	return true
}

@(private = "file")
is_non_filtering :: proc(a: ^Analyzer, root: ^Node) -> bool {
	stack := make([dynamic]^Node, 0, 8, a.scratch)
	append(&stack, root)
	for len(stack) > 0 {
		n := pop(&stack)
		if n == nil {
			return false
		}
		#partial switch n.kind {
		case .Identity:
		case .Field, .Iterate, .Index:
			if .Opt in n.flags || (n.kind == .Index && n.b.kind != .Literal) {
				return false
			}
			append(&stack, n.a)
		case .Pipe: append(&stack, n.b, n.a)
		case:       return false
		}
	}
	return true
}

// ---- Serial, globals & facts scan over reachable AST

@(private = "file")
walk_reachable :: proc(prog: ^Program, alloc: runtime.Allocator, ctx: rawptr, visit: proc(ctx: rawptr, n: ^Node) -> bool) {
	if prog == nil || prog.body == nil {
		return
	}
	seen := make([dynamic]^Func, 0, 16, alloc)
	defer delete(seen)
	stack := make([dynamic]^Node, 0, 64, alloc)
	defer delete(stack)
	append(&stack, prog.body)
	for len(stack) > 0 {
		n := pop(&stack)
		if !visit(ctx, n) {
			return
		}
		if n.kind == .Call && n.ref.kind == .Def && n.callee != nil && !slice.contains(seen[:], n.callee) {
			append(&seen, n.callee)
			if n.callee.body != nil {
				append(&stack, n.callee.body)
			}
		}
		for i in 0 ..< child_count(n) {
			if c := child(n, i); c != nil {
				append(&stack, c)
			}
		}
	}
}

@(private = "file")
collect_serial :: proc(prog: ^Program, alloc: runtime.Allocator) -> (why: query.Serial_Flags) {
	if prog == nil || prog.body == nil {
		return
	}
	Frame :: struct { n: ^Node, exit_fn: ^Func }
	on := make([dynamic]^Func, 0, 16, alloc)
	done := make([dynamic]^Func, 0, 16, alloc)
	stack := make([dynamic]Frame, 0, 64, alloc)
	append(&stack, Frame{n = prog.body})
	for len(stack) > 0 {
		fr := pop(&stack)
		if fr.exit_fn != nil {
			pop(&on)
			append(&done, fr.exit_fn)
			continue
		}
		n := fr.n
		if n == nil {
			continue
		}
		for i := child_count(n) - 1; i >= 0; i -= 1 {
			if c := child(n, i); c != nil {
				append(&stack, Frame{n = c})
			}
		}
		if n.kind != .Call {
			continue
		}
		if n.builtin != nil {
			#partial switch n.builtin.op {
			case .Input, .Inputs:    why += {.Inputs}
			case .Debug, .Stderr:    why += {.Messages}
			case .Halt, .Halt_Error: why += {.Halts}
			case .None:
				if n.builtin.name == "input_filename" || n.builtin.name == "input_line_number" {
					why += {.Position}
				}
			}
		}
		if n.ref.kind == .Def && n.callee != nil {
			f := n.callee
			if (f.prelude && f.name == "recurse" && len(n.args) > 0) || slice.contains(on[:], f) {
				why += {.Recurses}
			} else if !slice.contains(done[:], f) {
				append(&on, f)
				append(&stack, Frame{exit_fn = f})
				if f.body != nil {
					append(&stack, Frame{n = f.body})
				}
			}
		}
	}
	return
}

used_globals_of :: proc(prog: ^Program, allocator := context.allocator) -> []bool {
	if prog == nil || len(prog.globals) == 0 {
		return nil
	}
	used := make([]bool, len(prog.globals), allocator)
	visit :: proc(ctx: rawptr, n: ^Node) -> bool {
		u := (^[]bool)(ctx)^
		if n.kind == .Var && n.ref.kind == .Global && int(n.ref.slot) < len(u) {
			u[n.ref.slot] = true
		}
		return true
	}
	walk_reachable(prog, allocator, &used, visit)
	return used
}

@(private = "file")
collect_ext_reachable :: proc(a: ^Analyzer) {
	visit :: proc(ctx: rawptr, n: ^Node) -> bool {
		an := (^Analyzer)(ctx)
		if n.kind == .Var && n.ref.kind == .Global && int(n.ref.slot) < len(an.global_to_ext) {
			if ext_i := an.global_to_ext[n.ref.slot]; ext_i >= 0 {
				an.ext_reachable[ext_i], an.has_reachable_ext = true, true
			}
		}
		return true
	}
	walk_reachable(a.prog, a.scratch, a, visit)
}

@(private = "file")
needs_facts :: proc(prog: ^Program, alloc: runtime.Allocator) -> bool {
	found := false
	visit :: proc(ctx: rawptr, n: ^Node) -> bool {
		if n.kind == .Index && n.b.kind == .Literal {
			if _, _, is_fact := query.fact_step_literal(n.b.value); is_fact {
				(^bool)(ctx)^ = true
				return false
			}
		}
		if n.kind == .Call && n.builtin != nil && (n.builtin.op == .Css || n.builtin.fn == v_fact_step || n.builtin.fn == v_attribute_step) {
			(^bool)(ctx)^ = true
			return false
		}
		return true
	}
	walk_reachable(prog, alloc, &found, visit)
	return found
}

// ---- Plan Hints extraction

@(private = "file")
extract_hints :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, materialize: bool, allocator: runtime.Allocator) {
	root := body
	for root != nil && root.kind == .Def {
		root = root.a
	}
	if root != nil {
		extract_split(a, root, plan, materialize, allocator)
		extract_projection(a, root, plan, allocator)
		extract_conditional(a, root, plan, allocator)
	}
}

@(private = "file")
extract_split :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, materialize: bool, allocator: runtime.Allocator) {
	steps := make([dynamic]tape.Step, 0, 4, a.scratch)
	owned := &plan.owned_nodes if materialize else nil
	is_len :: proc "contextless" (n: ^Node) -> bool {
		return n != nil && n.kind == .Call && n.ref.kind == .None && n.builtin != nil && n.builtin.name == "length" && n.builtin.arity == 0
	}
	if is_len(body) {
		plan.hints.split = {kind = .Length}
		return
	}
	if body.kind == .Pipe && is_len(body.b) {
		if collect_static_steps(body.a, &steps, .Names) && len(steps) > 0 {
			plan.hints.split = {kind = .Length, prefix = slice.clone(steps[:], allocator)}
			return
		}
		clear(&steps)
		if body.a.kind == .Array && body.a.a != nil {
			if each, borrowed, ok := split_iterate_prefix(a, body.a.a, &steps, owned, allocator); ok {
				each_d := finalize_need(a, demand_node(a, each, {}, nil), allocator) if each != nil else query.Source_Demand{}
				plan.hints.split = {kind = .Length, prefix = slice.clone(steps[:], allocator), each_demand = each_d, has_each = each != nil}
				plan.each_body = each if borrowed else nil
				return
			}
		}
	}
	clear(&steps)
	if body.kind == .Reduce && body.a.kind == .Iterate && (.Opt not_in body.a.flags) && collect_static_steps(body.a.a, &steps, .Names) {
		frame := Var_Frame{slots = make([]Need, int(body.slots), a.scratch)}
		_ = demand_node(a, body.c, whole_need(.Whole_Op), &frame)
		_, pat_need := lift_patterns(a, body.patterns, frame.slots, &frame if len(body.patterns) > 1 else nil)
		plan.hints.split = {kind = .Reduce, prefix = slice.clone(steps[:], allocator), each_demand = finalize_need(a, pat_need, allocator), has_each = true}
		plan.each_body = body.c
		return
	}
	clear(&steps)
	if each, tail, borrowed, ok := split_collect(a, body, &steps, owned, allocator); ok {
		tail_elem := unwrap_container_need(a, demand_node(a, tail, whole_need(.Identity), nil), false, "") if tail != nil else whole_need(.Identity)
		each_need := demand_node(a, each, tail_elem, nil) if each != nil else tail_elem
		plan.hints.split = {kind = .Collect, prefix = slice.clone(steps[:], allocator), each_demand = finalize_need(a, each_need, allocator), has_each = each != nil, has_tail = tail != nil}
		plan.each_body, plan.tail_body = each if borrowed else nil, tail
		return
	}
	clear(&steps)
	if each, borrowed, ok := split_iterate_prefix(a, body, &steps, owned, allocator); ok {
		each_d := finalize_need(a, demand_node(a, each, whole_need(.Identity), nil), allocator) if each != nil else query.whole_demand(false, .Identity)
		plan.hints.split = {kind = .Stream, prefix = slice.clone(steps[:], allocator), each_demand = each_d, has_each = each != nil}
		plan.each_body = each if borrowed else nil
	}
}

@(private = "file")
Static_Step_Mode :: enum u8 { Names, Nonneg_Idx, Any_Idx }

@(private = "file")
collect_static_steps :: proc(n: ^Node, steps: ^[dynamic]tape.Step, mode: Static_Step_Mode) -> bool {
	at := len(steps)
	for cur := n; cur != nil && (.Opt not_in cur.flags); {
		#partial switch cur.kind {
		case .Identity: return true
		case .Field:
			inject_at(steps, at, tape.Name(cur.name))
			cur = cur.a
		case .Index:
			if mode == .Nonneg_Idx {
				if idx, ok := literal_nonneg_int(cur.b); ok {
					inject_at(steps, at, tape.Index(idx))
					cur = cur.a
					continue
				}
			} else if mode == .Any_Idx && cur.b.kind == .Literal {
				if idx, ok := query.as_i64(cur.b.value); ok && idx >= -(1 << 30) && idx <= (1 << 30) {
					inject_at(steps, at, tape.Index(int(idx)))
					cur = cur.a
					continue
				}
			}
			resize(steps, at)
			return false
		case:
			resize(steps, at)
			return false
		}
	}
	resize(steps, at)
	return false
}

@(private = "file")
is_const_literal_expr :: proc "contextless" (n: ^Node) -> bool {
	return n != nil && (n.kind == .Literal || (n.kind == .Neg && n.a != nil && n.a.kind == .Literal))
}

@(private = "file")
mk_plan_node :: proc(a: ^Analyzer, owned: ^[dynamic]^Node, val: Node, allocator: runtime.Allocator) -> ^Node {
	x: ^Node
	if owned == nil {
		x = new_clone(val, a.scratch)
	} else {
		if owned.allocator.procedure == nil {
			owned.allocator = allocator
		}
		x = new_clone(val, allocator)
		append(owned, x)
	}
	a0, b0, c0 := x.a, x.b, x.c
	single := is_single(a0) && is_single(b0) && is_single(c0)
	nat := false
	h := max(int(a0.height) if a0 != nil else 0, int(b0.height) if b0 != nil else 0, int(c0.height) if c0 != nil else 0)
	x.height = u8(min(h + 1, 255))
	#partial switch x.kind {
	case .Identity, .Literal, .Var: single, nat = true, true
	case .Field, .Index, .Slice, .Pipe:
		nat = single && (a0 == nil || .Native in a0.flags) && (b0 == nil || .Native in b0.flags) && (c0 == nil || .Native in c0.flags) && int(x.height) <= NATIVE_HEIGHT
	case .Iterate: single, nat = false, false
	}
	x.flags = (x.flags + {.Single}) if single else (x.flags - {.Single})
	x.flags = (x.flags + {.Native}) if nat else (x.flags - {.Native})
	return x
}

@(private = "file")
split_iterate_prefix :: proc(a: ^Analyzer, n: ^Node, steps: ^[dynamic]tape.Step, owned: ^[dynamic]^Node, allocator: runtime.Allocator) -> (each: ^Node, borrowed, ok: bool) {
	at := len(steps)
	stages := make([dynamic]^Node, 0, 4, a.scratch)
	cur := n
	for cur != nil && cur.kind == .Pipe {
		append(&stages, cur.b)
		cur = cur.a
	}
	append(&stages, cur)
	i := len(stages) - 1
	for i > 0 && collect_static_steps(stages[i], steps, .Nonneg_Idx) {
		i -= 1
	}
	head := stages[i]
	wraps := make([dynamic]^Node, 0, 4, a.scratch)
	for head != nil {
		if head.kind == .Iterate && (.Opt not_in head.flags) && collect_static_steps(head.a, steps, .Nonneg_Idx) {
			break
		}
		valid := false
		#partial switch head.kind {
		case .Field, .Iterate: valid = true
		case .Index:           valid = is_const_literal_expr(head.b)
		case .Slice:           valid = (head.b == nil || is_const_literal_expr(head.b)) && (head.c == nil || is_const_literal_expr(head.c))
		}
		if !valid {
			resize(steps, at)
			return nil, false, false
		}
		append(&wraps, head)
		head = head.a
	}
	if head == nil || head.kind != .Iterate || (.Opt in head.flags) {
		resize(steps, at)
		return nil, false, false
	}
	each_head: ^Node
	if len(wraps) > 0 {
		each_head = mk_plan_node(a, owned, Node{kind = .Identity}, allocator)
		#reverse for w in wraps {
			clone := w^
			clone.a = each_head
			each_head = mk_plan_node(a, owned, clone, allocator)
		}
	}
	if i == 0 {
		return each_head, each_head == nil || owned != nil, true
	}
	if each_head == nil && i == 1 {
		return stages[0], true, true
	}
	tail := each_head if each_head != nil else stages[i - 1]
	for j := (i - 1) if each_head != nil else (i - 2); j >= 0; j -= 1 {
		tail = mk_plan_node(a, owned, Node{kind = .Pipe, a = tail, b = stages[j]}, allocator)
	}
	return tail, owned != nil, true
}

@(private = "file")
split_collect :: proc(a: ^Analyzer, n: ^Node, steps: ^[dynamic]tape.Step, owned: ^[dynamic]^Node, allocator: runtime.Allocator) -> (each, tail: ^Node, borrowed, ok: bool) {
	at := len(steps)
	c := n
	for c != nil && c.kind == .Pipe && collect_static_steps(c.a, steps, .Nonneg_Idx) {
		c = c.b
	}
	if c != nil && c.kind == .Pipe {
		c, tail = c.a, c.b
	}
	if c != nil {
		if c.kind == .Call && c.ref.kind == .Def && c.callee != nil && c.callee.prelude && c.callee.name == "map" && len(c.args) == 1 {
			return c.args[0], tail, true, true
		}
		if c.kind == .Array && c.a != nil {
			if e, e_borrowed, matched := split_iterate_prefix(a, c.a, steps, owned, allocator); matched {
				return e, tail, e_borrowed, true
			}
		}
	}
	resize(steps, at)
	return nil, nil, false, false
}

@(private = "file")
extract_projection :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, allocator: runtime.Allocator) {
	fields := make([dynamic]query.Projection_Field, 0, 4, a.scratch)
	shape := query.Projection_Shape.None
	#partial switch body.kind {
	case .Object:
		if len(body.args) == 0 {
			return
		}
		for i := 0; i < len(body.args); i += 2 {
			k, v := body.args[i], body.args[i + 1]
			steps := make([dynamic]tape.Step, 0, 4, a.scratch)
			if k.kind != .Literal || k.value.kind != .String || v == nil || !collect_static_steps(v, &steps, .Any_Idx) || len(steps) == 0 {
				return
			}
			key := query.text_of(k.value)
			for f in fields {
				if f.key == key {
					return
				}
			}
			append(&fields, query.Projection_Field{key = key, path = steps[:]})
		}
		shape = .Object
	case .Array, .Comma:
		root := body.a if body.kind == .Array else body
		if root == nil || !collect_path_comma(a, root, &fields) || len(fields) == 0 {
			return
		}
		shape = .Array if body.kind == .Array else .Stream
	case .Field, .Index:
		steps := make([dynamic]tape.Step, 0, 4, a.scratch)
		if !collect_static_steps(body, &steps, .Any_Idx) || len(steps) == 0 {
			return
		}
		append(&fields, query.Projection_Field{path = steps[:]})
		shape = .Single
	}
	if shape != .None {
		out := make([]query.Projection_Field, len(fields), allocator)
		for f, i in fields {
			out[i] = {key = f.key, path = slice.clone(f.path, allocator)}
		}
		plan.hints.projection = {shape = shape, fields = out}
	}
}

@(private = "file")
collect_path_comma :: proc(a: ^Analyzer, root: ^Node, fields: ^[dynamic]query.Projection_Field) -> bool {
	stack := make([dynamic]^Node, 0, 8, a.scratch)
	append(&stack, root)
	for len(stack) > 0 {
		n := pop(&stack)
		if n == nil {
			return false
		}
		if n.kind == .Comma {
			append(&stack, n.b, n.a)
			continue
		}
		steps := make([dynamic]tape.Step, 0, 4, a.scratch)
		if !collect_static_steps(n, &steps, .Any_Idx) || len(steps) == 0 {
			return false
		}
		append(fields, query.Projection_Field{path = steps[:]})
	}
	return true
}

@(private = "file")
extract_conditional :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, allocator: runtime.Allocator) {
	if body.kind != .Call || body.ref.kind != .None || body.builtin == nil || body.builtin.op != .Select || len(body.args) != 1 {
		return
	}
	pred := body.args[0]
	plan.hints.conditional.active = true
	plan.hints.conditional.pred_demand = finalize_need(a, demand_node(a, pred, grain_need(a, .Exists), nil), allocator)
	plan.pred_body = pred
	if pred.kind == .Binary && pred.op >= .Eq && pred.op <= .Ge && pred.b.kind == .Literal {
		if t := query.type_of(pred.b.value); t != .Array && t != .Object {
			steps := make([dynamic]tape.Step, 0, 4, a.scratch)
			if collect_static_steps(pred.a, &steps, .Any_Idx) && len(steps) > 0 {
				plan.hints.conditional.cmp = {
					path    = slice.clone(steps[:], allocator),
					op      = query.Compare_Op(int(pred.op) - int(Op.Eq) + int(query.Compare_Op.Eq)),
					literal = pred.b.value,
				}
			}
		}
	}
}
