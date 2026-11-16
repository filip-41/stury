#+private
package core

// The document's arms of the readers `value.odin` names for both forms of a value, `kind`, `length`, `child_at`,
// `member`, `children`, `pairs`, `text` and `number`, which a caller reaches through those names.

// Returns the kind of node `i`, or `.Null` when `i` is past the last node. A `Plain` cell is the kind the format reads
// it as under the handle the document was read with.
doc_kind :: #force_inline proc(doc: ^Document, i: Node_Index) -> Kind {
	if int(i) >= len(doc.nodes) {
		return .Null
	}
	if k := doc.nodes[i].kind; k != .Plain {
		return k
	}
	return doc.readers.resolve(doc, i)
}

// Returns the number of members in container `i`, from its `spelling`, or 0 for a scalar or a node past the last.
// A count that saturated `MAX_CHILDREN` is read from `Document.counts`.
doc_length :: #force_inline proc(doc: ^Document, i: Node_Index) -> int {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind != .Array && doc.nodes[i].kind != .Object {
		return 0
	}
	n := doc.nodes[i]
	if n.spelling != MAX_CHILDREN {
		return int(n.spelling)
	}
	return wide_length(doc, i)
}

// Returns the true child count of container `i` from `Document.counts`, which holds it because `spelling` saturated.
@(cold)
wide_length :: #force_no_inline proc(doc: ^Document, i: Node_Index) -> int {
	at := lower_node(doc.counts, i)
	return int(doc.counts[at].count) if at < len(doc.counts) && doc.counts[at].node == i else 0
}

// Returns container `i`'s `k`th member value, counted from 0: for an inline-key `Object`, the value after its `k`th
// key, which is the node after the key. A `k` past the last member, a negative `k`, and a node that holds no members
// return no node. A container whose members are one node each is indexed, since its subtree size gives the stride: an
// `Array`'s is its member count plus one, a shared-key `Object`'s its count plus one, and an inline-key `Object`'s
// twice its count plus one. Any other container is read from its child index when `index_children` built one, else
// walked, stepping one subtree size per member. A count that saturated `MAX_CHILDREN` is read from `Document.counts`,
// so the stride test uses the true member count.
doc_child_at :: #force_inline proc(doc: ^Document, i: Node_Index, k: int) -> (Node_Index, bool) {
	if int(i) >= len(doc.nodes) || k < 0 {
		return NO_NODE, false
	}
	n := doc.nodes[i]
	count := int(n.spelling)
	// A saturated count holds only `MAX_CHILDREN`, the true count is in `Document.counts`. Reading it here keeps the
	// index path for a uniform container of any width and makes a `k` past the last member answer without a walk.
	if n.spelling == MAX_CHILDREN {
		if n.role == .Partial {
			return kept_child(doc, i, k)
		}
		count = wide_length(doc, i)
	}
	if k >= count {
		return NO_NODE, false
	}
	if n.kind != .Array && n.kind != .Object {
		return NO_NODE, false
	}
	if stride := one_node_stride(doc, n, count); stride != 0 {
		return i + Node_Index(stride * (k + 1)), true
	}
	return child_at_walk(doc, i, k)
}

// The distance in nodes between members of `n` when each member is one node: 2 for an inline-key `Object`, else 1. It is
// 0 when a member spans more nodes. The dsv header row is a child of the root but no member, so such a root gets 0.
one_node_stride :: #force_inline proc(doc: ^Document, n: Node, count: int) -> int {
	if n.kind == .Object && header_of(doc) == 0 {
		return 2 if int(n.n) == 2 * count + 1 else 0
	}
	return 1 if int(n.n) == count + 1 else 0
}

// `child_at` for a container whose members are not all one node, with `k` below the member count. The rows of a table
// with a width are computed. Else it reads the child index if there is one, and walks if not.
@(cold)
child_at_walk :: #force_no_inline proc(doc: ^Document, i: Node_Index, k: int) -> (Node_Index, bool) {
	if table, ok := table_of(doc, i); ok && table.width != 0 {
		return table.first_row + Node_Index(k) * Node_Index(table.width + 1), true
	}
	if members, indexed := indexed_members(doc, i); indexed && k < len(members) {
		return members[k], true
	}
	it := children(doc, i)
	for _ in 0 ..< k {
		if _, ok := child_next(&it); !ok {
			return NO_NODE, false
		}
	}
	v, ok := child_next(&it)
	return v, ok
}

