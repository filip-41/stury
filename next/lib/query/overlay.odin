package query

import "base:runtime"
import "core:math"
import "core:math/big"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"

// `Overlay_Ref` (`Kind.Overlay`) integration for `lib/query`.

Overlay_Block :: struct {
	using block: Block,
	ov:          ^edit.Overlay,
	doc_block:   ^Doc_Block,
	owned:       bool,
}

@(private = "file", require_results)
alloc_overlay_block :: proc(h: ^Heap, ov: ^edit.Overlay, db: ^Doc_Block, owned, retain_db: bool) -> (ob: ^Overlay_Block, status: Status) {
	ob_raw := alloc_block(h, size_of(Overlay_Block)) or_return
	if retain_db { db.rc += 1 }
	ob = (^Overlay_Block)(ob_raw)
	ob.ov, ob.doc_block, ob.owned = ov, db, owned
	return ob, .Ok
}

@(require_results)
overlay_value :: proc(h: ^Heap, ov: ^edit.Overlay, doc_block: ^Doc_Block = nil, owned := false) -> (res: Value, status: Status) {
	if ov == nil || ov.base == nil {
		return ABSENT, .Ok
	}
	root_h, rerr := edit.ensure_root(ov)
	if rerr != nil {
		return NULL, overlay_fail_edit(h, rerr)
	}
	db, created_db := doc_block, doc_block == nil
	if created_db {
		b := alloc_block(h, size_of(Doc_Block)) or_return
		db = (^Doc_Block)(b)
		db.doc, db.owned, db.index = ov.base^, false, {allocator = heap_allocator(h)}
	}
	ob, s := alloc_overlay_block(h, ov, db, owned, !created_db)
	if s != .Ok {
		if created_db { free_one(h, .Node, db) }
		return NULL, s
	}
	refresh_overlay_writer(h, ob)
	res = Value{p = ob, n = root_h.idx, kind = .Overlay, held = true}
	if es := ensure_overlay_decoded_scalar(h, ob, root_h); es != .Ok {
		release(h, res)
		return NULL, es
	}
	return res, .Ok
}

@(private = "file")
base_needs_decode :: #force_inline proc "contextless" (doc: ^tape.Document, base: tape.Node_Index) -> (bt: tape.Node, needed: bool) {
	if base == tape.NO_NODE || int(base) >= len(doc.nodes) {
		return {}, false
	}
	bt = doc.nodes[base]
	return bt, (bt.kind == .String || bt.kind == .Plain || bt.kind == .Bytes) && bt.spelling & tape.SPELLING_DECODE != 0
}

@(private)
ensure_overlay_decoded_scalar :: proc(h: ^Heap, ob: ^Overlay_Block, eh: edit.Handle) -> Status {
	if ob == nil || ob.ov == nil || ob.ov.base == nil || eh == edit.NO_HANDLE {
		return .Ok
	}
	n, ok := edit.get_node(ob.ov, eh)
	if !ok || n.state != .Ancestor || n.val.kind != .None {
		return .Ok
	}
	if _, needed := base_needs_decode(ob.ov.base, n.base); needed {
		alloc := heap_allocator(h)
		tk := edit.decode_node_text_tmp(ob.ov.base, n.base, alloc)
		defer edit.free_tmp_text(tk, alloc)
		if cerr := edit.cache_ancestor_text(ob.ov, eh, tk.text); cerr != nil {
			return overlay_fail_edit(h, cerr)
		}
	}
	return .Ok
}

@(private, require_results)
cow_clone_overlay :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	defer release(h, v)
	ob, eh, _, ok := resolve_overlay(v)
	if !ok {
		return NULL, fail_fact_msg(h, "invalid overlay handle for COW")
	}
	alloc := heap_allocator(h)
	handles := [1]edit.Handle{eh}
	cloned_ov, cerr := edit.clone_overlay(ob.ov, handles[:], alloc)
	if cerr != nil {
		return NULL, overlay_fail_edit(h, cerr)
	}
	ov_ptr, aerr := new(edit.Overlay, alloc)
	if aerr != nil {
		edit.destroy(&cloned_ov)
		return NULL, fail_memory(h)
	}
	ov_ptr^ = cloned_ov
	new_ob, s := alloc_overlay_block(h, ov_ptr, ob.doc_block, owned = true, retain_db = true)
	if s != .Ok {
		edit.destroy(ov_ptr)
		free(ov_ptr, alloc)
		return NULL, s
	}
	if h.write_fact_data == ob {
		attach_overlay_writer(h, new_ob)
	}
	return Value{p = new_ob, n = handles[0].idx, kind = .Overlay, held = true}, .Ok
}

@(private, require_results)
ensure_unique_overlay :: proc(h: ^Heap, v: Value, extra_refs := 0) -> (Value, Status) {
	if overlay_is_unique(v, extra_refs) {
		return v, .Ok
	}
	return cow_clone_overlay(h, v)
}

@(require_results)
overlay_from_doc :: proc(h: ^Heap, doc: tape.Document, doc_owned: bool) -> (val: Value, ov: ^edit.Overlay, status: Status) {
	alloc := heap_allocator(h)
	db := (^Doc_Block)(alloc_block(h, size_of(Doc_Block)) or_return)
	db.doc, db.owned, db.index = doc, doc_owned, {allocator = alloc}
	ov_ptr, aerr := new(edit.Overlay, alloc)
	if aerr != nil {
		free_one(h, .Node, db)
		return NULL, nil, fail_memory(h)
	}
	if ierr := edit.init(ov_ptr, &db.doc, alloc); ierr != nil {
		free(ov_ptr, alloc)
		free_one(h, .Node, db)
		return NULL, nil, overlay_fail_edit(h, ierr)
	}
	v, vs := overlay_value(h, ov_ptr, db, owned = true)
	if vs != .Ok {
		edit.destroy(ov_ptr)
		free(ov_ptr, alloc)
		free_one(h, .Node, db)
		return NULL, nil, vs
	}
	db.rc -= 1
	attach_overlay_writer(h, (^Overlay_Block)(v.p))
	return v, ov_ptr, .Ok
}

attach_overlay_writer :: proc(h: ^Heap, ob: ^Overlay_Block) {
	h.write_fact, h.write_fact_data = overlay_write_fact_hook, ob
}

@(private)
refresh_overlay_writer :: #force_inline proc "contextless" (h: ^Heap, ob: ^Overlay_Block) {
	if ob != nil && (h.write_fact == nil || h.write_fact == overlay_write_fact_hook) {
		h.write_fact, h.write_fact_data = overlay_write_fact_hook, ob
	}
}

@(private = "file")
overlay_write_fact_hook :: proc(data: rawptr, h: ^Heap, v: Value, kind: tape.Fact_Kind, attr: string, is_attr: bool, nv: Value) -> (Value, Status) {
	return overlay_write_fact(data, h, v, kind, attr, is_attr, nv, 0)
}

@(private, cold)
overlay_fail_edit :: proc(h: ^Heap, err: edit.Error) -> Status {
	switch e in err {
	case runtime.Allocator_Error: return fail_memory(h)
	case edit.Refusal:            return fail_fact_msg(h, e.detail if len(e.detail) > 0 else "overlay edit refused")
	case tape.Fault:              return fail_fact_msg(h, "invalid syntax in edited value")
	case tape.Exceeded:           return fail_fact_msg(h, "edit exceeded format limits")
	case tape.Bad_Option:         return fail_fact_msg(h, "invalid edit option")
	}
	return fail_fact_msg(h, "overlay edit failed")
}

