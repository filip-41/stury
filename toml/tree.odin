#+private
package toml

import "base:runtime"
import core "../core"

// The tables of a text, in the order the text defines them. A TOML text names a member where it is written, and a
// table's members may be written apart (`[a.b]` before `[a]`), so the walk builds this tree first and then replays it
// in document order. Node 0 is the root table.

NIL :: u32(max(u32))

// A text of short keyed lines holds a node for about `NODE_BYTES` bytes, and a large table a member for about
// `MEMBER_BYTES`. The tree reserves nodes for that many and the index, once a table outgrows its list, for that many
// members. Past the cap or in a sparser text each grows as it fills.
NODE_BYTES :: 6
MEMBER_BYTES :: 16
MAX_RESERVED_NODES :: 1 << 20

// The most members a table holds before its members join `Table_Tree.index`. A smaller table finds a member along its list.
INDEXED_AFTER :: 16

Node_Kind :: enum u8 {
	Table,
	Array,
	Scalar,
}

Flag :: enum u8 {
	Header, // a table a `[header]` or `[[header]]` defines
	Dotted, // a table a dotted key created
	Inline, // a table written in braces, closed to later keys
	Tables, // an array a `[[header]]` created, which more headers extend
}

Comment :: struct {
	lo: u64,
	n:  u32,
}

// One key of a path, its token and its decoded text.
Part :: struct {
	tok:  core.Token,
	name: string,
}

Table_Node :: struct {
	key:                              core.Token, // role `Key`, empty for an array element
	value:                            core.Token, // a scalar's token, a container's first byte
	name:                             string, // the key's decoded text
	parent, first, last, next, chain: u32,
	count, depth:                     u32,
	head, heads:                      u32, // the comments above, a range of `Table_Tree.comments`
	foot, foots:                      u32, // the comments before the close
	inline:                           Comment, // the comment on the line where the value ends
	kind:                             Node_Kind,
	flags:                            bit_set[Flag; u8],
}

Table_Tree :: struct {
	nodes:     [dynamic]Table_Node,
	comments:  [dynamic]Comment,
	index:     map[u64]u32,
	names:     runtime.Arena,
	members:   int, // the members the index reserves for
	max_depth: u32,
}

// Why an insertion refused.
Refusal :: enum u8 {
	None,
	Redefined, // a table written twice, or a header over a dotted table
	Duplicate, // a key written twice
	Inline, // a key or header into an inline table
	Static, // a header into an array no header created
	Not_Table, // a header through a value that is no table
	Too_Deep,
	No_Memory,
}

tree_init :: proc "contextless" (t: ^Table_Tree, max_depth: u32, src_len: int) -> bool {
	context = runtime.default_context()
	t.max_depth = max_depth
	t.members = min(src_len / MEMBER_BYTES, MAX_RESERVED_NODES) + 16
	// A node is written whole when it is appended, so the reservation is not zeroed.
	t.nodes = non_zero_make([dynamic]Table_Node, 0, min(src_len / NODE_BYTES, MAX_RESERVED_NODES) + 16)
	t.comments = make([dynamic]Comment, 0, 8)
	if t.nodes == nil || t.comments == nil {
		return false
	}
	append(&t.nodes, Table_Node{kind = .Table, flags = {.Header}, parent = NIL, first = NIL, last = NIL, next = NIL, chain = NIL})
	return true
}

tree_destroy :: proc "contextless" (t: ^Table_Tree) {
	context = runtime.default_context()
	delete(t.nodes)
	delete(t.comments)
	delete(t.index)
	runtime.arena_destroy(&t.names)
}

name_hash :: #force_inline proc "contextless" (parent: u32, name: string) -> u64 {
	h := u64(parent) * 0x9e3779b97f4a7c15 + 0xcbf29ce484222325
	for b in transmute([]u8)name {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	return h
}

find_child :: proc "contextless" (t: ^Table_Tree, parent: u32, name: string) -> u32 {
	if t.nodes[parent].count <= INDEXED_AFTER {
		for id := t.nodes[parent].first; id != NIL; id = t.nodes[id].next {
			// The length and the first byte part most names without a call.
			m := t.nodes[id].name
			if len(m) == len(name) && (len(m) == 0 || m[0] == name[0]) && m == name {
				return id
			}
		}
		return NIL
	}
	context = runtime.default_context()
	id, ok := t.index[name_hash(parent, name)]
	if !ok {
		return NIL
	}
	for id != NIL {
		n := &t.nodes[id]
		if n.parent == parent && n.name == name {
			return id
		}
		id = n.chain
	}
	return NIL
}

