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
	return Value{p = ob, n = root_h.idx, kind = .Overlay, held = true}, .Ok
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
	h.write_fact = overlay_write_fact
	h.write_fact_data = ob
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

// Returns the underlying `Doc_Block` and base `Node_Index` of an `.Overlay` (for `jq/css` and `where`).
overlay_doc_origin :: proc "contextless" (v: Value) -> (d: ^Doc_Block, at: tape.Node_Index, ok: bool) {
	ob, _, n, valid := resolve_overlay(v)
	if !valid || ob.doc_block == nil {
		return nil, tape.NO_NODE, false
	}
	bn := edit.node_base_container(n)
	if bn == tape.NO_NODE {
		return nil, tape.NO_NODE, false
	}
	return ob.doc_block, bn, true
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
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return Value{p = ob.doc_block, n = u32(bn), kind = .Node}
	}
	return NULL
}

// Returns the raw decimal literal bytes of an `.Overlay` number if it can be emitted verbatim as JSON.
@(private, cold)
overlay_number_literal :: proc "contextless" (v: Value) -> ([]u8, bool) {
	ob, _, n, ok := resolve_overlay(v)
	if !ok {
		return nil, false
	}
	if n.state == .Replaced {
		if n.val.kind == .Number_Text {
			return transmute([]u8)n.val.text, true
		}
		if n.val.kind == .Base_Ref && n.val.base_ref != tape.NO_NODE {
			d := ob.doc_block
			if d.doc.format == nil || .Binary not_in d.doc.format.caps {
				return node_bytes(Value{p = d, n = u32(n.val.base_ref), kind = .Node}), true
			}
		}
		return nil, false
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		d := ob.doc_block
		if d.doc.format == nil || .Binary not_in d.doc.format.caps {
			return node_bytes(Value{p = d, n = u32(bn), kind = .Node}), true
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
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE {
				return node_big_int(Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node})
			}
		}
		return
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return node_big_int(Value{p = ob.doc_block, n = u32(bn), kind = .Node})
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
			if pok {
				return parsed, .Ok
			}
			return double_value(math.nan_f64()), .Ok
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE {
				return number_of(h, Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node})
			}
		}
		return NULL, .Ok
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return number_of(h, Value{p = ob.doc_block, n = u32(bn), kind = .Node})
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
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE {
				return as_f64(Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node})
			}
		}
		return 0
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return as_f64(Value{p = ob.doc_block, n = u32(bn), kind = .Node})
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
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE {
				return as_i64(Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node})
			}
		}
		return 0, false
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return as_i64(Value{p = ob.doc_block, n = u32(bn), kind = .Node})
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
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE {
				return is_integer(Value{p = ob.doc_block, n = u32(n.val.base_ref), kind = .Node})
			}
		}
		return false
	}
	if bn := edit.node_base_container(n); bn != tape.NO_NODE {
		return is_integer(Value{p = ob.doc_block, n = u32(bn), kind = .Node})
	}
	return false
}

@(private, cold)
overlay_length :: #force_no_inline proc(h: ^Heap, v: Value) -> int {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return 0
	}
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
	ch, cb, found := edit.lookup_element(ob.ov, eh, i)
	if !found {
		return ABSENT, .Ok
	}
	return overlay_wrap_child(h, ob, ch, cb)
}

// Member `key` of an `.Overlay` object (supporting XML repeated-name grouping in BOTH `.Ancestor` and `.Container_Delta`!).
@(private, cold, require_results)
overlay_member :: #force_no_inline proc(h: ^Heap, v: Value, key: string) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return ABSENT, .Ok
	}
	bn := edit.node_base_container(n)
	if bn != tape.NO_NODE && groups_names(ob.doc_block, u32(bn)) {
		if n.state == .Ancestor {
			return overlay_group_member(h, ob, bn, key)
		}
		if n.state == .Container_Delta {
			return overlay_group_member_delta(h, ob, eh, key)
		}
	}
	ch, cb, found := edit.lookup_member(ob.ov, eh, key)
	if !found {
		return ABSENT, .Ok
	}
	return overlay_wrap_child(h, ob, ch, cb)
}

