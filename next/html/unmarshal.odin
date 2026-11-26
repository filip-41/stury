package html

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strings"
import "core:time"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/markup"
import "stury:lib/core/tape"
import "stury:lib/ops/typed"

// Iterative zero-recursion HTML5 typed unmarshaler (`unmarshal` / `Unmarshal_Options`).
// Reads an HTML5 document (via `build`) into Odin structs, slices, dynamic arrays, fixed arrays, maps,
// unions, Maybes, pointers, enums, bit_sets, `time.Time`, `typed.Raw`, and primitives.
// Maps element attributes + child elements + `#text` onto struct fields via `"html"` / `"stury"` tags,
// groups repeated sibling elements under `.Group` into slices / dynamic arrays, and parses character-reference
// decoded text (`&#45;&#55;`) into numbers cleanly.

Unmarshal_Options :: typed.Unmarshal_Options
Typed_Refusal :: typed.Typed_Refusal

@(require_results)
unmarshal :: proc(src: []u8, target: ^$T, spec := Spec.Html, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_into(src, target, T, spec, {}, read, opts, allocator)
}

@(require_results)
unmarshal_fragment :: proc(src: []u8, target: ^$T, fopts := Fragment_Options{}, read := Unmarshal_Options{}, opts := Options{}, allocator := context.allocator) -> tape.Error {
	return unmarshal_into(src, target, T, .Fragment, fopts, read, opts, allocator)
}

@(private)
unmarshal_into :: proc(
	src: []u8,
	target: rawptr,
	T: typeid,
	spec: Spec,
	fopts: Fragment_Options,
	read: Unmarshal_Options,
	opts: Options,
	caller: runtime.Allocator,
) -> tape.Error {
	if read.path != nil {
		clear(read.path)
		if read.path.allocator.procedure == nil {
			read.path.allocator = caller
		}
	}
	if spec > max(Spec) {
		return tape.Bad_Option{"spec"}
	}
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil {
		return e
	}
	if target == nil {
		return tape.Bad_Option{"target"}
	}
	if opts.pieces != nil {
		return tape.Bad_Option{"pieces"}
	}
	if read.plan != nil && (read.plan.type != T || read.plan.tag != TAG) {
		return tape.Bad_Option{"plan"}
	}

	arena := new(runtime.Arena, caller) or_return
	defer free(arena, caller)
	runtime.arena_init(arena, 0, caller) or_return
	defer runtime.arena_destroy(arena)
	scratch := runtime.arena_allocator(arena)

	doc: tape.Document
	err: tape.Error
	if spec == .Fragment && (fopts.context_name != "" || fopts.scripting || fopts.context_namespace != .Html) {
		m: hook.Read_Budget
		doc, err = build_as_inner(src, spec, opts, fopts, scratch, &m)
	} else {
		doc, err = build(src, spec, opts, scratch)
	}
	if err != nil {
		return err
	}
	defer tape.destroy(&doc)

	if len(doc.nodes) == 0 {
		return nil
	}

	cx := Unmarshal_Cx {
		doc    = &doc,
		read   = read,
		opts   = opts,
		caller = caller,
		tmp    = scratch,
	}
	return unmarshal_root(&cx, target, T)
}

@(private)
Path_Node :: struct {
	parent: int,
	step:   tape.Step,
}

@(private)
Trial_Block :: struct {
	ptr:   rawptr,
	size:  int,
	align: int,
}

@(private)
Trial_Container :: struct {
	raw:    rawptr,
	is_map: bool,
}

@(private)
Trial_Alloc :: struct {
	backing: runtime.Allocator,
	blocks:  [dynamic]Trial_Block,
	oom:     bool,
}

@(private)
Union_Trial :: struct {
	val_node:    tape.Node_Index,
	group_elems: [dynamic]tape.Node_Index,
	dst:         rawptr,
	ti:          ^runtime.Type_Info_Union,
	ti_size:     int,
	path_idx:    int,
	stack_base:  int,
	next_var:    int,
	work:        []u8,
	path_len:    int,
	alloc:       ^Trial_Alloc,
	containers:  [dynamic]Trial_Container,
	in_group:    bool,
}

@(private)
Unmarshal_Cx :: struct {
	doc:        ^tape.Document,
	read:       Unmarshal_Options,
	opts:       Options,
	caller:     runtime.Allocator,
	tmp:        runtime.Allocator,
	buf:        [dynamic]u8,
	path_nodes: [dynamic]Path_Node,
	trials:     [dynamic]Union_Trial,
}

@(private)
Unmarshal_Frame :: struct {
	val_node:    tape.Node_Index,
	group_elems: [dynamic]tape.Node_Index,
	dst:         rawptr,
	ti:          ^runtime.Type_Info,
	path_idx:    int,
	in_group:    bool,
}

@(private)
push_path_node :: proc(cx: ^Unmarshal_Cx, parent: int, step: tape.Step) -> int {
	if cx.read.path == nil {
		return -1
	}
	idx := len(cx.path_nodes)
	if _, err := append(&cx.path_nodes, Path_Node{parent = parent, step = step}); err != nil {
		return -1
	}
	return idx
}

@(private)
caller_alloc :: #force_inline proc "contextless" (cx: ^Unmarshal_Cx) -> runtime.Allocator {
	if len(cx.trials) > 0 {
		return runtime.Allocator{trial_alloc_proc, cx.trials[len(cx.trials) - 1].alloc}
	}
	return cx.caller
}

