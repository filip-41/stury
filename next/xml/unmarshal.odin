package xml

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Iterative zero-recursion typed XML unmarshaler (WASM32-clean, zero `context.temp_allocator`,
// OOM-safe rollback, full `Budget` and `Options.scratch` support). Struct fields honor `xml:"..."`
// tags first, then `stury:"..."`. Supports child elements, attributes, `#text`/`$text` content,
// and repeated sibling elements mapped to slices/arrays in document order.

Unmarshal_Options :: typed.Unmarshal_Options
Raw :: typed.Raw
Typed_Refusal :: typed.Typed_Refusal

// Reads `src`, an XML text of `spec`, into `target`. Absent fields keep destination defaults.
@(require_results)
unmarshal :: proc(src: []u8, target: ^$T, spec := Spec.Xml, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_into(src, target, T, spec, read, opts, allocator)
}

@(private)
unmarshal_into :: proc(src: []u8, target: rawptr, T: typeid, spec: Spec, read: Unmarshal_Options, opts: Options, caller: runtime.Allocator) -> tape.Error {
	if read.path != nil {
		clear(read.path)
		if read.path.allocator.procedure == nil { read.path.allocator = caller }
	}
	if spec > max(Spec) { return tape.Bad_Option{"spec"} }
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil { return e }
	if target == nil { return tape.Bad_Option{"target"} }
	if opts.pieces != nil { return tape.Bad_Option{"pieces"} }
	if read.plan != nil && (read.plan.type != T || read.plan.tag != TAG) { return tape.Bad_Option{"plan"} }

	rb_buf: [size_of(hook.Read_Budget) / size_of(u64)]u64
	#assert(size_of(rb_buf) == size_of(hook.Read_Budget) && align_of(hook.Read_Budget) <= align_of(u64))
	rb := (^hook.Read_Budget)(rawptr(&rb_buf[0]))
	sc_buf: [size_of(hook.Memory_Budget) / size_of(u64)]u64
	#assert(size_of(sc_buf) == size_of(hook.Memory_Budget) && align_of(hook.Memory_Budget) <= align_of(u64))
	local_sc := (^hook.Memory_Budget)(rawptr(&sc_buf[0]))

	alloc := caller
	scratch_alloc: runtime.Allocator
	if opts.budget.memory == 0 {
		scratch_alloc = hook.scratch(opts, caller, local_sc)
	} else {
		alloc = hook.read_budget(rb, opts, caller)
		scratch_alloc = hook.scratch(opts, alloc, local_sc)
	}

	build_opts := opts
	build_opts.scratch = scratch_alloc
	if build_opts.dups == .Refuse { build_opts.dups = .Group }
	doc, err := build(src, spec, build_opts, scratch_alloc)
	if err != nil { return hook.memory_budget_error(&rb.main, err) if opts.budget.memory != 0 else err }
	defer tape.destroy(&doc)
	if len(doc.nodes) == 0 { return nil }

	err = unmarshal_root(&doc, target, T, read, opts, caller, alloc, scratch_alloc)
	return hook.memory_budget_error(&rb.main, err) if err != nil && opts.budget.memory != 0 else err
}

@(private)
Path_Node :: struct { parent: int, step: tape.Step }
@(private)
Trial_Block :: struct { ptr: rawptr, size, align: int }
@(private)
Deferred_Free :: struct { ptr: rawptr, size: int, alloc: runtime.Allocator }
@(private)
Trial_Alloc :: struct { backing: runtime.Allocator, blocks: [dynamic]Trial_Block }

@(private)
Union_Trial :: struct {
	val_node:                                            tape.Node_Index,
	group_lo, group_hi:                                  u32,
	dst:                                                 rawptr,
	ti:                                                  ^runtime.Type_Info_Union,
	ti_size, path_idx, stack_base, next_var, path_len, pool_len: int,
	work:                                                []u8,
	alloc:                                               ^Trial_Alloc,
	in_group:                                            bool,
}

@(private)
Unmarshal_Cx :: struct {
	doc:            ^tape.Document,
	read:           Unmarshal_Options,
	opts:           Options,
	caller:         runtime.Allocator,
	alloc:          runtime.Allocator,
	tmp:            runtime.Allocator,
	buf:            [dynamic]u8,
	group_pool:     [dynamic]tape.Node_Index,
	path_nodes:     [dynamic]Path_Node,
	trials:         [dynamic]Union_Trial,
	root_alloc:     Trial_Alloc,
	deferred_frees: [dynamic]Deferred_Free,
}

@(private)
Unmarshal_Frame :: struct {
	val_node:           tape.Node_Index,
	group_lo, group_hi: u32,
	dst:                rawptr,
	ti:                 ^runtime.Type_Info,
	path_idx:           int,
	in_group:           bool,
}

@(private)
BEFORE_STACK :: 128

@(private)
push_path_node :: proc(cx: ^Unmarshal_Cx, parent: int, step: tape.Step) -> int {
	if cx.read.path == nil { return -1 }
	idx := len(cx.path_nodes)
	if _, err := append(&cx.path_nodes, Path_Node{parent, step}); err != nil { return -1 }
	return idx
}

@(private)
work_alloc :: #force_inline proc "contextless" (cx: ^Unmarshal_Cx) -> runtime.Allocator {
	ta := cx.trials[len(cx.trials) - 1].alloc if len(cx.trials) > 0 else &cx.root_alloc
	return runtime.Allocator{trial_alloc_proc, ta}
}