@(private)
resolve_overlay :: #force_inline proc "contextless" (v: Value) -> (ob: ^Overlay_Block, eh: edit.Handle, n: ^edit.Edit_Node, ok: bool) {
	if v.kind != .Overlay || v.p == nil {
		return nil, edit.NO_HANDLE, nil, false
	}
	ob = (^Overlay_Block)(v.p)
	n, ok = edit.get_node_by_idx(ob.ov, v.n)
	return ob, (n.handle if ok else edit.NO_HANDLE), n, ok
}

overlay_handle :: proc "contextless" (v: Value) -> (ov: ^edit.Overlay, h: edit.Handle, ok: bool) {
	ob, eh, _, valid := resolve_overlay(v)
	return (ob.ov if valid else nil), eh, valid
}

overlay_css_origin :: proc(h: ^Heap, v: Value) -> (mat: Value, d: ^Doc_Block, at: tape.Node_Index, need_release: bool, status: Status) {
	ob, eh, n, valid := resolve_overlay(v)
	if !valid || ob.doc_block == nil {
		return ABSENT, nil, tape.NO_NODE, false, .Ok
	}
	refresh_overlay_writer(h, ob)
	if !ob.ov.dirty {
		bn := edit.node_base_container(n)
		return ABSENT, (ob.doc_block if bn != tape.NO_NODE else nil), bn, false, .Ok
	}
	root_h, rerr := edit.ensure_root(ob.ov)
	if rerr != nil {
		return ABSENT, nil, tape.NO_NODE, false, overlay_fail_edit(h, rerr)
	}
	mat_node := tape.NO_NODE
	mat_doc, merr := edit.materialize_subtree(ob.ov, root_h, tape.ROOT, {
		xml_attrs = true, include_root_comments = true, flatten_xml_arrays = true,
		target_format = ob.doc_block.doc.format, track_handle = eh, tracked_node = &mat_node,
	}, heap_allocator(h))
	if merr != nil {
		return ABSENT, nil, tape.NO_NODE, false, overlay_fail_edit(h, merr)
	}
	dv, ds := document_value(h, mat_doc, owned = true)
	if ds != .Ok {
		tape.destroy_document(&mat_doc)
		return ABSENT, nil, tape.NO_NODE, false, ds
	}
	if dv.kind != .Node {
		release(h, dv)
		return ABSENT, nil, tape.NO_NODE, false, .Ok
	}
	if mat_node == tape.NO_NODE && eh == root_h {
		mat_node = tape.ROOT
	}
	return dv, (^Doc_Block)(dv.p), mat_node, true, .Ok
}

@(private)
overlay_is_unique :: #force_inline proc "contextless" (v: Value, depth := 0) -> bool {
	return v.kind == .Overlay && v.held && v.p != nil && (^Overlay_Block)(v.p).rc <= u32(1 + depth)
}

@(private)
overlay_child_ref :: #force_inline proc "contextless" (ob: ^Overlay_Block, eh: edit.Handle) -> Value {
	ob.rc += 1
	return Value{p = ob, n = eh.idx, kind = .Overlay, held = true}
}

@(private, cold)
overlay_type :: #force_no_inline proc "contextless" (v: Value) -> Type {
	ob, eh, _, ok := resolve_overlay(v)
	return TAPE_NODE_TYPE[edit.node_kind(ob.ov, eh)] if ok else .Null
}

@(private = "file")
overlay_base_node :: #force_inline proc "contextless" (ob: ^Overlay_Block, n: ^edit.Edit_Node) -> (Value, bool) {
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return Value{p = ob.doc_block, n = u32(bn), kind = .Node}, true
	}
	return {}, false
}

@(private, cold)
overlay_unwrap_scalar :: #force_no_inline proc "contextless" (v: Value) -> Value {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return NULL
	}
	if n.state == .Replaced {
		switch n.val.kind {
		case .None, .Null:              return NULL
		case .False:                    return FALSE
		case .True:                     return TRUE
		case .Int:                      return int_value(n.val.i)
		case .Uint:                     return int_value(i64(n.val.u)) if n.val.u <= u64(max(i64)) else double_value(f64(n.val.u))
		case .Float:                    return double_value(n.val.f)
		case .String, .Number_Text, .Raw: return text_borrowed(n.val.text)
		case .Bytes:                    return bytes_borrowed(n.val.raw)
		case .Base_Ref:                 return Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node} if n.val.base_ref != tape.NO_NODE else NULL
		case .Array, .Object:           return v
		}
	}
	if n.state == .Ancestor && n.val.kind == .String {
		if bv, has_base := overlay_base_node(ob, n); has_base && node_token(bv).kind == .Bytes {
			return bytes_borrowed(transmute([]u8)n.val.text)
		}
		return text_borrowed(n.val.text)
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return bv
	}
	return NULL
}

@(private, cold)
overlay_number_literal :: proc "contextless" (v: Value) -> ([]u8, bool) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return nil, false
	}
	if n.state == .Replaced && n.val.kind == .Number_Text {
		return transmute([]u8)n.val.text, true
	}
	if bv, has_base := overlay_base_node(ob, n); has_base && (ob.doc_block.doc.format == nil || .Binary not_in ob.doc_block.doc.format.caps) {
		return node_bytes(bv), true
	}
	return nil, false
}

@(private, cold)
overlay_big_int :: proc(v: Value) -> (u: u64, is_uint: bool, dec: string, ok: bool) {
	ob, _, n, valid := resolve_overlay(v)
	if !valid {
		return
	}
	if n.state == .Replaced {
		if n.val.kind == .Uint && n.val.u > u64(max(i64)) {
			return n.val.u, true, "", true
		}
		if n.val.kind == .Number_Text && spell.is_plain_int_dec(n.val.text) {
			if sn, sok := spell.number_strict(transmute([]u8)n.val.text, 0, u64(len(n.val.text))); !sok || sn.kind != .Int {
				return 0, false, n.val.text, true
			}
		}
		return
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return node_big_int(bv)
	}
	return
}

@(private, cold, require_results)
overlay_number_of :: #force_no_inline proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return NULL, .Ok
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int:   return int_value(n.val.i), .Ok
		case .Uint:
			if n.val.u <= u64(max(i64)) { return int_value(i64(n.val.u)), .Ok }
			return big_from_u64(h, n.val.u)
		case .Float: return double_value(n.val.f), .Ok
		case .Number_Text:
			parsed, pok := parse_number(h, n.val.text, loose = true) or_return
			return (parsed if pok else double_value(math.nan_f64())), .Ok
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return number_of(h, bv)
	}
	return NULL, .Ok
}

@(private, cold)
overlay_as_f64 :: #force_no_inline proc(v: Value) -> f64 {
	ob, _, n, ok := resolve_overlay(v)
	if !ok { return 0 }
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int:   return f64(n.val.i)
		case .Uint:  return f64(n.val.u)
		case .Float: return n.val.f
		case .Number_Text:
			if f, valid := spelled_as_f64(n.val.text); valid { return f }
			return spell.wide_double(transmute([]u8)n.val.text)
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base { return as_f64(bv) }
	return 0
}

@(private, cold)
overlay_as_i64 :: #force_no_inline proc(v: Value) -> (i64, bool) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok { return 0, false }
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int:         return n.val.i, true
		case .Uint:
			if n.val.u <= u64(max(i64)) { return i64(n.val.u), true }
			return 0, false
		case .Float:       return as_i64(double_value(n.val.f))
		case .Number_Text: return spelled_as_i64(n.val.text)
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base { return as_i64(bv) }
	return 0, false
}