@(private)
trial_alloc_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	ta := (^Trial_Alloc)(data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		res, err := ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err != nil {
			return nil, err
		}
		if size > 0 {
			if _, perr := append(&ta.blocks, Trial_Block{ptr = raw_data(res), size = size, align = alignment}); perr != nil {
				_, _ = ta.backing.procedure(ta.backing.data, .Free, 0, 0, raw_data(res), size, loc)
				ta.oom = true
				return nil, .Out_Of_Memory
			}
		}
		return res, nil
	case .Resize, .Resize_Non_Zeroed:
		res, err := ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
		if err != nil {
			return nil, err
		}
		if old_memory != nil {
			for &b, idx in ta.blocks {
				if b.ptr == old_memory {
					if size == 0 {
						unordered_remove(&ta.blocks, idx)
					} else {
						b.ptr = raw_data(res)
						b.size = size
						b.align = alignment
					}
					return res, nil
				}
			}
		}
		if size > 0 {
			if _, perr := append(&ta.blocks, Trial_Block{ptr = raw_data(res), size = size, align = alignment}); perr != nil {
				if old_memory == nil {
					_, _ = ta.backing.procedure(ta.backing.data, .Free, 0, 0, raw_data(res), size, loc)
					ta.oom = true
					return nil, .Out_Of_Memory
				}
				ta.oom = true
				return res, .Out_Of_Memory
			}
		}
		return res, nil
	case .Free:
		if old_memory != nil {
			for b, idx in ta.blocks {
				if b.ptr == old_memory {
					unordered_remove(&ta.blocks, idx)
					break
				}
			}
		}
		return ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
	case .Free_All, .Query_Features, .Query_Info:
		return ta.backing.procedure(ta.backing.data, mode, size, alignment, old_memory, old_size, loc)
	}
	return nil, .Mode_Not_Implemented
}

@(private)
clone_group_elems :: proc(elems: [dynamic]tape.Node_Index, alloc: runtime.Allocator) -> (out: [dynamic]tape.Node_Index, err: runtime.Allocator_Error) {
	if len(elems) == 0 {
		return nil, nil
	}
	out = make([dynamic]tape.Node_Index, len(elems), alloc) or_return
	copy(out[:], elems[:])
	return out, nil
}

@(private)
rollback_trial_allocs :: proc(tr: ^Union_Trial, tmp: runtime.Allocator, free_alloc: bool) {
	if tr.alloc != nil {
		#reverse for b in tr.alloc.blocks {
			runtime.mem_free_with_size(b.ptr, b.size, tr.alloc.backing)
		}
		if free_alloc {
			delete(tr.alloc.blocks)
			free(tr.alloc, tmp)
			tr.alloc = nil
		} else {
			clear(&tr.alloc.blocks)
			tr.alloc.oom = false
		}
	}
	if free_alloc {
		delete(tr.containers)
		delete(tr.group_elems)
	} else {
		clear(&tr.containers)
	}
}

@(private)
set_union_tag :: proc "contextless" (dst: rawptr, info: ^runtime.Type_Info_Union, ti_size: int, tag_val: u64) {
	if info.tag_type == nil || info.tag_offset >= uintptr(ti_size) {
		return
	}
	tag_ptr := rawptr(uintptr(dst) + uintptr(info.tag_offset))
	switch info.tag_type.size {
	case 1: (^u8)(tag_ptr)^ = u8(tag_val)
	case 2: (^u16)(tag_ptr)^ = u16(tag_val)
	case 4: (^u32)(tag_ptr)^ = u32(tag_val)
	case 8: (^u64)(tag_ptr)^ = tag_val
	}
}

