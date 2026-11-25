package edit

import "base:runtime"
import "core:container/handle_map"
import "core:container/xar"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// `Overlay` replaces v1's mutable `Document` with an immutable `base: ^tape.Document` plus a sparse,
// handle-addressed delta tree backed by `core:container/handle_map`.

Handle :: struct {
	idx: u32,
	gen: u32,
}

NO_HANDLE :: Handle{}

Value_Kind :: enum u8 {
	None,
	Null,
	False,
	True,
	Int,
	Uint,
	Float,
	Number_Text, // exact decimal/format number text (e.g. arbitrary-precision big int)
	String,
	Bytes,
	Raw,         // pre-formatted source bytes in the target format
	Array,       // elements stored in `Edit_Node.elems`
	Object,      // entries stored in `Edit_Node.members`
	Base_Ref,    // zero-copy reference to an untouched subtree `base_ref` in `ov.base`
}

// Compact tagged value payload for a newly built or replaced node inside an `Overlay`.
Edit_Value :: struct {
	kind: Value_Kind,
	using _: struct #raw_union {
		i:        i64,
		u:        u64,
		f:        f64,
		text:     string,          // owned by `ov.allocator` when stored on an `Edit_Node`
		raw:      []u8,            // owned by `ov.allocator` for `.Bytes`
		base_ref: tape.Node_Index, // for `.Base_Ref`
		elems:    []Handle,        // input slice for `val_array` (copied into `Edit_Node.elems`)
		entries:  []Object_Entry,  // input slice for `val_object` (copied into `Edit_Node.members`)
	},
}

Object_Entry :: struct {
	key:   string,
	value: Handle,
}

Node_State :: enum u8 {
	Ancestor,        // light ancestor carrier or fact-only node (zero copy of ancestor member lists)
	Replaced,        // value/container replaced by `val` (or newly constructed with `base == tape.NO_NODE`)
	Container_Delta, // base (or `.Base_Ref`) container with sparse structural deltas in `delta`
}

Member_Insert :: struct {
	at:    int,    // target insertion index (0..=len, or -1 for append)
	key:   string, // owned by `ov.allocator`
	value: Handle,
}

Member_Rename :: struct {
	old_key:  string, // original base key (owned by `ov.allocator`)
	new_key:  string, // current effective key (owned by `ov.allocator`)
	base_idx: int,    // original 0-based index of the renamed base member (-1 if unresolved)
}

Array_Insert :: struct {
	at:    int,
	value: Handle,
}

// Lazily allocated sparse structural delta table for `Node_State.Container_Delta`.
Container_Delta :: struct {
	deleted_keys:     [dynamic]string,        // original base object keys deleted
	inserted_members: [dynamic]Member_Insert, // newly inserted object members
	renamed_members:  [dynamic]Member_Rename, // renamed base object members
	deleted_indices:  [dynamic]u32,           // removed base array element indices
	inserted_elems:   [dynamic]Array_Insert,  // newly inserted array elements
	order:            []u32,                  // explicit reorder permutation (nil unless reordered)
}

Fact_Override :: struct {
	kind:    tape.Fact_Kind,
	attr:    string,     // non-empty only when `kind == .Attribute` (owned by `ov.allocator`)
	deleted: bool,
	values:  []string,   // owned strings
	num_tag: Maybe(u64), // numeric CBOR tag value when set from an integer
	padded:  bool,
}

Edit_Node :: struct {
	handle:    Handle,
	base:      tape.Node_Index, // `tape.NO_NODE` for newly constructed nodes
	base_ref:  tape.Node_Index, // non-NO_NODE when constructed from `.Base_Ref` and later structurally edited
	parent:    Handle,
	state:     Node_State,
	val:       Edit_Value,
	elems:     [dynamic]Handle,
	members:   [dynamic]Object_Entry,
	delta:     ^Container_Delta, // lazily allocated only when `state == .Container_Delta`
	facts:     [dynamic]Fact_Override,
	has_edits: bool,
}

Overlay :: struct {
	base:      ^tape.Document,
	allocator: runtime.Allocator,
	nodes:     handle_map.Dynamic_Handle_Map(Edit_Node, Handle),
	root:      Handle,
	by_base:   map[tape.Node_Index]Handle,
	parents:   []tape.Node_Index,
	present:   tape.Facts,
	dirty:     bool,
}

init :: proc(ov: ^Overlay, base: ^tape.Document, allocator := context.allocator) -> Error {
	if base == nil || len(base.nodes) == 0 {
		return refuse(.No_Document, "overlay requires a built document")
	}
	if base.partial != nil {
		return refuse(.Partial_Document, "cannot edit a partial document")
	}
	ov^ = {
		base      = base,
		allocator = allocator,
		present   = base.present,
	}
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
	for n in dynamic_iter_next(&it) {
		free_edit_node(ov, n)
	}
	handle_map.dynamic_destroy(&ov.nodes)
	delete(ov.by_base)
	if ov.parents != nil {
		delete(ov.parents, ov.allocator)
	}
	ov^ = {}
}

@(private)
dynamic_iter_next :: proc "contextless" (it: ^handle_map.Dynamic_Handle_Map_Iterator(handle_map.Dynamic_Handle_Map(Edit_Node, Handle))) -> (^Edit_Node, bool) {
	for it.index < xar.len(it.m.items) {
		p := xar.get_ptr_unsafe(&it.m.items, it.index)
		it.index += 1
		if p.handle.idx != 0 {
			return p, true
		}
	}
	return nil, false
}

@(private)
ensure_delta :: proc(ov: ^Overlay, n: ^Edit_Node) -> (^Container_Delta, runtime.Allocator_Error) {
	if n.delta != nil {
		return n.delta, nil
	}
	d, err := new(Container_Delta, ov.allocator)
	if err != nil {
		return nil, err
	}
	n.delta = d
	return d, nil
}

@(private)
free_container_delta :: proc(ov: ^Overlay, d: ^Container_Delta) {
	if d == nil {
		return
	}
	a := ov.allocator
	for k in d.deleted_keys {
		delete(k, a)
	}
	delete(d.deleted_keys)
	for ins in d.inserted_members {
		delete(ins.key, a)
	}
	delete(d.inserted_members)
	for r in d.renamed_members {
		delete(r.old_key, a)
		delete(r.new_key, a)
	}
	delete(d.renamed_members)
	delete(d.deleted_indices)
	delete(d.inserted_elems)
	if d.order != nil {
		delete(d.order, a)
	}
	free(d, a)
}

@(private)
reset_node_deltas :: proc(ov: ^Overlay, n: ^Edit_Node) {
	free_edit_value(ov, &n.val)
	clear(&n.elems)
	for m in n.members {
		delete(m.key, ov.allocator)
	}
	clear(&n.members)
	if n.delta != nil {
		free_container_delta(ov, n.delta)
		n.delta = nil
	}
	n.base_ref = tape.NO_NODE
}

@(private)
free_edit_node :: proc(ov: ^Overlay, n: ^Edit_Node) {
	reset_node_deltas(ov, n)
	delete(n.elems)
	delete(n.members)
	for &f in n.facts {
		free_fact_override(ov, &f)
	}
	delete(n.facts)
}

@(private)
free_edit_value :: proc(ov: ^Overlay, v: ^Edit_Value) {
	a := ov.allocator
	#partial switch v.kind {
	case .String, .Number_Text, .Raw:
		if len(v.text) > 0 {
			delete(v.text, a)
		}
	case .Bytes:
		if v.raw != nil {
			delete(v.raw, a)
		}
	}
	v^ = {}
}

@(private)
free_fact_override :: proc(ov: ^Overlay, f: ^Fact_Override) {
	a := ov.allocator
	if len(f.attr) > 0 {
		delete(f.attr, a)
	}
	for s in f.values {
		delete(s, a)
	}
	if f.values != nil {
		delete(f.values, a)
	}
	f^ = {}
}

