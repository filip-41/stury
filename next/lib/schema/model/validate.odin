// Iterative in-memory validation and token-tape emission (`validate`, `val_run_judged`, `emit_node`)
// over compiled `Type_Plan` values, enforcing depth/budgets, applicators, and write refusals.
package model

import "base:runtime"
import "core:encoding/uuid"
import "core:math"
import "core:reflect"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "stury:lib/base/regex"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:lib/schema/rules"

@(require_results)
validate :: proc(m: ^Model($T), v: ^T, sink: ^Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> Error {
	if m == nil || v == nil || len(m.plan.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "value"}} }
	return validate_inner(&m.plan, m.judging, rawptr(v), sink, opts, nil, allocator)
}

@(private)
Omit_Pred :: proc(ctx: rawptr, si: ^Struct_Info, fi: int, struct_ptr: rawptr) -> bool
@(private)
Omit_Hook :: struct { fn: Omit_Pred, ctx: rawptr }

@(private)
validate_inner :: proc(plan: ^Type_Plan, judging: ^Applied, val_ptr: rawptr, sink: ^Sink, opts: Load_Opts, omit: ^Omit_Hook, allocator: runtime.Allocator) -> Error {
	policy, ok := resolve_dups(opts.dups, nil)
	if !ok { return Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	sc: Scratch_Scope; scratch_begin(&sc, opts, allocator); defer scratch_end(&sc)
	from := len(sink.entries) if sink != nil else 0
	rs, rerr := regex.scratch_make(sc.scratch)
	if rerr.kind != .None { return scratch_oom_error(&sc) }
	defer regex.scratch_destroy(&rs)

	w := Walk_State{mode = .Validate, plan = plan, judging = judging, validators = opts.validators, policy = policy, sink = sink, omit = omit, re_scratch = rs, allocator = sc.out, scratch = sc.scratch}
	budget_init(&w.budget, opts.budget); w.steps.allocator = sc.scratch; report_init(&w.rep, sc.scratch); defer report_destroy(&w.rep)
	walk_loop(&w, plan.root, val_ptr)
	if sink != nil { order_sink(sink, from) }
	if w.budget.exceeded.kind != .None { error_destroy(w.first, sc.out); return tape.Error(w.budget.exceeded) }
	if w.oom { error_destroy(w.first, sc.out); return scratch_oom_error(&sc) }
	return w.first if w.first.kind != .None else nil
}

@(private)
emit_node :: proc(plan: ^Type_Plan, tt: ^write.Token_Tape, root_idx: i32, root_ptr: rawptr, omit: ^Omit_Hook, sink: ^Sink, allocator, scratch: runtime.Allocator, silent := false, redact := false, redact_mask := "", redact_paths: []string = nil) -> Error {
	w := Walk_State{mode = .Emit, plan = plan, tt = tt, sink = sink, omit = omit, silent = silent, redact = redact, redact_mask = resolve_redact_mask(redact_mask), redact_paths = redact_paths, allocator = allocator, scratch = scratch}
	budget_init(&w.budget, {}); w.steps.allocator = scratch
	walk_loop(&w, root_idx, root_ptr)
	if w.budget.exceeded.kind != .None { error_destroy(w.first, allocator); return tape.Error(w.budget.exceeded) }
	if w.oom { error_destroy(w.first, allocator); return runtime.Allocator_Error.Out_Of_Memory }
	if w.write_err != nil { error_destroy(w.first, allocator); return w.write_err }
	return w.first if w.first.kind != .None else nil
}

@(private)
Walk_Mode :: enum u8 { Validate, Emit }

@(private)
Walk_State :: struct {
	mode:               Walk_Mode,
	plan:               ^Type_Plan,
	judging:            ^Applied,
	validators:         ^Validator_Registry,
	tt:                 ^write.Token_Tape,
	policy:             tape.Duplicates,
	sink:               ^Sink,
	omit:               ^Omit_Hook,
	first:              Model_Error,
	oom, silent, redact: bool,
	redact_mask:        string,
	redact_paths:       []string,
	secret_depth:       int,
	write_err:          write.Error,
	fail_count:         u64,
	budget:             Budget_Tracker,
	steps:              [dynamic]tape.Step,
	rep:                Report,
	re_scratch:         regex.Scratch,
	allocator, scratch: runtime.Allocator,
}

@(private)
walk_fail :: proc(w: ^Walk_State, kind: Error_Kind, operand := "", want := Want{}) -> bool {
	w.fail_count += 1
	if w.mode == .Emit && w.sink == nil && kind != .Duplicate_Key { if w.first.kind == .None { w.first = {kind = kind, want = want} }; return false }
	return record_failure(w.sink, &w.first, &w.oom, w.allocator, kind, 0, w.steps[:], operand, want, w.silent, w.secret_depth > 0)
}

@(private)
walk_emit_tok :: #force_inline proc(w: ^Walk_State, kind: write.Token_Kind, text: string) -> bool {
	werr := write.token_tape_take(w.tt, kind, text)
	if werr == nil { return true }
	if _, is_oom := werr.(runtime.Allocator_Error); is_oom { w.oom = true } else { w.write_err = werr }
	return false
}

