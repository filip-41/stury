package core

// The row document and the reads of it that need no format: kind, members by index and in order, the
// authored span, the facts. A format's package decodes the strings, keys and numbers of its rows.

import "core:slice"

// A text and its row tree: one row per value over the source bytes.
//
//	- `src` is borrowed and must outlive every read: a number is decoded from its text there at each read,
//	  and an escape-free string is a slice of it.
//	- Everything else is owned by whoever built it.
Row_Document :: struct {
	src:       []byte,
	// One row per value, in the order the values appear in `src`.
	rows:      [dynamic]Row,
	// Escaped strings the build decoded, addressed by the rows.
	values:    [dynamic]u8,
	// What reads decoded or listed, made by the first such read (`row_cache`).
	cache:     ^Row_Cache,
	// The comments of a document read with them.
	facts:     [dynamic]Fact,
	dialect:   Row_Dialect,
	// Read under a nesting cap past the format's default, so it may nest deeper than its writer writes.
	deep:      bool,
	// The builder knows no object repeats a key, so a reader need not look.
	distinct_keys: bool,
}

// What a document's reads keep, in the rows' allocator, so a document that is only built carries one pointer.
Row_Cache :: struct {
	// Escaped strings and keys decoded on demand; `keys` and `strings` cache them by node.
	arena:     Name_Arena,
	keys:      map[Node]string,
	strings:   map[Node]string,
	// The member nodes of containers that `child_by_index` reached deep into; `member_at` has each run's start.
	members:   [dynamic]Node,
	member_at: map[Node]int,
}

// The document's cache, made in the rows' allocator on the first call; nil when that allocation is refused.
row_cache :: proc(doc: ^Row_Document) -> ^Row_Cache {
	if doc.cache != nil {
		return doc.cache
	}
	a := doc.rows.allocator
	c, err := new(Row_Cache, a)
	if err != nil {
		return nil
	}
	c.keys.allocator, c.strings.allocator, c.members.allocator, c.member_at.allocator = a, a, a, a
	c.arena.blocks.allocator = a
	doc.cache = c
	return c
}

// Empty the cache for a rescan, keeping its storage.
row_cache_reset :: proc(doc: ^Row_Document) {
	if c := doc.cache; c != nil {
		clear(&c.keys)
		clear(&c.strings)
		clear(&c.members)
		clear(&c.member_at)
		name_arena_reset(&c.arena)
	}
}

// Free the cache and everything it holds.
row_cache_destroy :: proc(doc: ^Row_Document) {
	if c := doc.cache; c != nil {
		delete(c.keys)
		delete(c.strings)
		delete(c.members)
		delete(c.member_at)
		name_arena_destroy(&c.arena)
		free(c, doc.rows.allocator)
		doc.cache = nil
	}
}

// The kind of value `n`. `ok` is false, and the kind `.Null`, when `n` is no value, such as `NO_NODE`.
@(require_results)
kind :: #force_inline proc(doc: ^Row_Document, n: Node) -> (k: Kind, ok: bool) {
	if !dom_has(doc.rows[:], n) {
		return .Null, false
	}
	return doc.rows[n].kind, true
}

// The authored text of value `n`, a slice of `doc.src`: a string with its quotes, a container with its
// brackets and everything between. Nil for `NO_NODE`.
@(require_results)
get_raw :: proc(doc: ^Row_Document, n: Node) -> []byte {
	if !dom_has(doc.rows[:], n) {
		return nil
	}
	return doc.src[doc.rows[n].lo:doc.rows[n].hi]
}

// The facts attached to `n`, sorted by place (`Fact_Place`) then source order. Empty for a document read
// without them.
@(require_results)
facts :: proc(doc: ^Row_Document, n: Node) -> []Fact {
	all := doc.facts[:]
	lo, _ := slice.binary_search_by(all, n, proc(f: Fact, n: Node) -> slice.Ordering {
		return slice.cmp(f.node, n) if f.node != n else .Greater
	})
	hi := lo
	for hi < len(all) && all[hi].node == n {
		hi += 1
	}
	return all[lo:hi]
}

