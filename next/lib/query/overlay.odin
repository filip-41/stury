package query

import "base:runtime"
import "core:math"
import "core:math/big"
import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"

// `Overlay_Ref` (`Kind.Overlay`) integration for `lib/query`.
//
// Lets `jq`, path readers, container cursors, fact readers/writers, `css`, `apply_patch`, and `where` read and
// edit an `edit.Overlay` through the exact same 16-byte `Value` interface with zero second code path, zero
// `^Commented` wrapper, and zero overhead on plain non-overlay `Value` hot paths.

Overlay_Block :: struct {
	using block: Block,
	ov:          ^edit.Overlay,
	doc_block:   ^Doc_Block,
	owned:       bool, // when true, `edit.destroy(ov)` + `free(ov, heap_allocator(h))` when rc reaches 0
}

// Wraps an existing `^edit.Overlay` as a `Kind.Overlay` `Value` pointing to its root handle.
// If `doc_block` is nil, creates a lightweight unowned `Doc_Block` over `ov.base`.
@(require_results)
overlay_value :: proc(h: ^Heap, ov: ^edit.Overlay, doc_block: ^Doc_Block = nil, owned := false) -> (res: Value, status: Status) {
	if ov == nil || ov.base == nil {
		return ABSENT, .Ok
	}
	root_h, rerr := edit.ensure_root(ov)
	if rerr != nil {
		return NULL, overlay_fail_edit(h, rerr)
	}
	db := doc_block
	created_db := false
	if db == nil {
		b := alloc_block(h, size_of(Doc_Block)) or_return
		db = (^Doc_Block)(b)
		db.doc = ov.base^
		db.owned = false
		db.index = {allocator = heap_allocator(h)}
		created_db = true
	}
	ob_raw, s := alloc_block(h, size_of(Overlay_Block))
	if s != .Ok {
		if created_db {
			free_one(h, .Node, db)
		}
		return NULL, s
	}
	if !created_db {
		db.rc += 1
	}
	ob := (^Overlay_Block)(ob_raw)
	ob.ov = ov
	ob.doc_block = db
	ob.owned = owned
	refresh_overlay_writer(h, ob)
	res = Value{p = ob, n = root_h.idx, kind = .Overlay, held = true}
	if es := ensure_overlay_decoded_scalar(h, ob, root_h); es != .Ok {
		release(h, res)
		return NULL, es
	}
	return res, .Ok
}

// Ensures any `.Overlay` referencing an undecoded `SPELLING_DECODE`/`.Bytes` base scalar has its decoded UTF-8
// cached in `Edit_Node.val` so `text_of` always returns decoded text cleanly!
@(private)
ensure_overlay_decoded_scalar :: proc(h: ^Heap, ob: ^Overlay_Block, eh: edit.Handle) -> Status {
	if ob == nil || ob.ov == nil || ob.ov.base == nil || eh == edit.NO_HANDLE {
		return .Ok
	}
	n, ok := edit.get_node(ob.ov, eh)
	if !ok {
		return .Ok
	}
	if n.state == .Ancestor && n.val.kind == .None && n.base != tape.NO_NODE && int(n.base) < len(ob.ov.base.nodes) {
		bt := ob.ov.base.nodes[n.base]
		if (bt.kind == .String || bt.kind == .Plain || bt.kind == .Bytes) && (bt.kind == .Bytes || bt.spelling & tape.SPELLING_DECODE != 0) {
			alloc := heap_allocator(h)
			tk := edit.decode_node_text_tmp(ob.ov.base, n.base, alloc)
			defer edit.free_tmp_text(tk, alloc)
			if cerr := edit.cache_ancestor_text(ob.ov, eh, tk.text); cerr != nil {
				return overlay_fail_edit(h, cerr)
			}
		}
	}
	return .Ok
}

// Deep-clones `v`'s `edit.Overlay` into a fresh unique `Overlay_Block` (`rc == 1`) sharing `v.doc_block` cleanly
// so aliases (`$orig`, `[., ...]`, `try`) remain untouched.
@(private, require_results)
cow_clone_overlay :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(v)
	if !ok {
		release(h, v)
		return NULL, fail_fact_msg(h, "invalid overlay handle for COW")
	}
	alloc := heap_allocator(h)
	handles := [1]edit.Handle{eh}
	cloned_ov, cerr := edit.clone_overlay(ob.ov, handles[:], alloc)
	if cerr != nil {
		release(h, v)
		return NULL, overlay_fail_edit(h, cerr)
	}
	ov_ptr, aerr := new(edit.Overlay, alloc)
	if aerr != nil {
		edit.destroy(&cloned_ov)
		release(h, v)
		return NULL, fail_memory(h)
	}
	ov_ptr^ = cloned_ov
	ob_raw, s := alloc_block(h, size_of(Overlay_Block))
	if s != .Ok {
		edit.destroy(ov_ptr)
		free(ov_ptr, alloc)
		release(h, v)
		return NULL, s
	}
	ob.doc_block.rc += 1
	new_ob := (^Overlay_Block)(ob_raw)
	new_ob.ov = ov_ptr
	new_ob.doc_block = ob.doc_block
	new_ob.owned = true
	if h.write_fact_data == ob {
		attach_overlay_writer(h, new_ob)
	}
	res = Value{p = new_ob, n = handles[0].idx, kind = .Overlay, held = true}
	release(h, v)
	return res, .Ok
}

// Creates a new `edit.Overlay` over `doc` (using `heap_allocator(h)` so `Heap.limit` is enforced) and returns
// its root `Overlay_Ref` `Value` plus the `^edit.Overlay` pointer, wiring `h.write_fact` to back fact writes.
@(require_results)
overlay_from_doc :: proc(h: ^Heap, doc: tape.Document, doc_owned: bool) -> (val: Value, ov: ^edit.Overlay, status: Status) {
	alloc := heap_allocator(h)
	db_raw := alloc_block(h, size_of(Doc_Block)) or_return
	db := (^Doc_Block)(db_raw)
	db.doc = doc
	db.owned = doc_owned
	db.index = {allocator = alloc}

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
	// `overlay_value` retained `db` once; drop our initial creation ref so `Overlay_Block` is its sole owner.
	db.rc -= 1
	attach_overlay_writer(h, (^Overlay_Block)(v.p))
	return v, ov_ptr, .Ok
}

// Wires `Heap.write_fact` to route fact writes onto `ob.ov`.
attach_overlay_writer :: proc(h: ^Heap, ob: ^Overlay_Block) {
	h.write_fact = overlay_write_fact_hook
	h.write_fact_data = ob
}

// Re-arms `Heap.write_fact` onto live overlay `ob` when unset or still wired to an overlay writer hook.
@(private)
refresh_overlay_writer :: #force_inline proc "contextless" (h: ^Heap, ob: ^Overlay_Block) {
	if ob != nil && (h.write_fact == nil || h.write_fact == overlay_write_fact_hook) {
		h.write_fact = overlay_write_fact_hook
		h.write_fact_data = ob
	}
}

@(private = "file")
overlay_write_fact_hook :: proc(
	data: rawptr,
	h: ^Heap,
	v: Value,
	kind: tape.Fact_Kind,
	attr: string,
	is_attr: bool,
	nv: Value,
) -> (
	res: Value,
	status: Status,
) {
	return overlay_write_fact(data, h, v, kind, attr, is_attr, nv, 0)
}

// Maps an `edit.Error` into a catchable `query.Status` (only `Allocator_Error` becomes `.Memory`).
@(private, cold)
overlay_fail_edit :: proc(h: ^Heap, err: edit.Error) -> Status {
	switch e in err {
	case runtime.Allocator_Error:
		return fail_memory(h)
	case edit.Refusal:
		msg := e.detail if len(e.detail) > 0 else "overlay edit refused"
		return fail_fact_msg(h, msg)
	case tape.Fault:
		return fail_fact_msg(h, "invalid syntax in edited value")
	case tape.Exceeded:
		return fail_fact_msg(h, "edit exceeded format limits")
	case tape.Bad_Option:
		return fail_fact_msg(h, "invalid edit option")
	}
	return fail_fact_msg(h, "overlay edit failed")
}

// Shared helper to resolve an `.Overlay` value into `(ob, eh, node)`.
@(private)
resolve_overlay :: #force_inline proc "contextless" (v: Value) -> (ob: ^Overlay_Block, eh: edit.Handle, n: ^edit.Edit_Node, ok: bool) {
	if v.kind != .Overlay || v.p == nil {
		return nil, edit.NO_HANDLE, nil, false
	}
	ob = (^Overlay_Block)(v.p)
	n, ok = edit.get_node_by_idx(ob.ov, v.n)
	if !ok {
		return ob, edit.NO_HANDLE, nil, false
	}
	return ob, n.handle, n, true
}

// Returns the `^edit.Overlay` and `edit.Handle` behind an `.Overlay` value.
overlay_handle :: proc "contextless" (v: Value) -> (ov: ^edit.Overlay, h: edit.Handle, ok: bool) {
	ob, eh, _, valid := resolve_overlay(v)
	if !valid {
		return nil, edit.NO_HANDLE, false
	}
	return ob.ov, eh, true
}