@(private)
walk_stopped :: #force_inline proc "contextless" (w: ^Walk_State) -> bool {
	return w.oom || w.write_err != nil || w.budget.exceeded.kind != .None || ((w.mode == .Emit || w.sink == nil) && w.first.kind != .None)
}

// Shared after-validator runner used by both `validate.odin` and `load.odin`.
@(private)
run_after_validators :: proc(
	afters: []Validator, named: []Named_Validator_Ref, val_ptr: rawptr, ti: ^runtime.Type_Info, si: ^Struct_Info,
	vr: ^Validator_Registry, rep: ^Report, steps: []tape.Step, at: u64, sink: ^Sink, first: ^Model_Error,
	oom: ^bool, fail_count: ^u64, allocator, scratch: runtime.Allocator, silent, secret: bool,
) {
	report_reset(rep)
	for av in afters { av.call(val_ptr, av.fn, rep) }
	if len(named) > 0 {
		if missing := run_named_validators(named, val_ptr, ti, vr, rep); missing != "" {
			fail_count^ += 1
			_ = record_failure(sink, first, oom, allocator, .Missing_Validator, at, steps, "", {text = missing}, silent, secret)
			return
		}
	}
	if rep.failed || rep.oom {
		fail_count^ += 1
		_ = emit_report(rep, steps, at, si, sink, first, oom, allocator, scratch, silent, secret)
	}
}

@(private)
Walk_Frame_Kind :: enum u8 { Node, Struct_Fields, Struct_Finish, Close, Field_After, Node_After, List_Elems, Map_Entries, Run_Judged, Pop_Step, Leave_Depth }

@(private)
Walk_Frame :: struct {
	kind:                               Walk_Frame_Kind,
	node_idx, field_rule_idx:           i32,
	ptr:                                rawptr,
	field_unique, not_null, pop_secret: bool,
	tag_key, tag_val:                   string,
	si:                                 ^Struct_Info,
	fi, idx, count:                     int,
	stride, base:                       uintptr,
	start_fails:                        u64,
	entries:                            []Sorted_Map_Entry,
	is_cap:                             bool,
}

