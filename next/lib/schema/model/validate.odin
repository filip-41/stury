// Iterative in-memory validation of Odin values against compiled model constraints,
// schema applicators, write refusals (`Non_Finite`, invalid enums), budgets, and custom validators.
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
	if m == nil || v == nil || len(m.plan.nodes) == 0 {
		return Model_Error{kind = .Bad_Option, want = {text = "value"}}
	}
	return validate_inner(&m.plan, m.judging, rawptr(v), sink, opts, nil, allocator)
}

@(private)
Omit_Pred :: proc(ctx: rawptr, si: ^Struct_Info, fi: int, struct_ptr: rawptr) -> bool

@(private)
Omit_Hook :: struct {
	fn:  Omit_Pred,
	ctx: rawptr,
}

@(private)
validate_inner :: proc(plan: ^Type_Plan, judging: ^Applied, val_ptr: rawptr, sink: ^Sink, opts: Load_Opts, omit: ^Omit_Hook, allocator: runtime.Allocator) -> Error {
	policy, ok := resolve_dups(opts.dups, nil)
	if !ok {
		return Model_Error{kind = .Bad_Option, want = {text = "dups"}}
	}
	sc: Scratch_Scope
	scratch_begin(&sc, opts, allocator)
	defer scratch_end(&sc)

	from := len(sink.entries) if sink != nil else 0
	rs, rerr := regex.scratch_make(sc.scratch)
	if rerr.kind != .None {
		return scratch_oom_error(&sc)
	}
	defer regex.scratch_destroy(&rs)

	val := Validator_State{
		plan = plan, judging = judging, policy = policy, sink = sink, omit = omit,
		re_scratch = rs, allocator = sc.out, scratch = sc.scratch,
	}
	budget_init(&val.budget, opts.budget)
	val.steps.allocator = sc.scratch
	report_init(&val.rep, sc.scratch)
	defer report_destroy(&val.rep)

	validate_loop(&val, plan.root, val_ptr)
	if sink != nil {
		order_sink(sink, from)
	}
	if val.budget.exceeded.kind != .None {
		error_destroy(val.first, sc.out)
		return tape.Error(val.budget.exceeded)
	}
	if val.oom {
		error_destroy(val.first, sc.out)
		return scratch_oom_error(&sc)
	}
	return val.first if val.first.kind != .None else nil
}

@(private)
Validator_State :: struct {
	plan:       ^Type_Plan,
	judging:    ^Applied,
	policy:     tape.Duplicates,
	sink:       ^Sink,
	omit:       ^Omit_Hook,
	first:      Model_Error,
	oom:        bool,
	fail_count: u64,
	budget:     Budget_Tracker,
	steps:      [dynamic]tape.Step,
	rep:        Report,
	re_scratch: regex.Scratch,
	allocator:  runtime.Allocator,
	scratch:    runtime.Allocator,
}

@(private)
val_fail :: proc(v: ^Validator_State, kind: Error_Kind, operand := "", want := Want{}) -> bool {
	v.fail_count += 1
	return record_failure(v.sink, &v.first, &v.oom, v.allocator, kind, 0, v.steps[:], operand, want, false)
}

@(private)
val_stopped :: #force_inline proc "contextless" (v: ^Validator_State) -> bool {
	return v.oom || v.budget.exceeded.kind != .None || (v.sink == nil && v.first.kind != .None)
}

@(private)
Val_Frame_Kind :: enum u8 { Node, Struct_Fields, Struct_Finish, Field_After, List_Elems, Map_Entries, Run_Judged, Pop_Step, Leave_Depth }

@(private)
Val_Frame :: struct {
	kind:           Val_Frame_Kind,
	node_idx:       i32,
	ptr:            rawptr,
	field_rule_idx: i32,
	field_unique:   bool,
	not_null:       bool,
	si:             ^Struct_Info,
	fi, idx, count: int,
	stride, base:   uintptr,
	start_fails:    u64,
	entries:        []Sorted_Map_Entry,
	is_cap:         bool,
}