@(private)
trial_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	ta := (^Trial_Alloc)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		res, err := ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err != nil { return nil, err }
		if size > 0 {
			if _, perr := append(&ta.blocks, Trial_Block{raw_data(res), size, alignment}); perr != nil {
				_, _ = ta.backing.procedure(ta.backing.data, .Free, 0, 0, raw_data(res), size, loc)
				return nil, .Out_Of_Memory
			}
		}
		return res, nil
	case .Resize, .Resize_Non_Zeroed:
		res, err := ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err != nil { return nil, err }
		if old_memory != nil {
			for &b, idx in ta.blocks {
				if b.ptr == old_memory {
					if size == 0 { unordered_remove(&ta.blocks, idx) } else { b = {raw_data(res), size, alignment} }
					return res, nil
				}
			}
		}
		if size > 0 {
			if _, perr := append(&ta.blocks, Trial_Block{raw_data(res), size, alignment}); perr != nil {
				if old_memory == nil { _, _ = ta.backing.procedure(ta.backing.data, .Free, 0, 0, raw_data(res), size, loc) }
				return res if old_memory != nil else nil, .Out_Of_Memory
			}
		}
		return res, nil
	case .Free:
		if old_memory != nil {
			for b, idx in ta.blocks { if b.ptr == old_memory { unordered_remove(&ta.blocks, idx); break } }
		}
		return ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
	case .Free_All, .Query_Features, .Query_Info:
		return ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
	}
	return nil, .Mode_Not_Implemented
}

@(private)
rollback_blocks :: proc(ta: ^Trial_Alloc) {
	if ta == nil { return }
	#reverse for b in ta.blocks { runtime.mem_free_with_size(b.ptr, b.size, ta.backing) }
	clear(&ta.blocks)
}

@(private)
free_trial :: proc(cx: ^Unmarshal_Cx, tr: ^Union_Trial) {
	if tr.alloc != nil {
		delete(tr.alloc.blocks)
		free(tr.alloc, cx.tmp)
		tr.alloc = nil
	}
	if tr.work != nil {
		delete(tr.work, cx.tmp)
		tr.work = nil
	}
}

@(private)
write_word :: #force_inline proc "contextless" (dst: rawptr, val: u64, size: int) -> bool {
	switch size {
	case 1: (^u8)(dst)^ = u8(val)
	case 2: (^u16)(dst)^ = u16(val)
	case 4: (^u32)(dst)^ = u32(val)
	case 8: (^u64)(dst)^ = val
	case:   return false
	}
	return true
}

@(private)
set_union_tag :: #force_inline proc "contextless" (dst: rawptr, info: ^runtime.Type_Info_Union, ti_size: int, tag_val: u64) {
	if info.tag_type != nil && info.tag_offset < uintptr(ti_size) {
		_ = write_word(rawptr(uintptr(dst) + uintptr(info.tag_offset)), tag_val, info.tag_type.size)
	}
}

@(private)
push_union_variant :: proc(tr: ^Union_Trial, vi: int, stack: ^[dynamic]Unmarshal_Frame) -> runtime.Allocator_Error {
	intrinsics.mem_zero(raw_data(tr.work), tr.ti_size)
	set_union_tag(raw_data(tr.work), tr.ti, tr.ti_size, u64(vi) if tr.ti.no_nil else u64(vi + 1))
	append(stack, Unmarshal_Frame{
		val_node = tr.val_node, group_lo = tr.group_lo, group_hi = tr.group_hi,
		dst = raw_data(tr.work), ti = tr.ti.variants[vi], path_idx = tr.path_idx, in_group = tr.in_group,
	}) or_return
	return nil
}

@(private)
unmarshal_root :: proc(
	doc: ^tape.Document, target: rawptr, T: typeid, read: Unmarshal_Options, opts: Options,
	caller, alloc, tmp: runtime.Allocator,
) -> (err: tape.Error) {
	ti := type_info_of(T)
	before_buf: [BEFORE_STACK]u8 = ---
	before: []u8
	before_heap := false
	if ti.size > 0 {
		if ti.size <= BEFORE_STACK {
			before = before_buf[:ti.size]
		} else {
			before = make([]u8, ti.size, tmp) or_return
			before_heap = true
		}
		intrinsics.mem_copy_non_overlapping(raw_data(before), target, ti.size)
	}
	defer if before_heap { delete(before, tmp) }

	cx := Unmarshal_Cx{doc = doc, read = read, opts = opts, caller = caller, alloc = alloc, tmp = tmp, root_alloc = {backing = alloc}}
	cx.buf.allocator, cx.group_pool.allocator, cx.path_nodes.allocator = tmp, tmp, tmp
	cx.trials.allocator, cx.root_alloc.blocks.allocator, cx.deferred_frees.allocator = tmp, tmp, tmp
	defer {
		if err != nil {
			#reverse for &tr in cx.trials {
				rollback_blocks(tr.alloc)
				free_trial(&cx, &tr)
			}
			rollback_blocks(&cx.root_alloc)
			if len(before) > 0 { intrinsics.mem_copy_non_overlapping(target, raw_data(before), len(before)) }
		} else {
			for df in cx.deferred_frees { runtime.mem_free_with_size(df.ptr, df.size, df.alloc) }
		}
		delete(cx.deferred_frees)
		delete(cx.root_alloc.blocks)
		delete(cx.trials)
		delete(cx.path_nodes)
		delete(cx.group_pool)
		delete(cx.buf)
	}

	stack := make([dynamic]Unmarshal_Frame, 0, 16, tmp) or_return
	defer delete(stack)
	append(&stack, Unmarshal_Frame{val_node = tape.ROOT, dst = target, ti = ti, path_idx = -1}) or_return

	for len(stack) > 0 {
		fr := pop(&stack)
		step_err := step_unmarshal(&cx, &fr, &stack)
		if step_err != nil {
			f, is_f := step_err.(tape.Fault)
			can_retry := is_f && f.kind == .Refused && Typed_Refusal(f.detail) != .None && len(cx.trials) > 0
			for can_retry && len(cx.trials) > 0 {
				tr := &cx.trials[len(cx.trials) - 1]
				if len(stack) > tr.stack_base { resize(&stack, tr.stack_base) }
				rollback_blocks(tr.alloc)
				if len(cx.path_nodes) > tr.path_len { resize(&cx.path_nodes, tr.path_len) }
				if len(cx.group_pool) > tr.pool_len { resize(&cx.group_pool, tr.pool_len) }
				if tr.next_var < len(tr.ti.variants) {
					vi := tr.next_var
					tr.next_var += 1
					push_union_variant(tr, vi, &stack) or_return
					step_err = nil
					break
				}
				v_idx, p_idx := tr.val_node, tr.path_idx
				popped := pop(&cx.trials)
				free_trial(&cx, &popped)
				fr.path_idx = p_idx
				step_err = refuse_typed(&cx, &fr, cx.doc.nodes[v_idx].lo, .No_Arm)
			}
			if step_err != nil {
				if cx.read.path != nil {
					for cur := fr.path_idx; cur >= 0 && cur < len(cx.path_nodes); cur = cx.path_nodes[cur].parent {
						_, _ = inject_at(cx.read.path, 0, cx.path_nodes[cur].step)
					}
				}
				return step_err
			}
		}
		for len(cx.trials) > 0 && len(stack) == cx.trials[len(cx.trials) - 1].stack_base {
			tr := pop(&cx.trials)
			intrinsics.mem_copy_non_overlapping(tr.dst, raw_data(tr.work), tr.ti_size)
			if tr.alloc != nil && len(tr.alloc.blocks) > 0 {
				parent_blocks := &cx.trials[len(cx.trials) - 1].alloc.blocks if len(cx.trials) > 0 else &cx.root_alloc.blocks
				if _, berr := append(parent_blocks, ..tr.alloc.blocks[:]); berr != nil {
					rollback_blocks(tr.alloc)
					free_trial(&cx, &tr)
					return berr
				}
				clear(&tr.alloc.blocks)
			}
			free_trial(&cx, &tr)
		}
	}
	return nil
}

