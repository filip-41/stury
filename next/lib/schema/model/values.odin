// Deep copy, structural equality, and iterative free over arbitrary Odin values (O(1) native stack).
package model

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"

@(private)
Values_Op :: enum u8 { Copy, Equal, Free }

@(private)
Copy_Frame_Kind :: enum u8 { Value, Free_Block, Free_Map, Copy_Map_Insert }

@(private)
Copy_Frame :: struct {
	kind:            Copy_Frame_Kind,
	a, b:            rawptr,
	ti:              ^runtime.Type_Info,
	alloc:           runtime.Allocator,
	map_info:        ^runtime.Map_Info,
	key_ti, val_ti:  ^runtime.Type_Info,
	key_buf, val_buf: rawptr,
}

@(private)
values :: proc(op: Values_Op, a, b: rawptr, ti: ^runtime.Type_Info, allocator: runtime.Allocator, scratch := context.allocator) -> (same: bool, err: runtime.Allocator_Error) {
	scr := scratch if scratch.procedure != nil else (allocator if allocator.procedure != nil else context.allocator)
	stack := make([dynamic]Copy_Frame, 0, 16, scr)
	defer {
		for f in stack {
			if f.kind == .Copy_Map_Insert {
				if f.key_buf != nil { runtime.mem_free(f.key_buf, scr) }
				if f.val_buf != nil { runtime.mem_free(f.val_buf, scr) }
			}
		}
		delete(stack)
	}
	append(&stack, Copy_Frame{kind = .Value, a = a, b = b, ti = ti, alloc = allocator}) or_return

	for len(stack) > 0 {
		f := pop(&stack)
		switch f.kind {
		case .Free_Block:
			if f.a != nil { runtime.mem_free(f.a, f.alloc) }
			continue
		case .Free_Map:
			_ = runtime.map_free_dynamic((^runtime.Raw_Map)(f.a)^, f.map_info)
			continue
		case .Copy_Map_Insert:
			_, failed := runtime.__dynamic_map_set_without_hash((^runtime.Raw_Map)(f.a), f.map_info, f.key_buf, f.val_buf)
			if failed != nil {
				free_value(f.key_buf, f.key_ti, f.alloc); free_value(f.val_buf, f.val_ti, f.alloc)
				runtime.mem_free(f.key_buf, scr); runtime.mem_free(f.val_buf, scr)
				return false, .Out_Of_Memory
			}
			runtime.mem_free(f.key_buf, scr); runtime.mem_free(f.val_buf, scr)
			continue
		case .Value:
		}

		base := runtime.type_info_base(f.ti)
		#partial switch v in base.variant {
		case ^runtime.Type_Info_String:
			if v.is_cstring {
				x, y := (^cstring)(f.a), (^cstring)(f.b)
				switch op {
				case .Copy:  if y^ != nil { x^ = strings.clone_to_cstring(string(y^), f.alloc) or_return }
				case .Equal: if string(x^) != string(y^) || (x^ == nil) != (y^ == nil) { return false, nil }
				case .Free:  if x^ != nil { delete(x^, f.alloc) }
				}
			} else {
				x, y := (^string)(f.a), (^string)(f.b)
				switch op {
				case .Copy:  x^ = strings.clone(y^, f.alloc) or_return if len(y^) > 0 else ""
				case .Equal: if x^ != y^ { return false, nil }
				case .Free:  if len(x^) > 0 { delete(x^, f.alloc) }
				}
			}
			continue
		case ^runtime.Type_Info_Slice:
			x, y := (^runtime.Raw_Slice)(f.a), (^runtime.Raw_Slice)(f.b)
			if op == .Copy { x.len = y.len }
			if !(push_elements(&stack, op, &x.data, x.len, y.data, y.len, v.elem, f.alloc) or_return) { return false, nil }
			continue
		case ^runtime.Type_Info_Dynamic_Array:
			x, y := (^runtime.Raw_Dynamic_Array)(f.a), (^runtime.Raw_Dynamic_Array)(f.b)
			if op == .Copy { x.len, x.cap, x.allocator = y.len, y.len, f.alloc }
			el_alloc := f.alloc if op == .Copy else (x.allocator if x.allocator.procedure != nil else f.alloc)
			if !(push_elements(&stack, op, &x.data, x.len, y.data, y.len, v.elem, el_alloc) or_return) { return false, nil }
			continue
		case ^runtime.Type_Info_Array:
			for i := v.count - 1; i >= 0; i -= 1 {
				at := uintptr(i * v.elem_size)
				append(&stack, Copy_Frame{kind = .Value, a = rawptr(uintptr(f.a) + at), b = rawptr(uintptr(f.b) + at), ti = v.elem, alloc = f.alloc}) or_return
			}
			continue
		case ^runtime.Type_Info_Struct:
			if .raw_union in v.flags { break }
			for i := int(v.field_count) - 1; i >= 0; i -= 1 {
				append(&stack, Copy_Frame{kind = .Value, a = rawptr(uintptr(f.a) + v.offsets[i]), b = rawptr(uintptr(f.b) + v.offsets[i]), ti = v.types[i], alloc = f.alloc}) or_return
			}
			continue
		case ^runtime.Type_Info_Pointer:
			x, y := (^rawptr)(f.a), (^rawptr)(f.b)
			if op == .Equal && (x^ == y^ || x^ == nil || y^ == nil) { if x^ != y^ { return false, nil }; continue }
			if v.elem == nil {
				if op == .Copy { x^ = y^ } else if op == .Equal && x^ != y^ { return false, nil }
				continue
			}
			if !(push_elements(&stack, op, x, 1 if x^ != nil else 0, y^, 1 if y^ != nil else 0, v.elem, f.alloc) or_return) { return false, nil }
			continue
		case ^runtime.Type_Info_Union:
			if reflect.type_info_union_is_pure_maybe(v^) {
				append(&stack, Copy_Frame{kind = .Value, a = f.a, b = f.b, ti = v.variants[0], alloc = f.alloc}) or_return
				continue
			}
			tag := reflect.get_union_variant_raw_tag(any{f.b if op == .Copy else f.a, f.ti.id})
			if op == .Copy { mem.copy(f.a, f.b, base.size); mem.zero(f.a, int(v.tag_offset)) } else if op == .Equal && tag != reflect.get_union_variant_raw_tag(any{f.b, f.ti.id}) { return false, nil }
			if arm := tag if v.no_nil else tag - 1; arm >= 0 && int(arm) < len(v.variants) {
				append(&stack, Copy_Frame{kind = .Value, a = f.a, b = f.b, ti = v.variants[arm], alloc = f.alloc}) or_return
			}
			continue
		case ^runtime.Type_Info_Map:
			x, y := (^runtime.Raw_Map)(f.a), (^runtime.Raw_Map)(f.b)
			switch op {
			case .Copy:
				if y.len == 0 { continue }
				if x.allocator.procedure == nil { x.allocator = f.alloc }
				it := 0
				for k, e in reflect.iterate_map(any{f.b, f.ti.id}, &it) {
					if held := map_entry(x, v^, k.data); held != nil {
						free_value(held, v.value, x.allocator)
						append(&stack, Copy_Frame{kind = .Value, a = held, b = e.data, ti = v.value, alloc = f.alloc}) or_return
						continue
					}
					kbuf := runtime.mem_alloc(max(v.key.size, 1), v.key.align, scr) or_return
					vbuf, verr := runtime.mem_alloc(max(v.value.size, 1), v.value.align, scr)
					if verr != nil { runtime.mem_free(raw_data(kbuf), scr); return false, verr }
					append(&stack, Copy_Frame{kind = .Copy_Map_Insert, a = f.a, alloc = f.alloc, map_info = v.map_info, key_ti = v.key, val_ti = v.value, key_buf = raw_data(kbuf), val_buf = raw_data(vbuf)}) or_return
					append(&stack, Copy_Frame{kind = .Value, a = raw_data(vbuf), b = e.data, ti = v.value, alloc = f.alloc}) or_return
					append(&stack, Copy_Frame{kind = .Value, a = raw_data(kbuf), b = k.data, ti = v.key, alloc = f.alloc}) or_return
				}
			case .Equal:
				if x.len != y.len { return false, nil }
				it := 0
				for k, e in reflect.iterate_map(any{f.a, f.ti.id}, &it) {
					found := map_entry(y, v^, k.data)
					if found == nil { return false, nil }
					append(&stack, Copy_Frame{kind = .Value, a = e.data, b = found, ti = v.value, alloc = f.alloc}) or_return
				}
			case .Free:
				if x.len > 0 || x.data != 0 {
					m_alloc := x.allocator if x.allocator.procedure != nil else f.alloc
					append(&stack, Copy_Frame{kind = .Free_Map, a = f.a, map_info = v.map_info, alloc = m_alloc}) or_return
					it := 0
					for k, e in reflect.iterate_map(any{f.a, f.ti.id}, &it) {
						append(&stack, Copy_Frame{kind = .Value, a = e.data, b = e.data, ti = v.value, alloc = m_alloc}) or_return
						append(&stack, Copy_Frame{kind = .Value, a = k.data, b = k.data, ti = v.key, alloc = m_alloc}) or_return
					}
				}
			}
			continue
		}
		if op == .Copy { mem.copy(f.a, f.b, base.size) } else if op == .Equal && mem.compare_ptrs(f.a, f.b, base.size) != 0 { return false, nil }
	}
	return true, nil
}

