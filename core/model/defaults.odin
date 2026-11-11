package model

import "base:runtime"
import "core:mem"
import "core:mem/virtual"
import "core:reflect"
import core ".."
import typed "../typed"

// A default's value and its type, which `copied` clones for each load.
@(private)
Constant :: struct {
	type:  ^runtime.Type_Info,
	value: rawptr,
}

// The constant that makes `value` the default of member `field`, of type `member`, in the registry's memory, or the
// refusal for a value the member cannot hold.
@(private)
default_constant :: proc(reg: ^Registry, member: ^runtime.Type_Info, field: string, value: any) -> (held: ^Constant, refusal: core.Typed_Refusal, err: runtime.Allocator_Error) {
	memory := virtual.arena_allocator(&reg.loads.memory)
	held = new(Constant, memory) or_return
	held.type = member
	held.value = mem.alloc(member.size, member.align, memory) or_return
	if fits := default_into(held.value, member, value, memory) or_return; !fits {
		refusal = {kind = .Wrong_Kind, found = found_kind(type_info_of(value.id)), n_steps = 1}
		refusal.want.type = member.id
		refusal.steps[0] = core.Name(field)
		typed.own_names(&refusal)
	}
	return
}

// The defaults of `reg`, none for nil, in the temp allocator, with a copy in `memory` of each constant.
@(private)
copied_defaults :: proc(reg: ^Registry, memory: ^virtual.Arena) -> ([]Default_Of, core.Error) {
	if reg == nil {
		return nil, nil
	}
	out := make([]Default_Of, len(reg.loads.defaults), context.temp_allocator)
	a := virtual.arena_allocator(memory)
	for x, i in reg.loads.defaults {
		out[i] = x
		if x.make != copied_constant {
			continue
		}
		from := (^Constant)(x.data)
		c, failed := new(Constant, a)
		if failed == nil {
			c.type = from.type
			c.value, failed = mem.alloc(from.type.size, from.type.align, a)
		}
		if failed == nil {
			failed = copy_value(c.value, from.value, from.type, a)
		}
		if failed != nil {
			return nil, core.error_of(core.Typed_Refusal{kind = .No_Memory})
		}
		out[i].data = c
	}
	return out, nil
}

@(private)
copied_constant :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	c := (^Constant)(data)
	return copy_value(dest, c.value, c.type, allocator)
}

// Stores `value` in `slot`, which holds the zero value of `member`, when `member` can hold it: it has the member's type,
// or is a number the member's number type holds exactly, or fits what a `Maybe` member holds. Says whether it fit.
@(private)
default_into :: proc(slot: rawptr, member: ^runtime.Type_Info, value: any, a: runtime.Allocator) -> (fits: bool, err: runtime.Allocator_Error) {
	if member.id == value.id {
		return true, copy_value(slot, value.data, member, a)
	}
	if store_number(slot, member, value) {
		return true, nil
	}
	if u, is_union := runtime.type_info_base(member).variant.(runtime.Type_Info_Union); is_union && len(u.variants) == 1 && !u.no_nil && u.tag_type != nil {
		fits = default_into(slot, u.variants[0], value, a) or_return
		if fits {
			one := u64(1)
			mem.copy(rawptr(uintptr(slot) + u.tag_offset), &one, u.tag_type.size)
		}
	}
	return
}

// Stores the number `from` in `slot` as the number type `to` when `to` holds it exactly.
@(private)
store_number :: proc(slot: rawptr, to: ^runtime.Type_Info, from: any) -> bool {
	n: i128
	x: f64
	is_int, valid: bool
	#partial switch v in runtime.type_info_base(type_info_of(from.id)).variant {
	case runtime.Type_Info_Integer:
		is_int = true
		if v.signed {
			i, ok := reflect.as_i64(from)
			n, valid = i128(i), ok
		} else {
			u, ok := reflect.as_u64(from)
			n, valid = i128(u), ok
		}
	case runtime.Type_Info_Float:
		x, valid = reflect.as_f64(from)
	}
	if !valid {
		return false
	}
	#partial switch t in runtime.type_info_base(to).variant {
	case runtime.Type_Info_Integer:
		if !is_int {
			// A float that is a whole number an i64 holds.
			if x != x || x != f64(i64(x)) {
				return false
			}
			n = i128(i64(x))
		}
		if to.size > 8 || t.endianness != .Platform {
			return false
		}
		bits := uint(to.size) * 8
		low, high := -(i128(1) << (bits - 1)) if t.signed else 0, (i128(1) << (bits - 1)) - 1 if t.signed else (i128(1) << bits) - 1
		if n < low || n > high {
			return false
		}
		mem.copy(slot, &n, to.size)
		return true
	case runtime.Type_Info_Float:
		if t.endianness != .Platform {
			return false
		}
		f := x if !is_int else f64(n)
		if is_int && i128(f) != n {
			return false
		}
		switch to.size {
		case 8:
			(^f64)(slot)^ = f
		case 4:
			narrow := f32(f)
			if f64(narrow) != f && f == f {
				return false
			}
			(^f32)(slot)^ = narrow
		case:
			return false
		}
		return true
	}
	return false
}

// The kind of value a default of type `ti` reads as, for the refusal that names the member's type.
@(private)
found_kind :: proc(ti: ^runtime.Type_Info) -> core.Kind {
	#partial switch _ in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		return .Number
	case runtime.Type_Info_String:
		return .String
	case runtime.Type_Info_Boolean:
		return .True
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array:
		return .Array
	}
	return .Object
}
