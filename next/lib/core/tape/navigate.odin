package tape

import "base:intrinsics"
import "base:runtime"

// The readers that step from a node of a document to the values in it, on a whole document and on a path read's
// partial one alike. A partial container answers `.Not_Loaded` for what it cannot settle, so no reader takes a value
// the read left out for one the text lacks. A step follows the rules of step.odin: null has no member and no element,
// so a step into it is `.Missing`, and it has no children to iterate. `.Default` duplicates are the document format's
// policy, and a key of any scalar kind is named by its text.

// A document and an index of its whole containers, nil for none, which the readers work over. Without an index they
// walk the containers. An index fills as the readers read, so a reader is not shared between threads while it has one.
Reader :: struct {
	doc:   ^Document,
	index: ^Doc_Index,
}

// The tables the readers built over the whole containers of a document, each when a read first needed it: a wide
// array's elements by place, a wide object's distinct keys in text order with a hash table over them, and for each
// object the readers examined whether it repeats a key, so they take the others as written. A refused allocation
// leaves the readers walking, which answers the same. An index serves the readers of one document, from its first read
// to `destroy`, and is empty until a read needs a table, so a zero one with its allocator set starts it.
Doc_Index :: struct {
	examined:  []u64, // a bit per node, set for a whole object whose keys were compared
	repeats:   []u64, // a bit per node, set for an examined object two of whose members share a key
	entries:   [dynamic]Index_Entry,
	table:     []u32, // one past an entry, by its node's hash, 0 for an empty slot, at most half full
	allocator: runtime.Allocator,
}

// A wide container's tables in a `Doc_Index`: an array's elements, or an object's distinct keys and their hash table,
// each its own allocation, so a `Children` holding them outlives later entries.
@(private)
Index_Entry :: struct {
	node:     Node_Index,
	elements: []Node_Index,
	members:  []Distinct_Member,
	room:     []Distinct_Member, // the whole block `members` is a prefix of
	slots:    []Key_Slot,
}

// The fewest elements a read passes in an array before the index lists its elements.
@(private)
INDEX_ELEMENTS :: 16

// A walk over the children of a container, from `children`, which `next_child` moves and `destroy_children` frees.
Children :: struct {
	container: Node_Index,
	next:      Node_Index, // the next member's key or the next element
	room:      []Distinct_Member, // the whole block `members` is a prefix of, which `owned` frees
	place:     u32, // the next element's index, or the next distinct key's in `members`
	kept:      u32, // in a partial array, the first `Partial.kept` entry not passed
	// For a wide object that may repeat a key, its distinct keys in text order, else nil.
	members:   []Distinct_Member,
	allocator: runtime.Allocator, // of `members` when `owned`, else the index's
	owned:     bool,
	once:      bool, // an object holding each key once, whose members are taken as written
	header:    Node_Index, // for a table's row, the header whose keys name its cells by place, else 0
	name:      string, // with `named`, the key every member the walk gives has
	named:     bool,
}

// A key of an object at its first place, and the values of its first and last members.
@(private)
Distinct_Member :: struct {
	key, first, last: Node_Index,
}

// The most members of an object whose repeated keys the readers find by comparing each key with the others, with no
// table, and that the index lists no table of.
@(private)
SMALL_OBJECT :: 8

// The root value, `.Not_Loaded` for a partial document that kept none.
@(require_results)
root :: proc "contextless" (r: Reader) -> (Node_Index, Presence) {
	if len(r.doc.nodes) == 0 {
		return NO_NODE, .Not_Loaded if r.doc.partial != nil else .Missing
	}
	return ROOT, .Found
}

// Answer `k` of path `path` of a path read, in document order: the value found, the deepest container reached for
// `.Missing`, or the value a step could not enter for `.Wrong_Kind`. False past the path's last answer, and for a
// document no path read made.
@(require_results)
answer :: proc "contextless" (r: Reader, path, k: int) -> (node: Node_Index, p: Presence, ok: bool) #no_bounds_check {
	x := r.doc.partial
	if x == nil || path < 0 || path + 1 >= len(x.starts) {
		return NO_NODE, .Missing, false
	}
	lo, hi := int(x.starts[path]), int(x.starts[path + 1])
	if k < 0 || k >= hi - lo {
		return NO_NODE, .Missing, false
	}
	a := x.answers[lo + k]
	return a.node, a.outcome, true
}