@(private, cold)
overlay_is_integer :: #force_no_inline proc(v: Value) -> bool {
	ob, _, n, ok := resolve_overlay(v)
	if !ok { return false }
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int, .Uint:  return true
		case .Float:       return is_integral_f64(n.val.f)
		case .Number_Text: return spelled_is_integer(n.val.text)
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base { return is_integer(bv) }
	return false
}

@(private, cold)
overlay_length :: #force_no_inline proc(h: ^Heap, v: Value) -> int {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok { return 0 }
	refresh_overlay_writer(h, ob)
	if n.state == .Ancestor && n.base != tape.NO_NODE {
		cnt, p, _ := tape.length(reader(ob.doc_block), n.base, heap_allocator(h))
		note_presence(h, p)
		return cnt
	}
	return edit.container_len(ob.ov, eh)
}

@(private, cold, require_results)
overlay_element :: #force_no_inline proc(h: ^Heap, v: Value, i: int) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(v)
	if !ok { return ABSENT, .Ok }
	refresh_overlay_writer(h, ob)
	ch, cb, found := edit.lookup_element(ob.ov, eh, i)
	if !found { return ABSENT, .Ok }
	return overlay_wrap_child(h, ob, ch, cb, eh)
}

@(private, cold, require_results)
overlay_member :: #force_no_inline proc(h: ^Heap, v: Value, key: string) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok { return ABSENT, .Ok }
	refresh_overlay_writer(h, ob)
	if bn := edit.node_base_container(n); bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn)) {
		if n.state == .Ancestor || (n.state == .Replaced && n.val.kind == .Base_Ref) {
			return overlay_group_member(h, ob, bn, eh, edit.is_live_base_node(n), key)
		}
		if n.state == .Container_Delta {
			return overlay_group_member_delta(h, ob, eh, key)
		}
	}
	ch, cb, found := edit.lookup_member(ob.ov, eh, key)
	if !found { return ABSENT, .Ok }
	return overlay_wrap_child(h, ob, ch, cb, eh)
}

@(private = "file")
replaced_array_elems :: #force_inline proc "contextless" (ov: ^edit.Overlay, h: edit.Handle) -> ([]edit.Handle, bool) {
	if h != edit.NO_HANDLE {
		if cn, ok := edit.get_node(ov, h); ok && cn.state == .Replaced && cn.val.kind == .Array {
			return cn.elems[:], true
		}
	}
	return nil, false
}

@(private = "file", require_results)
append_overlay_array_elems :: proc(h: ^Heap, ob: ^Overlay_Block, parent_h: edit.Handle, elems: []edit.Handle, out: Value) -> (res: Value, status: Status) {
	res = out
	if res.kind == .Absent {
		res = make_array(h, len(elems)) or_return
	}
	for elem_h in elems {
		ex, es := overlay_wrap_child(h, ob, elem_h, tape.NO_NODE, parent_h)
		if es != .Ok {
			release(h, res)
			return ABSENT, es
		}
		res = append_grouped(h, res, ex) or_return
	}
	return res, .Ok
}

@(private = "file", require_results)
overlay_group_member :: proc(h: ^Heap, ob: ^Overlay_Block, at: tape.Node_Index, parent_h: edit.Handle, use_by_base: bool, key: string) -> (res: Value, status: Status) {
	c, p := tape.named(reader(ob.doc_block), at, key)
	if p != .Found {
		note_presence(h, p)
		return ABSENT, .Ok
	}
	out := ABSENT
	for {
		_, node, q := tape.next_child(reader(ob.doc_block), &c, .Group)
		if q != .Found {
			note_presence(h, q)
			return out, .Ok
		}
		ch := (ob.ov.by_base[node] or_else edit.NO_HANDLE) if use_by_base else edit.NO_HANDLE
		if use_by_base {
			if elems, is_arr := replaced_array_elems(ob.ov, ch); is_arr {
				return append_overlay_array_elems(h, ob, ch, elems, out)
			}
		}
		x, s := overlay_wrap_child(h, ob, ch, node, parent_h)
		if s != .Ok {
			release(h, out)
			return ABSENT, s
		}
		out = append_grouped(h, out, x) or_return
	}
}

@(private = "file", require_results)
overlay_group_member_delta :: proc(h: ^Heap, ob: ^Overlay_Block, eh: edit.Handle, key: string) -> (res: Value, status: Status) {
	alloc := heap_allocator(h)
	members, owned, merr := edit.effective_members(ob.ov, eh, alloc)
	if merr != nil { return ABSENT, fail_memory(h) }
	defer edit.destroy_effective_members(members, owned, alloc)
	out, replaced_array := ABSENT, false
	for m in members {
		if m.key != key || (replaced_array && m.base_val != tape.NO_NODE && !m.is_inserted) {
			continue
		}
		if elems, is_arr := replaced_array_elems(ob.ov, m.handle); is_arr {
			replaced_array = true
			out = append_overlay_array_elems(h, ob, m.handle, elems, out) or_return
			continue
		}
		x, s := overlay_wrap_child(h, ob, m.handle, m.base_val, eh)
		if s != .Ok {
			release(h, out)
			return ABSENT, s
		}
		out = append_grouped(h, out, x) or_return
	}
	return out, .Ok
}

@(private, require_results)
append_grouped :: proc(h: ^Heap, out, x: Value) -> (Value, Status) {
	if out.kind == .Absent { return x, .Ok }
	res := out
	if res.kind != .Array {
		first := res
		s: Status
		if res, s = make_array(h, 2); s != .Ok {
			release(h, first); release(h, x)
			return ABSENT, s
		}
		if s = append_owned(h, &res, first); s != .Ok {
			release(h, res); release(h, x)
			return ABSENT, s
		}
	}
	if s := append_owned(h, &res, x); s != .Ok {
		release(h, res)
		return ABSENT, s
	}
	return res, .Ok
}

@(private, require_results)
overlay_wrap_child :: proc(h: ^Heap, ob: ^Overlay_Block, ch: edit.Handle, cb: tape.Node_Index, parent_h: edit.Handle) -> (res: Value, status: Status) {
	refresh_overlay_writer(h, ob)
	if ch != edit.NO_HANDLE {
		cn, ok := edit.get_node(ob.ov, ch)
		if !ok { return ABSENT, .Ok }
		if edit.node_kind(ob.ov, ch) >= .Array { return overlay_child_ref(ob, ch), .Ok }
		if cn.state == .Replaced {
			if cn.val.kind == .Base_Ref && cn.val.base_ref != tape.NO_NODE {
				if len(cn.facts) == 0 && cn.base == cn.val.base_ref {
					return node_value(h, ob.doc_block, cn.val.base_ref, force_origin = true)
				}
				if bt, needed := base_needs_decode(&ob.doc_block.doc, cn.val.base_ref); needed {
					alloc := heap_allocator(h)
					tk := edit.decode_node_text_tmp(ob.ov.base, cn.val.base_ref, alloc)
					defer edit.free_tmp_text(tk, alloc)
					br := cn.val.base_ref
					val := edit.val_bytes(transmute([]u8)tk.text) if bt.kind == .Bytes else edit.val_string(tk.text)
					if serr := edit.set(ob.ov, ch, val); serr != nil { return NULL, overlay_fail_edit(h, serr) }
					if cn2, ok2 := edit.get_node(ob.ov, ch); ok2 { cn2.base_ref = br }
				}
			}
			return overlay_child_ref(ob, ch), .Ok
		}
		if len(cn.facts) > 0 {
			ensure_overlay_decoded_scalar(h, ob, ch) or_return
			return overlay_child_ref(ob, ch), .Ok
		}
		if cn.base != tape.NO_NODE { return node_value(h, ob.doc_block, cn.base, force_origin = true) }
		return overlay_child_ref(ob, ch), .Ok
	}
	if cb != tape.NO_NODE {
		if ob.doc_block.doc.nodes[cb].kind >= .Array {
			if pn, pok := edit.get_node(ob.ov, parent_h); pok && !edit.is_live_base_node(pn) {
				return node_value(h, ob.doc_block, cb, force_origin = true)
			}
			nh, herr := edit.handle_for_base(ob.ov, cb, parent_h)
			if herr != nil { return NULL, overlay_fail_edit(h, herr) }
			return overlay_child_ref(ob, nh), .Ok
		}
		return node_value(h, ob.doc_block, cb, force_origin = true)
	}
	return ABSENT, .Ok
}

