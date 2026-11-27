package edit

import "base:runtime"
import "core:container/handle_map"
import "core:container/xar"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// Sparse, handle-addressed delta tree over an immutable `base: ^tape.Document`.

Handle :: struct {
	idx, gen: u32,
}

NO_HANDLE :: Handle{}

Value_Kind :: enum u8 {
	None, Null, False, True, Int, Uint, Float, Number_Text, String, Bytes, Raw, Array, Object, Base_Ref,
}

Edit_Value :: struct {
	kind: Value_Kind,
	using _: struct #raw_union {
		i:        i64,
		u:        u64,
		f:        f64,
		text:     string,
		raw:      []u8,
		base_ref: tape.Node_Index,
		elems:    []Handle,
		entries:  []Object_Entry,
	},
}

Object_Entry :: struct {
	key:   string,
	value: Handle,
}

Node_State :: enum u8 { Ancestor, Replaced, Container_Delta }

Member_Insert :: struct {
	at:    int,
	key:   string,
	value: Handle,
}

Member_Rename :: struct {
	old_key, new_key: string,
	base_idx:         int,
}

Array_Insert :: struct {
	at:    int,
	value: Handle,
}

Container_Delta :: struct {
	deleted_keys:     [dynamic]string,
	inserted_members: [dynamic]Member_Insert,
	renamed_members:  [dynamic]Member_Rename,
	deleted_indices:  [dynamic]u32,
	inserted_elems:   [dynamic]Array_Insert,
	order:            []u32,
}

Fact_Override :: struct {
	kind:    tape.Fact_Kind,
	attr:    string,
	deleted: bool,
	values:  []string,
	num_tag: Maybe(u64),
	padded:  bool,
}

Edit_Node :: struct {
	handle:              Handle,
	base, base_ref:      tape.Node_Index,
	parent:              Handle,
	state:               Node_State,
	val_inline, has_edits: bool,
	val:                 Edit_Value,
	inline_buf:          [16]u8,
	elems:               [dynamic]Handle,
	members:             [dynamic]Object_Entry,
	delta:               ^Container_Delta,
	facts:               [dynamic]Fact_Override,
}

Overlay :: struct {
	base:                               ^tape.Document,
	allocator:                          runtime.Allocator,
	nodes:                              handle_map.Dynamic_Handle_Map(Edit_Node, Handle),
	root:                               Handle,
	by_base:                            map[tape.Node_Index]Handle,
	parents:                            []tape.Node_Index,
	present:                            tape.Facts,
	dirty, unlinked_parents, has_structural: bool,
}

init :: proc(ov: ^Overlay, base: ^tape.Document, allocator := context.allocator) -> Error {
	if base == nil || len(base.nodes) == 0 {
		return refuse(.No_Document, "overlay requires a built document")
	}
	if base.partial != nil {
		return refuse(.Partial_Document, "cannot edit a partial document")
	}
	ov^ = {base = base, allocator = allocator, present = base.present}
	handle_map.dynamic_init(&ov.nodes, allocator)
	ov.by_base = make(map[tape.Node_Index]Handle, 16, allocator)
	return nil
}

destroy :: proc(ov: ^Overlay) {
	if ov.allocator.procedure == nil {
		ov^ = {}
		return
	}
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) { free_edit_node(ov, n) }
	handle_map.dynamic_destroy(&ov.nodes)
	delete(ov.by_base)
	delete(ov.parents, ov.allocator)
	ov^ = {}
}

@(private)
dynamic_iter_next :: proc "contextless" (it: ^handle_map.Dynamic_Handle_Map_Iterator(handle_map.Dynamic_Handle_Map(Edit_Node, Handle))) -> (^Edit_Node, bool) {
	for it.index < xar.len(it.m.items) {
		p := xar.get_ptr_unsafe(&it.m.items, it.index)
		it.index += 1
		if p.handle.idx != 0 { return p, true }
	}
	return nil, false
}

@(private = "file")
ov_append :: proc(ov: ^Overlay, arr: ^[dynamic]$T, val: T, init_cap := 4) -> runtime.Allocator_Error {
	if arr.allocator.procedure == nil {
		arr^ = make([dynamic]T, 0, init_cap, ov.allocator) or_return
	}
	_, err := append(arr, val)
	return err
}

@(private = "file")
ov_inject_at :: proc(ov: ^Overlay, arr: ^[dynamic]$T, at: int, val: T) -> runtime.Allocator_Error {
	if arr.allocator.procedure == nil {
		arr^ = make([dynamic]T, 0, 4, ov.allocator) or_return
	}
	_, err := inject_at(arr, len(arr^) if at < 0 || at > len(arr^) else at, val)
	return err
}

@(private = "file")
ov_append_str :: proc(ov: ^Overlay, arr: ^[dynamic]string, s: string, init_cap := 4) -> runtime.Allocator_Error {
	k := clone_str(ov, s) or_return
	if err := ov_append(ov, arr, k, init_cap); err != nil {
		delete(k, ov.allocator)
		return err
	}
	return nil
}

@(private = "file")
ov_append_entry :: proc(ov: ^Overlay, arr: ^[dynamic]Object_Entry, key: string, val: Handle, init_cap := 4) -> runtime.Allocator_Error {
	k := clone_str(ov, key) or_return
	if err := ov_append(ov, arr, Object_Entry{k, val}, init_cap); err != nil {
		delete(k, ov.allocator)
		return err
	}
	return nil
}

@(private = "file")
ov_append_member_ins :: proc(ov: ^Overlay, arr: ^[dynamic]Member_Insert, at: int, key: string, val: Handle, init_cap := 4) -> runtime.Allocator_Error {
	k := clone_str(ov, key) or_return
	if err := ov_append(ov, arr, Member_Insert{at, k, val}, init_cap); err != nil {
		delete(k, ov.allocator)
		return err
	}
	return nil
}

@(private = "file")
ov_append_rename :: proc(ov: ^Overlay, arr: ^[dynamic]Member_Rename, old_key, new_key: string, bidx: int, init_cap := 2) -> runtime.Allocator_Error {
	ok_s := clone_str(ov, old_key) or_return
	nk_s, nerr := clone_str(ov, new_key)
	if nerr != nil {
		delete(ok_s, ov.allocator)
		return nerr
	}
	if aerr := ov_append(ov, arr, Member_Rename{ok_s, nk_s, bidx}, init_cap); aerr != nil {
		delete(ok_s, ov.allocator)
		delete(nk_s, ov.allocator)
		return aerr
	}
	return nil
}

@(private = "file")
replace_cloned_str :: proc(ov: ^Overlay, dst: ^string, s: string) -> runtime.Allocator_Error {
	nk := clone_str(ov, s) or_return
	delete(dst^, ov.allocator)
	dst^ = nk
	return nil
}

@(private)
ensure_delta :: proc(ov: ^Overlay, n: ^Edit_Node) -> (res: ^Container_Delta, err: runtime.Allocator_Error) {
	if n.delta != nil { return n.delta, nil }
	d := new(Container_Delta, ov.allocator) or_return
	n.delta = d
	return d, nil
}

@(private)
free_container_delta :: proc(ov: ^Overlay, d: ^Container_Delta) {
	if d == nil { return }
	a := ov.allocator
	for k in d.deleted_keys { delete(k, a) }
	for ins in d.inserted_members { delete(ins.key, a) }
	for r in d.renamed_members { delete(r.old_key, a); delete(r.new_key, a) }
	delete(d.deleted_keys)
	delete(d.inserted_members)
	delete(d.renamed_members)
	delete(d.deleted_indices)
	delete(d.inserted_elems)
	delete(d.order, a)
	free(d, a)
}

@(private)
reset_node_deltas :: proc(ov: ^Overlay, n: ^Edit_Node) {
	free_edit_value(ov, &n.val, n.val_inline)
	n.val_inline = false
	clear(&n.elems)
	for m in n.members { delete(m.key, ov.allocator) }
	clear(&n.members)
	free_container_delta(ov, n.delta)
	n.delta, n.base_ref = nil, tape.NO_NODE
}

