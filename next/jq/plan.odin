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
// 3. Three optional execution hints (`Per_Element_Split`, `Projection_Template`, `Conditional_Whole`).
// Soundness invariant: every byte read at run time is covered by the analyzed demand; caps or dynamic
// constructs degrade only the affected part to `.Whole`.

Analyze_Options :: struct {
	null_input:       bool, // -n: `.` is null, inputs come through `input`/`inputs`
	slurp:            bool, // -s: `.` is an array of all input records
	raw_input:        bool, // -R: inputs are raw strings
	stream:           bool, // --stream: always demands whole
	materialize_each: bool, // keep synthesized split `each_body` AST nodes in `owned_nodes` (caller MUST use `jq.destroy_plan`)
}

// A jq program's query plan: the shared `query.Plan` contract plus borrowed/owned AST roots for the hints.
Plan :: struct {
	using contract: query.Plan,
	each_body:      ^Node, // borrowed from `Program` or `owned_nodes`; set when `hints.split.has_each`
	tail_body:      ^Node, // borrowed from `Program`; set when `hints.split.has_tail`
	pred_body:      ^Node, // borrowed from `Program`; set when `hints.conditional.active`
	owned_nodes:    [dynamic]^Node, // synthesized hint AST nodes freed by `jq.destroy_plan` (populated only when `materialize_each`)
}

@(private = "file")
MAX_ANALYSIS_DEPTH :: 32
@(private = "file")
MAX_MEMO_ENTRIES :: 256
@(private = "file")
MAX_CALL_DEPTH :: 64

// Abstract backward demand on one value during analysis. Every slice lives in `Analyzer.scratch`.
@(private = "file")
Need :: struct {
	whole:  bool,
	facts:  bool,
	reason: query.Whole_Reason,
	paths:  []query.Demand_Path,
}

@(private = "file")
Var_Frame :: struct {
	parent: ^Var_Frame,
	slots:  []Need, // demand accumulated for each local variable slot
	args:   []Arg_Binding, // filter parameters of a jq function call
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

// Analyzes `prog` under `opts`, allocating the returned `Plan` in `allocator`. Free with `destroy_plan`.
analyze :: proc(prog: ^Program, opts := Analyze_Options{}, allocator := context.allocator) -> Plan {
	plan, _ := analyze_plan_with_vars(prog, nil, opts, allocator)
	return plan
}

// Reports whether `prog` is the bare identity filter `.`.
is_identity :: proc "contextless" (prog: ^Program) -> bool {
	return prog != nil && prog.body != nil && prog.body.kind == .Identity
}

// Analyzes `prog` with named external `$var` bindings `ext_vars`, returning the shared `query.Plan` contract.
// Each variable in `ext_vars` is recorded in `plan.aux` with its pruned `Source_Demand`.
// Free the returned plan with `query.destroy_plan`.
analyze_with_vars :: proc(
	prog: ^Program,
	ext_vars: []string,
	allocator := context.allocator,
	opts := Analyze_Options{},
) -> (
	plan: query.Plan,
	ok: bool,
) {
	jq_plan, valid := analyze_plan_with_vars(prog, ext_vars, opts, allocator)
	if !valid {
		return {}, false
	}
	destroy_jq_extras(&jq_plan)
	return jq_plan.contract, true
}

// Analyzes `prog` with named external `$var` bindings `ext_vars`, returning the full `jq.Plan` (with hints + `aux`).
analyze_plan_with_vars :: proc(
	prog: ^Program,
	ext_vars: []string,
	opts := Analyze_Options{},
	allocator := context.allocator,
) -> (
	plan: Plan,
	ok: bool,
) {
	if prog == nil {
		return {}, false
	}
	a: Analyzer
	mem.dynamic_arena_init(&a.arena, allocator, allocator)
	defer mem.dynamic_arena_destroy(&a.arena)
	a.prog = prog
	a.scratch = mem.dynamic_arena_allocator(&a.arena)
	a.active_fns = make([dynamic]^Func, 0, 16, a.scratch)
	a.memo = make([dynamic]Memo_Entry, 0, 32, a.scratch)

	init_ext_vars(&a, ext_vars)

	// Always collect serial flags across the entire reachable program (even dead branches).
	a.serial = collect_serial(prog, a.scratch)
	if len(a.ext_names) > 0 {
		collect_ext_reachable(&a)
	}

	plan = Plan{contract = {allocator = allocator}}
	plan.serial = a.serial

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

	if opts.null_input {
		plan.sources[.Main] = {mode = .None, allocator = allocator}
	} else if opts.raw_input {
		plan.sources[.Raw] = finalize_need(&a, root_need, allocator)
	} else if opts.slurp {
		elem := array_element_need(&a, root_need)
		plan.sources[.Slurp] = finalize_need(&a, elem, allocator)
		plan.sources[.Main] = finalize_need(&a, root_need, allocator)
	} else {
		plan.sources[.Main] = finalize_need(&a, root_need, allocator)
	}

	if a.inputs_need.whole || len(a.inputs_need.paths) > 0 || a.inputs_need.facts {
		plan.sources[.Inputs] = finalize_need(&a, a.inputs_need, allocator)
	}

	finalize_ext_aux(&a, &plan.contract, allocator)

	// Extract optional execution hints (only for standard non-slurp, non-null-input, non-raw runs).
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
		if name == "" {
			continue
		}
		dup := false
		for prev in names {
			if prev == name {
				dup = true
				break
			}
		}
		if !dup {
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
	for &m in a.global_to_ext {
		m = -1
	}
	for g, gi in a.prog.globals {
		for name, ei in names {
			if g == name {
				a.global_to_ext[gi] = ei
				break
			}
		}
	}
}

@(private = "file")
finalize_ext_aux :: proc(a: ^Analyzer, contract: ^query.Plan, allocator: runtime.Allocator) {
	if len(a.ext_names) == 0 {
		return
	}
	entries := make([]query.Named_Demand, len(a.ext_names), a.scratch)
	for name, i in a.ext_names {
		entries[i] = {
			name   = name,
			demand = finalize_need(a, a.ext_needs[i], allocator),
		}
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
	a := p.allocator
	for n in p.owned_nodes {
		free(n, a)
	}
	delete(p.owned_nodes)
	p.owned_nodes = nil
}

destroy_plan :: proc(p: ^Plan) {
	destroy_jq_extras(p)
	query.destroy_plan(&p.contract)
	p^ = {}
}

// Formats `p` as a human-readable `--explain` string in `allocator`.
explain_plan :: proc(p: ^Plan, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	query.format_plan(&b, &p.contract)
	return strings.to_string(b)
}

// ---- Need algebra

@(private = "file")
empty_need :: #force_inline proc "contextless" () -> Need {
	return {}
}

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
	if x.whole {
		return {whole = true, facts = facts, reason = x.reason if x.reason != .None else y.reason}
	}
	if y.whole {
		return {whole = true, facts = facts, reason = y.reason if y.reason != .None else x.reason}
	}
	if len(x.paths) == 0 {
		out := y
		out.facts = facts
		return out
	}
	if len(y.paths) == 0 {
		out := x
		out.facts = facts
		return out
	}
	out := make([dynamic]query.Demand_Path, 0, len(x.paths) + len(y.paths), a.scratch)
	append(&out, ..x.paths)
	for p in y.paths {
		merged := false
		for &k in out {
			if query.steps_equal(k.steps, p.steps) {
				k.grain = query.broader_grain(k.grain, p.grain)
				k.limit = query.merge_limit(k.limit, p.limit)
				merged = true
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
	h := u64(0xCBF29CE484222325)
	mix :: #force_inline proc "contextless" (h, v: u64) -> u64 {
		return (h ~ v) * 0x100000001B3
	}
	h = mix(h, u64(n.whole) | u64(n.facts) << 1)
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
			case tape.Index:
				h = mix(h, 2)
				h = mix(h, u64(i64(step)))
			case tape.All:
				h = mix(h, 3)
				h = mix(h, u64(step.limit))
			case tape.Slice:
				h = mix(h, 4)
				h = mix(h, u64(i64(step.lo)))
				if hi, ok := step.hi.?; ok {
					h = mix(h, u64(i64(hi)))
				}
			case tape.Descend:
				h = mix(h, 5)
			}
		}
	}
	return h
}