@(private)
group_pick :: #force_inline proc "contextless" (cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame) -> (tape.Node_Index, bool) {
	v := fr.val_node
	if fr.in_group {
		g := cx.group_pool[fr.group_lo:fr.group_hi]
		if len(g) == 0 { return 0, false }
		v = g[len(g) - 1] if cx.opts.dups == .Last else g[0]
	}
	if cx.doc.nodes[v].kind == .Array {
		end := tape.node_after(cx.doc, v)
		if v + 1 >= end { return 0, false }
		if cx.opts.dups != .Last { return v + 1, true }
		last := v + 1
		for c := v + 1; c < end; c = tape.node_after(cx.doc, c) { last = c }
		return last, true
	}
	return v, true
}

@(private)
has_attributes :: #force_inline proc "contextless" (doc: ^tape.Document, v: tape.Node_Index) -> bool {
	for af in tape.facts_of(doc, v) { if af.kind == .Attribute { return true } }
	return false
}

@(private)
step_unmarshal :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if fr.ti.id == typed.Raw || fr.ti.id == time.Time {
		v, ok := group_pick(cx, fr)
		return fill_scalar(cx, fr, v, fr.dst, fr.ti) if ok else nil
	}
	#partial switch info in runtime.type_info_base(fr.ti).variant {
	case ^runtime.Type_Info_Struct:           return fill_struct(cx, fr, info, stack)
	case ^runtime.Type_Info_Dynamic_Array:    return fill_dynamic_array(cx, fr, info, stack)
	case ^runtime.Type_Info_Slice:            return fill_slice(cx, fr, info, stack)
	case ^runtime.Type_Info_Array:            return fill_fixed_array(cx, fr, info.elem, info.elem_size, info.count, stack)
	case ^runtime.Type_Info_Enumerated_Array:
		if info.is_sparse { return tape.Bad_Option{"type"} }
		return fill_fixed_array(cx, fr, info.elem, info.elem_size, info.count, stack)
	case ^runtime.Type_Info_Map:              return fill_map(cx, fr, info, stack)
	case ^runtime.Type_Info_Pointer:          return fill_pointer(cx, fr, info, stack)
	case ^runtime.Type_Info_Union:            return fill_union(cx, fr, info, stack)
	case ^runtime.Type_Info_Bit_Set:          return fill_bit_set(cx, fr, info)
	}
	v, ok := group_pick(cx, fr)
	return fill_scalar(cx, fr, v, fr.dst, fr.ti) if ok else nil
}

@(private)
Seen_Fields :: struct { lo: u64, hi: []bool }

@(private)
mark_seen :: #force_inline proc "contextless" (s: ^Seen_Fields, idx: int) {
	if idx < 64 { s.lo |= u64(1) << uint(idx) } else if idx - 64 < len(s.hi) { s.hi[idx - 64] = true }
}

@(private)
is_seen :: #force_inline proc "contextless" (s: ^Seen_Fields, idx: int) -> bool {
	return (s.lo & (u64(1) << uint(idx))) != 0 if idx < 64 else (idx - 64 < len(s.hi) && s.hi[idx - 64])
}

@(private)
check_required :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Struct, seen: ^Seen_Fields, at: u64) -> tape.Error {
	for fi in 0 ..< int(info.field_count) {
		if is_seen(seen, fi) { continue }
		name, req, skip := struct_field_name(info, fi)
		if !skip && req { return refuse_typed(cx, fr, at, .Missing_Field, tape.Step(tape.Name(name))) }
	}
	return nil
}