@(private)
validate_loop :: proc(v: ^Validator_State, root_idx: i32, root_ptr: rawptr) {
	stack, serr := make([dynamic]Val_Frame, 0, 32, v.scratch)
	if serr != nil { v.oom = true; return }
	defer delete(stack)
	if !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = root_idx, ptr = root_ptr}) { return }

	for len(stack) > 0 && !val_stopped(v) {
		top := &stack[len(stack) - 1]
		switch top.kind {
		case .Pop_Step:
			pop(&stack)
			if len(v.steps) > 0 { pop(&v.steps) }
		case .Leave_Depth:
			pop(&stack); budget_leave(&v.budget)
		case .Run_Judged:
			f := pop(&stack)
			if !val_run_judged(v, &v.plan.nodes[f.node_idx], f.node_idx, f.field_unique, f.ptr) { v.fail_count += 1 }
		case .Field_After:
			f := pop(&stack)
			if v.fail_count != f.start_fails { continue }
			report_reset(&v.rep)
			for av in f.si.fields[f.fi].afters { av.call(f.ptr, av.fn, &v.rep) }
			if v.rep.failed || v.rep.oom {
				v.fail_count += 1
				_ = emit_report(&v.rep, v.steps[:], 0, nil, v.sink, &v.first, &v.oom, v.allocator, v.scratch)
			}
		case .Struct_Finish:
			f := pop(&stack)
			tn := &v.plan.nodes[f.node_idx]
			if tn.judged && !val_run_judged(v, tn, f.node_idx, false, f.ptr) { v.fail_count += 1 }
			if val_stopped(v) { budget_leave(&v.budget); return }
			if v.fail_count == f.start_fails && len(f.si.validators) > 0 {
				report_reset(&v.rep)
				for sv in f.si.validators { sv.call(f.ptr, sv.fn, &v.rep) }
				if v.rep.failed || v.rep.oom {
					v.fail_count += 1
					_ = emit_report(&v.rep, v.steps[:], 0, f.si, v.sink, &v.first, &v.oom, v.allocator, v.scratch)
				}
			}
			budget_leave(&v.budget)
		case .Struct_Fields:
			si := top.si
			if top.idx < len(si.fields) {
				fi := top.idx; top.idx += 1
				fld := &si.fields[fi]
				if fld.access == .Write_Only || (v.omit != nil && v.omit.fn(v.omit.ctx, si, fi, top.ptr)) { continue }
				if !push_oom(&v.oom, &v.steps, tape.Step(tape.Name(fld.name))) { return }
				fdest := rawptr(uintptr(top.ptr) + fld.offset)
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Pop_Step}) { return }
				if len(fld.afters) > 0 && !push_oom(&v.oom, &stack, Val_Frame{kind = .Field_After, si = si, fi = fi, ptr = fdest, start_fails = v.fail_count}) { return }
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = fld.node, ptr = fdest, field_rule_idx = fld.rule_idx, field_unique = fld.has_unique, not_null = fld.not_null}) { return }
				continue
			}
			ptr := top.ptr; pop(&stack)
			if si.capture_idx >= 0 {
				cap_tn := &v.plan.nodes[si.capture_node]
				entries, merr := collect_sorted_map_entries(cap_tn.ti, rawptr(uintptr(ptr) + si.capture_offset), v.scratch)
				if merr != nil { v.oom = true; return }
				if len(entries) > 0 && !push_oom(&v.oom, &stack, Val_Frame{kind = .Map_Entries, node_idx = cap_tn.child, si = si, entries = entries, is_cap = true}) { return }
			}
		case .List_Elems:
			if top.idx >= top.count { pop(&stack); continue }
			i := top.idx; top.idx += 1
			if !push_oom(&v.oom, &v.steps, tape.Step(tape.Index(i))) { return }
			child_idx, elem_ptr := top.node_idx, rawptr(top.base + uintptr(i) * top.stride)
			if !push_oom(&v.oom, &stack, Val_Frame{kind = .Pop_Step}) || !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = child_idx, ptr = elem_ptr}) { return }
		case .Map_Entries:
			if top.idx >= len(top.entries) { pop(&stack); continue }
			e := top.entries[top.idx]; top.idx += 1
			if !push_oom(&v.oom, &v.steps, tape.Step(tape.Name(e.key_text))) { return }
			if top.is_cap && struct_find_field(top.si, e.key_text) >= 0 {
				_ = val_fail(v, .Duplicate_Key)
				pop(&v.steps)
				continue
			}
			child_idx := top.node_idx
			if !push_oom(&v.oom, &stack, Val_Frame{kind = .Pop_Step}) || !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = child_idx, ptr = e.val_ptr}) { return }
		case .Node:
			f := pop(&stack)
			if !budget_node(&v.budget, 0) { return }
			tn := &v.plan.nodes[f.node_idx]
			rule_idx := f.field_rule_idx if f.field_rule_idx > 0 else tn.rule_idx
			has_unique := f.field_unique || tn.has_unique
			ptr := f.ptr
			#partial switch tn.kind {
			case .Maybe:
				if !maybe_is_set(tn, ptr) {
					if f.not_null { _ = val_fail(v, .Wrong_Kind, "", {type = tn.type, text = "non-null"}) }
				} else if !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = tn.child, ptr = ptr, field_rule_idx = rule_idx, field_unique = has_unique}) { return }
			case .Ptr:
				inner := (^rawptr)(ptr)^
				if inner == nil {
					if f.not_null { _ = val_fail(v, .Wrong_Kind, "", {type = tn.type, text = "non-null"}) }
				} else {
					if !budget_enter(&v.budget, 0) { return }
					if !push_oom(&v.oom, &stack, Val_Frame{kind = .Leave_Depth}) || !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = tn.child, ptr = inner, field_rule_idx = rule_idx, field_unique = has_unique}) { return }
				}
			case .Struct:
				if !budget_enter(&v.budget, 0) || !budget_step(&v.budget, 0) { return }
				si := &v.plan.structs[tn.struct_idx]
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Struct_Finish, node_idx = f.node_idx, ptr = ptr, si = si, start_fails = v.fail_count}) { return }
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Struct_Fields, si = si, ptr = ptr}) { return }
			case .Slice, .Dynamic, .Array, .Fixed_List:
				if !budget_enter(&v.budget, 0) || !budget_step(&v.budget, 0) { return }
				base, n := list_span(tn, ptr)
				if !check_count_leaf(v.plan, rule_idx, u64(n), false, 0, v.steps[:], v.sink, &v.first, &v.oom, v.allocator, v.scratch, false) {
					v.fail_count += 1
					if val_stopped(v) { budget_leave(&v.budget); return }
				}
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Leave_Depth}) { return }
				if (has_unique || tn.judged) && !push_oom(&v.oom, &stack, Val_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr, field_unique = has_unique}) { return }
				if n > 0 && !push_oom(&v.oom, &stack, Val_Frame{kind = .List_Elems, node_idx = tn.child, base = base, count = n, stride = uintptr(v.plan.nodes[tn.child].size)}) { return }
			case .Map:
				if !budget_enter(&v.budget, 0) || !budget_step(&v.budget, 0) { return }
				rm := (^runtime.Raw_Map)(ptr)
				if !check_count_leaf(v.plan, rule_idx, u64(rm.len), true, 0, v.steps[:], v.sink, &v.first, &v.oom, v.allocator, v.scratch, false) {
					v.fail_count += 1
					if val_stopped(v) { budget_leave(&v.budget); return }
				}
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Leave_Depth}) { return }
				if tn.judged && !push_oom(&v.oom, &stack, Val_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr}) { return }
				if rm.len > 0 {
					entries, merr := collect_sorted_map_entries(tn.ti, ptr, v.scratch)
					if merr != nil { v.oom = true; return }
					if !push_oom(&v.oom, &stack, Val_Frame{kind = .Map_Entries, node_idx = tn.child, entries = entries}) { return }
				}
			case .Bit_Set:
				bytes, cnt := ([^]u8)(ptr)[:tn.size], u64(0)
				for bit in 0 ..< tn.count {
					if (bytes[bit / 8] >> uint(bit % 8)) & 1 != 0 { cnt += 1 }
				}
				if !check_count_leaf(v.plan, rule_idx, cnt, false, 0, v.steps[:], v.sink, &v.first, &v.oom, v.allocator, v.scratch, false) { v.fail_count += 1 }
				if !val_stopped(v) && tn.judged && !val_run_judged(v, tn, f.node_idx, false, ptr) { v.fail_count += 1 }
			case .Union:
				u := &v.plan.unions[tn.union_idx]
				arm_idx := int(read_union_tag(ptr, u.tag_offset, u.tag_size)) - (0 if u.no_nil else 1)
				if arm_idx < 0 {
					if tn.judged && !val_run_judged(v, tn, f.node_idx, false, ptr) { v.fail_count += 1 }
				} else if arm_idx >= len(u.arms) {
					_ = val_fail(v, .No_Arm)
				} else {
					if tn.judged && !push_oom(&v.oom, &stack, Val_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr}) { return }
					if !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = u.arms[arm_idx].node, ptr = ptr, field_rule_idx = rule_idx}) { return }
				}
			case .Custom:
				c, ctn := &v.plan.customs[tn.custom_idx], &v.plan.nodes[tn.child]
				cbuf, cerr := runtime.mem_alloc(max(ctn.size, 1), ctn.align, v.scratch)
				if cerr != nil { v.oom = true; return }
				if ck := c.convert_to(c.to, ptr, raw_data(cbuf), v.scratch); ck != .None {
					_ = val_fail(v, ck)
					continue
				}
				if tn.judged && !push_oom(&v.oom, &stack, Val_Frame{kind = .Run_Judged, node_idx = f.node_idx, ptr = ptr}) { return }
				if !push_oom(&v.oom, &stack, Val_Frame{kind = .Node, node_idx = tn.child, ptr = raw_data(cbuf), field_rule_idx = rule_idx, field_unique = has_unique}) { return }
			case:
				validate_scalar(v, f.node_idx, tn, ptr, rule_idx, f.not_null)
			}
		}
	}
}