@(private)
free_edit_node :: proc(ov: ^Overlay, n: ^Edit_Node) {
	reset_node_deltas(ov, n)
	delete(n.elems)
	delete(n.members)
	for &f in n.facts { free_fact_override(ov, &f) }
	delete(n.facts)
}

@(private)
free_edit_value :: proc(ov: ^Overlay, v: ^Edit_Value, is_inline := false) {
	if !is_inline {
		#partial switch v.kind {
		case .String, .Number_Text, .Raw: delete(v.text, ov.allocator)
		case .Bytes: delete(v.raw, ov.allocator)
		}
	}
	v^ = {}
}

@(private)
free_fact_override :: proc(ov: ^Overlay, f: ^Fact_Override) {
	delete(f.attr, ov.allocator)
	for s in f.values { delete(s, ov.allocator) }
	delete(f.values, ov.allocator)
	f^ = {}
}

@(private)
clone_str :: proc(ov: ^Overlay, s: string) -> (string, runtime.Allocator_Error) {
	if len(s) == 0 { return "", nil }
	return strings.clone(s, ov.allocator)
}

@(private)
clone_value :: proc(ov: ^Overlay, v: Edit_Value) -> (out: Edit_Value, err: runtime.Allocator_Error) {
	out.kind = v.kind
	#partial switch v.kind {
	case .Int: out.i = v.i
	case .Uint: out.u = v.u
	case .Float: out.f = v.f
	case .Base_Ref: out.base_ref = v.base_ref
	case .String, .Number_Text, .Raw: out.text = clone_str(ov, v.text) or_return
	case .Bytes:
		if len(v.raw) > 0 { out.raw = slice.clone(v.raw, ov.allocator) or_return }
	}
	return out, nil
}

@(private)
link_children_parent :: proc "contextless" (ov: ^Overlay, parent: Handle, n: ^Edit_Node) {
	set_p :: proc "contextless" (ov: ^Overlay, ch, parent: Handle) {
		if cn, cok := get_node(ov, ch); cok { cn.parent = parent }
	}
	for eh in n.elems { set_p(ov, eh, parent) }
	for entry in n.members { set_p(ov, entry.value, parent) }
	if d := n.delta; d != nil {
		for ins in d.inserted_members { set_p(ov, ins.value, parent) }
		for ins in d.inserted_elems { set_p(ov, ins.value, parent) }
	}
}

@(private = "file")
clone_children :: proc(ov: ^Overlay, val: Edit_Value) -> (elems: [dynamic]Handle, members: [dynamic]Object_Entry, err: runtime.Allocator_Error) {
	if val.kind == .Array && len(val.elems) > 0 {
		elems = make([dynamic]Handle, len(val.elems), ov.allocator) or_return
		copy(elems[:], val.elems)
	} else if val.kind == .Object && len(val.entries) > 0 {
		defer if err != nil {
			for m in members { delete(m.key, ov.allocator) }
			delete(members)
		}
		for entry in val.entries {
			ov_append_entry(ov, &members, entry.key, entry.value, len(val.entries)) or_return
		}
	}
	return elems, members, nil
}

is_live_base_node :: #force_inline proc "contextless" (n: ^Edit_Node) -> bool {
	return n.base != tape.NO_NODE && n.base_ref == tape.NO_NODE && !(n.state == .Replaced && n.val.kind == .Base_Ref)
}

node_base_container :: proc "contextless" (n: ^Edit_Node) -> tape.Node_Index {
	if n.state == .Replaced {
		return n.val.base_ref if n.val.kind == .Base_Ref else tape.NO_NODE
	}
	return n.base_ref if n.base_ref != tape.NO_NODE else n.base
}

@(private = "file")
base_child_count :: proc "contextless" (ov: ^Overlay, n: ^Edit_Node) -> int {
	bc := node_base_container(n)
	return 0 if bc == tape.NO_NODE else max(0, tape.child_count(ov.base, bc, ov.base.nodes[bc]))
}

@(private)
enter_container_delta :: proc(ov: ^Overlay, n: ^Edit_Node) -> (^Container_Delta, runtime.Allocator_Error) {
	if n.state == .Replaced && n.val.kind == .Base_Ref {
		n.base_ref, n.val = n.val.base_ref, {}
	}
	n.state, ov.has_structural = .Container_Delta, true
	return ensure_delta(ov, n)
}

get_node :: proc "contextless" (ov: ^Overlay, h: Handle) -> (^Edit_Node, bool) {
	if ov == nil || h == NO_HANDLE { return nil, false }
	return handle_map.dynamic_get(&ov.nodes, h)
}

get_node_by_idx :: proc "contextless" (ov: ^Overlay, idx: u32) -> (^Edit_Node, bool) {
	if ov == nil || idx == 0 || int(idx) >= xar.len(ov.nodes.items) { return nil, false }
	p := xar.get_ptr_unsafe(&ov.nodes.items, idx)
	if p.handle.idx != idx { return nil, false }
	return p, true
}

@(private = "file")
require_container :: proc "contextless" (ov: ^Overlay, h: Handle, want: tape.Kind, msg: string) -> (^Edit_Node, Error) {
	n, ok := get_node(ov, h)
	if !ok { return nil, refuse(.Bad_Handle, "invalid overlay handle") }
	k := node_kind(ov, h)
	if (want == .End && k != .Array && k != .Object) || (want != .End && k != want) {
		return nil, refuse(.Wrong_Container, msg, n.base)
	}
	return n, nil
}

ensure_root :: proc(ov: ^Overlay) -> (res: Handle, err: Error) {
	if ov.root != NO_HANDLE { return ov.root, nil }
	h := handle_map.dynamic_add(&ov.nodes, Edit_Node{base = tape.ROOT, base_ref = tape.NO_NODE, state = .Ancestor}) or_return
	ov.root, ov.by_base[tape.ROOT] = h, h
	return h, nil
}

@(private)
ensure_parents :: proc(ov: ^Overlay) -> runtime.Allocator_Error {
	if ov.parents != nil { return nil }
	n := len(ov.base.nodes)
	parents := make([]tape.Node_Index, n, ov.allocator) or_return
	slice.fill(parents, tape.NO_NODE)
	Frame :: struct { container, end: tape.Node_Index }
	stack := make([dynamic]Frame, 0, 32, ov.allocator)
	defer delete(stack)
	for t, i in ov.base.nodes {
		idx := tape.Node_Index(i)
		for len(stack) > 0 && idx >= stack[len(stack) - 1].end { pop(&stack) }
		if len(stack) > 0 { parents[i] = stack[len(stack) - 1].container }
		if t.kind >= .Array && t.n > 1 { append(&stack, Frame{idx, idx + tape.Node_Index(t.n)}) or_return }
	}
	ov.parents = parents
	return nil
}

handle_for_base :: proc(ov: ^Overlay, base_node: tape.Node_Index, parent := NO_HANDLE) -> (Handle, Error) {
	return handle_for_base_with_parent(ov, base_node, parent)
}

@(private)
handle_for_base_with_parent :: proc(ov: ^Overlay, base_node: tape.Node_Index, parent_h: Handle) -> (res: Handle, err: Error) {
	if base_node == tape.NO_NODE || int(base_node) >= len(ov.base.nodes) {
		return NO_HANDLE, refuse(.Bad_Handle, "base node out of range", base_node)
	}
	if h, ok := ov.by_base[base_node]; ok {
		if parent_h != NO_HANDLE && base_node != tape.ROOT {
			if cn, cok := get_node(ov, h); cok && cn.parent == NO_HANDLE {
				cn.parent = parent_h
				if cn.has_edits { mark_edited(ov, parent_h) }
			}
		}
		return h, nil
	}
	if base_node == tape.ROOT { return ensure_root(ov) }
	h := handle_map.dynamic_add(&ov.nodes, Edit_Node{base = base_node, base_ref = tape.NO_NODE, parent = parent_h, state = .Ancestor}) or_return
	ov.by_base[base_node] = h
	if parent_h == NO_HANDLE { ov.unlinked_parents = true }
	return h, nil
}

