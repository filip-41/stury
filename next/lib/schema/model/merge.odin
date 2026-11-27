// Deep transactional `patch` / `merge` with >128-field structs, budgets, and recursive `Maybe(struct)` patching.
package model

import "base:runtime"
import "core:mem"
import "stury:lib/core/tape"
import "stury:lib/schema/rules"

@(private)
Patch_Node :: struct { struct_idx: i32, present: Fields_Set, set_null, partial_maybe: bool, children: map[int]^Patch_Node }

@(private)
alloc_patch_child :: proc(parent: ^Patch_Node, fi: int, scratch: runtime.Allocator) -> ^Patch_Node {
	if parent.children == nil { m, merr := make(map[int]^Patch_Node, 4, scratch); if merr != nil { return nil }; parent.children = m }
	if existing, ok := parent.children[fi]; ok { return existing }
	child, err := new(Patch_Node, scratch); if err != nil { return nil }; child.struct_idx = -1
	if _, merr := map_insert(&parent.children, fi, child); merr != nil { return nil }
	return child
}

@(require_results)
patch :: proc(
	m: ^Model($T), existing: ^T, body: []u8, format: ^tape.Format, reads: ^tape.Reads,
	sink: ^Sink = nil, opts := Load_Opts{}, format_opts: tape.Format_Options = nil, allocator := context.allocator,
) -> Error {
	if format == nil || reads == nil || reads.build == nil || existing == nil { return Model_Error{kind = .Bad_Option, want = {text = "format"}} }
	policy, ok := resolve_dups(opts.dups, format); if !ok { return Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	sc: Scratch_Scope; sp := (^Scratch_Scope)(rawptr(&sc))
	scratch_begin(sp, opts, allocator); defer scratch_end(sp)
	doc, berr := reads.build(format, body, {budget = opts.budget, dups = policy, format = format_opts, scratch = sp.scratch}, sp.scratch)
	if berr != nil { return map_build_fault(berr, sink, allocator) }
	defer tape.destroy(&doc)
	return patch_document(m, existing, &doc, sink, opts, allocator)
}

@(require_results)
patch_document :: proc(m: ^Model($T), existing: ^T, doc: ^tape.Document, sink: ^Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> Error {
	if m == nil || doc == nil || existing == nil || len(doc.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "document"}} }
	if doc.partial != nil { return Model_Error{kind = .Unsupported, want = {text = "partial"}} }
	return patch_value(m, existing, rules.Node_Ref{doc, tape.ROOT}, sink, opts, allocator)
}

@(require_results)
patch_value :: proc(m: ^Model($T), existing: ^T, v: rules.Value, sink: ^Sink = nil, opts := Load_Opts{}, allocator := context.allocator) -> Error {
	if m == nil || existing == nil || len(m.plan.nodes) == 0 { return Model_Error{kind = .Bad_Option, want = {text = "target"}} }
	root_tn := &m.plan.nodes[m.plan.root]
	if root_tn.kind != .Struct || !m.plan.structs[root_tn.struct_idx].has_fields_set { return Model_Error{kind = .Bad_Option, want = {text = "Fields_Set"}} }
	fmt: ^tape.Format; if ref, is_ref := v.(rules.Node_Ref); is_ref && ref.doc != nil { fmt = ref.doc.format }
	policy, ok := resolve_dups(opts.dups, fmt); if !ok { return Model_Error{kind = .Bad_Option, want = {text = "dups"}} }
	sc: Scratch_Scope; sp := (^Scratch_Scope)(rawptr(&sc))
	scratch_begin(sp, opts, allocator); defer scratch_end(sp)
	from := len(sink.entries) if sink != nil else 0
	l, lerr := loader_make(&m.plan, m.judging, policy, opts.budget, sink, sp.out, sp.scratch, validators = opts.validators)
	if lerr != nil { return scratch_oom_error(sp) }
	defer loader_cleanup(&l)

	root_patch := Patch_Node{struct_idx = root_tn.struct_idx}; changes: T
	decode_loop(&l, m.plan.root, v, rawptr(&changes), rawptr(existing), &root_patch)
	if sink != nil { order_sink(sink, from) }
	err := loader_result_err(&l, sp)
	if err == nil {
		if jerr := merge_struct(.Prepare, &m.plan, &root_patch, uintptr(existing), uintptr(&changes), sp.out, sp.scratch); jerr != nil {
			err = scratch_oom_error(sp) if opts.budget.memory > 0 else Error(jerr)
		}
	}
	merged := existing^
	if err == nil {
		_ = merge_struct(.Move, &m.plan, &root_patch, uintptr(&merged), uintptr(&changes), sp.out, sp.scratch)
		err = validate_inner(&m.plan, m.judging, rawptr(&merged), sink, opts, nil, sp.out)
	}
	if err != nil { free_value(&changes, type_info_of(T), sp.out); return err }
	_ = merge_struct(.Free_Old, &m.plan, &root_patch, uintptr(existing), uintptr(&changes), sp.out, sp.scratch)
	existing^ = merged
	return nil
}