@(private)
validate_scalar :: proc(v: ^Validator_State, node_idx: i32, tn: ^Type_Node, ptr: rawptr, rule_idx: i32, not_null: bool) {
	check_s :: #force_inline proc(v: ^Validator_State, rule_idx: i32, s: string) -> bool {
		return check_string_leaf(v.plan, &v.re_scratch, rule_idx, s, 0, v.steps[:], v.sink, &v.first, &v.oom, v.allocator, v.scratch, false)
	}
	check_n :: #force_inline proc(v: ^Validator_State, rule_idx: i32, s: string, small: Maybe(i64)) -> bool {
		return check_number_leaf(v.plan, rule_idx, s, small, 0, v.steps[:], v.sink, &v.first, &v.oom, v.allocator, v.scratch, false)
	}
	leaf_ok := true
	#partial switch tn.kind {
	case .Enum:
		ei := &v.plan.enums[tn.enum_idx]
		if !slice.contains(ei.values, read_enum_value(ptr, tn.size, ei.ti)) {
			leaf_ok = false; _ = val_fail(v, .Not_A_Member)
		}
	case .String, .Email:
		leaf_ok = check_s(v, rule_idx, (^string)(ptr)^)
	case .Cstring:
		if cs := (^cstring)(ptr)^; cs == nil {
			if not_null { leaf_ok = false; _ = val_fail(v, .Wrong_Kind, "", {type = tn.type, text = "string"}) }
		} else {
			leaf_ok = check_s(v, rule_idx, string(cs))
		}
	case .Bytes, .Base64:
		enc, err := encode_base64((^[]u8)(ptr)^, v.scratch)
		if err != nil { v.oom = true; return }
		leaf_ok = check_s(v, rule_idx, enc)
	case .Hex:
		enc, err := encode_hex((^Hex)(ptr)^, v.scratch)
		if err != nil { v.oom = true; return }
		leaf_ok = check_s(v, rule_idx, enc)
	case .I8 ..= .U64:
		buf: [32]u8 = ---
		if tn.kind <= .I64 {
			iv := read_signed_int(ptr, tn.kind)
			leaf_ok = check_n(v, rule_idx, strconv.write_int(buf[:], iv, 10), iv)
		} else {
			uv := read_unsigned_int(ptr, tn.kind)
			leaf_ok = check_n(v, rule_idx, strconv.write_uint(buf[:], uv, 10), i64(uv) if uv <= u64(max(i64)) else nil)
		}
	case .F32:
		x := (^f32)(ptr)^
		if math.is_nan(x) || math.is_inf(x, 0) { leaf_ok = false; _ = val_fail(v, .Non_Finite) } else {
			buf: [64]u8 = ---
			leaf_ok = check_n(v, rule_idx, strconv.write_float(buf[:], f64(x), 'g', -1, 32, {}), nil)
		}
	case .F64:
		x := (^f64)(ptr)^
		if math.is_nan(x) || math.is_inf(x, 0) { leaf_ok = false; _ = val_fail(v, .Non_Finite) } else {
			buf: [64]u8 = ---
			leaf_ok = check_n(v, rule_idx, strconv.write_float(buf[:], x, 'g', -1, 64, {}), nil)
		}
	case .Number_Text:
		if nt := (^Number_Text)(ptr)^; nt.text == "" {
			if not_null { leaf_ok = false; _ = val_fail(v, .Wrong_Kind, "", {type = tn.type, text = "number"}) }
		} else {
			leaf_ok = check_n(v, rule_idx, nt.text, nil)
		}
	case .Time:
		buf: [40]u8 = ---
		if s, ok := format_rfc3339_utc((^time.Time)(ptr)^, &buf); !ok { leaf_ok = false; _ = val_fail(v, .Bad_Format) } else { leaf_ok = check_s(v, rule_idx, s) }
	case .Uuid:
		buf: [36]u8 = ---
		leaf_ok = check_s(v, rule_idx, format_uuid((^uuid.Identifier)(ptr)^, &buf))
	case .Decimal:
		d := (^Decimal)(ptr)^
		text := d.text if d.text != "" else "0"
		if !rules.valid_decimal_text(text) { leaf_ok = false; _ = val_fail(v, .No_Match) } else { leaf_ok = check_n(v, rule_idx, text, nil) }
	}
	if !leaf_ok { v.fail_count += 1 }
	if !val_stopped(v) && tn.judged && !val_run_judged(v, tn, node_idx, false, ptr) { v.fail_count += 1 }
}

