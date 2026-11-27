package toml

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// The tables of a text, in the order the text defines them. A TOML text names a member where it is written, and a
// table's members may be written apart (`[a.b]` before `[a]`), so the walk reads statements into this tree and gives
// the hook its nodes in document order. Node 0 is the root table.

@(private)
NIL :: u32(max(u32))

// A text of keyed lines holds a node for about `NODE_BYTES` bytes. The tree reserves nodes for that many, and grows
// past the cap or in a denser text as it fills.
@(private)
NODE_BYTES :: 24
@(private)
MAX_RESERVED_NODES :: 1 << 20

// The most members a table holds before its members join `Table_Tree.index`. A smaller table finds a member along its
// list.
@(private)
INDEXED_AFTER :: 16

// The slots the index holds once a table outgrows its list, a power of two. It doubles from there.
@(private)
INDEX_SLOTS :: 64

// How a container is written, in its token's `tape.CONTAINER_STYLE` bits: a table in braces or an array in brackets,
// a table a dotted key made, and on its `End` a table only other headers' paths made. A table a header made and an
// array of tables have none.
@(private)
STYLE_INLINE :: u16(1) << 13
@(private)
STYLE_DOTTED :: u16(2) << 13
@(private)
STYLE_IMPLICIT :: u16(3) << 13

#assert(STYLE_IMPLICIT == tape.CONTAINER_STYLE)

@(private)
Node_Kind :: enum u8 {
	Table,
	Array,
	Scalar,
}

@(private)
Flag :: enum u8 {
	Header, // a table a `[header]` or `[[header]]` defines
	Dotted, // a table a dotted key created
	Inline, // a table written in braces, closed to later keys
	Tables, // an array a `[[header]]` created, which more headers extend
	Given, // a table other headers made, whose key a walk gave before a header defined the table
}

@(private)
Comment :: struct {
	lo: u64,
	n:  u32,
}

// One key of a path, its token and its decoded text.
@(private)
Part :: struct {
	tok:  tape.Token,
	name: string,
}

// A node of the tree. A container's `value` is its token, and for one written in brackets or braces `value.n` is the
// distance from its open to its close.
@(private)
Table_Node :: struct {
	key:                              tape.Token, // role `Key`, zero for an array element
	value:                            tape.Token,
	name:                             string, // the key's decoded text
	parent, first, last, next:        u32,
	count, depth:                     u32,
	notes:                            u32, // its comments, 1 past their index in `Table_Tree.notes`, 0 for none
	kind:                             Node_Kind,
	flags:                            bit_set[Flag; u8],
}

// The comments of a node that has any.
@(private)
Notes :: struct {
	head, heads: u32, // the comments above, a range of `Table_Tree.comments`
	foot, foots: u32, // the comments before the close
	inline:      Comment, // the comment on the line where the value ends
}

@(private)
Table_Tree :: struct {
	allocator:  runtime.Allocator,
	nodes:      [dynamic]Table_Node,
	comments:   [dynamic]Comment,
	notes:      [dynamic]Notes,
	index:      []u64, // open addressing: a slot is 0 or a member's name hash's high half over its id plus 1
	indexed:    int, // the slots in use
	names:      runtime.Arena,
	keyed:      int, // the nodes with a key
	inlines:    int, // the comments set on a value's line, which may replace one another
	max_depth:  u32,
	deepest:    u32, // the depth of the deepest container node, 0 for the root alone
	extended:   u32, // the array of tables a header last added an element to, `NIL` once the walk took it
}

// Why an insertion refused.
@(private)
Tree_Refusal :: enum u8 {
	None,
	Redefined, // a table written twice, or a header over a dotted table
	Duplicate, // a key written twice
	Inline, // a key or header into an inline table
	Static, // a header into an array no header created
	Not_Table, // a header through a value that is no table
	Too_Deep,
	No_Memory,
}

