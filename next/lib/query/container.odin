package query

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// Arrays and objects: built ones in blocks of the heap, and a document's, read through the tape's readers. An object
// holds each key once, in the order its keys first came. An operation that changes a container takes it by pointer,
// owned by the caller: it changes the block in place when the caller holds it alone, else a copy that replaces it.

@(private)
array_size :: #force_inline proc "contextless" (cap: int) -> int {
	return size_of(Array_Block) + cap * size_of(Value)
}

@(private)
object_size :: #force_inline proc "contextless" (cap: int) -> int {
	return size_of(Object_Block) + cap * size_of(Entry)
}

@(private)
array_items :: #force_inline proc "contextless" (a: ^Array_Block) -> []Value {
	return ([^]Value)(uintptr(a) + size_of(Array_Block))[:a.len]
}

@(private)
object_entries :: #force_inline proc "contextless" (o: ^Object_Block) -> []Entry {
	return ([^]Entry)(uintptr(o) + size_of(Object_Block))[:o.len]
}

// The elements of built array `v`.
items_of :: #force_inline proc "contextless" (v: Value) -> []Value {
	return array_items((^Array_Block)(v.p))
}

// The entries of built object `v`.
entries_of :: #force_inline proc "contextless" (v: Value) -> []Entry {
	return object_entries((^Object_Block)(v.p))
}

// The type of `v`.
type_of :: proc "contextless" (v: Value) -> Type {
	switch v.kind {
	case .Absent:
		return .Absent
	case .Null:
		return .Null
	case .False:
		return .False
	case .True:
		return .True
	case .Int, .Double, .Big:
		return .Number
	case .String:
		return .String
	case .Array:
		return .Array
	case .Object:
		return .Object
	case .Node:
		return node_type(node_token(v))
	}
	return .Null
}

@(private)
node_type :: #force_inline proc "contextless" (t: tape.Node) -> Type {
	#partial switch t.kind {
	case .Null:
		return .Null
	case .False:
		return .False
	case .True:
		return .True
	case .Number:
		return .Number
	case .Array:
		return .Array
	case .Object:
		return .Object
	}
	return .String
}

@(require_results)
make_array :: proc(h: ^Heap, cap: int) -> (res: Value, status: Status) {
	size := block_room(array_size(max(cap, 1)))
	b := alloc_block(h, size) or_return
	a := (^Array_Block)(b)
	a.next, a.len, a.cap = nil, 0, u32((size - size_of(Array_Block)) / size_of(Value))
	return {p = a, kind = .Array, held = true}, .Ok
}

@(require_results)
make_object :: proc(h: ^Heap, cap: int) -> (res: Value, status: Status) {
	size := block_room(object_size(max(cap, 1)))
	b := alloc_block(h, size) or_return
	o := (^Object_Block)(b)
	o.next_or_slots, o.len, o.cap = nil, 0, u32((size - size_of(Object_Block)) / size_of(Entry))
	return {p = o, kind = .Object, held = true}, .Ok
}

// Makes the built array `a^` one the caller alone holds, with room for `more` elements past its length.
@(require_results)
own_array :: proc(h: ^Heap, a: ^Value, more: int) -> Status {
	old := (^Array_Block)(a.p)
	n := int(old.len)
	if unique(a^) && n + more <= int(old.cap) {
		return .Ok
	}
	cap := n + more
	if unique(a^) {
		cap = max(cap, 2 * n)
		if old.class == DIRECT {
			// The allocator may grow a large block where it is, with no copy.
			b := resize_direct(h, old, array_size(int(old.cap)), array_size(cap)) or_return
			x := (^Array_Block)(b)
			x.cap = u32(cap)
			a.p = x
			return .Ok
		}
	}
	w := make_array(h, cap) or_return
	x := (^Array_Block)(w.p)
	items := array_items(old)
	runtime.mem_copy_non_overlapping(rawptr(uintptr(x) + size_of(Array_Block)), raw_data(items), n * size_of(Value))
	x.len = u32(n)
	x.flags = old.flags
	if unique(a^) {
		// The elements move: the old block is freed without giving them up.
		free_block(h, block_of(a^), array_size(int(old.cap)))
	} else {
		for v in items {
			_ = retain(v)
		}
		release(h, a^)
	}
	a^ = w
	return .Ok
}

// Appends `x`, which moves into the array, to the built array `a^` the caller owns.
@(require_results)
append_owned :: proc(h: ^Heap, a: ^Value, x: Value) -> Status #no_bounds_check {
	b := (^Array_Block)(a.p)
	if !(unique(a^) && b.len < b.cap) {
		if s := own_array(h, a, 1); s != .Ok {
			release(h, x)
			return s
		}
		b = (^Array_Block)(a.p)
	}
	([^]Value)(uintptr(b) + size_of(Array_Block))[b.len] = x
	b.len += 1
	if x.held {
		b.flags |= BLOCK_HAS_HELD
	}
	if x.kind >= .Array {
		b.flags |= BLOCK_HAS_CONTAINER
		if b.flags & BLOCK_HAS_PARTIAL == 0 && value_has_partial(x) {
			b.flags |= BLOCK_HAS_PARTIAL
		}
	}
	return .Ok
}