@(private)
walk_loop :: proc(w: ^Walk_State, root_idx: i32, root_ptr: rawptr) {
	stack, serr := make([dynamic]Walk_Frame, 0, 32, w.scratch)
	if serr != nil { w.oom = true; return }
	defer delete(stack)
	if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = root_idx, ptr = root_ptr}) { return }

	for len(stack) > 0 && !walk_stopped(w) {
		top := &stack[len(stack) - 1]
		switch top.kind {
		case .Pop_Step:    f := pop(&stack); if f.pop_secret && w.secret_depth > 0 { w.secret_depth -= 1 }; if len(w.steps) > 0 { pop(&w.steps) }
		case .Leave_Depth: pop(&stack); budget_leave(&w.budget)
		case .Close:       pop(&stack); _ = walk_emit_tok(w, .Close, ""); budget_leave(&w.budget)
		case .Run_Judged:  f := pop(&stack); if !val_run_judged(w, &w.plan.nodes[f.node_idx], f.node_idx, f.field_unique, f.ptr) { w.fail_count += 1 }
		case .Field_After:
			f := pop(&stack); if w.fail_count != f.start_fails { continue }
			fld := &f.si.fields[f.fi]
			run_after_validators(fld.afters, fld.named_validators, f.ptr, w.plan.nodes[fld.node].ti, nil, w.validators, &w.rep, w.steps[:], 0, w.sink, &w.first, &w.oom, &w.fail_count, w.allocator, w.scratch, false, w.secret_depth > 0)
		case .Node_After:
			f := pop(&stack); if w.fail_count != f.start_fails { continue }
			tn := &w.plan.nodes[f.node_idx]
			if len(tn.named_validators) > 0 {
				run_after_validators(nil, tn.named_validators, f.ptr, tn.ti, nil, w.validators, &w.rep, w.steps[:], 0, w.sink, &w.first, &w.oom, &w.fail_count, w.allocator, w.scratch, false, w.secret_depth > 0)
			}
		case .Struct_Finish:
			f := pop(&stack); tn := &w.plan.nodes[f.node_idx]
			if tn.judged && !val_run_judged(w, tn, f.node_idx, false, f.ptr) { w.fail_count += 1 }
			if walk_stopped(w) { budget_leave(&w.budget); return }
			if w.fail_count == f.start_fails && len(f.si.validators) > 0 {
				run_after_validators(f.si.validators, nil, f.ptr, nil, f.si, w.validators, &w.rep, w.steps[:], 0, w.sink, &w.first, &w.oom, &w.fail_count, w.allocator, w.scratch, false, w.secret_depth > 0)
			}
			budget_leave(&w.budget)
		case .Struct_Fields:
			si := top.si
			if top.idx < len(si.fields) {
				fi := top.idx; top.idx += 1; fld := &si.fields[fi]
				if .Write_Only in fld.flags || (w.omit != nil && w.omit.fn(w.omit.ctx, si, fi, top.ptr)) { continue }
				if w.mode == .Emit && !walk_emit_tok(w, .Key, fld.name) { return }
				if !push_oom(&w.oom, &w.steps, tape.Step(tape.Name(fld.name))) { return }
				if w.mode == .Emit && ((w.redact && .Secret in fld.flags) || redact_steps_match(w.steps[:], w.redact_paths)) { _ = walk_emit_tok(w, .String, w.redact_mask); pop(&w.steps); continue }
				fdest, field_secret := rawptr(uintptr(top.ptr) + fld.offset), w.mode == .Validate && .Secret in fld.flags
				if field_secret { w.secret_depth += 1 }
				if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Pop_Step, pop_secret = field_secret}) { return }
				if w.mode == .Validate && (len(fld.afters) > 0 || len(fld.named_validators) > 0) && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Field_After, si = si, fi = fi, ptr = fdest, start_fails = w.fail_count}) { return }
				if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = fld.node, ptr = fdest, field_rule_idx = fld.rule_idx, field_unique = .Has_Unique in fld.flags, not_null = .Not_Null in fld.flags}) { return }
				continue
			}
			ptr := top.ptr; pop(&stack)
			if si.capture_idx >= 0 {
				cap_tn := &w.plan.nodes[si.capture_node]
				entries, merr := collect_sorted_map_entries(cap_tn.ti, rawptr(uintptr(ptr) + si.capture_offset), w.scratch)
				if merr != nil { w.oom = true; return }
				if len(entries) > 0 && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Map_Entries, node_idx = cap_tn.child, si = si, entries = entries, is_cap = true}) { return }
			}
		case .List_Elems:
			if top.idx >= top.count { pop(&stack); continue }
			i := top.idx; top.idx += 1
			if !push_oom(&w.oom, &w.steps, tape.Step(tape.Index(i))) { return }
			if w.mode == .Emit && redact_steps_match(w.steps[:], w.redact_paths) { _ = walk_emit_tok(w, .String, w.redact_mask); pop(&w.steps); continue }
			if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Pop_Step}) || !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = top.node_idx, ptr = rawptr(top.base + uintptr(i) * top.stride)}) { return }
		case .Map_Entries:
			if top.idx >= len(top.entries) { pop(&stack); continue }
			e := top.entries[top.idx]; top.idx += 1
			if !push_oom(&w.oom, &w.steps, tape.Step(tape.Name(e.key_text))) { return }
			if top.is_cap && struct_find_field(top.si, e.key_text) >= 0 { _ = walk_fail(w, .Duplicate_Key); pop(&w.steps); continue }
			if w.mode == .Emit && !walk_emit_tok(w, .Key, e.key_text) { pop(&w.steps); return }
			if w.mode == .Emit && redact_steps_match(w.steps[:], w.redact_paths) { _ = walk_emit_tok(w, .String, w.redact_mask); pop(&w.steps); continue }
			if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Pop_Step}) || !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = top.node_idx, ptr = e.val_ptr}) { return }
		case .Node:
			f := pop(&stack); if !budget_node(&w.budget, 0) { return }
			tn := &w.plan.nodes[f.node_idx]; rule_idx := f.field_rule_idx if f.field_rule_idx > 0 else tn.rule_idx; has_unique := f.field_unique || tn.has_unique; ptr := f.ptr
			if w.mode == .Validate && len(tn.named_validators) > 0 && tn.kind != .Maybe && tn.kind != .Ptr {
				if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node_After, node_idx = f.node_idx, ptr = ptr, start_fails = w.fail_count}) { return }
			}
			#partial switch tn.kind {
			case .Maybe, .Ptr:
				inner := ptr if tn.kind == .Maybe else (^rawptr)(ptr)^
				set := maybe_is_set(tn, ptr) if tn.kind == .Maybe else inner != nil
				if !set { if w.mode == .Emit { _ = walk_emit_tok(w, .Null, "") } else if f.not_null { _ = walk_fail(w, .Wrong_Kind, "", {type = tn.type, text = "non-null"}) } } else {
					if tn.kind == .Ptr && (!budget_enter(&w.budget, 0) || !push_oom(&w.oom, &stack, Walk_Frame{kind = .Leave_Depth})) { return }
					if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = tn.child, ptr = inner, field_rule_idx = rule_idx, field_unique = has_unique, tag_key = f.tag_key, tag_val = f.tag_val}) { return }
				}
			case .Struct:
				if !budget_enter(&w.budget, 0) || !budget_step(&w.budget, 0) { return }
				si := &w.plan.structs[tn.struct_idx]
				if w.mode == .Emit {
					if !walk_emit_tok(w, .Object, "") || (f.tag_key != "" && (!walk_emit_tok(w, .Key, f.tag_key) || !walk_emit_tok(w, .String, f.tag_val))) { budget_leave(&w.budget); return }
					if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Close}) { return }
				} else if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Struct_Finish, node_idx = f.node_idx, ptr = ptr, si = si, start_fails = w.fail_count}) { return }
				if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Struct_Fields, si = si, ptr = ptr}) { return }
			case .Slice, .Dynamic, .Array, .Fixed_List:
				if !budget_enter(&w.budget, 0) || !budget_step(&w.budget, 0) { return }
				base, n := list_span(tn, ptr)
				if w.mode == .Validate {
					if !check_count_leaf(w.plan, rule_idx, u64(n), false, 0, w.steps[:], w.sink, &w.first, &w.oom, w.allocator, w.scratch, false, w.secret_depth > 0) { w.fail_count += 1; if walk_stopped(w) { budget_leave(&w.budget); return } }
					if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Leave_Depth}) { return }
					if (has_unique || tn.judged) && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr, field_unique = has_unique}) { return }
				} else if !walk_emit_tok(w, .Array, "") { budget_leave(&w.budget); return } else if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Close}) { return }
				if n > 0 && !push_oom(&w.oom, &stack, Walk_Frame{kind = .List_Elems, node_idx = tn.child, base = base, count = n, stride = uintptr(w.plan.nodes[tn.child].size)}) { return }
			case .Map:
				if !budget_enter(&w.budget, 0) || !budget_step(&w.budget, 0) { return }
				rm := (^runtime.Raw_Map)(ptr)
				if w.mode == .Validate && !check_count_leaf(w.plan, rule_idx, u64(rm.len), true, 0, w.steps[:], w.sink, &w.first, &w.oom, w.allocator, w.scratch, false, w.secret_depth > 0) { w.fail_count += 1; if walk_stopped(w) { budget_leave(&w.budget); return } }
				entries: []Sorted_Map_Entry
				if rm.len > 0 { merr: runtime.Allocator_Error; entries, merr = collect_sorted_map_entries(tn.ti, ptr, w.scratch); if merr != nil { budget_leave(&w.budget); w.oom = true; return } }
				if w.mode == .Validate {
					if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Leave_Depth}) { return }
					if tn.judged && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr}) { return }
				} else if !walk_emit_tok(w, .Object, "") { budget_leave(&w.budget); return } else if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Close}) { return }
				if len(entries) > 0 && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Map_Entries, node_idx = tn.child, entries = entries}) { return }
			case .Bit_Set: walk_bit_set(w, f.node_idx, tn, ptr, rule_idx)
			case .Union:
				u := &w.plan.unions[tn.union_idx]; arm_idx := int(read_union_tag(ptr, u.tag_offset, u.tag_size)) - (0 if u.no_nil else 1)
				if arm_idx < 0 { if w.mode == .Emit { _ = walk_emit_tok(w, .Null, "") } else if tn.judged && !val_run_judged(w, tn, f.node_idx, false, ptr) { w.fail_count += 1 } } else if arm_idx >= len(u.arms) { _ = walk_fail(w, .No_Arm) } else {
					arm := u.arms[arm_idx]; tkey := u.tag_key if w.mode == .Emit && u.mode == .Tag && u.tag_key != "" && arm.is_struct && arm.name != "" else ""
					if w.mode == .Validate && tn.judged && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr}) { return }
					if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = arm.node, ptr = ptr, field_rule_idx = rule_idx, tag_key = tkey, tag_val = arm.name}) { return }
				}
			case .Custom:
				c, ctn := &w.plan.customs[tn.custom_idx], &w.plan.nodes[tn.child]
				cbuf, cerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, w.scratch); if cerr != nil { w.oom = true; return }
				if ck := c.convert_to(c.to, ptr, raw_data(cbuf), w.scratch); ck != .None { _ = walk_fail(w, ck); continue }
				if w.mode == .Validate && tn.judged && !push_oom(&w.oom, &stack, Walk_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr}) { return }
				if !push_oom(&w.oom, &stack, Walk_Frame{kind = .Node, node_idx = tn.child, ptr = raw_data(cbuf), field_rule_idx = rule_idx, field_unique = has_unique, tag_key = f.tag_key, tag_val = f.tag_val}) { return }
			case: walk_scalar(w, f.node_idx, tn, ptr, rule_idx, f.not_null)
			}
		}
	}
}