// Returns the `Doc_Block` and `Node_Index` to pass to `css.select` for `.Overlay` `v`.
// Fast path (`!ov.dirty`): returns base `ob.doc_block` and `bn` with zero allocations.
// Edited path (`ov.dirty`): materializes a fresh XML view via `edit.materialize_subtree` so edited classes/attrs,
// deleted elements, and newly inserted elements are queried accurately.
overlay_css_origin :: proc(h: ^Heap, v: Value) -> (mat: Value, d: ^Doc_Block, at: tape.Node_Index, need_release: bool, status: Status) {
	ob, eh, n, valid := resolve_overlay(v)
	if !valid || ob.doc_block == nil {
		return ABSENT, nil, tape.NO_NODE, false, .Ok
	}
	refresh_overlay_writer(h, ob)
	if !ob.ov.dirty {
		bn := edit.node_base_container(n)
		if bn == tape.NO_NODE {
			return ABSENT, nil, tape.NO_NODE, false, .Ok
		}
		return ABSENT, ob.doc_block, bn, false, .Ok
	}
	root_h, rerr := edit.ensure_root(ob.ov)
	if rerr != nil {
		return ABSENT, nil, tape.NO_NODE, false, overlay_fail_edit(h, rerr)
	}
	alloc := heap_allocator(h)
	mat_node := tape.NO_NODE
	mat_doc, merr := edit.materialize_subtree(ob.ov, root_h, tape.ROOT, {
		xml_attrs             = true,
		include_root_comments = true,
		flatten_xml_arrays    = true,
		target_format         = ob.doc_block.doc.format,
		track_handle          = eh,
		tracked_node          = &mat_node,
	}, alloc)
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
	if mat_node == tape.NO_NODE {
		mat_node = tape.ROOT if eh == root_h else tape.NO_NODE
	}
	return dv, (^Doc_Block)(dv.p), mat_node, true, .Ok
}

// Whether `.Overlay` `v` has no external aliases beyond the current single-chain update stack of `depth` ancestors.
@(private)
overlay_is_unique :: #force_inline proc "contextless" (v: Value, depth := 0) -> bool {
	if v.kind != .Overlay || !v.held || v.p == nil {
		return false
	}
	return (^Overlay_Block)(v.p).rc <= u32(1 + depth)
}

@(private)
overlay_child_ref :: #force_inline proc "contextless" (ob: ^Overlay_Block, eh: edit.Handle) -> Value {
	ob.rc += 1
	return Value{p = ob, n = eh.idx, kind = .Overlay, held = true}
}

@(private, cold)
overlay_type :: #force_no_inline proc "contextless" (v: Value) -> Type {
	ob, eh, _, ok := resolve_overlay(v)
	if !ok {
		return .Null
	}
	switch edit.node_kind(ob.ov, eh) {
	case .Null:
		return .Null
	case .False:
		return .False
	case .True:
		return .True
	case .Number:
		return .Number
	case .String, .Plain, .Bytes:
		return .String
	case .Array:
		return .Array
	case .Object:
		return .Object
	case .End:
		return .Null
	}
	return .Null
}

// Unwraps an `.Overlay` scalar into an unheld read-only scalar `Value` (or `.Node` when decode-free).
@(private, cold)
overlay_unwrap_scalar :: #force_no_inline proc "contextless" (v: Value) -> Value {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return NULL
	}
	if n.state == .Replaced {
		switch n.val.kind {
		case .None, .Null:
			return NULL
		case .False:
			return FALSE
		case .True:
			return TRUE
		case .Int:
			return int_value(n.val.i)
		case .Uint:
			if n.val.u <= u64(max(i64)) {
				return int_value(i64(n.val.u))
			}
			return double_value(f64(n.val.u))
		case .Float:
			return double_value(n.val.f)
		case .String, .Number_Text, .Raw:
			return Value{s = raw_data(n.val.text), n = u32(len(n.val.text)), kind = .String}
		case .Bytes:
			return Value{s = raw_data(n.val.raw), n = u32(len(n.val.raw)), kind = .String}
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE {
				return Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node}
			}
			return NULL
		case .Array, .Object:
			return v
		}
	}
	if n.state == .Ancestor && n.val.kind == .String {
		return Value{s = raw_data(n.val.text), n = u32(len(n.val.text)), kind = .String}
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return Value{p = ob.doc_block, n = u32(bn), kind = .Node}
	}
	return NULL
}

@(private = "file")
overlay_base_node :: #force_inline proc "contextless" (ob: ^Overlay_Block, n: ^edit.Edit_Node) -> (Value, bool) {
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return Value{p = ob.doc_block, n = u32(bn), kind = .Node}, true
	}
	return {}, false
}

// Returns the raw decimal literal bytes of an `.Overlay` number if it can be emitted verbatim as JSON.
@(private, cold)
overlay_number_literal :: proc "contextless" (v: Value) -> ([]u8, bool) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return nil, false
	}
	if n.state == .Replaced && n.val.kind == .Number_Text {
		return transmute([]u8)n.val.text, true
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		d := ob.doc_block
		if d.doc.format == nil || .Binary not_in d.doc.format.caps {
			return node_bytes(bv), true
		}
	}
	return nil, false
}

// Whether an `.Overlay` number is an exact integer outside `i64`'s range (used by `node_big_int`, `compare_wide`, `hash_number`, `trunc_i64`).
@(private, cold)
overlay_big_int :: proc(v: Value) -> (u: u64, is_uint: bool, dec: string, ok: bool) {
	ob, _, n, valid := resolve_overlay(v)
	if !valid {
		return
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Uint:
			if n.val.u > u64(max(i64)) {
				return n.val.u, true, "", true
			}
			return
		case .Number_Text:
			if is_plain_int_dec(n.val.text) {
				if sn, sok := spell.number_strict(transmute([]u8)n.val.text, 0, u64(len(n.val.text))); sok && sn.kind == .Int {
					return
				}
				return 0, false, n.val.text, true
			}
			return
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return node_big_int(bv)
	}
	return
}

// Converts an `.Overlay` scalar into an owned numeric `Value` (`.Int`, `.Double`, or `.Big`).
@(private, cold, require_results)
overlay_number_of :: #force_no_inline proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return NULL, .Ok
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int:
			return int_value(n.val.i), .Ok
		case .Uint:
			if n.val.u <= u64(max(i64)) {
				return int_value(i64(n.val.u)), .Ok
			}
			return big_from_u64(h, n.val.u)
		case .Float:
			return double_value(n.val.f), .Ok
		case .Number_Text:
			parsed, pok, ps := parse_number(h, n.val.text, loose = true)
			if ps != .Ok {
				return NULL, ps
			}
			return parsed if pok else double_value(math.nan_f64()), .Ok
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
	if !ok {
		return 0
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int:
			return f64(n.val.i)
		case .Uint:
			return f64(n.val.u)
		case .Float:
			return n.val.f
		case .Number_Text:
			b := transmute([]u8)n.val.text
			if sn, valid := spell.number_strict(b, 0, u64(len(b))); valid {
				switch sn.kind {
				case .Int:
					return f64(i64(sn.bits))
				case .Uint:
					return f64(sn.bits)
				case .Float:
					return transmute(f64)sn.bits
				case .Wide:
					return wide_double(b)
				}
			}
			return wide_double(b)
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return as_f64(bv)
	}
	return 0
}

@(private, cold)
overlay_as_i64 :: #force_no_inline proc(v: Value) -> (i64, bool) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return 0, false
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int:
			return n.val.i, true
		case .Uint:
			if n.val.u <= u64(max(i64)) {
				return i64(n.val.u), true
			}
			return 0, false
		case .Float:
			return as_i64(double_value(n.val.f))
		case .Number_Text:
			b := transmute([]u8)n.val.text
			if sn, valid := spell.number_strict(b, 0, u64(len(b))); valid {
				if sn.kind == .Int {
					return i64(sn.bits), true
				}
				if sn.kind == .Float {
					return as_i64(double_value(transmute(f64)sn.bits))
				}
			}
			return 0, false
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return as_i64(bv)
	}
	return 0, false
}

@(private, cold)
overlay_is_integer :: #force_no_inline proc(v: Value) -> bool {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return false
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Int, .Uint:
			return true
		case .Float:
			return n.val.f == math.trunc(n.val.f) && !math.is_inf(n.val.f)
		case .Number_Text:
			if is_plain_int_dec(n.val.text) {
				return true
			}
			b := transmute([]u8)n.val.text
			if sn, valid := spell.number_strict(b, 0, u64(len(b))); valid {
				#partial switch sn.kind {
				case .Int, .Uint:
					return true
				case .Float:
					f := transmute(f64)sn.bits
					return f == math.trunc(f) && !math.is_inf(f)
				}
			}
			return false
		}
	}
	if bv, has_base := overlay_base_node(ob, n); has_base {
		return is_integer(bv)
	}
	return false
}