// The value of the member `name` of the object at `at` under `dups`, `.Missing` when the object or null has none and
// `.Wrong_Kind` for any other value. Every reader takes `NO_NODE`, which a miss gives, as a miss and answers `.Missing`.
@(require_results)
member :: proc(r: Reader, at: Node_Index, name: string, dups := Duplicates.Default) -> (Node_Index, Presence) #no_bounds_check {
	if at == NO_NODE {
		return NO_NODE, .Missing
	}
	doc := r.doc
	node := doc.nodes[at]
	if node.kind != .Object {
		return NO_NODE, step_refused(node.kind)
	}
	policy := read_dups(doc.format, dups)
	if t, row := row_of(doc, at); row {
		return row_member(doc, t, at, name, policy)
	}
	partial := node.spelling & CONTAINER_PARTIAL != 0
	if policy == .Last && clashes(doc, at, name) {
		return NO_NODE, .Ambiguous
	}
	if !partial && r.index != nil {
		if count := child_count(doc, at, node); count > SMALL_OBJECT {
			if e, ok := object_entry(r, at, count); ok {
				return index_member(r, e, name, policy)
			}
		}
	}
	// An object that holds each key once has its only match at the first, and a group's first member is its own.
	first := policy != .Last || !partial && keys_known_once(r, at)
	found := NO_NODE
	end := at + Node_Index(node.n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		if doc_names(doc, doc.nodes[k], name) {
			found = k
			if first {
				break
			}
		}
	}
	if found != NO_NODE {
		// A read keeps every member of a key it keeps one of, but under `.First` the first only, and none past a stop,
		// which leaves the count of an object it comes inside not known.
		if !partial || policy != .Last || doc.partial != nil && doc.partial.dups != .First && child_count(doc, at, node) >= 0 {

			return found + 1, .Found
		}
		return NO_NODE, .Not_Loaded
	}
	if !partial || named_missing(doc.partial, at, name) {
		return NO_NODE, .Missing
	}
	return NO_NODE, .Not_Loaded
}

// The element `index` of the array at `at`, negative from the end, `.Missing` past either end of an array and for
// null, and `.Wrong_Kind` for any other value.
@(require_results)
element :: proc(r: Reader, at: Node_Index, index: int) -> (Node_Index, Presence) #no_bounds_check {
	if at == NO_NODE {
		return NO_NODE, .Missing
	}
	doc := r.doc
	node := doc.nodes[at]
	if node.kind != .Array {
		return NO_NODE, step_refused(node.kind)
	}
	count := child_count(doc, at, node)
	if index < 0 && count < 0 {
		return NO_NODE, .Not_Loaded
	}
	place, in_array := index_in(i64(index), u64(count) if count >= 0 else max(u64))
	if !in_array {
		return NO_NODE, .Missing
	}
	i := int(place)
	if node.spelling & CONTAINER_PARTIAL == 0 {
		first := at + 1
		if t, table := table_of(doc, at); table {
			if t.width != 0 {
				return t.first_row + Node_Index(i) * Node_Index(t.width + 1), .Found
			}
			first = t.first_row
		}
		if r.index != nil && i >= INDEX_ELEMENTS {
			if e, ok := array_entry(r, at, first, count); ok {
				return e.elements[i], .Found
			}
		}
		k := first
		for _ in 0 ..< i {
			k = node_after(doc, k)
		}
		return k, .Found
	}
	if doc.partial == nil {
		return NO_NODE, .Not_Loaded
	}
	end := at + Node_Index(node.n)
	c := Children{container = at, next = at + 1, kept = kept_from(doc.partial, at)}
	for ; c.next < end; c.next = node_after(doc, c.next) {
		if place, ok := kept_place(doc.partial, &c); ok && place == u32(i) {
			return c.next, .Found
		}
	}
	return NO_NODE, .Not_Loaded
}