@(private, require_results)
overlay_promote_fact_target :: proc(h: ^Heap, parent_v, step, cur: Value) -> (res: Value, status: Status) {
	ob, ph, pn, ok := resolve_overlay(parent_v)
	if !ok { return cur, .Ok }
	refresh_overlay_writer(h, ob)
	if cur.kind == .Overlay && cur.p == parent_v.p { return cur, .Ok }
	ch, cb, found, is_str, idx := edit.NO_HANDLE, tape.NO_NODE, false, type_of(step) == .String, 0
	if is_str {
		ch, cb, found = edit.lookup_member(ob.ov, ph, text_of(step))
	} else if type_of(step) == .Number {
		if i, iok := element_index(step); iok {
			idx = i + edit.container_len(ob.ov, ph) if i < 0 else i
			ch, cb, found = edit.lookup_element(ob.ov, ph, idx)
		}
	}
	if !found { return cur, .Ok }
	target_h := ch
	if target_h == edit.NO_HANDLE && cb != tape.NO_NODE {
		herr: edit.Error
		if edit.is_live_base_node(pn) {
			target_h, herr = edit.handle_for_base(ob.ov, cb, ph)
		} else if is_str {
			target_h, herr = edit.set_member(ob.ov, ph, text_of(step), edit.val_base_ref(cb))
		} else {
			target_h, herr = edit.set_element(ob.ov, ph, idx, edit.val_base_ref(cb))
		}
		if herr != nil { release(h, cur); return NULL, overlay_fail_edit(h, herr) }
	}
	if target_h == edit.NO_HANDLE { return cur, .Ok }
	if es := ensure_overlay_decoded_scalar(h, ob, target_h); es != .Ok {
		release(h, cur)
		return NULL, es
	}
	release(h, cur)
	return overlay_child_ref(ob, target_h), .Ok
}

@(private, cold)
overlay_has_member :: #force_no_inline proc(h: ^Heap, v: Value, key: string) -> bool {
	ob, eh, _, ok := resolve_overlay(v)
	if !ok { return false }
	refresh_overlay_writer(h, ob)
	_, _, found := edit.lookup_member(ob.ov, eh, key)
	return found
}

@(private)
put_key_str :: proc(h: ^Heap, out: ^Value, key: string, val: Value) -> Status {
	kv, ks := text_value(h, key)
	if ks != .Ok {
		release(h, val)
		return ks
	}
	return object_put(h, out, kv, val)
}

@(private, cold, require_results)
overlay_built :: #force_no_inline proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok { return NULL, .Ok }
	refresh_overlay_writer(h, ob)
	alloc, k := heap_allocator(h), edit.node_kind(ob.ov, eh)
	if k == .Array {
		elems, eerr := edit.effective_elements(ob.ov, eh, alloc)
		if eerr != nil { return NULL, fail_memory(h) }
		defer delete(elems, alloc)
		out := make_array(h, len(elems)) or_return
		defer if status != .Ok { release(h, out) }
		for e in elems {
			append_owned(h, &out, overlay_wrap_child(h, ob, e.handle, e.base, eh) or_return) or_return
		}
		return out, .Ok
	}
	if k != .Object { return retain(v), .Ok }
	members, owned_keys, merr := edit.effective_members(ob.ov, eh, alloc)
	if merr != nil { return NULL, fail_memory(h) }
	defer edit.destroy_effective_members(members, owned_keys, alloc)
	bn := edit.node_base_container(n)
	grouped := bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn))
	out := make_object(h, len(members)) or_return
	defer if status != .Ok { release(h, out) }
	replaced_keys := make([dynamic]string, 0, 2, alloc)
	defer delete(replaced_keys)
	for m in members {
		if grouped && m.base_val != tape.NO_NODE && !m.is_inserted {
			skip := false
			for rk in replaced_keys {
				if rk == m.key { skip = true; break }
			}
			if skip { continue }
		}
		if grouped {
			if elems, is_arr := replaced_array_elems(ob.ov, m.handle); is_arr {
				append(&replaced_keys, m.key)
				put_key_str(h, &out, m.key, append_overlay_array_elems(h, ob, m.handle, elems, ABSENT) or_return) or_return
				continue
			}
		}
		cv := overlay_wrap_child(h, ob, m.handle, m.base_val, eh) or_return
		if grouped {
			if prev, ps := member(h, out, m.key); ps == .Ok && prev.kind != .Absent {
				cv = append_grouped(h, prev, cv) or_return
			}
		}
		put_key_str(h, &out, m.key, cv) or_return
	}
	return out, .Ok
}

@(private, cold, require_results)
overlay_fact_read :: #force_no_inline proc(h: ^Heap, v: Value, kind: tape.Fact_Kind, attr: string, is_attr: bool) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok { return NULL, .Ok }
	refresh_overlay_writer(h, ob)
	bn := edit.node_base_container(n)

	if is_attr {
		if fo, fok := edit.find_fact_override(ob.ov, eh, .Attribute, attr); fok {
			if fo.deleted || len(fo.values) == 0 { return NULL, .Ok }
			return text_value(h, fo.values[0])
		}
		if bn != tape.NO_NODE { return read_attributes(h, ob.doc_block, bn, attr, true) }
		return NULL, .Ok
	}
	if kind == .Attribute {
		base_attrs := read_attributes(h, ob.doc_block, bn, "", false) or_return if bn != tape.NO_NODE else NULL
		has_override := false
		for f in n.facts {
			if f.kind == .Attribute { has_override = true; break }
		}
		if !has_override { return base_attrs, .Ok }
		out := base_attrs
		if out.kind != .Object {
			release(h, out)
			out = make_object(h, 4) or_return
		}
		defer if status != .Ok { release(h, out) }
		for f in n.facts {
			if f.kind != .Attribute { continue }
			if f.deleted || len(f.values) == 0 {
				object_delete(h, &out, f.attr) or_return
			} else {
				put_key_str(h, &out, f.attr, text_value(h, f.values[0]) or_return) or_return
			}
		}
		if length_of(h, out) == 0 {
			release(h, out)
			return NULL, .Ok
		}
		return out, .Ok
	}
	if fo, fok := edit.find_fact_override(ob.ov, eh, kind); fok {
		if fo.deleted { return NULL, .Ok }
		#partial switch kind {
		case .Comment, .Comment_Inline, .Comment_Foot:
			if len(fo.values) == 0 { return NULL, .Ok }
			arr := make_array(h, len(fo.values)) or_return
			defer if status != .Ok { release(h, arr) }
			for line in fo.values {
				append_owned(h, &arr, text_value(h, line) or_return) or_return
			}
			return arr, .Ok
		case .Tag:
			if num, has_num := fo.num_tag.?; has_num {
				if num <= u64(max(i64)) { return int_value(i64(num)), .Ok }
				return big_from_u64(h, num)
			}
			if len(fo.values) > 0 { return text_value(h, fo.values[0]) }
			return NULL, .Ok
		case .Style, .Anchor, .Alias:
			if len(fo.values) > 0 { return text_value(h, fo.values[0]) }
			return NULL, .Ok
		}
	}
	if bn != tape.NO_NODE { return read_base_node_fact(h, ob.doc_block, bn, kind, attr, is_attr) }
	return NULL, .Ok
}