@(private, cold)
overlay_length :: #force_no_inline proc(h: ^Heap, v: Value) -> int {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return 0
	}
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
	if !ok {
		return ABSENT, .Ok
	}
	refresh_overlay_writer(h, ob)
	ch, cb, found := edit.lookup_element(ob.ov, eh, i)
	if !found {
		return ABSENT, .Ok
	}
	return overlay_wrap_child(h, ob, ch, cb, eh)
}

// Member `key` of an `.Overlay` object (supporting XML repeated-name grouping across `.Ancestor`, `.Base_Ref`, and `.Container_Delta`).
@(private, cold, require_results)
overlay_member :: #force_no_inline proc(h: ^Heap, v: Value, key: string) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return ABSENT, .Ok
	}
	refresh_overlay_writer(h, ob)
	bn := edit.node_base_container(n)
	if bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn)) {
		if n.state == .Ancestor || (n.state == .Replaced && n.val.kind == .Base_Ref) {
			return overlay_group_member(h, ob, bn, eh, edit.is_live_base_node(n), key)
		}
		if n.state == .Container_Delta {
			return overlay_group_member_delta(h, ob, eh, key)
		}
	}
	ch, cb, found := edit.lookup_member(ob.ov, eh, key)
	if !found {
		return ABSENT, .Ok
	}
	return overlay_wrap_child(h, ob, ch, cb, eh)
}

// Flattens a `.Array`-replaced XML element's `elems` into a grouped `.Array` `Value` (preserving 0- and 1-element arrays).
@(private = "file", require_results)
append_overlay_array_elems :: proc(
	h: ^Heap,
	ob: ^Overlay_Block,
	parent_h: edit.Handle,
	elems: []edit.Handle,
	out: Value,
) -> (Value, Status) {
	res := out
	if res.kind == .Absent {
		a, as := make_array(h, len(elems))
		if as != .Ok {
			return ABSENT, as
		}
		res = a
	}
	for elem_h in elems {
		ex, es := overlay_wrap_child(h, ob, elem_h, tape.NO_NODE, parent_h)
		if es != .Ok {
			release(h, res)
			return ABSENT, es
		}
		res, es = append_grouped(h, res, ex)
		if es != .Ok {
			return ABSENT, es
		}
	}
	return res, .Ok
}

@(private = "file", require_results)
overlay_group_member :: proc(
	h: ^Heap,
	ob: ^Overlay_Block,
	at: tape.Node_Index,
	parent_h: edit.Handle,
	use_by_base: bool,
	key: string,
) -> (res: Value, status: Status) {
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
		if use_by_base && ch != edit.NO_HANDLE {
			if cn, cok := edit.get_node(ob.ov, ch); cok && cn.state == .Replaced && cn.val.kind == .Array {
				return append_overlay_array_elems(h, ob, ch, cn.elems[:], out)
			}
		}
		x, s := overlay_wrap_child(h, ob, ch, node, parent_h)
		if s != .Ok {
			release(h, out)
			return ABSENT, s
		}
		out, s = append_grouped(h, out, x)
		if s != .Ok {
			return ABSENT, s
		}
	}
}

@(private = "file", require_results)
overlay_group_member_delta :: proc(h: ^Heap, ob: ^Overlay_Block, eh: edit.Handle, key: string) -> (res: Value, status: Status) {
	alloc := heap_allocator(h)
	members, owned, merr := edit.effective_members(ob.ov, eh, alloc)
	if merr != nil {
		return ABSENT, fail_memory(h)
	}
	defer edit.destroy_effective_members(members, owned, alloc)
	out := ABSENT
	replaced_array := false
	for m in members {
		if m.key != key {
			continue
		}
		if replaced_array && m.base_val != tape.NO_NODE && !m.is_inserted {
			continue
		}
		if m.handle != edit.NO_HANDLE {
			if cn, ok := edit.get_node(ob.ov, m.handle); ok && cn.state == .Replaced && cn.val.kind == .Array {
				replaced_array = true
				out = append_overlay_array_elems(h, ob, m.handle, cn.elems[:], out) or_return
				continue
			}
		}
		x, s := overlay_wrap_child(h, ob, m.handle, m.base_val, eh)
		if s != .Ok {
			release(h, out)
			return ABSENT, s
		}
		out, s = append_grouped(h, out, x)
		if s != .Ok {
			return ABSENT, s
		}
	}
	return out, .Ok
}

@(private = "file", require_results)
append_grouped :: proc(h: ^Heap, out, x: Value) -> (Value, Status) {
	if out.kind == .Absent {
		return x, .Ok
	}
	res := out
	if res.kind != .Array {
		first := res
		s: Status
		res, s = make_array(h, 2)
		if s != .Ok {
			release(h, first)
			release(h, x)
			return ABSENT, s
		}
		if s = append_owned(h, &res, first); s != .Ok {
			release(h, res)
			release(h, x)
			return ABSENT, s
		}
	}
	if s := append_owned(h, &res, x); s != .Ok {
		release(h, res)
		return ABSENT, s
	}
	return res, .Ok
}

// Wraps child `(ch, cb)` of `ob` (under `parent_h`) into a `Value`.
// Containers stay `.Overlay` (linked directly to `parent_h` without setting `unlinked_parents`) unless `parent_h` is
// a detached `.Base_Ref` copy. Scalars with facts or decoded `SPELLING_DECODE` base scalars preserve `.Overlay` + decoded UTF-8.
@(private, require_results)
overlay_wrap_child :: proc(
	h: ^Heap,
	ob: ^Overlay_Block,
	ch: edit.Handle,
	cb: tape.Node_Index,
	parent_h: edit.Handle,
) -> (res: Value, status: Status) {
	refresh_overlay_writer(h, ob)
	if ch != edit.NO_HANDLE {
		cn, ok := edit.get_node(ob.ov, ch)
		if !ok {
			return ABSENT, .Ok
		}
		k := edit.node_kind(ob.ov, ch)
		if k >= .Array {
			return overlay_child_ref(ob, ch), .Ok
		}
		if cn.state == .Replaced {
			if cn.val.kind == .Base_Ref && cn.val.base_ref != tape.NO_NODE && len(cn.facts) == 0 && cn.base == cn.val.base_ref {
				return node_value(h, ob.doc_block, cn.val.base_ref, force_origin = true)
			}
			// Decode if needed and keep `.Overlay` so subsequent fact writes preserve handle identity!
			if cn.val.kind == .Base_Ref && cn.val.base_ref != tape.NO_NODE {
				bt := ob.doc_block.doc.nodes[cn.val.base_ref]
				if (bt.kind == .String || bt.kind == .Plain || bt.kind == .Bytes) && (bt.kind == .Bytes || bt.spelling & tape.SPELLING_DECODE != 0) {
					alloc := heap_allocator(h)
					tk := edit.decode_node_text_tmp(ob.ov.base, cn.val.base_ref, alloc)
					defer edit.free_tmp_text(tk, alloc)
					br := cn.val.base_ref
					if serr := edit.set(ob.ov, ch, edit.val_bytes(transmute([]u8)tk.text) if bt.kind == .Bytes else edit.val_string(tk.text)); serr != nil {
						return NULL, overlay_fail_edit(h, serr)
					}
					if cn2, ok2 := edit.get_node(ob.ov, ch); ok2 {
						cn2.base_ref = br
					}
				}
			}
			return overlay_child_ref(ob, ch), .Ok
		}
		if len(cn.facts) > 0 {
			ensure_overlay_decoded_scalar(h, ob, ch) or_return
			return overlay_child_ref(ob, ch), .Ok
		}
		if cn.base != tape.NO_NODE {
			return node_value(h, ob.doc_block, cn.base, force_origin = true)
		}
		return overlay_child_ref(ob, ch), .Ok
	}
	if cb != tape.NO_NODE {
		if ob.doc_block.doc.nodes[cb].kind >= .Array {
			// If `parent_h` is a detached `.Base_Ref` container copy (not a live `by_base` node), return a `.Node`
			// so reading/updating children NEVER aliases `ov.by_base` back onto `.a` or causes `.a = .` cycles!
			if pn, pok := edit.get_node(ob.ov, parent_h); pok && !edit.is_live_base_node(pn) {
				return node_value(h, ob.doc_block, cb, force_origin = true)
			}
			nh, herr := edit.handle_for_base(ob.ov, cb, parent_h)
			if herr != nil {
				return NULL, overlay_fail_edit(h, herr)
			}
			return overlay_child_ref(ob, nh), .Ok
		}
		return node_value(h, ob.doc_block, cb, force_origin = true)
	}
	return ABSENT, .Ok
}