// The member count of container `n`; zero on a scalar.
@(require_results)
child_count :: proc(doc: ^Row_Document, n: Node) -> int {
	return dom_child_count(doc.rows[:], n)
}

// Member `i` of container `n`, 0-based (from the end when negative), or `NO_NODE`. O(1) over an array of
// scalars, and over any other container once a call has reached NTH_WALK members into it, which lists its
// members once in its cache (`Row_Cache`): a write and an allocation from the rows' allocator.
@(require_results)
child_by_index :: proc(doc: ^Row_Document, n: Node, index: int) -> Node {
	i := index
	if i < 0 {
		i += child_count(doc, n)
		if i < 0 {
			return NO_NODE
		}
	}
	if i == 0 {
		return dom_first_member(doc.rows[:], n)
	}
	if i < NTH_WALK || i >= child_count(doc, n) || dom_flat_array(doc.rows[n]) {
		return dom_nth_member(doc.rows[:], n, i)
	}
	at, listed := 0, false
	if doc.cache != nil {
		at, listed = doc.cache.member_at[n]
	}
	if !listed {
		at, listed = list_members(doc, n)
		if !listed {
			return dom_nth_member(doc.rows[:], n, i)
		}
	}
	return doc.cache.members[at + i]
}

// How many members `child_by_index` steps over before it lists a container's members: past that, a walk
// per call made reading every member by index quadratic.
@(private = "file")
NTH_WALK :: 64

// List the members of container `n` in `members`, and where they start; false when the allocator refused,
// or a refused append left the container short of rows, and nothing is kept.
@(private = "file")
list_members :: proc(doc: ^Row_Document, n: Node) -> (at: int, ok: bool) {
	c := row_cache(doc)
	if c == nil {
		return
	}
	at = len(c.members)
	count := child_count(doc, n)
	if reserve(&c.members, at + count) != nil {
		return
	}
	it := members_of(doc, n)
	for j in children_next(&it) {
		append(&c.members, j)
	}
	if len(c.members) - at != count {
		resize(&c.members, at)
		return
	}
	if map_insert(&c.member_at, n, at) == nil {
		resize(&c.members, at)
		return
	}
	return at, true
}

// The position of a walk over one container's members. A value, owning nothing; it borrows the document. A
// member's run of rows ends where the next begins, so a step is one add, bounded by the container's end (`end`).
Members :: struct {
	doc:  ^Row_Document,
	node: Node,
	end:  Node,
}

// Start a walk over the members of `n`: over a scalar or `NO_NODE`, an empty one.
@(require_results)
members_of :: proc(doc: ^Row_Document, n: Node) -> Members {
	when ODIN_DEBUG {
		check_node(doc, n)
	}
	first := dom_first_member(doc.rows[:], n)
	if first == NO_NODE {
		return {doc = doc}
	}
	return {doc = doc, node = first, end = n + Node(doc.rows[n].subtree_size)}
}

// The next member of the walk, `ok` false past the last.
@(require_results)
children_next :: #force_inline proc(it: ^Members) -> (n: Node, ok: bool) {
	if it.node >= it.end {
		return NO_NODE, false
	}
	n = it.node
	it.node += Node(it.doc.rows[n].subtree_size)
	return n, true
}

// A debug build's check of the one row `n` and its run, which the readers trust of a document whose fields a
// caller can break. `row_ok` is the check of row `i`. Compiled out unless `ODIN_DEBUG`.
when ODIN_DEBUG {
	check_node :: proc(doc: ^Row_Document, n: Node, loc := #caller_location) {
		assert(!dom_has(doc.rows[:], n) || row_ok(doc, int(n)), "Document is corrupt: a row's run or span is out of range", loc)
	}

	row_ok :: proc(doc: ^Row_Document, i: int) -> bool {
		r := doc.rows[i]
		return r.subtree_size >= 1 && i + int(r.subtree_size) <= len(doc.rows) && r.lo <= r.hi && int(r.hi) <= len(doc.src) &&
			(r.kind == .Array || r.kind == .Object || r.subtree_size == 1)
	}
}