// Sets element `i` of the built array `a^` the caller owns to `x`, which moves in, filling with nulls past its end.
@(require_results)
array_put :: proc(h: ^Heap, a: ^Value, i: int, x: Value) -> Status #no_bounds_check {
	n := int((^Array_Block)(a.p).len)
	if s := own_array(h, a, max(i + 1 - n, 0)); s != .Ok {
		release(h, x)
		return s
	}
	b := (^Array_Block)(a.p)
	items := ([^]Value)(uintptr(b) + size_of(Array_Block))
	for k in n ..< i {
		items[k] = NULL
	}
	if i < n {
		release(h, items[i])
	}
	items[i] = x
	b.len = u32(max(n, i + 1))
	if x.held {
		b.flags |= BLOCK_HAS_HELD
	}
	if x.kind >= .Array {
		b.flags |= BLOCK_HAS_CONTAINER
		if b.flags & BLOCK_HAS_PARTIAL == 0 && value_has_partial(x) {
			b.flags |= BLOCK_HAS_PARTIAL
		}
	}
	return .Ok
}

// The number of elements of an array or members of an object, built or a document's, whose distinct keys it counts.
length_of :: proc(h: ^Heap, v: Value) -> int {
	#partial switch v.kind {
	case .Array:
		return int((^Array_Block)(v.p).len)
	case .Object:
		return int((^Object_Block)(v.p).len)
	case .Node:
		d := (^Doc_Block)(v.p)
		n, p, _ := tape.length(reader(d), tape.Node_Index(v.n), h.allocator)
		note_presence(h, p)
		return n
	}
	return 0
}

@(private)
reader :: #force_inline proc "contextless" (d: ^Doc_Block) -> tape.Reader {
	return {doc = &d.doc, index = &d.index}
}

// A read reached a value a partial document did not keep. Part of the guard to come: noted, read as absent.
@(private)
note_presence :: #force_inline proc "contextless" (h: ^Heap, p: tape.Presence) {
	if p == .Not_Loaded {
		h.tainted = true
	}
}

// Whether node `at` of partial document `doc` or any descendant in its subtree is marked `CONTAINER_PARTIAL`.
@(private)
node_has_partial :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> bool #no_bounds_check {
	if doc.partial == nil || int(at) >= len(doc.nodes) {
		return false
	}
	t := doc.nodes[at]
	if t.kind < .Array {
		return false
	}
	if t.spelling & tape.CONTAINER_PARTIAL != 0 {
		return true
	}
	end := min(at + tape.Node_Index(t.n), tape.Node_Index(len(doc.nodes)))
	for i := at + 1; i < end; i += 1 {
		n := doc.nodes[i]
		if n.kind >= .Array && n.spelling & tape.CONTAINER_PARTIAL != 0 {
			return true
		}
	}
	return false
}

// Whether `v` is or contains a partial document container (an unloaded subtree that must not be emitted whole).
// O(1) on scalars, whole-doc nodes, and built containers (tracked via `BLOCK_HAS_PARTIAL`, no DAG walk).
value_has_partial :: #force_inline proc "contextless" (v: Value) -> bool {
	if v.kind < .Array {
		return false
	}
	if v.kind == .Node {
		d := (^Doc_Block)(v.p)
		return node_has_partial(&d.doc, tape.Node_Index(v.n))
	}
	if b := block_of(v); b != nil {
		return b.flags & BLOCK_HAS_PARTIAL != 0
	}
	return false
}

// Whether nodes of `d` may carry facts or belong to a partial document (so scalars keep their document origin).
@(private)
doc_keeps_origin :: #force_inline proc "contextless" (d: ^Doc_Block) -> bool {
	return d.doc.present != {} || d.doc.partial != nil || (d.doc.format != nil && (d.doc.format.attribute != nil || d.doc.format.fact_name != nil))
}

// The value of node `at` of document block `d`: null and booleans as themselves (or as `.Node` when `doc_keeps_origin`),
// a string with an escape decoded into a string of the heap (carrying `(d, at)` when `doc_keeps_origin`), anything else
// the node, holding the block.
@(private, require_results)
node_value :: proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index, force_origin := false) -> (res: Value, status: Status) #no_bounds_check {
	t := d.doc.nodes[at]
	#partial switch t.kind {
	case .Number, .Array, .Object:
		d.rc += 1
		return {p = d, n = u32(at), kind = .Node, held = true}, .Ok
	case .String, .Plain:
		if intrinsics.expect(t.role != .Key && t.spelling & tape.SPELLING_DECODE == 0, true) {
			d.rc += 1
			return {p = d, n = u32(at), kind = .Node, held = true}, .Ok
		}
		return decoded_text(h, d, at, t.role != .Key && (force_origin || h.keep_origins || doc_keeps_origin(d)))
	case .Bytes:
		return decoded_text(h, d, at, t.role != .Key && (force_origin || h.keep_origins || doc_keeps_origin(d)))
	case .Null:
		if !(force_origin || h.keep_origins || doc_keeps_origin(d)) {
			return NULL, .Ok
		}
	case .False:
		if !(force_origin || h.keep_origins || doc_keeps_origin(d)) {
			return FALSE, .Ok
		}
	case .True:
		if !(force_origin || h.keep_origins || doc_keeps_origin(d)) {
			return TRUE, .Ok
		}
	}
	d.rc += 1
	return {p = d, n = u32(at), kind = .Node, held = true}, .Ok
}