// Promotes a `.Node` or detached scalar inside `parent_v` (`^Overlay_Block`) into an `.Overlay` child handle owned by
// `parent_ob.ov` before a fact write, avoiding `ov.by_base` aliasing on `.Base_Ref` copies and stale COW writers.
@(private, require_results)
overlay_promote_fact_target :: proc(h: ^Heap, parent_v, step, cur: Value) -> (res: Value, status: Status) {
	ob, ph, pn, ok := resolve_overlay(parent_v)
	if !ok {
		return cur, .Ok
	}
	refresh_overlay_writer(h, ob)
	if cur.kind == .Overlay && cur.p == parent_v.p {
		return cur, .Ok
	}
	ch, cb, found := edit.NO_HANDLE, tape.NO_NODE, false
	if type_of(step) == .String {
		ch, cb, found = edit.lookup_member(ob.ov, ph, text_of(step))
	} else if type_of(step) == .Number {
		if idx, iok := element_index(step); iok {
			if idx < 0 {
				idx += edit.container_len(ob.ov, ph)
			}
			ch, cb, found = edit.lookup_element(ob.ov, ph, idx)
		}
	}
	if !found {
		return cur, .Ok
	}
	target_h := ch
	if target_h == edit.NO_HANDLE && cb != tape.NO_NODE {
		herr: edit.Error
		if edit.is_live_base_node(pn) {
			target_h, herr = edit.handle_for_base(ob.ov, cb, ph)
		} else if type_of(step) == .String {
			target_h, herr = edit.set_member(ob.ov, ph, text_of(step), edit.val_base_ref(cb))
		} else if idx, iok := element_index(step); iok {
			if idx < 0 {
				idx += edit.container_len(ob.ov, ph)
			}
			target_h, herr = edit.set_element(ob.ov, ph, idx, edit.val_base_ref(cb))
		}
		if herr != nil {
			release(h, cur)
			return NULL, overlay_fail_edit(h, herr)
		}
	}
	if target_h == edit.NO_HANDLE {
		return cur, .Ok
	}
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
	if !ok {
		return false
	}
	refresh_overlay_writer(h, ob)
	_, _, found := edit.lookup_member(ob.ov, eh, key)
	return found
}

// Materializes an `.Overlay` container into a fresh built `Array_Block` or `Object_Block` (preserving XML `.Group`!).
@(private, cold, require_results)
overlay_built :: #force_no_inline proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return NULL, .Ok
	}
	refresh_overlay_writer(h, ob)
	alloc := heap_allocator(h)
	k := edit.node_kind(ob.ov, eh)
	if k == .Array {
		elems, eerr := edit.effective_elements(ob.ov, eh, alloc)
		if eerr != nil {
			return NULL, fail_memory(h)
		}
		defer delete(elems, alloc)
		out := make_array(h, len(elems)) or_return
		defer if status != .Ok {
			release(h, out)
		}
		for e in elems {
			cv := overlay_wrap_child(h, ob, e.handle, e.base, eh) or_return
			append_owned(h, &out, cv) or_return
		}
		return out, .Ok
	}
	if k == .Object {
		members, owned_keys, merr := edit.effective_members(ob.ov, eh, alloc)
		if merr != nil {
			return NULL, fail_memory(h)
		}
		defer edit.destroy_effective_members(members, owned_keys, alloc)
		bn := edit.node_base_container(n)
		grouped := bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn))
		out := make_object(h, len(members)) or_return
		defer if status != .Ok {
			release(h, out)
		}
		replaced_keys := make([dynamic]string, 0, 2, alloc)
		defer delete(replaced_keys)
		for m in members {
			if grouped && m.base_val != tape.NO_NODE && !m.is_inserted {
				skip := false
				for rk in replaced_keys {
					if rk == m.key {
						skip = true
						break
					}
				}
				if skip {
					continue
				}
			}
			if grouped && m.handle != edit.NO_HANDLE {
				if cn, cok := edit.get_node(ob.ov, m.handle); cok && cn.state == .Replaced && cn.val.kind == .Array {
					append(&replaced_keys, m.key)
					arr := make_array(h, len(cn.elems)) or_return
					for elem_h in cn.elems {
						ev, es := overlay_wrap_child(h, ob, elem_h, tape.NO_NODE, m.handle)
						if es != .Ok {
							release(h, arr)
							return NULL, es
						}
						if as := append_owned(h, &arr, ev); as != .Ok {
							release(h, arr)
							return NULL, as
						}
					}
					kv, ks := text_value(h, m.key)
					if ks != .Ok {
						release(h, arr)
						return NULL, ks
					}
					object_put(h, &out, kv, arr) or_return
					continue
				}
			}
			cv := overlay_wrap_child(h, ob, m.handle, m.base_val, eh) or_return
			if grouped {
				if prev, ps := member(h, out, m.key); ps == .Ok && prev.kind != .Absent {
					merged, ms := append_grouped(h, prev, cv)
					if ms != .Ok {
						return NULL, ms
					}
					kv, ks := text_value(h, m.key)
					if ks != .Ok {
						release(h, merged)
						return NULL, ks
					}
					object_put(h, &out, kv, merged) or_return
					continue
				}
			}
			kv, ks := text_value(h, m.key)
			if ks != .Ok {
				release(h, cv)
				return NULL, ks
			}
			object_put(h, &out, kv, cv) or_return
		}
		return out, .Ok
	}
	return retain(v), .Ok
}

// Reads a fact on an `.Overlay` value (merging `Edit_Node.facts` overrides over the base `tape.Document`'s facts).
@(private, cold, require_results)
overlay_fact_read :: #force_no_inline proc(
	h: ^Heap,
	v: Value,
	kind: tape.Fact_Kind,
	attr: string,
	is_attr: bool,
) -> (
	res: Value,
	status: Status,
) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return NULL, .Ok
	}
	refresh_overlay_writer(h, ob)
	bn := edit.node_base_container(n)

	if is_attr {
		if fo, fok := edit.find_fact_override(ob.ov, eh, .Attribute, attr); fok {
			if fo.deleted || len(fo.values) == 0 {
				return NULL, .Ok
			}
			return text_value(h, fo.values[0])
		}
		if bn != tape.NO_NODE {
			return read_attributes(h, ob.doc_block, bn, attr, true)
		}
		return NULL, .Ok
	}

	if kind == .Attribute {
		base_attrs := NULL
		if bn != tape.NO_NODE {
			base_attrs = read_attributes(h, ob.doc_block, bn, "", false) or_return
		}
		has_attr_override := false
		for f in n.facts {
			if f.kind == .Attribute {
				has_attr_override = true
				break
			}
		}
		if !has_attr_override {
			return base_attrs, .Ok
		}
		out := base_attrs
		if out.kind != .Object {
			release(h, out)
			out = make_object(h, 4) or_return
		}
		defer if status != .Ok {
			release(h, out)
		}
		for f in n.facts {
			if f.kind != .Attribute {
				continue
			}
			if f.deleted || len(f.values) == 0 {
				object_delete(h, &out, f.attr) or_return
			} else {
				kv := text_value(h, f.attr) or_return
				vv, vs := text_value(h, f.values[0])
				if vs != .Ok {
					release(h, kv)
					return NULL, vs
				}
				object_put(h, &out, kv, vv) or_return
			}
		}
		if length_of(h, out) == 0 {
			release(h, out)
			return NULL, .Ok
		}
		return out, .Ok
	}

	if fo, fok := edit.find_fact_override(ob.ov, eh, kind); fok {
		if fo.deleted {
			return NULL, .Ok
		}
		#partial switch kind {
		case .Comment, .Comment_Inline, .Comment_Foot:
			if len(fo.values) == 0 {
				return NULL, .Ok
			}
			arr := make_array(h, len(fo.values)) or_return
			defer if status != .Ok {
				release(h, arr)
			}
			for line in fo.values {
				s := text_value(h, line) or_return
				append_owned(h, &arr, s) or_return
			}
			return arr, .Ok
		case .Tag:
			if num, has_num := fo.num_tag.?; has_num {
				if num <= u64(max(i64)) {
					return int_value(i64(num)), .Ok
				}
				return big_from_u64(h, num)
			}
			if len(fo.values) > 0 {
				return text_value(h, fo.values[0])
			}
			return NULL, .Ok
		case .Style, .Anchor, .Alias:
			if len(fo.values) > 0 {
				return text_value(h, fo.values[0])
			}
			return NULL, .Ok
		}
	}

	if bn != tape.NO_NODE {
		return read_base_node_fact(h, ob.doc_block, bn, kind, attr, is_attr)
	}
	return NULL, .Ok
}

// Extracts an exact `u64` tag from a numeric `Value` (supports `.Int`, `.Big`, `.Double`, `.Node`, `.Overlay` up to `max(u64)`!).
@(private = "file")
extract_u64_tag :: proc(nv: Value) -> (u: u64, ok: bool) {
	if i, iok := as_i64(nv); iok {
		if i < 0 {
			return 0, false
		}
		return u64(i), true
	}
	if nv.kind == .Big {
		x := &(^Big_Block)(nv.p).value
		if x.sign == .Negative {
			return 0, false
		}
		bits, _ := big.count_bits(x)
		if bits > 64 {
			return 0, false
		}
		v, err := big.int_get_u64(x)
		return v, err == nil
	}
	if nu, is_uint, dec, is_big := node_big_int(nv); is_big {
		if is_uint {
			return nu, true
		}
		if len(dec) == 0 || dec[0] == '-' || len(dec) > 20 {
			return 0, false
		}
		val: u64
		for c in transmute([]u8)dec {
			if c < '0' || c > '9' {
				return 0, false
			}
			d := u64(c - '0')
			if val > (max(u64) - d) / 10 {
				return 0, false
			}
			val = val * 10 + d
		}
		return val, true
	}
	return 0, false
}

