package cbor

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/ops/typed"

// Multi-threaded `validate`, `build`, and root-array `unmarshal` over `Part_Plan`.

@(private)
plan_parallel :: proc(src: []u8, $S: Spec, want: int, opts: Options, backing: runtime.Allocator, plan: ^Part_Plan, m: ^hook.Memory_Budget) -> (allocator: runtime.Allocator, ok: bool) {
	run_parts :: proc(src: []u8, want: int, plan: ^Part_Plan, runner: ^tape.Runner) -> bool {
		return plan_parts(src, S, want, plan, runner)
	}
	return build.binary_plan_parallel(src, want, opts, backing, plan, m, run_parts)
}

@(private)
validate_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> tape.Error {
	plan_fn :: proc(src: []u8, want: int, opts: Options, backing: runtime.Allocator, plan: ^Part_Plan, m: ^hook.Memory_Budget) -> (runtime.Allocator, bool) {
		return plan_parallel(src, S, want, opts, backing, plan, m)
	}
	walk_fn :: proc "contextless" (src: []u8, from, to: int, opts: Options, plan: ^Part_Plan, k: int, h: ^hook.No_Hooks, regs: ^hook.Regs) -> (hook.Walk_Result, bool) {
		return walk_part(src, from, to, S, opts, plan, k, h, regs, hook.no_hook)
	}
	fallback_fn :: proc(src: []u8, opts: Options, caller: runtime.Allocator) -> tape.Error {
		return validate_as(src, S, false, opts, caller)
	}
	return build.binary_validate_parallel(src, opts, &RULES, caller, Level(.Length_First), plan_fn, walk_fn, fallback_fn, u8(Detail.Trailing))
}

@(private)
build_parallel :: proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	plan_fn :: proc(src: []u8, want: int, opts: Options, backing: runtime.Allocator, plan: ^Part_Plan, m: ^hook.Memory_Budget) -> (runtime.Allocator, bool) {
		return plan_parallel(src, S, want, opts, backing, plan, m)
	}
	walk_fn :: proc "contextless" (src: []u8, from, to: int, opts: Options, plan: ^Part_Plan, k: int, h: ^build.Builder, regs: ^hook.Regs) -> (hook.Walk_Result, bool) {
		return walk_part(src, from, to, S, opts, plan, k, h, regs, build.builder_hook_facts)
	}
	fallback_fn :: proc(src: []u8, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
		if opts.budget.steps != 0 { return build_as(src, S, true, opts, caller) }
		return build_as(src, S, false, opts, caller)
	}
	return build.binary_build_parallel(src, &FORMATS[S], &RULES, opts, caller, Level(.Length_First), plan_fn, walk_fn, fallback_fn, u8(Detail.Trailing))
}

@(private)
walk_part :: proc "contextless" (src: []u8, from, to: int, $S: Spec, opts: Options, plan: ^Part_Plan, k: int, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (hook.Walk_Result, bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	stack: [WALK_LEVELS]Level(S) = ---
	w: Walk(S, H, false, C)
	walk_init(&w, src[:to], h, raw_data(stack[:]), min(build.read_depth(opts), MAX_LEVELS), WALK_LEVELS, opts)
	w.whole = u64(len(src))
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	w.depth = min(w.limit, WALK_LEVELS)
	s := plan.seams[k]
	held := ([^]Level(S))(raw_data(plan.levels[s.at:]))
	intrinsics.mem_copy_non_overlapping(w.stack, held, int(s.d) * size_of(Level(S)))
	r := run(&w, u64(from), s.d, s.top, regs, on)
	return r, w.tolerated
}

// Parallel typed unmarshal for root CBOR arrays using `plan_parts` seams aligned to depth 1.
@(private)
unmarshal_parallel :: #force_no_inline proc(src: []u8, target: rawptr, T: typeid, $S: Spec, $REFUSE: bool, read: Unmarshal_Options, opts: Options, caller: runtime.Allocator) -> (tape.Error, bool) {
	if len(src) == 0 || src[0] >> 5 != 4 || (src[0] != 0x9f && src[0] & 31 >= 28) {
		return nil, false
	}
	if !typed.parallel_list_ready(target, T, &FORMATS[S], TAG, opts, read, caller) {
		return nil, false
	}
	head_len: u64
	if src[0] == 0x9f {
		head_len = 1
	} else {
		arg, hl, ok := read_head(src, 0, src[0] & 31)
		if !ok || arg == 0 {
			return nil, false
		}
		head_len = hl
	}
	want := min(build.chunk_count(opts.runner, len(src)), typed.MAX_PARALLEL_PARTS)
	m: hook.Memory_Budget
	plan: Part_Plan
	scratch := typed.parallel_scratch_backing(opts, caller)
	if _, pok := plan_parallel(src, S, want, opts, scratch, &plan, &m); !pok {
		return nil, false
	}
	advance :: proc(src: []u8, pos, d, top: u64, held: [^]Level(S)) -> (u64, u64, bool) {
		st: Pass(S, false)
		st.i, st.d, st.top = pos, d, top
		intrinsics.mem_copy_non_overlapping(&st.stack[0], held, int(d) * size_of(Level(S)))
		run_abs :: proc(src: []u8, st: ^Pass(S, false), stop: u64, plan: ^Part_Plan) -> Pass_End {
			return plan_run(src, S, false, st, stop, plan)
		}
		return build.binary_advance_to_depth1(src, &st, Level(.Length_First), run_abs)
	}
	parts: [typed.MAX_PARALLEL_PARTS]typed.Parallel_Part
	n_parts, last_top, dok := build.binary_depth1_parts(src, &plan, head_len, parts[:], Level(S), FLAG_OBJECT | FLAG_TAG, advance)
	build.binary_plan_destroy(&plan)
	if !dok {
		return nil, false
	}
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
			if t.role == .Tag {
				note_epoch(&h.epoch, h.base, t)
			}
			when REFUSE {
				return typed.refusing_hook(h, s, t, number_in_place)
			} else {
				return typed.text_hook(h, s, t, number_in_place)
			}
		}
		stack: [WALK_LEVELS]Level(S) = ---
		stack[0] = {}
		w: Walk(S, H, false, C)
		walk_init(&w, d.src[:p.to], hk, raw_data(stack[:]), min(build.read_depth(d.opts), MAX_LEVELS), WALK_LEVELS, d.opts)
		w.whole = u64(len(d.src))
		w.depth = min(w.limit, WALK_LEVELS)
		end := k == d.n_parts - 1
		top := d.last_top if end else indefinite_frame(0)
		r := run(&w, u64(p.from), 1, top, regs, on)
		err, astray := build.binary_typed_part_verdict(r, u64(len(d.src)), p.to, end, hk.sp, &RULES, u8(Detail.Trailing))
		return {err = err, astray = astray}
	}
	td := Typed_Data{src = src, opts = opts, n_parts = n_parts, last_top = last_top}
	return typed.read_parallel_list(src, target, T, &FORMATS[S], &RULES, TAG, opts, read, caller, parts[:n_parts], H, walk_part_typed, &td)
}