@(private)
clone_str :: proc(ov: ^Overlay, s: string) -> (string, runtime.Allocator_Error) {
	if len(s) == 0 {
		return "", nil
	}
	return strings.clone(s, ov.allocator)
}

@(private)
clone_value :: proc(ov: ^Overlay, v: Edit_Value) -> (out: Edit_Value, err: runtime.Allocator_Error) {
	out.kind = v.kind
	#partial switch v.kind {
	case .Int:
		out.i = v.i
	case .Uint:
		out.u = v.u
	case .Float:
		out.f = v.f
	case .Base_Ref:
		out.base_ref = v.base_ref
	case .String, .Number_Text, .Raw:
		if len(v.text) > 0 {
			out.text = strings.clone(v.text, ov.allocator) or_return
		}
	case .Bytes:
		if len(v.raw) > 0 {
			out.raw = slice.clone(v.raw, ov.allocator) or_return
		}
	}
	return out, nil
}

// Populates `n.elems` or `n.members` from `val` and links children's `parent` to `owner` (if non-NO_HANDLE).
@(private)
assign_children :: proc(ov: ^Overlay, n: ^Edit_Node, owner: Handle, val: Edit_Value) -> runtime.Allocator_Error {
	if val.kind == .Array {
		if n.elems.allocator.procedure == nil {
			n.elems = make([dynamic]Handle, 0, len(val.elems), ov.allocator)
		}
		for eh in val.elems {
			append(&n.elems, eh) or_return
			if owner != NO_HANDLE {
				if cn, cok := get_node(ov, eh); cok {
					cn.parent = owner
				}
			}
		}
	} else if val.kind == .Object {
		if n.members.allocator.procedure == nil {
			n.members = make([dynamic]Object_Entry, 0, len(val.entries), ov.allocator)
		}
		for entry in val.entries {
			k := clone_str(ov, entry.key) or_return
			if _, aerr := append(&n.members, Object_Entry{key = k, value = entry.value}); aerr != nil {
				delete(k, ov.allocator)
				return aerr
			}
			if owner != NO_HANDLE {
				if cn, cok := get_node(ov, entry.value); cok {
					cn.parent = owner
				}
			}
		}
	}
	return nil
}

// Effective base container index of `n` (`n.base`, or `n.base_ref` if originally a `.Base_Ref`).
node_base_container :: proc "contextless" (n: ^Edit_Node) -> tape.Node_Index {
	if n.base != tape.NO_NODE {
		return n.base
	}
	if n.state == .Replaced && n.val.kind == .Base_Ref {
		return n.val.base_ref
	}
	return n.base_ref
}

// Transitions an `.Ancestor` or `.Base_Ref` node into `.Container_Delta`, preserving its base reference!
@(private)
enter_container_delta :: proc(ov: ^Overlay, n: ^Edit_Node) -> (^Container_Delta, runtime.Allocator_Error) {
	if n.state == .Replaced && n.val.kind == .Base_Ref {
		n.base_ref = n.val.base_ref
		n.val = {}
	}
	n.state = .Container_Delta
	return ensure_delta(ov, n)
}

get_node :: proc "contextless" (ov: ^Overlay, h: Handle) -> (^Edit_Node, bool) {
	if ov == nil || h == NO_HANDLE {
		return nil, false
	}
	return handle_map.dynamic_get(&ov.nodes, h)
}

get_node_by_idx :: proc "contextless" (ov: ^Overlay, idx: u32) -> (^Edit_Node, bool) {
	if ov == nil || idx == 0 || int(idx) >= xar.len(ov.nodes.items) {
		return nil, false
	}
	p := xar.get_ptr_unsafe(&ov.nodes.items, idx)
	if p.handle.idx != idx {
		return nil, false
	}
	return p, true
}

handle_of_idx :: proc "contextless" (ov: ^Overlay, idx: u32) -> Handle {
	if n, ok := get_node_by_idx(ov, idx); ok {
		return n.handle
	}
	return NO_HANDLE
}

ensure_root :: proc(ov: ^Overlay) -> (Handle, Error) {
	if ov.root != NO_HANDLE {
		return ov.root, nil
	}
	h, err := handle_map.dynamic_add(&ov.nodes, Edit_Node{base = tape.ROOT, base_ref = tape.NO_NODE, state = .Ancestor})
	if err != nil {
		return NO_HANDLE, err
	}
	ov.root = h
	ov.by_base[tape.ROOT] = h
	return h, nil
}

@(private)
ensure_parents :: proc(ov: ^Overlay) -> runtime.Allocator_Error {
	if ov.parents != nil {
		return nil
	}
	n := len(ov.base.nodes)
	parents := make([]tape.Node_Index, n, ov.allocator) or_return
	for i in 0 ..< n {
		parents[i] = tape.NO_NODE
	}
	Frame :: struct {
		container: tape.Node_Index,
		end:       tape.Node_Index,
	}
	stack := make([dynamic]Frame, 0, 32, ov.allocator)
	defer delete(stack)
	nodes := ov.base.nodes
	for i := 0; i < n; i += 1 {
		idx := tape.Node_Index(i)
		for len(stack) > 0 && idx >= stack[len(stack) - 1].end {
			pop(&stack)
		}
		if len(stack) > 0 {
			parents[i] = stack[len(stack) - 1].container
		}
		t := nodes[i]
		if t.kind >= .Array && t.n > 1 {
			append(&stack, Frame{container = idx, end = idx + tape.Node_Index(t.n)}) or_return
		}
	}
	ov.parents = parents
	return nil
}

handle_for_base :: proc(ov: ^Overlay, base_node: tape.Node_Index) -> (Handle, Error) {
	if base_node == tape.NO_NODE || int(base_node) >= len(ov.base.nodes) {
		return NO_HANDLE, refuse(.Bad_Handle, "base node out of range", base_node)
	}
	if h, ok := ov.by_base[base_node]; ok {
		return h, nil
	}
	if base_node == tape.ROOT {
		return ensure_root(ov)
	}
	if err := ensure_parents(ov); err != nil {
		return NO_HANDLE, err
	}
	chain := make([dynamic]tape.Node_Index, 0, 16, ov.allocator)
	defer delete(chain)
	cur := base_node
	parent_h := NO_HANDLE
	for {
		if existing, ok := ov.by_base[cur]; ok {
			parent_h = existing
			break
		}
		if _, err := append(&chain, cur); err != nil {
			return NO_HANDLE, err
		}
		if cur == tape.ROOT {
			break
		}
		p := ov.parents[cur]
		if p == tape.NO_NODE {
			break
		}
		cur = p
	}
	#reverse for bn in chain {
		h, err := handle_map.dynamic_add(&ov.nodes, Edit_Node {
			base     = bn,
			base_ref = tape.NO_NODE,
			parent   = parent_h,
			state    = .Ancestor,
		})
		if err != nil {
			return NO_HANDLE, err
		}
		ov.by_base[bn] = h
		if bn == tape.ROOT {
			ov.root = h
		}
		parent_h = h
	}
	return parent_h, nil
}

@(private)
mark_edited :: proc(ov: ^Overlay, h: Handle) {
	ov.dirty = true
	cur := h
	for cur != NO_HANDLE {
		n, ok := get_node(ov, cur)
		if !ok {
			break
		}
		n.has_edits = true
		cur = n.parent
	}
}