@(private)
unmarshal_root :: proc(cx: ^Unmarshal_Cx, target: rawptr, T: typeid) -> tape.Error {
	cx.buf.allocator = cx.tmp
	cx.path_nodes.allocator = cx.tmp
	cx.trials.allocator = cx.tmp
	stack, serr := make([dynamic]Unmarshal_Frame, 0, 16, cx.tmp)
	if serr != nil {
		return serr
	}
	defer {
		for &fr in stack {
			delete(fr.group_elems)
		}
		delete(stack)
		for &tr in cx.trials {
			rollback_trial_allocs(&tr, cx.tmp, true)
			delete(tr.work, cx.tmp)
		}
		delete(cx.trials)
		delete(cx.path_nodes)
		delete(cx.buf)
	}
	append(&stack, Unmarshal_Frame{val_node = tape.ROOT, dst = target, ti = type_info_of(T), path_idx = -1}) or_return

	for len(stack) > 0 {
		fr := pop(&stack)
		err := step_unmarshal(cx, &fr, &stack)
		delete(fr.group_elems)
		if err != nil {
			can_retry := false
			if f, is_f := err.(tape.Fault); is_f && f.kind == .Refused && Typed_Refusal(f.detail) != .None {
				can_retry = len(cx.trials) > 0
			}
			for can_retry && len(cx.trials) > 0 {
				tr := &cx.trials[len(cx.trials) - 1]
				for len(stack) > tr.stack_base {
					dropped := pop(&stack)
					delete(dropped.group_elems)
				}
				has_more := tr.next_var < len(tr.ti.variants)
				rollback_trial_allocs(tr, cx.tmp, !has_more)
				if len(cx.path_nodes) > tr.path_len {
					resize(&cx.path_nodes, tr.path_len)
				}
				if has_more {
					vi := tr.next_var
					tr.next_var += 1
					intrinsics.mem_zero(raw_data(tr.work), tr.ti_size)
					tag_val := u64(vi) if tr.ti.no_nil else u64(vi + 1)
					set_union_tag(raw_data(tr.work), tr.ti, tr.ti_size, tag_val)
					var_elems, gerr := clone_group_elems(tr.group_elems, cx.tmp)
					if gerr != nil {
						return gerr
					}
					if _, aerr := append(&stack, Unmarshal_Frame{
						val_node    = tr.val_node,
						group_elems = var_elems,
						dst         = raw_data(tr.work),
						ti          = tr.ti.variants[vi],
						path_idx    = tr.path_idx,
						in_group    = tr.in_group,
					}); aerr != nil {
						delete(var_elems)
						return aerr
					}
					err = nil
					break
				}
				// All variants refused -> pop this union trial cleanly and surface `.No_Arm` (or retry outer trial!).
				delete(tr.work, cx.tmp)
				v_idx := tr.val_node
				p_idx := tr.path_idx
				_ = pop(&cx.trials)
				err = refuse_typed(cx, cx.doc.nodes[v_idx].lo, .No_Arm)
				fr.path_idx = p_idx
				if len(cx.trials) == 0 {
					break
				}
			}
			if err != nil {
				if cx.read.path != nil {
					cur := fr.path_idx
					for cur >= 0 && cur < len(cx.path_nodes) {
						pn := cx.path_nodes[cur]
						_, _ = inject_at(cx.read.path, 0, pn.step)
						cur = pn.parent
					}
				}
				return err
			}
		}
		for len(cx.trials) > 0 && len(stack) == cx.trials[len(cx.trials) - 1].stack_base {
			tr := pop(&cx.trials)
			next_alloc := caller_alloc(cx)
			work_lo := uintptr(raw_data(tr.work))
			work_hi := work_lo + uintptr(tr.ti_size)
			for tc in tr.containers {
				if tc.is_map {
					((^runtime.Raw_Map)(tc.raw)).allocator = next_alloc
				} else {
					((^runtime.Raw_Dynamic_Array)(tc.raw)).allocator = next_alloc
				}
			}
			intrinsics.mem_copy_non_overlapping(tr.dst, raw_data(tr.work), tr.ti_size)
			if len(cx.trials) > 0 {
				parent := &cx.trials[len(cx.trials) - 1]
				if tr.alloc != nil && len(tr.alloc.blocks) > 0 {
					if _, berr := append(&parent.alloc.blocks, ..tr.alloc.blocks[:]); berr != nil {
						rollback_trial_allocs(&tr, cx.tmp, true)
						delete(tr.work, cx.tmp)
						return berr
					}
					clear(&tr.alloc.blocks)
				}
				for tc in tr.containers {
					raw_ptr := tc.raw
					if uintptr(raw_ptr) >= work_lo && uintptr(raw_ptr) < work_hi {
						raw_ptr = rawptr(uintptr(tr.dst) + (uintptr(raw_ptr) - work_lo))
					}
					if _, cerr := append(&parent.containers, Trial_Container{raw = raw_ptr, is_map = tc.is_map}); cerr != nil {
						rollback_trial_allocs(&tr, cx.tmp, true)
						delete(tr.work, cx.tmp)
						return cerr
					}
				}
			}
			if tr.alloc != nil {
				delete(tr.alloc.blocks)
				free(tr.alloc, cx.tmp)
			}
			delete(tr.containers)
			delete(tr.group_elems)
			delete(tr.work, cx.tmp)
		}
	}
	return nil
}

@(private)
step_unmarshal :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	ti := runtime.type_info_base(fr.ti)
	#partial switch info in ti.variant {
	case ^runtime.Type_Info_Struct:
		return fill_struct(cx, fr, info, stack)
	case ^runtime.Type_Info_Dynamic_Array:
		return fill_dynamic_array(cx, fr, info, stack)
	case ^runtime.Type_Info_Slice:
		return fill_slice(cx, fr, info, stack)
	case ^runtime.Type_Info_Array:
		return fill_fixed_array(cx, fr, info, stack)
	case ^runtime.Type_Info_Map:
		return fill_map(cx, fr, info, stack)
	case ^runtime.Type_Info_Pointer:
		return fill_pointer(cx, fr, info, stack)
	case ^runtime.Type_Info_Union:
		return fill_union(cx, fr, info, stack)
	}
	if fr.in_group {
		if len(fr.group_elems) == 0 {
			return nil
		}
		v := fr.group_elems[0] if cx.opts.dups == .First else fr.group_elems[len(fr.group_elems) - 1]
		return fill_scalar(cx, v, fr.dst, fr.ti)
	}
	return fill_scalar(cx, fr.val_node, fr.dst, fr.ti)
}