// The value of node `at` inside the document of `d`, retaining `d` when a node value is returned.
@(require_results)
node_at :: proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index) -> (res: Value, status: Status) {
	return node_value(h, d, at)
}

// The text of a document token decoded into a string of the heap, optionally retaining `(d, origin)` for facts.
@(private)
token_text_value :: proc(h: ^Heap, d: ^Doc_Block, t: tape.Token, attach_doc := false, origin := tape.NO_NODE) -> (res: Value, status: Status) {
	room := tape.text_room(&d.doc, t)
	if room == 0 {
		raw := string(tape.span_bytes(&d.doc, t.lo, t.n))
		if !attach_doc {
			return text_value(h, raw)
		}
		v, p := make_doc_text(h, d, origin, len(raw)) or_return
		runtime.mem_copy_non_overlapping(p, raw_data(raw), len(raw))
		return v, .Ok
	}
	v: Value
	p: [^]u8
	if attach_doc {
		v, p = make_doc_text(h, d, origin, room) or_return
	} else {
		v, p = make_text(h, room) or_return
	}
	s, ok := tape.node_text(&d.doc, t, p[:room])
	if !ok {
		release(h, v)
		return NULL, fail(h, .Parse, .To_Text)
	}
	// The decode may be its bytes in the text, which `buf` did not take.
	if raw_data(s) != p {
		release(h, v)
		if !attach_doc {
			return text_value(h, s)
		}
		w, wp := make_doc_text(h, d, origin, len(s)) or_return
		runtime.mem_copy_non_overlapping(wp, raw_data(s), len(s))
		return w, .Ok
	}
	v.n = u32(len(s))
	return v, .Ok
}

// The text of a key or a string node that holds an escape, decoded into a string of the heap.
@(private, cold)
decoded_text :: #force_no_inline proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index, attach_doc := false) -> (res: Value, status: Status) #no_bounds_check {
	t := d.doc.nodes[at]
	if t.role == .Key && (t.kind == .String || t.kind == .Plain) && !tape.text_decodes(t) {
		d.rc += 1
		return {p = d, n = u32(at), kind = .Node, held = true}, .Ok
	}
	return token_text_value(h, d, t, attach_doc, at)
}

// The key of the built object entry or the document member whose key node is `at`, as a string value.
@(require_results)
key_value :: proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index) -> (res: Value, status: Status) {
	return decoded_text(h, d, at)
}

// Element `i` of an array, from the end when negative, `.Absent` past either end.
@(require_results)
element :: proc(h: ^Heap, v: Value, i: int) -> (res: Value, status: Status) #no_bounds_check {
	if v.kind == .Array {
		items := items_of(v)
		k := i if i >= 0 else len(items) + i
		if k < 0 || k >= len(items) {
			return ABSENT, .Ok
		}
		return retain(items[k]), .Ok
	}
	d := (^Doc_Block)(v.p)
	at, p := tape.element(reader(d), tape.Node_Index(v.n), i)
	if p != .Found {
		note_presence(h, p)
		return ABSENT, .Ok
	}
	return node_value(h, d, at)
}

// The value of member `key` of an object, `.Absent` when it has none.
@(require_results)
member :: proc(h: ^Heap, v: Value, key: string) -> (res: Value, status: Status) #no_bounds_check {
	if v.kind == .Object {
		o := (^Object_Block)(v.p)
		k := find_key(o, key)
		if k < 0 {
			return ABSENT, .Ok
		}
		return retain(object_entries(o)[k].value), .Ok
	}
	d := (^Doc_Block)(v.p)
	if intrinsics.expect(groups_names(d, v.n), false) {
		return group_member(h, d, tape.Node_Index(v.n), key)
	}
	at, p := tape.member(reader(d), tape.Node_Index(v.n), key)
	if p != .Found {
		note_presence(h, p)
		return ABSENT, .Ok
	}
	t := d.doc.nodes[at]
	if t.kind == .Number || t.kind >= .Array || (u8(t.kind) - u8(tape.Kind.String) <= 1 && t.role != .Key && t.spelling & tape.SPELLING_DECODE == 0) {
		d.rc += 1
		return {p = d, n = u32(at), kind = .Node, held = true}, .Ok
	}
	return node_value(h, d, at)
}