ensure_linked :: proc(ov: ^Overlay) -> runtime.Allocator_Error {
	if ov == nil || !ov.unlinked_parents { return nil }
	ensure_parents(ov) or_return
	unlinked := make([dynamic]Handle, 0, 16, ov.allocator)
	defer delete(unlinked)
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		if n.base != tape.NO_NODE && n.base != tape.ROOT && n.parent == NO_HANDLE {
			append(&unlinked, n.handle) or_return
		}
	}
	chain := make([dynamic]tape.Node_Index, 0, 16, ov.allocator)
	defer delete(chain)
	for h in unlinked {
		n, ok := get_node(ov, h)
		if !ok || n.parent != NO_HANDLE { continue }
		edited := n.has_edits
		clear(&chain)
		parent_h := NO_HANDLE
		for cur := ov.parents[n.base]; cur != tape.NO_NODE; cur = ov.parents[cur] {
			if existing, has := ov.by_base[cur]; has {
				parent_h = existing
				break
			}
			append(&chain, cur) or_return
			if cur == tape.ROOT { break }
		}
		#reverse for anc in chain {
			ah := handle_map.dynamic_add(&ov.nodes, Edit_Node{base = anc, base_ref = tape.NO_NODE, parent = parent_h, state = .Ancestor}) or_return
			ov.by_base[anc] = ah
			if anc == tape.ROOT { ov.root = ah }
			parent_h = ah
		}
		if n2, ok2 := get_node(ov, h); ok2 { n2.parent = parent_h }
		if edited && parent_h != NO_HANDLE { mark_edited(ov, parent_h) }
	}
	if ov.root == NO_HANDLE { ov.root = ov.by_base[tape.ROOT] or_else NO_HANDLE }
	ov.unlinked_parents = false
	return nil
}

@(private)
mark_edited :: proc(ov: ^Overlay, h: Handle) {
	ov.dirty = true
	for cur := h; cur != NO_HANDLE; {
		n, ok := get_node(ov, cur)
		if !ok { break }
		n.has_edits = true
		cur = n.parent
	}
}

@(private)
try_inline_bytes :: #force_inline proc "contextless" (val: Edit_Value) -> (src: []u8, ok: bool) {
	#partial switch val.kind {
	case .String, .Number_Text, .Raw:
		if len(val.text) <= 16 { return transmute([]u8)val.text, true }
	case .Bytes:
		if len(val.raw) <= 16 { return val.raw, true }
	}
	return nil, false
}

@(private)
store_inline_bytes :: #force_inline proc "contextless" (n: ^Edit_Node, kind: Value_Kind, src: []u8) {
	n.val, n.val_inline = {kind = kind}, true
	if len(src) > 0 {
		copy(n.inline_buf[:len(src)], src)
		if kind == .Bytes { n.val.raw = n.inline_buf[:len(src)] } else { n.val.text = string(n.inline_buf[:len(src)]) }
	}
}

new_node :: proc(ov: ^Overlay, val: Edit_Value) -> (res: Handle, err: Error) {
	inline_src, can_inline := try_inline_bytes(val)
	cloned := Edit_Value{kind = val.kind}
	if !can_inline { cloned = clone_value(ov, val) or_return }
	elems, members, cerr := clone_children(ov, val)
	if cerr != nil {
		free_edit_value(ov, &cloned, can_inline)
		return NO_HANDLE, cerr
	}
	node := Edit_Node{base = tape.NO_NODE, base_ref = tape.NO_NODE, state = .Replaced, val_inline = can_inline, val = cloned, elems = elems, members = members, has_edits = true}
	h, aerr := handle_map.dynamic_add(&ov.nodes, node)
	if aerr != nil {
		free_edit_node(ov, &node)
		return NO_HANDLE, aerr
	}
	if created, ok := get_node(ov, h); ok {
		if can_inline { store_inline_bytes(created, val.kind, inline_src) }
		link_children_parent(ov, h, created)
	}
	return h, nil
}

@(private = "file")
new_child_node :: proc(ov: ^Overlay, parent: Handle, val: Edit_Value) -> (res: Handle, err: Error) {
	ch := new_node(ov, val) or_return
	if cn, cok := get_node(ov, ch); cok { cn.parent = parent }
	return ch, nil
}

val_null :: proc "contextless" () -> Edit_Value { return {kind = .Null} }
val_bool :: proc "contextless" (b: bool) -> Edit_Value { return {kind = .True if b else .False} }
val_int :: proc "contextless" (i: i64) -> Edit_Value { return {kind = .Int, i = i} }
val_float :: proc "contextless" (f: f64) -> Edit_Value { return {kind = .Float, f = f} }
val_number_text :: proc "contextless" (s: string) -> Edit_Value { return {kind = .Number_Text, text = s} }
val_string :: proc "contextless" (s: string) -> Edit_Value { return {kind = .String, text = s} }
val_bytes :: proc "contextless" (b: []u8) -> Edit_Value { return {kind = .Bytes, raw = b} }
val_raw :: proc "contextless" (s: string) -> Edit_Value { return {kind = .Raw, text = s} }
val_array :: proc "contextless" (elems: []Handle = nil) -> Edit_Value { return {kind = .Array, elems = elems} }
val_object :: proc "contextless" (entries: []Object_Entry = nil) -> Edit_Value { return {kind = .Object, entries = entries} }
val_base_ref :: proc "contextless" (node: tape.Node_Index) -> Edit_Value { return {kind = .Base_Ref, base_ref = node} }

@(private)
prune_base_descendants :: proc(ov: ^Overlay, base_c: tape.Node_Index) {
	if base_c == tape.NO_NODE || int(base_c) >= len(ov.base.nodes) || len(ov.by_base) <= 1 { return }
	t := ov.base.nodes[base_c]
	if t.kind < .Array || t.n <= 1 { return }
	lo, hi := base_c + 1, base_c + tape.Node_Index(t.n)
	stale := make([dynamic]tape.Node_Index, 0, 8, ov.allocator)
	defer delete(stale)
	for bn in ov.by_base { if bn >= lo && bn < hi { append(&stale, bn) } }
	for bn in stale { delete_key(&ov.by_base, bn) }
}

set :: proc(ov: ^Overlay, target: Handle, val: Edit_Value) -> Error {
	n, ok := get_node(ov, target)
	if !ok { return refuse(.Bad_Handle, "invalid overlay handle") }
	if val.kind != .Array && val.kind != .Object {
		inline_src, can_inline := try_inline_bytes(val)
		inline_tmp: [16]u8 = ---
		cloned: Edit_Value
		if can_inline { copy(inline_tmp[:len(inline_src)], inline_src) } else { cloned = clone_value(ov, val) or_return }
		if n.base != tape.NO_NODE {
			bn := ov.base.nodes[n.base]
			if n.base == tape.ROOT || bn.kind >= .Array || bn.role != .Value {
				ov.has_structural = true
				if n.state != .Replaced { prune_base_descendants(ov, n.base) }
			}
		} else {
			ov.has_structural = true
		}
		if val.kind == .Base_Ref { ov.has_structural = true }
		if n.state != .Ancestor {
			reset_node_deltas(ov, n)
		} else if n.val.kind != .None {
			free_edit_value(ov, &n.val, n.val_inline)
			n.val_inline = false
		}
		n.state = .Replaced
		if can_inline {
			store_inline_bytes(n, val.kind, inline_tmp[:len(inline_src)])
		} else {
			n.val, n.val_inline = cloned, false
		}
		mark_edited(ov, target)
		return nil
	}

	new_elems, new_members := clone_children(ov, val) or_return
	ov.has_structural = true
	if n.base != tape.NO_NODE && n.state != .Replaced { prune_base_descendants(ov, n.base) }
	reset_node_deltas(ov, n)
	n.state, n.val = .Replaced, {kind = val.kind}
	if val.kind == .Array {
		delete(n.elems)
		n.elems = new_elems
	} else {
		delete(n.members)
		n.members = new_members
	}
	link_children_parent(ov, target, n)
	mark_edited(ov, target)
	return nil
}

