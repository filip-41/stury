package model

import "base:runtime"
import "core:mem"
import core ".."
import typed "../typed"

// Applies the patch `body`, a text of the model's format, to `existing`. Each member's rules judge the patch as a load
// judges a text, in the structs a patch descends into: the root and its struct members whose structs hold a
// `Fields_Set`. There a member the text leaves out is neither required nor defaulted, and it keeps what `existing` holds.
// Any other member the text holds, a list, a map and a struct without a set among them, replaces `existing`'s whole and
// is read in full. The members a struct's `extra` map captured join `existing`'s, replacing those of the same keys, and
// `existing`'s sets then hold their members and the patch's. Struct validators and applicators judge the merged value,
// as `validate` judges it. What the patch reads is allocated with `allocator`, and the merged value holds it. `existing`
// is written only when nothing failed, and then what it held in the members and entries the patch replaced is freed into
// `allocator`, a dynamic array's and a map's into their own, so `existing`'s memory is from `allocator`. A failure frees
// what the patch read and leaves `existing` as it was. Every failure goes to `sink` as a load's does, at its path in the
// patch, and the first is returned. `T` without a `Fields_Set` is `.Bad_Option`.
patch :: proc(m: ^Model($T), existing: ^T, body: []u8, sink: ^typed.Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> core.Error {
	root := &m.load_plan.fields[0]
	if !has_set(&m.load_plan, root) {
		return core.error_of(core.Typed_Refusal{kind = .Bad_Option})
	}
	read := read_options(&m.load_plan, opts, sink)
	read.partial = true
	changes: T
	err := typed.check_text(body, &changes, T, &m.load_plan, read, allocator)
	if err == nil && merge_struct(.Join, &m.load_plan, root, uintptr(existing), uintptr(&changes), allocator) != nil {
		err = core.error_of(core.Typed_Refusal{kind = .No_Memory})
	}
	merged := existing^
	if err == nil {
		merge_struct(.Move, &m.load_plan, root, uintptr(&merged), uintptr(&changes), allocator)
		err = validate_value(&m.plan, &merged, sink, m.judging)
	}
	if err != nil {
		free_value(&changes, type_info_of(T), allocator)
		return err
	}
	merge_struct(.Free, &m.load_plan, root, uintptr(existing), uintptr(&changes), allocator)
	existing^ = merged
	return nil
}

// Whether the struct of record `f` in `plan` has a `Fields_Set`. A judged struct's record is the one its `.Before` keeps.
@(private)
has_set :: proc(plan: ^typed.Plan, f: ^typed.Field) -> bool {
	m := &plan.meta[f.meta]
	kind := typed.extra_at(plan, f.meta).before.field.kind if f.kind == .Before else f.kind
	return (kind == .Struct || kind == .Required) && m.model != nil && m.model.fields_set != 0
}

// What `merge_struct` does with a member of the patch's struct at `src` that its `Fields_Set` holds, and a map that
// struct's `extra` captured, and the member at `dst`.
@(private)
Merge_Step :: enum u8 {
	Join, // makes `src`'s captured map a new map from the allocator with `dst`'s entries and then `src`'s
	Move, // moves `src`'s member and captured map into `dst`, and `dst`'s set then holds `src`'s members
	Free, // frees `dst`'s member and captured map into the allocator
}

// Does `step` with each member of the struct of record `f` at `src` that its `Fields_Set` holds and its captured map
// when it holds entries, member by member into a struct member whose struct has a set.
@(private)
merge_struct :: proc(step: Merge_Step, plan: ^typed.Plan, f: ^typed.Field, dst, src: uintptr, a: runtime.Allocator) -> runtime.Allocator_Error {
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
			merge_struct(step, plan, r, dst + at, src + at, a) or_return
		} else if step != .Join {
			member(step, rawptr(dst + at), rawptr(src + at), type_info_of(plan.meta[m.block + i].type), a)
		}
	}
	if step == .Move {
		into.bits |= from.bits
	}
	if end.capture < 0 {
		return nil
	}
	r := &plan.fields[end.capture]
	ti := type_info_of(plan.meta[r.meta].type)
	held := rawptr(src + uintptr(r.offset))
	if (^runtime.Raw_Map)(held).len == 0 {
		return nil
	}
	if step != .Join {
		member(step, rawptr(dst + uintptr(r.offset)), held, ti, a)
		return nil
	}
	joined: runtime.Raw_Map
	_, err := values(.Copy, &joined, rawptr(dst + uintptr(r.offset)), ti, a)
	if err == nil {
		_, err = values(.Copy, &joined, held, ti, a)
	}
	if err != nil {
		free_value(&joined, ti, a)
		return err
	}
	free_value(held, ti, a)
	(^runtime.Raw_Map)(held)^ = joined
	return nil
}

@(private)
member :: proc(step: Merge_Step, dst, src: rawptr, ti: ^runtime.Type_Info, a: runtime.Allocator) {
	if step == .Move {
		mem.copy(dst, src, ti.size)
	} else {
		free_value(dst, ti, a)
	}
}