new_node :: proc(ov: ^Overlay, val: Edit_Value) -> (Handle, Error) {
	cloned, cerr := clone_value(ov, val)
	if cerr != nil {
		return NO_HANDLE, cerr
	}
	node := Edit_Node {
		base      = tape.NO_NODE,
		base_ref  = tape.NO_NODE,
		state     = .Replaced,
		val       = cloned,
		has_edits = true,
	}
	if aerr := assign_children(ov, &node, NO_HANDLE, val); aerr != nil {
		free_edit_node(ov, &node)
		return NO_HANDLE, aerr
	}
	h, err := handle_map.dynamic_add(&ov.nodes, node)
	if err != nil {
		free_edit_node(ov, &node)
		return NO_HANDLE, err
	}
	if created, ok := get_node(ov, h); ok {
		for eh in created.elems {
			if cn, cok := get_node(ov, eh); cok {
				cn.parent = h
			}
		}
		for entry in created.members {
			if cn, cok := get_node(ov, entry.value); cok {
				cn.parent = h
			}
		}
	}
	return h, nil
}

// Convenience value builders for `Edit_Value`.
val_null :: proc "contextless" () -> Edit_Value { return {kind = .Null} }
val_bool :: proc "contextless" (b: bool) -> Edit_Value { return {kind = .True if b else .False} }
val_int :: proc "contextless" (i: i64) -> Edit_Value { return {kind = .Int, i = i} }
val_uint :: proc "contextless" (u: u64) -> Edit_Value { return {kind = .Uint, u = u} }
val_float :: proc "contextless" (f: f64) -> Edit_Value { return {kind = .Float, f = f} }
val_number_text :: proc "contextless" (s: string) -> Edit_Value { return {kind = .Number_Text, text = s} }
val_string :: proc "contextless" (s: string) -> Edit_Value { return {kind = .String, text = s} }
val_bytes :: proc "contextless" (b: []u8) -> Edit_Value { return {kind = .Bytes, raw = b} }
val_raw :: proc "contextless" (s: string) -> Edit_Value { return {kind = .Raw, text = s} }
val_array :: proc "contextless" (elems: []Handle = nil) -> Edit_Value { return {kind = .Array, elems = elems} }
val_object :: proc "contextless" (entries: []Object_Entry = nil) -> Edit_Value { return {kind = .Object, entries = entries} }
val_base_ref :: proc "contextless" (node: tape.Node_Index) -> Edit_Value { return {kind = .Base_Ref, base_ref = node} }

// Removes stale `ov.by_base` descendant entries inside `[base_c + 1 ..< base_c + n)` when `base_c` is wholly replaced.
@(private)
prune_base_descendants :: proc(ov: ^Overlay, base_c: tape.Node_Index) {
	if base_c == tape.NO_NODE || int(base_c) >= len(ov.base.nodes) {
		return
	}
	t := ov.base.nodes[base_c]
	if t.kind < .Array || t.n <= 1 || len(ov.by_base) <= 1 {
		return
	}
	lo := base_c + 1
	hi := base_c + tape.Node_Index(t.n)
	stale := make([dynamic]tape.Node_Index, 0, 8, ov.allocator)
	defer delete(stale)
	for bn in ov.by_base {
		if bn >= lo && bn < hi {
			append(&stale, bn)
		}
	}
	for bn in stale {
		delete_key(&ov.by_base, bn)
	}
}

// Replaces `target`'s value in place, preserving its stable `Handle`, `base`, `parent`, and any `facts`.
// Clones `val` BEFORE freeing old storage so self-assignment (`set(ov, h, n.val)`) is UAF-free!
set :: proc(ov: ^Overlay, target: Handle, val: Edit_Value) -> Error {
	n, ok := get_node(ov, target)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	cloned, cerr := clone_value(ov, val)
	if cerr != nil {
		return cerr
	}
	// Copy incoming child lists before resetting old ones in case `val.elems`/`val.entries` aliases `n`'s own slices.
	new_elems: [dynamic]Handle
	new_members: [dynamic]Object_Entry
	if val.kind == .Array && len(val.elems) > 0 {
		new_elems = make([dynamic]Handle, len(val.elems), ov.allocator)
		copy(new_elems[:], val.elems)
	} else if val.kind == .Object && len(val.entries) > 0 {
		new_members = make([dynamic]Object_Entry, 0, len(val.entries), ov.allocator)
		for entry in val.entries {
			k, kerr := clone_str(ov, entry.key)
			if kerr != nil {
				for m in new_members {
					delete(m.key, ov.allocator)
				}
				delete(new_members)
				free_edit_value(ov, &cloned)
				return kerr
			}
			append(&new_members, Object_Entry{key = k, value = entry.value})
		}
	}

	if n.base != tape.NO_NODE && n.state != .Replaced {
		prune_base_descendants(ov, n.base)
	}
	reset_node_deltas(ov, n)
	n.state = .Replaced
	n.val = cloned
	if val.kind == .Array {
		delete(n.elems)
		n.elems = new_elems
		for eh in n.elems {
			if cn, cok := get_node(ov, eh); cok {
				cn.parent = target
			}
		}
	} else if val.kind == .Object {
		delete(n.members)
		n.members = new_members
		for entry in n.members {
			if cn, cok := get_node(ov, entry.value); cok {
				cn.parent = target
			}
		}
	}
	mark_edited(ov, target)
	return nil
}

node_kind :: proc "contextless" (ov: ^Overlay, h: Handle) -> tape.Kind {
	n, ok := get_node(ov, h)
	if !ok {
		return .Null
	}
	if n.state == .Replaced {
		switch n.val.kind {
		case .None, .Null:
			return .Null
		case .False:
			return .False
		case .True:
			return .True
		case .Int, .Uint, .Float, .Number_Text:
			return .Number
		case .String, .Raw:
			return .String
		case .Bytes:
			return .Bytes
		case .Array:
			return .Array
		case .Object:
			return .Object
		case .Base_Ref:
			if n.val.base_ref != tape.NO_NODE && int(n.val.base_ref) < len(ov.base.nodes) {
				return ov.base.nodes[n.val.base_ref].kind
			}
			return .Null
		}
	}
	bn := node_base_container(n)
	if bn != tape.NO_NODE && int(bn) < len(ov.base.nodes) {
		return ov.base.nodes[bn].kind
	}
	return .Null
}

// Helper: resolves the 0-based base member index & value node for original base key `orig_key` in `base_obj`.
@(private)
find_base_member_idx :: proc(ov: ^Overlay, base_obj: tape.Node_Index, orig_key: string) -> (idx: int, val_node: tape.Node_Index, found: bool) {
	if base_obj == tape.NO_NODE {
		return -1, tape.NO_NODE, false
	}
	c, p, cerr := tape.children(tape.Reader{doc = ov.base}, base_obj, ov.allocator)
	if cerr != nil || p != .Found {
		return -1, tape.NO_NODE, false
	}
	defer tape.destroy_children(&c)
	i := 0
	for {
		kn, vn, np := tape.next_child(tape.Reader{doc = ov.base}, &c)
		if np != .Found {
			break
		}
		tk := decode_node_text_tmp(ov.base, kn, ov.allocator)
		match := tk.text == orig_key
		free_tmp_text(tk, ov.allocator)
		if match {
			idx = i
			val_node = vn
			found = true
		}
		i += 1
	}
	return idx, val_node, found
}

// Maintains `d.order` when inserting item `slot` at logical position `at`.
@(private)
order_on_insert :: proc(ov: ^Overlay, d: ^Container_Delta, slot: u32, at: int) -> runtime.Allocator_Error {
	if len(d.order) == 0 {
		return nil
	}
	new_ord := make([]u32, len(d.order) + 1, ov.allocator) or_return
	pos := len(d.order) if at < 0 || at > len(d.order) else at
	copy(new_ord[:pos], d.order[:pos])
	new_ord[pos] = slot
	copy(new_ord[pos + 1:], d.order[pos:])
	delete(d.order, ov.allocator)
	d.order = new_ord
	return nil
}

// Maintains `d.order` when deleting `slot` (and shifting any higher insert slots when `is_inserted`).
@(private)
order_on_delete :: proc(ov: ^Overlay, d: ^Container_Delta, slot: u32, is_inserted: bool) {
	if len(d.order) == 0 {
		return
	}
	w := 0
	for v in d.order {
		if v == slot {
			continue
		}
		d.order[w] = v - 1 if (is_inserted && v > slot) else v
		w += 1
	}
	d.order = d.order[:w]
}

