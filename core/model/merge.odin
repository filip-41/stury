package model

import "base:runtime"
import "core:mem"
import "core:reflect"
import core ".."
import typed "../typed"

// Applies the patch `body`, a text of the model's format, to `existing`. Each member's rules judge the patch as a load
// judges a text, in the structs a patch descends into: the root and its struct members whose structs hold a
// `Fields_Set`. There a member the text leaves out is neither required nor defaulted, and it keeps what `existing` holds.
// Any other member the text holds, a list, a map and a struct without a set among them, replaces `existing`'s whole and
// is read in full. The members a struct's `extra` map captured join `existing`'s, replacing those of the same keys, and
// `existing`'s sets then hold their members and the patch's. Struct validators and applicators judge the merged value,
// as `validate` judges it. `existing` is written only when nothing failed, and its own memory is left as it was. What
// the patch reads is allocated with `allocator`, and the merged value holds it. Every failure goes to `sink` as a load's
// does, at its path in the patch, and the first is returned. `T` without a `Fields_Set` is `.Bad_Option`.
patch :: proc(m: ^Model($T), existing: ^T, body: []u8, sink: ^typed.Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> core.Error {
	root := &m.load_plan.fields[0]
	if !has_set(&m.load_plan, root) {
		return core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	read := read_options(opts, sink)
	read.partial = true
	changes: T
	typed.check_text(body, &changes, T, &m.load_plan, read, allocator) or_return
	merged := existing^
	merge_struct(&m.load_plan, root, uintptr(&merged), uintptr(&changes), allocator) or_return
	validate_value(&m.plan, &merged, sink, m.judging) or_return
	existing^ = merged
	return nil
}

// Whether the struct of record `f` in `plan` has a `Fields_Set`. A judged struct's record is the one its `.Before` keeps.
@(private)
has_set :: proc(plan: ^typed.Plan, f: ^typed.Field) -> bool {
	m := &plan.meta[f.meta]
	kind := m.before.field.kind if f.kind == .Before else f.kind
	return (kind == .Struct || kind == .Required) && m.model != nil && m.model.fields_set != 0
}

// Moves each member of the struct at `src` that its `Fields_Set` holds into the struct at `dst`, member by member into a
// struct member whose struct has a set. A captured map is a new map from `a` with `dst`'s entries and then `src`'s, so
// the map `dst` held is not written.
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
		if has_set(plan, r) {
			merge_struct(plan, r, dst + at, src + at, a) or_return
			continue
		}
		mem.copy(rawptr(dst + at), rawptr(src + at), type_info_of(plan.meta[m.block + i].type).size)
	}
	if end.capture >= 0 {
		r := &plan.fields[end.capture]
		ti := type_info_of(plan.meta[r.meta].type)
		info := runtime.type_info_base(ti).variant.(runtime.Type_Info_Map)
		held := (^runtime.Raw_Map)(dst + uintptr(r.offset))
		old := held^
		held^ = {}
		join_map(held, &old, ti, info, a) or_return
		join_map(held, (^runtime.Raw_Map)(src + uintptr(r.offset)), ti, info, a) or_return
	}
	into.bits |= from.bits
	return nil
}

// Inserts the entries of map `from` into map `to`, whose entries they share, `to` taking `a` when it has no allocator.
@(private)
join_map :: proc(to, from: ^runtime.Raw_Map, ti: ^runtime.Type_Info, v: runtime.Type_Info_Map, a: runtime.Allocator) -> core.Error {
	if to.allocator.procedure == nil {
		to.allocator = a
	}
	it := 0
	for k, x in reflect.iterate_map(any{from, ti.id}, &it) {
		if _, err := runtime.__dynamic_map_set_without_hash(to, v.map_info, k.data, x.data); err != nil {
			return core.error_of(core.Typed_Refusal{kind = .No_Memory})
		}
	}
	return nil
}