node_kind :: proc "contextless" (ov: ^Overlay, h: Handle) -> tape.Kind {
	n, ok := get_node(ov, h)
	if !ok { return .Null }
	if n.state == .Replaced {
		switch n.val.kind {
		case .None, .Null: return .Null
		case .False: return .False
		case .True: return .True
		case .Int, .Uint, .Float, .Number_Text: return .Number
		case .String, .Raw: return .String
		case .Bytes: return .Bytes
		case .Array: return .Array
		case .Object: return .Object
		case .Base_Ref:
			return ov.base.nodes[n.val.base_ref].kind if n.val.base_ref != tape.NO_NODE && int(n.val.base_ref) < len(ov.base.nodes) else .Null
		}
	}
	bn := node_base_container(n)
	return ov.base.nodes[bn].kind if bn != tape.NO_NODE && int(bn) < len(ov.base.nodes) else .Null
}

@(private)
find_base_member_idx :: proc(ov: ^Overlay, base_obj: tape.Node_Index, orig_key: string) -> (idx: int, val_node: tape.Node_Index, found: bool) {
	if base_obj == tape.NO_NODE { return -1, tape.NO_NODE, false }
	c, p, cerr := tape.children(tape.Reader{doc = ov.base}, base_obj, ov.allocator)
	if cerr != nil || p != .Found { return -1, tape.NO_NODE, false }
	defer tape.destroy_children(&c)
	for i := 0; ; i += 1 {
		kn, vn, np := tape.next_child(tape.Reader{doc = ov.base}, &c)
		if np != .Found { break }
		tk := decode_node_text_tmp(ov.base, kn, ov.allocator)
		match := tk.text == orig_key
		free_tmp_text(tk, ov.allocator)
		if match { idx, val_node, found = i, vn, true }
	}
	return idx, val_node, found
}

@(private = "file")
find_ins_member :: proc "contextless" (d: ^Container_Delta, key: string) -> int {
	for ins, i in d.inserted_members { if ins.key == key { return i } }
	return -1
}

@(private = "file")
find_rename :: proc "contextless" (d: ^Container_Delta, key: string, by_new: bool) -> int {
	for r, i in d.renamed_members {
		if (r.new_key if by_new else r.old_key) == key { return i }
	}
	return -1
}

@(private)
order_on_insert :: proc(ov: ^Overlay, d: ^Container_Delta, slot: u32, at: int) -> runtime.Allocator_Error {
	if len(d.order) == 0 { return nil }
	new_ord := make([]u32, len(d.order) + 1, ov.allocator) or_return
	pos := len(d.order) if at < 0 || at > len(d.order) else at
	copy(new_ord[:pos], d.order[:pos])
	new_ord[pos] = slot
	copy(new_ord[pos + 1:], d.order[pos:])
	delete(d.order, ov.allocator)
	d.order = new_ord
	return nil
}

@(private)
order_on_delete :: proc(ov: ^Overlay, d: ^Container_Delta, slot: u32, is_inserted: bool) {
	_ = ov
	if len(d.order) == 0 { return }
	w := 0
	for v in d.order {
		if v == slot { continue }
		d.order[w] = v - 1 if (is_inserted && v > slot) else v
		w += 1
	}
	d.order = d.order[:w]
}

@(private = "file")
delete_renamed_to_base :: proc(ov: ^Overlay, d: ^Container_Delta, ri: int) -> (bidx: int, err: runtime.Allocator_Error) {
	r := d.renamed_members[ri]
	orig, bi := r.old_key, r.base_idx
	delete(r.new_key, ov.allocator)
	ordered_remove(&d.renamed_members, ri)
	if aerr := ov_append(ov, &d.deleted_keys, orig); aerr != nil {
		delete(orig, ov.allocator)
		return -1, aerr
	}
	if bi >= 0 { order_on_delete(ov, d, u32(bi), false) }
	return bi, nil
}

@(private = "file")
set_base_child :: proc(ov: ^Overlay, parent: Handle, child_base: tape.Node_Index, val: Edit_Value) -> (res: Handle, err: Error) {
	ch := handle_for_base_with_parent(ov, child_base, parent) or_return
	set(ov, ch, val) or_return
	return ch, nil
}

set_member :: proc(ov: ^Overlay, obj: Handle, key: string, val: Edit_Value) -> (res: Handle, err: Error) {
	n := require_container(ov, obj, .Object, "set_member requires an object") or_return
	if n.state == .Replaced && n.val.kind == .Object {
		for &m in n.members {
			if m.key == key {
				set(ov, m.value, val) or_return
				return m.value, nil
			}
		}
		return insert_member(ov, obj, -1, key, val)
	}
	base_obj, live_base := node_base_container(n), is_live_base_node(n)
	if d := n.delta; d != nil {
		if ii := find_ins_member(d, key); ii >= 0 {
			set(ov, d.inserted_members[ii].value, val) or_return
			return d.inserted_members[ii].value, nil
		}
		if ri := find_rename(d, key, true); ri >= 0 {
			if live_base {
				if cb, p := tape.member(tape.Reader{doc = ov.base}, base_obj, d.renamed_members[ri].old_key); p == .Found {
					return set_base_child(ov, obj, cb, val)
				}
			} else {
				bidx := delete_renamed_to_base(ov, d, ri) or_return
				return insert_member(ov, obj, bidx if len(d.order) == 0 else -1, key, val)
			}
		}
		for dk, di in d.deleted_keys {
			if dk != key { continue }
			bidx, child_base, found_base := find_base_member_idx(ov, base_obj, key)
			delete(dk, ov.allocator)
			ordered_remove(&d.deleted_keys, di)
			if live_base && found_base {
				if bidx >= 0 { order_on_insert(ov, d, u32(bidx), -1) or_return }
				return set_base_child(ov, obj, child_base, val)
			}
			if found_base && len(d.order) == 0 { return insert_member(ov, obj, bidx, key, val) }
			break
		}
		if ri := find_rename(d, key, false); ri >= 0 && d.renamed_members[ri].new_key != key {
			return insert_member(ov, obj, -1, key, val)
		}
	}
	if base_obj != tape.NO_NODE && live_base {
		if cb, p := tape.member(tape.Reader{doc = ov.base}, base_obj, key); p == .Found {
			return set_base_child(ov, obj, cb, val)
		}
	} else if base_obj != tape.NO_NODE {
		if bidx, _, exists := find_base_member_idx(ov, base_obj, key); exists {
			del_member(ov, obj, key) or_return
			n_cur, _ := get_node(ov, obj)
			return insert_member(ov, obj, bidx if (n_cur.delta == nil || len(n_cur.delta.order) == 0) else -1, key, val)
		}
	}
	return insert_member(ov, obj, -1, key, val)
}

insert_member :: proc(ov: ^Overlay, obj: Handle, at: int, key: string, val: Edit_Value) -> (res: Handle, err: Error) {
	require_container(ov, obj, .Object, "insert_member requires an object") or_return
	ch := new_child_node(ov, obj, val) or_return
	n, _ := get_node(ov, obj)
	if n.state == .Replaced && n.val.kind == .Object {
		k := clone_str(ov, key) or_return
		if ierr := ov_inject_at(ov, &n.members, at, Object_Entry{k, ch}); ierr != nil {
			delete(k, ov.allocator)
			return NO_HANDLE, ierr
		}
		mark_edited(ov, obj)
		return ch, nil
	}
	d := enter_container_delta(ov, n) or_return
	ins_idx := len(d.inserted_members)
	ov_append_member_ins(ov, &d.inserted_members, at, key, ch) or_return
	order_on_insert(ov, d, u32(base_child_count(ov, n) + ins_idx), at) or_return
	mark_edited(ov, obj)
	return ch, nil
}