// `Heap.write_fact` implementation backed by `edit.Overlay` (enforces COW uniqueness before mutating!).
overlay_write_fact :: proc(
	data: rawptr,
	h: ^Heap,
	v: Value,
	kind: tape.Fact_Kind,
	attr: string,
	is_attr: bool,
	nv: Value,
	overlay_depth := 0,
) -> (
	res: Value,
	status: Status,
) {
	ob: ^Overlay_Block
	eh: edit.Handle
	cur_v := v

	if cur_v.kind == .Overlay {
		if !overlay_is_unique(cur_v, overlay_depth) {
			cloned, cs := cow_clone_overlay(h, cur_v)
			if cs != .Ok {
				release(h, nv)
				return NULL, cs
			}
			cur_v = cloned
		}
		ov_ob, ov_eh, _, ok := resolve_overlay(cur_v)
		if !ok {
			release(h, cur_v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "invalid overlay handle for fact write")
		}
		ob, eh = ov_ob, ov_eh
		refresh_overlay_writer(h, ob)
	} else {
		ob = (^Overlay_Block)(data)
		if ob == nil || ob.ov == nil {
			release(h, cur_v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "fact writes require an overlay")
		}
		if d, at, from_doc := value_doc_origin(cur_v, true); from_doc && &d.doc == ob.ov.base {
			if ob.rc > 0 {
				// `cur_v` is not `.Overlay` (e.g. piped scalar `.Node` / `Str_Block`), while any live `Overlay_Block`
				// ref (`$orig`, `[., ...]`, `Update_Frame.state`) exists -> COW-clone safely before mutating!
				root_h, rerr := edit.ensure_root(ob.ov)
				if rerr != nil {
					release(h, cur_v)
					release(h, nv)
					return NULL, overlay_fail_edit(h, rerr)
				}
				tmp_ref := overlay_child_ref(ob, root_h)
				ov_val, os := cow_clone_overlay(h, tmp_ref)
				if os != .Ok {
					release(h, cur_v)
					release(h, nv)
					return NULL, os
				}
				ob = (^Overlay_Block)(ov_val.p)
				herr: edit.Error
				eh, herr = edit.handle_for_base(ob.ov, at)
				if herr != nil {
					release(h, ov_val)
					release(h, cur_v)
					release(h, nv)
					return NULL, overlay_fail_edit(h, herr)
				}
				// Restore text if `take_container` cleared `ob`'s node to `.Null` right before `|=`.
				if en, eok := edit.get_node(ob.ov, eh); eok && en.state == .Replaced && en.val.kind == .Null && cur_v.kind == .String {
					if serr := edit.set(ob.ov, eh, edit.val_string(text_of(cur_v))); serr != nil {
						release(h, ov_val)
						release(h, cur_v)
						release(h, nv)
						return NULL, overlay_fail_edit(h, serr)
					}
				}
				release(h, cur_v)
				cur_v = ov_val
				cur_v.n = eh.idx
			} else {
				herr: edit.Error
				eh, herr = edit.handle_for_base(ob.ov, at)
				if herr != nil {
					release(h, cur_v)
					release(h, nv)
					return NULL, overlay_fail_edit(h, herr)
				}
				if en, eok := edit.get_node(ob.ov, eh); eok && en.state == .Replaced && en.val.kind == .Null && cur_v.kind == .String {
					if serr := edit.set(ob.ov, eh, edit.val_string(text_of(cur_v))); serr != nil {
						release(h, cur_v)
						release(h, nv)
						return NULL, overlay_fail_edit(h, serr)
					}
				}
			}
		} else {
			release(h, cur_v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "cannot write fact on a value with no overlay node")
		}
	}

	nt := type_of(nv)
	edit_err: edit.Error
	if nt == .Null || nt == .Absent {
		edit_err = edit.del_fact(ob.ov, eh, kind, attr if is_attr else "")
	} else if is_attr {
		if msg, bad := validate_fact_write_group1(ob.ov, .Attribute, nil, attr); bad {
			release(h, cur_v)
			release(h, nv)
			return NULL, fail_fact_msg(h, msg)
		}
		vals := [1]string{text_of(nv)}
		edit_err = edit.set_fact(ob.ov, eh, .Attribute, vals[:], attr)
	} else if kind == .Comment || kind == .Comment_Inline || kind == .Comment_Foot {
		if nt == .String {
			vals := [1]string{text_of(nv)}
			if msg, bad := validate_fact_write_group1(ob.ov, kind, vals[:], ""); bad {
				release(h, cur_v)
				release(h, nv)
				return NULL, fail_fact_msg(h, msg)
			}
			edit_err = edit.set_fact(ob.ov, eh, kind, vals[:], padded = true)
		} else if nt == .Array {
			alloc := heap_allocator(h)
			lines := make([dynamic]string, 0, length_of(h, nv), alloc)
			owned_vals := make([dynamic]Value, 0, length_of(h, nv), alloc)
			defer {
				for lv in owned_vals {
					release(h, lv)
				}
				delete(owned_vals)
				delete(lines)
			}
			c, cs := cursor_open(h, nv)
			if cs != .Ok {
				release(h, cur_v)
				release(h, nv)
				return NULL, cs
			}
			defer cursor_close(&c)
			for {
				_, elem, more, ns := cursor_next(h, &c)
				if ns != .Ok {
					release(h, cur_v)
					release(h, nv)
					return NULL, ns
				}
				if !more {
					break
				}
				if _, aerr := append(&owned_vals, elem); aerr != nil {
					release(h, elem)
					release(h, cur_v)
					release(h, nv)
					return NULL, fail_memory(h)
				}
				if _, aerr := append(&lines, text_of(elem)); aerr != nil {
					release(h, cur_v)
					release(h, nv)
					return NULL, fail_memory(h)
				}
			}
			if len(lines) == 0 {
				edit_err = edit.del_fact(ob.ov, eh, kind)
			} else if msg, bad := validate_fact_write_group1(ob.ov, kind, lines[:], ""); bad {
				release(h, cur_v)
				release(h, nv)
				return NULL, fail_fact_msg(h, msg)
			} else {
				edit_err = edit.set_fact(ob.ov, eh, kind, lines[:], padded = true)
			}
		}
	} else if kind == .Tag && nt == .Number {
		if u, uok := extract_u64_tag(nv); uok {
			edit_err = edit.set_fact(ob.ov, eh, .Tag, nil, num_tag = u)
		} else {
			release(h, cur_v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "numeric tag must be an unsigned 64-bit integer")
		}
	} else {
		vals := [1]string{text_of(nv)}
		edit_err = edit.set_fact(ob.ov, eh, kind, vals[:])
	}

	release(h, nv)
	if edit_err != nil {
		release(h, cur_v)
		return NULL, overlay_fail_edit(h, edit_err)
	}
	if es := ensure_overlay_decoded_scalar(h, ob, eh); es != .Ok {
		release(h, cur_v)
		return NULL, es
	}
	if cur_v.kind == .Overlay {
		return cur_v, .Ok
	}
	release(h, cur_v)
	return overlay_child_ref(ob, eh), .Ok
}

// Validates Group 1 format constraints on `fact_write` when `ov.base.format` is known.
@(private = "file")
validate_fact_write_group1 :: proc "contextless" (ov: ^edit.Overlay, kind: tape.Fact_Kind, vals: []string, attr: string) -> (msg: string, bad: bool) {
	if ov == nil || ov.base == nil || ov.base.format == nil {
		return "", false
	}
	fname := ov.base.format.name
	if kind == .Attribute {
		if len(attr) == 0 {
			return "attribute name cannot be empty", true
		}
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
				if len(line) > 0 && line[len(line) - 1] == '-' {
					return "XML comment cannot end with '-'", true
				}
				for i := 0; i + 1 < len(line); i += 1 {
					if line[i] == '-' && line[i + 1] == '-' {
						return "XML comment cannot contain '--'", true
					}
				}
			}
		} else if len(fname) >= 4 && fname[:4] == "toml" {
			for line in vals {
				for c in transmute([]u8)line {
					if (c < 0x20 && c != '\t') || c == 0x7f {
						return "TOML comment contains disallowed control byte", true
					}
				}
			}
		}
	}
	return "", false
}

// Unified iterative conversion from any `query.Value` into an `edit.Handle` (or writing directly into an existing
// `target` handle) with zero UAF on `.Big`/wide numbers, zero leaked orphan handles, full `.Overlay` & `.Node`
// provenance preservation, and zero native recursion!
@(private, require_results)
write_value_to_handle :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, root_v: Value) -> edit.Error {
	if done, err := try_set_leaf_or_ref(h, ov, target, root_v); done || err != nil {
		return err
	}
	return write_container_to_handle(h, ov, target, root_v)
}

