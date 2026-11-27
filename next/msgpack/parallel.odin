package msgpack

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/ops/typed"

// Multi-threaded `validate`, `build`, and root-array `unmarshal` over `Part_Plan`.

@(private)
validate_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> tape.Error {
	err, done := validate_parts(src, S, opts, caller)
	if done {
		return err
	}
	one := opts
	one.runner = nil
	return validate_as(src, S, false, one, caller)
}

@(private)
plan_parallel :: proc(src: []u8, want: int, opts: Options, backing: runtime.Allocator, plan: ^Part_Plan, m: ^hook.Memory_Budget) -> (allocator: runtime.Allocator, ok: bool) {
	return build.binary_plan_parallel(src, want, opts, backing, plan, m, plan_parts)
}

@(private)
destroy_plan :: #force_inline proc(plan: ^Part_Plan) {
	build.binary_plan_destroy(plan)
}

@(private)
validate_parts :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (err: tape.Error, done: bool) {
	walk_fn :: proc "contextless" (src: []u8, from, to: int, opts: Options, plan: ^Part_Plan, k: int, h: ^hook.No_Hooks, regs: ^hook.Regs) -> (hook.Walk_Result, bool) {
		return walk_part(src, from, to, S, opts, plan, k, h, regs, hook.no_hook)
	}
	return build.binary_validate_parts(src, opts, &RULES, caller, Level, plan_parallel, walk_fn, u8(Detail.Trailing))
}

@(private)
build_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	doc, err, built := build_parts(src, S, opts, caller)
	if built {
		return doc, err
	}
	one := opts
	one.runner = nil
	if one.budget.steps != 0 {
		return build_as(src, S, true, one, caller)
	}
	return build_as(src, S, false, one, caller)
}

@(private)
build_parts :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (doc: tape.Document, err: tape.Error, built: bool) {
	walk_fn :: proc "contextless" (src: []u8, from, to: int, opts: Options, plan: ^Part_Plan, k: int, h: ^build.Builder, regs: ^hook.Regs) -> (hook.Walk_Result, bool) {
		return walk_part(src, from, to, S, opts, plan, k, h, regs, build.builder_hook_facts)
	}
	return build.binary_build_parts(src, &FORMATS[S], &RULES, opts, caller, Level, plan_parallel, walk_fn, u8(Detail.Trailing))
}