@(private)
push_elements :: proc(stack: ^[dynamic]Copy_Frame, op: Values_Op, x: ^rawptr, n: int, y: rawptr, m: int, elem: ^runtime.Type_Info, allocator: runtime.Allocator) -> (ok: bool, err: runtime.Allocator_Error) {
	switch op {
	case .Copy:
		if m == 0 || y == nil { x^ = nil; return true, nil }
		data := runtime.mem_alloc(m * max(elem.size, 1), elem.align, allocator) or_return
		x^ = raw_data(data)
	case .Equal:
		if n != m { return false, nil }
	case .Free:
		if x^ != nil { append(stack, Copy_Frame{kind = .Free_Block, a = x^, alloc = allocator}) or_return }
	}
	base_x := x^
	if op == .Free { x^ = nil }
	for i := (m if op == .Copy else n) - 1; i >= 0; i -= 1 {
		at := uintptr(i * elem.size)
		append(stack, Copy_Frame{kind = .Value, a = rawptr(uintptr(base_x) + at), b = rawptr(uintptr(y) + at), ti = elem, alloc = allocator}) or_return
	}
	return true, nil
}

@(private)
map_entry :: proc(m: ^runtime.Raw_Map, v: runtime.Type_Info_Map, key: rawptr) -> rawptr {
	return runtime.__dynamic_map_get(m, v.map_info, v.map_info.key_hasher(key, runtime.map_seed(m^)), key) if m.len > 0 else nil
}

@(private)
copy_value :: proc(dst, src: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator, scratch := context.allocator) -> runtime.Allocator_Error {
	_, err := values(.Copy, dst, src, ti, a, scratch)
	return err
}

@(private)
equal_values :: proc(a, b: rawptr, ti: ^runtime.Type_Info, scratch := context.allocator) -> bool {
	same, _ := values(.Equal, a, b, ti, {}, scratch)
	return same
}

free_value :: proc(v: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) {
	if v == nil || ti == nil { return }
	values(.Free, v, v, ti, a, a)
	mem.zero(v, ti.size)
}