@(private)
fill_struct :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Struct, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if fr.in_group {
		if len(fr.group_elems) == 0 {
			return nil
		}
		fr.val_node = fr.group_elems[0] if cx.opts.dups == .First else fr.group_elems[len(fr.group_elems) - 1]
	}
	if fr.ti.id == time.Time {
		return fill_scalar(cx, fr.val_node, fr.dst, fr.ti)
	}
	v := fr.val_node
	node := cx.doc.nodes[v]
	if node.kind == .Null {
		return fill_struct_attributes(cx, fr, info, v)
	}
	if node.kind != .Object {
		// Element with only text (and possibly attributes): match `#text` field and attributes!
		if node.kind <= .Plain {
			has_text := false
			for fi in 0 ..< info.field_count {
				name, _, skip := struct_field_name(info, int(fi))
				if skip {
					continue
				}
				field_dst := rawptr(uintptr(fr.dst) + uintptr(info.offsets[fi]))
				if name == markup.TEXT_KEY {
					has_text = true
					if err := fill_scalar(cx, v, field_dst, info.types[fi]); err != nil {
						record_step(cx, tape.Step(tape.Name(info.names[fi])))
						return err
					}
				}
			}
			has_attr := false
			for af in tape.facts_of(cx.doc, v) {
				if af.kind == .Attribute {
					has_attr = true
					break
				}
			}
			if !has_text && !has_attr {
				return refuse_typed(cx, node.lo, .Expected_Object)
			}
			return fill_struct_attributes(cx, fr, info, v)
		}
		return refuse_typed(cx, node.lo, .Expected_Object)
	}

	// Attributes on `.Object` node `v`.
	fill_struct_attributes(cx, fr, info, v) or_return

	// Child members of object `v`: group same-named members in document order.
	Member_Bucket :: struct {
		field_idx: int,
		nodes:     [dynamic]tape.Node_Index,
	}
	buckets, berr := make([dynamic]Member_Bucket, 0, int(info.field_count), cx.tmp)
	if berr != nil {
		return berr
	}
	defer {
		for &b in buckets {
			delete(b.nodes)
		}
		delete(buckets)
	}

	end := tape.node_after(cx.doc, v)
	k := v + 1
	for k < end {
		val := tape.node_after(cx.doc, k)
		mname := read_token_tmp(cx, cx.doc.nodes[k]) or_return
		fidx, found := find_struct_field(info, mname)
		if !found {
			if cx.read.refuse_unknown {
				return refuse_typed(cx, cx.doc.nodes[k].lo, .Unknown_Field, tape.Step(tape.Name(path_token_name(cx, cx.doc.nodes[k]))))
			}
			k = tape.node_after(cx.doc, val)
			continue
		}
		bi := -1
		for &b, idx in buckets {
			if b.field_idx == fidx {
				bi = idx
				break
			}
		}
		if bi < 0 {
			bnodes, nerr := make([dynamic]tape.Node_Index, 0, 2, cx.tmp)
			if nerr != nil {
				return nerr
			}
			if _, aerr := append(&buckets, Member_Bucket{field_idx = fidx, nodes = bnodes}); aerr != nil {
				delete(bnodes)
				return aerr
			}
			bi = len(buckets) - 1
		}
		append(&buckets[bi].nodes, val) or_return
		k = tape.node_after(cx.doc, val)
	}

	for bi := len(buckets) - 1; bi >= 0; bi -= 1 {
		b := &buckets[bi]
		fti := info.types[b.field_idx]
		field_dst := rawptr(uintptr(fr.dst) + uintptr(info.offsets[b.field_idx]))
		if len(b.nodes) > 1 && cx.opts.dups == .Refuse && !is_list_type(fti) {
			return tape.Fault{at = cx.doc.nodes[b.nodes[1] - 1].lo, rules = &RULES, kind = .Duplicate_Key}
		}
		cloned, cerr := make([dynamic]tape.Node_Index, len(b.nodes), cx.tmp)
		if cerr != nil {
			return cerr
		}
		copy(cloned[:], b.nodes[:])
		child_path := push_path_node(cx, fr.path_idx, tape.Step(tape.Name(info.names[b.field_idx])))
		if _, serr := append(stack, Unmarshal_Frame {
			val_node    = b.nodes[0],
			group_elems = cloned,
			dst         = field_dst,
			ti          = fti,
			path_idx    = child_path,
			in_group    = true,
		}); serr != nil {
			delete(cloned)
			return serr
		}
	}
	return nil
}

@(private)
fill_struct_attributes :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Struct, v: tape.Node_Index) -> tape.Error {
	for af in tape.facts_of(cx.doc, v) {
		if af.kind != .Attribute {
			continue
		}
		kt, vt := attribute(cx.doc, af)
		aname := read_token_tmp(cx, kt) or_return
		idx, found := find_struct_field(info, aname)
		if found {
			field_dst := rawptr(uintptr(fr.dst) + uintptr(info.offsets[idx]))
			if err := fill_token_scalar(cx, vt, field_dst, info.types[idx]); err != nil {
				record_step(cx, tape.Step(tape.Name(info.names[idx])))
				return err
			}
		} else if cx.read.refuse_unknown {
			return refuse_typed(cx, af.lo, .Unknown_Field, tape.Step(tape.Name(path_token_name(cx, kt))))
		}
	}
	return nil
}

@(private)
fill_dynamic_array :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Dynamic_Array, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	elems := collect_list_elems(cx, fr) or_return
	n := len(elems)
	raw := (^runtime.Raw_Dynamic_Array)(fr.dst)
	alloc := caller_alloc(cx)
	if raw.allocator.procedure == nil {
		raw.allocator = alloc
		if len(cx.trials) > 0 {
			tr := &cx.trials[len(cx.trials) - 1]
			append(&tr.containers, Trial_Container{raw = raw, is_map = false}) or_return
		}
	} else {
		alloc = raw.allocator
	}
	if n == 0 {
		raw.len = 0
		return nil
	}
	bytes, err := runtime.mem_alloc(n * info.elem_size, info.elem.align, alloc)
	if err != nil {
		return err
	}
	if raw.data != nil {
		runtime.mem_free_with_size(raw.data, raw.cap * info.elem_size, alloc)
	}
	raw.data = raw_data(bytes)
	raw.len = n
	raw.cap = n
	for idx := n - 1; idx >= 0; idx -= 1 {
		el_dst := rawptr(uintptr(raw.data) + uintptr(idx * info.elem_size))
		cpath := push_path_node(cx, fr.path_idx, tape.Step(tape.Index(idx)))
		append(stack, Unmarshal_Frame{val_node = elems[idx], dst = el_dst, ti = info.elem, path_idx = cpath}) or_return
	}
	return nil
}

