package tape

import "base:intrinsics"
import "base:runtime"

// Lazy container index (`Doc_Index`), key hashing and distinct-key deduplication.

// The tables the readers built over the whole containers of a document, each when a read first needed it: a wide
// array's elements by place, a wide object's distinct keys in text order with a hash table over them, and for each
// object the readers examined whether it repeats a key, so they take the others as written. A refused allocation
// leaves the readers walking, which answers the same. An index serves the readers of one document, from its first read
// to `destroy`, and is empty until a read needs a table, so a zero one with its allocator set starts it. With no
// allocator each table is refused, so a zero index reads as none.
Doc_Index :: struct {
	examined:  []u64, // a bit per node, set for a whole object whose keys were compared
	repeats:   []u64, // a bit per node, set for an examined object two of whose members share a key
	entries:   [dynamic]Index_Entry,
	table:     []u32, // one past an entry, by its node's hash, 0 for an empty slot, at most half full
	lines:     Line_Index, // lazy 4 KiB line-checkpoint table and cursor for `node_place`
	allocator: runtime.Allocator,
}

// A wide container's tables in a `Doc_Index`: an array's elements, or an object's distinct keys and their hash table,
// each its own allocation, so a `Children` holding them outlives later entries.
@(private)
Index_Entry :: struct {
	node:     Node_Index,
	elements: []Node_Index,
	kept:     []Kept_Child, // for a partial array, its kept direct children sorted by index
	members:  []Distinct_Member,
	room:     []Distinct_Member, // the whole block `members` is a prefix of
	slots:    []Key_Slot,
	// Two of an object's distinct keys of different kinds read as one text, which its table cannot take a member by a
	// name from, as the member of the name is the first or last of all the keys that read as it.
	clash:    bool,
}

// The fewest elements a read passes in an array before the index lists its elements.
@(private)
INDEX_ELEMENTS :: 16

// A key of an object at its first place, and the values of its first and last members.
@(private)
Distinct_Member :: struct {
	key, first, last: Node_Index,
}

// The most members of an object whose repeated keys the readers find by comparing each key with the others, with no
// table, and that the index lists no table of.
@(private)
SMALL_OBJECT :: 8

// The slots of a key table `key_table` keeps in a caller's room, for a wide object of up to half as many members.
@(private)
WIDE_ROOM :: 128

@(private)
Key_Slot :: struct {
	hash:  u32,
	entry: u32, // 0 for an empty slot
}

// Frees what the readers listed in `x` and leaves it zero. A members list is a prefix of its entry's `room`,
// freed whole.
destroy_index :: proc(x: ^Doc_Index) {
	for e in x.entries {
		delete(e.elements, x.allocator)
		delete(e.kept, x.allocator)
		delete(e.room, x.allocator)
		delete(e.slots, x.allocator)
	}
	delete(x.entries)
	delete(x.table, x.allocator)
	if x.examined != nil {
		delete(raw_data(x.examined)[:2 * len(x.examined)], x.allocator)
	}
	destroy_line_index(&x.lines)
	x^ = {}
}

// The distinct keys of the whole object at `at` of `count` members, wider than `SMALL_OBJECT`, in `allocator`, or nil
// for an object that holds each key once, whose keys are counted first so it lists none.
@(private)
wide_members :: proc(doc: ^Document, at: Node_Index, count: int, allocator: runtime.Allocator) -> (members: []Distinct_Member, room: []Distinct_Member, err: runtime.Allocator_Error) {
	table_room: [WIDE_ROOM]Key_Slot = ---
	slots := key_table(count, table_room[:], allocator) or_return
	defer if len(slots) > len(table_room) {
		delete(slots, allocator)
	}
	if n, _ := distinct_keys(doc, at, nil, slots); n == count {
		return nil, nil, nil
	}
	made, merr2 := alloc_slice(Distinct_Member, count, allocator)
	if merr2 != nil {
		return nil, nil, merr2
	}
	members = made
	intrinsics.mem_zero(raw_data(slots), len(slots) * size_of(Key_Slot))
	n, _ := distinct_keys(doc, at, members, slots)
	return members[:n], members, nil
}

