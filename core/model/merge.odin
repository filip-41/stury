package model

import "base:runtime"
import "core:mem"
import core ".."
import typed "../typed"

// Merges `patch`, as a partial load reads it, into `existing`: each member the patch's `Fields_Set` holds replaces the
// one in `existing`, with a copy from `allocator`, so `existing` holds nothing of the patch's memory. A struct member whose
// own struct has a `Fields_Set` is merged member by member, and any other member, a list and a map among them, is
// replaced whole. The members a struct's `extra` map captured join `existing`'s, replacing those of the same keys.
// `existing`'s sets then hold their members and the patch's. What a replaced member held is left to `existing`'s memory.
// `T` without a `Fields_Set` is `.Bad_Option`.
merge :: proc(m: ^Model($T), existing, patch: ^T, allocator := context.allocator) -> core.Error {
	root := &m.load_plan.fields[0]
	if model_of(&m.load_plan, root) == nil {
		return core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	if existing == patch {
		return nil
	}
	return merge_struct(&m.load_plan, root, uintptr(existing), uintptr(patch), allocator)
}

// The model of the struct of record `f` in `plan` when it has a `Fields_Set`, nil otherwise.
@(private)
model_of :: proc(plan: ^typed.Plan, f: ^typed.Field) -> ^typed.Struct_Model {
	sm := plan.meta[f.meta].model
	return sm if (f.kind == .Struct || f.kind == .Required) && sm != nil && sm.fields_set != 0 else nil
}

@(private)
merge_struct :: proc(plan: ^typed.Plan, f: ^typed.Field, dst, src: uintptr, a: runtime.Allocator) -> core.Error {
	m := &plan.meta[f.meta]
	end := &plan.meta[m.block + m.members]
	sm := end.model
	into := (^Fields_Set)(dst + uintptr(sm.fields_set - 1))
	from := (^Fields_Set)(src + uintptr(sm.fields_set - 1))
	for i in 0 ..< m.members {
		if from.bits[i / 64] >> uint(i % 64) & 1 == 0 {
			continue
		}
		r := &plan.fields[m.block + i]
		at := uintptr(r.offset)
		if model_of(plan, r) != nil {
			merge_struct(plan, r, dst + at, src + at, a) or_return
			continue
		}
		ti := type_info_of(plan.meta[m.block + i].type)
		mem.zero(rawptr(dst + at), ti.size)
		clone(rawptr(dst + at), rawptr(src + at), ti, a) or_return
	}
	if end.capture >= 0 {
		r := &plan.fields[end.capture]
		ti := type_info_of(plan.meta[r.meta].type)
		clone_map(rawptr(dst + uintptr(r.offset)), rawptr(src + uintptr(r.offset)), ti, runtime.type_info_base(ti).variant.(runtime.Type_Info_Map), a) or_return
	}
	into.bits |= from.bits
	return nil
}