@(private)
walk_part :: proc "contextless" (src: []u8, from, to: int, $S: Spec, opts: Options, plan: ^Part_Plan, k: int, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level = ---
	w: Walk(S, H, false, C)
	walk_init(&w, src[:to], h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.whole = u64(len(src))
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	w.depth = min(w.limit, WALK_LEVELS)
	s := plan.seams[k]
	held := ([^]Level)(raw_data(plan.levels[s.at:]))
	intrinsics.mem_copy_non_overlapping(w.stack, held, int(s.d) * size_of(Level))
	r := run(&w, u64(from), s.d, s.top, regs, on)
	return r, w.tolerated
}

// Parallel typed unmarshal for root MessagePack arrays using `plan_parts` seams aligned to depth 1.
@(private)
unmarshal_parallel :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $REFUSE: bool, read: Unmarshal_Options, opts: Options, caller: runtime.Allocator) -> (tape.Error, bool) {
	if len(src) == 0 {
		return nil, false
	}
	b := src[0]
	is_fix := b >= 0x90 && b <= 0x9f
	if !is_fix && b != 0xdc && b != 0xdd {
		return nil, false
	}
	if !typed.parallel_list_ready(target, T, &FORMATS[S], TAG, opts, read, caller) {
		return nil, false
	}
	arg, head_len: u64
	if is_fix {
		arg, head_len = u64(b & 0x0f), 1
	} else {
		wlen := ARG_WIDTH[b]
		ok: bool
		arg, ok = read_arg(src, 0, wlen)
		if !ok {
			return nil, false
		}
		head_len = u64(1 + wlen)
	}
	if arg == 0 || (S == .Compact && !compact_container_ok(b, arg)) {
		return nil, false
	}
	want := min(build.chunk_count(opts.runner, len(src)), typed.MAX_PARALLEL_PARTS)
	m: hook.Memory_Budget
	plan: Part_Plan
	scratch := typed.parallel_scratch_backing(opts, caller)
	if _, pok := plan_parallel(src, want, opts, scratch, &plan, &m); !pok {
		return nil, false
	}
	defer destroy_plan(&plan)

	parts: [typed.MAX_PARALLEL_PARTS]typed.Parallel_Part
	last_top: u64
	cur := int(head_len)
	n_parts := 0
	for k in 1 ..< len(plan.parts) {
		s := plan.seams[k]
		pos := u64(plan.parts[k].from)
		top := s.top
		if s.d > 1 {
			st: Pass(false)
			st.i, st.d, st.top = pos, s.d, s.top
			held := ([^]Level)(raw_data(plan.levels[s.at:]))
			intrinsics.mem_copy_non_overlapping(&st.stack[0], held, int(s.d) * size_of(Level))
			ok := false
			pos, top, ok = advance_to_depth1(src, &st)
			if !ok {
				continue
			}
		}
		if s.d == 0 || top & FLAG_OBJECT != 0 {
			continue
		}
		if int(pos) > cur && int(pos) < len(src) && n_parts + 1 < len(parts) {
			parts[n_parts] = {from = cur, to = int(pos)}
			n_parts += 1
			cur = int(pos)
			last_top = top
		}
	}
	if n_parts < 1 || cur >= len(src) {
		return nil, false
	}
	parts[n_parts] = {from = cur, to = len(src)}
	n_parts += 1
	destroy_plan(&plan)
	plan = {}

	H :: typed.Refusing_Reader when REFUSE else typed.Text_Reader
	Typed_Data :: struct {
		src:      []u8,
		opts:     Options,
		n_parts:  int,
		last_top: u64,
	}
	walk_part_typed :: proc(k: int, p: typed.Parallel_Part, hk: ^H, regs: ^hook.Regs, data: rawptr) -> typed.Part_Result {
		d := (^Typed_Data)(data)
		C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
		on :: #force_inline proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
			when REFUSE {
				return typed.refusing_hook(h, s, t, number_in_place)
			} else {
				return typed.text_hook(h, s, t, number_in_place)
			}
		}
		stack: [WALK_LEVELS]Level = ---
		stack[0] = {}
		w: Walk(S, H, false, C)
		walk_init(&w, d.src[:p.to], hk, raw_data(stack[:]), min(build.read_depth(d.opts), MAX_LEVELS), WALK_LEVELS, d.opts)
		w.whole = u64(len(d.src))
		w.depth = min(w.limit, WALK_LEVELS)
		end := k == d.n_parts - 1
		top := d.last_top if end else frame_of(1 << 50, 0)
		r := run(&w, u64(p.from), 1, top, regs, on)
		if end && u8(r) == 0 && u64(r) >> 16 < u64(len(d.src)) {
			r = fault(u64(r) >> 16, .Bad_Char, .Trailing)
		}
		_, err, _ := hook.walk_error(r, &RULES)
		if !end {
			if f, is_fault := err.(tape.Fault); is_fault && f.kind == .Truncated && f.at == u64(p.to) {
				err = nil
			} else if err == nil {
				return {astray = true}
			}
		} else if err == nil && (u64(r) >> 16 != u64(p.to) || hk.sp != 1) {
			return {astray = true}
		}
		return {err = err}
	}
	td := Typed_Data{src = src, opts = opts, n_parts = n_parts, last_top = last_top}
	return typed.read_parallel_list(src, target, T, &FORMATS[S], &RULES, TAG, opts, read, caller, parts[:n_parts], H, walk_part_typed, &td)
}

@(private)
advance_to_depth1 :: proc(src: []u8, st: ^Pass(false)) -> (pos, top: u64, ok: bool) {
	dummy: Part_Plan
	dummy_part: [1]build.Part
	dummy.parts = slice_as_dyn(dummy_part[:])
	dummy.want = 1
	for st.d > 1 && st.i < u64(len(src)) {
		if plan_run(src, false, st, st.i + 1, &dummy) != .Stopped {
			return 0, 0, false
		}
	}
	return st.i, st.top, st.d == 1 && st.i < u64(len(src))
}

@(private)
slice_as_dyn :: #force_inline proc "contextless" (s: []build.Part) -> [dynamic]build.Part {
	return transmute([dynamic]build.Part)runtime.Raw_Dynamic_Array{data = raw_data(s), len = len(s), cap = len(s)}
}