@(private)
walk_bit_set :: proc(w: ^Walk_State, node_idx: i32, tn: ^Type_Node, ptr: rawptr, rule_idx: i32) {
	if w.mode == .Emit { if !budget_enter(&w.budget, 0) { return }; defer budget_leave(&w.budget); if !walk_emit_tok(w, .Array, "") { return } }
	bytes, cnt := ([^]u8)(ptr)[:tn.size], u64(0); buf: [32]u8 = ---
	for bit in 0 ..< tn.count {
		if (bytes[bit / 8] >> uint(bit % 8)) & 1 == 0 { continue }
		cnt += 1; if w.mode != .Emit { continue }
		val, ok := tn.bit_lower + i64(bit), false
		if tn.enum_idx >= 0 {
			ei := &w.plan.enums[tn.enum_idx]
			for ev, i in ei.values { if ev == val { ok = walk_emit_tok(w, .String, ei.names[i]) if ei.by_name else walk_emit_tok(w, .Number, strconv.write_int(buf[:], val, 10)); break } }
		} else { ok = walk_emit_tok(w, .Number, strconv.write_int(buf[:], val, 10)) }
		if !ok && walk_stopped(w) { return }
	}
	if w.mode == .Emit { _ = walk_emit_tok(w, .Close, ""); return }
	if !check_count_leaf(w.plan, rule_idx, cnt, false, 0, w.steps[:], w.sink, &w.first, &w.oom, w.allocator, w.scratch, false, w.secret_depth > 0) { w.fail_count += 1 }
	if !walk_stopped(w) && tn.judged && !val_run_judged(w, tn, node_idx, false, ptr) { w.fail_count += 1 }
}