// The length of the container at `at`, an array's elements or an object's distinct keys, 0 for null and
// `.Wrong_Kind` for any other scalar. With no index, the keys of a wide object that may repeat one are counted through
// a table, in `allocator` past the room `key_table` keeps it in, freed before the return, and a refused allocation is
// the error. An index keeps that table.
@(require_results)
length :: proc(r: Reader, at: Node_Index, allocator: runtime.Allocator) -> (n: int, p: Presence, err: runtime.Allocator_Error) #no_bounds_check {
	if at == NO_NODE {
		return 0, .Missing, nil
	}
	doc := r.doc
	node := doc.nodes[at]
	#partial switch node.kind {
	case .Null:
		return 0, .Found, nil
	case .Array, .Object:
	case:
		return 0, .Wrong_Kind, nil
	}
	count := child_count(doc, at, node)
	if node.kind == .Array || count <= 1 {
		return count, .Found if count >= 0 else .Not_Loaded, nil
	}
	if t, row := row_of(doc, at); row {
		return row_length(doc, t, at), .Found, nil
	}
	// A member a partial object did not keep may repeat a key.
	if node.spelling & CONTAINER_PARTIAL != 0 {
		return 0, .Not_Loaded, nil
	}
	if r.index != nil && count > SMALL_OBJECT {
		if e, ok := object_entry(r, at, count); ok {
			return len(e.members), .Found, nil
		}
	}
	if keys_once(r, at) {
		return count, .Found, nil
	}
	if count <= SMALL_OBJECT {
		c := Children{container = at, next = at + 1}
		for {
			if _, _, p = next_key(doc, &c, at + Node_Index(node.n), .First); p == .Missing {
				return int(c.place), .Found, nil
			}
		}
	}
	room: [WIDE_ROOM]Key_Slot = ---
	slots := key_table(count, room[:], allocator) or_return
	defer if len(slots) > len(room) {
		delete(slots, allocator)
	}
	return distinct_keys(doc, at, nil, slots), .Found, nil
}

// A walk over the children of the container at `at`, which `next_child` moves. `.Wrong_Kind` for a scalar, null
// included, and `.Not_Loaded` for a partial object, whose members' places are not kept. The distinct keys of an object
// that may repeat one are listed in the index, or with none in `allocator`, which the walk holds until
// `destroy_children`, and a refused allocation is the error.
@(require_results)
children :: proc(r: Reader, at: Node_Index, allocator: runtime.Allocator) -> (c: Children, p: Presence, err: runtime.Allocator_Error) #no_bounds_check {
	if at == NO_NODE {
		return {}, .Missing, nil
	}
	doc := r.doc
	node := doc.nodes[at]
	if node.kind < .Array {
		return {}, .Wrong_Kind, nil
	}
	partial := node.spelling & CONTAINER_PARTIAL != 0
	if node.kind == .Object && partial {
		return {}, .Not_Loaded, nil
	}
	c = Children{container = at, next = at + 1, allocator = allocator}
	if partial {
		c.kept = kept_from(doc.partial, at)
	}
	if node.kind != .Object {
		if t, table := table_of(doc, at); table {
			c.next = t.first_row
		}
		return c, .Found, nil
	}
	if t, row := row_of(doc, at); row {
		c.header, c.once = t.header, bool(t.unique_keys)
		return c, .Found, nil
	}
	count := child_count(doc, at, node)
	if r.index != nil && count > SMALL_OBJECT {
		if e, ok := object_entry(r, at, count); ok {
			if c.once = len(e.members) == count; !c.once {
				c.members = e.members
			}
			return c, .Found, nil
		}
	}
	// With no index a small object's keys are compared once here, so a walk over it takes its members as written.
	if r.index == nil && count <= SMALL_OBJECT {
		c.once = !small_repeats(doc, at)
		return c, .Found, nil
	}
	if c.once = r.index != nil && (keys_known_once(r, at) || keys_once(r, at)); c.once || count <= SMALL_OBJECT {
		return c, .Found, nil
	}
	werr: runtime.Allocator_Error
	c.members, c.room, werr = wide_members(doc, at, count, allocator)
	if werr != nil {
		return c, {}, werr
	}
	c.once, c.owned = c.members == nil, c.members != nil
	return c, .Found, nil
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
	if distinct_keys(doc, at, nil, slots) == count {
		return nil, nil, nil
	}
	made, merr2 := make([]Distinct_Member, count, allocator)
	if merr2 == nil && (len(made) < count || count > 0 && raw_data(made) == nil) {
		merr2 = .Out_Of_Memory
	}
	if merr2 != nil {
		return nil, nil, merr2
	}
	members = made
	intrinsics.mem_zero(raw_data(slots), len(slots) * size_of(Key_Slot))
	return members[:distinct_keys(doc, at, members, slots)], members, nil
}