@(private)
fill_slice :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Slice, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	elems := collect_list_elems(cx, fr) or_return
	n := len(elems)
	raw := (^runtime.Raw_Slice)(fr.dst)
	if n == 0 {
		raw^ = {}
		return nil
	}
	bytes, err := runtime.mem_alloc(n * info.elem_size, info.elem.align, caller_alloc(cx))
	if err != nil {
		return err
	}
	raw.data = raw_data(bytes)
	raw.len = n
	for idx := n - 1; idx >= 0; idx -= 1 {
		el_dst := rawptr(uintptr(raw.data) + uintptr(idx * info.elem_size))
		cpath := push_path_node(cx, fr.path_idx, tape.Step(tape.Index(idx)))
		append(stack, Unmarshal_Frame{val_node = elems[idx], dst = el_dst, ti = info.elem, path_idx = cpath}) or_return
	}
	return nil
}

@(private)
fill_fixed_array :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Array, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	elems := collect_list_elems(cx, fr) or_return
	if len(elems) > info.count {
		return refuse_typed(cx, cx.doc.nodes[elems[info.count]].lo, .Too_Many, tape.Step(tape.Index(info.count)))
	}
	for idx := len(elems) - 1; idx >= 0; idx -= 1 {
		el_dst := rawptr(uintptr(fr.dst) + uintptr(idx * info.elem_size))
		cpath := push_path_node(cx, fr.path_idx, tape.Step(tape.Index(idx)))
		append(stack, Unmarshal_Frame{val_node = elems[idx], dst = el_dst, ti = info.elem, path_idx = cpath}) or_return
	}
	return nil
}

@(private)
collect_list_elems :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame) -> (elems: []tape.Node_Index, err: tape.Error) {
	if fr.in_group {
		return fr.group_elems[:], nil
	}
	node := cx.doc.nodes[fr.val_node]
	if node.kind == .Null {
		return nil, nil
	}
	if node.kind != .Array {
		return nil, refuse_typed(cx, node.lo, .Expected_Array)
	}
	out, cerr := make([dynamic]tape.Node_Index, 0, int(tape.child_count(cx.doc, fr.val_node, node)), cx.tmp)
	if cerr != nil {
		return nil, cerr
	}
	end := tape.node_after(cx.doc, fr.val_node)
	for c := fr.val_node + 1; c < end; c = tape.node_after(cx.doc, c) {
		append(&out, c) or_return
	}
	return out[:], nil
}

@(private)
fill_map :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Map, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	if fr.in_group {
		if len(fr.group_elems) == 0 {
			return nil
		}
		fr.val_node = fr.group_elems[0] if cx.opts.dups == .First else fr.group_elems[len(fr.group_elems) - 1]
	}
	node := cx.doc.nodes[fr.val_node]
	if node.kind == .Null {
		return nil
	}
	if node.kind != .Object {
		return refuse_typed(cx, node.lo, .Expected_Object)
	}
	base_k := runtime.type_info_base(info.key)
	if base_k.id != string {
		return tape.Bad_Option{"map"}
	}
	raw := (^runtime.Raw_Map)(fr.dst)
	if raw.allocator.procedure == nil {
		raw.allocator = caller_alloc(cx)
		if len(cx.trials) > 0 {
			tr := &cx.trials[len(cx.trials) - 1]
			append(&tr.containers, Trial_Container{raw = raw, is_map = true}) or_return
		}
	}
	zero, zerr := make([]u8, info.value.size, cx.tmp)
	if zerr != nil {
		return zerr
	}
	defer delete(zero, cx.tmp)
	Map_Pending :: struct {
		key:      string,
		val_node: tape.Node_Index,
		path_idx: int,
	}
	end := tape.node_after(cx.doc, fr.val_node)
	pending, perr := make([dynamic]Map_Pending, 0, 8, cx.tmp)
	if perr != nil {
		return perr
	}
	defer delete(pending)
	kalloc := caller_alloc(cx)
	for k := fr.val_node + 1; k < end; {
		val := tape.node_after(cx.doc, k)
		kstr := clone_token(cx, cx.doc.nodes[k]) or_return
		kp, _, just_inserted, merr := runtime.__dynamic_map_entry(raw, info.map_info, &kstr, raw_data(zero))
		if merr != nil {
			if !cx.read.borrow_strings {
				delete(kstr, kalloc)
			}
			return runtime.Allocator_Error.Out_Of_Memory
		}
		if !just_inserted {
			if !cx.read.borrow_strings {
				delete(kstr, kalloc)
			}
			if cx.opts.dups == .Refuse {
				return tape.Fault{at = cx.doc.nodes[k].lo, rules = &RULES, kind = .Duplicate_Key}
			}
			if cx.opts.dups != .First {
				existing_key := (^string)(kp)^
				cpath := push_path_node(cx, fr.path_idx, tape.Step(tape.Name(path_token_name(cx, cx.doc.nodes[k]))))
				for &p in pending {
					if p.key == existing_key {
						p.val_node = val
						p.path_idx = cpath
						break
					}
				}
			}
			k = tape.node_after(cx.doc, val)
			continue
		}
		cpath := push_path_node(cx, fr.path_idx, tape.Step(tape.Name(path_token_name(cx, cx.doc.nodes[k]))))
		append(&pending, Map_Pending{key = kstr, val_node = val, path_idx = cpath}) or_return
		k = tape.node_after(cx.doc, val)
	}
	// Resolve final value slot pointers AFTER all map insertions/rehashes have completed.
	for idx := len(pending) - 1; idx >= 0; idx -= 1 {
		p := pending[idx]
		h := info.map_info.key_hasher(&p.key, runtime.map_seed(raw^))
		slot := runtime.__dynamic_map_get(raw, info.map_info, h, &p.key)
		if slot == nil {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		append(stack, Unmarshal_Frame{val_node = p.val_node, dst = slot, ti = info.value, path_idx = p.path_idx}) or_return
	}
	return nil
}