// Prepends `step` to every path in `child`, keeping at least `[step]@min_grain` when `child` is empty.
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

// Whether consumer demand `out` is safe to combine with a path-level `limit` from `first`/`limit`:
// rejects demands that fan out across multiple children or read container length after the limit boundary.
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
			case tape.All, tape.Slice, tape.Descend:
				return false
			case tape.Index:
				if step < 0 {
					return false
				}
			}
		}
	}
	return true
}

// Marks all reachable outer variable slots (and `inputs_need` if the program reads inputs) `.Whole` on
// a recursion or cap bailout so no skipped variable/input read is under-demanded.
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

// Applies a path-level `limit` to every path in `n` (used for `first(f)` and `limit(k; f)`).
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

// Unwraps one array-element layer from consumer demand `out` (for `[a]`, `a[lo:hi]`, and `-s` slurp).
@(private = "file")
array_element_need :: proc(a: ^Analyzer, out: Need) -> Need {
	if out.whole {
		return whole_need(out.reason, out.facts)
	}
	acc := empty_need()
	for p in out.paths {
		if len(p.steps) == 0 {
			if p.grain == .Whole {
				return whole_need(.Identity, out.facts)
			}
			// `.Keys` or `.Exists` on a built array does not inspect elements.
			continue
		}
		switch _ in p.steps[0] {
		case tape.Index, tape.All, tape.Slice:
			rest := p.steps[1:]
			if len(rest) == 0 && p.grain == .Whole {
				return whole_need(.Identity, out.facts)
			}
			sub := make([]query.Demand_Path, 1, a.scratch)
			sub[0] = {steps = rest, grain = p.grain}
			acc = need_join(a, acc, {facts = out.facts, paths = sub})
		case tape.Descend:
			return whole_need(.Whole_Op, out.facts)
		case tape.Name:
			// Indexing an array with a name fails on the array itself, not its elements.
		}
	}
	return acc
}

// Unwraps one object-member layer for static key `key_name` from consumer demand `out` (for `{k: v}`).
@(private = "file")
object_member_need :: proc(a: ^Analyzer, out: Need, key_name: string) -> Need {
	if out.whole {
		return whole_need(out.reason, out.facts)
	}
	acc := empty_need()
	for p in out.paths {
		if len(p.steps) == 0 {
			if p.grain == .Whole {
				return whole_need(.Identity, out.facts)
			}
			continue
		}
		#partial switch step in p.steps[0] {
		case tape.Name:
			if string(step) != key_name {
				continue
			}
			rest := p.steps[1:]
			if len(rest) == 0 && p.grain == .Whole {
				return whole_need(.Identity, out.facts)
			}
			sub := make([]query.Demand_Path, 1, a.scratch)
			sub[0] = {steps = rest, grain = p.grain}
			acc = need_join(a, acc, {facts = out.facts, paths = sub})
		case tape.All:
			rest := p.steps[1:]
			if len(rest) == 0 && p.grain == .Whole {
				return whole_need(.Identity, out.facts)
			}
			sub := make([]query.Demand_Path, 1, a.scratch)
			sub[0] = {steps = rest, grain = p.grain}
			acc = need_join(a, acc, {facts = out.facts, paths = sub})
		case tape.Descend:
			return whole_need(.Whole_Op, out.facts)
		}
	}
	return acc
}

@(private = "file")
finalize_need :: proc(a: ^Analyzer, n: Need, allocator: runtime.Allocator) -> query.Source_Demand {
	if n.whole {
		return query.whole_demand(n.facts, n.reason if n.reason != .None else .Identity)
	}
	if len(n.paths) == 0 {
		if n.facts {
			return query.whole_demand(true, .Whole_Op)
		}
		return {mode = .None, allocator = allocator}
	}
	return query.finalize_source_demand(n.paths, n.facts, allocator)
}

// ---- Backward demand transfer