@(private = "file")
extract_u64_tag :: proc(nv: Value) -> (u: u64, ok: bool) {
	if i, iok := as_i64(nv); iok { return u64(i), i >= 0 }
	if nv.kind == .Big {
		x := &(^Big_Block)(nv.p).value
		if x.sign == .Negative { return 0, false }
		if bits, _ := big.count_bits(x); bits > 64 { return 0, false }
		v, err := big.int_get_u64(x)
		return v, err == nil
	}
	if nu, is_uint, dec, is_big := node_big_int(nv); is_big {
		if is_uint { return nu, true }
		if len(dec) == 0 || dec[0] == '-' || len(dec) > 20 { return 0, false }
		val: u64
		for c in transmute([]u8)dec {
			if c < '0' || c > '9' { return 0, false }
			d := u64(c - '0')
			if val > (max(u64) - d) / 10 { return 0, false }
			val = val * 10 + d
		}
		return val, true
	}
	return 0, false
}

overlay_write_fact :: proc(data: rawptr, h: ^Heap, v: Value, kind: tape.Fact_Kind, attr: string, is_attr: bool, nv: Value, overlay_depth := 0) -> (res: Value, status: Status) {
	defer release(h, nv)
	cur_v := v
	defer if status != .Ok { release(h, cur_v) }
	ob: ^Overlay_Block
	eh: edit.Handle

	if cur_v.kind == .Overlay {
		cur_v = ensure_unique_overlay(h, cur_v, overlay_depth) or_return
		ov_ob, ov_eh, _, ok := resolve_overlay(cur_v)
		if !ok { return NULL, fail_fact_msg(h, "invalid overlay handle for fact write") }
		ob, eh = ov_ob, ov_eh
		refresh_overlay_writer(h, ob)
	} else {
		ob = (^Overlay_Block)(data)
		if ob == nil || ob.ov == nil { return NULL, fail_fact_msg(h, "fact writes require an overlay") }
		d, at, from_doc := value_doc_origin(cur_v, true)
		if !from_doc || &d.doc != ob.ov.base { return NULL, fail_fact_msg(h, "cannot write fact on a value with no overlay node") }
		ov_val := ABSENT
		if ob.rc > 0 {
			root_h, rerr := edit.ensure_root(ob.ov)
			if rerr != nil { return NULL, overlay_fail_edit(h, rerr) }
			ov_val = cow_clone_overlay(h, overlay_child_ref(ob, root_h)) or_return
			ob = (^Overlay_Block)(ov_val.p)
		}
		herr: edit.Error
		if eh, herr = edit.handle_for_base(ob.ov, at); herr != nil {
			release(h, ov_val)
			return NULL, overlay_fail_edit(h, herr)
		}
		if en, eok := edit.get_node(ob.ov, eh); eok && en.state == .Replaced && en.val.kind == .Null && (cur_v.kind == .String || cur_v.kind == .Bytes) {
			ev := edit.val_bytes(bytes_of(cur_v)) if cur_v.kind == .Bytes else edit.val_string(text_of(cur_v))
			if serr := edit.set(ob.ov, eh, ev); serr != nil {
				release(h, ov_val)
				return NULL, overlay_fail_edit(h, serr)
			}
		}
		if ov_val.kind == .Overlay {
			release(h, cur_v)
			cur_v = ov_val
			cur_v.n = eh.idx
		}
	}

	nt := type_of(nv)
	edit_err: edit.Error
	switch {
	case nt == .Null || nt == .Absent:
		edit_err = edit.del_fact(ob.ov, eh, kind, attr if is_attr else "")
	case is_attr:
		if msg, bad := validate_fact_write_group1(ob.ov, .Attribute, nil, attr); bad { return NULL, fail_fact_msg(h, msg) }
		vals := [1]string{text_of(nv)}
		edit_err = edit.set_fact(ob.ov, eh, .Attribute, vals[:], attr)
	case kind == .Comment || kind == .Comment_Inline || kind == .Comment_Foot:
		if nt == .String {
			vals := [1]string{text_of(nv)}
			if msg, bad := validate_fact_write_group1(ob.ov, kind, vals[:], ""); bad { return NULL, fail_fact_msg(h, msg) }
			edit_err = edit.set_fact(ob.ov, eh, kind, vals[:], padded = true)
		} else if nt == .Array {
			alloc, n := heap_allocator(h), length_of(h, nv)
			lines := make([dynamic]string, 0, n, alloc)
			owned_vals := make([dynamic]Value, 0, n, alloc)
			defer {
				for lv in owned_vals { release(h, lv) }
				delete(owned_vals)
				delete(lines)
			}
			c := cursor_open(h, nv) or_return
			defer cursor_close(&c)
			for {
				_, elem, more := cursor_next(h, &c) or_return
				if !more { break }
				if _, aerr := append(&owned_vals, elem); aerr != nil { release(h, elem); return NULL, fail_memory(h) }
				if _, aerr := append(&lines, text_of(elem)); aerr != nil { return NULL, fail_memory(h) }
			}
			if len(lines) == 0 {
				edit_err = edit.del_fact(ob.ov, eh, kind)
			} else if msg, bad := validate_fact_write_group1(ob.ov, kind, lines[:], ""); bad {
				return NULL, fail_fact_msg(h, msg)
			} else {
				edit_err = edit.set_fact(ob.ov, eh, kind, lines[:], padded = true)
			}
		}
	case kind == .Tag && nt == .Number:
		u, uok := extract_u64_tag(nv)
		if !uok { return NULL, fail_fact_msg(h, "numeric tag must be an unsigned 64-bit integer") }
		edit_err = edit.set_fact(ob.ov, eh, .Tag, nil, num_tag = u)
	case:
		vals := [1]string{text_of(nv)}
		edit_err = edit.set_fact(ob.ov, eh, kind, vals[:])
	}

	if edit_err != nil { return NULL, overlay_fail_edit(h, edit_err) }
	ensure_overlay_decoded_scalar(h, ob, eh) or_return
	if cur_v.kind == .Overlay { return cur_v, .Ok }
	release(h, cur_v)
	return overlay_child_ref(ob, eh), .Ok
}

@(private = "file")
validate_fact_write_group1 :: proc "contextless" (ov: ^edit.Overlay, kind: tape.Fact_Kind, vals: []string, attr: string) -> (msg: string, bad: bool) {
	if ov == nil || ov.base == nil || ov.base.format == nil { return "", false }
	fname := ov.base.format.name
	if kind == .Attribute {
		if len(attr) == 0 { return "attribute name cannot be empty", true }
		if fname == "xml" || fname == "html" {
			for b in transmute([]u8)attr {
				if b <= 0x20 || b == '=' || b == '"' || b == '\'' || b == '<' || b == '>' || b == '/' {
					return "invalid markup attribute name", true
				}
			}
		}
		return "", false
	}
	if kind == .Comment || kind == .Comment_Inline || kind == .Comment_Foot {
		if fname == "xml" || fname == "html" {
			for line in vals {
				if len(line) > 0 && line[len(line) - 1] == '-' { return "XML comment cannot end with '-'", true }
				for i := 0; i + 1 < len(line); i += 1 {
					if line[i] == '-' && line[i + 1] == '-' { return "XML comment cannot contain '--'", true }
				}
			}
		} else if len(fname) >= 4 && fname[:4] == "toml" {
			for line in vals {
				for c in transmute([]u8)line {
					if (c < 0x20 && c != '\t') || c == 0x7f { return "TOML comment contains disallowed control byte", true }
				}
			}
		}
	}
	return "", false
}