// The slots of a key table `key_table` keeps in a caller's room, for a wide object of up to half as many members.
@(private)
WIDE_ROOM :: 128

// An empty key table for `count` keys, in `room` when it fits and else in `allocator`, which the caller frees. A
// nil allocator's empty table is a refusal, as a key probe cannot read one.
@(private)
key_table :: proc(count: int, room: []Key_Slot, allocator: runtime.Allocator) -> ([]Key_Slot, runtime.Allocator_Error) {
	size := table_size(count)
	if size > len(room) {
		s, err := make([]Key_Slot, size, allocator)
		if err == nil && (len(s) < size || raw_data(s) == nil) {
			err = .Out_Of_Memory
		}
		return s, err
	}
	intrinsics.mem_zero(raw_data(room), size * size_of(Key_Slot))
	return room[:size], nil
}

// Frees what `children` listed for `c` and leaves it zero. The members list is a prefix of `room`, freed whole.
destroy_children :: proc(c: ^Children) {
	if c.owned {
		delete(c.room, c.allocator)
	}
	c^ = {}
}

// The next element of an array, or the next distinct key of an object in text order with its value under `dups`, the
// key `NO_NODE` for an element. Under `.Group`, and for a walk from `named`, the next member as written. `.Missing`
// once no child is left, and `.Not_Loaded` for each child a partial array did not keep, the walk going on past it.
@(require_results)
next_child :: proc "contextless" (r: Reader, c: ^Children, dups := Duplicates.Default) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
	doc := r.doc
	node := doc.nodes[c.container]
	end := c.container + Node_Index(node.n)
	if node.kind == .Object {
		policy := read_dups(doc.format, dups)
		if c.header != 0 {
			return next_cell(doc, c, policy)
		}
		if c.named || policy == .Group {
			for c.next < end {
				key = c.next
				c.next = node_after(doc, key + 1)
				if !c.named || doc_names(doc, doc.nodes[key], c.name) {
					c.place += 1
					return key, key + 1, .Found
				}
			}
			return NO_NODE, NO_NODE, .Missing
		}
		if c.members == nil {
			if !c.once {
				return next_key(doc, c, end, policy)
			}
			if c.next >= end {
				return NO_NODE, NO_NODE, .Missing
			}
			key = c.next
			c.next = node_after(doc, key + 1)
			c.place += 1
			return key, key + 1, .Found
		}
		if int(c.place) == len(c.members) {
			return NO_NODE, NO_NODE, .Missing
		}
		m := c.members[c.place]
		c.place += 1
		return m.key, m.first if policy != .Last else m.last, .Found
	}
	if node.spelling & CONTAINER_PARTIAL == 0 {
		if c.next >= end {
			return NO_NODE, NO_NODE, .Missing
		}
	} else {
		count := child_count(doc, c.container, node)
		if count >= 0 && int(c.place) >= count {
			return NO_NODE, NO_NODE, .Missing
		}
		if doc.partial == nil || c.next >= end {
			c.place += 1
			return NO_NODE, NO_NODE, .Not_Loaded
		}
		if place, ok := kept_place(doc.partial, c); !ok || place != c.place {
			c.place += 1
			return NO_NODE, NO_NODE, .Not_Loaded
		}
	}

	value = c.next
	c.next = node_after(doc, value)
	c.place += 1
	return NO_NODE, value, .Found
}