del_member :: proc(ov: ^Overlay, obj: Handle, key: string) -> Error {
	n := require_container(ov, obj, .Object, "del_member requires an object") or_return
	if n.state == .Replaced && n.val.kind == .Object {
		for m, i in n.members {
			if m.key == key {
				delete(m.key, ov.allocator)
				ordered_remove(&n.members, i)
				mark_edited(ov, obj)
				return nil
			}
		}
		return nil
	}
	base_obj := node_base_container(n)
	if d := n.delta; d != nil {
		if ii := find_ins_member(d, key); ii >= 0 {
			delete(d.inserted_members[ii].key, ov.allocator)
			ordered_remove(&d.inserted_members, ii)
			if base_obj != tape.NO_NODE { order_on_delete(ov, d, u32(base_child_count(ov, n) + ii), true) }
			mark_edited(ov, obj)
			return nil
		}
		if ri := find_rename(d, key, true); ri >= 0 {
			delete_renamed_to_base(ov, d, ri) or_return
			mark_edited(ov, obj)
			return nil
		}
		if (find_rename(d, key, false) >= 0 && d.renamed_members[find_rename(d, key, false)].new_key != key) || slice.contains(d.deleted_keys[:], key) {
			return nil
		}
	}
	bidx, _, found := find_base_member_idx(ov, base_obj, key)
	if !found { return nil }
	d := enter_container_delta(ov, n) or_return
	ov_append_str(ov, &d.deleted_keys, key) or_return
	if bidx >= 0 { order_on_delete(ov, d, u32(bidx), false) }
	mark_edited(ov, obj)
	return nil
}

rename_member :: proc(ov: ^Overlay, obj: Handle, old_key, new_key: string) -> Error {
	n := require_container(ov, obj, .Object, "rename_member requires an object") or_return
	if old_key == new_key { return nil }
	if n.state == .Replaced && n.val.kind == .Object {
		for &m in n.members {
			if m.key == old_key {
				replace_cloned_str(ov, &m.key, new_key) or_return
				mark_edited(ov, obj)
				return nil
			}
		}
		return nil
	}
	if d := n.delta; d != nil {
		if ii := find_ins_member(d, old_key); ii >= 0 {
			replace_cloned_str(ov, &d.inserted_members[ii].key, new_key) or_return
			mark_edited(ov, obj)
			return nil
		}
		if ri := find_rename(d, old_key, true); ri >= 0 {
			r := &d.renamed_members[ri]
			if r.old_key == new_key {
				delete(r.old_key, ov.allocator)
				delete(r.new_key, ov.allocator)
				ordered_remove(&d.renamed_members, ri)
			} else {
				replace_cloned_str(ov, &r.new_key, new_key) or_return
			}
			mark_edited(ov, obj)
			return nil
		}
		if slice.contains(d.deleted_keys[:], old_key) || find_rename(d, old_key, false) >= 0 { return nil }
	}
	bidx, _, found := find_base_member_idx(ov, node_base_container(n), old_key)
	if !found { return nil }
	d := enter_container_delta(ov, n) or_return
	ov_append_rename(ov, &d.renamed_members, old_key, new_key, bidx) or_return
	mark_edited(ov, obj)
	return nil
}

@(private = "file")
pad_and_append_elem :: proc(ov: ^Overlay, arr: Handle, cur_len, idx: int, val: Edit_Value) -> (res: Handle, err: Error) {
	for k := cur_len; k < idx; k += 1 {
		_ = insert_element(ov, arr, -1, val_null()) or_return
	}
	return insert_element(ov, arr, -1, val)
}

set_element :: proc(ov: ^Overlay, arr: Handle, index: int, val: Edit_Value) -> (res: Handle, err: Error) {
	n := require_container(ov, arr, .Array, "set_element requires an array") or_return
	if n.state == .Replaced && n.val.kind == .Array {
		idx := index if index >= 0 else len(n.elems) + index
		if idx < 0 { return NO_HANDLE, refuse(.Bad_Position, "negative array index out of bounds", n.base) }
		if idx < len(n.elems) {
			set(ov, n.elems[idx], val) or_return
			return n.elems[idx], nil
		}
		return pad_and_append_elem(ov, arr, len(n.elems), idx, val)
	}
	base_arr := node_base_container(n)
	if n.state == .Ancestor && n.base != tape.NO_NODE {
		if elem_base, p := tape.element(tape.Reader{doc = ov.base}, base_arr, index); p == .Found {
			return set_base_child(ov, arr, elem_base, val)
		}
		cur_len := container_len(ov, arr)
		idx := index if index >= 0 else cur_len + index
		if idx < 0 { return NO_HANDLE, refuse(.Bad_Position, "negative array index out of bounds", base_arr) }
		return pad_and_append_elem(ov, arr, cur_len, idx, val)
	}
	eff := effective_elements(ov, arr, ov.allocator) or_return
	defer delete(eff, ov.allocator)
	idx := index if index >= 0 else len(eff) + index
	if idx < 0 { return NO_HANDLE, refuse(.Bad_Position, "negative array index out of bounds", base_arr) }
	if idx < len(eff) {
		e := eff[idx]
		if e.handle != NO_HANDLE {
			set(ov, e.handle, val) or_return
			return e.handle, nil
		}
		if is_live_base_node(n) { return set_base_child(ov, arr, e.base, val) }
		del_element(ov, arr, idx) or_return
		return insert_element(ov, arr, idx, val)
	}
	return pad_and_append_elem(ov, arr, len(eff), idx, val)
}

insert_element :: proc(ov: ^Overlay, arr: Handle, at: int, val: Edit_Value) -> (res: Handle, err: Error) {
	require_container(ov, arr, .Array, "insert_element requires an array") or_return
	ch := new_child_node(ov, arr, val) or_return
	n, _ := get_node(ov, arr)
	if n.state == .Replaced && n.val.kind == .Array {
		ov_inject_at(ov, &n.elems, at, ch) or_return
		mark_edited(ov, arr)
		return ch, nil
	}
	d := enter_container_delta(ov, n) or_return
	ins_idx := len(d.inserted_elems)
	ov_append(ov, &d.inserted_elems, Array_Insert{at, ch}) or_return
	order_on_insert(ov, d, u32(base_child_count(ov, n) + ins_idx), at) or_return
	mark_edited(ov, arr)
	return ch, nil
}

del_element :: proc(ov: ^Overlay, arr: Handle, index: int) -> Error {
	n := require_container(ov, arr, .Array, "del_element requires an array") or_return
	if n.state == .Replaced && n.val.kind == .Array {
		idx := index if index >= 0 else len(n.elems) + index
		if idx >= 0 && idx < len(n.elems) {
			ordered_remove(&n.elems, idx)
			mark_edited(ov, arr)
		}
		return nil
	}
	eff := effective_elements(ov, arr, ov.allocator) or_return
	defer delete(eff, ov.allocator)
	idx := index if index >= 0 else len(eff) + index
	if idx < 0 || idx >= len(eff) { return nil }
	e := eff[idx]
	n, _ = get_node(ov, arr)
	if e.is_inserted {
		d := n.delta
		ordered_remove(&d.inserted_elems, e.insert_idx)
		if node_base_container(n) != tape.NO_NODE { order_on_delete(ov, d, u32(base_child_count(ov, n) + e.insert_idx), true) }
		mark_edited(ov, arr)
		return nil
	}
	d := enter_container_delta(ov, n) or_return
	ov_append(ov, &d.deleted_indices, u32(e.base_idx)) or_return
	order_on_delete(ov, d, u32(e.base_idx), false)
	mark_edited(ov, arr)
	return nil
}

reorder :: proc(ov: ^Overlay, container: Handle, order: []u32) -> Error {
	n := require_container(ov, container, .End, "reorder requires an array or object") or_return
	cloned := slice.clone(order, ov.allocator) or_return
	d, derr := enter_container_delta(ov, n)
	if derr != nil {
		delete(cloned, ov.allocator)
		return derr
	}
	delete(d.order, ov.allocator)
	d.order = cloned
	mark_edited(ov, container)
	return nil
}

@(private)
recompute_present :: proc(ov: ^Overlay) {
	p := ov.base.present if ov.base != nil else tape.Facts{}
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		for f in n.facts { if !f.deleted { p += {f.kind} } }
	}
	ov.present = p
}