@(private)
tree_init :: proc(t: ^Table_Tree, max_depth: u32, src_len: int, allocator: runtime.Allocator) -> bool {
	t.allocator = allocator
	t.max_depth = max_depth
	t.extended = NIL
	// A node is written whole when it is appended, so the reservation is not zeroed.
	err: runtime.Allocator_Error
	t.nodes, err = runtime.non_zero_make_dynamic_array_len_cap([dynamic]Table_Node, 0, min(src_len / NODE_BYTES, MAX_RESERVED_NODES) + 16, allocator)
	if err != nil {
		return false
	}
	t.comments.allocator = allocator
	t.notes.allocator = allocator
	t.names = {backing_allocator = allocator, minimum_block_size = 4096}
	append(&t.nodes, Table_Node{kind = .Table, flags = {.Header}, parent = NIL, first = NIL, last = NIL, next = NIL, value = {kind = .Object}})
	return true
}

@(private)
tree_destroy :: proc(t: ^Table_Tree) {
	delete(t.nodes)
	delete(t.comments)
	delete(t.notes)
	delete(t.index, t.allocator)
	runtime.arena_destroy(&t.names)
}

// The hash of member `name` of table `parent`: the name read as up to two overlapping words a call, or sixteen bytes a
// round for a longer one, folded by a full multiply.
@(private)
name_hash :: #force_inline proc "contextless" (parent: u32, name: string) -> u64 #no_bounds_check {
	fold :: #force_inline proc "contextless" (x, y: u64) -> u64 {
		product := u128(x) * u128(y)
		return u64(product) ~ u64(product >> 64)
	}
	word :: #force_inline proc "contextless" (p: [^]u8, $T: typeid) -> u64 {
		return u64(intrinsics.unaligned_load((^T)(p)))
	}
	n := len(name)
	p := raw_data(name)
	h := u64(parent) * 0x9e3779b97f4a7c15 + u64(n)
	a, b: u64
	switch {
	case n > 16:
		i := 0
		for ; n - i > 16; i += 16 {
			h = fold(word(p[i:], u64) ~ 0xa0761d6478bd642f, word(p[i + 8:], u64) ~ h)
		}
		a, b = word(p[n - 16:], u64), word(p[n - 8:], u64)
	case n >= 8:
		a, b = word(p, u64), word(p[n - 8:], u64)
	case n >= 4:
		a, b = word(p, u32), word(p[n - 4:], u32)
	case n > 0:
		a = u64(p[0]) << 16 | u64(p[n >> 1]) << 8 | u64(p[n - 1])
	}
	return fold(a ~ 0xe7037ed1a0b428db, b ~ h ~ 0x8ebc6af09c88c6e3)
}

@(private)
find_child :: proc(t: ^Table_Tree, parent: u32, name: string) -> u32 #no_bounds_check {
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
	return index_find(t, parent, name)
}

// The member `name` of `parent` in the index, or NIL.
@(private)
index_find :: proc "contextless" (t: ^Table_Tree, parent: u32, name: string) -> u32 #no_bounds_check {
	tag := u32(name_hash(parent, name) >> 32)
	mask := len(t.index) - 1
	for i := int(tag) & mask;; i = (i + 1) & mask {
		slot := t.index[i]
		if slot == 0 {
			return NIL
		}
		if u32(slot >> 32) == tag {
			id := u32(slot) - 1
			if n := &t.nodes[id]; n.parent == parent && n.name == name {
				return id
			}
		}
	}
}

// Adds member `id` of `parent` to the index, which doubles when three slots in four are in use.
@(private)
index_insert :: proc(t: ^Table_Tree, parent, id: u32) -> bool #no_bounds_check {
	if 4 * (t.indexed + 1) > 3 * len(t.index) && !index_grow(t) {
		return false
	}
	tag := u32(name_hash(parent, t.nodes[id].name) >> 32)
	mask := len(t.index) - 1
	i := int(tag) & mask
	for t.index[i] != 0 {
		i = (i + 1) & mask
	}
	t.index[i] = u64(tag) << 32 | u64(id + 1)
	t.indexed += 1
	return true
}

