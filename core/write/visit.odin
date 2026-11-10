package write

// A visit: the typed write's walk over a value, writing nothing, that hands each record with a rule set and each refusal to
// a visitor with the path to its value.

import "base:intrinsics"
import core ".."
import "../typed"

// What a visit calls at each record whose `Meta.rule_set` is set, with `kind` `.None`, and at each refusal of the walk,
// with its kind. `f` is the record and `at` its value. It returns whether the visit goes on. The walk goes on past a
// refused number or enum when it does, and ends at any other refusal.
Visit :: #type proc(v: ^Visitor, f: ^typed.Field, at: uintptr, kind: core.Typed_Error_Kind) -> bool

Visitor :: struct {
	call:   Visit,
	// Called at the close of a struct that has validators, with its model and the address of its first byte, nil for none.
	close:  proc(v: ^Visitor, sm: ^typed.Struct_Model, base: uintptr) -> bool,
	// The walk being visited, which `visit_path` reads during a call.
	walker: rawptr,
}

// The tree a visit is instantiated with, whose bytes it writes nowhere.
@(private)
VISIT_TREE :: Tree{.Open_Object = "{", .Close_Object = "}", .Open_Array = "[", .Close_Array = "]", .Comma = ",", .Colon = ":", .After_Colon = " ", .Null = "null", .True = "true", .False = "false"}

// Walks `value`, of `plan`'s type, as `marshal` would write it, and calls `v.call` as `Visit` says. An `any` and a hooked
// value are not entered. Returns the refusal that ended the visit, with its path. It allocates only for a map or a
// struct whose members are listed before they are walked.
visit :: proc(plan: ^typed.Plan, value: rawptr, v: ^Visitor) -> core.Typed_Error {
	if plan.err.kind != .None {
		return plan.err
	}
	frames: [FRAMES]Frame = ---
	ptrs: [core.MAX_DEPTH]Target = ---
	spill: [ROOM_MAX]u8 = ---
	w: Walker
	init(&w.out, &spill)
	walker_init(&w, {}, raw_data(frames[:]), raw_data(ptrs[:]))
	w.plan, w.meta, w.visitor, v.walker = plan, raw_data(plan.meta), v, &w
	w.err.kind = walk(&w, uintptr(value), false, VISIT_TREE, visit_put, true)
	v.walker = nil
	release_walker(&w)
	return w.err
}

// Appends the path to the value of the record the visitor is called at to `steps`, outermost first. Its names last as
// long as the call.
visit_path :: proc(v: ^Visitor, steps: ^[dynamic]core.Step) -> bool {
	w := (^Walker)(v.walker)
	first := len(steps)
	for i := w.top + 1; i >= 1; i -= 1 {
		if step, ok := frame_step(w, &w.open if i == w.top + 1 else &w.frames[i]); ok {
			if _, failed := append(steps, step); failed != nil {
				return false
			}
		}
	}
	for i, j := first, len(steps) - 1; i < j; i, j = i + 1, j - 1 {
		steps[i], steps[j] = steps[j], steps[i]
	}
	return true
}

// Calls the visitor at `f` with `kind`, and says whether the walk goes on.
@(private)
visit_record :: proc(w: ^Walker, open: Frame, top: int, f: ^typed.Field, at: uintptr, kind: core.Typed_Error_Kind) -> bool {
	w.open, w.top = open, top
	more := w.visitor.call(w.visitor, f, at, kind)
	#partial switch f.kind {
	case .F32, .F64, .Enum:
		return more
	}
	return more && kind == .None
}

// Calls the visitor's close at the struct of frame `cur`, whose path is that of the frames below it, and says whether the
// walk goes on.
@(private)
visit_close :: proc(w: ^Walker, cur: Frame, top: int, sm: ^typed.Struct_Model) -> bool {
	open := cur
	open.mode = .Target
	w.open, w.top = open, top
	return w.visitor.close(w.visitor, sm, cur.at)
}

// What a visit refuses of a value with no frame: a float that is not finite and an enum value no member has.
@(private)
visit_leaf :: proc(w: ^Walker, f: ^typed.Field, v: uintptr) -> core.Typed_Error_Kind {
	#partial switch f.kind {
	case .F32:
		x := (^f32)(v)^
		if x - x != 0 {
			return .Non_Finite
		}
	case .Enum:
		info := w.meta[f.meta].enum_info
		if typed.enum_member(info, enum_value(info, v)) < 0 {
			return .Not_A_Member
		}
	}
	return .None
}

// The string writer of a visit, which writes nothing. A listed key then holds only its own bytes.
@(private)
visit_put :: proc(out: ^Out, p: [^]u8, s: string, opts: ^core.Write_Options) -> core.Typed_Error_Kind {
	return .None
}

// The step frame `f` adds to the path of the value it holds open, false for a frame that adds none.
@(private)
frame_step :: proc(w: ^Walker, f: ^Frame) -> (core.Step, bool) {
	#partial switch f.mode {
	case .Members:
		return core.Name(w.meta[intrinsics.ptr_offset(f.r, -1).meta].name), true
	case .Elements:
		if f.left < f.total {
			return core.Index(f.total - f.left - 1), true
		}
	case .Entries:
		if f.left < f.total {
			return core.Name(entry_name(w, w.entries[f.at - 1])), true
		}
	}
	return {}, false
}