@(private = "file")
put_fact_override :: proc(ov: ^Overlay, target: Handle, kind: tape.Fact_Kind, values: []string, attr: string, num_tag: Maybe(u64), padded, deleted: bool) -> Error {
	n, ok := get_node(ov, target)
	if !ok { return refuse(.Bad_Handle, "invalid overlay handle") }
	fo := make_fact_override(ov, kind, values, attr, num_tag, padded, deleted) or_return
	ov.has_structural = true
	for &f in n.facts {
		if f.kind == kind && (kind != .Attribute || f.attr == attr) {
			free_fact_override(ov, &f)
			f = fo
			if deleted { recompute_present(ov) } else { ov.present += {kind} }
			mark_edited(ov, target)
			return nil
		}
	}
	if aerr := ov_append(ov, &n.facts, fo, 2); aerr != nil {
		free_fact_override(ov, &fo)
		return aerr
	}
	if !deleted { ov.present += {kind} }
	mark_edited(ov, target)
	return nil
}

set_fact :: proc(ov: ^Overlay, target: Handle, kind: tape.Fact_Kind, values: []string, attr := "", num_tag: Maybe(u64) = nil, padded := true) -> Error {
	return put_fact_override(ov, target, kind, values, attr, num_tag, padded, false)
}

del_fact :: proc(ov: ^Overlay, target: Handle, kind: tape.Fact_Kind, attr := "") -> Error {
	return put_fact_override(ov, target, kind, nil, attr, nil, false, true)
}

@(private)
make_fact_override :: proc(ov: ^Overlay, kind: tape.Fact_Kind, values: []string, attr: string, num_tag: Maybe(u64), padded, deleted: bool) -> (fo: Fact_Override, err: runtime.Allocator_Error) {
	fo = {kind = kind, deleted = deleted, num_tag = num_tag, padded = padded}
	defer if err != nil { free_fact_override(ov, &fo) }
	fo.attr = clone_str(ov, attr) or_return
	if !deleted && len(values) > 0 {
		fo.values = make([]string, len(values), ov.allocator) or_return
		for v, i in values { fo.values[i] = clone_str(ov, v) or_return }
	}
	return fo, nil
}

find_fact_override :: proc "contextless" (ov: ^Overlay, target: Handle, kind: tape.Fact_Kind, attr := "") -> (^Fact_Override, bool) {
	n, ok := get_node(ov, target)
	if !ok { return nil, false }
	for &f in n.facts {
		if f.kind == kind && (kind != .Attribute || f.attr == attr) { return &f, true }
	}
	return nil, false
}

@(private)
child_handle_for_edit :: proc(ov: ^Overlay, parent: Handle, step: tape.Step, ch: Handle, cb: tape.Node_Index) -> (Handle, Error) {
	if ch != NO_HANDLE { return ch, nil }
	if pn, pok := get_node(ov, parent); pok && is_live_base_node(pn) {
		return handle_for_base_with_parent(ov, cb, parent)
	}
	#partial switch s in step {
	case tape.Name: return set_member(ov, parent, string(s), val_base_ref(cb))
	case tape.Index: return set_element(ov, parent, int(s), val_base_ref(cb))
	}
	return NO_HANDLE, refuse(.Bad_Handle, "cannot materialize non-live child handle", cb)
}

@(private = "file")
step_lookup :: proc(ov: ^Overlay, cur: Handle, step: tape.Step) -> (ch: Handle, cb: tape.Node_Index, found, ok_step: bool) {
	#partial switch s in step {
	case tape.Name:
		ch, cb, found = lookup_member(ov, cur, string(s))
		return ch, cb, found, true
	case tape.Index:
		ch, cb, found = lookup_element(ov, cur, int(s))
		return ch, cb, found, true
	}
	return NO_HANDLE, tape.NO_NODE, false, false
}

@(private = "file")
step_set :: proc(ov: ^Overlay, cur: Handle, step: tape.Step, val: Edit_Value) -> (Handle, Error) {
	#partial switch s in step {
	case tape.Name: return set_member(ov, cur, string(s), val)
	case tape.Index: return set_element(ov, cur, int(s), val)
	}
	return NO_HANDLE, refuse(.Bad_Path, "path edit requires concrete Name/Index steps")
}

set_path :: proc(ov: ^Overlay, steps: []tape.Step, val: Edit_Value) -> (res: Handle, err: Error) {
	cur := ensure_root(ov) or_return
	if len(steps) == 0 {
		set(ov, cur, val) or_return
		return cur, nil
	}
	for step, i in steps {
		if i + 1 == len(steps) { return step_set(ov, cur, step, val) }
		ch, cb, found, ok_step := step_lookup(ov, cur, step)
		if !ok_step { return NO_HANDLE, refuse(.Bad_Path, "path edit requires concrete Name/Index steps") }
		if found {
			cur = child_handle_for_edit(ov, cur, step, ch, cb) or_return
		} else {
			_, next_idx := steps[i + 1].(tape.Index)
			cur = step_set(ov, cur, step, val_array() if next_idx else val_object()) or_return
		}
	}
	return cur, nil
}

del_path :: proc(ov: ^Overlay, steps: []tape.Step) -> Error {
	if len(steps) == 0 { return refuse(.Bad_Path, "cannot delete root") }
	cur := ensure_root(ov) or_return
	for step in steps[:len(steps) - 1] {
		ch, cb, found, ok_step := step_lookup(ov, cur, step)
		if !ok_step { return refuse(.Bad_Path, "path delete requires concrete Name/Index steps") }
		if !found { return nil }
		cur = child_handle_for_edit(ov, cur, step, ch, cb) or_return
	}
	#partial switch s in steps[len(steps) - 1] {
	case tape.Name: return del_member(ov, cur, string(s))
	case tape.Index: return del_element(ov, cur, int(s))
	}
	return refuse(.Bad_Path, "path delete requires concrete Name/Index steps")
}

Effective_Element :: struct {
	handle:               Handle,
	base:                 tape.Node_Index,
	base_idx, insert_idx: int,
	is_inserted:          bool,
}

Effective_Member :: struct {
	key:                  string,
	handle:               Handle,
	base_key, base_val:   tape.Node_Index,
	base_idx, insert_idx: int,
	is_inserted, renamed: bool,
}

@(private = "file")
resolve_base_lookup :: proc(ov: ^Overlay, cb: tape.Node_Index, p: tape.Presence, use_by_base: bool) -> (Handle, tape.Node_Index, bool) {
	if p != .Found { return NO_HANDLE, tape.NO_NODE, false }
	if use_by_base {
		if ch, has := ov.by_base[cb]; has { return ch, cb, true }
	}
	return NO_HANDLE, cb, true
}

@(private)
lookup_base_member :: proc(ov: ^Overlay, base_obj: tape.Node_Index, key: string, use_by_base := true) -> (Handle, tape.Node_Index, bool) {
	if base_obj == tape.NO_NODE { return NO_HANDLE, tape.NO_NODE, false }
	cb, p := tape.member(tape.Reader{doc = ov.base}, base_obj, key)
	return resolve_base_lookup(ov, cb, p, use_by_base)
}

@(private)
lookup_base_element :: proc(ov: ^Overlay, base_arr: tape.Node_Index, index: int, use_by_base := true) -> (Handle, tape.Node_Index, bool) {
	if base_arr == tape.NO_NODE { return NO_HANDLE, tape.NO_NODE, false }
	cb, p := tape.element(tape.Reader{doc = ov.base}, base_arr, index)
	return resolve_base_lookup(ov, cb, p, use_by_base)
}