// Container `i`'s entry in `Document.indexed`, and whether it has one.
indexed_members :: proc(doc: ^Document, i: Node_Index) -> ([]Node_Index, bool) {
	at := lower_node(doc.indexed[:], i)
	if at < len(doc.indexed) && doc.indexed[at].node == i {
		return doc.indexed[at].members, true
	}
	return nil, false
}

doc_children :: proc(doc: ^Document, i: Node_Index) -> Child_Iter {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind != .Array && doc.nodes[i].kind != .Object {
		return {doc = doc, parent = i, done = true}
	}
	n := doc.nodes[i]
	it := Child_Iter{doc = doc, parent = i, end = i + Node_Index(n.n), pairs = n.kind == .Object && header_of(doc) == 0}
	j := int(i) + 1
	if it.pairs {
		// The first member's key is one node.
		j += 1
	} else if n.role != .Key && j < int(it.end) && doc.nodes[j].role == .Key {
		// The dsv header row a root holds first. The key-role `Array` is that row, and it holds key cells, not
		// members.
		j += subtree_size(doc, Node_Index(j))
	}
	if j >= int(it.end) {
		it.done = true
	} else {
		it.at = Node_Index(j)
	}
	return it
}

// Returns the next value of a container and is inlined at every call, so a call does not spill the iterator and
// re-read it per member.
doc_child_next :: #force_inline proc(it: ^Child_Iter) -> (Node_Index, bool) {
	if it.done {
		return NO_NODE, false
	}
	v := it.at
	doc := it.doc
	n := doc.nodes[v]
	j := int(v) + 1
	if n.kind == .Array || n.kind == .Object {
		j = subtree_step(int(v), n.n)
	}
	if it.pairs {
		j += 1
	}
	if j >= int(it.end) {
		it.done = true
	} else {
		it.at = Node_Index(j)
	}
	return v, true
}

// Returns the step from `v` over a container's subtree, to the node after it. The call makes the kind test a
// `b.eq` with the load of `n` in the taken block: inlined, LLVM computes the stride with `csinc` from a load of
// `n` that the next member's address waits for.
subtree_step :: #force_no_inline proc(v: int, n: u32) -> int {
	return v + int(n)
}

// Returns the value of the member of `obj` whose key decodes to `name`, the first under `.First` and else the last.
// `members_named` yields every match. A headed dsv record's members are its cells, named by the header's cells.
doc_member :: #force_inline proc(doc: ^Document, obj: Node_Index, name: string, dups := Duplicates.Last) -> (Node_Index, bool) {
	// A single loop handles both shapes: `member_next` is inlined, so an object's step uses this frame's registers.
	it := members_named(doc, obj, name)
	if it.rec != NO_NODE && len(doc.tables_at[0].key_slots) != 0 {
		return member_probed(doc, it.rec, name)
	}
	found := NO_NODE
	for {
		v, ok := member_next(&it)
		if !ok {
			return found, found != NO_NODE
		}
		if dups == .First || it.rec != NO_NODE && doc.tables_at[0].unique_keys {
			return v, true
		}
		found = v
	}
}

// Returns the cell of headed record `obj`, an `Object` node, whose key is `name`, found through the table's `key_slots`. A
// cell past a short record's last matches no key.
member_probed :: #force_inline proc(doc: ^Document, obj: Node_Index, name: string) -> (Node_Index, bool) {
	t := &doc.tables_at[0]
	mask := u32(len(t.key_slots) - 1)
	for h := key_hash(name) & mask; t.key_slots[h] != 0; h = (h + 1) & mask {
		col := Node_Index(t.key_slots[h])
		if key_equals(doc, t.header + col, name) {
			if col >= Node_Index(doc.nodes[obj].n) {
				break
			}
			return obj + col, true
		}
	}
	return NO_NODE, false
}