@(private)
walk_scalar :: proc(w: ^Walk_State, node_idx: i32, tn: ^Type_Node, ptr: rawptr, rule_idx: i32, not_null: bool) {
	leaf_ok := true
	check_s :: proc(w: ^Walk_State, rule_idx: i32, s: string) -> bool {
		return walk_emit_tok(w, .String, s) if w.mode == .Emit else check_string_leaf(w.plan, &w.re_scratch, rule_idx, s, 0, w.steps[:], w.sink, &w.first, &w.oom, w.allocator, w.scratch, false, w.secret_depth > 0)
	}
	check_n :: proc(w: ^Walk_State, rule_idx: i32, s: string, small: Maybe(i64)) -> bool {
		return walk_emit_tok(w, .Number, s) if w.mode == .Emit else check_number_leaf(w.plan, rule_idx, s, small, 0, w.steps[:], w.sink, &w.first, &w.oom, w.allocator, w.scratch, false, w.secret_depth > 0)
	}
	buf: [64]u8 = ---
	#partial switch tn.kind {
	case .Enum:
		ei, ev := &w.plan.enums[tn.enum_idx], read_enum_value(ptr, tn.size, w.plan.enums[tn.enum_idx].ti); found := false
		for val, i in ei.values {
			if val == ev {
				found = true
				if w.mode == .Emit { leaf_ok = walk_emit_tok(w, .String, ei.names[i]) if ei.by_name else walk_emit_tok(w, .Number, strconv.write_uint(buf[:], u64(ev), 10) if ei.is_unsigned else strconv.write_int(buf[:], ev, 10)) }
				break
			}
		}
		if !found { leaf_ok = false; _ = walk_fail(w, .Not_A_Member) }
	case .String, .Email: leaf_ok = check_s(w, rule_idx, (^string)(ptr)^)
	case .Cstring:
		if cs := (^cstring)(ptr)^; cs == nil { if w.mode == .Emit { _ = walk_emit_tok(w, .Null, "") } else if not_null { leaf_ok = false; _ = walk_fail(w, .Wrong_Kind, "", {type = tn.type, text = "string"}) } } else { leaf_ok = check_s(w, rule_idx, string(cs)) }
	case .Bytes, .Base64, .Hex:
		enc: string; err: runtime.Allocator_Error
		if tn.kind == .Hex { enc, err = encode_hex((^Hex)(ptr)^, w.scratch) } else { enc, err = encode_base64((^[]u8)(ptr)^, w.scratch) }
		if err != nil { w.oom = true; return }
		leaf_ok = check_s(w, rule_idx, enc)
	case .Bool, .Bool_Wide:
		if w.mode == .Emit { _ = walk_emit_tok(w, .True if ((^bool)(ptr)^ if tn.kind == .Bool else read_wide_bool(ptr, tn.size)) else .False, "") }
	case .I8 ..= .I64: iv := read_signed_int(ptr, tn.kind); leaf_ok = check_n(w, rule_idx, strconv.write_int(buf[:], iv, 10), iv)
	case .U8 ..= .U64: uv := read_unsigned_int(ptr, tn.kind); leaf_ok = check_n(w, rule_idx, strconv.write_uint(buf[:], uv, 10), i64(uv) if uv <= u64(max(i64)) else nil)
	case .F32, .F64:
		x := f64((^f32)(ptr)^) if tn.kind == .F32 else (^f64)(ptr)^
		if math.is_nan(x) || math.is_inf(x, 0) { leaf_ok = false; _ = walk_fail(w, .Non_Finite) } else { leaf_ok = check_n(w, rule_idx, strconv.write_float(buf[:], x, 'g', -1, 32 if tn.kind == .F32 else 64, {}), nil) }
	case .Number_Text:
		if nt := (^Number_Text)(ptr)^; nt.text == "" { if w.mode == .Emit { _ = walk_emit_tok(w, .Null, "") } else if not_null { leaf_ok = false; _ = walk_fail(w, .Wrong_Kind, "", {type = tn.type, text = "number"}) } } else { leaf_ok = check_n(w, rule_idx, nt.text, nil) }
	case .Time:
		if s, ok := format_rfc3339_utc((^time.Time)(ptr)^, (^[40]u8)(&buf)); !ok { leaf_ok = false; _ = walk_fail(w, .Bad_Format) } else { leaf_ok = check_s(w, rule_idx, s) }
	case .Uuid: leaf_ok = check_s(w, rule_idx, format_uuid((^uuid.Identifier)(ptr)^, (^[36]u8)(&buf)))
	case .Decimal:
		d := (^Decimal)(ptr)^; text := d.text if d.text != "" else "0"
		if w.mode == .Emit { _ = walk_emit_tok(w, .Number, text) } else if !rules.valid_decimal_text(text) { leaf_ok = false; _ = walk_fail(w, .No_Match) } else { leaf_ok = check_n(w, rule_idx, text, nil) }
	case .Value:
		if w.mode == .Emit {
			if eerr := emit_rules_value_tokens(w.tt, (^rules.Value)(ptr)^, w.scratch); eerr != nil {
				switch e in eerr {
				case runtime.Allocator_Error: w.oom = true
				case write.Error: if _, is_oom := e.(runtime.Allocator_Error); is_oom { w.oom = true } else { w.write_err = e }
				case Model_Error: _ = walk_fail(w, e.kind, e.operand, e.want); error_destroy(e, w.scratch)
				case tape.Error:  w.oom = true
				}
			}
		}
	case .Raw: if w.mode == .Emit { _ = walk_fail(w, .Unsupported, want = {text = "Raw"}) }
	case:      if w.mode == .Emit { _ = walk_fail(w, .Unsupported) }
	}
	if !leaf_ok { w.fail_count += 1 }
	if w.mode == .Validate && !walk_stopped(w) && tn.judged && !val_run_judged(w, tn, node_idx, false, ptr) { w.fail_count += 1 }
}

