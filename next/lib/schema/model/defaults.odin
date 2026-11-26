// Default constant storage and factory defaults (backed by `mem.Dynamic_Arena`, WASM-clean).
package model

import "base:intrinsics"
import "base:runtime"
import "core:encoding/uuid"
import "core:math"
import "core:mem"
import "core:reflect"
import "core:time"

Make_Default :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error

@(private)
Default_Of :: struct { type: typeid, field: string, make: Make_Default, data: rawptr }
@(private)
Constant_Kind :: enum u8 { Complex, Pod, String }
@(private)
Constant :: struct { type: ^runtime.Type_Info, value: rawptr, size: int, kind: Constant_Kind, is_zero: bool }

@(private)
constant_kind_of :: proc(ti: ^runtime.Type_Info) -> Constant_Kind {
	if ti == nil { return .Complex }
	if ti.id == time.Time || ti.id == uuid.Identifier { return .Pod }
	#partial switch v in runtime.type_info_base(ti).variant {
	case ^runtime.Type_Info_Boolean, ^runtime.Type_Info_Integer, ^runtime.Type_Info_Float, ^runtime.Type_Info_Enum, ^runtime.Type_Info_Bit_Set: return .Pod
	case ^runtime.Type_Info_String: return .Complex if v.is_cstring else .String
	}
	return .Complex
}

@(private)
bytes_all_zero :: proc "contextless" (p: rawptr, n: int) -> bool {
	if p == nil || n <= 0 { return true }
	for x in ([^]u8)(p)[:n] { if x != 0 { return false } }
	return true
}

@(private)
default_is_zero :: proc "contextless" (make_fn: Make_Default, data: rawptr) -> bool {
	return data != nil && (make_fn == copied_pod || make_fn == copied_string) && (^Constant)(data).is_zero
}

@(private)
default_constant :: proc(reg: ^Registry, member: ^runtime.Type_Info, field: string, value: any) -> (held: ^Constant, err: Error) {
	memory := reg_arena(reg)
	held = new(Constant, memory) or_return
	held.type, held.size, held.kind = member, member.size, constant_kind_of(member)
	held.value = mem.alloc(max(member.size, 1), member.align, memory) or_return
	fits := default_into(held.value, member, value, memory) or_return
	if !fits { return nil, Model_Error{kind = .Wrong_Kind, pointer = field, want = {member.id, type_name_short(member)}} }
	if held.kind == .Pod { held.is_zero = bytes_all_zero(held.value, held.size) } else if held.kind == .String { held.is_zero = len((^string)(held.value)^) == 0 }
	return held, nil
}

@(private)
copied_defaults :: proc(reg: ^Registry, arena, scratch: runtime.Allocator) -> (out: []Default_Of, err: Error) {
	if reg == nil || len(reg.loads.defaults) == 0 { return nil, nil }
	out = make([]Default_Of, len(reg.loads.defaults), scratch) or_return
	for x, i in reg.loads.defaults {
		out[i] = x
		if x.make != copied_constant || x.data == nil { continue }
		from := (^Constant)(x.data)
		c := new(Constant, arena) or_return; c^ = from^
		c.value = mem.alloc(max(from.type.size, 1), from.type.align, arena) or_return
		copy_value(c.value, from.value, from.type, arena, scratch) or_return
		out[i].data = c
		out[i].make = copied_pod if c.kind == .Pod else (copied_string if c.kind == .String else copied_constant)
	}
	return out, nil
}

@(private)
copied_pod :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	c := (^Constant)(data); if c.size > 0 { intrinsics.mem_copy_non_overlapping(dest, c.value, c.size) }
	return nil
}

@(private)
copied_string :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	s := (^string)((^Constant)(data).value)^; n := len(s)
	if n == 0 { (^string)(dest)^ = ""; return nil }
	raw, err := allocator.procedure(allocator.data, .Alloc_Non_Zeroed, n, 1, nil, 0)
	if err != nil || len(raw) < n || raw_data(raw) == nil { return err if err != nil else .Out_Of_Memory }
	stream_copy_short(raw_data(raw), raw_data(s), n)
	(^runtime.Raw_String)(dest)^ = {raw_data(raw), n}
	return nil
}