@(private)
fill_pointer :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Pointer, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	v := fr.val_node
	if fr.in_group {
		if len(fr.group_elems) == 0 {
			return nil
		}
		v = fr.group_elems[0] if cx.opts.dups == .First else fr.group_elems[len(fr.group_elems) - 1]
	}
	if cx.doc.nodes[v].kind == .Null {
		(^rawptr)(fr.dst)^ = nil
		return nil
	}
	p := (^rawptr)(fr.dst)^
	if p == nil {
		bytes, err := runtime.mem_alloc(info.elem.size, info.elem.align, caller_alloc(cx))
		if err != nil {
			return err
		}
		p = raw_data(bytes)
		(^rawptr)(fr.dst)^ = p
	}
	append(stack, Unmarshal_Frame{val_node = v, dst = p, ti = info.elem, path_idx = fr.path_idx}) or_return
	return nil
}

@(private)
fill_union :: proc(cx: ^Unmarshal_Cx, fr: ^Unmarshal_Frame, info: ^runtime.Type_Info_Union, stack: ^[dynamic]Unmarshal_Frame) -> tape.Error {
	v := fr.val_node
	if fr.in_group {
		if len(fr.group_elems) == 0 {
			return nil
		}
		v = fr.group_elems[0] if cx.opts.dups == .First else fr.group_elems[len(fr.group_elems) - 1]
	}
	if cx.doc.nodes[v].kind == .Null && !info.no_nil && (!fr.in_group || len(fr.group_elems) <= 1) {
		intrinsics.mem_zero(fr.dst, fr.ti.size)
		return nil
	}
	if len(info.variants) == 0 {
		return refuse_typed(cx, cx.doc.nodes[v].lo, .No_Arm)
	}
	tag_val := u64(1 if !info.no_nil else 0)
	if len(info.variants) == 1 {
		set_union_tag(fr.dst, info, fr.ti.size, tag_val)
		elems := fr.group_elems
		fr.group_elems = nil
		if _, serr := append(stack, Unmarshal_Frame{
			val_node    = v,
			group_elems = elems,
			dst         = fr.dst,
			ti          = info.variants[0],
			path_idx    = fr.path_idx,
			in_group    = fr.in_group,
		}); serr != nil {
			delete(elems)
			return serr
		}
		return nil
	}
	work, werr := make([]u8, fr.ti.size, cx.tmp)
	if werr != nil {
		return werr
	}
	ta, ta_err := new(Trial_Alloc, cx.tmp)
	if ta_err != nil {
		delete(work, cx.tmp)
		return ta_err
	}
	ta^ = {backing = cx.caller}
	ta.blocks.allocator = cx.tmp
	tr := Union_Trial {
		val_node    = v,
		group_elems = fr.group_elems,
		dst         = fr.dst,
		ti          = info,
		ti_size     = fr.ti.size,
		path_idx    = fr.path_idx,
		stack_base  = len(stack),
		next_var    = 1,
		work        = work,
		path_len    = len(cx.path_nodes),
		alloc       = ta,
		in_group    = fr.in_group,
	}
	fr.group_elems = nil
	tr.containers.allocator = cx.tmp
	set_union_tag(raw_data(work), info, fr.ti.size, tag_val)
	if _, aerr := append(&cx.trials, tr); aerr != nil {
		rollback_trial_allocs(&tr, cx.tmp, true)
		delete(work, cx.tmp)
		return aerr
	}
	var_elems, gerr := clone_group_elems(tr.group_elems, cx.tmp)
	if gerr != nil {
		return gerr
	}
	if _, serr := append(stack, Unmarshal_Frame{
		val_node    = v,
		group_elems = var_elems,
		dst         = raw_data(work),
		ti          = info.variants[0],
		path_idx    = fr.path_idx,
		in_group    = tr.in_group,
	}); serr != nil {
		delete(var_elems)
		return serr
	}
	return nil
}

@(private)
fill_scalar :: proc(cx: ^Unmarshal_Cx, v: tape.Node_Index, dst: rawptr, ti: ^runtime.Type_Info) -> tape.Error {
	node := cx.doc.nodes[v]
	if ti.id == typed.Raw {
		lo := node.lo
		hi, ok := close_end(cx.doc, v)
		if !ok || node.kind <= .Plain {
			hi = lo + u64(node.n)
		}
		if lo < hi {
			if cx.read.borrow_strings {
				(^string)(dst)^ = string(cx.doc.src[lo:hi])
			} else {
				(^string)(dst)^ = strings.clone(string(cx.doc.src[lo:hi]), caller_alloc(cx)) or_return
			}
		} else {
			(^string)(dst)^ = ""
		}
		return nil
	}
	return fill_token_scalar(cx, node, dst, ti)
}