@(private)
fill_struct :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Struct, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if info.soa_kind != .None || .raw_union in info.flags { return tape.Bad_Option{"type"} }
	v, ok := group_pick(cx, fr)
	if !ok { return nil }
	node := cx.doc.nodes[v]
	seen: Seen_Fields
	if info.field_count > 64 { seen.hi = make([]bool, int(info.field_count) - 64, cx.tmp) or_return }
	defer if seen.hi != nil { delete(seen.hi, cx.tmp) }

	if node.kind == .Null {
		fill_struct_attributes(cx, fr, info, v, &seen) or_return
		return check_required(cx, fr, info, &seen, node.lo)
	}
	if node.kind != .Object {
		if node.kind > .Plain { return refuse_typed(cx, fr, node.lo, .Expected_Object) }
		has_attr := fill_struct_attributes(cx, fr, info, v, &seen) or_return
		has_text := false
		for fi in 0 ..< int(info.field_count) {
			name, _, skip := struct_field_name(info, fi)
			if skip || !is_text_field_name(name) { continue }
			has_text = true
			mark_seen(&seen, fi)
			pool_lo := u32(len(cx.group_pool))
			append(&cx.group_pool, v) or_return
			child_path := push_path_node(cx, fr.path_idx, tape.Step(tape.Name(name)))
			append(stack, Unmarshal_Frame{
				val_node = v, group_lo = pool_lo, group_hi = pool_lo + 1,
				dst = rawptr(uintptr(fr.dst) + uintptr(info.offsets[fi])), ti = info.types[fi], path_idx = child_path, in_group = true,
			}) or_return
		}
		if !has_text && !has_attr { return refuse_typed(cx, fr, node.lo, .Expected_Object) }
		if !has_text && cx.read.refuse_unknown { return refuse_typed(cx, fr, node.lo, .Unknown_Field, tape.Step(tape.Name(tape.TEXT_KEY))) }
		return check_required(cx, fr, info, &seen, node.lo + u64(node.n))
	}

	fill_struct_attributes(cx, fr, info, v, &seen) or_return

	Member_Occ :: struct { bi: u32, val: tape.Node_Index }
	Field_Bucket :: struct { field_idx: int, count, lo: u32, dup_lo: u64, name: string }
	occs := make([dynamic]Member_Occ, 0, 8, cx.tmp) or_return
	defer delete(occs)
	buckets := make([dynamic]Field_Bucket, 0, min(int(info.field_count), 16), cx.tmp) or_return
	defer delete(buckets)

	for k, end := v + 1, tape.node_after(cx.doc, v); k < end; {
		val := tape.node_after(cx.doc, k)
		ktok := cx.doc.nodes[k]
		mname := key_text(cx.doc.src, ktok)
		fidx, fname, found := find_struct_field(info, mname)
		if !found {
			if cx.read.refuse_unknown { return refuse_typed(cx, fr, ktok.lo, .Unknown_Field, tape.Step(tape.Name(mname))) }
			k = tape.node_after(cx.doc, val)
			continue
		}
		mark_seen(&seen, fidx)
		bi := -1
		for &b, idx in buckets { if b.field_idx == fidx { bi = idx; break } }
		if bi < 0 {
			append(&buckets, Field_Bucket{field_idx = fidx, name = fname}) or_return
			bi = len(buckets) - 1
		}
		b := &buckets[bi]
		if b.count == 1 { b.dup_lo = ktok.lo }
		b.count += 1
		append(&occs, Member_Occ{u32(bi), val}) or_return
		k = tape.node_after(cx.doc, val)
	}

	end_at, has_end := close_end(cx.doc, v)
	check_required(cx, fr, info, &seen, end_at if has_end else node.lo) or_return

	for b in buckets {
		if b.count > 1 && cx.opts.dups == .Refuse && !can_be_list(info.types[b.field_idx]) {
			return tape.Fault{at = b.dup_lo, rules = &RULES, kind = .Duplicate_Key}
		}
	}
	if len(occs) == 0 { return nil }

	pool_base := len(cx.group_pool)
	resize(&cx.group_pool, pool_base + len(occs)) or_return
	cur := u32(pool_base)
	for &b in buckets {
		b.lo = cur
		cur += b.count
		b.count = 0
	}
	for occ in occs {
		b := &buckets[occ.bi]
		cx.group_pool[b.lo + b.count] = occ.val
		b.count += 1
	}

	#reverse for b in buckets {
		child_path := push_path_node(cx, fr.path_idx, tape.Step(tape.Name(b.name)))
		append(stack, Unmarshal_Frame{
			val_node = cx.group_pool[b.lo], group_lo = b.lo, group_hi = b.lo + b.count,
			dst = rawptr(uintptr(fr.dst) + uintptr(info.offsets[b.field_idx])),
			ti = info.types[b.field_idx], path_idx = child_path, in_group = true,
		}) or_return
	}
	return nil
}

@(private)
fill_struct_attributes :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Struct, v: tape.Node_Index, seen: ^Seen_Fields) -> (has_attr: bool, err: tape.Error) {
	for af in tape.facts_of(cx.doc, v) {
		if af.kind != .Attribute { continue }
		has_attr = true
		kt, vt := attribute(cx.doc, af)
		aname := key_text(cx.doc.src, kt)
		if idx, fname, found := find_struct_field(info, aname); found {
			mark_seen(seen, idx)
			child_fr := Unmarshal_Frame{path_idx = push_path_node(cx, fr.path_idx, tape.Step(tape.Name(fname)))}
			if serr := fill_attr_value(cx, &child_fr, vt, rawptr(uintptr(fr.dst) + uintptr(info.offsets[idx])), info.types[idx]); serr != nil {
				fr.path_idx = child_fr.path_idx
				return has_attr, serr
			}
		} else if cx.read.refuse_unknown && af.spelling & ATTRIBUTE_NS == 0 {
			return has_attr, refuse_typed(cx, fr, af.lo, .Unknown_Field, tape.Step(tape.Name(aname)))
		}
	}
	return has_attr, nil
}

@(private)
fill_attr_value :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, tok: tape.Token, dst: rawptr, ti: ^runtime.Type_Info) -> tape.Error {
	cur_dst, cur_ti := dst, ti
	for {
		base := runtime.type_info_base(cur_ti)
		if u, is_u := base.variant.(^runtime.Type_Info_Union); is_u && len(u.variants) == 1 && !u.no_nil {
			set_union_tag(cur_dst, u, cur_ti.size, 1)
			cur_ti = u.variants[0]
			continue
		}
		if ptr, is_p := base.variant.(^runtime.Type_Info_Pointer); is_p && ptr.elem != nil {
			p := (^rawptr)(cur_dst)^
			if p == nil {
				bytes := runtime.mem_alloc(ptr.elem.size, ptr.elem.align, work_alloc(cx)) or_return
				p = raw_data(bytes)
				(^rawptr)(cur_dst)^ = p
			}
			cur_dst = p
			cur_ti = ptr.elem
			continue
		}
		return fill_token_scalar(cx, fr, tok, cur_dst, cur_ti)
	}
}