@(private)
copied_constant :: proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	c := (^Constant)(data); return copy_value(dest, c.value, c.type, allocator, allocator)
}

@(private)
default_into :: proc(slot: rawptr, member: ^runtime.Type_Info, value: any, a: runtime.Allocator) -> (fits: bool, err: runtime.Allocator_Error) {
	if member.id == value.id { return true, copy_value(slot, value.data, member, a, a) }
	if store_number(slot, member, value) { return true, nil }
	if u, is_u := runtime.type_info_base(member).variant.(^runtime.Type_Info_Union); is_u && len(u.variants) == 1 && !u.no_nil {
		fits = default_into(slot, u.variants[0], value, a) or_return
		if fits && !reflect.type_info_union_is_pure_maybe(u^) && u.tag_type != nil && u.tag_offset < uintptr(member.size) {
			one := u64(1); mem.copy(rawptr(uintptr(slot) + u.tag_offset), &one, u.tag_type.size)
		}
	}
	return
}

@(private)
store_number :: proc(slot: rawptr, to: ^runtime.Type_Info, from: any) -> bool {
	n: i128; x: f64; is_int, valid: bool
	#partial switch v in runtime.type_info_base(type_info_of(from.id)).variant {
	case ^runtime.Type_Info_Integer: is_int = true; if v.signed { i, ok := reflect.as_i64(from); n, valid = i128(i), ok } else { u, ok := reflect.as_u64(from); n, valid = i128(u), ok }
	case ^runtime.Type_Info_Float:   x, valid = reflect.as_f64(from)
	}
	if !valid { return false }
	#partial switch t in runtime.type_info_base(to).variant {
	case ^runtime.Type_Info_Integer:
		if to.size > 8 || t.endianness != .Platform { return false }
		if !is_int {
			if math.is_nan(x) || math.is_inf(x, 0) || math.trunc(x) != x { return false }
			if t.signed { if x < f64(min(i64)) || x >= 9223372036854775808.0 { return false }; n = i128(i64(x)) } else {
				if x < 0 || x >= 18446744073709551616.0 { return false }; n = i128(u64(x))
			}
		}
		bits := uint(to.size) * 8
		low, high := -(i128(1) << (bits - 1)) if t.signed else i128(0), (i128(1) << (bits - 1)) - 1 if t.signed else (i128(1) << bits) - 1
		if n < low || n > high { return false }
		mem.copy(slot, &n, to.size); return true
	case ^runtime.Type_Info_Float:
		if t.endianness != .Platform { return false }
		f := x if !is_int else f64(n)
		if is_int && (f < f64(min(i64)) || f >= 18446744073709551616.0 || (i128(u64(f)) if f >= 0 else i128(i64(f))) != n) { return false }
		switch to.size {
		case 8: (^f64)(slot)^ = f
		case 4: narrow := f32(f); if f64(narrow) != f && !math.is_nan(f) { return false }; (^f32)(slot)^ = narrow
		case: return false
		}
		return true
	}
	return false
}

@(private)
type_name_short :: proc(ti: ^runtime.Type_Info) -> string {
	if ti == nil { return "" }
	if named, ok := ti.variant.(^runtime.Type_Info_Named); ok { return named.name }
	#partial switch v in ti.variant {
	case ^runtime.Type_Info_String:  return "cstring" if v.is_cstring else "string"
	case ^runtime.Type_Info_Boolean: return "bool"
	case ^runtime.Type_Info_Integer:
		idx := intrinsics.count_trailing_zeros(ti.size)
		names := [4]string{"i8", "i16", "i32", "int"} if v.signed else [4]string{"u8", "u16", "u32", "u64"}
		if idx < 4 { return names[idx] }
	case ^runtime.Type_Info_Float:   return "f32" if ti.size == 4 else "f64"
	case ^runtime.Type_Info_Slice, ^runtime.Type_Info_Dynamic_Array, ^runtime.Type_Info_Array: return "array"
	case ^runtime.Type_Info_Map, ^runtime.Type_Info_Struct: return "object"
	}
	return "value"
}