@(private = "file")
demand_node :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	if n == nil {
		return empty_need()
	}
	if a.call_depth > MAX_CALL_DEPTH {
		taint_outer_env(a, env, .Analysis_Cap, out.facts)
		return whole_need(.Analysis_Cap, out.facts)
	}
	a.call_depth += 1
	defer a.call_depth -= 1

	switch n.kind {
	case .Identity:
		return out
	case .Literal:
		return empty_need()
	case .Var:
		if n.ref.kind == .Var {
			f := var_frame_up(env, n.ref.hops)
			if f != nil && int(n.ref.slot) < len(f.slots) {
				f.slots[n.ref.slot] = need_join(a, f.slots[n.ref.slot], out)
			}
		} else if n.ref.kind == .Global && int(n.ref.slot) < len(a.global_to_ext) {
			ext_i := a.global_to_ext[n.ref.slot]
			if ext_i >= 0 {
				a.ext_needs[ext_i] = need_join(a, a.ext_needs[ext_i], out)
			}
		}
		return empty_need()
	case .Field:
		return demand_node(a, n.a, need_prepend(a, tape.Name(n.name), out), env)
	case .Index:
		return demand_index(a, n, out, env)
	case .Slice:
		return demand_slice(a, n, out, env)
	case .Iterate:
		return demand_node(a, n.a, need_prepend(a, tape.All{}, out), env)
	case .String:
		acc := empty_need()
		for part in n.args {
			acc = need_join(a, acc, demand_node(a, part, whole_need(.Whole_Op), env))
		}
		return acc
	case .Format:
		if n.a == nil {
			return whole_need(.Whole_Op)
		}
		return demand_node(a, n.a, whole_need(.Whole_Op), env)
	case .Array:
		if n.a == nil {
			return empty_need()
		}
		return demand_node(a, n.a, array_element_need(a, out), env)
	case .Object:
		acc := empty_need()
		for i := 0; i < len(n.args); i += 2 {
			k, v := n.args[i], n.args[i + 1]
			if k.kind == .Literal && k.value.kind == .String {
				key_name := query.text_of(k.value)
				if v != nil {
					acc = need_join(a, acc, demand_node(a, v, object_member_need(a, out, key_name), env))
				}
			} else {
				acc = need_join(a, acc, demand_node(a, k, whole_need(.Dynamic_Step), env))
				if v == nil {
					// Shorthand `{(expr)}`: indexes `.` dynamically by `expr`.
					acc = need_join(a, acc, whole_need(.Dynamic_Step, out.facts))
				} else {
					val_out := empty_need()
					if out.whole || has_non_shallow_path(out) {
						val_out = whole_need(.Dynamic_Step, out.facts)
					}
					acc = need_join(a, acc, demand_node(a, v, val_out, env))
				}
			}
		}
		return acc
	case .Neg:
		return demand_node(a, n.a, whole_need(.Whole_Op), env)
	case .Pipe:
		db := demand_node(a, n.b, out, env)
		return demand_node(a, n.a, db, env)
	case .Comma:
		da := demand_node(a, n.a, out, env)
		db := demand_node(a, n.b, out, env)
		return need_join(a, da, db)
	case .Binary:
		da := demand_node(a, n.a, whole_need(.Whole_Op), env)
		db := demand_node(a, n.b, whole_need(.Whole_Op), env)
		return need_join(a, da, db)
	case .And, .Or:
		da := demand_node(a, n.a, grain_need(a, .Exists), env)
		db := demand_node(a, n.b, grain_need(a, .Exists), env)
		return need_join(a, da, db)
	case .Alt:
		da := demand_node(a, n.a, need_join(a, out, grain_need(a, .Exists)), env)
		db := demand_node(a, n.b, out, env)
		return need_join(a, da, db)
	case .If:
		dc := demand_node(a, n.a, grain_need(a, .Exists), env)
		dt := demand_node(a, n.b, out, env)
		de := demand_node(a, n.c, out, env) if n.c != nil else out
		return need_join(a, need_join(a, dc, dt), de)
	case .Try:
		da := demand_node(a, n.a, out, env)
		if n.b != nil {
			// Catch runs on the error value, not `.`, so discard its `.` paths while preserving var/input/facts needs.
			db := demand_node(a, n.b, out, env)
			da.facts ||= db.facts
		}
		return da
	case .Bind:
		return demand_bind(a, n, out, env)
	case .Reduce, .Foreach:
		return demand_fold(a, n, out, env)
	case .Def:
		return demand_node(a, n.a, out, env)
	case .Label:
		frame := Var_Frame{parent = env}
		return demand_node(a, n.a, out, &frame)
	case .Break:
		return empty_need()
	case .Update:
		da := demand_node(a, n.a, whole_need(.Whole_Op), env)
		db := demand_node(a, n.b, whole_need(.Whole_Op), env)
		return whole_need(.Whole_Op, out.facts || da.facts || db.facts)
	case .Call:
		return demand_call(a, n, out, env)
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
		// Static fact step: `.@comment`, `.@tag`, `.&attr`, etc.
		if kind, _, is_fact := query.fact_step_literal(b.value); is_fact {
			if kind == .Content {
				return demand_node(a, n.a, whole_need(.Whole_Op, true), env)
			}
			return demand_node(a, n.a, grain_need(a, .Exists, true), env)
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
	// Dynamic fact / attribute accessor: `.@(expr)` or `.&[expr]`.
	if b.kind == .Call && b.builtin != nil && (b.builtin.fn == v_fact_step || b.builtin.fn == v_attribute_step) {
		dk := demand_node(a, b.args[0], whole_need(.Whole_Op), env)
		da := demand_node(a, n.a, whole_need(.Dynamic_Step, true), env)
		return need_join(a, dk, da)
	}
	dk := demand_node(a, b, whole_need(.Whole_Op), env)
	elem_need: Need
	if !out.whole && len(out.paths) > 0 && all_paths_start_with_name(out) && b.kind != .Array && b.kind != .Object {
		// Dynamic lookup `$src[expr].field` only accesses `.field` (and siblings in `out`) on matched entries,
		// so keep `[].field` rather than upgrading the entire indexed source to `.Whole`.
		elem_need = need_prepend(a, tape.All{}, out)
	} else {
		elem_need = whole_need(.Dynamic_Step, out.facts)
	}
	da := demand_node(a, n.a, elem_need, env)
	return need_join(a, dk, da)
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
	lo_need := demand_node(a, n.b, whole_need(.Whole_Op), env) if n.b != nil else empty_need()
	hi_need := demand_node(a, n.c, whole_need(.Whole_Op), env) if n.c != nil else empty_need()
	bounds_need := need_join(a, lo_need, hi_need)

	lo := i32(0)
	hi: Maybe(i32) = nil
	static := true
	if n.b != nil {
		if i, ok := literal_exact_i32(n.b); ok {
			lo = i
		} else {
			static = false
		}
	}
	if n.c != nil {
		if i, ok := literal_exact_i32(n.c); ok {
			hi = i
		} else {
			static = false
		}
	}
	if !static {
		return need_join(a, bounds_need, demand_node(a, n.a, whole_need(.Dynamic_Step, out.facts), env))
	}
	// `slice` reads `length_of` (`.Keys` keeps exact array count even under `stop_early`) and elements `lo..hi`.
	elem_out := array_element_need(a, out)
	if need_is_empty(elem_out) {
		elem_out = grain_need(a, .Exists, out.facts)
	}
	slice_need := need_join(a, grain_need(a, .Keys, out.facts), need_prepend(a, tape.Slice{lo = lo, hi = hi}, elem_out))
	da := demand_node(a, n.a, slice_need, env)
	return need_join(a, bounds_need, da)
}

@(private = "file")
literal_exact_i32 :: proc(n: ^Node) -> (i32, bool) {
	if n.kind != .Literal || n.value.kind != .Int {
		return 0, false
	}
	if n.value.i < -(1 << 30) || n.value.i > (1 << 30) {
		return 0, false
	}
	return i32(n.value.i), true
}

@(private = "file")
demand_bind :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	frame := Var_Frame{parent = env, slots = make([]Need, int(n.slots), a.scratch)}
	dot_need := demand_node(a, n.b, out, &frame)
	key_env := &frame if len(n.patterns) > 1 else env
	key_need, pat_need := lift_patterns(a, n.patterns, frame.slots, key_env)
	src_need := demand_node(a, n.a, pat_need, env)
	return need_join(a, need_join(a, dot_need, key_need), src_need)
}