// Whether document object `d`'s node `at` reads its repeated names as one member holding an array, as markup does.
@(private)
groups_names :: #force_inline proc "contextless" (d: ^Doc_Block, at: u32) -> bool #no_bounds_check {
	return d.doc.format.dups == .Group && d.doc.nodes[at].kind == .Object
}

// Member `key` of the markup element at `at` of `d`: its one child as itself, several as an array of them in document
// order, `.Absent` for none.
@(private, cold)
group_member :: #force_no_inline proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index, key: string) -> (res: Value, status: Status) {
	c, p := tape.named(reader(d), at, key)
	if p != .Found {
		note_presence(h, p)
		return ABSENT, .Ok
	}
	out := ABSENT
	for {
		_, node, q := tape.next_child(reader(d), &c, .Group)
		if q != .Found {
			note_presence(h, q)
			return out, .Ok
		}
		x, s := node_value(h, d, node)
		if s != .Ok {
			release(h, out)
			return ABSENT, s
		}
		if out.kind == .Absent {
			out = x
			continue
		}
		if out.kind != .Array {
			first := out
			out, s = make_array(h, 2)
			if s != .Ok {
				release(h, first)
				release(h, x)
				return ABSENT, s
			}
			s = append_owned(h, &out, first)
			if s != .Ok {
				release(h, out)
				release(h, x)
				return ABSENT, s
			}
		}
		if s = append_owned(h, &out, x); s != .Ok {
			release(h, out)
			return ABSENT, s
		}
	}
}

// Whether an object has member `key`.
has_member :: proc(h: ^Heap, v: Value, key: string) -> bool {
	if v.kind == .Object {
		return find_key((^Object_Block)(v.p), key) >= 0
	}
	d := (^Doc_Block)(v.p)
	_, p := tape.member(reader(d), tape.Node_Index(v.n), key)
	note_presence(h, p)
	return p == .Found
}

// Fast word-at-a-time hash for built `Object_Block.slots` tables (private to this file).
@(private = "file")
object_key_hash :: #force_inline proc "contextless" (s: string) -> u32 #no_bounds_check {
	n := len(s)
	p := raw_data(s)
	if intrinsics.expect(n <= 8, true) {
		w: u64
		switch {
		case n >= 4:
			w = u64(intrinsics.unaligned_load((^u32)(p))) | u64(intrinsics.unaligned_load((^u32)(p[n - 4:]))) << 32
		case n >= 2:
			w = u64(intrinsics.unaligned_load((^u16)(p))) | u64(p[n - 1]) << 16
		case n == 1:
			w = u64(p[0])
		}
		h := (u64(0x9E3779B97F4A7C15) ~ w ~ u64(n) << 56) * 0x9E3779B97F4A7C15
		h ~= h >> 32
		return u32((h * 0x9E3779B97F4A7C15) >> 32)
	}
	return tape.text_hash(transmute([]u8)s)
}

@(private = "file", cold)
entry_node_text :: #force_no_inline proc "contextless" (v: Value) -> string {
	return string(node_bytes(v))
}

@(private = "file")
entry_key_text :: #force_inline proc "contextless" (v: Value) -> string #no_bounds_check {
	if intrinsics.expect(v.kind == .String, true) {
		return string(v.s[:v.n])
	}
	return entry_node_text(v)
}

// Fast equality of built object entry key `v` against `ks`.
@(private = "file")
entry_key_eq :: #force_inline proc "contextless" (v: Value, ks: string) -> bool #no_bounds_check {
	s := entry_key_text(v)
	n := len(ks)
	if len(s) != n {
		return false
	}
	a, b := raw_data(s), raw_data(ks)
	if a == b {
		return true
	}
	switch {
	case n > 16:
		return s == ks
	case n >= 8:
		return intrinsics.unaligned_load((^u64)(a)) == intrinsics.unaligned_load((^u64)(b)) &&
			intrinsics.unaligned_load((^u64)(a[n - 8:])) == intrinsics.unaligned_load((^u64)(b[n - 8:]))
	case n >= 4:
		return intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b)) &&
			intrinsics.unaligned_load((^u32)(a[n - 4:])) == intrinsics.unaligned_load((^u32)(b[n - 4:]))
	case n >= 2:
		return intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b)) && a[n - 1] == b[n - 1]
	}
	return n == 0 || a[0] == b[0]
}

// The index of the entry of `o` with key `key`, -1 for none.
@(private)
find_key :: proc "contextless" (o: ^Object_Block, key: string) -> int #no_bounds_check {
	entries := object_entries(o)
	slots := object_slots(o)
	if slots == nil {
		for e, i in entries {
			if entry_key_eq(e.key, key) {
				return i
			}
		}
		return -1
	}
	mask := object_slot_count(o) - 1
	for at := object_key_hash(key) & mask; ; at = (at + 1) & mask {
		k := slots[at]
		if k == 0 {
			return -1
		}
		if entry_key_eq(entries[k - 1].key, key) {
			return int(k - 1)
		}
	}
}