@(private)
collect_list_elems :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame) -> (lo, hi: u32, err: tape.Error) {
	arr_node := tape.NO_NODE
	if fr.in_group {
		if fr.group_hi - fr.group_lo == 1 && cx.doc.nodes[cx.group_pool[fr.group_lo]].kind == .Array {
			arr_node = cx.group_pool[fr.group_lo]
		} else {
			return fr.group_lo, fr.group_hi, nil
		}
	} else {
		node := cx.doc.nodes[fr.val_node]
		if node.kind == .Null { return 0, 0, nil }
		if node.kind != .Array { return 0, 0, refuse_typed(cx, fr, node.lo, .Expected_Array) }
		arr_node = fr.val_node
	}
	base := u32(len(cx.group_pool))
	for c, end := arr_node + 1, tape.node_after(cx.doc, arr_node); c < end; c = tape.node_after(cx.doc, c) {
		append(&cx.group_pool, c) or_return
	}
	return base, u32(len(cx.group_pool)), nil
}

@(private)
push_list_frames :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, lo, hi: u32, data: rawptr, elem_size: int, elem_ti: ^runtime.Type_Info, stack: ^[dynamic]Unmarshal_Frame) -> runtime.Allocator_Error {
	for idx := int(hi - lo) - 1; idx >= 0; idx -= 1 {
		cpath := push_path_node(cx, fr.path_idx, tape.Step(tape.Index(idx)))
		append(stack, Unmarshal_Frame{
			val_node = cx.group_pool[int(lo) + idx],
			dst = rawptr(uintptr(data) + uintptr(idx * elem_size)),
			ti = elem_ti, path_idx = cpath,
		}) or_return
	}
	return nil
}

@(private)
fill_dynamic_array :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Dynamic_Array, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if info.elem_size == 0 { return tape.Bad_Option{"type"} }
	lo, hi := collect_list_elems(cx, fr) or_return
	n := int(hi - lo)
	raw := (^runtime.Raw_Dynamic_Array)(fr.dst)
	old_alloc := raw.allocator
	if raw.allocator.procedure == nil { raw.allocator = cx.caller }
	if n == 0 {
		raw.len = 0
		return nil
	}
	bytes := runtime.mem_alloc(n * info.elem_size, info.elem.align, work_alloc(cx)) or_return
	if raw.data != nil {
		append(&cx.deferred_frees, Deferred_Free{raw.data, raw.cap * info.elem_size, old_alloc if old_alloc.procedure != nil else cx.caller}) or_return
	}
	raw.data, raw.len, raw.cap = raw_data(bytes), n, n
	push_list_frames(cx, fr, lo, hi, raw.data, info.elem_size, info.elem, stack) or_return
	return nil
}

@(private)
fill_slice :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Slice, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if info.elem_size == 0 { return tape.Bad_Option{"type"} }
	lo, hi := collect_list_elems(cx, fr) or_return
	n := int(hi - lo)
	raw := (^runtime.Raw_Slice)(fr.dst)
	if n == 0 {
		raw^ = {}
		return nil
	}
	bytes := runtime.mem_alloc(n * info.elem_size, info.elem.align, work_alloc(cx)) or_return
	raw.data, raw.len = raw_data(bytes), n
	push_list_frames(cx, fr, lo, hi, raw.data, info.elem_size, info.elem, stack) or_return
	return nil
}

@(private)
fill_fixed_array :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, elem_ti: ^runtime.Type_Info, elem_size, count: int, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if elem_size == 0 { return tape.Bad_Option{"type"} }
	lo, hi := collect_list_elems(cx, fr) or_return
	n := int(hi - lo)
	if n > count { return refuse_typed(cx, fr, cx.doc.nodes[cx.group_pool[int(lo) + count]].lo, .Too_Many, tape.Step(tape.Index(count))) }
	if n < count {
		at := cx.doc.nodes[cx.group_pool[hi - 1]].lo if n > 0 else cx.doc.nodes[fr.val_node].lo
		return refuse_typed(cx, fr, at, .Too_Few)
	}
	push_list_frames(cx, fr, lo, hi, fr.dst, elem_size, elem_ti, stack) or_return
	return nil
}

@(private)
fill_map :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Map, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	v, ok := group_pick(cx, fr)
	if !ok { return nil }
	node := cx.doc.nodes[v]
	if node.kind == .Null { return nil }
	if node.kind != .Object { return refuse_typed(cx, fr, node.lo, .Expected_Object) }
	if runtime.type_info_base(info.key).id != string { return tape.Bad_Option{"map"} }

	Map_Occ :: struct { ei: u32, val: tape.Node_Index }
	Map_Entry :: struct { key_tok: tape.Token, key_str: string, count, lo: u32, dup_lo: u64, cpath: int }
	occs := make([dynamic]Map_Occ, 0, 8, cx.tmp) or_return
	defer delete(occs)
	entries := make([dynamic]Map_Entry, 0, 8, cx.tmp) or_return
	defer delete(entries)

	for k, end := v + 1, tape.node_after(cx.doc, v); k < end; {
		val := tape.node_after(cx.doc, k)
		ktok := cx.doc.nodes[k]
		kname := key_text(cx.doc.src, ktok)
		ei := -1
		for &e, idx in entries { if e.key_str == kname { ei = idx; break } }
		if ei < 0 {
			append(&entries, Map_Entry{key_tok = ktok, key_str = kname}) or_return
			ei = len(entries) - 1
		}
		e := &entries[ei]
		if e.count == 1 { e.dup_lo = ktok.lo }
		e.count += 1
		append(&occs, Map_Occ{u32(ei), val}) or_return
		k = tape.node_after(cx.doc, val)
	}

	val_is_list := can_be_list(info.value)
	for e in entries {
		if e.count > 1 && cx.opts.dups == .Refuse && !val_is_list { return tape.Fault{at = e.dup_lo, rules = &RULES, kind = .Duplicate_Key} }
	}
	if len(entries) == 0 { return nil }

	pool_base := len(cx.group_pool)
	resize(&cx.group_pool, pool_base + len(occs)) or_return
	cur := u32(pool_base)
	for &e in entries {
		e.lo = cur
		cur += e.count
		e.count = 0
	}
	for occ in occs {
		e := &entries[occ.ei]
		cx.group_pool[e.lo + e.count] = occ.val
		e.count += 1
	}

	zero := make([]u8, info.value.size, cx.tmp) or_return
	defer delete(zero, cx.tmp)

	raw := (^runtime.Raw_Map)(fr.dst)
	orig_alloc := raw.allocator if raw.allocator.procedure != nil else cx.caller
	wa := work_alloc(cx)
	raw.allocator = wa
	defer raw.allocator = orig_alloc

	for &e in entries {
		kstr, cloned := clone_key(cx, e.key_tok, wa) or_return
		_, _, just_inserted, merr := runtime.__dynamic_map_entry(raw, info.map_info, &kstr, raw_data(zero))
		if merr != nil {
			if cloned { delete(kstr, wa) }
			return runtime.Allocator_Error.Out_Of_Memory
		}
		if !just_inserted && cloned { delete(kstr, wa) }
		e.cpath = push_path_node(cx, fr.path_idx, tape.Step(tape.Name(e.key_str)))
	}

	#reverse for e in entries {
		k := e.key_str
		h := info.map_info.key_hasher(&k, runtime.map_seed(raw^))
		slot := runtime.__dynamic_map_get(raw, info.map_info, h, &k)
		if slot == nil { return runtime.Allocator_Error.Out_Of_Memory }
		append(stack, Unmarshal_Frame{
			val_node = cx.group_pool[e.lo], group_lo = e.lo, group_hi = e.lo + e.count,
			dst = slot, ti = info.value, path_idx = e.cpath, in_group = true,
		}) or_return
	}
	return nil
}