@(private)
val_run_judged :: proc(v: ^Validator_State, tn: ^Type_Node, node_idx: i32, unique: bool, ptr: rawptr) -> bool {
	if v.judging == nil || node_idx < 0 { return true }
	j := judged_of(v.judging, tn.type, unique)
	if j == nil && unique { j = judged_of(v.judging, tn.type, false) }
	if j == nil { return true }
	tt: write.Token_Tape
	if write.token_tape_start(&tt, false, 0, v.scratch) != nil { v.oom = true; return false }
	defer write.token_tape_drop(&tt)
	d := Emitter{plan = v.plan, tt = &tt, allocator = v.allocator, scratch = v.scratch}
	if eerr := emit_node(&d, node_idx, ptr, ""); eerr != nil {
		switch e in eerr {
		case runtime.Allocator_Error: v.oom = true; return false
		case tape.Error:
			if exc, ok := e.(tape.Exceeded); ok { v.budget.exceeded = exc } else { v.oom = true }
			return false
		case write.Error:
			if _, is_oom := e.(runtime.Allocator_Error); is_oom { v.oom = true; return false }
			return true
		case Model_Error:
			error_destroy(e, v.allocator)
			return true
		}
	}
	sub_doc, terr := write.token_tape_document(&tt)
	if terr != nil { v.oom = true; return false }
	return run_judged_on_subdoc(j, &sub_doc, v.policy, v.budget.limit, v.steps[:], v.sink, &v.first, &v.oom, &v.budget.exceeded, v.allocator, v.scratch)
}