@(private = "file")
demand_fold :: proc(a: ^Analyzer, n: ^Node, out: Need, env: ^Var_Frame) -> Need {
	frame := Var_Frame{parent = env, slots = make([]Need, int(n.slots), a.scratch)}
	acc_need := out
	if n.kind == .Foreach && n.d != nil {
		acc_need = demand_node(a, n.d, out, &frame)
	}
	upd_dot := demand_node(a, n.c, acc_need, &frame)
	acc_need.facts ||= upd_dot.facts
	if !acc_need.whole && !need_equal(need_join(a, acc_need, upd_dot), acc_need) {
		acc_need = whole_need(.Whole_Op, acc_need.facts)
		frame.slots = make([]Need, int(n.slots), a.scratch)
		if n.kind == .Foreach && n.d != nil {
			_ = demand_node(a, n.d, out, &frame)
		}
		upd2 := demand_node(a, n.c, acc_need, &frame)
		acc_need.facts ||= upd2.facts
	}
	key_env := &frame if len(n.patterns) > 1 else env
	key_need, pat_need := lift_patterns(a, n.patterns, frame.slots, key_env)
	init_need := demand_node(a, n.b, acc_need, env)
	gen_need := demand_node(a, n.a, pat_need, env)
	return need_join(a, need_join(a, init_need, key_need), gen_need)
}

// Lifts variable demands in `slots` back through `patterns` into a demand on the bound value,
// plus any demand on `.` from dynamic object-pattern keys.
@(private = "file")
lift_patterns :: proc(a: ^Analyzer, patterns: []^Pattern, slots: []Need, env: ^Var_Frame) -> (key_need, val_need: Need) {
	for pat in patterns {
		kn, vn := lift_pattern(a, pat, slots, env)
		key_need = need_join(a, key_need, kn)
		val_need = need_join(a, val_need, vn)
	}
	// Multiple `?//` alternatives test types during destructuring, so keep at least `.Exists`.
	if len(patterns) > 1 && need_is_empty(val_need) {
		val_need = grain_need(a, .Exists)
	}
	return
}