@(private)
fill_pointer :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Pointer, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if info.elem == nil { return tape.Bad_Option{"type"} }
	v, ok := group_pick(cx, fr)
	if !ok { return nil }
	single := !fr.in_group || fr.group_hi - fr.group_lo <= 1
	if cx.doc.nodes[v].kind == .Null && single && !has_attributes(cx.doc, v) {
		(^rawptr)(fr.dst)^ = nil
		return nil
	}
	p := (^rawptr)(fr.dst)^
	if p == nil {
		bytes := runtime.mem_alloc(info.elem.size, info.elem.align, work_alloc(cx)) or_return
		p = raw_data(bytes)
		(^rawptr)(fr.dst)^ = p
	}
	append(stack, Unmarshal_Frame{
		val_node = v, group_lo = fr.group_lo, group_hi = fr.group_hi,
		dst = p, ti = info.elem, path_idx = fr.path_idx, in_group = fr.in_group,
	}) or_return
	return nil
}

@(private)
fill_union :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Union, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	v, ok := group_pick(cx, fr)
	if !ok { return nil }
	single := !fr.in_group || fr.group_hi - fr.group_lo <= 1
	if cx.doc.nodes[v].kind == .Null && !info.no_nil && single && !has_attributes(cx.doc, v) {
		intrinsics.mem_zero(fr.dst, fr.ti.size)
		return nil
	}
	if len(info.variants) == 0 { return refuse_typed(cx, fr, cx.doc.nodes[v].lo, .No_Arm) }
	if len(info.variants) == 1 {
		set_union_tag(fr.dst, info, fr.ti.size, u64(0 if info.no_nil else 1))
		append(stack, Unmarshal_Frame{
			val_node = v, group_lo = fr.group_lo, group_hi = fr.group_hi,
			dst = fr.dst, ti = info.variants[0], path_idx = fr.path_idx, in_group = fr.in_group,
		}) or_return
		return nil
	}
	work := make([]u8, fr.ti.size, cx.tmp) or_return
	ta, ta_err := new(Trial_Alloc, cx.tmp)
	if ta_err != nil {
		delete(work, cx.tmp)
		return ta_err
	}
	ta^ = {backing = cx.alloc}
	ta.blocks.allocator = cx.tmp
	tr := Union_Trial {
		val_node = v, group_lo = fr.group_lo, group_hi = fr.group_hi, dst = fr.dst, ti = info, ti_size = fr.ti.size,
		path_idx = fr.path_idx, stack_base = len(stack), next_var = 1, path_len = len(cx.path_nodes),
		pool_len = len(cx.group_pool), work = work, alloc = ta, in_group = fr.in_group,
	}
	if _, aerr := append(&cx.trials, tr); aerr != nil {
		free_trial(cx, &tr)
		return aerr
	}
	if perr := push_union_variant(&cx.trials[len(cx.trials) - 1], 0, stack); perr != nil {
		popped := pop(&cx.trials)
		free_trial(cx, &popped)
		return perr
	}
	return nil
}

@(private)
fill_bit_set :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Bit_Set) -> tape.Error {
	lo, hi := collect_list_elems(cx, fr) or_return
	intrinsics.mem_zero(fr.dst, fr.ti.size)
	einfo, is_enum := runtime.type_info_base(info.elem).variant.(^runtime.Type_Info_Enum)
	count := info.upper - info.lower + 1
	for idx in int(lo) ..< int(hi) {
		tok := cx.doc.nodes[cx.group_pool[idx]]
		step := tape.Step(tape.Index(idx - int(lo)))
		val: i64
		if is_enum {
			if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Name, step) }
			s := read_token_tmp(cx, tok) or_return
			found := false
			for ename, ei in einfo.names { if ename == s { val, found = i64(einfo.values[ei]), true; break } }
			if !found { return refuse_typed(cx, fr, tok.lo, .Not_A_Member, step) }
		} else {
			if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Integer, step) }
			s := read_token_tmp(cx, tok) or_return
			n, ok := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
			if !ok || n.kind == .Float { return refuse_typed(cx, fr, tok.lo, .Expected_Integer, step) }
			if n.kind != .Int {
				return refuse_typed(cx, fr, tok.lo, .Below_Minimum if len(s) > 0 && s[0] == '-' else .Above_Maximum, step)
			}
			val = i64(n.bits)
		}
		bit := val - info.lower
		if bit < 0 { return refuse_typed(cx, fr, tok.lo, .Below_Minimum, step) }
		if bit >= count { return refuse_typed(cx, fr, tok.lo, .Above_Maximum, step) }
		(^u8)(uintptr(fr.dst) + uintptr(bit / 8))^ |= 1 << uint(bit % 8)
	}
	return nil
}