lookup_member :: proc(ov: ^Overlay, obj: Handle, key: string) -> (Handle, tape.Node_Index, bool) {
	n, ok := get_node(ov, obj)
	if !ok { return NO_HANDLE, tape.NO_NODE, false }
	if n.state == .Replaced {
		if n.val.kind == .Object {
			for m in n.members { if m.key == key { return m.value, tape.NO_NODE, true } }
		} else if n.val.kind == .Base_Ref {
			return lookup_base_member(ov, n.val.base_ref, key, false)
		}
		return NO_HANDLE, tape.NO_NODE, false
	}
	base_obj, live_base := node_base_container(n), is_live_base_node(n)
	if d := n.delta; n.state == .Container_Delta && d != nil {
		if ii := find_ins_member(d, key); ii >= 0 { return d.inserted_members[ii].value, tape.NO_NODE, true }
		if ri := find_rename(d, key, true); ri >= 0 { return lookup_base_member(ov, base_obj, d.renamed_members[ri].old_key, live_base) }
		if (find_rename(d, key, false) >= 0 && d.renamed_members[find_rename(d, key, false)].new_key != key) || slice.contains(d.deleted_keys[:], key) {
			return NO_HANDLE, tape.NO_NODE, false
		}
	}
	return lookup_base_member(ov, base_obj, key, live_base)
}

lookup_element :: proc(ov: ^Overlay, arr: Handle, index: int) -> (Handle, tape.Node_Index, bool) {
	n, ok := get_node(ov, arr)
	if !ok { return NO_HANDLE, tape.NO_NODE, false }
	if n.state == .Replaced {
		if n.val.kind == .Array {
			idx := index if index >= 0 else len(n.elems) + index
			if idx >= 0 && idx < len(n.elems) { return n.elems[idx], tape.NO_NODE, true }
		} else if n.val.kind == .Base_Ref {
			return lookup_base_element(ov, n.val.base_ref, index, false)
		}
		return NO_HANDLE, tape.NO_NODE, false
	}
	if n.state == .Ancestor { return lookup_base_element(ov, n.base, index, true) }
	eff, err := effective_elements(ov, arr, ov.allocator)
	if err != nil { return NO_HANDLE, tape.NO_NODE, false }
	defer delete(eff, ov.allocator)
	idx := index if index >= 0 else len(eff) + index
	if idx < 0 || idx >= len(eff) { return NO_HANDLE, tape.NO_NODE, false }
	return eff[idx].handle, eff[idx].base, true
}

container_len :: proc(ov: ^Overlay, h: Handle) -> int {
	n, ok := get_node(ov, h)
	if !ok { return 0 }
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Array: return len(n.elems)
		case .Object: return len(n.members)
		case .Base_Ref:
			c, _, _ := tape.length(tape.Reader{doc = ov.base}, n.val.base_ref, ov.allocator)
			return c
		}
		return 0
	}
	if n.state == .Ancestor {
		c, _, _ := tape.length(tape.Reader{doc = ov.base}, n.base, ov.allocator)
		return c
	}
	#partial switch node_kind(ov, h) {
	case .Array:
		eff, err := effective_elements(ov, h, ov.allocator)
		defer delete(eff, ov.allocator)
		return len(eff) if err == nil else 0
	case .Object:
		eff, owned, err := effective_members(ov, h, ov.allocator)
		defer destroy_effective_members(eff, owned, ov.allocator)
		return len(eff) if err == nil else 0
	}
	return 0
}

// Builds the effective slot sequence over `n_base` base items and `ins` inserts (`>= n_base` means insert `k - n_base`).
@(private)
build_effective_slots :: proc(n_base: int, deleted: []bool, ins: []$I, ord: []u32, allocator: runtime.Allocator) -> (slots: [dynamic]int, err: runtime.Allocator_Error) {
	slots = make([dynamic]int, 0, n_base + len(ins), allocator) or_return
	defer if err != nil { delete(slots) }
	if len(ord) > 0 {
		for idx in ord {
			k := int(idx)
			if (k < n_base && !deleted[k]) || (k >= n_base && k - n_base < len(ins)) { append(&slots, k) or_return }
		}
		return slots, nil
	}
	for j in 0 ..= n_base {
		for it, ins_i in ins {
			if (n_base if it.at < 0 || it.at > n_base else it.at) == j { append(&slots, n_base + ins_i) or_return }
		}
		if j < n_base && !deleted[j] { append(&slots, j) or_return }
	}
	return slots, nil
}

effective_elements :: proc(ov: ^Overlay, arr: Handle, allocator: runtime.Allocator) -> (res: []Effective_Element, err: runtime.Allocator_Error) {
	n, ok := get_node(ov, arr)
	if !ok { return nil, nil }
	if n.state == .Replaced && n.val.kind == .Array {
		out := make([]Effective_Element, len(n.elems), allocator) or_return
		for eh, i in n.elems { out[i] = {eh, tape.NO_NODE, -1, i, true} }
		return out, nil
	}
	base_arr := node_base_container(n)
	bc := max(0, tape.child_count(ov.base, base_arr, ov.base.nodes[base_arr]))
	base_nodes := make([]tape.Node_Index, bc, allocator) or_return
	defer delete(base_nodes, allocator)
	c, _, cerr := tape.children(tape.Reader{doc = ov.base}, base_arr, allocator)
	if cerr != nil { return nil, cerr }
	defer tape.destroy_children(&c)
	bi := 0
	for bi < bc {
		_, v, p := tape.next_child(tape.Reader{doc = ov.base}, &c)
		if p != .Found { break }
		base_nodes[bi] = v
		bi += 1
	}
	base_nodes = base_nodes[:bi]
	deleted := make([]bool, len(base_nodes), allocator) or_return
	defer delete(deleted, allocator)
	d := n.delta
	ins_elems := d.inserted_elems[:] if d != nil else nil
	if d != nil {
		for di in d.deleted_indices { if int(di) < len(deleted) { deleted[di] = true } }
	}
	slots := build_effective_slots(len(base_nodes), deleted, ins_elems, d.order if d != nil else nil, allocator) or_return
	defer delete(slots)
	out := make([]Effective_Element, len(slots), allocator) or_return
	use_by_base := is_live_base_node(n)
	for k, i in slots {
		if k < len(base_nodes) {
			bn := base_nodes[k]
			out[i] = {(ov.by_base[bn] or_else NO_HANDLE) if use_by_base else NO_HANDLE, bn, k, -1, false}
		} else {
			ik := k - len(base_nodes)
			out[i] = {ins_elems[ik].value, tape.NO_NODE, -1, ik, true}
		}
	}
	return out, nil
}

effective_members :: proc(ov: ^Overlay, obj: Handle, allocator: runtime.Allocator) -> (members: []Effective_Member, owned_keys: []string, err: runtime.Allocator_Error) {
	n, ok := get_node(ov, obj)
	if !ok { return nil, nil, nil }
	if n.state == .Replaced && n.val.kind == .Object {
		out := make([]Effective_Member, len(n.members), allocator) or_return
		for m, i in n.members { out[i] = {m.key, m.value, tape.NO_NODE, tape.NO_NODE, -1, i, true, false} }
		return out, nil, nil
	}
	Base_Entry :: struct { key: string, base_key, base_val: tape.Node_Index, deleted, renamed: bool }
	base_list := make([dynamic]Base_Entry, 0, 8, allocator)
	defer delete(base_list)
	dec_keys := make([dynamic]string, 0, 4, allocator)
	defer if err != nil {
		for dk in dec_keys { delete(dk, allocator) }
		delete(dec_keys)
	}
	d := n.delta
	c, p, cerr := tape.children(tape.Reader{doc = ov.base}, node_base_container(n), allocator)
	if cerr != nil { return nil, nil, cerr }
	defer tape.destroy_children(&c)
	if p == .Found {
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = ov.base}, &c)
			if np != .Found { break }
			tk: Tmp_Text
			if kn != tape.NO_NODE {
				tk = decode_node_text_tmp(ov.base, kn, allocator)
			} else if c.keys_n != 0 {
				tk = decode_token_text_tmp(ov.base, tape.cell_key(tape.Reader{doc = ov.base}, c), allocator)
			}
			if tk.owned { append(&dec_keys, tk.text) or_return }
			is_del, ren_to := base_delta_status(d, tk.text, 0, true)
			is_ren := len(ren_to) > 0
			append(&base_list, Base_Entry{ren_to if is_ren else tk.text, kn, vn, is_del, is_ren}) or_return
		}
	}
	deleted := make_deleted_flags(base_list[:], allocator) or_return
	defer delete(deleted, allocator)
	ins_members := d.inserted_members[:] if d != nil else nil
	slots := build_effective_slots(len(base_list), deleted, ins_members, d.order if d != nil else nil, allocator) or_return
	defer delete(slots)
	out := make([]Effective_Member, len(slots), allocator) or_return
	use_by_base := is_live_base_node(n)
	for k, i in slots {
		if k < len(base_list) {
			be := base_list[k]
			out[i] = {be.key, (ov.by_base[be.base_val] or_else NO_HANDLE) if use_by_base else NO_HANDLE, be.base_key, be.base_val, k, -1, false, be.renamed}
		} else {
			ik := k - len(base_list)
			out[i] = {ins_members[ik].key, ins_members[ik].value, tape.NO_NODE, tape.NO_NODE, -1, ik, true, false}
		}
	}
	return out, dec_keys[:], nil
}