@(private, require_results)
write_value_to_handle :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, root_v: Value) -> edit.Error {
	if done, err := try_set_leaf_or_ref(h, ov, target, root_v); done || err != nil {
		return err
	}
	return write_container_to_handle(h, ov, target, root_v)
}

@(private = "file")
overlay_same_base_ref :: proc "contextless" (ov: ^edit.Overlay, v: Value) -> (base: tape.Node_Index, src_n: ^edit.Edit_Node, ok: bool) {
	if v.kind == .Node && &(^Doc_Block)(v.p).doc == ov.base {
		return tape.Node_Index(v.n), nil, true
	}
	if v.kind == .Overlay {
		if ob, _, n, valid := resolve_overlay(v); valid && ob.ov.base == ov.base {
			if n.state == .Ancestor && n.base != tape.NO_NODE && !edit.base_subtree_has_edits(ob.ov, n.base) {
				return n.base, n, true
			}
			if n.state == .Replaced && n.val.kind == .Base_Ref {
				return n.val.base_ref, n, true
			}
		}
	}
	return tape.NO_NODE, nil, false
}

@(private)
is_leaf_or_provenance :: proc "contextless" (ov: ^edit.Overlay, v: Value) -> bool {
	if _, src_n, ok := overlay_same_base_ref(ov, v); ok && (src_n == nil || len(src_n.facts) == 0) {
		return true
	}
	t := type_of(v)
	return t != .Array && t != .Object
}

@(private)
copy_overlay_node_facts :: proc(ov: ^edit.Overlay, dst: edit.Handle, src_n: ^edit.Edit_Node) -> edit.Error {
	for f in src_n.facts {
		if f.deleted {
			edit.del_fact(ov, dst, f.kind, f.attr) or_return
		} else {
			edit.set_fact(ov, dst, f.kind, f.values, f.attr, f.num_tag, f.padded) or_return
		}
	}
	return nil
}

@(private)
try_set_leaf_or_ref :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, v: Value) -> (done: bool, err: edit.Error) {
	if base, src_n, ok := overlay_same_base_ref(ov, v); ok {
		edit.set(ov, target, edit.val_base_ref(base)) or_return
		if src_n != nil { copy_overlay_node_facts(ov, target, src_n) or_return }
		return true, nil
	}
	switch type_of(v) {
	case .Absent, .Null: edit.set(ov, target, edit.val_null()) or_return
	case .False:         edit.set(ov, target, edit.val_bool(false)) or_return
	case .True:          edit.set(ov, target, edit.val_bool(true)) or_return
	case .Number:
		if i, iok := as_i64(v); iok {
			edit.set(ov, target, edit.val_int(i)) or_return
		} else if v.kind == .Big || is_integer(v) {
			buf := make([dynamic]u8, 0, 32, heap_allocator(h))
			defer delete(buf)
			if write_json(h, &buf, v) != .Ok { return true, runtime.Allocator_Error.Out_Of_Memory }
			edit.set(ov, target, edit.val_number_text(string(buf[:]))) or_return
		} else {
			edit.set(ov, target, edit.val_float(as_f64(v))) or_return
		}
	case .String:        edit.set(ov, target, edit.val_string(text_of(v))) or_return
	case .Bytes:         edit.set(ov, target, edit.val_bytes(bytes_of(v))) or_return
	case .Array, .Object: return false, nil
	}
	if v.kind == .Overlay {
		if _, _, sn, sok := resolve_overlay(v); sok && len(sn.facts) > 0 {
			copy_overlay_node_facts(ov, target, sn) or_return
		}
	}
	return true, nil
}

@(private)
write_container_to_handle :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, root_v: Value) -> edit.Error {
	alloc := heap_allocator(h)
	Frame :: struct {
		v:               Value,
		c:               Cursor,
		is_obj, has_key: bool,
		elems:           [dynamic]edit.Handle,
		entries:         [dynamic]edit.Object_Entry,
		key:             string,
	}
	drop_frame :: proc(h: ^Heap, alloc: runtime.Allocator, f: ^Frame) {
		cursor_close(&f.c)
		release(h, f.v)
		delete(f.elems)
		for e in f.entries { delete(e.key, alloc) }
		delete(f.entries)
		if f.has_key { delete(f.key, alloc) }
	}
	push_frame :: proc(h: ^Heap, alloc: runtime.Allocator, stack: ^[dynamic]Frame, v: Value, key: string, has_key: bool) -> edit.Error {
		c, s := cursor_open(h, v)
		if s != .Ok {
			release(h, v)
			if has_key { delete(key, alloc) }
			return runtime.Allocator_Error.Out_Of_Memory
		}
		f := Frame{v = v, c = c, is_obj = type_of(v) == .Object, elems = make([dynamic]edit.Handle, alloc), entries = make([dynamic]edit.Object_Entry, alloc), key = key, has_key = has_key}
		if _, aerr := append(stack, f); aerr != nil {
			drop_frame(h, alloc, &f)
			return aerr
		}
		return nil
	}
	attach_child :: proc(alloc: runtime.Allocator, f: ^Frame, key: string, has_key: bool, ch: edit.Handle) -> edit.Error {
		if f.is_obj {
			if _, aerr := append(&f.entries, edit.Object_Entry{key = key, value = ch}); aerr != nil {
				delete(key, alloc)
				return aerr
			}
			return nil
		}
		if has_key { delete(key, alloc) }
		if _, aerr := append(&f.elems, ch); aerr != nil { return aerr }
		return nil
	}
	stack := make([dynamic]Frame, 0, 16, alloc)
	defer {
		for &f in stack { drop_frame(h, alloc, &f) }
		delete(stack)
	}
	push_frame(h, alloc, &stack, retain(root_v), "", false) or_return

	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		k, x, more, ns := cursor_next(h, &f.c)
		if ns != .Ok { return runtime.Allocator_Error.Out_Of_Memory }
		if !more {
			is_root := len(stack) == 1
			val := edit.val_object(f.entries[:]) if f.is_obj else edit.val_array(f.elems[:])
			nh := target
			if is_root { edit.set(ov, target, val) or_return } else { nh = edit.new_node(ov, val) or_return }
			pk, has_pk := f.key, f.has_key
			f.has_key = false
			drop_frame(h, alloc, f)
			pop(&stack)
			if is_root { return nil }
			attach_child(alloc, &stack[len(stack) - 1], pk, has_pk, nh) or_return
			continue
		}
		ks: string
		if f.is_obj {
			ks_buf, kerr := make([]u8, len(text_of(k)), alloc)
			if kerr != nil { release(h, k); release(h, x); return kerr }
			copy(ks_buf, text_of(k))
			ks = string(ks_buf)
			release(h, k)
		}
		if is_leaf_or_provenance(ov, x) {
			ch, ch_err := edit.new_node(ov, edit.val_null())
			if ch_err != nil {
				if f.is_obj { delete(ks, alloc) }
				release(h, x)
				return ch_err
			}
			_, lerr := try_set_leaf_or_ref(h, ov, ch, x)
			release(h, x)
			if lerr != nil {
				if f.is_obj { delete(ks, alloc) }
				return lerr
			}
			attach_child(alloc, f, ks, f.is_obj, ch) or_return
			continue
		}
		push_frame(h, alloc, &stack, x, ks, f.is_obj) or_return
	}
	return nil
}