// Rebuilds the key table of `o`, which has more than `SMALL_ENTRIES` entries, or drops it.
@(private)
index_keys :: proc(h: ^Heap, o: ^Object_Block) -> Status #no_bounds_check {
	free_object_slots(h, o)
	if o.len <= SMALL_ENTRIES {
		return .Ok
	}
	log2 := u8(4)
	for (u32(1) << log2) < 2 * o.cap {
		log2 += 1
	}
	count := u32(1) << log2
	if h.limit != 0 && h.used + u64(count) * size_of(u32) > h.limit {
		return fail_memory(h)
	}
	mem, err := runtime.mem_alloc(int(count) * size_of(u32), align_of(u32), h.allocator)
	if err != nil {
		return fail_memory(h)
	}
	h.used += u64(count) * size_of(u32)
	o.next_or_slots = raw_data(mem)
	o.slot_log2 = log2
	slots := ([^]u32)(o.next_or_slots)
	mask := count - 1
	for e, i in object_entries(o) {
		at := object_key_hash(entry_key_text(e.key)) & mask
		for slots[at] != 0 {
			at = (at + 1) & mask
		}
		slots[at] = u32(i) + 1
	}
	return .Ok
}

@(private)
slot_put :: #force_inline proc "contextless" (o: ^Object_Block, key: string, i: u32) #no_bounds_check {
	slots := ([^]u32)(o.next_or_slots)
	mask := (u32(1) << o.slot_log2) - 1
	at := object_key_hash(key) & mask
	for slots[at] != 0 {
		at = (at + 1) & mask
	}
	slots[at] = i + 1
}

// Makes the built object `o^` one the caller alone holds, with room for `more` entries past its length.
@(private, require_results)
own_object :: proc(h: ^Heap, o: ^Value, more: int) -> Status {
	old := (^Object_Block)(o.p)
	n := int(old.len)
	if unique(o^) && n + more <= int(old.cap) {
		return .Ok
	}
	cap := n + more
	if unique(o^) {
		cap = max(cap, 2 * n)
		if old.class == DIRECT {
			b := resize_direct(h, old, object_size(int(old.cap)), object_size(cap)) or_return
			x := (^Object_Block)(b)
			x.cap = u32(cap)
			o.p = x
			return index_keys(h, x)
		}
	}
	w := make_object(h, cap) or_return
	x := (^Object_Block)(w.p)
	entries := object_entries(old)
	runtime.mem_copy_non_overlapping(rawptr(uintptr(x) + size_of(Object_Block)), raw_data(entries), n * size_of(Entry))
	x.len = u32(n)
	x.flags = old.flags
	if unique(o^) {
		free_object_slots(h, old)
		free_block(h, block_of(o^), object_size(int(old.cap)))
	} else {
		for e in entries {
			_, _ = retain(e.key), retain(e.value)
		}
		release(h, o^)
	}
	o^ = w
	if s := index_keys(h, x); s != .Ok {
		return s
	}
	return .Ok
}

// Sets member `key`, a string, of the built object `o^` the caller owns to `x`. Both move into the object. A member
// already there keeps its place.
@(require_results)
object_put :: proc(h: ^Heap, o: ^Value, key: Value, x: Value) -> Status #no_bounds_check {
	b := (^Object_Block)(o.p)
	ks := entry_key_text(key)
	k := -1
	empty_slot := u32(0)
	has_slot := false
	key_hash := u32(0)
	if slots := object_slots(b); slots != nil {
		entries := object_entries(b)
		mask := (u32(1) << b.slot_log2) - 1
		key_hash = object_key_hash(ks)
		for at := key_hash & mask; ; at = (at + 1) & mask {
			slot := slots[at]
			if slot == 0 {
				empty_slot = at
				has_slot = true
				break
			}
			if entry_key_eq(entries[slot - 1].key, ks) {
				k = int(slot - 1)
				break
			}
		}
	} else {
		for e, i in object_entries(b) {
			if entry_key_eq(e.key, ks) {
				k = i
				break
			}
		}
	}
	if k >= 0 {
		if s := own_object(h, o, 0); s != .Ok {
			release(h, key)
			release(h, x)
			return s
		}
		b = (^Object_Block)(o.p)
		e := &object_entries(b)[k]
		release(h, e.value)
		release(h, key)
		e.value = x
		if x.held {
			b.flags |= BLOCK_HAS_HELD
		}
		if x.kind >= .Array {
			b.flags |= BLOCK_HAS_CONTAINER
			if b.flags & BLOCK_HAS_PARTIAL == 0 && value_has_partial(x) {
				b.flags |= BLOCK_HAS_PARTIAL
			}
		}
		return .Ok
	}
	grew := false
	if intrinsics.expect(!(unique(o^) && b.len < b.cap), false) {
		if s := own_object(h, o, 1); s != .Ok {
			release(h, key)
			release(h, x)
			return s
		}
		b = (^Object_Block)(o.p)
		grew = true
	}
	([^]Entry)(uintptr(b) + size_of(Object_Block))[b.len] = {key, x}
	b.len += 1
	if key.held || x.held {
		b.flags |= BLOCK_HAS_HELD
	}
	if x.kind >= .Array {
		b.flags |= BLOCK_HAS_CONTAINER
		if b.flags & BLOCK_HAS_PARTIAL == 0 && value_has_partial(x) {
			b.flags |= BLOCK_HAS_PARTIAL
		}
	}
	if b.slot_log2 != 0 {
		if has_slot && !grew {
			([^]u32)(b.next_or_slots)[empty_slot] = b.len
		} else {
			slots := ([^]u32)(b.next_or_slots)
			mask := (u32(1) << b.slot_log2) - 1
			at := (key_hash if has_slot else object_key_hash(ks)) & mask
			for slots[at] != 0 {
				at = (at + 1) & mask
			}
			slots[at] = b.len
		}
	} else if b.len > SMALL_ENTRIES {
		return index_keys(h, b)
	}
	return .Ok
}

