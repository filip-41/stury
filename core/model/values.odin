package model

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"

// What `values` does with the values of one type at `a` and `b`. Strings, slices, dynamic arrays, maps, pointers' targets
// and unions are taken by what they hold, and the rest, floats among them, by their bytes.
@(private)
Values_Op :: enum u8 {
	// Copies `b` into `a`, which holds the zero value, whole into the allocator. A map that holds entries keeps them, and
	// the entry of a key it holds takes `b`'s value.
	Copy,
	Equal, // whether `a` and `b` are equal
	Free, // frees what `a` holds into the allocator, a dynamic array and a map into their own, and `b` is `a`. An allocator that frees nothing is not a failure
}

// Does `op` with the values of type `ti` at `a` and `b`. Says whether they are equal for `.Equal`, and true otherwise.
@(private)
values :: proc(op: Values_Op, a, b: rawptr, ti: ^runtime.Type_Info, allocator: runtime.Allocator) -> (same: bool, err: runtime.Allocator_Error) {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		if v.is_cstring {
			x, y := (^cstring)(a), (^cstring)(b)
			switch op {
			case .Copy:
				if y^ != nil {
					x^ = strings.clone_to_cstring(string(y^), allocator) or_return
				}
			case .Equal:
				return string(x^) == string(y^) && (x^ == nil) == (y^ == nil), nil
			case .Free:
				delete(x^, allocator)
			}
			return true, nil
		}
		x, y := (^string)(a), (^string)(b)
		switch op {
		case .Copy:
			x^ = strings.clone(y^, allocator) or_return
		case .Equal:
			return x^ == y^, nil
		case .Free:
			delete(x^, allocator)
		}
		return true, nil
	case runtime.Type_Info_Slice:
		x, y := (^runtime.Raw_Slice)(a), (^runtime.Raw_Slice)(b)
		if op == .Copy {
			x.len = y.len
		}
		return elements(op, &x.data, x.len, y.data, y.len, v.elem, allocator)
	case runtime.Type_Info_Dynamic_Array:
		x, y := (^runtime.Raw_Dynamic_Array)(a), (^runtime.Raw_Dynamic_Array)(b)
		if op == .Copy {
			x.len, x.cap, x.allocator = y.len, y.len, allocator
		}
		return elements(op, &x.data, x.len, y.data, y.len, v.elem, allocator if op == .Copy else x.allocator)
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			at := uintptr(i * v.elem_size)
			if same = values(op, rawptr(uintptr(a) + at), rawptr(uintptr(b) + at), v.elem, allocator) or_return; !same {
				return
			}
		}
		return true, nil
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags {
			break
		}
		for i in 0 ..< int(v.field_count) {
			if same = values(op, rawptr(uintptr(a) + v.offsets[i]), rawptr(uintptr(b) + v.offsets[i]), v.types[i], allocator) or_return; !same {
				return
			}
		}
		return true, nil
	case runtime.Type_Info_Pointer:
		x, y := (^rawptr)(a), (^rawptr)(b)
		if op == .Equal && (x^ == y^ || x^ == nil || y^ == nil) {
			return x^ == y^, nil
		}
		return elements(op, x, 1 if x^ != nil else 0, y^, 1 if y^ != nil else 0, v.elem, allocator)
	case runtime.Type_Info_Union:
		return union_values(op, a, b, ti, v, allocator)
	case runtime.Type_Info_Map:
		return map_values(op, a, b, ti, v, allocator)
	}
	switch op {
	case .Copy:
		mem.copy(a, b, base.size)
	case .Equal:
		return mem.compare_ptrs(a, b, base.size) == 0, nil
	case .Free:
	}
	return true, nil
}

// `values` over the `n` elements at `x^` and the `m` at `y`, and for `.Copy` into new elements at `x^`, which `.Free`
// frees.
@(private)
elements :: proc(op: Values_Op, x: ^rawptr, n: int, y: rawptr, m: int, elem: ^runtime.Type_Info, allocator: runtime.Allocator) -> (same: bool, err: runtime.Allocator_Error) {
	switch op {
	case .Copy:
		if m == 0 || y == nil {
			return true, nil
		}
		data := runtime.mem_alloc(m * elem.size, elem.align, allocator) or_return
		x^ = raw_data(data)
	case .Equal:
		if n != m {
			return false, nil
		}
	case .Free:
	}
	for i in 0 ..< (m if op == .Copy else n) {
		at := uintptr(i * elem.size)
		if same = values(op, rawptr(uintptr(x^) + at), rawptr(uintptr(y) + at), elem, allocator) or_return; !same {
			return
		}
	}
	if op == .Free {
		runtime.mem_free(x^, allocator)
	}
	return true, nil
}