// Makes the index twice as large, or `INDEX_SLOTS` when it is the first.
@(private)
index_grow :: #force_no_inline proc(t: ^Table_Tree) -> bool #no_bounds_check {
	old := t.index
	size := 2 * len(old) if len(old) > 0 else INDEX_SLOTS
	grown, err := make([]u64, size, t.allocator)
	if err != nil {
		return false
	}
	mask := size - 1
	for slot in old {
		if slot != 0 {
			i := int(u32(slot >> 32)) & mask
			for grown[i] != 0 {
				i = (i + 1) & mask
			}
			grown[i] = slot
		}
	}
	delete(old, t.allocator)
	t.index = grown
	return true
}

// Appends a node of `kind` under `parent`, its value token `value`, keyed by `part` but for an array element, whose
// `part` is nil. A keyed node joins the parent's lookup, the index once the parent holds more than `INDEXED_AFTER`
// members, when its earlier members join it too. A container node is refused past the depth limit,
// since its token opens a level.
@(private)
add_node :: proc(t: ^Table_Tree, parent: u32, part: ^Part, value: tape.Token, kind: Node_Kind, flags: bit_set[Flag; u8]) -> (id: u32, r: Tree_Refusal) #no_bounds_check {
	depth := t.nodes[parent].depth + 1
	if kind != .Scalar && depth + 1 > t.max_depth {
		return NIL, .Too_Deep
	}
	id = u32(len(t.nodes))
	if len(t.nodes) == cap(t.nodes) && !grow_nodes(t) {
		return NIL, .No_Memory
	}
	// The node is written in its slot, which the reservation left unwritten.
	(^runtime.Raw_Dynamic_Array)(&t.nodes).len += 1
	if kind != .Scalar {
		t.deepest = max(t.deepest, depth)
	}
	n := &t.nodes[id]
	n^ = Table_Node{value = value, parent = parent, first = NIL, last = NIL, next = NIL, depth = depth, kind = kind, flags = flags}
	if part != nil {
		n.key, n.name = part.tok, part.name
		t.keyed += 1
	}
	p := &t.nodes[parent]
	if p.last == NIL {
		p.first = id
	} else {
		t.nodes[p.last].next = id
	}
	p.last = id
	p.count += 1
	if part == nil || p.count <= INDEXED_AFTER {
		return id, .None
	}
	if p.count == INDEXED_AFTER + 1 {
		// The member that crossed the limit takes the earlier ones along.
		for m := p.first; m != NIL; m = t.nodes[m].next {
			if !index_insert(t, parent, m) {
				return NIL, .No_Memory
			}
		}
	} else if !index_insert(t, parent, id) {
		return NIL, .No_Memory
	}
	return id, .None
}

@(private, cold)
grow_nodes :: proc(t: ^Table_Tree) -> bool {
	return reserve(&t.nodes, 2 * cap(t.nodes)) == nil
}

// The member a dotted key's part `part` names in table `cur`, which the key creates when it is new, with its token at
// `lo`, the key part after it. An existing one is reached only when a dotted key made it.
@(private)
dotted_step :: proc(t: ^Table_Tree, cur: u32, part: ^Part, lo: u64) -> (id: u32, first: bool, r: Tree_Refusal) #no_bounds_check {
	id = find_child(t, cur, part.name)
	if id == NIL {
		id, r = add_node(t, cur, part, {lo = lo, kind = .Object, spelling = STYLE_DOTTED}, .Table, {.Dotted})
		return id, true, r
	}
	n := &t.nodes[id]
	if n.kind != .Table || .Dotted not_in n.flags {
		return NIL, false, .Inline if .Inline in n.flags else .Duplicate
	}
	return id, false, .None
}

// The scalar slot a key's last part names in table `cur`. The value is set once it has been read.
@(private)
leaf_key :: proc(t: ^Table_Tree, cur: u32, part: ^Part) -> (id: u32, r: Tree_Refusal) #no_bounds_check {
	if find_child(t, cur, part.name) != NIL {
		return NIL, .Duplicate
	}
	return add_node(t, cur, part, {}, .Scalar, {})
}