// Appends member `{key, x}` to the built object `o^` the caller owns when `key` is guaranteed not already present.
@(require_results)
object_put_fresh :: proc(h: ^Heap, o: ^Value, key: Value, x: Value) -> Status #no_bounds_check {
	b := (^Object_Block)(o.p)
	if !(unique(o^) && b.len < b.cap) {
		if s := own_object(h, o, 1); s != .Ok {
			release(h, key)
			release(h, x)
			return s
		}
		b = (^Object_Block)(o.p)
	}
	([^]Entry)(uintptr(b) + size_of(Object_Block))[b.len] = {key, x}
	b.len += 1
	if key.held || x.held {
		b.flags |= BLOCK_HAS_HELD
	}
	if x.kind >= .Array {
		b.flags |= BLOCK_HAS_CONTAINER
		if b.flags & BLOCK_HAS_PARTIAL == 0 && value_has_partial(x) {
			b.flags |= BLOCK_HAS_PARTIAL
		}
	}
	if b.slot_log2 != 0 {
		slot_put(b, entry_key_text(key), b.len - 1)
	} else if b.len > SMALL_ENTRIES {
		return index_keys(h, b)
	}
	return .Ok
}

// Removes member `key` of the built object `o^` the caller owns, when it has one.
@(require_results)
object_delete :: proc(h: ^Heap, o: ^Value, key: string) -> Status {
	if find_key((^Object_Block)(o.p), key) < 0 {
		return .Ok
	}
	own_object(h, o, 0) or_return
	b := (^Object_Block)(o.p)
	k := find_key(b, key)
	entries := ([^]Entry)(uintptr(b) + size_of(Object_Block))
	release(h, entries[k].key)
	release(h, entries[k].value)
	copy(entries[k:b.len - 1], entries[k + 1:b.len])
	b.len -= 1
	return index_keys(h, b)
}

// Removes all members named by `keys` (string values) from the built object `o^` in one pass and rebuilds its index once.
@(require_results)
object_delete_many :: proc(h: ^Heap, o: ^Value, keys: []Value) -> Status {
	if len(keys) == 0 {
		return .Ok
	}
	if len(keys) == 1 {
		return object_delete(h, o, text_of(keys[0]))
	}
	b := (^Object_Block)(o.p)
	n := int(b.len)
	if n == 0 {
		return .Ok
	}
	alloc := heap_allocator(h)
	gone := make([]bool, n, alloc)
	if gone == nil {
		return fail_memory(h)
	}
	defer delete(gone, alloc)
	removed := 0
	for k in keys {
		idx := find_key(b, text_of(k))
		if idx >= 0 && !gone[idx] {
			gone[idx] = true
			removed += 1
		}
	}
	if removed == 0 {
		return .Ok
	}
	own_object(h, o, 0) or_return
	b = (^Object_Block)(o.p)
	entries := ([^]Entry)(uintptr(b) + size_of(Object_Block))
	w := 0
	for i in 0 ..< n {
		if gone[i] {
			release(h, entries[i].key)
			release(h, entries[i].value)
		} else {
			if w != i {
				entries[w] = entries[i]
			}
			w += 1
		}
	}
	b.len = u32(w)
	return index_keys(h, b)
}

// A walk over the children of an array or object, built or a document's. Its container is borrowed: the caller keeps
// it until `cursor_close`.
Cursor :: struct {
	of:       Value, // under `h`, the grouped copy of a markup element, which the cursor owns
	at:       u32, // a built container's next child
	h:        ^Heap, // set when the cursor owns `of`
	children: tape.Children,
}

@(require_results)
cursor_open :: proc(h: ^Heap, v: Value) -> (c: Cursor, s: Status) {
	c.of = v
	if v.kind != .Node {
		return c, .Ok
	}
	d := (^Doc_Block)(v.p)
	if groups_names(d, v.n) {
		c.of = grouped(h, v) or_return
		c.h = h
		return c, .Ok
	}
	p: tape.Presence
	err: runtime.Allocator_Error
	c.children, p, err = tape.children(reader(d), tape.Node_Index(v.n), h.allocator)
	if err != nil {
		return c, fail_memory(h)
	}
	note_presence(h, p)
	if p != .Found {
		c.of = ABSENT
	}
	return c, .Ok
}