// Sets (or appends) member `key` of object `obj` to `val`, returning the member's stable child `Handle`.
set_member :: proc(ov: ^Overlay, obj: Handle, key: string, val: Edit_Value) -> (res: Handle, err: Error) {
	n, ok := get_node(ov, obj)
	if !ok {
		return NO_HANDLE, refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, obj) != .Object {
		return NO_HANDLE, refuse(.Wrong_Container, "set_member requires an object", n.base)
	}
	if n.state == .Replaced && n.val.kind == .Object {
		for &m in n.members {
			if m.key == key {
				set(ov, m.value, val) or_return
				return m.value, nil
			}
		}
		ch := new_node(ov, val) or_return
		if cn, cok := get_node(ov, ch); cok {
			cn.parent = obj
		}
		k, kerr := clone_str(ov, key)
		if kerr != nil {
			return NO_HANDLE, kerr
		}
		n, _ = get_node(ov, obj)
		if n.members.allocator.procedure == nil {
			n.members = make([dynamic]Object_Entry, 0, 4, ov.allocator)
		}
		if _, aerr := append(&n.members, Object_Entry{key = k, value = ch}); aerr != nil {
			delete(k, ov.allocator)
			return NO_HANDLE, aerr
		}
		mark_edited(ov, obj)
		return ch, nil
	}
	base_obj := node_base_container(n)
	d := n.delta
	if d != nil {
		// 1. Check already-inserted members.
		for &ins in d.inserted_members {
			if ins.key == key {
				set(ov, ins.value, val) or_return
				return ins.value, nil
			}
		}
		// 2. Check renamed base members matching `key` as `new_key`.
		for r in d.renamed_members {
			if r.new_key == key {
				if child_base, p := tape.member(tape.Reader{doc = ov.base}, base_obj, r.old_key); p == .Found {
					ch := handle_for_base(ov, child_base) or_return
					set(ov, ch, val) or_return
					return ch, nil
				}
			}
		}
		// 3. If `key` was previously deleted from `base_obj`, restore it in-place rather than duplicating in `inserted_members`!
		for dk, di in d.deleted_keys {
			if dk == key {
				// Only un-delete if no other member was renamed onto `key` (already checked above).
				if child_base, p := tape.member(tape.Reader{doc = ov.base}, base_obj, key); p == .Found {
					bidx, _, _ := find_base_member_idx(ov, base_obj, key)
					delete(dk, ov.allocator)
					ordered_remove(&d.deleted_keys, di)
					if len(d.order) > 0 && bidx >= 0 {
						order_on_insert(ov, d, u32(bidx), -1) or_return
					}
					ch := handle_for_base(ov, child_base) or_return
					set(ov, ch, val) or_return
					return ch, nil
				}
				delete(dk, ov.allocator)
				ordered_remove(&d.deleted_keys, di)
				break
			}
		}
		// 4. If original base `key` was renamed away to another name, setting `key` inserts a new member.
		renamed_away := false
		for r in d.renamed_members {
			if r.old_key == key && r.new_key != key {
				renamed_away = true
				break
			}
		}
		if renamed_away {
			return insert_member(ov, obj, -1, key, val)
		}
	}
	// 5. Base member exists directly in `base_obj` -> update its stable base handle in place (O(1) + ancestor chain)!
	if base_obj != tape.NO_NODE && n.base != tape.NO_NODE {
		if child_base, p := tape.member(tape.Reader{doc = ov.base}, base_obj, key); p == .Found {
			ch := handle_for_base(ov, child_base) or_return
			set(ov, ch, val) or_return
			return ch, nil
		}
	} else if base_obj != tape.NO_NODE {
		// `.Base_Ref` object: do not alias `ov.by_base`; replace via delete + insert on this ref's delta!
		if _, p := tape.member(tape.Reader{doc = ov.base}, base_obj, key); p == .Found {
			del_member(ov, obj, key) or_return
		}
	}
	return insert_member(ov, obj, -1, key, val)
}

insert_member :: proc(ov: ^Overlay, obj: Handle, at: int, key: string, val: Edit_Value) -> (res: Handle, err: Error) {
	n, ok := get_node(ov, obj)
	if !ok {
		return NO_HANDLE, refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, obj) != .Object {
		return NO_HANDLE, refuse(.Wrong_Container, "insert_member requires an object", n.base)
	}
	ch := new_node(ov, val) or_return
	if cn, cok := get_node(ov, ch); cok {
		cn.parent = obj
	}
	k, kerr := clone_str(ov, key)
	if kerr != nil {
		return NO_HANDLE, kerr
	}
	n, _ = get_node(ov, obj)
	if n.state == .Replaced && n.val.kind == .Object {
		if n.members.allocator.procedure == nil {
			n.members = make([dynamic]Object_Entry, 0, 4, ov.allocator)
		}
		pos := len(n.members) if at < 0 || at > len(n.members) else at
		if _, ierr := inject_at(&n.members, pos, Object_Entry{key = k, value = ch}); ierr != nil {
			delete(k, ov.allocator)
			return NO_HANDLE, ierr
		}
		mark_edited(ov, obj)
		return ch, nil
	}
	d := enter_container_delta(ov, n) or_return
	if d.inserted_members.allocator.procedure == nil {
		d.inserted_members = make([dynamic]Member_Insert, 0, 4, ov.allocator)
	}
	ins_idx := len(d.inserted_members)
	if _, aerr := append(&d.inserted_members, Member_Insert{at = at, key = k, value = ch}); aerr != nil {
		delete(k, ov.allocator)
		return NO_HANDLE, aerr
	}
	if len(d.order) > 0 {
		base_obj := node_base_container(n)
		bc := max(0, tape.child_count(ov.base, base_obj, ov.base.nodes[base_obj]))
		order_on_insert(ov, d, u32(bc + ins_idx), at) or_return
	}
	mark_edited(ov, obj)
	return ch, nil
}

del_member :: proc(ov: ^Overlay, obj: Handle, key: string) -> Error {
	n, ok := get_node(ov, obj)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, obj) != .Object {
		return refuse(.Wrong_Container, "del_member requires an object", n.base)
	}
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
		// 1. Delete from newly inserted members.
		for ins, i in d.inserted_members {
			if ins.key == key {
				delete(ins.key, ov.allocator)
				ordered_remove(&d.inserted_members, i)
				if len(d.order) > 0 && base_obj != tape.NO_NODE {
					bc := max(0, tape.child_count(ov.base, base_obj, ov.base.nodes[base_obj]))
					order_on_delete(ov, d, u32(bc + i), true)
				}
				mark_edited(ov, obj)
				return nil
			}
		}
		// 2. If `key` is the current `new_key` of a renamed base member, remove the rename and delete its original base key!
		for r, ri in d.renamed_members {
			if r.new_key == key {
				orig := r.old_key
				bidx := r.base_idx
				delete(r.new_key, ov.allocator)
				ordered_remove(&d.renamed_members, ri)
				// Transfer ownership of `orig` into `d.deleted_keys`.
				if d.deleted_keys.allocator.procedure == nil {
					d.deleted_keys = make([dynamic]string, 0, 4, ov.allocator)
				}
				if _, aerr := append(&d.deleted_keys, orig); aerr != nil {
					delete(orig, ov.allocator)
					return aerr
				}
				if len(d.order) > 0 && bidx >= 0 {
					order_on_delete(ov, d, u32(bidx), false)
				}
				mark_edited(ov, obj)
				return nil
			}
		}
		// 3. If original base `key` was renamed away or already deleted, no-op.
		for r in d.renamed_members {
			if r.old_key == key && r.new_key != key {
				return nil
			}
		}
		for dk in d.deleted_keys {
			if dk == key {
				return nil
			}
		}
	}
	bidx, _, found := find_base_member_idx(ov, base_obj, key)
	if !found {
		return nil
	}
	d := enter_container_delta(ov, n) or_return
	if d.deleted_keys.allocator.procedure == nil {
		d.deleted_keys = make([dynamic]string, 0, 4, ov.allocator)
	}
	dk, kerr := clone_str(ov, key)
	if kerr != nil {
		return kerr
	}
	if _, aerr := append(&d.deleted_keys, dk); aerr != nil {
		delete(dk, ov.allocator)
		return aerr
	}
	if len(d.order) > 0 && bidx >= 0 {
		order_on_delete(ov, d, u32(bidx), false)
	}
	mark_edited(ov, obj)
	return nil
}