@(private)
fill_scalar :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, v: tape.Node_Index, dst: rawptr, ti: ^runtime.Type_Info) -> tape.Error {
	node := cx.doc.nodes[v]
	if ti.id == typed.Raw {
		lo := node.lo
		hi := lo + u64(node.n)
		if node.kind > .Plain {
			end, ok := close_end(cx.doc, v)
			hi = end if ok else lo
		}
		if lo < hi {
			raw_s := string(cx.doc.src[lo:hi])
			(^string)(dst)^ = raw_s if cx.read.borrow_strings else (strings.clone(raw_s, work_alloc(cx)) or_return)
		} else {
			(^string)(dst)^ = ""
		}
		return nil
	}
	return fill_token_scalar(cx, fr, node, dst, ti)
}

@(private)
fill_token_scalar :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, tok: tape.Token, dst: rawptr, ti: ^runtime.Type_Info) -> tape.Error {
	if ti.id == typed.Raw {
		if tok.n > 0 {
			raw_s := string(cx.doc.src[tok.lo:][:tok.n])
			(^string)(dst)^ = raw_s if cx.read.borrow_strings else (strings.clone(raw_s, work_alloc(cx)) or_return)
		} else {
			(^string)(dst)^ = ""
		}
		return nil
	}
	if tok.kind == .Null {
		intrinsics.mem_zero(dst, ti.size)
		return nil
	}
	if ti.id == time.Time {
		if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Date_Time) }
		s := read_token_tmp(cx, tok) or_return
		nsec, spelled, in_range := spell.date_time_nsec(s)
		if !spelled { return refuse_typed(cx, fr, tok.lo, .Bad_Date_Time) }
		if !in_range { return refuse_typed(cx, fr, tok.lo, .Out_Of_Range) }
		(^time.Time)(dst)^ = {nsec}
		return nil
	}
	base := runtime.type_info_base(ti)
	#partial switch info in base.variant {
	case ^runtime.Type_Info_String:
		if info.is_cstring || info.encoding != .UTF_8 { return tape.Bad_Option{"type"} }
		if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_String) }
		if tok.kind == .True || tok.kind == .False {
			w := "true" if tok.kind == .True else "false"
			(^string)(dst)^ = w if cx.read.borrow_strings else (strings.clone(w, work_alloc(cx)) or_return)
		} else {
			(^string)(dst)^ = clone_token(cx, tok) or_return
		}
		return nil
	case ^runtime.Type_Info_Boolean:
		if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Bool) }
		s := read_token_tmp(cx, tok) or_return
		val := tok.kind == .True || s == "true"
		if !val && tok.kind != .False && s != "false" { return refuse_typed(cx, fr, tok.lo, .Expected_Bool) }
		return nil if write_word(dst, 1 if val else 0, base.size) else tape.Bad_Option{"type"}
	case ^runtime.Type_Info_Integer:
		if info.endianness != .Platform && info.endianness != (.Little if ODIN_ENDIAN == .Little else .Big) { return tape.Bad_Option{"type"} }
		if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Integer) }
		s := read_token_tmp(cx, tok) or_return
		n, ok := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
		if !ok || n.kind == .Float { return refuse_typed(cx, fr, tok.lo, .Expected_Integer) }
		if n.kind == .Wide {
			if !is_int_digits(s) { return refuse_typed(cx, fr, tok.lo, .Expected_Integer) }
			return refuse_typed(cx, fr, tok.lo, .Below_Minimum if len(s) > 0 && s[0] == '-' else .Above_Maximum)
		}
		if n.kind == .Uint {
			if !info.signed && base.size == 8 {
				(^u64)(dst)^ = n.bits
				return nil
			}
			return refuse_typed(cx, fr, tok.lo, .Above_Maximum)
		}
		iv := i64(n.bits)
		if info.signed {
			lo_lim := i64(min(i8)) if base.size == 1 else i64(min(i16)) if base.size == 2 else i64(min(i32)) if base.size == 4 else min(i64)
			hi_lim := i64(max(i8)) if base.size == 1 else i64(max(i16)) if base.size == 2 else i64(max(i32)) if base.size == 4 else max(i64)
			if base.size != 1 && base.size != 2 && base.size != 4 && base.size != 8 { return tape.Bad_Option{"type"} }
			if iv < lo_lim { return refuse_typed(cx, fr, tok.lo, .Below_Minimum) }
			if iv > hi_lim { return refuse_typed(cx, fr, tok.lo, .Above_Maximum) }
		} else {
			if iv < 0 { return refuse_typed(cx, fr, tok.lo, .Below_Minimum) }
			hi_lim := u64(max(u8)) if base.size == 1 else u64(max(u16)) if base.size == 2 else u64(max(u32)) if base.size == 4 else max(u64)
			if base.size != 1 && base.size != 2 && base.size != 4 && base.size != 8 { return tape.Bad_Option{"type"} }
			if u64(iv) > hi_lim { return refuse_typed(cx, fr, tok.lo, .Above_Maximum) }
		}
		_ = write_word(dst, n.bits, base.size)
		return nil
	case ^runtime.Type_Info_Float:
		if info.endianness != .Platform { return tape.Bad_Option{"type"} }
		if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Number) }
		s := read_token_tmp(cx, tok) or_return
		n, ok := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
		if !ok { return refuse_typed(cx, fr, tok.lo, .Expected_Number) }
		minus := len(s) > 0 && s[0] == '-'
		fv: f64
		switch n.kind {
		case .Int:
			fv = f64(i64(n.bits))
			if n.bits == 0 && minus { fv = -fv }
		case .Uint:
			fv = f64(n.bits)
		case .Float:
			fv = transmute(f64)n.bits
		case .Wide:
			parsed, pok := strconv.parse_f64(s)
			if !pok || math.is_nan(parsed) || math.is_inf(parsed) {
				return refuse_typed(cx, fr, tok.lo, .Below_Minimum if minus else .Above_Maximum)
			}
			fv = parsed
		}
		if math.is_nan(fv) { return refuse_typed(cx, fr, tok.lo, .Expected_Number) }
		if math.is_inf(fv) { return refuse_typed(cx, fr, tok.lo, .Below_Minimum if fv < 0 else .Above_Maximum) }
		switch base.size {
		case 4:
			v32 := f32(fv)
			if math.is_inf(f64(v32)) { return refuse_typed(cx, fr, tok.lo, .Below_Minimum if v32 < 0 else .Above_Maximum) }
			(^f32)(dst)^ = v32
		case 8:
			(^f64)(dst)^ = fv
		case:
			return tape.Bad_Option{"type"}
		}
		return nil
	case ^runtime.Type_Info_Enum:
		if tok.kind > .Plain { return refuse_typed(cx, fr, tok.lo, .Expected_Name) }
		s := read_token_tmp(cx, tok) or_return
		for name, i in info.names {
			if name == s {
				return nil if write_word(dst, u64(info.values[i]), base.size) else tape.Bad_Option{"type"}
			}
		}
		return refuse_typed(cx, fr, tok.lo, .Not_A_Member)
	}
	return tape.Bad_Option{"type"}
}