// The next child: an object's key as a string and its value, an array's element with `.Absent` for its key. False
// once none is left. Both are the caller's.
@(require_results)
cursor_next :: proc(h: ^Heap, c: ^Cursor) -> (key, value: Value, more: bool, s: Status) #no_bounds_check {
	#partial switch c.of.kind {
	case .Absent:
		return ABSENT, ABSENT, false, .Ok
	case .Array:
		items := items_of(c.of)
		if int(c.at) >= len(items) {
			return ABSENT, ABSENT, false, .Ok
		}
		c.at += 1
		return ABSENT, retain(items[c.at - 1]), true, .Ok
	case .Object:
		entries := entries_of(c.of)
		if int(c.at) >= len(entries) {
			return ABSENT, ABSENT, false, .Ok
		}
		c.at += 1
		e := entries[c.at - 1]
		return retain(e.key), retain(e.value), true, .Ok
	}
	d := (^Doc_Block)(c.of.p)
	nodes := raw_data(d.doc.nodes)
	cont := nodes[c.children.container]
	if cont.kind == .Array && cont.spelling & tape.CONTAINER_PARTIAL == 0 {
		end := c.children.container + tape.Node_Index(cont.n)
		at := c.children.next
		if at >= end {
			return ABSENT, ABSENT, false, .Ok
		}
		intrinsics.prefetch_read_data(&nodes[at + 64], 3)
		elem := nodes[at]
		c.children.next = at + (tape.Node_Index(elem.n) if elem.kind > .Plain else 1)
		c.children.place += 1
		if elem.kind == .Number || elem.kind >= .Array || (u8(elem.kind) - u8(tape.Kind.String) <= 1 && elem.role != .Key && elem.spelling & tape.SPELLING_DECODE == 0) {
			d.rc += 1
			return ABSENT, {p = d, n = u32(at), kind = .Node, held = true}, true, .Ok
		}
		return cursor_next_array_slow(h, d, at)
	}
	return cursor_next_node_slow(h, d, &c.children)
}

@(private = "file", cold, require_results)
cursor_next_array_slow :: #force_no_inline proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index) -> (key, value: Value, more: bool, s: Status) {
	value, s = node_value(h, d, at)
	if s != .Ok {
		return ABSENT, ABSENT, false, s
	}
	return ABSENT, value, true, .Ok
}

@(private = "file", cold, require_results)
cursor_next_node_slow :: #force_no_inline proc(h: ^Heap, d: ^Doc_Block, ch: ^tape.Children) -> (key, value: Value, more: bool, s: Status) #no_bounds_check {
	k, at, p := tape.next_child(reader(d), ch)
	if p != .Found {
		note_presence(h, p)
		return ABSENT, ABSENT, false, .Ok
	}
	if k != tape.NO_NODE {
		key = key_value(h, d, k) or_return
	} else if ch.keys_n != 0 {
		key = token_text_value(h, d, tape.cell_key(reader(d), ch^)) or_return
	}
	value, s = node_value(h, d, at)
	if s != .Ok {
		release(h, key)
		return ABSENT, ABSENT, false, s
	}
	return key, value, true, .Ok
}

cursor_close :: proc(c: ^Cursor) {
	if c.h != nil {
		release(c.h, c.of)
	} else if c.of.kind == .Node {
		tape.destroy_children(&c.children)
	}
	c^ = {}
}

// A built object of the markup element `v`'s children, a repeated name one member that holds an array of its children
// in document order, at the place its first came. Each child is still its node. Only this reads a built array among
// the children, so an array among them is a group.
@(private, require_results)
grouped :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	d := (^Doc_Block)(v.p)
	out := make_object(h, length_of(h, v)) or_return
	defer if status != .Ok {
		release(h, out)
	}
	c, p, err := tape.children(reader(d), tape.Node_Index(v.n), h.allocator)
	if err != nil {
		return NULL, fail_memory(h)
	}
	defer tape.destroy_children(&c)
	note_presence(h, p)
	if p != .Found {
		return out, .Ok
	}
	for {
		k, at, q := tape.next_child(reader(d), &c, .Group)
		if q != .Found {
			note_presence(h, q)
			return out, .Ok
		}
		key := key_value(h, d, k) or_return
		x, s := node_value(h, d, at)
		if s != .Ok {
			release(h, key)
			return NULL, s
		}
		i := find_key((^Object_Block)(out.p), text_of(key))
		if i < 0 {
			if s = object_put_fresh(h, &out, key, x); s != .Ok {
				return NULL, s
			}
			continue
		}
		release(h, key)
		ob := (^Object_Block)(out.p)
		entry := &object_entries(ob)[i]
		if entry.value.kind != .Array {
			first := entry.value
			entry.value, s = make_array(h, 2)
			if s != .Ok {
				entry.value = first
				release(h, x)
				return NULL, s
			}
			ob.flags |= BLOCK_HAS_HELD | BLOCK_HAS_CONTAINER
			if s = append_owned(h, &entry.value, first); s != .Ok {
				entry.value = NULL
				release(h, x)
				return NULL, s
			}
		}
		if s = append_owned(h, &entry.value, x); s != .Ok {
			return NULL, s
		}
	}
}

