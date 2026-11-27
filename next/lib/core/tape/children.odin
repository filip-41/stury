package tape

import "base:intrinsics"
import "base:runtime"

// Container length and child iteration over whole, partial and tabular containers.

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
	expanded:  bool, // with `named`, the name is one the format reads as an expanded name
	keys_lo:   u32, // for a table's row, its table's `Table.keys_lo`
	keys_n:    u32, // for a table's row, the keys of its table, which name its cells by place, else 0
	name:      string, // with `named`, the key every member the walk gives has
	named:     bool,
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
	keys, _ := distinct_keys(doc, at, nil, slots)
	return keys, .Found, nil
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
		c.keys_lo, c.keys_n, c.once = t.keys_lo, t.keys_n, bool(t.unique_keys)
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

// Frees what `children` listed for `c` and leaves it zero. The members list is a prefix of `room`, freed whole.
destroy_children :: proc(c: ^Children) {
	if c.owned {
		delete(c.room, c.allocator)
	}
	c^ = {}
}

// The next element of an array, or the next distinct key of an object in text order with its value under `dups`, the
// key `NO_NODE` for an element and for a table row's cell, whose key is `cell_key`. Under `.Group`, and for a walk from
// `named`, the next member as written. `.Missing` once no child is left, and `.Not_Loaded` for each child a partial
// array did not keep, the walk going on past it.
@(require_results)
next_child :: proc "contextless" (r: Reader, c: ^Children, dups := Duplicates.Default) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
	doc := r.doc
	nodes := raw_data(doc.nodes)
	node := nodes[c.container]
	end := c.container + Node_Index(node.n)
	if node.kind == .Object {
		if intrinsics.expect(c.keys_n != 0, false) {
			return next_child_cell(doc, c, dups)
		}
		policy := read_dups(doc.format, dups)
		if intrinsics.expect(c.named || policy == .Group, false) {
			return next_child_named(doc, c, end)
		}
		if c.members == nil {
			if !c.once {
				return next_key(doc, c, end, policy)
			}
			if c.next >= end {
				return NO_NODE, NO_NODE, .Missing
			}
			key = c.next
			v := nodes[key + 1]
			c.next = key + 1 + (Node_Index(v.n) if v.kind > .Plain else 1)
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
	if intrinsics.expect(node.spelling & CONTAINER_PARTIAL != 0, false) {
		return next_child_partial_array(doc, node, c, end)
	}
	if c.next >= end {
		return NO_NODE, NO_NODE, .Missing
	}
	value = c.next
	// The nodes ahead are fetched, as each step waits on the load of the element it passes.
	intrinsics.prefetch_read_data(&nodes[value + NTH_AHEAD], 3)
	v := nodes[value]
	c.next = value + (Node_Index(v.n) if v.kind > .Plain else 1)
	c.place += 1
	return NO_NODE, value, .Found
}

@(private = "file", cold, require_results)
next_child_cell :: #force_no_inline proc "contextless" (doc: ^Document, c: ^Children, dups: Duplicates) -> (Node_Index, Node_Index, Presence) #no_bounds_check {
	value, p := next_cell(doc, c, row_policy(doc, dups))
	return NO_NODE, value, p
}

@(private = "file", cold, require_results)
next_child_named :: #force_no_inline proc "contextless" (doc: ^Document, c: ^Children, end: Node_Index) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
	for c.next < end {
		key = c.next
		c.next = node_after(doc, key + 1)
		unknown := false
		if !c.named || key_at_names(doc, key, c.name, c.expanded, &unknown) {
			c.place += 1
			return key, key + 1, .Found
		}
		if unknown {
			return NO_NODE, NO_NODE, .Not_Loaded
		}
	}
	return NO_NODE, NO_NODE, .Missing
}

@(private = "file", cold, require_results)
next_child_partial_array :: #force_no_inline proc "contextless" (doc: ^Document, node: Node, c: ^Children, end: Node_Index) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
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
	value = c.next
	intrinsics.prefetch_read_data(&raw_data(doc.nodes)[value + NTH_AHEAD], 3)
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
	c = Children{container = at, next = at + 1, name = name, named = true, expanded = names_expanded(doc, name)}
	if t, row := row_of(doc, at); row {
		c.keys_lo, c.keys_n = t.keys_lo, t.keys_n
		_, p = row_member(doc, t, at, name, .First)
		return c, p
	}
	unknown := false
	hit := false
	end := at + Node_Index(node.n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		if key_at_names(doc, k, name, c.expanded, &unknown) {
			hit = true
			break
		}
	}
	if hit {
		// A read keeps every member of a key it keeps one of, but under `.First` the first only, and none past a
		// stop, which leaves the count of an object it comes inside not known.
		if node.spelling & CONTAINER_PARTIAL != 0 && (doc.partial == nil || doc.partial.dups == .First || child_count(doc, at, node) < 0) {
			return {}, .Not_Loaded
		}
		return c, .Found
	}
	if !unknown && (node.spelling & CONTAINER_PARTIAL == 0 || named_missing(doc.partial, at, name)) {
		return {}, .Missing
	}
	return {}, .Not_Loaded
}

// The next key of the whole object ending at `end` that no member before it has, and its value under `dups`, by
// comparing keys, for an object of at most `SMALL_OBJECT` members.
@(private = "file", cold)
next_key :: #force_no_inline proc "contextless" (doc: ^Document, c: ^Children, end: Node_Index, dups: Duplicates) -> (key, value: Node_Index, p: Presence) #no_bounds_check {
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

// Whether key node `k` of `doc` reads as `name`, by the format's reading for an `expanded` one, which sets `unknown`
// for a key whose document did not keep what decides it.
@(private = "file")
key_at_names :: #force_inline proc "contextless" (doc: ^Document, k: Node_Index, name: string, expanded: bool, unknown: ^bool) -> bool #no_bounds_check {
	if !expanded {
		return doc_names(doc, doc.nodes[k], name)
	}
	p := doc.format.expanded(doc, k, name)
	unknown^ ||= p == .Not_Loaded
	return p == .Found
}