@(private)
is_int_digits :: proc "contextless" (s: string) -> bool {
	t := s[1:] if len(s) > 0 && s[0] == '-' else s
	if len(t) == 0 { return false }
	for c in transmute([]u8)t { if c < '0' || c > '9' { return false } }
	return true
}

@(private)
read_token_tmp :: proc(cx: ^Unmarshal_Cx, tok: tape.Token) -> (res: string, err: runtime.Allocator_Error) {
	if !tape.text_decodes(tok) && .Held not_in cx.doc.flags { return string(cx.doc.src[tok.lo:][:tok.n]), nil }
	room := max(tape.text_room(cx.doc, tok), int(tok.n), 64)
	if len(cx.buf) < room { resize(&cx.buf, room) or_return }
	s, ok := tape.node_text(cx.doc, tok, cx.buf[:])
	return s if ok else "", nil
}

@(private)
clone_key :: proc(cx: ^Unmarshal_Cx, tok: tape.Token, alloc: runtime.Allocator) -> (s: string, cloned: bool, err: runtime.Allocator_Error) {
	raw := key_text(cx.doc.src, tok)
	if cx.read.borrow_strings || len(raw) == 0 { return raw, false, nil }
	out := runtime.mem_alloc_non_zeroed(len(raw), 1, alloc) or_return
	copy(out, raw)
	return string(out), true, nil
}

@(private)
clone_token :: proc(cx: ^Unmarshal_Cx, tok: tape.Token) -> (cloned: string, err: runtime.Allocator_Error) {
	alloc := work_alloc(cx)
	if !tape.text_decodes(tok) && .Held not_in cx.doc.flags {
		span := cx.doc.src[tok.lo:][:tok.n]
		if cx.read.borrow_strings || len(span) == 0 { return string(span), nil }
		out := runtime.mem_alloc_non_zeroed(len(span), 1, alloc) or_return
		copy(out, span)
		return string(out), nil
	}
	room := max(tape.text_room(cx.doc, tok), int(tok.n))
	if room == 0 { return "", nil }
	if len(cx.buf) < room { resize(&cx.buf, room) or_return }
	s, ok := tape.node_text(cx.doc, tok, cx.buf[:])
	if !ok || len(s) == 0 { return "", nil }
	if cx.read.borrow_strings && .Held not_in cx.doc.flags && s == string(cx.doc.src[tok.lo:][:tok.n]) {
		return string(cx.doc.src[tok.lo:][:tok.n]), nil
	}
	return strings.clone(s, alloc)
}

@(private)
can_be_list :: proc "contextless" (ti: ^runtime.Type_Info) -> bool {
	work: [16]^runtime.Type_Info
	work[0] = ti
	n := 1
	for n > 0 {
		n -= 1
		#partial switch v in runtime.type_info_base(work[n]).variant {
		case ^runtime.Type_Info_Dynamic_Array, ^runtime.Type_Info_Slice, ^runtime.Type_Info_Array, ^runtime.Type_Info_Enumerated_Array, ^runtime.Type_Info_Bit_Set:
			return true
		case ^runtime.Type_Info_Pointer:
			if v.elem != nil && n < len(work) {
				work[n] = v.elem
				n += 1
			}
		case ^runtime.Type_Info_Union:
			for arm in v.variants {
				if n < len(work) {
					work[n] = arm
					n += 1
				}
			}
		}
	}
	return false
}

@(private)
is_text_field_name :: #force_inline proc "contextless" (name: string) -> bool {
	return name == tape.TEXT_KEY || name == "$text"
}

@(private)
struct_field_name :: proc(info: ^runtime.Type_Info_Struct, idx: int) -> (name: string, required: bool, skip: bool) {
	raw_val, has := typed.tag_lookup(info.tags[idx], TAG)
	if !has { raw_val, has = typed.tag_lookup(info.tags[idx], "stury") }
	if !has { return info.names[idx], false, false }
	if raw_val == "-" { return "", false, true }
	comma := strings.index_byte(raw_val, ',')
	head := raw_val[:comma] if comma >= 0 else raw_val
	req := false
	if comma >= 0 {
		flags := raw_val[comma + 1:]
		for len(flags) > 0 {
			k := strings.index_byte(flags, ',')
			part := flags[:k] if k >= 0 else flags
			if part == "required" {
				req = true
				break
			}
			if k < 0 { break }
			flags = flags[k + 1:]
		}
	}
	return head if len(head) > 0 else info.names[idx], req, false
}

@(private)
find_struct_field :: proc(info: ^runtime.Type_Info_Struct, target: string) -> (int, string, bool) {
	is_txt := target == tape.TEXT_KEY
	for i in 0 ..< int(info.field_count) {
		name, _, skip := struct_field_name(info, i)
		if !skip && (name == target || (is_txt && name == "$text")) { return i, name, true }
	}
	return -1, "", false
}

@(private)
refuse_typed :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, at: u64, detail: Typed_Refusal, step: Maybe(tape.Step) = nil) -> tape.Error {
	if s, ok := step.?; ok { fr.path_idx = push_path_node(cx, fr.path_idx, s) }
	return tape.Fault{at = at, rules = &typed.RULES, kind = .Refused, detail = u8(detail)}
}