// Appends a node under `parent`. A keyed node joins the parent's lookup, the index once the parent holds more than
// `INDEXED_AFTER` members, when its earlier members join it too. A container node is refused past the depth limit,
// since its token opens a level.
add_node :: proc "contextless" (t: ^Table_Tree, parent: u32, node: Table_Node, keyed: bool) -> (id: u32, r: Refusal) {
	context = runtime.default_context()
	n := node
	n.parent, n.depth = parent, t.nodes[parent].depth + 1
	n.first, n.last, n.next, n.chain = NIL, NIL, NIL, NIL
	if n.kind != .Scalar && n.depth + 1 > t.max_depth {
		return NIL, .Too_Deep
	}
	id = u32(len(t.nodes))
	if _, err := append(&t.nodes, n); err != nil {
		return NIL, .No_Memory
	}
	p := &t.nodes[parent]
	if p.last == NIL {
		p.first = id
	} else {
		t.nodes[p.last].next = id
	}
	p.last = id
	p.count += 1
	if !keyed || p.count <= INDEXED_AFTER {
		return id, .None
	}
	from := id
	if p.count == INDEXED_AFTER + 1 {
		if cap(t.index) == 0 && reserve(&t.index, t.members) != nil {
			return NIL, .No_Memory
		}
		from = p.first
	}
	for m := from; m != NIL; m = t.nodes[m].next {
		h := name_hash(parent, t.nodes[m].name)
		if head, ok := t.index[h]; ok {
			t.nodes[m].chain = head
		}
		t.index[h] = m
	}
	return id, .None
}

// The member a dotted key's part `part` names in table `cur`, which the key creates when it is new. An existing one is
// reached only when a dotted key made it.
dotted_step :: proc "contextless" (t: ^Table_Tree, cur: u32, part: Part) -> (id: u32, first: bool, r: Refusal) {
	id = find_child(t, cur, part.name)
	if id == NIL {
		id, r = add_node(t, cur, Table_Node{key = part.tok, value = core.Token{lo = part.tok.lo}, name = part.name, kind = .Table, flags = {.Dotted}}, true)
		return id, true, r
	}
	n := &t.nodes[id]
	if n.kind != .Table || .Dotted not_in n.flags {
		return NIL, false, .Inline if .Inline in n.flags else .Duplicate
	}
	return id, false, .None
}

// The scalar slot a key's last part names in table `cur`. The value is set once it has been read.
leaf_key :: proc "contextless" (t: ^Table_Tree, cur: u32, part: Part) -> (id: u32, r: Refusal) {
	if find_child(t, cur, part.name) != NIL {
		return NIL, .Duplicate
	}
	return add_node(t, cur, Table_Node{key = part.tok, name = part.name, kind = .Scalar}, true)
}

// A table or array element a header's path passes through. An array of tables continues in its last element.
header_step :: proc "contextless" (t: ^Table_Tree, cur: u32, part: Part) -> (id: u32, r: Refusal) {
	id = find_child(t, cur, part.name)
	if id == NIL {
		return add_node(t, cur, Table_Node{key = part.tok, value = core.Token{lo = part.tok.lo}, name = part.name, kind = .Table}, true)
	}
	n := &t.nodes[id]
	switch n.kind {
	case .Table:
		if .Inline in n.flags {
			return NIL, .Inline
		}
		return id, .None
	case .Array:
		if .Tables not_in n.flags {
			return NIL, .Static
		}
		return n.last, .None
	case .Scalar:
	}
	return NIL, .Not_Table
}

// The table a `[header]` ends in, which is new or a table only other headers' paths made.
header_leaf :: proc "contextless" (t: ^Table_Tree, cur: u32, part: Part, start: u64) -> (id: u32, r: Refusal) {
	id = find_child(t, cur, part.name)
	if id == NIL {
		return add_node(t, cur, Table_Node{key = part.tok, value = core.Token{lo = start}, name = part.name, kind = .Table, flags = {.Header}}, true)
	}
	n := &t.nodes[id]
	if n.kind != .Table {
		return NIL, .Duplicate
	}
	if n.flags != {} {
		return NIL, .Inline if .Inline in n.flags else .Redefined
	}
	n.flags = {.Header}
	n.value.lo = start
	return id, .None
}

// The new element table of the array of tables a `[[header]]` ends in.
array_leaf :: proc "contextless" (t: ^Table_Tree, cur: u32, part: Part, start: u64) -> (id: u32, r: Refusal) {
	array := find_child(t, cur, part.name)
	if array == NIL {
		array, r = add_node(t, cur, Table_Node{key = part.tok, value = core.Token{lo = start}, name = part.name, kind = .Array, flags = {.Tables}}, true)
		if r != .None {
			return NIL, r
		}
	} else if n := &t.nodes[array]; n.kind != .Array || .Tables not_in n.flags {
		return NIL, .Static if n.kind == .Array else .Duplicate
	}
	return add_node(t, array, Table_Node{value = core.Token{lo = start}, kind = .Table, flags = {.Header}}, false)
}

// A comment into the tree's list. Returns false when the list cannot grow.
push_comment :: proc "contextless" (t: ^Table_Tree, c: Comment) -> bool {
	context = runtime.default_context()
	_, err := append(&t.comments, c)
	return err == nil
}