@(private)
is_leaf_or_provenance :: proc "contextless" (ov: ^edit.Overlay, v: Value) -> bool {
	if v.kind == .Node && &(^Doc_Block)(v.p).doc == ov.base {
		return true
	}
	if v.kind == .Overlay {
		ob, _, n, ok := resolve_overlay(v)
		if ok && ob.ov.base == ov.base {
			if len(n.facts) == 0 && n.state == .Ancestor && n.base != tape.NO_NODE && !edit.base_subtree_has_edits(ob.ov, n.base) {
				return true
			}
			if len(n.facts) == 0 && n.state == .Replaced && n.val.kind == .Base_Ref {
				return true
			}
		}
	}
	t := type_of(v)
	return t != .Array && t != .Object
}

// Copies any `Fact_Override` entries from `src_n` onto `dst` in `ov`.
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

// Sets `target` directly if `v` is a scalar or a zero-copy `.Base_Ref` provenance match (returns `done = true`).
// Preserves `.Overlay` scalar/ref facts (`len(n.facts) > 0`) when copying across overlay nodes!
@(private)
try_set_leaf_or_ref :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, v: Value) -> (done: bool, err: edit.Error) {
	// Zero-copy provenance: untouched `.Node` from `ov.base` -> `.Base_Ref`!
	if v.kind == .Node && &(^Doc_Block)(v.p).doc == ov.base {
		return true, edit.set(ov, target, edit.val_base_ref(tape.Node_Index(v.n)))
	}
	// Provenance / scalar copy from an `.Overlay` over the same base doc (preserving any facts on `n`!):
	if v.kind == .Overlay {
		ob, _, n, ok := resolve_overlay(v)
		if ok && ob.ov.base == ov.base {
			if n.state == .Ancestor && n.base != tape.NO_NODE && !edit.base_subtree_has_edits(ob.ov, n.base) {
				edit.set(ov, target, edit.val_base_ref(n.base)) or_return
				copy_overlay_node_facts(ov, target, n) or_return
				return true, nil
			}
			if n.state == .Replaced && n.val.kind == .Base_Ref {
				edit.set(ov, target, edit.val_base_ref(n.val.base_ref)) or_return
				copy_overlay_node_facts(ov, target, n) or_return
				return true, nil
			}
		}
	}
	switch type_of(v) {
	case .Absent, .Null:
		edit.set(ov, target, edit.val_null()) or_return
	case .False:
		edit.set(ov, target, edit.val_bool(false)) or_return
	case .True:
		edit.set(ov, target, edit.val_bool(true)) or_return
	case .Number:
		if i, iok := as_i64(v); iok {
			edit.set(ov, target, edit.val_int(i)) or_return
		} else if v.kind == .Big || is_integer(v) {
			alloc := heap_allocator(h)
			buf := make([dynamic]u8, 0, 32, alloc)
			defer delete(buf)
			if s := write_json(h, &buf, v); s == .Ok {
				edit.set(ov, target, edit.val_number_text(string(buf[:]))) or_return
			} else {
				return true, runtime.Allocator_Error.Out_Of_Memory
			}
		} else {
			edit.set(ov, target, edit.val_float(as_f64(v))) or_return
		}
	case .String:
		edit.set(ov, target, edit.val_string(text_of(v))) or_return
	case .Array, .Object:
		return false, nil
	}
	if v.kind == .Overlay {
		if _, _, sn, sok := resolve_overlay(v); sok && len(sn.facts) > 0 {
			copy_overlay_node_facts(ov, target, sn) or_return
		}
	}
	return true, nil
}

// Iteratively writes a built or edited `.Array`/`.Object` `root_v` into `target` in `ov` (zero recursion, zero orphan leaks!).
@(private)
write_container_to_handle :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, root_v: Value) -> edit.Error {
	alloc := heap_allocator(h)
	Frame :: struct {
		v:       Value, // held
		c:       Cursor,
		is_obj:  bool,
		elems:   [dynamic]edit.Handle,
		entries: [dynamic]edit.Object_Entry,
		key:     string,
		has_key: bool,
	}
	stack := make([dynamic]Frame, 0, 16, alloc)
	defer {
		for &f in stack {
			cursor_close(&f.c)
			release(h, f.v)
			delete(f.elems)
			for e in f.entries {
				delete(e.key, alloc)
			}
			delete(f.entries)
			if f.has_key {
				delete(f.key, alloc)
			}
		}
		delete(stack)
	}
	c0, s0 := cursor_open(h, root_v)
	if s0 != .Ok {
		return runtime.Allocator_Error.Out_Of_Memory
	}
	if _, aerr := append(&stack, Frame {
		v       = retain(root_v),
		c       = c0,
		is_obj  = type_of(root_v) == .Object,
		elems   = make([dynamic]edit.Handle, alloc),
		entries = make([dynamic]edit.Object_Entry, alloc),
	}); aerr != nil {
		cursor_close(&c0)
		release(h, root_v)
		return aerr
	}

	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		k, x, more, ns := cursor_next(h, &f.c)
		if ns != .Ok {
			return runtime.Allocator_Error.Out_Of_Memory
		}
		if !more {
			is_root := len(stack) == 1
			nh := target
			if is_root {
				if f.is_obj {
					edit.set(ov, target, edit.val_object(f.entries[:])) or_return
				} else {
					edit.set(ov, target, edit.val_array(f.elems[:])) or_return
				}
			} else {
				if f.is_obj {
					nh = edit.new_node(ov, edit.val_object(f.entries[:])) or_return
				} else {
					nh = edit.new_node(ov, edit.val_array(f.elems[:])) or_return
				}
			}
			parent_key := f.key
			has_pk := f.has_key
			f.has_key = false
			cursor_close(&f.c)
			release(h, f.v)
			delete(f.elems)
			for e in f.entries {
				delete(e.key, alloc)
			}
			delete(f.entries)
			pop(&stack)
			if is_root {
				return nil
			}
			up := &stack[len(stack) - 1]
			if up.is_obj {
				if _, aerr := append(&up.entries, edit.Object_Entry{key = parent_key, value = nh}); aerr != nil {
					delete(parent_key, alloc)
					return aerr
				}
			} else {
				if has_pk {
					delete(parent_key, alloc)
				}
				if _, aerr := append(&up.elems, nh); aerr != nil {
					return aerr
				}
			}
			continue
		}

		ks: string
		if f.is_obj {
			ks_buf, kerr := make([]u8, len(text_of(k)), alloc)
			if kerr != nil {
				release(h, k)
				release(h, x)
				return kerr
			}
			copy(ks_buf, text_of(k))
			ks = string(ks_buf)
			release(h, k)
		}

		// Only allocate a child handle immediately when `x` is a leaf or provenance `.Base_Ref` (never orphan handles!).
		if is_leaf_or_provenance(ov, x) {
			ch, ch_err := edit.new_node(ov, edit.val_null())
			if ch_err != nil {
				if f.is_obj {
					delete(ks, alloc)
				}
				release(h, x)
				return ch_err
			}
			_, lerr := try_set_leaf_or_ref(h, ov, ch, x)
			release(h, x)
			if lerr != nil {
				if f.is_obj {
					delete(ks, alloc)
				}
				return lerr
			}
			if f.is_obj {
				if _, aerr := append(&f.entries, edit.Object_Entry{key = ks, value = ch}); aerr != nil {
					delete(ks, alloc)
					return aerr
				}
			} else {
				if _, aerr := append(&f.elems, ch); aerr != nil {
					return aerr
				}
			}
			continue
		}

		cc, cs := cursor_open(h, x)
		if cs != .Ok {
			if f.is_obj {
				delete(ks, alloc)
			}
			release(h, x)
			return runtime.Allocator_Error.Out_Of_Memory
		}
		if _, aerr := append(&stack, Frame {
			v       = x,
			c       = cc,
			is_obj  = type_of(x) == .Object,
			elems   = make([dynamic]edit.Handle, alloc),
			entries = make([dynamic]edit.Object_Entry, alloc),
			key     = ks,
			has_key = f.is_obj,
		}); aerr != nil {
			cursor_close(&cc)
			if f.is_obj {
				delete(ks, alloc)
			}
			release(h, x)
			return aerr
		}
	}
	return nil
}

// Provenance-based reconciliation (`analysis.md` §1 Way 2):
// Reconciles an arbitrary filter output `result` against `ov` WITHOUT whole-value diffing!
@(require_results)
reconcile_overlay :: proc(h: ^Heap, ov: ^edit.Overlay, result: Value) -> edit.Error {
	if ov == nil || ov.base == nil {
		return edit.refuse(.No_Document, "reconcile_overlay requires a built overlay")
	}
	if ov.unlinked_parents {
		edit.ensure_linked(ov) or_return
	}
	root_h := edit.ensure_root(ov) or_return
	return reconcile_node(h, ov, root_h, tape.ROOT, result)
}