// An empty key table for `count` keys, in `room` when it fits and else in `allocator`, which the caller frees. A
// nil allocator's empty table is a refusal, as a key probe cannot read one.
@(private)
key_table :: proc(count: int, room: []Key_Slot, allocator: runtime.Allocator) -> ([]Key_Slot, runtime.Allocator_Error) {
	size := table_size(count)
	if size == 0 {
		return nil, .Out_Of_Memory
	}
	if size > len(room) {
		return alloc_slice(Key_Slot, size, allocator)
	}
	intrinsics.mem_zero(raw_data(room), size * size_of(Key_Slot))
	return room[:size], nil
}

// Whether the index found the whole object at `at` holding each key once, without examining an object it did not.
@(private)
keys_known_once :: #force_inline proc "contextless" (r: Reader, at: Node_Index) -> bool #no_bounds_check {
	x := r.index
	return x != nil && x.examined != nil && x.examined[at / 64] & (1 << uint(at % 64)) != 0 && x.repeats[at / 64] & (1 << uint(at % 64)) == 0
}

// Whether the whole object at `at` holds each key once, which the index examines once and keeps. False with no index,
// and when the index cannot keep its verdict, which leaves the readers comparing keys.
@(private)
keys_once :: proc(r: Reader, at: Node_Index) -> bool #no_bounds_check {
	x := r.index
	node := r.doc.nodes[at]
	assert_contextless(node.kind == .Object && node.spelling & CONTAINER_PARTIAL == 0, "keys_once of a partial object or no object")
	if x == nil {
		return false
	}
	if x.examined != nil && x.examined[at / 64] & (1 << uint(at % 64)) != 0 {
		return x.repeats[at / 64] & (1 << uint(at % 64)) == 0
	}
	if count := child_count(r.doc, at, node); count > SMALL_OBJECT {
		e, ok := object_entry(r, at, count)
		return ok && len(e.members) == count
	}
	repeats := small_repeats(r.doc, at)
	return index_mark(r, at, repeats) && !repeats
}

// Whether two members of the whole object at `at`, of at most `SMALL_OBJECT` members, share a key or have keys of two
// kinds that read as one text.
@(private)
small_repeats :: proc "contextless" (doc: ^Document, at: Node_Index) -> bool #no_bounds_check {
	keys: [SMALL_OBJECT]Node_Index = ---
	// Each key's length, which two keys of one text share unless one of them is spelled with escapes.
	sizes: [SMALL_OBJECT]u64 = ---
	n := 0
	end := at + Node_Index(doc.nodes[at].n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		t := doc.nodes[k]
		size := u64(t.n) if t.spelling & SPELLING_DECODE == 0 else max(u64)
		for i in 0 ..< n {
			if (sizes[i] == size || sizes[i] == max(u64) || size == max(u64)) && doc_same_text(doc, doc.nodes[keys[i]], t) {
				return true
			}
		}
		keys[n], sizes[n] = k, size
		n += 1
	}
	return false
}

// The elements of the whole array at `at` of `count` elements, listed in the reader's index the first time, false when
// the index cannot hold them.
@(private)
array_entry :: proc(r: Reader, at, first: Node_Index, count: int) -> (e: Index_Entry, ok: bool) #no_bounds_check {
	x := r.index
	if e, ok = index_entry(x, at); ok {
		return
	}
	elements, err := alloc_slice(Node_Index, count, x.allocator)
	if err != nil {
		return {}, false
	}
	for k, j := first, 0; j < count; j += 1 {
		elements[j] = k
		k = node_after(r.doc, k)
	}
	e = {node = at, elements = elements}
	if !index_add(x, e) {
		delete(elements, x.allocator)
		return {}, false
	}
	return e, true
}

