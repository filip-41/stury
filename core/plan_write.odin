package core

// Writing a value by its type plan: the walk over its kinds (`plan_write_value`), what a pointer, an `any`, a
// union or a hooked value writes, the depth and cycle checks on the open path, and the path to a value refused.
// A format's writer embeds a `Plan_Writer` and passes its emit procs, fixed at compile time; its containers and
// scalars are framed by those procs.

import "base:runtime"
import "core:unicode/utf8"

// A pointer's or an `any`'s target on the open path. A cycle meets the same address as the same type again. A
// struct and its first field share an address but not an op.
Plan_Target :: struct {
	at: rawptr,
	op: u32,
}

// The walk's state, embedded (`using`) in a format's writer.
Plan_Writer :: struct {
	plan:      ^Hooked_Plan,
	// MAX_DEPTH slots, of which ptrs[:n_ptrs] are the targets on the open path.
	ptrs:      [^]Plan_Target,
	// Where a refusal's path is put on its way out (`plan_refused_in`); nil when the caller takes the kind alone.
	fault:     ^Marshal_Error,
	depth:     u32, // containers and pointers open: the recursion ceiling
	n_ptrs:    u32,
	// The format's `marshal_into`: `w` is the format's writer, which embeds this one first.
	hook_write: proc(w: ^Plan_Writer, value: any) -> Marshal_Error_Kind,
	// A hook is running and has not yet written its one value.
	hook_open: bool,
	// The op `plan_hook_value` last looked up, by type: a hook passes one type every time, so most calls skip the
	// plan's map.
	into_id:   typeid,
	into_op:   u32,
}

// The value a pointer or an `any` refers to, counted toward the depth and checked against the open path.
plan_write_target :: proc(
	w: ^$W,
	idx: u32,
	target: rawptr,
	$value: proc(w: ^W, idx: u32, data: rawptr) -> Marshal_Error_Kind,
) -> Marshal_Error_Kind {
	for k in 0 ..< w.n_ptrs {
		if w.ptrs[k] == {target, idx} {
			return .Cycle
		}
	}
	if w.depth == MAX_DEPTH {
		return .Too_Deep
	}
	w.ptrs[w.n_ptrs] = {target, idx}
	w.n_ptrs += 1
	w.depth += 1
	err := value(w, idx, target)
	w.n_ptrs -= 1
	w.depth -= 1
	return err
}

// The pointer `op` at `data`: its target, or no value for nil.
plan_write_pointer :: proc(
	w: ^$W,
	op: Plan_Op,
	data: rawptr,
	$value: proc(w: ^W, idx: u32, data: rawptr) -> Marshal_Error_Kind,
	$null: proc(w: ^W) -> Marshal_Error_Kind,
) -> Marshal_Error_Kind {
	target := (^rawptr)(data)^
	if target == nil {
		return null(w)
	}
	return plan_write_target(w, op.elem, target, value)
}

// The `any` at `data`: its value by the plan of its type, or no value for nil. A type met first here compiles,
// which may move the plan's arrays (`Type_Plan`).
plan_write_any :: proc(
	w: ^$W,
	data: rawptr,
	$value: proc(w: ^W, idx: u32, data: rawptr) -> Marshal_Error_Kind,
	$null: proc(w: ^W) -> Marshal_Error_Kind,
) -> Marshal_Error_Kind {
	a := (^any)(data)^
	if a.id == nil || a.data == nil {
		return null(w)
	}
	idx := plan_op_m(w.plan, type_info_of(a.id)) or_return
	return plan_write_target(w, idx, a.data, value)
}

// The arm the union `op` at `data` holds: its op and, for a struct arm of a tagged union under `union_tag`, its
// tag name as spelled in `keys`. `ok` is false for nil.
plan_union_written :: proc(p: ^Hooked_Plan, op: Plan_Op, data: rawptr) -> (arm_op: u32, tag: string, ok: bool) {
	k := plan_union_arm(op, data)
	if k < 0 {
		return 0, "", false
	}
	// A union's arm lives at offset 0.
	arm := p.fields[op.elem + u32(k)]
	if op.tagged && p.tag_hi > 0 && arm.key_hi > arm.key_lo {
		tag = string(p.keys[arm.key_lo:arm.key_hi])
	}
	return arm.op, tag, true
}

// The hooked value `op` at `data`: the caller's proc writes it through `w.hook_write`, and must write exactly one
// value (`plan_hook_value`), nested as deep as the values open around it.
plan_write_hooked :: proc(w: ^Plan_Writer, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	write := w.plan.writes[op.elem]
	if write == nil {
		return .Unsupported
	}
	// Saved: the hook's value may hold a hooked value of its own.
	outer := w.hook_open
	w.hook_open = true
	err := write(Marshal_Out(w), data)
	if err == .None && w.hook_open {
		err = .Bad_State
	}
	w.hook_open = outer
	return err
}

// The one value a running hook writes (`marshal_into`): the op of its type, or `.Bad_State` when the hook has
// already written. `null` is true for a nil `value`. A type met first here compiles, which may move the plan's
// arrays under every writer the hook runs inside (`Type_Plan`).
plan_hook_value :: proc(w: ^Plan_Writer, value: any) -> (idx: u32, null: bool, err: Marshal_Error_Kind) {
	if !w.hook_open {
		return 0, false, .Bad_State
	}
	w.hook_open = false
	if value.id == nil || value.data == nil {
		return 0, true, .None
	}
	if value.id != w.into_id {
		w.into_op = plan_op_m(w.plan, type_info_of(value.id)) or_return
		w.into_id = value.id
	}
	return w.into_op, false, .None
}