// ============================================================================
// Shared reflection helpers for `validate` and `dump`
// ============================================================================

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
read_wide_bool :: proc "contextless" (ptr: rawptr, size: int) -> bool {
	switch size {
	case 2: return bool((^b16)(ptr)^)
	case 4: return bool((^b32)(ptr)^)
	case 8: return bool((^b64)(ptr)^)
	}
	return false
}

@(private)
read_signed_int :: proc "contextless" (ptr: rawptr, kind: Type_Kind) -> i64 {
	#partial switch kind {
	case .I8:  return i64((^i8)(ptr)^)
	case .I16: return i64((^i16)(ptr)^)
	case .I32: return i64((^i32)(ptr)^)
	case .I64: return (^i64)(ptr)^
	}
	return 0
}

@(private)
read_unsigned_int :: proc "contextless" (ptr: rawptr, kind: Type_Kind) -> u64 {
	#partial switch kind {
	case .U8:  return u64((^u8)(ptr)^)
	case .U16: return u64((^u16)(ptr)^)
	case .U32: return u64((^u32)(ptr)^)
	case .U64: return (^u64)(ptr)^
	}
	return 0
}

@(private)
read_enum_value :: proc(ptr: rawptr, size: int, ei: ^runtime.Type_Info_Enum) -> i64 {
	iv, _ := runtime.type_info_base(ei.base).variant.(^runtime.Type_Info_Integer)
	if iv.signed {
		switch size {
		case 1: return i64((^i8)(ptr)^)
		case 2: return i64((^i16)(ptr)^)
		case 4: return i64((^i32)(ptr)^)
		case 8: return (^i64)(ptr)^
		}
	} else {
		switch size {
		case 1: return i64((^u8)(ptr)^)
		case 2: return i64((^u16)(ptr)^)
		case 4: return i64((^u32)(ptr)^)
		case 8: return i64((^u64)(ptr)^)
		}
	}
	return 0
}

@(private)
read_union_tag :: proc "contextless" (ptr: rawptr, offset: uintptr, size: int) -> i64 {
	switch size {
	case 1: return i64((^u8)(uintptr(ptr) + offset)^)
	case 2: return i64((^u16)(uintptr(ptr) + offset)^)
	case 4: return i64((^u32)(uintptr(ptr) + offset)^)
	case 8: return (^i64)(uintptr(ptr) + offset)^
	}
	return 0
}

@(private)
Sorted_Map_Entry :: struct {
	key_text: string,
	val_ptr:  rawptr,
}

@(private)
collect_sorted_map_entries :: proc(ti: ^runtime.Type_Info, map_ptr: rawptr, scratch: runtime.Allocator) -> (res: []Sorted_Map_Entry, err: runtime.Allocator_Error) {
	rm := (^runtime.Raw_Map)(map_ptr)
	if rm.len == 0 { return nil, nil }
	out := make([dynamic]Sorted_Map_Entry, 0, rm.len, scratch) or_return
	it := 0
	for k, val in reflect.iterate_map(any{map_ptr, ti.id}, &it) {
		append(&out, Sorted_Map_Entry{format_map_key(k, scratch) or_return, val.data}) or_return
	}
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