// The kept direct children of the partial array at `at`, listed in the reader's index the first time, false when the
// index cannot hold them.
@(private)
partial_array_entry :: proc(r: Reader, at: Node_Index, node: Node) -> (e: Index_Entry, ok: bool) #no_bounds_check {
	x := r.index
	if e, ok = index_entry(x, at); ok {
		return
	}
	doc := r.doc
	end := at + Node_Index(node.n)
	start := kept_from(doc.partial, at)
	// First pass counts direct children kept in `at` so the index allocates exact capacity.
	c := Children{container = at, next = at + 1, kept = start}
	n := 0
	for ; c.next < end; c.next = node_after(doc, c.next) {
		if _, has := kept_place(doc.partial, &c); has {
			n += 1
		}
	}
	kept: []Kept_Child
	if n > 0 {
		err: runtime.Allocator_Error
		kept, err = alloc_slice(Kept_Child, n, x.allocator)
		if err != nil {
			return {}, false
		}
		c = Children{container = at, next = at + 1, kept = start}
		j := 0
		for ; c.next < end; c.next = node_after(doc, c.next) {
			if place, has := kept_place(doc.partial, &c); has {
				kept[j] = {node = c.next, index = place}
				j += 1
			}
		}
	}
	e = {node = at, kept = kept}
	if !index_add(x, e) {
		delete(kept, x.allocator)
		return {}, false
	}
	return e, true
}

// The distinct keys of the whole object at `at` of `count` members and their table, listed in the reader's index the
// first time, false when the index cannot hold them.
@(private)
object_entry :: proc(r: Reader, at: Node_Index, count: int) -> (e: Index_Entry, ok: bool) #no_bounds_check {
	x := r.index
	if e, ok = index_entry(x, at); ok {
		return
	}
	slot_n := table_size(count)
	if slot_n == 0 {
		return {}, false
	}
	members, merr := alloc_slice(Distinct_Member, count, x.allocator)
	slots, serr := alloc_slice(Key_Slot, slot_n, x.allocator)
	if merr == nil && serr == nil {
		n, clash := distinct_keys(r.doc, at, members, slots)
		e = {node = at, members = members[:n], room = members, slots = slots, clash = clash}
		if index_mark(r, at, n < count || clash) && index_add(x, e) {
			return e, true
		}
	}
	delete(members, x.allocator)
	delete(slots, x.allocator)
	return {}, false
}

// The member `name` of the indexed object `e` under `dups`.
@(private)
index_member :: proc "contextless" (r: Reader, e: Index_Entry, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	slots, members := e.slots, e.members
	h := r.doc.format.key_hash(transmute([]u8)name, {n = u32(len(name)), kind = .String})
	mask := u32(len(slots) - 1)
	for i := h & mask; ; i = (i + 1) & mask {
		s := slots[i]
		if s.entry == 0 {
			return NO_NODE, .Missing
		}
		if s.hash == h {
			m := members[s.entry - 1]
			if doc_names(r.doc, r.doc.nodes[m.key], name) {
				return m.first if dups != .Last else m.last, .Found
			}
		}
	}
}

// The number of distinct keys of the whole object at `at`, found through the empty hash table `slots`, and with
// `members` each distinct key in text order with its first and last values, the slots' entries then one past a member.
// Keys are hashed and compared by the format's one relation, `Format.key_hash` with `same_keys`.
@(private)
distinct_keys :: proc "contextless" (doc: ^Document, at: Node_Index, members: []Distinct_Member, slots: []Key_Slot) -> (n: int, clash: bool) #no_bounds_check {
	mask := u32(len(slots) - 1)
	end := at + Node_Index(doc.nodes[at].n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		value := k + 1
		t := doc.nodes[k]
		h := doc_key_hash(doc, t)
		i := h & mask
		for {
			s := &slots[i]
			if s.entry == 0 {
				s.hash = h
				if members == nil {
					s.entry = u32(k) + 1
				} else {
					members[n] = {k, value, value}
					s.entry = u32(n) + 1
				}
				n += 1
				break
			}
			if s.hash == h {
				key := Node_Index(s.entry - 1) if members == nil else members[s.entry - 1].key
				if doc_same_keys(doc, doc.nodes[key], t) {
					if members != nil {
						members[s.entry - 1].last = value
					}
					break
				}
				// Two distinct keys of different kinds reading as the same text (e.g. YAML `1` and `"1"`).
				if doc.nodes[key].kind != t.kind && doc_same_text(doc, doc.nodes[key], t) {
					clash = true
				}
			}
			i = (i + 1) & mask
		}
	}
	return
}