@(private)
Merge_Step :: enum u8 { Prepare, Move, Free_Old }

@(private)
merge_struct :: proc(step: Merge_Step, plan: ^Type_Plan, pn: ^Patch_Node, dst, src: uintptr, a, scratch: runtime.Allocator) -> runtime.Allocator_Error {
	if pn == nil || pn.struct_idx < 0 { return nil }
	si := &plan.structs[pn.struct_idx]
	for f, fi in si.fields {
		if !fields_set_has(pn.present, fi) { continue }
		at, ftn := f.offset, &plan.nodes[f.node]
		child_pn := pn.children[fi] if pn.children != nil else nil
		if child_pn != nil && (ftn.kind == .Struct || (ftn.kind == .Maybe && child_pn.partial_maybe)) {
			merge_struct(step, plan, child_pn, dst + at, src + at, a, scratch) or_return
		} else if step == .Move {
			if child_pn != nil && ftn.kind == .Maybe && child_pn.set_null { mem.zero(rawptr(dst + at), ftn.size) } else { mem.copy(rawptr(dst + at), rawptr(src + at), ftn.size) }
		} else if step == .Free_Old { free_value(rawptr(dst + at), ftn.ti, a) }
	}
	if si.has_fields_set {
		dst_set, src_set := (^Fields_Set)(dst + si.fields_set_offset), (^Fields_Set)(src + si.fields_set_offset)
		switch step {
		case .Prepare:
			if max_w := max(len(dst_set.wide), len(src_set.wide)); max_w > 0 {
				combined := make([]u64, max_w, a) or_return
				for w, i in dst_set.wide { combined[i] |= w }
				for w, i in src_set.wide { combined[i] |= w }
				if len(src_set.wide) > 0 { delete(src_set.wide, a) }
				src_set.wide = combined
			}
		case .Move:     dst_set.bits[0] |= src_set.bits[0]; dst_set.bits[1] |= src_set.bits[1]; if len(src_set.wide) > 0 { dst_set.wide = src_set.wide }
		case .Free_Old: if len(src_set.wide) > 0 && len(dst_set.wide) > 0 && raw_data(dst_set.wide) != raw_data(src_set.wide) { delete(dst_set.wide, a) }
		}
	}
	if si.capture_idx >= 0 {
		cap_tn := &plan.nodes[si.capture_node]
		src_map, dst_map := rawptr(src + si.capture_offset), rawptr(dst + si.capture_offset)
		if (^runtime.Raw_Map)(src_map).len > 0 {
			switch step {
			case .Prepare:
				joined: runtime.Raw_Map
				_, err := values(.Copy, &joined, dst_map, cap_tn.ti, a, scratch)
				if err == nil { _, err = values(.Copy, &joined, src_map, cap_tn.ti, a, scratch) }
				if err != nil { free_value(&joined, cap_tn.ti, a); return err }
				free_value(src_map, cap_tn.ti, a); (^runtime.Raw_Map)(src_map)^ = joined
			case .Move:     mem.copy(dst_map, src_map, cap_tn.size)
			case .Free_Old: free_value(dst_map, cap_tn.ti, a)
			}
		}
	}
	return nil
}