@(require_results)
reconcile_overlay :: proc(h: ^Heap, ov: ^edit.Overlay, result: Value) -> edit.Error {
	if ov == nil || ov.base == nil { return edit.refuse(.No_Document, "reconcile_overlay requires a built overlay") }
	if ov.unlinked_parents { edit.ensure_linked(ov) or_return }
	return reconcile_node(h, ov, edit.ensure_root(ov) or_return, tape.ROOT, result)
}

@(private = "file")
is_same_provenance :: proc "contextless" (ov: ^edit.Overlay, xv: Value, target_h: edit.Handle, base_node: tape.Node_Index) -> bool {
	if xv.kind == .Node && base_node != tape.NO_NODE && &(^Doc_Block)(xv.p).doc == ov.base && tape.Node_Index(xv.n) == base_node {
		return !edit.base_subtree_has_edits(ov, base_node)
	}
	if xv.kind == .Overlay {
		if ob, _, en, ok := resolve_overlay(xv); ok && ob.ov == ov {
			if target_h != edit.NO_HANDLE && xv.n == target_h.idx { return true }
			if target_h != edit.NO_HANDLE {
				if tn, tok := edit.get_node(ov, target_h); tok && (tn.state != .Ancestor || tn.has_edits || len(tn.facts) > 0) {
					return false
				}
			}
			if base_node != tape.NO_NODE && en.base == base_node && en.state == .Ancestor && !en.has_edits && len(en.facts) == 0 {
				return !edit.base_subtree_has_edits(ov, base_node)
			}
		}
	}
	return false
}

@(private = "file")
Reconcile_Pair :: struct {
	target:    edit.Handle,
	base_node: tape.Node_Index,
	val:       Value,
}

@(private = "file")
reconcile_push_child :: proc(h: ^Heap, ov: ^edit.Overlay, stack: ^[dynamic]Reconcile_Pair, parent_h, ch: edit.Handle, base_node: tape.Node_Index, ev: Value) -> edit.Error {
	if is_same_provenance(ov, ev, ch, base_node) {
		release(h, ev)
		return nil
	}
	target := ch
	if target == edit.NO_HANDLE {
		herr: edit.Error
		if target, herr = edit.handle_for_base(ov, base_node, parent_h); herr != nil {
			release(h, ev)
			return herr
		}
	}
	if _, aerr := append(stack, Reconcile_Pair{target = target, base_node = base_node, val = ev}); aerr != nil {
		release(h, ev)
		return aerr
	}
	return nil
}

@(private = "file")
reconcile_node :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, base_node: tape.Node_Index, val: Value) -> edit.Error {
	alloc := heap_allocator(h)
	stack := make([dynamic]Reconcile_Pair, 0, 16, alloc)
	defer {
		for p in stack { release(h, p.val) }
		delete(stack)
	}
	if _, aerr := append(&stack, Reconcile_Pair{target = target, base_node = base_node, val = retain(val)}); aerr != nil {
		release(h, val)
		return aerr
	}

	for len(stack) > 0 {
		cur := pop(&stack)
		defer release(h, cur.val)
		if is_same_provenance(ov, cur.val, cur.target, cur.base_node) { continue }
		cur_kind, val_type := edit.node_kind(ov, cur.target), type_of(cur.val)

		if cur_kind == .Object && val_type == .Object {
			eff, owned_keys, merr := edit.effective_members(ov, cur.target, alloc)
			if merr != nil { return merr }
			defer edit.destroy_effective_members(eff, owned_keys, alloc)
			Eff_Info :: struct { handle: edit.Handle, base_val: tape.Node_Index }
			Eff_Group :: struct { array_h: edit.Handle, has_base: bool, first_base_idx: int, items: [dynamic]Eff_Info }
			eff_groups := make(map[string]Eff_Group, len(eff), alloc)
			defer {
				for _, g in eff_groups { delete(g.items) }
				delete(eff_groups)
			}
			grouped := ov.base.format != nil && ov.base.format.dups == .Group
			replaced_arr := make(map[string]bool, 4, alloc)
			defer delete(replaced_arr)
			for m in eff {
				g, g_exists := eff_groups[m.key]
				if !g_exists { g = {array_h = edit.NO_HANDLE, first_base_idx = -1} }
				if m.base_val != tape.NO_NODE && !m.is_inserted && !g.has_base { g.has_base, g.first_base_idx = true, m.base_idx }
				if grouped && m.base_val != tape.NO_NODE && !m.is_inserted && replaced_arr[m.key] { eff_groups[m.key] = g; continue }
				if grouped {
					if elems, is_arr := replaced_array_elems(ov, m.handle); is_arr {
						replaced_arr[m.key], g.array_h = true, m.handle
						if g.items.allocator.procedure == nil { g.items = make([dynamic]Eff_Info, 0, len(elems), alloc) } else { clear(&g.items) }
						for eh in elems { append(&g.items, Eff_Info{handle = eh, base_val = tape.NO_NODE}) or_return }
						eff_groups[m.key] = g
						continue
					}
				}
				if g.items.allocator.procedure == nil { g.items = make([dynamic]Eff_Info, 0, 1, alloc) }
				append(&g.items, Eff_Info{handle = m.handle, base_val = m.base_val}) or_return
				eff_groups[m.key] = g
			}
			kept := make(map[string]bool, len(eff_groups), alloc)
			defer delete(kept)
			vc, vs := cursor_open(h, cur.val)
			if vs != .Ok { return runtime.Allocator_Error.Out_Of_Memory }
			defer cursor_close(&vc)
			for {
				kv, xv, more, ns := cursor_next(h, &vc)
				if ns != .Ok { return runtime.Allocator_Error.Out_Of_Memory }
				if !more { break }
				defer { release(h, kv); release(h, xv) }
				kname := text_of(kv)
				if g, exists := eff_groups[kname]; exists {
					infos := g.items[:]
					kept[kname] = true
					if grouped && (g.array_h != edit.NO_HANDLE || len(infos) > 1 || (type_of(xv) == .Array && len(infos) == 1 && edit.node_kind(ov, infos[0].handle) != .Array)) {
						new_arr := type_of(xv) == .Array
						if !new_arr && (g.array_h != edit.NO_HANDLE || len(infos) > 1) {
							collapse_grouped_xml_member(h, ov, cur.target, kname, g.first_base_idx, g.has_base, g.array_h, xv) or_return
							continue
						}
						if new_n := length_of(h, xv) if new_arr else 1; new_n == len(infos) {
							for i in 0 ..< new_n {
								ev := retain(xv)
								if new_arr {
									es: Status
									if ev, es = element(h, xv, i); es != .Ok { return runtime.Allocator_Error.Out_Of_Memory }
								}
								reconcile_push_child(h, ov, &stack, cur.target, infos[i].handle, infos[i].base_val, ev) or_return
							}
							continue
						}
						ch := g.array_h if g.array_h != edit.NO_HANDLE else infos[0].handle
						if ch == edit.NO_HANDLE && infos[0].base_val != tape.NO_NODE {
							ch = edit.handle_for_base(ov, infos[0].base_val, cur.target) or_return
						}
						write_value_to_handle(h, ov, ch, xv) or_return
						continue
					}
					reconcile_push_child(h, ov, &stack, cur.target, infos[0].handle, infos[0].base_val, retain(xv)) or_return
				} else {
					ch := edit.set_member(ov, cur.target, kname, edit.val_null()) or_return
					write_value_to_handle(h, ov, ch, xv) or_return
				}
			}
			for bk in eff_groups {
				if !kept[bk] { edit.del_member(ov, cur.target, bk) or_return }
			}
			continue
		}
		if cur_kind == .Array && val_type == .Array {
			eff := edit.effective_elements(ov, cur.target, alloc) or_return
			defer delete(eff, alloc)
			new_len := length_of(h, cur.val)
			for i in 0 ..< min(len(eff), new_len) {
				xv, xs := element(h, cur.val, i)
				if xs != .Ok { return runtime.Allocator_Error.Out_Of_Memory }
				reconcile_push_child(h, ov, &stack, cur.target, eff[i].handle, eff[i].base, xv) or_return
			}
			for i := len(eff) - 1; i >= new_len; i -= 1 { edit.del_element(ov, cur.target, i) or_return }
			for i in len(eff) ..< new_len {
				xv, xs := element(h, cur.val, i)
				if xs != .Ok { return runtime.Allocator_Error.Out_Of_Memory }
				defer release(h, xv)
				ch := edit.insert_element(ov, cur.target, -1, edit.val_null()) or_return
				write_value_to_handle(h, ov, ch, xv) or_return
			}
			continue
		}
		write_value_to_handle(h, ov, cur.target, cur.val) or_return
	}
	return nil
}