@(private = "file", require_results)
overlay_group_member :: proc(h: ^Heap, ob: ^Overlay_Block, at: tape.Node_Index, key: string) -> (res: Value, status: Status) {
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
		ch := ob.ov.by_base[node] or_else edit.NO_HANDLE
		x, s := overlay_wrap_child(h, ob, ch, node)
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
	for m in members {
		if m.key != key {
			continue
		}
		x, s := overlay_wrap_child(h, ob, m.handle, m.base_val)
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

// Wraps child `(ch, cb)` of `ob` into a `Value`.
// Containers stay `.Overlay` so nested updates remain O(1); base scalars with `SPELLING_DECODE`/`.Bytes`
// are ALWAYS decoded via `node_value(..., force_origin = true)` so `text_of` never sees raw escaped bytes!
@(private, require_results)
overlay_wrap_child :: proc(h: ^Heap, ob: ^Overlay_Block, ch: edit.Handle, cb: tape.Node_Index) -> (res: Value, status: Status) {
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
			if cn.val.kind == .Base_Ref && cn.val.base_ref != tape.NO_NODE {
				return node_value(h, ob.doc_block, cn.val.base_ref, force_origin = true)
			}
			// Keep `.Overlay` on replaced scalars (already decoded in `cn.val`) so subsequent fact writes
			// like `.a = 42 | .a.@comment = "note"` retain their exact `Overlay` handle!
			return overlay_child_ref(ob, ch), .Ok
		}
		// `.Ancestor` scalar with fact overrides: if base node requires decoding (`.Bytes` or `SPELLING_DECODE`),
		// return decoded `node_value(..., force_origin = true)` so `text_of` gets decoded UTF-8 AND `fact_read`
		// still reads the overlay overrides via `h.write_fact_data`!
		if cn.base != tape.NO_NODE {
			bt := ob.doc_block.doc.nodes[cn.base]
			if bt.kind == .Bytes || bt.spelling & tape.SPELLING_DECODE != 0 {
				return node_value(h, ob.doc_block, cn.base, force_origin = true)
			}
			if len(cn.facts) > 0 {
				return overlay_child_ref(ob, ch), .Ok
			}
			return node_value(h, ob.doc_block, cn.base, force_origin = true)
		}
		return overlay_child_ref(ob, ch), .Ok
	}
	if cb != tape.NO_NODE {
		if ob.doc_block.doc.nodes[cb].kind >= .Array {
			nh, herr := edit.handle_for_base(ob.ov, cb)
			if herr != nil {
				return NULL, overlay_fail_edit(h, herr)
			}
			return overlay_child_ref(ob, nh), .Ok
		}
		return node_value(h, ob.doc_block, cb, force_origin = true)
	}
	return ABSENT, .Ok
}

@(private, cold)
overlay_has_member :: #force_no_inline proc(h: ^Heap, v: Value, key: string) -> bool {
	ob, eh, _, ok := resolve_overlay(v)
	if !ok {
		return false
	}
	_, _, found := edit.lookup_member(ob.ov, eh, key)
	_ = h
	return found
}