// A walk over the members of the object at `at` whose key is `name`, in document order, which `next_child` moves: the
// group a repeated name reads as. `.Missing` for an object with no such member and for null, `.Wrong_Kind` for any
// other value, and `.Not_Loaded` for a partial object that may hold a member it did not keep.
@(require_results)
named :: proc "contextless" (r: Reader, at: Node_Index, name: string) -> (c: Children, p: Presence) #no_bounds_check {
	if at == NO_NODE {
		return {}, .Missing
	}
	doc := r.doc
	node := doc.nodes[at]
	if node.kind != .Object {
		return {}, step_refused(node.kind)
	}
	c = Children{container = at, next = at + 1, name = name, named = true}
	if t, row := row_of(doc, at); row {
		c.header = t.header
		_, p = row_member(doc, t, at, name, .First)
		return c, p
	}
	end := at + Node_Index(node.n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		if doc_names(doc, doc.nodes[k], name) {
			// A read keeps every member of a key it keeps one of, but under `.First` the first only, and none past a
			// stop, which leaves the count of an object it comes inside not known.
			if node.spelling & CONTAINER_PARTIAL != 0 && (doc.partial.dups == .First || child_count(doc, at, node) < 0) {

				return {}, .Not_Loaded
			}
			return c, .Found
		}
	}
	if node.spelling & CONTAINER_PARTIAL == 0 || named_missing(doc.partial, at, name) {
		return {}, .Missing
	}
	return {}, .Not_Loaded
}

// Frees what the readers listed in `x` and leaves it zero. A members list is a prefix of its entry's `room`,
// freed whole.
destroy_index :: proc(x: ^Doc_Index) {
	for e in x.entries {
		delete(e.elements, x.allocator)
		delete(e.room, x.allocator)
		delete(e.slots, x.allocator)
	}
	delete(x.entries)
	delete(x.table, x.allocator)
	if x.examined != nil {
		free(raw_data(x.examined), x.allocator)
	}
	x^ = {}
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

// Keeps in the reader's index whether the whole object at `at` repeats a key, false when memory is refused.
@(private)
index_mark :: proc(r: Reader, at: Node_Index, repeats: bool) -> bool #no_bounds_check {
	x := r.index
	if x.examined == nil {
		words := (len(r.doc.nodes) + 63) / 64
		bits, err := make([]u64, 2 * words, x.allocator)
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

// Whether two members of the whole object at `at`, of at most `SMALL_OBJECT` members, share a key.
@(private)
small_repeats :: proc "contextless" (doc: ^Document, at: Node_Index) -> bool #no_bounds_check {
	keys: [SMALL_OBJECT]Node_Index = ---
	// Each key's kind and length, which two keys of one text share unless one of them is spelled with escapes.
	sizes: [SMALL_OBJECT]u64 = ---
	n := 0
	end := at + Node_Index(doc.nodes[at].n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		t := doc.nodes[k]
		size := u64(t.n) | u64(t.kind) << 32 if t.spelling & SPELLING_DECODE == 0 else max(u64)
		for i in 0 ..< n {
			if (sizes[i] == size || sizes[i] == max(u64) || size == max(u64)) && doc_same_keys(doc, doc.nodes[keys[i]], t) {
				return true
			}
		}
		keys[n], sizes[n] = k, size
		n += 1
	}
	return false
}

// The entry of the container at `at` in `x`, false for one it lists no table of.
@(private)
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

// The elements of the whole array at `at` of `count` elements, listed in the reader's index the first time, false when
// the index cannot hold them.
@(private)
array_entry :: proc(r: Reader, at, first: Node_Index, count: int) -> (e: Index_Entry, ok: bool) #no_bounds_check {
	x := r.index
	if e, ok = index_entry(x, at); ok {
		return
	}
	elements, err := make([]Node_Index, count, x.allocator)
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

// The distinct keys of the whole object at `at` of `count` members and their table, listed in the reader's index the
// first time, false when the index cannot hold them.
@(private)
object_entry :: proc(r: Reader, at: Node_Index, count: int) -> (e: Index_Entry, ok: bool) #no_bounds_check {
	x := r.index
	if e, ok = index_entry(x, at); ok {
		return
	}
	members, merr := make([]Distinct_Member, count, x.allocator)
	slots, serr := make([]Key_Slot, table_size(count), x.allocator)
	// A nil allocator gives no block and no error, or a shorter one, either read as a refusal.
	if merr == nil && (len(members) < count || count > 0 && raw_data(members) == nil) {
		merr = .Out_Of_Memory
	}
	if serr == nil && (len(slots) < table_size(count) || raw_data(slots) == nil) {
		serr = .Out_Of_Memory
	}
	if merr == nil && serr == nil {
		n := distinct_keys(r.doc, at, members, slots)
		e = {node = at, members = members[:n], room = members, slots = slots}
		if index_mark(r, at, n < count) && index_add(x, e) {
			return e, true
		}
	}
	delete(members, x.allocator)
	delete(slots, x.allocator)
	return {}, false
}