// Renames member `old_key` to `new_key` on object `obj` (handles chained renames `a->b; b->c`, swaps `a->b; b->a`, and deletes).
rename_member :: proc(ov: ^Overlay, obj: Handle, old_key, new_key: string) -> Error {
	n, ok := get_node(ov, obj)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, obj) != .Object {
		return refuse(.Wrong_Container, "rename_member requires an object", n.base)
	}
	if old_key == new_key {
		return nil
	}
	if n.state == .Replaced && n.val.kind == .Object {
		for &m in n.members {
			if m.key == old_key {
				nk, kerr := clone_str(ov, new_key)
				if kerr != nil {
					return kerr
				}
				delete(m.key, ov.allocator)
				m.key = nk
				mark_edited(ov, obj)
				return nil
			}
		}
		return nil
	}
	if d := n.delta; d != nil {
		// 1. Rename an inserted member directly.
		for &ins in d.inserted_members {
			if ins.key == old_key {
				nk, kerr := clone_str(ov, new_key)
				if kerr != nil {
					return kerr
				}
				delete(ins.key, ov.allocator)
				ins.key = nk
				mark_edited(ov, obj)
				return nil
			}
		}
		// 2. Chained rename (`a -> b`, then `b -> c` => `a -> c`, or `a -> b`, `b -> a` => remove identity rename!).
		for &r, ri in d.renamed_members {
			if r.new_key == old_key {
				if r.old_key == new_key {
					delete(r.old_key, ov.allocator)
					delete(r.new_key, ov.allocator)
					ordered_remove(&d.renamed_members, ri)
					mark_edited(ov, obj)
					return nil
				}
				nk, kerr := clone_str(ov, new_key)
				if kerr != nil {
					return kerr
				}
				delete(r.new_key, ov.allocator)
				r.new_key = nk
				mark_edited(ov, obj)
				return nil
			}
		}
		// 3. Cannot rename a deleted or already-renamed-away base key.
		for dk in d.deleted_keys {
			if dk == old_key {
				return nil
			}
		}
		for r in d.renamed_members {
			if r.old_key == old_key {
				return nil
			}
		}
	}
	base_obj := node_base_container(n)
	bidx, _, found := find_base_member_idx(ov, base_obj, old_key)
	if !found {
		return nil
	}
	d := enter_container_delta(ov, n) or_return
	if d.renamed_members.allocator.procedure == nil {
		d.renamed_members = make([dynamic]Member_Rename, 0, 2, ov.allocator)
	}
	ok_copy, oerr := clone_str(ov, old_key)
	if oerr != nil {
		return oerr
	}
	nk_copy, nerr := clone_str(ov, new_key)
	if nerr != nil {
		delete(ok_copy, ov.allocator)
		return nerr
	}
	if _, aerr := append(&d.renamed_members, Member_Rename{old_key = ok_copy, new_key = nk_copy, base_idx = bidx}); aerr != nil {
		delete(ok_copy, ov.allocator)
		delete(nk_copy, ov.allocator)
		return aerr
	}
	mark_edited(ov, obj)
	return nil
}

set_element :: proc(ov: ^Overlay, arr: Handle, index: int, val: Edit_Value) -> (res: Handle, err: Error) {
	n, ok := get_node(ov, arr)
	if !ok {
		return NO_HANDLE, refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, arr) != .Array {
		return NO_HANDLE, refuse(.Wrong_Container, "set_element requires an array", n.base)
	}
	if n.state == .Replaced && n.val.kind == .Array {
		idx := index if index >= 0 else len(n.elems) + index
		if idx < 0 {
			return NO_HANDLE, refuse(.Bad_Position, "negative array index out of bounds", n.base)
		}
		for len(n.elems) < idx {
			nh := new_node(ov, val_null()) or_return
			if cn, cok := get_node(ov, nh); cok {
				cn.parent = arr
			}
			n, _ = get_node(ov, arr)
			if _, aerr := append(&n.elems, nh); aerr != nil {
				return NO_HANDLE, aerr
			}
		}
		if idx < len(n.elems) {
			set(ov, n.elems[idx], val) or_return
			return n.elems[idx], nil
		}
		ch := new_node(ov, val) or_return
		if cn, cok := get_node(ov, ch); cok {
			cn.parent = arr
		}
		n, _ = get_node(ov, arr)
		if _, aerr := append(&n.elems, ch); aerr != nil {
			return NO_HANDLE, aerr
		}
		mark_edited(ov, arr)
		return ch, nil
	}
	base_arr := node_base_container(n)
	if n.state == .Ancestor && n.base != tape.NO_NODE {
		elem_base, p := tape.element(tape.Reader{doc = ov.base}, base_arr, index)
		if p == .Found {
			ch := handle_for_base(ov, elem_base) or_return
			set(ov, ch, val) or_return
			return ch, nil
		}
		cur_len := container_len(ov, arr)
		idx := index if index >= 0 else cur_len + index
		if idx < 0 {
			return NO_HANDLE, refuse(.Bad_Position, "negative array index out of bounds", base_arr)
		}
		for cur_len < idx {
			_ = insert_element(ov, arr, -1, val_null()) or_return
			cur_len += 1
		}
		return insert_element(ov, arr, -1, val)
	}
	eff := effective_elements(ov, arr, ov.allocator) or_return
	defer delete(eff, ov.allocator)
	idx := index if index >= 0 else len(eff) + index
	if idx < 0 {
		return NO_HANDLE, refuse(.Bad_Position, "negative array index out of bounds", base_arr)
	}
	if idx < len(eff) {
		e := eff[idx]
		ch := e.handle
		if ch == NO_HANDLE {
			if n.base != tape.NO_NODE {
				ch = handle_for_base(ov, e.base) or_return
				set(ov, ch, val) or_return
				return ch, nil
			}
			// `.Base_Ref` array: replace via del + insert without aliasing `ov.by_base`.
			del_element(ov, arr, idx) or_return
			return insert_element(ov, arr, idx, val)
		}
		set(ov, ch, val) or_return
		return ch, nil
	}
	for k := len(eff); k < idx; k += 1 {
		_ = insert_element(ov, arr, -1, val_null()) or_return
	}
	return insert_element(ov, arr, -1, val)
}

insert_element :: proc(ov: ^Overlay, arr: Handle, at: int, val: Edit_Value) -> (res: Handle, err: Error) {
	n, ok := get_node(ov, arr)
	if !ok {
		return NO_HANDLE, refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, arr) != .Array {
		return NO_HANDLE, refuse(.Wrong_Container, "insert_element requires an array", n.base)
	}
	ch := new_node(ov, val) or_return
	if cn, cok := get_node(ov, ch); cok {
		cn.parent = arr
	}
	n, _ = get_node(ov, arr)
	if n.state == .Replaced && n.val.kind == .Array {
		if n.elems.allocator.procedure == nil {
			n.elems = make([dynamic]Handle, 0, 4, ov.allocator)
		}
		pos := len(n.elems) if at < 0 || at > len(n.elems) else at
		if _, ierr := inject_at(&n.elems, pos, ch); ierr != nil {
			return NO_HANDLE, ierr
		}
		mark_edited(ov, arr)
		return ch, nil
	}
	d := enter_container_delta(ov, n) or_return
	if d.inserted_elems.allocator.procedure == nil {
		d.inserted_elems = make([dynamic]Array_Insert, 0, 4, ov.allocator)
	}
	ins_idx := len(d.inserted_elems)
	if _, aerr := append(&d.inserted_elems, Array_Insert{at = at, value = ch}); aerr != nil {
		return NO_HANDLE, aerr
	}
	if len(d.order) > 0 {
		base_arr := node_base_container(n)
		bc := max(0, tape.child_count(ov.base, base_arr, ov.base.nodes[base_arr]))
		order_on_insert(ov, d, u32(bc + ins_idx), at) or_return
	}
	mark_edited(ov, arr)
	return ch, nil
}