// Keeps in the reader's index whether the whole object at `at` repeats a key, false when memory is refused.
@(private = "file")
index_mark :: proc(r: Reader, at: Node_Index, repeats: bool) -> bool #no_bounds_check {
	x := r.index
	if x.examined == nil {
		words := (len(r.doc.nodes) + 63) / 64
		bits, err := alloc_slice(u64, 2 * words, x.allocator)
		if err != nil {
			return false
		}
		x.examined, x.repeats = bits[:words], bits[words:]
	}
	x.examined[at / 64] |= 1 << uint(at % 64)
	if repeats {
		x.repeats[at / 64] |= 1 << uint(at % 64)
	}
	return true
}

// The entry of the container at `at` in `x`, false for one it lists no table of.
@(private = "file")
index_entry :: #force_inline proc "contextless" (x: ^Doc_Index, at: Node_Index) -> (Index_Entry, bool) #no_bounds_check {
	if len(x.table) == 0 {
		return {}, false
	}
	mask := u32(len(x.table) - 1)
	for h := node_hash(at) & mask; ; h = (h + 1) & mask {
		e := x.table[h]
		if e == 0 {
			return {}, false
		}
		if entry := x.entries[e - 1]; entry.node == at {
			return entry, true
		}
	}
}

// Adds `e` to `x`, false when memory is refused.
@(private = "file")
index_add :: proc(x: ^Doc_Index, e: Index_Entry) -> bool #no_bounds_check {
	if u64(len(x.entries)) + 1 > u64(max(u32)) {
		return false
	}
	if 2 * (u64(len(x.entries)) + 1) > u64(len(x.table)) {
		want := max(u64(16), 2 * u64(len(x.table)))
		if want > u64(max(int) / size_of(u32)) {
			return false
		}
		table, err := alloc_slice(u32, int(want), x.allocator)
		if err != nil {
			return false
		}
		mask := u32(len(table) - 1)
		for i in 0 ..< len(x.entries) {
			h := node_hash(x.entries[i].node) & mask
			for table[h] != 0 {
				h = (h + 1) & mask
			}
			table[h] = u32(i) + 1
		}
		delete(x.table, x.allocator)
		x.table = table
	}
	if x.entries.allocator.procedure == nil {
		x.entries.allocator = x.allocator
	}
	if _, err := append(&x.entries, e); err != nil {
		return false
	}
	mask := u32(len(x.table) - 1)
	h := node_hash(e.node) & mask
	for x.table[h] != 0 {
		h = (h + 1) & mask
	}
	x.table[h] = u32(len(x.entries))
	return true
}

@(private = "file")
node_hash :: #force_inline proc "contextless" (at: Node_Index) -> u32 {
	return u32((u64(at) * 0x9E3779B97F4A7C15) >> 32)
}

// The slots of a key table at most half full for `count` keys, or 0 if it would overflow `int`.
@(private = "file")
table_size :: #force_inline proc "contextless" (count: int) -> int {
	need := 2 * u64(count)
	size := u64(1)
	for size < need {
		size <<= 1
	}
	if size > u64(max(int) / size_of(Key_Slot)) {
		return 0
	}
	return int(size)
}

// Allocates a zeroed slice of `n` elements of `T` in `allocator`, treating a nil or short allocation as `.Out_Of_Memory`.
@(private = "file")
alloc_slice :: proc($T: typeid, n: int, allocator: runtime.Allocator) -> ([]T, runtime.Allocator_Error) {
	s, err := make([]T, n, allocator)
	if err == nil && (len(s) < n || n > 0 && raw_data(s) == nil) {
		err = .Out_Of_Memory
	}
	return s, err
}