@(private = "file")
lift_pattern :: proc(a: ^Analyzer, pat: ^Pattern, slots: []Need, env: ^Var_Frame) -> (key_need, val_need: Need) {
	if pat == nil {
		return
	}
	switch pat.kind {
	case .Var:
		if int(pat.slot) < len(slots) {
			return empty_need(), slots[pat.slot]
		}
	case .Array:
		val_need = grain_need(a, .Exists)
		for elem, i in pat.elems {
			kn, vn := lift_pattern(a, elem, slots, env)
			key_need = need_join(a, key_need, kn)
			val_need = need_join(a, val_need, need_prepend(a, tape.Index(i), vn))
		}
	case .Object:
		val_need = grain_need(a, .Exists)
		// Reverse order so dynamic keys referencing earlier pattern variables write into `slots` before those slots are lifted.
		#reverse for m in pat.members {
			member_need := empty_need()
			if m.var != "" && int(m.slot) < len(slots) {
				member_need = need_join(a, member_need, slots[m.slot])
			}
			if m.pattern != nil {
				kn, vn := lift_pattern(a, m.pattern, slots, env)
				key_need = need_join(a, key_need, kn)
				member_need = need_join(a, member_need, vn)
			}
			if m.key != nil && m.key.kind == .Literal && m.key.value.kind == .String {
				val_need = need_join(a, val_need, need_prepend(a, tape.Name(query.text_of(m.key.value)), member_need))
			} else {
				if m.key != nil {
					key_need = need_join(a, key_need, demand_node(a, m.key, whole_need(.Dynamic_Step), env))
				}
				val_need = need_join(a, val_need, whole_need(.Dynamic_Step, member_need.facts))
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
		f := var_frame_up(env, n.ref.hops)
		if f != nil && int(n.ref.slot) < len(f.args) {
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
		// Recursion check.
		if slice.contains(a.active_fns[:], fn) {
			a.serial += {.Recurses}
			arg_need := empty_need()
			for arg in n.args {
				arg_need = need_join(a, arg_need, demand_node(a, arg, whole_need(.Dynamic_Call, out.facts), env))
			}
			taint_outer_env(a, env, .Dynamic_Call, out.facts || arg_need.facts)
			return whole_need(.Dynamic_Call, out.facts || arg_need.facts)
		}
		// Memoize zero-arg functions by `(fn, out)` unless tracked external `$var`s may accumulate per-callsite demands.
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
	b := n.builtin
	if b == nil {
		return whole_need(.Dynamic_Call, out.facts)
	}
	return demand_builtin(a, n, b, out, env)
}

@(private = "file")
demand_builtin :: proc(a: ^Analyzer, n: ^Node, b: ^Builtin, out: Need, env: ^Var_Frame) -> Need {
	switch b.op {
	case .Empty:
		return empty_need()
	case .Select:
		dp := demand_node(a, n.args[0], grain_need(a, .Exists), env)
		return need_join(a, out, dp)
	case .Kind_Filter:
		return need_join(a, out, grain_need(a, .Exists))
	case .Error:
		if len(n.args) > 0 {
			return demand_node(a, n.args[0], whole_need(.Whole_Op), env)
		}
		return whole_need(.Whole_Op)
	case .Path:
		if is_pure_path_expr(n.args[0]) {
			return demand_node(a, n.args[0], empty_need(), env)
		}
		return demand_node(a, n.args[0], whole_need(.Whole_Op), env)
	case .Getpath:
		return demand_getpath(a, n.args[0], out, env)
	case .First:
		df := demand_node(a, n.args[0], out, env)
		if is_non_filtering(n.args[0]) && out_safe_for_limit(out) {
			return need_limit(a, df, 1)
		}
		return df
	case .Limit:
		if k, ok := literal_nonneg_int(n.args[0]); ok {
			if k == 0 {
				return empty_need()
			}
			df := demand_node(a, n.args[1], out, env)
			if is_non_filtering(n.args[1]) && out_safe_for_limit(out) {
				return need_limit(a, df, k)
			}
			return df
		}
		dk := demand_node(a, n.args[0], whole_need(.Whole_Op), env)
		df := demand_node(a, n.args[1], out, env)
		return need_join(a, dk, df)
	case .Skip:
		dk := demand_node(a, n.args[0], whole_need(.Whole_Op), env)
		df := demand_node(a, n.args[1], out, env)
		return need_join(a, dk, df)
	case .Last:
		return demand_node(a, n.args[0], out, env)
	case .Isempty:
		return demand_node(a, n.args[0], empty_need(), env)
	case .Range:
		acc := empty_need()
		for arg in n.args {
			acc = need_join(a, acc, demand_node(a, arg, whole_need(.Whole_Op), env))
		}
		return acc
	case .Input, .Inputs:
		a.serial += {.Inputs}
		a.inputs_need = need_join(a, a.inputs_need, out)
		return empty_need()
	case .Debug, .Stderr:
		a.serial += {.Messages}
		return whole_need(.Whole_Op, out.facts)
	case .Halt:
		a.serial += {.Halts}
		return empty_need()
	case .Halt_Error:
		a.serial += {.Halts}
		da := demand_node(a, n.args[0], whole_need(.Whole_Op), env)
		return need_join(a, da, whole_need(.Whole_Op))
	case .Css:
		da := demand_node(a, n.args[0], whole_need(.Whole_Op), env)
		return need_join(a, da, whole_need(.Whole_Op, true))
	case .None:
		// Value builtins: evaluate arguments on `.`, then apply builtin to `.`.
		args_need := empty_need()
		for arg in n.args {
			args_need = need_join(a, args_need, demand_node(a, arg, whole_need(.Whole_Op), env))
		}
		switch b.name {
		case "not", "type", "where":
			return need_join(a, args_need, grain_need(a, .Exists))
		case "length", "keys", "keys_unsorted":
			return need_join(a, args_need, grain_need(a, .Keys))
		case "has":
			if len(n.args) == 1 && n.args[0].kind == .Literal {
				kv := n.args[0].value
				if kv.kind == .String {
					return need_join(a, args_need, need_prepend(a, tape.Name(query.text_of(kv)), empty_need(), .Exists))
				}
			}
			// `has(N)` on an array reads `length_of`, so keep `.Keys` (exact count even under `stop_early`).
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
demand_getpath :: proc(a: ^Analyzer, arg: ^Node, out: Need, env: ^Var_Frame) -> Need {
	if arg.kind == .Literal && arg.value.kind == .Array {
		items := query.items_of(arg.value)
		steps := make([dynamic]tape.Step, 0, len(items), a.scratch)
		static := true
		facts := out.facts
		for item, i in items {
			if kind, _, is_fact := query.fact_step_literal(item); is_fact {
				facts = true
				if i + 1 == len(items) && kind != .Content {
					// Static path ending in non-content fact.
					res := grain_need(a, .Exists, true)
					#reverse for s in steps {
						res = need_prepend(a, s, res)
					}
					return res
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
			res := out
			res.facts ||= facts
			#reverse for s in steps {
				res = need_prepend(a, s, res)
			}
			return res
		}
	}
	da := demand_node(a, arg, whole_need(.Whole_Op), env)
	return need_join(a, da, whole_need(.Dynamic_Step, out.facts))
}

@(private = "file")
literal_nonneg_int :: proc(n: ^Node) -> (int, bool) {
	if n.kind != .Literal || n.value.kind != .Int || n.value.i < 0 || n.value.i > (1 << 30) {
		return 0, false
	}
	return int(n.value.i), true
}

// Whether `n` is a pure path expression (never builds a non-path value whose brief text error_message would print).
@(private = "file")
is_pure_path_expr :: proc(n: ^Node) -> bool {
	if n == nil {
		return false
	}
	#partial switch n.kind {
	case .Identity:
		return true
	case .Field, .Iterate:
		return is_pure_path_expr(n.a)
	case .Index:
		return is_pure_path_expr(n.a)
	case .Slice:
		return is_pure_path_expr(n.a)
	case .Pipe:
		return is_pure_path_expr(n.a) && is_pure_path_expr(n.b)
	case .Comma:
		return is_pure_path_expr(n.a) && is_pure_path_expr(n.b)
	case .Call:
		if n.builtin != nil && n.builtin.op == .Select {
			return true
		}
	}
	return false
}

// Whether `n` never drops or multiplies outputs before its path steps (so `first(n)` / `limit(k; n)` can bound its demand paths).
@(private = "file")
is_non_filtering :: proc(n: ^Node) -> bool {
	if n == nil {
		return false
	}
	#partial switch n.kind {
	case .Identity:
		return true
	case .Field:
		return .Opt not_in n.flags && is_non_filtering(n.a)
	case .Index:
		return .Opt not_in n.flags && n.b.kind == .Literal && is_non_filtering(n.a)
	case .Iterate:
		return .Opt not_in n.flags && is_non_filtering(n.a)
	case .Pipe:
		return is_non_filtering(n.a) && is_non_filtering(n.b)
	}
	return false
}

// ---- Serial & facts scan over reachable AST

@(private = "file")
collect_serial :: proc(prog: ^Program, alloc: runtime.Allocator) -> query.Serial_Flags {
	why: query.Serial_Flags
	if prog == nil || prog.body == nil {
		return why
	}
	Frame :: struct {
		n:       ^Node,
		exit_fn: ^Func,
	}
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
		if n.kind == .Call {
			if n.builtin != nil {
				#partial switch n.builtin.op {
				case .Input, .Inputs:
					why += {.Inputs}
				case .Debug, .Stderr:
					why += {.Messages}
				case .Halt, .Halt_Error:
					why += {.Halts}
				case .None:
					if n.builtin.name == "input_filename" || n.builtin.name == "input_line_number" {
						why += {.Position}
					}
				}
			}
			if n.ref.kind == .Def && n.callee != nil {
				f := n.callee
				if f.prelude && f.name == "recurse" && len(n.args) > 0 {
					why += {.Recurses}
				}
				if slice.contains(on[:], f) {
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
	}
	return why
}

// Returns a `[]bool` mask indexed by `prog.globals` indicating which global variables are reachable
// from `prog.body`. Caller owns and frees the returned slice with `delete(..., allocator)`.
used_globals_of :: proc(prog: ^Program, allocator := context.allocator) -> []bool {
	if prog == nil {
		return nil
	}
	n_globals := len(prog.globals)
	if n_globals == 0 {
		return nil
	}
	used := make([]bool, n_globals, allocator)
	if prog.body == nil {
		return used
	}
	seen := make([dynamic]^Func, 0, 16, allocator)
	defer delete(seen)
	stack := make([dynamic]^Node, 0, 64, allocator)
	defer delete(stack)
	append(&stack, prog.body)
	for len(stack) > 0 {
		n := pop(&stack)
		if n.kind == .Var && n.ref.kind == .Global && int(n.ref.slot) < len(used) {
			used[n.ref.slot] = true
		} else if n.kind == .Call && n.ref.kind == .Def && n.callee != nil {
			f := n.callee
			if !slice.contains(seen[:], f) {
				append(&seen, f)
				if f.body != nil {
					append(&stack, f.body)
				}
			}
		}
		for i := 0; i < child_count(n); i += 1 {
			if c := child(n, i); c != nil {
				append(&stack, c)
			}
		}
	}
	return used
}

@(private = "file")
collect_ext_reachable :: proc(a: ^Analyzer) {
	if a.prog == nil || a.prog.body == nil {
		return
	}
	seen := make([dynamic]^Func, 0, 16, a.scratch)
	stack := make([dynamic]^Node, 0, 64, a.scratch)
	append(&stack, a.prog.body)
	for len(stack) > 0 {
		node := pop(&stack)
		if node.kind == .Var && node.ref.kind == .Global && int(node.ref.slot) < len(a.global_to_ext) {
			if ext_i := a.global_to_ext[node.ref.slot]; ext_i >= 0 {
				a.ext_reachable[ext_i] = true
				a.has_reachable_ext = true
			}
		} else if node.kind == .Call && node.ref.kind == .Def && node.callee != nil {
			fn := node.callee
			if !slice.contains(seen[:], fn) {
				append(&seen, fn)
				if fn.body != nil {
					append(&stack, fn.body)
				}
			}
		}
		for i := 0; i < child_count(node); i += 1 {
			if c := child(node, i); c != nil {
				append(&stack, c)
			}
		}
	}
}

@(private = "file")
needs_facts :: proc(prog: ^Program, alloc: runtime.Allocator) -> bool {
	if prog == nil || prog.body == nil {
		return false
	}
	seen := make([dynamic]^Func, 0, 16, alloc)
	stack := make([dynamic]^Node, 0, 64, alloc)
	append(&stack, prog.body)
	for len(stack) > 0 {
		n := pop(&stack)
		if n.kind == .Index && n.b.kind == .Literal {
			if _, _, is_fact := query.fact_step_literal(n.b.value); is_fact {
				return true
			}
		}
		if n.kind == .Call {
			if n.builtin != nil && (n.builtin.op == .Css || n.builtin.fn == v_fact_step || n.builtin.fn == v_attribute_step) {
				return true
			}
			if n.ref.kind == .Def && n.callee != nil && !slice.contains(seen[:], n.callee) {
				append(&seen, n.callee)
				if n.callee.body != nil {
					append(&stack, n.callee.body)
				}
			}
		}
		for i := 0; i < child_count(n); i += 1 {
			if c := child(n, i); c != nil {
				append(&stack, c)
			}
		}
	}
	return false
}

// ---- Plan Hints extraction

@(private = "file")
extract_hints :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, materialize: bool, allocator: runtime.Allocator) {
	root := unwrap_defs(body)
	if root == nil {
		return
	}
	extract_split(a, root, plan, materialize, allocator)
	extract_projection(a, root, plan, allocator)
	extract_conditional(a, root, plan, allocator)
}

@(private = "file")
unwrap_defs :: proc "contextless" (n: ^Node) -> ^Node {
	cur := n
	for cur != nil && cur.kind == .Def {
		cur = cur.a
	}
	return cur
}

// Hint 1: Per_Element_Split — `.prefix[] | each`, `[.prefix[] | each] | tail`, `.prefix | map(each) | tail`,
// `.prefix | length`, `[.prefix[] | each] | length`, or `reduce .prefix[] as $x (init; update)`.
@(private = "file")
extract_split :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, materialize: bool, allocator: runtime.Allocator) {
	steps := make([dynamic]tape.Step, 0, 4, a.scratch)

	// 1. `.prefix | length` or `length` or `[.prefix[] | each] | length`.
	if is_builtin_length(body) {
		plan.hints.split = {kind = .Length}
		return
	}
	if body.kind == .Pipe && is_builtin_length(body.b) {
		if static_name_steps(body.a, &steps) && len(steps) > 0 {
			plan.hints.split = {kind = .Length, prefix = slice.clone(steps[:], allocator)}
			return
		}
		clear(&steps)
		if body.a.kind == .Array && body.a.a != nil {
			if each, borrowed, ok := split_iterate_prefix(a, body.a.a, &steps, &plan.owned_nodes if materialize else nil, allocator); ok {
				each_d: query.Source_Demand
				if each != nil {
					each_d = finalize_need(a, demand_node(a, each, empty_need(), nil), allocator)
				}
				plan.hints.split = {kind = .Length, prefix = slice.clone(steps[:], allocator), each_demand = each_d, has_each = each != nil}
				plan.each_body = each if borrowed else nil
				return
			}
		}
	}

	// 2. `reduce .prefix[] as pat (init; update)`.
	clear(&steps)
	if body.kind == .Reduce && body.a.kind == .Iterate && (.Opt not_in body.a.flags) && static_name_steps(body.a.a, &steps) {
		frame := Var_Frame{slots = make([]Need, int(body.slots), a.scratch)}
		_ = demand_node(a, body.c, whole_need(.Whole_Op), &frame)
		key_env := &frame if len(body.patterns) > 1 else nil
		_, pat_need := lift_patterns(a, body.patterns, frame.slots, key_env)
		plan.hints.split = {
			kind        = .Reduce,
			prefix      = slice.clone(steps[:], allocator),
			each_demand = finalize_need(a, pat_need, allocator),
			has_each    = true,
		}
		plan.each_body = body.c
		return
	}

	// 3. `[.prefix[] | each] | tail` or `.prefix | map(each) | tail`.
	clear(&steps)
	if each, tail, borrowed, ok := split_collect(a, body, &steps, &plan.owned_nodes if materialize else nil, allocator); ok {
		tail_elem := array_element_need(a, demand_node(a, tail, whole_need(.Identity), nil)) if tail != nil else whole_need(.Identity)
		each_need := demand_node(a, each, tail_elem, nil) if each != nil else tail_elem
		plan.hints.split = {
			kind        = .Collect,
			prefix      = slice.clone(steps[:], allocator),
			each_demand = finalize_need(a, each_need, allocator),
			has_each    = each != nil,
			has_tail    = tail != nil,
		}
		plan.each_body = each if borrowed else nil
		plan.tail_body = tail
		return
	}

	// 4. `.prefix[] | each` (stream, including postfix chains `.prefix[].field` and multi-stage pipes `.prefix[] | f | g`).
	clear(&steps)
	if each, borrowed, ok := split_iterate_prefix(a, body, &steps, &plan.owned_nodes if materialize else nil, allocator); ok {
		each_d := finalize_need(a, demand_node(a, each, whole_need(.Identity), nil), allocator) if each != nil else query.whole_demand(false, .Identity)
		plan.hints.split = {
			kind        = .Stream,
			prefix      = slice.clone(steps[:], allocator),
			each_demand = each_d,
			has_each    = each != nil,
		}
		plan.each_body = each if borrowed else nil
	}
}

@(private = "file")
is_builtin_length :: proc "contextless" (n: ^Node) -> bool {
	return n != nil && n.kind == .Call && n.ref.kind == .None && n.builtin != nil && n.builtin.name == "length" && n.builtin.arity == 0
}

// Matches `.NAME...` (or `.`), appending each `tape.Name` to `steps`.
@(private = "file")
static_name_steps :: proc(n: ^Node, steps: ^[dynamic]tape.Step) -> bool {
	at := len(steps)
	cur := n
	for cur != nil && cur.kind == .Field && (.Opt not_in cur.flags) {
		inject_at(steps, at, tape.Name(cur.name))
		cur = cur.a
	}
	if cur == nil || cur.kind != .Identity {
		resize(steps, at)
		return false
	}
	return true
}

// Matches `.NAME` and non-negative constant `.[IDX]` chains starting at `.`.
@(private = "file")
static_prefix_steps :: proc(n: ^Node, steps: ^[dynamic]tape.Step) -> bool {
	at := len(steps)
	cur := n
	for cur != nil {
		if .Opt in cur.flags {
			resize(steps, at)
			return false
		}
		#partial switch cur.kind {
		case .Identity:
			return true
		case .Field:
			inject_at(steps, at, tape.Name(cur.name))
			cur = cur.a
		case .Index:
			if idx, ok := literal_nonneg_int(cur.b); ok {
				inject_at(steps, at, tape.Index(idx))
				cur = cur.a
				continue
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
	if n == nil {
		return false
	}
	if n.kind == .Literal {
		return true
	}
	if n.kind == .Neg && n.a != nil && n.a.kind == .Literal {
		return true
	}
	return false
}

@(private = "file")
mk_plan_node :: proc(a: ^Analyzer, owned: ^[dynamic]^Node, val: Node, allocator: runtime.Allocator) -> ^Node {
	if owned == nil {
		return new_clone(val, a.scratch)
	}
	if owned.allocator.procedure == nil {
		owned.allocator = allocator
	}
	x := new_clone(val, allocator)
	append(owned, x)
	return x
}

@(private = "file")
recompute_plan_marks :: proc(n: ^Node) {
	if n == nil {
		return
	}
	a, b, c := n.a, n.b, n.c
	single := is_single(a) && is_single(b) && is_single(c)
	nat := false
	h := 0
	if a != nil {
		h = max(h, int(a.height))
	}
	if b != nil {
		h = max(h, int(b.height))
	}
	if c != nil {
		h = max(h, int(c.height))
	}
	n.height = u8(min(h + 1, 255))
	#partial switch n.kind {
	case .Identity, .Literal, .Var:
		single = true
		nat = true
	case .Field, .Index, .Slice, .Pipe:
		nat = single && (a == nil || .Native in a.flags) && (b == nil || .Native in b.flags) && (c == nil || .Native in c.flags) && int(n.height) <= NATIVE_HEIGHT
	case .Iterate:
		single = false
		nat = false
	}
	if single {
		n.flags += {.Single}
	} else {
		n.flags -= {.Single}
	}
	if nat {
		n.flags += {.Native}
	} else {
		n.flags -= {.Native}
	}
}

// Matches `.prefix[]` (plus optional postfix field/index/slice/iterate steps like `.logs[].msg` or `.logs[][]`)
// followed by zero or more left-associated `| stage` pipes.
// Re-associates synthesized AST nodes in `owned` when non-nil so `each` outlives `analyze`; otherwise keeps `borrowed = false`.
@(private = "file")
split_iterate_prefix :: proc(
	a: ^Analyzer,
	n: ^Node,
	steps: ^[dynamic]tape.Step,
	owned: ^[dynamic]^Node,
	allocator: runtime.Allocator,
) -> (each: ^Node, borrowed, ok: bool) {
	at := len(steps)
	stages := make([dynamic]^Node, 0, 4, a.scratch)
	cur := n
	for cur != nil && cur.kind == .Pipe {
		append(&stages, cur.b)
		cur = cur.a
	}
	append(&stages, cur)
	i := len(stages) - 1
	for i > 0 && static_prefix_steps(stages[i], steps) {
		i -= 1
	}

	head := stages[i]
	wraps := make([dynamic]^Node, 0, 4, a.scratch)
	for head != nil {
		if head.kind == .Iterate && (.Opt not_in head.flags) && static_prefix_steps(head.a, steps) {
			break
		}
		#partial switch head.kind {
		case .Field:
			append(&wraps, head)
			head = head.a
		case .Iterate:
			append(&wraps, head)
			head = head.a
		case .Index:
			if !is_const_literal_expr(head.b) {
				resize(steps, at)
				return nil, false, false
			}
			append(&wraps, head)
			head = head.a
		case .Slice:
			if (head.b != nil && !is_const_literal_expr(head.b)) || (head.c != nil && !is_const_literal_expr(head.c)) {
				resize(steps, at)
				return nil, false, false
			}
			append(&wraps, head)
			head = head.a
		case:
			resize(steps, at)
			return nil, false, false
		}
	}
	if head == nil || head.kind != .Iterate || (.Opt in head.flags) {
		resize(steps, at)
		return nil, false, false
	}

	each_head: ^Node
	if len(wraps) > 0 {
		cur_e := mk_plan_node(a, owned, Node{kind = .Identity}, allocator)
		recompute_plan_marks(cur_e)
		#reverse for w in wraps {
			clone := w^
			clone.a = cur_e
			node_p := mk_plan_node(a, owned, clone, allocator)
			recompute_plan_marks(node_p)
			cur_e = node_p
		}
		each_head = cur_e
	}

	if i == 0 {
		return each_head, each_head == nil || owned != nil, true
	}
	if each_head == nil {
		if i == 1 {
			return stages[0], true, true
		}
		tail := stages[i - 1]
		for j := i - 2; j >= 0; j -= 1 {
			pipe_n := mk_plan_node(a, owned, Node{kind = .Pipe, a = tail, b = stages[j]}, allocator)
			recompute_plan_marks(pipe_n)
			tail = pipe_n
		}
		return tail, owned != nil, true
	}
	tail := each_head
	for j := i - 1; j >= 0; j -= 1 {
		pipe_n := mk_plan_node(a, owned, Node{kind = .Pipe, a = tail, b = stages[j]}, allocator)
		recompute_plan_marks(pipe_n)
		tail = pipe_n
	}
	return tail, owned != nil, true
}

// Matches `[.prefix[] | each] | tail` or `.prefix | map(each) | tail` (with optional `| tail`).
@(private = "file")
split_collect :: proc(
	a: ^Analyzer,
	n: ^Node,
	steps: ^[dynamic]tape.Step,
	owned: ^[dynamic]^Node,
	allocator: runtime.Allocator,
) -> (each, tail: ^Node, borrowed, ok: bool) {
	at := len(steps)
	c := n
	for c != nil && c.kind == .Pipe && static_prefix_steps(c.a, steps) {
		c = c.b
	}
	if c != nil && c.kind == .Pipe {
		c, tail = c.a, c.b
	}
	if c == nil {
		resize(steps, at)
		return nil, nil, false, false
	}
	if c.kind == .Call && c.ref.kind == .Def && c.callee != nil && c.callee.prelude && c.callee.name == "map" && len(c.args) == 1 {
		return c.args[0], tail, true, true
	}
	if c.kind == .Array && c.a != nil {
		if e, e_borrowed, matched := split_iterate_prefix(a, c.a, steps, owned, allocator); matched {
			return e, tail, e_borrowed, true
		}
	}
	resize(steps, at)
	return nil, nil, false, false
}

// Hint 2: Projection_Template — `.p`, `.p1, .p2`, `[.p1, .p2]`, or `{k1: .p1, k2: .p2}` of static paths.
@(private = "file")
extract_projection :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, allocator: runtime.Allocator) {
	fields := make([dynamic]query.Projection_Field, 0, 4, a.scratch)
	#partial switch body.kind {
	case .Object:
		if len(body.args) == 0 {
			return
		}
		for i := 0; i < len(body.args); i += 2 {
			k, v := body.args[i], body.args[i + 1]
			if k.kind != .Literal || k.value.kind != .String || v == nil {
				return
			}
			steps := make([dynamic]tape.Step, 0, 4, a.scratch)
			if !static_path_steps(v, &steps) || len(steps) == 0 {
				return
			}
			key := query.text_of(k.value)
			// Duplicate keys still evaluate shadowed expressions for errors in jq, so bail out of projection hint.
			for f in fields {
				if f.key == key {
					return
				}
			}
			append(&fields, query.Projection_Field{key = key, path = steps[:]})
		}
		plan.hints.projection = {shape = .Object, fields = clone_projection_fields(fields[:], allocator)}
	case .Array:
		if body.a == nil || !collect_path_comma(a, body.a, &fields) || len(fields) == 0 {
			return
		}
		plan.hints.projection = {shape = .Array, fields = clone_projection_fields(fields[:], allocator)}
	case .Comma:
		if !collect_path_comma(a, body, &fields) || len(fields) == 0 {
			return
		}
		plan.hints.projection = {shape = .Stream, fields = clone_projection_fields(fields[:], allocator)}
	case .Field, .Index:
		steps := make([dynamic]tape.Step, 0, 4, a.scratch)
		if static_path_steps(body, &steps) && len(steps) > 0 {
			append(&fields, query.Projection_Field{path = steps[:]})
			plan.hints.projection = {shape = .Single, fields = clone_projection_fields(fields[:], allocator)}
		}
	}
}