// Materializes an `.Overlay` container into a fresh built `Array_Block` or `Object_Block` (preserving XML `.Group`!).
@(private, cold, require_results)
overlay_built :: #force_no_inline proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	ob, eh, n, ok := resolve_overlay(v)
	if !ok {
		return NULL, .Ok
	}
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
			cv := overlay_wrap_child(h, ob, e.handle, e.base) or_return
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
		for m in members {
			cv := overlay_wrap_child(h, ob, m.handle, m.base_val) or_return
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
		return fact_read(h, Value{p = ob.doc_block, n = u32(bn), kind = .Node}, kind, attr, is_attr)
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

// `Heap.write_fact` implementation backed by `edit.Overlay`.
overlay_write_fact :: proc(
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
	ob: ^Overlay_Block
	eh: edit.Handle

	if v.kind == .Overlay {
		ov_ob, ov_eh, _, ok := resolve_overlay(v)
		if !ok {
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "invalid overlay handle for fact write")
		}
		ob, eh = ov_ob, ov_eh
	} else {
		ob = (^Overlay_Block)(data)
		if ob == nil || ob.ov == nil {
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "fact writes require an overlay")
		}
		if d, at, from_doc := value_doc_origin(v, true); from_doc && &d.doc == ob.ov.base {
			herr: edit.Error
			eh, herr = edit.handle_for_base(ob.ov, at)
			if herr != nil {
				release(h, v)
				release(h, nv)
				return NULL, overlay_fail_edit(h, herr)
			}
		} else {
			release(h, v)
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
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, msg)
		}
		vals := [1]string{text_of(nv)}
		edit_err = edit.set_fact(ob.ov, eh, .Attribute, vals[:], attr)
	} else if kind == .Comment || kind == .Comment_Inline || kind == .Comment_Foot {
		if nt == .String {
			vals := [1]string{text_of(nv)}
			if msg, bad := validate_fact_write_group1(ob.ov, kind, vals[:], ""); bad {
				release(h, v)
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
				release(h, v)
				release(h, nv)
				return NULL, cs
			}
			defer cursor_close(&c)
			for {
				_, elem, more, ns := cursor_next(h, &c)
				if ns != .Ok {
					release(h, v)
					release(h, nv)
					return NULL, ns
				}
				if !more {
					break
				}
				if _, aerr := append(&owned_vals, elem); aerr != nil {
					release(h, elem)
					release(h, v)
					release(h, nv)
					return NULL, fail_memory(h)
				}
				if _, aerr := append(&lines, text_of(elem)); aerr != nil {
					release(h, v)
					release(h, nv)
					return NULL, fail_memory(h)
				}
			}
			if len(lines) == 0 {
				edit_err = edit.del_fact(ob.ov, eh, kind)
			} else if msg, bad := validate_fact_write_group1(ob.ov, kind, lines[:], ""); bad {
				release(h, v)
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
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "numeric tag must be an unsigned 64-bit integer")
		}
	} else {
		vals := [1]string{text_of(nv)}
		edit_err = edit.set_fact(ob.ov, eh, kind, vals[:])
	}

	release(h, nv)
	if edit_err != nil {
		release(h, v)
		return NULL, overlay_fail_edit(h, edit_err)
	}
	if v.kind == .Overlay {
		return v, .Ok
	}
	release(h, v)
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
		if ok && ob.ov == ov {
			if !ov.unlinked_parents && n.state == .Ancestor && !n.has_edits && n.base != tape.NO_NODE && len(n.facts) == 0 {
				return true
			}
			if n.state == .Replaced && n.val.kind == .Base_Ref && len(n.facts) == 0 {
				return true
			}
		}
	}
	t := type_of(v)
	return t != .Array && t != .Object
}

// Sets `target` directly if `v` is a scalar or a zero-copy `.Base_Ref` provenance match (returns `done = true`).
// Never returns a dangling pointer to a temporary buffer (clones directly via `edit.set` before freeing!).
@(private)
try_set_leaf_or_ref :: proc(h: ^Heap, ov: ^edit.Overlay, target: edit.Handle, v: Value) -> (done: bool, err: edit.Error) {
	// Zero-copy provenance: untouched `.Node` from `ov.base` -> `.Base_Ref`!
	if v.kind == .Node && &(^Doc_Block)(v.p).doc == ov.base {
		return true, edit.set(ov, target, edit.val_base_ref(tape.Node_Index(v.n)))
	}
	// Zero-copy provenance: unedited `.Overlay` `.Ancestor` (or `.Base_Ref`) belonging to `ov` -> `.Base_Ref`!
	if v.kind == .Overlay {
		ob, _, n, ok := resolve_overlay(v)
		if ok && ob.ov == ov {
			if !ov.unlinked_parents && n.state == .Ancestor && !n.has_edits && n.base != tape.NO_NODE && len(n.facts) == 0 {
				return true, edit.set(ov, target, edit.val_base_ref(n.base))
			}
			if n.state == .Replaced && n.val.kind == .Base_Ref && len(n.facts) == 0 {
				return true, edit.set(ov, target, edit.val_base_ref(n.val.base_ref))
			}
		}
	}
	switch type_of(v) {
	case .Absent, .Null:
		return true, edit.set(ov, target, edit.val_null())
	case .False:
		return true, edit.set(ov, target, edit.val_bool(false))
	case .True:
		return true, edit.set(ov, target, edit.val_bool(true))
	case .Number:
		if i, iok := as_i64(v); iok {
			return true, edit.set(ov, target, edit.val_int(i))
		}
		if v.kind == .Big || is_integer(v) {
			alloc := heap_allocator(h)
			buf := make([dynamic]u8, 0, 32, alloc)
			defer delete(buf)
			if s := write_json(h, &buf, v); s == .Ok {
				// `edit.set` clones `string(buf[:])` into `ov.allocator` BEFORE `defer delete(buf)`!
				return true, edit.set(ov, target, edit.val_number_text(string(buf[:])))
			}
			return true, runtime.Allocator_Error.Out_Of_Memory
		}
		return true, edit.set(ov, target, edit.val_float(as_f64(v)))
	case .String:
		return true, edit.set(ov, target, edit.val_string(text_of(v)))
	case .Array, .Object:
		return false, nil
	}
	return true, edit.set(ov, target, edit.val_null())
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
	root_h := edit.ensure_root(ov) or_return
	return reconcile_node(h, ov, root_h, tape.ROOT, result)
}