@(private)
val_run_judged :: proc(w: ^Walk_State, tn: ^Type_Node, node_idx: i32, unique: bool, ptr: rawptr) -> bool {
	if w.judging == nil || node_idx < 0 { return true }
	j := judged_of(w.judging, tn.type, unique); if j == nil && unique { j = judged_of(w.judging, tn.type, false) }; if j == nil { return true }
	tt: write.Token_Tape
	if write.token_tape_start(&tt, false, 0, w.scratch) != nil { w.oom = true; return false }
	defer write.token_tape_drop(&tt)
	if eerr := emit_node(w.plan, &tt, node_idx, ptr, nil, nil, w.scratch, w.scratch, silent = true); eerr != nil {
		switch e in eerr {
		case runtime.Allocator_Error: w.oom = true; return false
		case tape.Error: if exc, ok := e.(tape.Exceeded); ok { w.budget.exceeded = exc } else { w.oom = true }; return false
		case write.Error: if _, is_oom := e.(runtime.Allocator_Error); is_oom { w.oom = true; return false }; return true
		case Model_Error: error_destroy(e, w.scratch); return true
		}
	}
	sub_doc, terr := write.token_tape_document(&tt); if terr != nil { w.oom = true; return false }
	return run_judged_on_subdoc(j, &sub_doc, w.policy, w.budget.limit, w.steps[:], w.sink, &w.first, &w.oom, &w.budget.exceeded, w.allocator, w.scratch, false, w.secret_depth > 0)
}