// Puts `s` before the path of the value refused with `e`, and returns `e`. A refusal is located on its way out,
// innermost step first, so the writers pay nothing for it until one happens.
@(cold)
plan_refused_in :: #force_no_inline proc(w: ^Plan_Writer, s: Step, e: Marshal_Error_Kind) -> Marshal_Error_Kind {
	if w.fault != nil {
		error_path_prepend(w.fault, s)
	}
	return e
}

// `plan_refused_in` element `k`.
@(cold)
plan_refused_at_index :: #force_no_inline proc(w: ^Plan_Writer, k: int, e: Marshal_Error_Kind) -> Marshal_Error_Kind {
	return plan_refused_in(w, Index(k), e)
}

// `plan_refused_in` the field `w.plan.fields[k]`, by its name.
@(cold)
plan_refused_at_field :: #force_no_inline proc(w: ^Plan_Writer, k: u32, e: Marshal_Error_Kind) -> Marshal_Error_Kind {
	return plan_refused_in(w, Name(w.plan.sources[k].name), e)
}

// The value `op` at `data`, written by its kind: core's for a pointer, an `any`, a union's arm and a cstring's or a
// rune's text, the format's emit procs for the rest. Each emit proc is fixed at compile time and inlined. `value`
// writes the value of an op by its index, `null` no value, `text` a string's text, `own` one of the format's own
// types (`Plan_Format.types`), `elems` a sequence's `n` elements from `base`; a format without containers
// refuses them in `elems`, `fields`, `entries` and `bits`.
plan_write_value :: #force_inline proc(
	w: ^$W,
	op: Plan_Op,
	data: rawptr,
	$value: proc(w: ^W, idx: u32, data: rawptr) -> Marshal_Error_Kind,
	$null: proc(w: ^W) -> Marshal_Error_Kind,
	$scalar: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind, // a bool, an int, a uint or a float
	$wide: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind, // a 128-bit integer
	$text: proc(w: ^W, s: string) -> Marshal_Error_Kind,
	$enum_: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
	$arm: proc(w: ^W, arm: u32, data: rawptr, tag: string) -> Marshal_Error_Kind, // `plan_union_written`'s
	$hooked: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
	$own: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
	$elems: proc(w: ^W, op: Plan_Op, base: rawptr, n: int) -> Marshal_Error_Kind,
	$fields: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
	$entries: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
	$bits: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
) -> Marshal_Error_Kind {
	switch op.kind {
	case .Unsupported:
		return .Unsupported
	case .Bool, .Int, .Uint, .Float:
		return scalar(w, op, data)
	case .Wide_Int, .Wide_Uint:
		return wide(w, op, data)
	case .String:
		return text(w, (^string)(data)^)
	case .Cstring, .Rune, .Enum_Int, .Enum_Uint, .Union, .Any:
		return plan_write_rare(w, op, data, value, null, text, enum_, arm)
	case .Hook:
		return hooked(w, op, data)
	case .Pointer:
		return plan_write_pointer(w, op, data, value, null)
	case .Raw, .Number, .Digits, .Decoded, .Null:
		return own(w, op, data)
	case .Slice, .Dynamic:
		raw := (^runtime.Raw_Slice)(data)^
		return elems(w, op, raw.data, raw.len)
	case .Array:
		return elems(w, op, data, int(op.count))
	case .Fixed_List:
		return elems(w, op, data, (^int)(uintptr(data) + uintptr(op.len_offset))^)
	case .Struct:
		return fields(w, op, data)
	case .Map:
		return entries(w, op, data)
	case .Bit_Set:
		return bits(w, op, data)
	}
	return .None
}

// The kinds that need locals of their own: a cstring, a rune's bytes, an enum's member, a union's arm and an
// `any`'s plan. Each level of a nested write holds a frame of the format's value writer, and a value nested
// MAX_DEPTH deep must fit a Windows thread's 1 MB stack, so these stay out of that frame.
@(private = "file")
plan_write_rare :: #force_no_inline proc(
	w: ^$W,
	op: Plan_Op,
	data: rawptr,
	$value: proc(w: ^W, idx: u32, data: rawptr) -> Marshal_Error_Kind,
	$null: proc(w: ^W) -> Marshal_Error_Kind,
	$text: proc(w: ^W, s: string) -> Marshal_Error_Kind,
	$enum_: proc(w: ^W, op: Plan_Op, data: rawptr) -> Marshal_Error_Kind,
	$arm: proc(w: ^W, arm: u32, data: rawptr, tag: string) -> Marshal_Error_Kind,
) -> Marshal_Error_Kind {
	#partial switch op.kind {
	case .Cstring:
		cs := (^cstring)(data)^
		if cs == nil {
			return null(w)
		}
		return text(w, string(cs))
	case .Rune:
		r := (^rune)(data)^
		if !utf8.valid_rune(r) {
			return .Bad_Utf8
		}
		bytes, n := utf8.encode_rune(r)
		return text(w, string(bytes[:n]))
	case .Enum_Int, .Enum_Uint:
		return enum_(w, op, data)
	case .Any:
		return plan_write_any(w, data, value, null)
	case .Union:
		k, tag, held := plan_union_written(w.plan, op, data)
		if !held {
			return null(w)
		}
		return arm(w, k, data, tag)
	}
	return .None
}