// Adds `e` to `x`, false when memory is refused.
@(private)
index_add :: proc(x: ^Doc_Index, e: Index_Entry) -> bool #no_bounds_check {
	if 2 * (len(x.entries) + 1) > len(x.table) {
		table, err := make([]u32, max(16, 2 * len(x.table)), x.allocator)
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

@(private)
node_hash :: #force_inline proc "contextless" (at: Node_Index) -> u32 {
	return u32((u64(at) * 0x9E3779B97F4A7C15) >> 32)
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

// The next key of the whole object ending at `end` that no member before it has, and its value under `dups`, by
// comparing keys, for an object of at most `SMALL_OBJECT` members.
@(private)
next_key :: proc "contextless" (doc: ^Document, c: ^Children, end: Node_Index, dups: Duplicates) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
	next: for c.next < end {
		key = c.next
		value = key + 1
		c.next = node_after(doc, value)
		t := doc.nodes[key]
		for k := c.container + 1; k < key; k = node_after(doc, k + 1) {
			if doc_same_keys(doc, doc.nodes[k], t) {
				continue next
			}
		}
		if dups != .First {
			for k := c.next; k < end; k = node_after(doc, k + 1) {
				if doc_same_keys(doc, doc.nodes[k], t) {
					value = k + 1
				}
			}
		}
		c.place += 1
		return key, value, .Found
	}
	return NO_NODE, NO_NODE, .Missing
}

// The child count of the container `node` at `at`, -1 when a partial document does not know it.
@(private)
child_count :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index, node: Node) -> int {
	count := node.spelling & MAX_CHILDREN
	if count < MAX_CHILDREN {
		return int(count)
	}
	return saturated_count(doc, at)
}

@(private)
saturated_count :: proc "contextless" (doc: ^Document, at: Node_Index) -> int #no_bounds_check {
	lo := by_node(doc.counts, at, false)
	if lo < len(doc.counts) && doc.counts[lo].node == at {
		return int(doc.counts[lo].count)
	}
	return -1
}

// The first entry of `list`, a list sorted by node, whose node is at or past `at`, or past it under `PAST`.
@(private)
by_node :: #force_inline proc "contextless" (list: []$T, at: Node_Index, $PAST: bool) -> int #no_bounds_check {
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].node < at || PAST && list[mid].node == at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The node after the value at `at` and its subtree.
node_after :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> Node_Index #no_bounds_check {
	n := doc.nodes[at]
	return at + Node_Index(n.n) if n.kind > .Plain else at + 1
}