// A built copy of document container `v`'s children, one level: an array of its elements or an object of its members,
// each child still its node.
@(require_results)
built :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if v.kind != .Node {
		return retain(v), .Ok
	}
	if groups_names((^Doc_Block)(v.p), v.n) {
		return grouped(h, v)
	}
	n := length_of(h, v)
	array := node_token(v).kind == .Array
	out: Value
	if array {
		out = make_array(h, n) or_return
	} else {
		out = make_object(h, n) or_return
	}
	c := cursor_open(h, v) or_return
	defer cursor_close(&c)
	for {
		k, x, more, s := cursor_next(h, &c)
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
		if !more {
			return out, .Ok
		}
		if array {
			s = append_owned(h, &out, x)
		} else {
			s = object_put(h, &out, k, x)
		}
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
	}
}


// A copy of `v` that reads no document: every container built, every number and string a value of its own. It is what
// a constant needs that outlives the document it was read from. No recursion.
@(require_results)
built_deep :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	Frame :: struct {
		from: Value, // the container being copied, held
		c:    Cursor,
		out:  Value, // its copy, owned
		key:  Value, // its key in the container above, owned, `.Absent` for an element or the outermost
	}
	open :: proc(h: ^Heap, from, key: Value) -> (f: Frame, s: Status) {
		f.from, f.key = from, key
		n := length_of(h, from)
		if type_of(from) == .Array {
			f.out, s = make_array(h, n)
		} else {
			f.out, s = make_object(h, n)
		}
		if s == .Ok {
			f.c, s = cursor_open(h, from)
		}
		return
	}
	scalar :: proc(h: ^Heap, x: Value) -> (Value, Status) {
		if x.kind == .Node {
			#partial switch type_of(x) {
			case .Null:
				return NULL, .Ok
			case .False:
				return FALSE, .Ok
			case .True:
				return TRUE, .Ok
			}
		}
		if is_text(x) {
			return text_value(h, text_of(x))
		}
		if x.kind == .Big {
			return big_clone(h, x)
		}
		if is_number(x) {
			return number_of(h, x)
		}
		return retain(x), .Ok
	}
	if t := type_of(v); t != .Array && t != .Object {
		return scalar(h, v)
	}
	frames, ferr := make([dynamic]Frame, 0, 8, h.allocator)
	if ferr != nil {
		return NULL, fail_memory(h)
	}
	defer delete(frames)
	defer for &f in frames {
		cursor_close(&f.c)
		release(h, f.out)
		release(h, f.key)
		release(h, f.from)
	}
	top, opened := open(h, retain(v), ABSENT)
	if _, aerr := append(&frames, top); aerr != nil {
		cursor_close(&top.c)
		release(h, top.out)
		release(h, top.key)
		release(h, top.from)
		return NULL, fail_memory(h)
	}
	if opened != .Ok {
		return NULL, opened
	}
	for {
		f := &frames[len(frames) - 1]
		k, x, more, next := cursor_next(h, &f.c)
		if next != .Ok {
			return NULL, next
		}
		if !more {
			done := pop(&frames)
			cursor_close(&done.c)
			release(h, done.from)
			if len(frames) == 0 {
				return done.out, .Ok
			}
			parent := &frames[len(frames) - 1]
			put: Status
			if type_of(parent.from) == .Array {
				put = append_owned(h, &parent.out, done.out)
			} else {
				put = object_put(h, &parent.out, done.key, done.out)
			}
			if put != .Ok {
				return NULL, put
			}
			continue
		}
		if type_of(f.from) == .Object {
			ck, ks := text_value(h, text_of(k))
			release(h, k)
			if ks != .Ok {
				release(h, x)
				return NULL, ks
			}
			k = ck
		}
		if t := type_of(x); t == .Array || t == .Object {
			if len(frames) >= depth_limit(h) {
				release(h, k)
				release(h, x)
				return NULL, fail(h, .Depth, .None)
			}
			child, made := open(h, x, k)
			if _, aerr := append(&frames, child); aerr != nil {
				cursor_close(&child.c)
				release(h, child.out)
				release(h, child.key)
				release(h, child.from)
				return NULL, fail_memory(h)
			}
			if made != .Ok {
				return NULL, made
			}
			continue
		}
		y, copied := scalar(h, x)
		release(h, x)
		if copied != .Ok {
			release(h, k)
			return NULL, copied
		}
		put: Status
		if type_of(f.from) == .Array {
			put = append_owned(h, &f.out, y)
		} else {
			put = object_put(h, &f.out, k, y)
		}
		if put != .Ok {
			return NULL, put
		}
	}
}