destroy_effective_members :: proc(members: []Effective_Member, owned_keys: []string, allocator: runtime.Allocator) {
	delete(members, allocator)
	for k in owned_keys { delete(k, allocator) }
	delete(owned_keys, allocator)
}

cache_ancestor_text :: proc(ov: ^Overlay, h: Handle, s: string) -> Error {
	n, ok := get_node(ov, h)
	if !ok || n.state != .Ancestor || n.val.kind != .None { return nil }
	if len(s) <= 16 {
		store_inline_bytes(n, .String, transmute([]u8)s)
		return nil
	}
	n.val, n.val_inline = {kind = .String, text = strings.clone(s, ov.allocator) or_return}, false
	return nil
}

base_subtree_has_edits :: proc "contextless" (ov: ^Overlay, base_node: tape.Node_Index) -> bool {
	node_dirty :: proc "contextless" (ov: ^Overlay, h: Handle) -> bool {
		cn, ok := get_node(ov, h)
		return ok && (cn.has_edits || cn.state != .Ancestor || len(cn.facts) > 0)
	}
	if ov == nil || ov.base == nil || base_node == tape.NO_NODE || int(base_node) >= len(ov.base.nodes) { return false }
	if ch, has := ov.by_base[base_node]; has && node_dirty(ov, ch) { return true }
	if !ov.unlinked_parents { return false }
	bt := ov.base.nodes[base_node]
	if bt.kind < .Array || bt.n <= 1 { return false }
	end := base_node + tape.Node_Index(bt.n)
	for bn, h in ov.by_base {
		if bn >= base_node && bn < end && node_dirty(ov, h) { return true }
	}
	return false
}

discard_node :: proc(ov: ^Overlay, h: Handle) {
	if n, ok := get_node(ov, h); ok {
		if n.base != tape.NO_NODE && n.base != tape.ROOT { delete_key(&ov.by_base, n.base) }
		free_edit_node(ov, n)
		handle_map.dynamic_remove(&ov.nodes, h)
	}
}

move_node_payload :: proc(ov: ^Overlay, dst, src: Handle) -> Error {
	dn, dok := get_node(ov, dst)
	sn, sok := get_node(ov, src)
	if !dok || !sok { return refuse(.Bad_Handle, "invalid overlay handle") }
	if dst == src { return nil }
	ov.has_structural = true
	if dn.base != tape.NO_NODE && dn.state != .Replaced { prune_base_descendants(ov, dn.base) }
	reset_node_deltas(ov, dn)
	delete(dn.elems)
	delete(dn.members)
	dn.state, dn.base_ref, dn.delta, dn.elems, dn.members = sn.state, sn.base_ref, sn.delta, sn.elems, sn.members
	if sn.val_inline {
		store_inline_bytes(dn, sn.val.kind, sn.val.raw if sn.val.kind == .Bytes else transmute([]u8)sn.val.text)
	} else {
		dn.val, dn.val_inline = sn.val, false
	}
	link_children_parent(ov, dst, dn)
	if len(sn.facts) > 0 {
		for &f in dn.facts { free_fact_override(ov, &f) }
		delete(dn.facts)
		dn.facts, sn.facts = sn.facts, {}
		recompute_present(ov)
	} else {
		delete(sn.facts)
		sn.facts = {}
	}
	sn^ = {handle = sn.handle, base = sn.base, base_ref = tape.NO_NODE, parent = sn.parent, state = .Ancestor}
	handle_map.dynamic_remove(&ov.nodes, src)
	mark_edited(ov, dst)
	return nil
}

clone_overlay :: proc(src: ^Overlay, remap_handles: []Handle, allocator: runtime.Allocator) -> (dst: Overlay, err: Error) {
	if src == nil || src.base == nil { return {}, refuse(.No_Document, "overlay has no document") }
	out: Overlay
	init(&out, src.base, allocator) or_return
	defer if err != nil { destroy(&out) }
	remap := make(map[Handle]Handle, max(8, xar.len(src.nodes.items)), allocator)
	defer delete(remap)

	it1 := handle_map.dynamic_iterator_make(&src.nodes)
	for sn in dynamic_iter_next(&it1) {
		remap[sn.handle] = handle_map.dynamic_add(&out.nodes, Edit_Node{base = sn.base, base_ref = sn.base_ref, state = sn.state, has_edits = sn.has_edits}) or_return
	}
	it2 := handle_map.dynamic_iterator_make(&src.nodes)
	for sn in dynamic_iter_next(&it2) {
		dn, _ := get_node(&out, remap[sn.handle])
		if sn.parent != NO_HANDLE { dn.parent = remap[sn.parent] or_else NO_HANDLE }
		if sn.val_inline {
			store_inline_bytes(dn, sn.val.kind, sn.val.raw if sn.val.kind == .Bytes else transmute([]u8)sn.val.text)
		} else if sn.val.kind != .None {
			dn.val = clone_value(&out, sn.val) or_return
		}
		for eh in sn.elems { ov_append(&out, &dn.elems, remap[eh] or_else NO_HANDLE, len(sn.elems)) or_return }
		for m in sn.members { ov_append_entry(&out, &dn.members, m.key, remap[m.value] or_else NO_HANDLE, len(sn.members)) or_return }
		if sd := sn.delta; sd != nil {
			dd := ensure_delta(&out, dn) or_return
			for dk in sd.deleted_keys { ov_append_str(&out, &dd.deleted_keys, dk, len(sd.deleted_keys)) or_return }
			for ins in sd.inserted_members { ov_append_member_ins(&out, &dd.inserted_members, ins.at, ins.key, remap[ins.value] or_else NO_HANDLE, len(sd.inserted_members)) or_return }
			for r in sd.renamed_members { ov_append_rename(&out, &dd.renamed_members, r.old_key, r.new_key, r.base_idx, len(sd.renamed_members)) or_return }
			for di in sd.deleted_indices { ov_append(&out, &dd.deleted_indices, di, len(sd.deleted_indices)) or_return }
			for ie in sd.inserted_elems { ov_append(&out, &dd.inserted_elems, Array_Insert{ie.at, remap[ie.value] or_else NO_HANDLE}, len(sd.inserted_elems)) or_return }
			if sd.order != nil { dd.order = slice.clone(sd.order, allocator) or_return }
		}
		for f in sn.facts {
			fo := make_fact_override(&out, f.kind, f.values, f.attr, f.num_tag, f.padded, f.deleted) or_return
			if aerr := ov_append(&out, &dn.facts, fo, len(sn.facts)); aerr != nil {
				free_fact_override(&out, &fo)
				return {}, aerr
			}
		}
	}

	out.root = remap[src.root] or_else NO_HANDLE
	for bn, h in src.by_base { if nh, ok := remap[h]; ok { out.by_base[bn] = nh } }
	if src.parents != nil { out.parents = slice.clone(src.parents, allocator) or_return }
	out.present, out.dirty, out.unlinked_parents, out.has_structural = src.present, src.dirty, src.unlinked_parents, src.has_structural
	for &rh in remap_handles { if nh, ok := remap[rh]; ok { rh = nh } }
	return out, nil
}