@(private = "file")
is_same_provenance :: proc "contextless" (ov: ^edit.Overlay, xv: Value, target_h: edit.Handle, base_node: tape.Node_Index) -> bool {
	if xv.kind == .Node && base_node != tape.NO_NODE && &(^Doc_Block)(xv.p).doc == ov.base && tape.Node_Index(xv.n) == base_node {
		return !edit.base_subtree_has_edits(ov, base_node)
	}
	if xv.kind == .Overlay {
		ob, _, en, ok := resolve_overlay(xv)
		if ok && ob.ov == ov {
			if target_h != edit.NO_HANDLE && xv.n == target_h.idx {
				return true
			}
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
reconcile_node :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, base_node: tape.Node_Index, val: Value) -> edit.Error {
	alloc := heap_allocator(h)
	Pair :: struct {
		target:    edit.Handle,
		base_node: tape.Node_Index,
		val:       Value, // held
	}
	stack := make([dynamic]Pair, 0, 16, alloc)
	defer {
		for p in stack {
			release(h, p.val)
		}
		delete(stack)
	}
	if _, aerr := append(&stack, Pair{target = target, base_node = base_node, val = retain(val)}); aerr != nil {
		release(h, val)
		return aerr
	}

	for len(stack) > 0 {
		cur := pop(&stack)
		defer release(h, cur.val)

		if is_same_provenance(ov, cur.val, cur.target, cur.base_node) {
			continue
		}

		cur_kind := edit.node_kind(ov, cur.target)
		val_type := type_of(cur.val)

		if cur_kind == .Object && val_type == .Object {
			eff, owned_keys, merr := edit.effective_members(ov, cur.target, alloc)
			if merr != nil {
				return merr
			}
			defer edit.destroy_effective_members(eff, owned_keys, alloc)

			Eff_Info :: struct {
				handle:   edit.Handle,
				base_val: tape.Node_Index,
			}
			Eff_Group :: struct {
				array_h:        edit.Handle,
				has_base:       bool,
				first_base_idx: int,
				items:          [dynamic]Eff_Info,
			}
			eff_groups := make(map[string]Eff_Group, len(eff), alloc)
			defer {
				for _, g in eff_groups {
					delete(g.items)
				}
				delete(eff_groups)
			}
			grouped := ov.base.format != nil && ov.base.format.dups == .Group
			replaced_arr := make(map[string]bool, 4, alloc)
			defer delete(replaced_arr)
			for m in eff {
				if grouped && m.base_val != tape.NO_NODE && !m.is_inserted && replaced_arr[m.key] {
					if g, ok_g := eff_groups[m.key]; ok_g {
						if !g.has_base {
							g.has_base = true
							g.first_base_idx = m.base_idx
							eff_groups[m.key] = g
						}
					}
					continue
				}
				g, g_exists := eff_groups[m.key]
				if !g_exists {
					g.array_h = edit.NO_HANDLE
					g.first_base_idx = -1
				}
				if m.base_val != tape.NO_NODE && !m.is_inserted && !g.has_base {
					g.has_base = true
					g.first_base_idx = m.base_idx
				}
				if grouped && m.handle != edit.NO_HANDLE {
					if cn, cok := edit.get_node(ov, m.handle); cok && cn.state == .Replaced && cn.val.kind == .Array {
						replaced_arr[m.key] = true
						g.array_h = m.handle
						if g.items.allocator.procedure == nil {
							g.items = make([dynamic]Eff_Info, 0, len(cn.elems), alloc)
						} else {
							clear(&g.items)
						}
						for eh in cn.elems {
							append(&g.items, Eff_Info{handle = eh, base_val = tape.NO_NODE}) or_return
						}
						eff_groups[m.key] = g
						continue
					}
				}
				if g.items.allocator.procedure == nil {
					g.items = make([dynamic]Eff_Info, 0, 1, alloc)
				}
				append(&g.items, Eff_Info{handle = m.handle, base_val = m.base_val}) or_return
				eff_groups[m.key] = g
			}

			kept := make(map[string]bool, len(eff_groups), alloc)
			defer delete(kept)

			vc, vs := cursor_open(h, cur.val)
			if vs != .Ok {
				return runtime.Allocator_Error.Out_Of_Memory
			}
			defer cursor_close(&vc)

			for {
				kv, xv, more, ns := cursor_next(h, &vc)
				if ns != .Ok {
					return runtime.Allocator_Error.Out_Of_Memory
				}
				if !more {
					break
				}
				kname := text_of(kv)
				if g, exists := eff_groups[kname]; exists {
					infos := g.items[:]
					kept[kname] = true
					if grouped && (g.array_h != edit.NO_HANDLE || len(infos) > 1 || (type_of(xv) == .Array && len(infos) == 1 && edit.node_kind(ov, infos[0].handle) != .Array)) {
						// Repeated XML element group: match elements 1:1 or update length cleanly.
						new_arr := type_of(xv) == .Array
						if !new_arr && (g.array_h != edit.NO_HANDLE || len(infos) > 1) {
							werr := collapse_grouped_xml_member(h, ov, cur.target, kname, g.first_base_idx, g.has_base, g.array_h, xv)
							release(h, kv)
							release(h, xv)
							if werr != nil {
								return werr
							}
							continue
						}
						new_n := length_of(h, xv) if new_arr else 1
						if new_n == len(infos) {
							for i in 0 ..< new_n {
								ev := retain(xv)
								if new_arr {
									es: Status
									ev, es = element(h, xv, i)
									if es != .Ok {
										release(h, kv)
										release(h, xv)
										return runtime.Allocator_Error.Out_Of_Memory
									}
								}
								info := infos[i]
								if is_same_provenance(ov, ev, info.handle, info.base_val) {
									release(h, ev)
									continue
								}
								ch := info.handle
								if ch == edit.NO_HANDLE {
									herr: edit.Error
									ch, herr = edit.handle_for_base(ov, info.base_val, cur.target)
									if herr != nil {
										release(h, ev)
										release(h, kv)
										release(h, xv)
										return herr
									}
								}
								if _, aerr := append(&stack, Pair{target = ch, base_node = info.base_val, val = ev}); aerr != nil {
									release(h, ev)
									release(h, kv)
									release(h, xv)
									return aerr
								}
							}
							release(h, kv)
							release(h, xv)
							continue
						}
						// Length changed: write onto the enclosing array-replaced handle `g.array_h` if present, else first member.
						ch := g.array_h
						if ch == edit.NO_HANDLE {
							first := infos[0]
							ch = first.handle
							if ch == edit.NO_HANDLE && first.base_val != tape.NO_NODE {
								ch = edit.handle_for_base(ov, first.base_val, cur.target) or_return
							}
						}
						werr := write_value_to_handle(h, ov, ch, xv)
						release(h, kv)
						release(h, xv)
						if werr != nil {
							return werr
						}
						continue
					}
					info := infos[0]
					if is_same_provenance(ov, xv, info.handle, info.base_val) {
						release(h, kv)
						release(h, xv)
						continue
					}
					ch := info.handle
					if ch == edit.NO_HANDLE {
						herr: edit.Error
						ch, herr = edit.handle_for_base(ov, info.base_val, cur.target)
						if herr != nil {
							release(h, kv)
							release(h, xv)
							return herr
						}
					}
					if _, aerr := append(&stack, Pair{target = ch, base_node = info.base_val, val = xv}); aerr != nil {
						release(h, kv)
						release(h, xv)
						return aerr
					}
					release(h, kv)
				} else {
					ch, cerr := edit.set_member(ov, cur.target, kname, edit.val_null())
					if cerr != nil {
						release(h, kv)
						release(h, xv)
						return cerr
					}
					werr := write_value_to_handle(h, ov, ch, xv)
					release(h, kv)
					release(h, xv)
					if werr != nil {
						return werr
					}
				}
			}
			for bk in eff_groups {
				if !kept[bk] {
					edit.del_member(ov, cur.target, bk) or_return
				}
			}
			continue
		}

		if cur_kind == .Array && val_type == .Array {
			eff, eerr := edit.effective_elements(ov, cur.target, alloc)
			if eerr != nil {
				return eerr
			}
			defer delete(eff, alloc)

			new_len := length_of(h, cur.val)
			common := min(len(eff), new_len)
			for i in 0 ..< common {
				xv, xs := element(h, cur.val, i)
				if xs != .Ok {
					return runtime.Allocator_Error.Out_Of_Memory
				}
				e := eff[i]
				if is_same_provenance(ov, xv, e.handle, e.base) {
					release(h, xv)
					continue
				}
				ch := e.handle
				if ch == edit.NO_HANDLE {
					herr: edit.Error
					ch, herr = edit.handle_for_base(ov, e.base, cur.target)
					if herr != nil {
						release(h, xv)
						return herr
					}
				}
				if _, aerr := append(&stack, Pair{target = ch, base_node = e.base, val = xv}); aerr != nil {
					release(h, xv)
					return aerr
				}
			}
			for i := len(eff) - 1; i >= new_len; i -= 1 {
				edit.del_element(ov, cur.target, i) or_return
			}
			for i in len(eff) ..< new_len {
				xv, xs := element(h, cur.val, i)
				if xs != .Ok {
					return runtime.Allocator_Error.Out_Of_Memory
				}
				ch, ierr := edit.insert_element(ov, cur.target, -1, edit.val_null())
				if ierr != nil {
					release(h, xv)
					return ierr
				}
				werr := write_value_to_handle(h, ov, ch, xv)
				release(h, xv)
				if werr != nil {
					return werr
				}
			}
			continue
		}

		write_value_to_handle(h, ov, cur.target, cur.val) or_return
	}
	return nil
}

// Writes arbitrary `Value` `x` (without releasing `x`) safely into existing overlay handle `target` via temp snapshot
// so same-overlay reads/writes (`.b = .a`, `.a = .`) never alias/clobber during overwrite!
@(private = "file")
write_handle_via_tmp :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, x: Value) -> edit.Error {
	tmp_h := edit.new_node(ov, edit.val_null()) or_return
	if werr := write_value_to_handle(h, ov, tmp_h, x); werr != nil {
		edit.discard_node(ov, tmp_h)
		return werr
	}
	if merr := edit.move_node_payload(ov, target, tmp_h); merr != nil {
		edit.discard_node(ov, tmp_h)
		return merr
	}
	return nil
}

// Collapses a multi-element or array-replaced XML group onto a single replacement value `xv` cleanly.
@(private = "file")
collapse_grouped_xml_member :: proc(
	h: ^Heap,
	ov: ^edit.Overlay,
	parent_h: edit.Handle,
	key: string,
	first_base_idx: int,
	has_base: bool,
	target_h: edit.Handle,
	xv: Value,
) -> edit.Error {
	if !has_base {
		return write_handle_via_tmp(h, ov, target_h, xv)
	}
	tmp_h := edit.new_node(ov, edit.val_null()) or_return
	if werr := write_value_to_handle(h, ov, tmp_h, xv); werr != nil {
		edit.discard_node(ov, tmp_h)
		return werr
	}
	for {
		_, _, found := edit.lookup_member(ov, parent_h, key)
		if !found {
			break
		}
		if derr := edit.del_member(ov, parent_h, key); derr != nil {
			edit.discard_node(ov, tmp_h)
			return derr
		}
	}
	ih, ierr := edit.insert_member(ov, parent_h, first_base_idx, key, edit.val_null())
	if ierr != nil {
		edit.discard_node(ov, tmp_h)
		return ierr
	}
	if merr := edit.move_node_payload(ov, ih, tmp_h); merr != nil {
		edit.discard_node(ov, tmp_h)
		return merr
	}
	return nil
}

// Unified setter for `overlay_set_member` (`is_member = true`) and `overlay_set_element` (`is_member = false`).
// Only skips when `x` IS the exact same target node (`cur_h.idx == x.n`); cross-slot same-overlay assignments
// (`.b = .a`, `.[1] = .[0]`, `.a = .`, `.a = .a.b`) snapshot `x` cleanly first before moving payload into target!
@(private, cold, require_results)
overlay_set_at :: proc(h: ^Heap, t: Value, key: string, idx: int, is_member: bool, x: Value) -> (res: Value, status: Status) {
	ob, eh, tn, ok := resolve_overlay(t)
	if !ok {
		release(h, t)
		release(h, x)
		return NULL, fail_fact_msg(h, "invalid overlay handle")
	}
	refresh_overlay_writer(h, ob)
	cur_h: edit.Handle
	cur_b: tape.Node_Index
	found: bool
	if is_member {
		cur_h, cur_b, found = edit.lookup_member(ob.ov, eh, key)
		// Grouped XML repeated-name writes: update surviving base elements 1:1 on match or collapse scalar cleanly!
		bn := edit.node_base_container(tn)
		if bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn)) {
			alloc := heap_allocator(h)
			members, owned_keys, merr := edit.effective_members(ob.ov, eh, alloc)
			if merr == nil {
				defer edit.destroy_effective_members(members, owned_keys, alloc)
				sibs := make([dynamic]edit.Effective_Member, 0, 4, alloc)
				defer delete(sibs)
				has_base := false
				first_base_idx := -1
				rep_arr_h := edit.NO_HANDLE
				for m in members {
					if m.key == key {
						append(&sibs, m)
						if m.base_val != tape.NO_NODE && !m.is_inserted && !has_base {
							has_base = true
							first_base_idx = m.base_idx
						}
						if rep_arr_h == edit.NO_HANDLE && m.handle != edit.NO_HANDLE {
							if cn, cok := edit.get_node(ob.ov, m.handle); cok && cn.state == .Replaced && cn.val.kind == .Array {
								rep_arr_h = m.handle
							}
						}
					}
				}
				has_rep_arr := rep_arr_h != edit.NO_HANDLE
				if type_of(x) != .Array && (has_rep_arr || len(sibs) > 1) {
					werr := collapse_grouped_xml_member(h, ob.ov, eh, key, first_base_idx, has_base, rep_arr_h, x)
					release(h, x)
					if werr != nil {
						release(h, t)
						return NULL, overlay_fail_edit(h, werr)
					}
					return t, .Ok
				}
				if type_of(x) == .Array && !has_rep_arr && len(sibs) > 1 {
					xlen := length_of(h, x)
					if xlen == len(sibs) {
						for i in 0 ..< xlen {
							ev, es := element(h, x, i)
							if es != .Ok {
								release(h, t)
								release(h, x)
								return NULL, es
							}
							defer release(h, ev)
							sm := sibs[i]
							if (sm.handle != edit.NO_HANDLE && ev.kind == .Overlay && (^Overlay_Block)(ev.p).ov == ob.ov && ev.n == sm.handle.idx) ||
								is_same_provenance(ob.ov, ev, sm.handle, sm.base_val) {
								continue
							}
							sh := sm.handle
							if sh == edit.NO_HANDLE {
								herr: edit.Error
								sh, herr = edit.handle_for_base(ob.ov, sm.base_val, eh)
								if herr != nil {
									release(h, t)
									release(h, x)
									return NULL, overlay_fail_edit(h, herr)
								}
							}
							if werr := write_handle_via_tmp(h, ob.ov, sh, ev); werr != nil {
								release(h, t)
								release(h, x)
								return NULL, overlay_fail_edit(h, werr)
							}
						}
						release(h, x)
						return t, .Ok
					}
				}
			}
		}
	} else {
		cur_h, cur_b, found = edit.lookup_element(ob.ov, eh, idx)
	}
	_ = cur_b
	// Self-assignment (`cur == x`) is a genuine no-op; any other handle (e.g. `.b = .a`, `.[1] = .[0]`) must write!
	if x.kind == .Overlay && (^Overlay_Block)(x.p).ov == ob.ov && found && cur_h != edit.NO_HANDLE && cur_h.idx == x.n {
		release(h, x)
		return t, .Ok
	}
	tmp_h, terr := edit.new_node(ob.ov, edit.val_null())
	if terr != nil {
		release(h, t)
		release(h, x)
		return NULL, overlay_fail_edit(h, terr)
	}
	werr := write_value_to_handle(h, ob.ov, tmp_h, x)
	release(h, x)
	if werr != nil {
		edit.discard_node(ob.ov, tmp_h)
		release(h, t)
		return NULL, overlay_fail_edit(h, werr)
	}
	ch: edit.Handle
	serr: edit.Error
	if is_member {
		ch, serr = edit.set_member(ob.ov, eh, key, edit.val_null())
	} else {
		ch, serr = edit.set_element(ob.ov, eh, idx, edit.val_null())
	}
	if serr != nil {
		edit.discard_node(ob.ov, tmp_h)
		release(h, t)
		return NULL, overlay_fail_edit(h, serr)
	}
	if merr := edit.move_node_payload(ob.ov, ch, tmp_h); merr != nil {
		edit.discard_node(ob.ov, tmp_h)
		release(h, t)
		return NULL, overlay_fail_edit(h, merr)
	}
	return t, .Ok
}