@(private = "file")
is_same_provenance :: proc "contextless" (ov: ^edit.Overlay, xv: Value, target_h: edit.Handle, base_node: tape.Node_Index) -> bool {
	if xv.kind == .Node && base_node != tape.NO_NODE && &(^Doc_Block)(xv.p).doc == ov.base && tape.Node_Index(xv.n) == base_node {
		return true
	}
	if xv.kind == .Overlay {
		ob, _, en, ok := resolve_overlay(xv)
		if ok && ob.ov == ov {
			if target_h != edit.NO_HANDLE && xv.n == target_h.idx {
				return true
			}
			if base_node != tape.NO_NODE && en.base == base_node {
				return true
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
			eff_map := make(map[string]Eff_Info, len(eff), alloc)
			defer delete(eff_map)
			for m in eff {
				eff_map[m.key] = {handle = m.handle, base_val = m.base_val}
			}

			kept := make(map[string]bool, len(eff), alloc)
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
				if info, exists := eff_map[kname]; exists {
					kept[kname] = true
					if is_same_provenance(ov, xv, info.handle, info.base_val) {
						release(h, kv)
						release(h, xv)
						continue
					}
					ch := info.handle
					if ch == edit.NO_HANDLE {
						herr: edit.Error
						ch, herr = edit.handle_for_base(ov, info.base_val)
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
			for bk in eff_map {
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
					ch, herr = edit.handle_for_base(ov, e.base)
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

@(private, cold, require_results)
overlay_set_member :: #force_no_inline proc(h: ^Heap, t: Value, key: string, x: Value) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(t)
	if !ok {
		release(h, t)
		release(h, x)
		return NULL, fail_fact_msg(h, "invalid overlay handle")
	}
	if x.kind == .Overlay && (^Overlay_Block)(x.p).ov == ob.ov {
		release(h, x)
		return t, .Ok
	}
	ch, serr := edit.set_member(ob.ov, eh, key, edit.val_null())
	if serr != nil {
		release(h, t)
		release(h, x)
		return NULL, overlay_fail_edit(h, serr)
	}
	werr := write_value_to_handle(h, ob.ov, ch, x)
	release(h, x)
	if werr != nil {
		release(h, t)
		return NULL, overlay_fail_edit(h, werr)
	}
	return t, .Ok
}

@(private, cold, require_results)
overlay_set_element :: #force_no_inline proc(h: ^Heap, t: Value, i: int, x: Value) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(t)
	if !ok {
		release(h, t)
		release(h, x)
		return NULL, fail_fact_msg(h, "invalid overlay handle")
	}
	if x.kind == .Overlay && (^Overlay_Block)(x.p).ov == ob.ov {
		release(h, x)
		return t, .Ok
	}
	ch, serr := edit.set_element(ob.ov, eh, i, edit.val_null())
	if serr != nil {
		release(h, t)
		release(h, x)
		return NULL, overlay_fail_edit(h, serr)
	}
	werr := write_value_to_handle(h, ob.ov, ch, x)
	release(h, x)
	if werr != nil {
		release(h, t)
		return NULL, overlay_fail_edit(h, werr)
	}
	return t, .Ok
}

@(private, cold, require_results)
overlay_del_members :: #force_no_inline proc(h: ^Heap, t: Value, keys: []Value) -> (res: Value, status: Status) {
	ob, eh, _, ok := resolve_overlay(t)
	if !ok {
		release(h, t)
		return NULL, fail_fact_msg(h, "invalid overlay handle")
	}
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