del_element :: proc(ov: ^Overlay, arr: Handle, index: int) -> Error {
	n, ok := get_node(ov, arr)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	if node_kind(ov, arr) != .Array {
		return refuse(.Wrong_Container, "del_element requires an array", n.base)
	}
	if n.state == .Replaced && n.val.kind == .Array {
		idx := index if index >= 0 else len(n.elems) + index
		if idx < 0 || idx >= len(n.elems) {
			return nil
		}
		ordered_remove(&n.elems, idx)
		mark_edited(ov, arr)
		return nil
	}
	eff := effective_elements(ov, arr, ov.allocator) or_return
	defer delete(eff, ov.allocator)
	idx := index if index >= 0 else len(eff) + index
	if idx < 0 || idx >= len(eff) {
		return nil
	}
	e := eff[idx]
	n, _ = get_node(ov, arr)
	base_arr := node_base_container(n)
	if e.is_inserted {
		d := n.delta
		ordered_remove(&d.inserted_elems, e.insert_idx)
		if len(d.order) > 0 && base_arr != tape.NO_NODE {
			bc := max(0, tape.child_count(ov.base, base_arr, ov.base.nodes[base_arr]))
			order_on_delete(ov, d, u32(bc + e.insert_idx), true)
		}
		mark_edited(ov, arr)
		return nil
	}
	d := enter_container_delta(ov, n) or_return
	if d.deleted_indices.allocator.procedure == nil {
		d.deleted_indices = make([dynamic]u32, 0, 4, ov.allocator)
	}
	if _, aerr := append(&d.deleted_indices, u32(e.base_idx)); aerr != nil {
		return aerr
	}
	if len(d.order) > 0 {
		order_on_delete(ov, d, u32(e.base_idx), false)
	}
	mark_edited(ov, arr)
	return nil
}

reorder :: proc(ov: ^Overlay, container: Handle, order: []u32) -> Error {
	n, ok := get_node(ov, container)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	k := node_kind(ov, container)
	if k != .Array && k != .Object {
		return refuse(.Wrong_Container, "reorder requires an array or object", n.base)
	}
	cloned, err := slice.clone(order, ov.allocator)
	if err != nil {
		return err
	}
	d, derr := enter_container_delta(ov, n)
	if derr != nil {
		delete(cloned, ov.allocator)
		return derr
	}
	if d.order != nil {
		delete(d.order, ov.allocator)
	}
	d.order = cloned
	mark_edited(ov, container)
	return nil
}

// Recomputes `ov.present` after a fact deletion so `ov.present` never retains stale fact kinds.
@(private)
recompute_present :: proc(ov: ^Overlay) {
	p := ov.base.present if ov.base != nil else tape.Facts{}
	it := handle_map.dynamic_iterator_make(&ov.nodes)
	for n in dynamic_iter_next(&it) {
		for f in n.facts {
			if !f.deleted {
				p += {f.kind}
			}
		}
	}
	ov.present = p
}

set_fact :: proc(
	ov: ^Overlay,
	target: Handle,
	kind: tape.Fact_Kind,
	values: []string,
	attr := "",
	num_tag: Maybe(u64) = nil,
	padded := true,
) -> Error {
	n, ok := get_node(ov, target)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	fo := make_fact_override(ov, kind, values, attr, num_tag, padded, false) or_return
	for &f in n.facts {
		if f.kind == kind && (kind != .Attribute || f.attr == attr) {
			free_fact_override(ov, &f)
			f = fo
			ov.present += {kind}
			mark_edited(ov, target)
			return nil
		}
	}
	if n.facts.allocator.procedure == nil {
		n.facts = make([dynamic]Fact_Override, 0, 2, ov.allocator)
	}
	if _, aerr := append(&n.facts, fo); aerr != nil {
		free_fact_override(ov, &fo)
		return aerr
	}
	ov.present += {kind}
	mark_edited(ov, target)
	return nil
}

del_fact :: proc(ov: ^Overlay, target: Handle, kind: tape.Fact_Kind, attr := "") -> Error {
	n, ok := get_node(ov, target)
	if !ok {
		return refuse(.Bad_Handle, "invalid overlay handle")
	}
	// Allocate replacement override BEFORE freeing the previous one so OOM never corrupts state!
	fo := make_fact_override(ov, kind, nil, attr, nil, false, true) or_return
	for &f in n.facts {
		if f.kind == kind && (kind != .Attribute || f.attr == attr) {
			free_fact_override(ov, &f)
			f = fo
			recompute_present(ov)
			mark_edited(ov, target)
			return nil
		}
	}
	if n.facts.allocator.procedure == nil {
		n.facts = make([dynamic]Fact_Override, 0, 2, ov.allocator)
	}
	if _, aerr := append(&n.facts, fo); aerr != nil {
		free_fact_override(ov, &fo)
		return aerr
	}
	mark_edited(ov, target)
	return nil
}

@(private)
make_fact_override :: proc(
	ov: ^Overlay,
	kind: tape.Fact_Kind,
	values: []string,
	attr: string,
	num_tag: Maybe(u64),
	padded: bool,
	deleted: bool,
) -> (fo: Fact_Override, err: runtime.Allocator_Error) {
	fo = {
		kind    = kind,
		deleted = deleted,
		num_tag = num_tag,
		padded  = padded,
	}
	defer if err != nil {
		free_fact_override(ov, &fo)
	}
	if len(attr) > 0 {
		fo.attr = clone_str(ov, attr) or_return
	}
	if !deleted && len(values) > 0 {
		fo.values = make([]string, len(values), ov.allocator) or_return
		for v, i in values {
			fo.values[i] = clone_str(ov, v) or_return
		}
	}
	return fo, nil
}

find_fact_override :: proc "contextless" (ov: ^Overlay, target: Handle, kind: tape.Fact_Kind, attr := "") -> (^Fact_Override, bool) {
	n, ok := get_node(ov, target)
	if !ok {
		return nil, false
	}
	for &f in n.facts {
		if f.kind == kind && (kind != .Attribute || f.attr == attr) {
			return &f, true
		}
	}
	return nil, false
}

set_path :: proc(ov: ^Overlay, steps: []tape.Step, val: Edit_Value) -> (res: Handle, err: Error) {
	cur := ensure_root(ov) or_return
	if len(steps) == 0 {
		set(ov, cur, val) or_return
		return cur, nil
	}
	for step, i in steps {
		last := i + 1 == len(steps)
		switch s in step {
		case tape.Name:
			if last {
				return set_member(ov, cur, string(s), val)
			}
			ch, cb, found := lookup_member(ov, cur, string(s))
			if found {
				cur = ch if ch != NO_HANDLE else (handle_for_base(ov, cb) or_return)
			} else {
				_, next_idx := steps[i + 1].(tape.Index)
				cur = set_member(ov, cur, string(s), val_array() if next_idx else val_object()) or_return
			}
		case tape.Index:
			if last {
				return set_element(ov, cur, int(s), val)
			}
			ch, cb, found := lookup_element(ov, cur, int(s))
			if found {
				cur = ch if ch != NO_HANDLE else (handle_for_base(ov, cb) or_return)
			} else {
				_, next_idx := steps[i + 1].(tape.Index)
				cur = set_element(ov, cur, int(s), val_array() if next_idx else val_object()) or_return
			}
		case tape.All, tape.Slice, tape.Descend:
			return NO_HANDLE, refuse(.Bad_Path, "path edit requires concrete Name/Index steps")
		}
	}
	return cur, nil
}