// Returns the next of a shared-key `Object`'s values whose key decodes to `it.name`. The walk runs over the shared keys. A
// key past the `Object`'s last value matches nothing, so a short `Object`'s missing members are absent.
member_next_shared :: #force_inline proc(it: ^Member_Iter) -> (Node_Index, bool) {
	width := int(it.doc.nodes[it.rec].n) - 1
	for !it.done {
		j := int(it.at)
		if j >= int(it.end) {
			it.done = true
			break
		}
		it.at = Node_Index(j + 1)
		col := j - int(header_of(it.doc)) - 1
		if col < width && key_equals(it.doc, Node_Index(j), it.name) {
			return it.rec + Node_Index(1 + col), true
		}
	}
	return NO_NODE, false
}

// Starts a `Pair_Iter` over the key/value pairs of `obj`. On a non-`Object` container, a scalar, or an index past the last
// node, returns an empty iterator. `pair_next` tests the ends, so an empty `Object` needs no test here.
doc_pairs :: proc(doc: ^Document, obj: Node_Index) -> Pair_Iter {
	if int(obj) >= len(doc.nodes) || doc.nodes[obj].kind != .Object {
		return {doc = doc, done = true}
	}
	end := obj + Node_Index(doc.nodes[obj].n)
	if keys := header_of(doc); keys != 0 {
		return {doc = doc, key_at = keys + 1, val_at = obj + 1, key_end = keys + Node_Index(doc.nodes[keys].n), val_end = end, shared = true}
	}
	return {doc = doc, key_at = obj + 1, key_end = end}
}

// Returns the next key and value node of the `Object`. For an inline-key `Object`, key and value alternate in preorder.
// For a shared-key `Object`, keys come from the table's header while values advance within `obj`. An inline-key `Object`
// reads neither `val_at` nor `val_end`.
doc_pair_next :: #force_inline proc(it: ^Pair_Iter) -> (key, val: Node_Index, ok: bool) {
	if it.done {
		return NO_NODE, NO_NODE, false
	}
	doc := it.doc
	if it.shared {
		if it.key_at >= it.key_end || it.val_at >= it.val_end {
			it.done = true
			return NO_NODE, NO_NODE, false
		}
		k := it.key_at
		v := it.val_at
		it.key_at += 1
		n := doc.nodes[v]
		next_v := int(v) + 1
		if n.kind == .Array || n.kind == .Object {
			next_v = subtree_step(int(v), n.n)
		}
		it.val_at = Node_Index(next_v)
		return k, v, true
	}
	if it.key_at >= it.key_end {
		it.done = true
		return NO_NODE, NO_NODE, false
	}
	k := it.key_at
	v := k + 1
	n := doc.nodes[v]
	next_k := int(v) + 1
	if n.kind == .Array || n.kind == .Object {
		next_k = subtree_step(int(v), n.n)
	}
	it.key_at = Node_Index(next_k)
	return k, v, true
}

// Returns the decoded text of string or plain node `i`, or the payload of a byte string. A node whose `SPELLING_DECODE`
// bit is clear is its span without its quotes. A node that needs decoding is written into `buf`, and the call returns
// false when `buf` is too short, which `text_room` bytes never are, and its content is then unspecified. It allocates
// nothing, so a caller that has no buffer long enough uses `text_clone`. Returns false for a container or a node past
// the last.
doc_text :: #force_inline proc(doc: ^Document, i: Node_Index, buf: []u8) -> (s: string, ok: bool) {
	// Only a scalar carries text: a container's `n` is a node count, not a byte length.
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind > .Plain {
		return "", false
	}
	n := doc.nodes[i]
	if n.spelling & SPELLING_DECODE == 0 {
		return string(node_text(doc.src, n)), true
	}
	return doc.readers.text(&doc.view, n, buf)
}

// Returns the number node `i` writes, decoded from its span, and false for a node that is no number: a container, a
// string, a key, a cell that spells no number, and an index past the last node.
doc_number :: #force_inline proc(doc: ^Document, i: Node_Index) -> (Number, bool) {
	if int(i) < len(doc.nodes) && doc.nodes[i].kind <= .Plain {
		return doc.readers.number(&doc.view, doc.nodes[i])
	}
	return {}, false
}