@(private)
list_span :: proc "contextless" (tn: ^Type_Node, ptr: rawptr) -> (uintptr, int) {
	#partial switch tn.kind {
	case .Slice:      rs := (^runtime.Raw_Slice)(ptr); return uintptr(rs.data), rs.len
	case .Dynamic:    rd := (^runtime.Raw_Dynamic_Array)(ptr); return uintptr(rd.data), rd.len
	case .Array:      return uintptr(ptr), tn.count
	case .Fixed_List: return uintptr(ptr), (^int)(uintptr(ptr) + tn.len_offset)^
	}
	return 0, 0
}

@(private)
read_u64_size :: proc "contextless" (ptr: rawptr, size: int) -> u64 {
	switch size {
	case 1: return u64((^u8)(ptr)^)
	case 2: return u64((^u16)(ptr)^)
	case 4: return u64((^u32)(ptr)^)
	case 8: return (^u64)(ptr)^
	}
	return 0
}

@(private)
read_i64_size :: proc "contextless" (ptr: rawptr, size: int) -> i64 {
	switch size {
	case 1: return i64((^i8)(ptr)^)
	case 2: return i64((^i16)(ptr)^)
	case 4: return i64((^i32)(ptr)^)
	case 8: return (^i64)(ptr)^
	}
	return 0
}