@(private)
fill_token_scalar :: proc(cx: ^Unmarshal_Cx, tok: tape.Token, dst: rawptr, ti: ^runtime.Type_Info) -> tape.Error {
	if tok.kind == .Null {
		intrinsics.mem_zero(dst, ti.size)
		return nil
	}
	base := runtime.type_info_base(ti)
	#partial switch info in base.variant {
	case ^runtime.Type_Info_String:
		if tok.kind > .Plain && tok.kind != .Number && tok.kind != .True && tok.kind != .False {
			return refuse_typed(cx, tok.lo, .Expected_String)
		}
		if tok.kind == .True {
			(^string)(dst)^ = "true" if cx.read.borrow_strings else (strings.clone("true", caller_alloc(cx)) or_return)
		} else if tok.kind == .False {
			(^string)(dst)^ = "false" if cx.read.borrow_strings else (strings.clone("false", caller_alloc(cx)) or_return)
		} else {
			(^string)(dst)^ = clone_token(cx, tok) or_return
		}
		return nil
	case ^runtime.Type_Info_Boolean:
		if tok.kind > .Plain {
			return refuse_typed(cx, tok.lo, .Expected_Bool)
		}
		s := read_token_tmp(cx, tok) or_return
		val := false
		if tok.kind == .True || s == "true" {
			val = true
		} else if tok.kind == .False || s == "false" {
			val = false
		} else {
			return refuse_typed(cx, tok.lo, .Expected_Bool)
		}
		switch base.size {
		case 1: (^bool)(dst)^ = val
		case 2: (^b16)(dst)^ = b16(val)
		case 4: (^b32)(dst)^ = b32(val)
		case 8: (^b64)(dst)^ = b64(val)
		}
		return nil
	case ^runtime.Type_Info_Integer:
		if tok.kind > .Plain {
			return refuse_typed(cx, tok.lo, .Expected_Integer)
		}
		s := read_token_tmp(cx, tok) or_return
		n, ok := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
		if !ok {
			return refuse_typed(cx, tok.lo, .Expected_Integer)
		}
		if n.kind == .Float {
			return refuse_typed(cx, tok.lo, .Expected_Integer)
		}
		if n.kind == .Wide {
			return refuse_typed(cx, tok.lo, .Below_Minimum if len(s) > 0 && s[0] == '-' else .Above_Maximum)
		}
		if n.kind == .Uint {
			if !info.signed && base.size == 8 {
				(^u64)(dst)^ = n.bits
				return nil
			}
			return refuse_typed(cx, tok.lo, .Above_Maximum)
		}
		iv := i64(n.bits)
		if info.signed {
			switch base.size {
			case 1:
				if iv < i64(min(i8)) { return refuse_typed(cx, tok.lo, .Below_Minimum) }
				if iv > i64(max(i8)) { return refuse_typed(cx, tok.lo, .Above_Maximum) }
				(^i8)(dst)^ = i8(iv)
			case 2:
				if iv < i64(min(i16)) { return refuse_typed(cx, tok.lo, .Below_Minimum) }
				if iv > i64(max(i16)) { return refuse_typed(cx, tok.lo, .Above_Maximum) }
				(^i16)(dst)^ = i16(iv)
			case 4:
				if iv < i64(min(i32)) { return refuse_typed(cx, tok.lo, .Below_Minimum) }
				if iv > i64(max(i32)) { return refuse_typed(cx, tok.lo, .Above_Maximum) }
				(^i32)(dst)^ = i32(iv)
			case 8:
				(^i64)(dst)^ = iv
			case:
				return tape.Bad_Option{"type"}
			}
		} else {
			if iv < 0 {
				return refuse_typed(cx, tok.lo, .Below_Minimum)
			}
			uv := u64(iv)
			switch base.size {
			case 1:
				if uv > u64(max(u8)) { return refuse_typed(cx, tok.lo, .Above_Maximum) }
				(^u8)(dst)^ = u8(uv)
			case 2:
				if uv > u64(max(u16)) { return refuse_typed(cx, tok.lo, .Above_Maximum) }
				(^u16)(dst)^ = u16(uv)
			case 4:
				if uv > u64(max(u32)) { return refuse_typed(cx, tok.lo, .Above_Maximum) }
				(^u32)(dst)^ = u32(uv)
			case 8:
				(^u64)(dst)^ = uv
			case:
				return tape.Bad_Option{"type"}
			}
		}
		return nil
	case ^runtime.Type_Info_Float:
		if tok.kind > .Plain {
			return refuse_typed(cx, tok.lo, .Expected_Number)
		}
		s := read_token_tmp(cx, tok) or_return
		n, ok := spell.number_strict(transmute([]u8)s, 0, u64(len(s)))
		if !ok {
			return refuse_typed(cx, tok.lo, .Expected_Number)
		}
		fv: f64
		if n.kind == .Int {
			fv = f64(i64(n.bits))
		} else if n.kind == .Uint {
			fv = f64(n.bits)
		} else if n.kind == .Float {
			fv = transmute(f64)n.bits
		} else {
			return refuse_typed(cx, tok.lo, .Below_Minimum if len(s) > 0 && s[0] == '-' else .Above_Maximum)
		}
		if math.is_nan(fv) {
			return refuse_typed(cx, tok.lo, .Expected_Number)
		}
		if math.is_inf(fv) {
			return refuse_typed(cx, tok.lo, .Below_Minimum if fv < 0 else .Above_Maximum)
		}
		switch base.size {
		case 4:
			v32 := f32(fv)
			if math.is_inf(f64(v32)) {
				return refuse_typed(cx, tok.lo, .Below_Minimum if v32 < 0 else .Above_Maximum)
			}
			(^f32)(dst)^ = v32
		case 8:
			(^f64)(dst)^ = fv
		case:
			return tape.Bad_Option{"type"}
		}
		return nil
	case ^runtime.Type_Info_Enum:
		if tok.kind > .Plain {
			return refuse_typed(cx, tok.lo, .Expected_Name)
		}
		s := read_token_tmp(cx, tok) or_return
		for name, i in info.names {
			if name == s {
				val := info.values[i]
				switch base.size {
				case 1: (^i8)(dst)^ = i8(val)
				case 2: (^i16)(dst)^ = i16(val)
				case 4: (^i32)(dst)^ = i32(val)
				case 8: (^i64)(dst)^ = i64(val)
				}
				return nil
			}
		}
		return refuse_typed(cx, tok.lo, .Not_A_Member)
	}
	return refuse_typed(cx, tok.lo, .None)
}