// Whether the object at `at` is recorded as having no member `name`, by a search that rests on `Partial.missing` being
// sorted by node.
@(private)
named_missing :: proc "contextless" (x: ^Partial, at: Node_Index, name: string) -> bool #no_bounds_check {
	if x == nil {
		return false
	}
	lo := by_node(x.missing, at, false)
	for m in x.missing[lo:] {
		if m.node != at {
			break
		}
		if string(x.names[m.lo:][:m.n]) == name {
			return true
		}
	}
	return false
}

// The first `kept` entry past the node `at`, by a search that rests on `Partial.kept` being sorted by node.
@(private)
kept_from :: proc "contextless" (x: ^Partial, at: Node_Index) -> u32 #no_bounds_check {
	if x == nil {
		return 0
	}
	return u32(by_node(x.kept, at, true))
}

// The index of the kept element `c.next` of a partial array, which moves `c.kept` past it. A read that keeps only some
// elements of an array gives each it keeps a `kept` entry, so one with none has no known index.
@(private)
kept_place :: proc "contextless" (x: ^Partial, c: ^Children) -> (index: u32, ok: bool) #no_bounds_check {
	for int(c.kept) < len(x.kept) && x.kept[c.kept].node < c.next {
		c.kept += 1
	}
	if int(c.kept) < len(x.kept) && x.kept[c.kept].node == c.next {
		return x.kept[c.kept].index, true
	}
	return 0, false
}

// The slots of a key table at most half full for `count` keys.
@(private)
table_size :: #force_inline proc "contextless" (count: int) -> int {
	size := 1
	for size < 2 * count {
		size *= 2
	}
	return size
}

// The number of distinct keys of the whole object at `at`, found through the empty hash table `slots`, and with
// `members` each distinct key in text order with its first and last values, the slots' entries then one past a member.
// Keys are hashed and compared by the format's one relation, `Format.key_hash` with `same_keys`.
@(private)
distinct_keys :: proc "contextless" (doc: ^Document, at: Node_Index, members: []Distinct_Member, slots: []Key_Slot) -> (n: int) #no_bounds_check {
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
			}
			i = (i + 1) & mask
		}
	}
	return
}

@(private)
Key_Slot :: struct {
	hash:  u32,
	entry: u32, // 0 for an empty slot
}


// The table whose row is the object at `at`, false for an object of no table.
@(private)
row_of :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (Table, bool) {
	ext, tabular := doc.ext.(^Tabular_Ext)
	if !tabular {
		return {}, false
	}
	return table_around(ext, doc, at)
}

// The table whose node is the array at `at`, false for an array that is no table.
@(private)
table_of :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> (Table, bool) {
	ext, tabular := doc.ext.(^Tabular_Ext)
	if !tabular {
		return {}, false
	}
	t, inside := table_around(ext, doc, at)
	return t, inside && t.node == at
}

// The table whose node holds node `at`, false for none. Tables are sorted by node and do not nest.
@(private)
table_around :: proc "contextless" (ext: ^Tabular_Ext, doc: ^Document, at: Node_Index) -> (Table, bool) #no_bounds_check {
	lo, hi := 0, len(ext.tables)
	for lo < hi {
		mid := (lo + hi) / 2
		if ext.tables[mid].node <= at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo == 0 {
		return {}, false
	}
	t := ext.tables[lo - 1]
	return t, at < t.node + Node_Index(doc.nodes[t.node].n)
}

// The cells of row `at` that a key of table `t` names, which a row with more cells than keys has fewer of.
@(private)
row_cells :: #force_inline proc "contextless" (doc: ^Document, t: Table, at: Node_Index) -> int {
	keys := int(doc.nodes[t.header].n) - 1 if t.header != 0 else 0
	return min(int(doc.nodes[at].n) - 1, keys)
}