@(private)
read_wide_bool :: proc "contextless" (ptr: rawptr, size: int) -> bool { return read_u64_size(ptr, size) != 0 }
@(private)
read_signed_int :: proc "contextless" (ptr: rawptr, kind: Type_Kind) -> i64 { return read_i64_size(ptr, 1 << uint(int(kind) - int(Type_Kind.I8))) }
@(private)
read_unsigned_int :: proc "contextless" (ptr: rawptr, kind: Type_Kind) -> u64 { return read_u64_size(ptr, 1 << uint(int(kind) - int(Type_Kind.U8))) }
@(private)
read_enum_value :: proc(ptr: rawptr, size: int, ei: ^runtime.Type_Info_Enum) -> i64 {
	iv, _ := runtime.type_info_base(ei.base).variant.(^runtime.Type_Info_Integer)
	return read_i64_size(ptr, size) if iv.signed else i64(read_u64_size(ptr, size))
}
@(private)
read_union_tag :: proc "contextless" (ptr: rawptr, offset: uintptr, size: int) -> i64 { return i64(read_u64_size(rawptr(uintptr(ptr) + offset), size)) }

@(private)
Sorted_Map_Entry :: struct { key_text: string, val_ptr: rawptr }

@(private)
collect_sorted_map_entries :: proc(ti: ^runtime.Type_Info, map_ptr: rawptr, scratch: runtime.Allocator) -> (res: []Sorted_Map_Entry, err: runtime.Allocator_Error) {
	rm := (^runtime.Raw_Map)(map_ptr)
	if rm.len == 0 { return nil, nil }
	out := make([dynamic]Sorted_Map_Entry, 0, rm.len, scratch) or_return
	it := 0
	for k, val in reflect.iterate_map(any{map_ptr, ti.id}, &it) { append(&out, Sorted_Map_Entry{format_map_key(k, scratch) or_return, val.data}) or_return }
	slice.sort_by(out[:], proc(a, b: Sorted_Map_Entry) -> bool { return strings.compare(a.key_text, b.key_text) < 0 })
	return out[:], nil
}

@(private)
format_map_key :: proc(k: any, scratch: runtime.Allocator) -> (string, runtime.Allocator_Error) {
	base := runtime.type_info_base(type_info_of(k.id))
	#partial switch v in base.variant {
	case ^runtime.Type_Info_String:
		if v.is_cstring { cs := (^cstring)(k.data)^; return string(cs) if cs != nil else "", nil }
		return (^string)(k.data)^, nil
	case ^runtime.Type_Info_Integer:
		buf: [32]u8 = ---
		if v.signed { iv, _ := reflect.as_i64(k); return strings.clone(strconv.write_int(buf[:], iv, 10), scratch) }
		uv, _ := reflect.as_u64(k); return strings.clone(strconv.write_uint(buf[:], uv, 10), scratch)
	case ^runtime.Type_Info_Enum:
		ev := read_enum_value(k.data, base.size, v)
		for val, i in v.values { if i64(val) == ev { return v.names[i], nil } }
		buf: [32]u8 = ---
		return strings.clone(strconv.write_int(buf[:], ev, 10), scratch)
	}
	return "", nil
}