@(private = "file")
write_handle_via_tmp :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, x: Value) -> edit.Error {
	tmp_h := edit.new_node(ov, edit.val_null()) or_return
	if werr := write_value_to_handle(h, ov, tmp_h, x); werr != nil { edit.discard_node(ov, tmp_h); return werr }
	if merr := edit.move_node_payload(ov, target, tmp_h); merr != nil { edit.discard_node(ov, tmp_h); return merr }
	return nil
}

@(private = "file")
collapse_grouped_xml_member :: proc(h: ^Heap, ov: ^edit.Overlay, parent_h: edit.Handle, key: string, first_base_idx: int, has_base: bool, target_h: edit.Handle, xv: Value) -> edit.Error {
	if !has_base { return write_handle_via_tmp(h, ov, target_h, xv) }
	tmp_h := edit.new_node(ov, edit.val_null()) or_return
	ok := false
	defer if !ok { edit.discard_node(ov, tmp_h) }
	write_value_to_handle(h, ov, tmp_h, xv) or_return
	for {
		_, _, found := edit.lookup_member(ov, parent_h, key)
		if !found { break }
		edit.del_member(ov, parent_h, key) or_return
	}
	ih := edit.insert_member(ov, parent_h, first_base_idx, key, edit.val_null()) or_return
	edit.move_node_payload(ov, ih, tmp_h) or_return
	ok = true
	return nil
}

@(private, cold, require_results)
overlay_set_at :: proc(h: ^Heap, t: Value, key: string, idx: int, is_member: bool, x: Value) -> (res: Value, status: Status) {
	defer release(h, x)
	defer if status != .Ok { release(h, t) }
	ob, eh, tn, ok := resolve_overlay(t)
	if !ok { return NULL, fail_fact_msg(h, "invalid overlay handle") }
	refresh_overlay_writer(h, ob)
	cur_h: edit.Handle
	found: bool
	if is_member {
		cur_h, _, found = edit.lookup_member(ob.ov, eh, key)
		if bn := edit.node_base_container(tn); bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn)) {
			alloc := heap_allocator(h)
			if members, owned_keys, merr := edit.effective_members(ob.ov, eh, alloc); merr == nil {
				defer edit.destroy_effective_members(members, owned_keys, alloc)
				sibs := make([dynamic]edit.Effective_Member, 0, 4, alloc)
				defer delete(sibs)
				has_base, first_base_idx, rep_arr_h := false, -1, edit.NO_HANDLE
				for m in members {
					if m.key != key { continue }
					append(&sibs, m)
					if m.base_val != tape.NO_NODE && !m.is_inserted && !has_base { has_base, first_base_idx = true, m.base_idx }
					if rep_arr_h == edit.NO_HANDLE {
						if _, is_arr := replaced_array_elems(ob.ov, m.handle); is_arr { rep_arr_h = m.handle }
					}
				}
				has_rep_arr := rep_arr_h != edit.NO_HANDLE
				if type_of(x) != .Array && (has_rep_arr || len(sibs) > 1) {
					if werr := collapse_grouped_xml_member(h, ob.ov, eh, key, first_base_idx, has_base, rep_arr_h, x); werr != nil {
						return NULL, overlay_fail_edit(h, werr)
					}
					return t, .Ok
				}
				if type_of(x) == .Array && !has_rep_arr && len(sibs) > 1 && length_of(h, x) == len(sibs) {
					for sm, i in sibs {
						ev := element(h, x, i) or_return
						defer release(h, ev)
						if is_same_provenance(ob.ov, ev, sm.handle, sm.base_val) { continue }
						sh := sm.handle
						if sh == edit.NO_HANDLE {
							herr: edit.Error
							if sh, herr = edit.handle_for_base(ob.ov, sm.base_val, eh); herr != nil { return NULL, overlay_fail_edit(h, herr) }
						}
						if werr := write_handle_via_tmp(h, ob.ov, sh, ev); werr != nil { return NULL, overlay_fail_edit(h, werr) }
					}
					return t, .Ok
				}
			}
		}
	} else {
		cur_h, _, found = edit.lookup_element(ob.ov, eh, idx)
	}
	if x.kind == .Overlay && (^Overlay_Block)(x.p).ov == ob.ov && found && cur_h != edit.NO_HANDLE && cur_h.idx == x.n {
		return t, .Ok
	}
	tmp_h, terr := edit.new_node(ob.ov, edit.val_null())
	if terr != nil { return NULL, overlay_fail_edit(h, terr) }
	if werr := write_value_to_handle(h, ob.ov, tmp_h, x); werr != nil { edit.discard_node(ob.ov, tmp_h); return NULL, overlay_fail_edit(h, werr) }
	ch: edit.Handle
	serr: edit.Error
	if is_member {
		ch, serr = edit.set_member(ob.ov, eh, key, edit.val_null())
	} else {
		ch, serr = edit.set_element(ob.ov, eh, idx, edit.val_null())
	}
	if serr != nil { edit.discard_node(ob.ov, tmp_h); return NULL, overlay_fail_edit(h, serr) }
	if merr := edit.move_node_payload(ob.ov, ch, tmp_h); merr != nil { edit.discard_node(ob.ov, tmp_h); return NULL, overlay_fail_edit(h, merr) }
	return t, .Ok
}

@(private, cold, require_results)
overlay_del_members :: #force_no_inline proc(h: ^Heap, t: Value, keys: []Value) -> (res: Value, status: Status) {
	defer if status != .Ok { release(h, t) }
	ob, eh, _, ok := resolve_overlay(t)
	if !ok { return NULL, fail_fact_msg(h, "invalid overlay handle") }
	refresh_overlay_writer(h, ob)
	for k in keys {
		if type_of(k) != .String { return NULL, fail(h, .Types, .Delete_Paths, t, k, "field of object") }
	}
	for k in keys {
		if derr := edit.del_member(ob.ov, eh, text_of(k)); derr != nil { return NULL, overlay_fail_edit(h, derr) }
	}
	return t, .Ok
}

@(private, cold, require_results)
overlay_del_elements :: #force_no_inline proc(h: ^Heap, t: Value, gone: []bool) -> (res: Value, status: Status) {
	defer if status != .Ok { release(h, t) }
	ob, eh, _, ok := resolve_overlay(t)
	if !ok { return NULL, fail_fact_msg(h, "invalid overlay handle") }
	refresh_overlay_writer(h, ob)
	for i := len(gone) - 1; i >= 0; i -= 1 {
		if gone[i] {
			if derr := edit.del_element(ob.ov, eh, i); derr != nil { return NULL, overlay_fail_edit(h, derr) }
		}
	}
	return t, .Ok
}