@(private)
read_token_tmp :: proc(cx: ^Unmarshal_Cx, tok: tape.Token) -> (res: string, err: runtime.Allocator_Error) {
	if !tape.text_decodes(tok) && .Held not_in cx.doc.flags {
		return string(cx.doc.src[tok.lo:][:tok.n]), nil
	}
	room := max(tape.text_room(cx.doc, tok), int(tok.n), 64)
	if len(cx.buf) < room {
		resize(&cx.buf, room) or_return
	}
	s, ok := tape.node_text(cx.doc, tok, cx.buf[:])
	return s if ok else "", nil
}

@(private)
path_token_name :: proc(cx: ^Unmarshal_Cx, tok: tape.Token) -> string {
	if !tape.text_decodes(tok) && .Held not_in cx.doc.flags && tok.n > 0 {
		return string(cx.doc.src[tok.lo:][:tok.n])
	}
	if fx := table_key_text(cx.doc.src, tok); len(fx) > 0 {
		return fx
	}
	return string(cx.doc.src[tok.lo:][:tok.n])
}

@(private)
record_step :: proc(cx: ^Unmarshal_Cx, step: tape.Step) {
	if cx.read.path != nil {
		_, _ = inject_at(cx.read.path, 0, step)
	}
}

@(private)
clone_token :: proc(cx: ^Unmarshal_Cx, tok: tape.Token) -> (cloned: string, err: runtime.Allocator_Error) {
	alloc := caller_alloc(cx)
	if !tape.text_decodes(tok) && .Held not_in cx.doc.flags {
		span := cx.doc.src[tok.lo:][:tok.n]
		if cx.read.borrow_strings {
			return string(span), nil
		}
		if len(span) == 0 {
			return "", nil
		}
		out := runtime.mem_alloc_non_zeroed(len(span), 1, alloc) or_return
		copy(out, span)
		return string(out), nil
	}
	room := max(tape.text_room(cx.doc, tok), int(tok.n))
	if room == 0 {
		return "", nil
	}
	if len(cx.buf) < room {
		resize(&cx.buf, room) or_return
	}
	s, ok := tape.node_text(cx.doc, tok, cx.buf[:])
	if !ok || len(s) == 0 {
		return "", nil
	}
	if cx.read.borrow_strings && s == string(cx.doc.src[tok.lo:][:tok.n]) {
		return string(cx.doc.src[tok.lo:][:tok.n]), nil
	}
	return strings.clone(s, alloc)
}

@(private)
is_list_type :: #force_inline proc "contextless" (ti: ^runtime.Type_Info) -> bool {
	b := runtime.type_info_base(ti)
	#partial switch _ in b.variant {
	case ^runtime.Type_Info_Dynamic_Array, ^runtime.Type_Info_Slice, ^runtime.Type_Info_Array:
		return true
	}
	return false
}

@(private)
struct_field_name :: proc(info: ^runtime.Type_Info_Struct, idx: int) -> (name: string, required: bool, skip: bool) {
	tag := info.tags[idx]
	raw_val, has := tag_value(tag, TAG)
	if !has {
		raw_val, has = tag_value(tag, "stury")
	}
	if !has {
		return info.names[idx], false, false
	}
	comma := strings.index_byte(raw_val, ',')
	head := raw_val[:comma] if comma >= 0 else raw_val
	if head == "-" {
		return "", false, true
	}
	name = head if len(head) > 0 else info.names[idx]
	if comma >= 0 && strings.contains(raw_val[comma + 1:], "required") {
		required = true
	}
	return
}

@(private)
tag_value :: proc "contextless" (tag, key: string) -> (string, bool) {
	t := tag
	for len(t) > 0 {
		i := 0
		for i < len(t) && t[i] == ' ' {
			i += 1
		}
		t = t[i:]
		k := 0
		for k < len(t) && t[k] > ' ' && t[k] != ':' && t[k] != '"' {
			k += 1
		}
		if k == 0 || k + 1 >= len(t) || t[k] != ':' || t[k + 1] != '"' {
			return "", false
		}
		name := t[:k]
		t = t[k + 2:]
		e := 0
		for e < len(t) && t[e] != '"' {
			if t[e] == '\\' {
				e += 1
			}
			e += 1
		}
		if e >= len(t) {
			return "", false
		}
		if name == key {
			return t[:e], true
		}
		t = t[e + 1:]
	}
	return "", false
}

@(private)
find_struct_field :: proc(info: ^runtime.Type_Info_Struct, target: string) -> (int, bool) {
	for i in 0 ..< info.field_count {
		name, _, skip := struct_field_name(info, int(i))
		if !skip && name == target {
			return int(i), true
		}
	}
	return -1, false
}

@(private)
refuse_typed :: proc(cx: ^Unmarshal_Cx, at: u64, detail: Typed_Refusal, step: Maybe(tape.Step) = nil) -> tape.Error {
	if s, ok := step.?; ok {
		record_step(cx, s)
	}
	return tape.Fault{at = at, rules = &typed.RULES, kind = .Refused, detail = u8(detail)}
}