@(private, cold, require_results)
overlay_set_member :: #force_no_inline proc(h: ^Heap, t: Value, key: string, x: Value) -> (res: Value, status: Status) {
	return overlay_set_at(h, t, key, 0, true, x)
}

@(private, cold, require_results)
overlay_set_element :: #force_no_inline proc(h: ^Heap, t: Value, i: int, x: Value) -> (res: Value, status: Status) {
	return overlay_set_at(h, t, "", i, false, x)
}

@(private, cold, require_results)
overlay_del_members :: #force_no_inline proc(h: ^Heap, t: Value, keys: []Value) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(t)
	if !ok {
		release(h, t)
		return NULL, fail_fact_msg(h, "invalid overlay handle")
	}
	refresh_overlay_writer(h, ob)
	for k in keys {
		if type_of(k) != .String {
			s := fail(h, .Types, .Delete_Paths, t, k, "field of object")
			release(h, t)
			return NULL, s
		}
	}
	for k in keys {
		if derr := edit.del_member(ob.ov, eh, text_of(k)); derr != nil {
			release(h, t)
			return NULL, overlay_fail_edit(h, derr)
		}
	}
	return t, .Ok
}

@(private, cold, require_results)
overlay_del_elements :: #force_no_inline proc(h: ^Heap, t: Value, gone: []bool) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(t)
	if !ok {
		release(h, t)
		return NULL, fail_fact_msg(h, "invalid overlay handle")
	}
	refresh_overlay_writer(h, ob)
	for i := len(gone) - 1; i >= 0; i -= 1 {
		if gone[i] {
			if derr := edit.del_element(ob.ov, eh, i); derr != nil {
				release(h, t)
				return NULL, overlay_fail_edit(h, derr)
			}
		}
	}
	return t, .Ok
}