del_path :: proc(ov: ^Overlay, steps: []tape.Step) -> Error {
	if len(steps) == 0 {
		return refuse(.Bad_Path, "cannot delete root")
	}
	cur := ensure_root(ov) or_return
	for step in steps[:len(steps) - 1] {
		switch s in step {
		case tape.Name:
			ch, cb, found := lookup_member(ov, cur, string(s))
			if !found {
				return nil
			}
			cur = ch if ch != NO_HANDLE else (handle_for_base(ov, cb) or_return)
		case tape.Index:
			ch, cb, found := lookup_element(ov, cur, int(s))
			if !found {
				return nil
			}
			cur = ch if ch != NO_HANDLE else (handle_for_base(ov, cb) or_return)
		case tape.All, tape.Slice, tape.Descend:
			return refuse(.Bad_Path, "path delete requires concrete Name/Index steps")
		}
	}
	switch s in steps[len(steps) - 1] {
	case tape.Name:
		return del_member(ov, cur, string(s))
	case tape.Index:
		return del_element(ov, cur, int(s))
	case tape.All, tape.Slice, tape.Descend:
		return refuse(.Bad_Path, "path delete requires concrete Name/Index steps")
	}
	return nil
}

Effective_Element :: struct {
	handle:      Handle,
	base:        tape.Node_Index,
	base_idx:    int,
	insert_idx:  int,
	is_inserted: bool,
}

Effective_Member :: struct {
	key:         string,
	handle:      Handle,
	base_key:    tape.Node_Index,
	base_val:    tape.Node_Index,
	base_idx:    int,
	insert_idx:  int,
	is_inserted: bool,
	renamed:     bool,
}

lookup_member :: proc(ov: ^Overlay, obj: Handle, key: string) -> (child_h: Handle, child_base: tape.Node_Index, found: bool) {
	n, ok := get_node(ov, obj)
	if !ok {
		return NO_HANDLE, tape.NO_NODE, false
	}
	if n.state == .Replaced {
		if n.val.kind == .Object {
			for m in n.members {
				if m.key == key {
					return m.value, tape.NO_NODE, true
				}
			}
			return NO_HANDLE, tape.NO_NODE, false
		}
		if n.val.kind == .Base_Ref {
			return lookup_base_member(ov, n.val.base_ref, key, n.base != tape.NO_NODE)
		}
		return NO_HANDLE, tape.NO_NODE, false
	}
	base_obj := node_base_container(n)
	if d := n.delta; n.state == .Container_Delta && d != nil {
		for ins in d.inserted_members {
			if ins.key == key {
				return ins.value, tape.NO_NODE, true
			}
		}
		// Check renamed members FIRST (handles swaps like `a->b; b->a` and `del(b); rename(a, b)`!).
		for r in d.renamed_members {
			if r.new_key == key {
				return lookup_base_member(ov, base_obj, r.old_key, n.base != tape.NO_NODE)
			}
		}
		// If original `key` was renamed away to something else, it's no longer present under `key`.
		for r in d.renamed_members {
			if r.old_key == key && r.new_key != key {
				return NO_HANDLE, tape.NO_NODE, false
			}
		}
		for dk in d.deleted_keys {
			if dk == key {
				return NO_HANDLE, tape.NO_NODE, false
			}
		}
	}
	return lookup_base_member(ov, base_obj, key, n.base != tape.NO_NODE)
}

@(private)
lookup_base_member :: proc(ov: ^Overlay, base_obj: tape.Node_Index, key: string, use_by_base := true) -> (Handle, tape.Node_Index, bool) {
	if base_obj == tape.NO_NODE {
		return NO_HANDLE, tape.NO_NODE, false
	}
	cb, p := tape.member(tape.Reader{doc = ov.base}, base_obj, key)
	if p != .Found {
		return NO_HANDLE, tape.NO_NODE, false
	}
	if use_by_base {
		if ch, has := ov.by_base[cb]; has {
			return ch, cb, true
		}
	}
	return NO_HANDLE, cb, true
}

lookup_element :: proc(ov: ^Overlay, arr: Handle, index: int) -> (child_h: Handle, child_base: tape.Node_Index, found: bool) {
	n, ok := get_node(ov, arr)
	if !ok {
		return NO_HANDLE, tape.NO_NODE, false
	}
	if n.state == .Replaced {
		if n.val.kind == .Array {
			idx := index if index >= 0 else len(n.elems) + index
			if idx < 0 || idx >= len(n.elems) {
				return NO_HANDLE, tape.NO_NODE, false
			}
			return n.elems[idx], tape.NO_NODE, true
		}
		if n.val.kind == .Base_Ref {
			return lookup_base_element(ov, n.val.base_ref, index, n.base != tape.NO_NODE)
		}
		return NO_HANDLE, tape.NO_NODE, false
	}
	if n.state == .Ancestor {
		return lookup_base_element(ov, n.base, index, true)
	}
	eff, err := effective_elements(ov, arr, ov.allocator)
	if err != nil {
		return NO_HANDLE, tape.NO_NODE, false
	}
	defer delete(eff, ov.allocator)
	idx := index if index >= 0 else len(eff) + index
	if idx < 0 || idx >= len(eff) {
		return NO_HANDLE, tape.NO_NODE, false
	}
	return eff[idx].handle, eff[idx].base, true
}

@(private)
lookup_base_element :: proc(ov: ^Overlay, base_arr: tape.Node_Index, index: int, use_by_base := true) -> (Handle, tape.Node_Index, bool) {
	if base_arr == tape.NO_NODE {
		return NO_HANDLE, tape.NO_NODE, false
	}
	cb, p := tape.element(tape.Reader{doc = ov.base}, base_arr, index)
	if p != .Found {
		return NO_HANDLE, tape.NO_NODE, false
	}
	if use_by_base {
		if ch, has := ov.by_base[cb]; has {
			return ch, cb, true
		}
	}
	return NO_HANDLE, cb, true
}