@(private)
union_values :: proc(op: Values_Op, a, b: rawptr, ti: ^runtime.Type_Info, v: runtime.Type_Info_Union, allocator: runtime.Allocator) -> (bool, runtime.Allocator_Error) {
	if reflect.type_info_union_is_pure_maybe(v) {
		return values(op, a, b, v.variants[0], allocator)
	}
	tag := reflect.get_union_variant_raw_tag(any{b if op == .Copy else a, ti.id})
	switch op {
	case .Copy:
		mem.copy(a, b, runtime.type_info_base(ti).size)
		// The bytes were copied, so the variant is cleared before it is copied whole.
		mem.zero(a, int(v.tag_offset))
	case .Equal:
		if tag != reflect.get_union_variant_raw_tag(any{b, ti.id}) {
			return false, nil
		}
	case .Free:
	}
	arm := tag if v.no_nil else tag - 1
	if arm < 0 {
		return true, nil
	}
	return values(op, a, b, v.variants[arm], allocator)
}

@(private)
map_values :: proc(op: Values_Op, a, b: rawptr, ti: ^runtime.Type_Info, v: runtime.Type_Info_Map, allocator: runtime.Allocator) -> (same: bool, err: runtime.Allocator_Error) {
	x, y := (^runtime.Raw_Map)(a), (^runtime.Raw_Map)(b)
	switch op {
	case .Copy:
		if y.len == 0 {
			return true, nil
		}
		if x.allocator.procedure == nil {
			x.allocator = allocator
		}
		key := runtime.mem_alloc(v.key.size, v.key.align, context.temp_allocator) or_return
		value := runtime.mem_alloc(v.value.size, v.value.align, context.temp_allocator) or_return
		it := 0
		for k, e in reflect.iterate_map(any{b, ti.id}, &it) {
			if held := map_entry(x, v, k.data); held != nil {
				values(.Free, held, held, v.value, x.allocator)
				mem.zero(held, v.value.size)
				values(.Copy, held, e.data, v.value, allocator) or_return
				continue
			}
			mem.zero(raw_data(key), len(key))
			mem.zero(raw_data(value), len(value))
			values(.Copy, raw_data(key), k.data, v.key, allocator) or_return
			values(.Copy, raw_data(value), e.data, v.value, allocator) or_return
			if _, failed := runtime.__dynamic_map_set_without_hash(x, v.map_info, raw_data(key), raw_data(value)); failed != nil {
				return false, .Out_Of_Memory
			}
		}
	case .Equal:
		if x.len != y.len {
			return false, nil
		}
		it := 0
		for k, e in reflect.iterate_map(any{a, ti.id}, &it) {
			found := map_entry(y, v, k.data)
			if found == nil || !(values(.Equal, e.data, found, v.value, allocator) or_return) {
				return false, nil
			}
		}
	case .Free:
		it := 0
		for k, e in reflect.iterate_map(any{a, ti.id}, &it) {
			values(.Free, k.data, k.data, v.key, x.allocator)
			values(.Free, e.data, e.data, v.value, x.allocator)
		}
		_ = runtime.map_free_dynamic(x^, v.map_info)
	}
	return true, nil
}

// The value of `key` in map `m`, nil when it holds none.
@(private)
map_entry :: proc(m: ^runtime.Raw_Map, v: runtime.Type_Info_Map, key: rawptr) -> rawptr {
	if m.len == 0 {
		return nil
	}
	return runtime.__dynamic_map_get(m, v.map_info, v.map_info.key_hasher(key, runtime.map_seed(m^)), key)
}

// Copies the value of type `ti` at `src` into `dst`, which holds the zero value, whole into `a`.
@(private)
copy_value :: proc(dst, src: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) -> runtime.Allocator_Error {
	_, err := values(.Copy, dst, src, ti, a)
	return err
}

@(private)
equal_values :: proc(a, b: rawptr, ti: ^runtime.Type_Info) -> bool {
	same, _ := values(.Equal, a, b, ti, {})
	return same
}

// Frees what the value of type `ti` at `v` holds into `a`, and leaves it the zero value.
@(private)
free_value :: proc(v: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) {
	values(.Free, v, v, ti, a)
	mem.zero(v, ti.size)
}