// The cell of row `at` of table `t` whose key is `name` under `dups`, through the table's key slots when they settle
// it.
@(private)
row_member :: proc "contextless" (doc: ^Document, t: Table, at: Node_Index, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	cells := row_cells(doc, t, at)
	f := doc.format
	// The slots hold each key's first column, which is its only one in a table whose keys are unique.
	if t.slots_len != 0 && (t.unique_keys || dups != .Last) {
		slots := doc.ext.(^Tabular_Ext).slots[t.slots_lo:][:t.slots_len]
		mask := t.slots_len - 1
		for i := f.key_hash(transmute([]u8)name, {n = u32(len(name)), kind = .String}) & mask; slots[i] != 0; i = (i + 1) & mask {
			col := Node_Index(slots[i]) - 1
			if doc_names(doc, doc.nodes[t.header + 1 + col], name) {
				if int(col) < cells {
					return at + 1 + col, .Found
				}
				break
			}
		}
		return NO_NODE, .Missing
	}
	found := NO_NODE
	for j in 0 ..< cells {
		if doc_names(doc, doc.nodes[t.header + 1 + Node_Index(j)], name) {
			found = at + 1 + Node_Index(j)
			if dups != .Last || t.unique_keys {
				break
			}
		}
	}
	return found, .Found if found != NO_NODE else .Missing
}

// The distinct keys of row `at` of table `t`.
@(private)
row_length :: proc "contextless" (doc: ^Document, t: Table, at: Node_Index) -> int #no_bounds_check {
	cells := row_cells(doc, t, at)
	if t.unique_keys {
		return cells
	}
	c := Children{container = at, next = at + 1, header = t.header}
	for {
		if _, _, p := next_cell(doc, &c, .First); p != .Found {
			return int(c.place)
		}
	}
}

// `next_child` over a table's row: each cell as written under `.Group`, for a walk from `named` and for a table of
// unique keys, else each distinct key with the cell `dups` takes.
@(private)
next_cell :: proc "contextless" (doc: ^Document, c: ^Children, dups: Duplicates) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
	t := Table{header = c.header}
	cells := Node_Index(row_cells(doc, t, c.container))
	next: for c.next < c.container + 1 + cells {
		j := c.next - c.container - 1
		value = c.next
		key = c.header + 1 + j
		c.next += 1
		k := doc.nodes[key]
		if c.named {
			if !doc_names(doc, k, c.name) {
				continue
			}
		} else if !c.once && dups != .Group {
			for o in c.header + 1 ..< key {
				if doc_same_keys(doc, doc.nodes[o], k) {
					continue next
				}
			}
			if dups != .First {
				for o in j + 1 ..< cells {
					if doc_same_keys(doc, doc.nodes[c.header + 1 + o], k) {
						value = c.container + 1 + o
					}
				}
			}
		}
		c.place += 1
		return key, value, .Found
	}
	return NO_NODE, NO_NODE, .Missing
}

// Whether keys of two kinds of the object at `at` read as `name`, in a document whose format records such a pair.
@(private)
clashes :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index, name: string) -> bool {
	ext, yaml := doc.ext.(^Yaml_Ext)
	return yaml && ext.clash != 0 && kinds_named(doc, at, name)
}

@(private)
kinds_named :: proc "contextless" (doc: ^Document, at: Node_Index, name: string) -> bool #no_bounds_check {
	end := at + Node_Index(doc.nodes[at].n)
	kind := Kind.End
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		if t := doc.nodes[k]; doc_names(doc, t, name) {
			if kind != .End && t.kind != kind {
				return true
			}
			kind = t.kind
		}
	}
	return false
}

// Whether key `t` of `doc` reads as `name`.
@(private)
doc_names :: #force_inline proc "contextless" (doc: ^Document, t: Token, name: string) -> bool {
	src, at := node_src(doc, t)
	return key_names(doc.format, src, at, name)
}

// Whether keys `a` and `b` of `doc` read as the same text.
@(private)
doc_same_keys :: #force_inline proc "contextless" (doc: ^Document, a, b: Token) -> bool {
	src_a, at_a := node_src(doc, a)
	src_b, at_b := node_src(doc, b)
	return same_keys(doc.format, src_a, at_a, src_b, at_b)
}

@(private)
doc_key_hash :: #force_inline proc "contextless" (doc: ^Document, t: Token) -> u32 {
	src, at := node_src(doc, t)
	return doc.format.key_hash(src, at)
}