@(private = "file")
collect_path_comma :: proc(a: ^Analyzer, n: ^Node, fields: ^[dynamic]query.Projection_Field) -> bool {
	if n == nil {
		return false
	}
	if n.kind == .Comma {
		return collect_path_comma(a, n.a, fields) && collect_path_comma(a, n.b, fields)
	}
	steps := make([dynamic]tape.Step, 0, 4, a.scratch)
	if !static_path_steps(n, &steps) || len(steps) == 0 {
		return false
	}
	append(fields, query.Projection_Field{path = steps[:]})
	return true
}

// Matches a static non-optional chain of `Name` and `Index` steps starting at `.`.
@(private = "file")
static_path_steps :: proc(n: ^Node, steps: ^[dynamic]tape.Step) -> bool {
	at := len(steps)
	cur := n
	for cur != nil {
		if .Opt in cur.flags {
			resize(steps, at)
			return false
		}
		#partial switch cur.kind {
		case .Identity:
			return true
		case .Field:
			inject_at(steps, at, tape.Name(cur.name))
			cur = cur.a
		case .Index:
			if cur.b.kind == .Literal {
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
clone_projection_fields :: proc(src: []query.Projection_Field, allocator: runtime.Allocator) -> []query.Projection_Field {
	out := make([]query.Projection_Field, len(src), allocator)
	for f, i in src {
		out[i] = {key = f.key, path = slice.clone(f.path, allocator)}
	}
	return out
}

// Hint 3: Conditional_Whole — `select(P)` where predicate `P` has a narrow demand; also extracts
// `Simple_Compare` when `P` is `PATH op SCALAR_LITERAL`.
@(private = "file")
extract_conditional :: proc(a: ^Analyzer, body: ^Node, plan: ^Plan, allocator: runtime.Allocator) {
	if body.kind != .Call || body.ref.kind != .None || body.builtin == nil || body.builtin.op != .Select || len(body.args) != 1 {
		return
	}
	pred := body.args[0]
	pred_need := demand_node(a, pred, grain_need(a, .Exists), nil)
	plan.hints.conditional.active = true
	plan.hints.conditional.pred_demand = finalize_need(a, pred_need, allocator)
	plan.pred_body = pred

	if pred.kind == .Binary && pred.op >= .Eq && pred.op <= .Ge && pred.b.kind == .Literal {
		t := query.type_of(pred.b.value)
		if t != .Array && t != .Object {
			steps := make([dynamic]tape.Step, 0, 4, a.scratch)
			if static_path_steps(pred.a, &steps) && len(steps) > 0 {
				plan.hints.conditional.cmp = {
					path    = slice.clone(steps[:], allocator),
					op      = query.Compare_Op(int(pred.op) - int(Op.Eq) + int(query.Compare_Op.Eq)),
					literal = pred.b.value,
				}
			}
		}
	}
}