// A table or array element a header's path passes through, a new table's token at `lo`, the key part after it. An
// array of tables continues in its last element.
@(private)
header_step :: proc(t: ^Table_Tree, cur: u32, part: ^Part, lo: u64) -> (id: u32, r: Tree_Refusal) #no_bounds_check {
	id = find_child(t, cur, part.name)
	if id == NIL {
		return add_node(t, cur, part, {lo = lo, kind = .Object}, .Table, {})
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

// The table a `[header]` ends in, which is new, with its token at `body`, the byte past the header, or a table only
// other headers' paths made, which keeps its token as a walk may have given it. `heads` says whether the comments
// above the header are the table's: false once a walk gave its key, as they would come after it.
@(private)
header_leaf :: proc(t: ^Table_Tree, cur: u32, part: ^Part, body: u64) -> (id: u32, heads: bool, r: Tree_Refusal) #no_bounds_check {
	id = find_child(t, cur, part.name)
	if id == NIL {
		id, r = add_node(t, cur, part, {lo = body, kind = .Object}, .Table, {.Header})
		return id, true, r
	}
	n := &t.nodes[id]
	if n.kind != .Table {
		return NIL, false, .Duplicate
	}
	if n.flags - {.Given} != {} {
		return NIL, false, .Inline if .Inline in n.flags else .Redefined
	}
	heads = .Given not_in n.flags
	n.flags = {.Header}
	return id, heads, .None
}

// The new element table of the array of tables a `[[header]]` at `start` ends in, its token at `body`, the byte past
// the header.
@(private)
array_leaf :: proc(t: ^Table_Tree, cur: u32, part: ^Part, start, body: u64) -> (id: u32, r: Tree_Refusal) #no_bounds_check {
	array := find_child(t, cur, part.name)
	if array == NIL {
		array, r = add_node(t, cur, part, {lo = start, kind = .Array}, .Array, {.Tables})
		if r != .None {
			return NIL, r
		}
	} else if n := &t.nodes[array]; n.kind != .Array || .Tables not_in n.flags {
		return NIL, .Static if n.kind == .Array else .Duplicate
	}
	t.extended = array
	return add_node(t, array, nil, {lo = body, kind = .Object}, .Table, {.Header})
}

// A comment into the tree's list. Returns false when the list cannot grow.
@(private)
push_comment :: proc(t: ^Table_Tree, c: Comment) -> bool {
	_, err := append(&t.comments, c)
	return err == nil && reserve_notes(t)
}

// Makes room for the notes of one more node. A node's notes are made by a comment, so a tree holds no more of them than
// comments and inline comments, and `notes_for` never allocates past this.
@(private)
reserve_notes :: proc(t: ^Table_Tree) -> bool {
	need := len(t.comments) + t.inlines + 1
	return need <= cap(t.notes) || reserve(&t.notes, max(need, 2 * cap(t.notes))) == nil
}

// The notes of node `id`, made on first use.
@(private)
notes_for :: proc(t: ^Table_Tree, id: u32) -> ^Notes #no_bounds_check {
	n := &t.nodes[id]
	if n.notes == 0 {
		append(&t.notes, Notes{})
		n.notes = u32(len(t.notes))
	}
	return &t.notes[n.notes - 1]
}

// Where the node `id` of `t`, a tree of `src`, ends: after a value's closing quote, at the close of a container in
// brackets or braces, and for any other table where its last member ends, or where its token is.
@(private)
end_of :: proc "contextless" (t: ^Table_Tree, src: []u8, id: u32) -> u64 {
	x := id
	for {
		n := &t.nodes[x]
		switch {
		case n.kind == .Scalar:
			_, tail := bounds(src, n.value)
			return n.value.lo + u64(n.value.n) + u64(tail)
		case n.value.spelling == STYLE_INLINE:
			return n.value.lo + u64(n.value.n) + 1
		case n.last == NIL:
			return n.value.lo
		}
		x = n.last
	}
}

// The notes of node `id`, empty for a node with no comment.
@(private)
notes_of :: #force_inline proc "contextless" (t: ^Table_Tree, id: u32) -> Notes #no_bounds_check {
	n := t.nodes[id].notes
	return t.notes[n - 1] if n != 0 else {}
}
