package model

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:strings"
import core ".."
import typed "../typed"

// Reads `src` into `v` by the model's rules, and reports every rule a value fails, not only the first. `v` is zeroed
// first, so a member the text leaves out holds its default or its zero. A read_only member is neither read nor judged,
// and a write_only one is read. A key the struct does not name is skipped unless the struct forbids it, and a key the
// text repeats anywhere, inside a skipped value too, ends the load as `.Duplicate_Key` unless `dups` says which one
// wins. Strings and the other values the text builds are allocated with `allocator`. Every refusal goes to `sink` as a
// `core.Error_Entry` with its path, up to the sink's limit, and with no sink the first ends the read. Returns the first.
load :: proc(m: ^Model($T), src: []u8, v: ^T, sink: ^typed.Sink = nil, dups := core.Duplicates.Refuse, allocator := context.allocator) -> core.Error {
	// A zero `dups` is the read's default, which a load takes as a refusal.
	read := typed.Read_Options{dups = .Refuse if dups == .Default else dups, sink = sink}
	return typed.check_text(src, v, T, &m.load_plan, read, allocator)
}

// Whether the load that filled `set`, a member of a struct of type `S` in `T`, read the member the text names `name`,
// its alias when it has one. A read_only member is never read.
was_set :: proc(m: ^Model($T), $S: typeid, set: Fields_Set, name: string) -> bool {
	for x in m.load_plan.meta {
		if x.type != S || x.members == 0 || x.list {
			continue
		}
		for i in 0 ..< x.members {
			if m.load_plan.meta[x.block + i].name == name {
				return set.bits[i / 64] >> uint(i % 64) & 1 != 0
			}
		}
		return false
	}
	return false
}

// Copies the value of type `ti` at `src` to `dst`, which holds the zero value. Strings, slices, dynamic arrays, maps,
// pointers and unions are copied whole into `a`, and everything else as bytes.
@(private)
clone :: proc(dst, src: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) -> runtime.Allocator_Error {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		if v.is_cstring {
			if c := (^cstring)(src)^; c != nil {
				(^cstring)(dst)^ = strings.clone_to_cstring(string(c), a) or_return
			}
		} else {
			(^string)(dst)^ = strings.clone((^string)(src)^, a) or_return
		}
	case runtime.Type_Info_Slice:
		s := (^runtime.Raw_Slice)(src)^
		(^runtime.Raw_Slice)(dst)^ = {clone_elements(s.data, s.len, v.elem, a) or_return, s.len}
	case runtime.Type_Info_Dynamic_Array:
		s := (^runtime.Raw_Dynamic_Array)(src)^
		(^runtime.Raw_Dynamic_Array)(dst)^ = {clone_elements(s.data, s.len, v.elem, a) or_return, s.len, s.len, a}
	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			clone(rawptr(uintptr(dst) + uintptr(i * v.elem_size)), rawptr(uintptr(src) + uintptr(i * v.elem_size)), v.elem, a) or_return
		}
	case runtime.Type_Info_Struct:
		if .raw_union in v.flags {
			mem.copy(dst, src, base.size)
			break
		}
		for i in 0 ..< int(v.field_count) {
			clone(rawptr(uintptr(dst) + v.offsets[i]), rawptr(uintptr(src) + v.offsets[i]), v.types[i], a) or_return
		}
	case runtime.Type_Info_Pointer:
		if p := (^rawptr)(src)^; p != nil {
			(^rawptr)(dst)^ = clone_elements(p, 1, v.elem, a) or_return
		}
	case runtime.Type_Info_Union:
		clone_union(dst, src, base, v, a) or_return
	case runtime.Type_Info_Map:
		clone_map(dst, src, ti, v, a) or_return
	case:
		mem.copy(dst, src, base.size)
	}
	return nil
}

@(private)
clone_elements :: proc(src: rawptr, n: int, elem: ^runtime.Type_Info, a: runtime.Allocator) -> (out: rawptr, err: runtime.Allocator_Error) {
	if n == 0 || src == nil {
		return nil, nil
	}
	data := runtime.mem_alloc(n * elem.size, elem.align, a) or_return
	for i in 0 ..< n {
		clone(rawptr(uintptr(raw_data(data)) + uintptr(i * elem.size)), rawptr(uintptr(src) + uintptr(i * elem.size)), elem, a) or_return
	}
	return raw_data(data), nil
}

@(private)
clone_union :: proc(dst, src: rawptr, base: ^runtime.Type_Info, v: runtime.Type_Info_Union, a: runtime.Allocator) -> runtime.Allocator_Error {
	if v.shared_nil {
		return clone(dst, src, v.variants[0], a)
	}
	mem.copy(dst, src, base.size)
	tag: u64
	mem.copy(&tag, rawptr(uintptr(src) + v.tag_offset), v.tag_type.size)
	if !v.no_nil {
		tag -= 1
		if tag == max(u64) {
			return nil
		}
	}
	// The bytes were copied, so the variant is cleared before it is copied whole.
	mem.zero(dst, int(v.tag_offset))
	return clone(dst, src, v.variants[tag], a)
}

@(private)
clone_map :: proc(dst, src: rawptr, ti: ^runtime.Type_Info, v: runtime.Type_Info_Map, a: runtime.Allocator) -> runtime.Allocator_Error {
	from := (^runtime.Raw_Map)(src)
	if from.len == 0 {
		return nil
	}
	to := (^runtime.Raw_Map)(dst)
	to.allocator = a
	key := runtime.mem_alloc(v.key.size, v.key.align, context.temp_allocator) or_return
	value := runtime.mem_alloc(v.value.size, v.value.align, context.temp_allocator) or_return
	it := 0
	for k, x in reflect.iterate_map(any{src, ti.id}, &it) {
		mem.zero(raw_data(key), len(key))
		mem.zero(raw_data(value), len(value))
		clone(raw_data(key), k.data, v.key, a) or_return
		clone(raw_data(value), x.data, v.value, a) or_return
		if _, err := runtime.__dynamic_map_set_without_hash(to, v.map_info, raw_data(key), raw_data(value)); err != nil {
			return .Out_Of_Memory
		}
	}
	return nil
}