container_len :: proc(ov: ^Overlay, h: Handle) -> int {
	n, ok := get_node(ov, h)
	if !ok {
		return 0
	}
	if n.state == .Replaced {
		#partial switch n.val.kind {
		case .Array:
			return len(n.elems)
		case .Object:
			return len(n.members)
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
	k := node_kind(ov, h)
	if k == .Array {
		eff, err := effective_elements(ov, h, ov.allocator)
		if err != nil {
			return 0
		}
		defer delete(eff, ov.allocator)
		return len(eff)
	}
	if k == .Object {
		eff, owned, err := effective_members(ov, h, ov.allocator)
		if err != nil {
			return 0
		}
		defer destroy_effective_members(eff, owned, ov.allocator)
		return len(eff)
	}
	return 0
}

effective_elements :: proc(ov: ^Overlay, arr: Handle, allocator: runtime.Allocator) -> (res: []Effective_Element, err: runtime.Allocator_Error) {
	n, ok := get_node(ov, arr)
	if !ok {
		return nil, nil
	}
	if n.state == .Replaced && n.val.kind == .Array {
		out := make([]Effective_Element, len(n.elems), allocator) or_return
		for eh, i in n.elems {
			out[i] = {handle = eh, base = tape.NO_NODE, base_idx = -1, insert_idx = i, is_inserted = true}
		}
		return out, nil
	}
	base_arr := node_base_container(n)
	base_count := tape.child_count(ov.base, base_arr, ov.base.nodes[base_arr])
	if base_count < 0 {
		base_count = 0
	}
	base_nodes := make([]tape.Node_Index, base_count, allocator) or_return
	defer delete(base_nodes, allocator)
	c, _, cerr := tape.children(tape.Reader{doc = ov.base}, base_arr, allocator)
	if cerr != nil {
		return nil, cerr
	}
	defer tape.destroy_children(&c)
	bi := 0
	for {
		_, v, p := tape.next_child(tape.Reader{doc = ov.base}, &c)
		if p != .Found || bi >= base_count {
			break
		}
		base_nodes[bi] = v
		bi += 1
	}
	base_nodes = base_nodes[:bi]
	deleted := make([]bool, len(base_nodes), allocator) or_return
	defer delete(deleted, allocator)
	d := n.delta
	use_by_base := n.base != tape.NO_NODE
	ins_elems: []Array_Insert
	ord: []u32
	if d != nil {
		for di in d.deleted_indices {
			if int(di) < len(deleted) {
				deleted[di] = true
			}
		}
		ins_elems = d.inserted_elems[:]
		ord = d.order
	}
	out := make([dynamic]Effective_Element, 0, len(base_nodes) + len(ins_elems), allocator)
	defer if err != nil {
		delete(out)
	}
	if len(ord) > 0 {
		for idx in ord {
			k := int(idx)
			if k < len(base_nodes) {
				if !deleted[k] {
					bn := base_nodes[k]
					eh := (ov.by_base[bn] or_else NO_HANDLE) if use_by_base else NO_HANDLE
					append(&out, Effective_Element{handle = eh, base = bn, base_idx = k, insert_idx = -1}) or_return
				}
			} else if ins_k := k - len(base_nodes); ins_k < len(ins_elems) {
				append(&out, Effective_Element{handle = ins_elems[ins_k].value, base = tape.NO_NODE, base_idx = -1, insert_idx = ins_k, is_inserted = true}) or_return
			}
		}
		return out[:], nil
	}
	for j in 0 ..= len(base_nodes) {
		for ins, ins_i in ins_elems {
			target := ins.at
			if target < 0 || target > len(base_nodes) {
				target = len(base_nodes)
			}
			if target == j {
				append(&out, Effective_Element{handle = ins.value, base = tape.NO_NODE, base_idx = -1, insert_idx = ins_i, is_inserted = true}) or_return
			}
		}
		if j < len(base_nodes) && !deleted[j] {
			bn := base_nodes[j]
			eh := (ov.by_base[bn] or_else NO_HANDLE) if use_by_base else NO_HANDLE
			append(&out, Effective_Element{handle = eh, base = bn, base_idx = j, insert_idx = -1}) or_return
		}
	}
	return out[:], nil
}

effective_members :: proc(ov: ^Overlay, obj: Handle, allocator: runtime.Allocator) -> (members: []Effective_Member, owned_keys: []string, err: runtime.Allocator_Error) {
	n, ok := get_node(ov, obj)
	if !ok {
		return nil, nil, nil
	}
	if n.state == .Replaced && n.val.kind == .Object {
		out := make([]Effective_Member, len(n.members), allocator) or_return
		for m, i in n.members {
			out[i] = {key = m.key, handle = m.value, base_key = tape.NO_NODE, base_val = tape.NO_NODE, base_idx = -1, insert_idx = i, is_inserted = true}
		}
		return out, nil, nil
	}
	base_obj := node_base_container(n)
	Base_Entry :: struct {
		key:      string,
		base_key: tape.Node_Index,
		base_val: tape.Node_Index,
		deleted:  bool,
		renamed:  bool,
	}
	base_list := make([dynamic]Base_Entry, 0, 8, allocator)
	defer delete(base_list)
	dec_keys := make([dynamic]string, 0, 4, allocator)
	defer if err != nil {
		for dk in dec_keys {
			delete(dk, allocator)
		}
		delete(dec_keys)
	}
	d := n.delta
	use_by_base := n.base != tape.NO_NODE
	c, p, cerr := tape.children(tape.Reader{doc = ov.base}, base_obj, allocator)
	if cerr != nil {
		return nil, nil, cerr
	}
	defer tape.destroy_children(&c)
	if p == .Found {
		for {
			kn, vn, np := tape.next_child(tape.Reader{doc = ov.base}, &c)
			if np != .Found {
				break
			}
			kstr: string
			if kn != tape.NO_NODE {
				tk := decode_node_text_tmp(ov.base, kn, allocator)
				kstr = tk.text
				if tk.owned {
					append(&dec_keys, tk.text) or_return
				}
			} else if c.keys_n != 0 {
				kt := tape.cell_key(tape.Reader{doc = ov.base}, c)
				room := tape.text_room(ov.base, kt)
				if room == 0 {
					kstr = string(tape.span_bytes(ov.base, kt.lo, kt.n))
				} else {
					buf := make([]u8, room, allocator) or_return
					if ds, dok := tape.node_text(ov.base, kt, buf); dok {
						if raw_data(ds) == raw_data(buf) {
							kstr = ds
							append(&dec_keys, string(buf)) or_return
						} else {
							delete(buf, allocator)
							kstr = ds
						}
					} else {
						delete(buf, allocator)
					}
				}
			}
			is_del := false
			is_ren := false
			if d != nil {
				for dk in d.deleted_keys {
					if dk == kstr {
						is_del = true
						break
					}
				}
				if !is_del {
					for r in d.renamed_members {
						if r.old_key == kstr {
							kstr = r.new_key
							is_ren = true
							break
						}
					}
				}
			}
			append(&base_list, Base_Entry{key = kstr, base_key = kn, base_val = vn, deleted = is_del, renamed = is_ren}) or_return
		}
	}
	ins_members: []Member_Insert
	ord: []u32
	if d != nil {
		ins_members = d.inserted_members[:]
		ord = d.order
	}
	out := make([dynamic]Effective_Member, 0, len(base_list) + len(ins_members), allocator)
	defer if err != nil {
		delete(out)
	}
	if len(ord) > 0 {
		for idx in ord {
			k := int(idx)
			if k < len(base_list) {
				be := base_list[k]
				if !be.deleted {
					eh := (ov.by_base[be.base_val] or_else NO_HANDLE) if use_by_base else NO_HANDLE
					append(&out, Effective_Member{key = be.key, handle = eh, base_key = be.base_key, base_val = be.base_val, base_idx = k, insert_idx = -1, renamed = be.renamed}) or_return
				}
			} else if ins_k := k - len(base_list); ins_k < len(ins_members) {
				ins := ins_members[ins_k]
				append(&out, Effective_Member{key = ins.key, handle = ins.value, base_key = tape.NO_NODE, base_val = tape.NO_NODE, base_idx = -1, insert_idx = ins_k, is_inserted = true}) or_return
			}
		}
		return out[:], dec_keys[:], nil
	}
	for j in 0 ..= len(base_list) {
		for ins, ins_i in ins_members {
			target := ins.at
			if target < 0 || target > len(base_list) {
				target = len(base_list)
			}
			if target == j {
				append(&out, Effective_Member{key = ins.key, handle = ins.value, base_key = tape.NO_NODE, base_val = tape.NO_NODE, base_idx = -1, insert_idx = ins_i, is_inserted = true}) or_return
			}
		}
		if j < len(base_list) && !base_list[j].deleted {
			be := base_list[j]
			eh := (ov.by_base[be.base_val] or_else NO_HANDLE) if use_by_base else NO_HANDLE
			append(&out, Effective_Member{key = be.key, handle = eh, base_key = be.base_key, base_val = be.base_val, base_idx = j, insert_idx = -1, renamed = be.renamed}) or_return
		}
	}
	return out[:], dec_keys[:], nil
}

destroy_effective_members :: proc(members: []Effective_Member, owned_keys: []string, allocator: runtime.Allocator) {
	delete(members, allocator)
	for k in owned_keys {
		delete(k, allocator)
	}
	delete(owned_keys, allocator)
}
