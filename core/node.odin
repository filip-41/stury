package core

import "base:runtime"
import spell "./spell"

// A document node's bytes, its text and numbers, its key compare, and the iterators over a container's members.

// Returns the byte span of node `i`: a scalar's token, or a container's opening through its closing bytes. The
// close is not a node, so it comes from `root_close` for the root and the format's `close_end` otherwise, which
// skips the whitespace and comments after the container's last descendant. A node past the last returns nil.
span :: #force_inline proc(doc: ^Document, i: Node_Index) -> []u8 {
	if int(i) >= len(doc.nodes) {
		return nil
	}
	n := doc.nodes[i]
	#partial switch n.kind {
	case .Array, .Object:
		if i == ROOT && doc.root_close != 0 {
			return doc.src[n.lo:doc.root_close]
		}
		return doc.src[n.lo:doc.readers.close_end(doc, i)]
	case:
		lo, hi := scalar_ends(n)
		return doc.src[lo:hi]
	}
}

// Returns the first byte and the byte past scalar token `t` as authored. A quoted JSON string's token leaves its quote
// pair out, and splicing needs the bytes as written.
scalar_ends :: #force_inline proc "contextless" (t: Token) -> (lo, hi: u64) {
	lo, hi = t.lo, t.lo + u64(t.n)
	if t.kind == .String && t.spelling & SPELLING_QUOTED != 0 {
		lo -= 1
		hi += 1
	}
	return
}

// Returns the first source byte of node `n`. A quoted string's token starts one byte past its opening quote.
node_start :: #force_inline proc(n: Node) -> u64 {
	lo, _ := scalar_ends(n)
	return lo
}

// Returns the distance from node `i` to the next node in preorder: its subtree size for a container, 1 for a
// scalar.
subtree_size :: #force_inline proc "contextless" (doc: ^Document, i: Node_Index) -> int {
	n := doc.nodes[i]
	return int(n.n) if n.kind == .Array || n.kind == .Object else 1
}

// Returns the bytes of node `n`'s text, for a node that needs no decoding. A string token leaves its quote pair
// out, an unquoted key is bare, and a dsv cell's span is its text: a quote in a TSV cell is a byte of the cell.
// `text`, `key_equals` and the duplicate rule read a node's text through this function, and none reads
// `src` to find a quote.
@(private)
node_text :: #force_inline proc(src: []u8, n: Node) -> []u8 {
	return src[n.lo:n.lo + u64(n.n)]
}

// Whether key node `i` decodes to `name`. A node whose `SPELLING_DECODE` bit is clear is compared with
// `spell.bytes_equal`, else through the format's `key_equals`. A dsv header cell has role `Key` and names a column.
key_equals :: #force_inline proc "contextless" (doc: ^Document, i: Node_Index, name: string) -> bool {
	if int(i) >= len(doc.nodes) || doc.nodes[i].role != .Key {
		return false
	}
	n := doc.nodes[i]
	if n.spelling & SPELLING_DECODE == 0 {
		// A key node is a scalar, so its span lies inside the source.
		#no_bounds_check {
			return spell.bytes_equal(doc.src[n.lo:n.lo + u64(n.n)], transmute([]u8)name)
		}
	}
	return key_equals_decode(doc, i, name)
}

// Out of line, so the hot loop of `member` passes the document and index as before and holds no token.
@(private, cold)
key_equals_decode :: #force_no_inline proc "contextless" (doc: ^Document, i: Node_Index, name: string) -> bool {
	if doc.readers.key_is != nil {
		return doc.readers.key_is(doc, i, name)
	}
	return doc.readers.key_equals(&doc.view, doc.nodes[i], name)
}

// Returns the payload of byte string `i`. A node whose `SPELLING_DECODE` bit is clear is its span, borrowed from the
// source. A node that needs joining, a binary format's chunked string, is written into `buf` by the format's `text`,
// which `text_room` bytes always hold, and the call returns false when `buf` is too short. It allocates nothing.
// Returns false for any node that is not a byte string.
doc_bytes :: proc(doc: ^Document, i: Node_Index, buf: []u8) -> (b: []u8, ok: bool) {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind != .Bytes {
		return nil, false
	}
	n := doc.nodes[i]
	if n.spelling & SPELLING_DECODE == 0 {
		return node_text(doc.src, n), true
	}
	s, joined := doc.readers.text(&doc.view, n, buf)
	return transmute([]u8)s, joined
}

// Returns the decimal digits of number node `i`, a `Plain` node the format resolves to a number among them: its span
// for a format whose number span is the text, else what the format's `number_text` writes into `buf`, with false when
// `buf` is too short. An infinity or a NaN has no digits and returns an empty text. Returns false for a node that is
// no number.
doc_number_text :: proc(doc: ^Document, i: Node_Index, buf: []u8) -> (s: string, ok: bool) {
	if doc_kind(doc, i) != .Number {
		return "", false
	}
	n := doc.nodes[i]
	if doc.readers.number_text == nil {
		return string(node_text(doc.src, n)), true
	}
	return doc.readers.number_text(&doc.view, n, buf)
}

// Returns a length of `buf` that always holds `text`'s decode of node `i`, which may pass the text's own length, and 0
// for a node that needs no decode, a container and a node past the last.
text_room :: proc(doc: ^Document, i: Node_Index) -> int {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind > .Plain || doc.nodes[i].spelling & SPELLING_DECODE == 0 {
		return 0
	}
	return view_room(doc.readers, &doc.view, doc.nodes[i])
}

// The bytes that hold the decode of token `t` in `view`: the format's `room` when it has one, else what the token's
// spelling bits say.
view_room :: #force_inline proc(readers: ^Readers, view: ^Token_View, t: Token) -> int {
	room := decoded_room(t.spelling, int(t.n))
	if readers != nil && readers.room != nil {
		room = max(room, readers.room(view, t.lo, t.n))
	}
	return room
}

// Returns the bytes that hold the decode of a token of `n` span bytes with `spelling`. A decode never yields more
// bytes than its span, except that a tolerated ill-formed sequence reads as U+FFFD, three bytes for one source byte,
// and a token that holds one carries `SPELLING_LAX`, as a `SPELLING_SYNTHETIC` token does for its added bytes.
@(private)
decoded_room :: #force_inline proc "contextless" (spelling: u16, n: int) -> int {
	if spelling & (SPELLING_DECODE | SPELLING_LAX) == SPELLING_DECODE | SPELLING_LAX {
		return 3 * n + DECODE_SLACK
	}
	return n
}

// Returns token `t`'s text as `readers.text` gives it: its span when the token needs no decode, else a decode into a
// buffer allocated from `allocator`. Returns false for a refused allocation or a failed decode.
token_text :: proc(readers: ^Readers, view: ^Token_View, t: Token, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if t.spelling & SPELLING_DECODE == 0 {
		return string(node_text(view.src, t)), true
	}
	room := view_room(readers, view, t)
	buf, err := runtime.mem_alloc_non_zeroed(room, 1, allocator)
	if err != nil {
		return "", false
	}
	s, ok = readers.text(view, t, buf)
	if !ok {
		runtime.mem_free_with_size(raw_data(buf), room, allocator)
	}
	return s, ok
}

// Returns a copy of node `i`'s decoded text, allocated from `allocator`. The result is the allocation the caller frees
// with `delete(s, allocator)`, for a text that needed no decode too, and its length is the allocation's length. A
// decode may write fewer bytes than the buffer it was given, so an over-long allocation is trimmed. Returns false for
// a container, a node past the last, or a refused allocation.
text_clone :: proc(doc: ^Document, i: Node_Index, allocator := context.allocator) -> (s: string, ok: bool) {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind > .Plain {
		return "", false
	}
	n := doc.nodes[i]
	size := view_room(doc.readers, &doc.view, n)
	raw, err := runtime.mem_alloc_non_zeroed(size, 1, allocator)
	if err != nil {
		return "", false
	}
	s, ok = text(doc, i, raw)
	if !ok {
		delete(raw, allocator)
		return "", false
	}
	if len(s) == 0 {
		// A text that decodes to no bytes, as a quoted empty dsv cell does, keeps no allocation. A resize to 0 is a free,
		// which an arena refuses.
		delete(raw, allocator)
		return "", true
	}
	if raw_data(s) != raw_data(raw) {
		// A format may answer with a span of its source instead of a decode into `buf`.
		copy(raw, s)
	}
	if len(s) != size {
		trimmed, rerr := runtime.non_zero_mem_resize(raw_data(raw), size, len(s), 1, allocator)
		if rerr != nil {
			delete(raw, allocator)
			return "", false
		}
		raw = trimmed
	}
	return string(raw[:len(s)]), true
}

// Returns the `i64` an `Int` node writes. Returns false for any other number.
int_value :: #force_inline proc(doc: ^Document, i: Node_Index) -> (i64, bool) {
	n, ok := number(doc, i)
	if !ok {
		return 0, false
	}
	switch n.kind {
	case .Int:
		return i64(n.bits), true
	case .Uint, .Float, .Wide:
	}
	return 0, false
}

// Returns the `f64` a number node writes: an `Int` or a `Uint` rounded once, and a `Float` as it is. `-0` keeps its
// sign. Returns false for a `Wide` number and a node that is no number.
float_value :: proc(doc: ^Document, i: Node_Index) -> (f64, bool) {
	n, ok := number(doc, i)
	if !ok || n.kind == .Wide {
		return 0, false
	}
	return number_f64(n, string(doc.src[doc.nodes[i].lo:])), true
}

// A `Child_Iter` walks one container's member values. `children` starts it and `child_next` returns the next value.
// For an `Object`, a value's key is the node before it.
Child_Iter :: struct {
	doc:    ^Document,
	parent: Node_Index,
	at:     Node_Index,
	end:    Node_Index,
	// The container is an inline-key `Object`, whose children are key/value pairs with a key of one node. A step skips the
	// value's span and then one node for the next key, with no role test: only a pair's first node is a key.
	pairs:  bool,
	done:   bool,
}

// Lists container `i`'s member values in `Document.indexed`, so `child_at` and `children_from` reach any member
// without a walk. Returns whether `i` is now read by position without a walk. A container whose members are one node
// each needs no entry. A scalar, a node past the last, a `Partial` container and a failed allocation give false. A
// container that could not be listed keeps an entry with no members, so a later call writes nothing and gives false.
// It writes the document, so nothing else may read `doc` during the call.
index_children :: proc(doc: ^Document, i: Node_Index) -> bool {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind != .Array && doc.nodes[i].kind != .Object || doc.nodes[i].role == .Partial {
		return false
	}
	n := doc.nodes[i]
	count := length(doc, i)
	if one_node_stride(doc, n, count) != 0 {
		return true
	}
	at := lower_node(doc.indexed[:], i)
	if at < len(doc.indexed) && doc.indexed[at].node == i {
		return doc.indexed[at].members != nil
	}
	// The entry goes in before its list, so a list that fails stays recorded as an entry with no members.
	doc.indexed.allocator = doc.allocator
	if _, err := inject_at(&doc.indexed, at, Child_Index{node = i}); err != nil {
		return false
	}
	members, merr := make([]Node_Index, count, doc.allocator)
	if merr != nil {
		return false
	}
	k := 0
	it := children(doc, i)
	for v in child_next(&it) {
		if k == len(members) {
			break
		}
		members[k] = v
		k += 1
	}
	// A count the walk disagrees with lists nothing.
	if k != count {
		delete(members, doc.allocator)
		return false
	}
	doc.indexed[at].members = members
	return true
}

// A `Child_Iter` over container `i`'s member values from the `k`th on. A `k` out of range, a scalar and a node past
// the last give a finished iterator.
children_from :: proc(doc: ^Document, i: Node_Index, k: int) -> Child_Iter {
	it := children(doc, i)
	if k == 0 || it.done {
		return it
	}
	if v, ok := child_at(doc, i, k); ok {
		it.at = v
	} else {
		it.done = true
	}
	return it
}

// A `Member_Iter` walks every member of `obj` whose key decodes to `name`, in source order. A headed dsv record is a
// `Object`, and its members are its cells. Column `i`'s key is header cell `i`, and a cell past the header's last
// matches no key. A cell's node is its record's node plus one plus its column.
Member_Iter :: struct {
	doc:  ^Document,
	at:   Node_Index,
	end:  Node_Index,
	name: string,
	rec:  Node_Index, // the headed record whose cells are read, NO_NODE for a JSON object
	done: bool,
}

members_named :: proc(doc: ^Document, obj: Node_Index, name: string) -> Member_Iter {
	if int(obj) >= len(doc.nodes) || doc.nodes[obj].kind != .Object {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	if keys := header_of(doc); keys != 0 {
		return {doc = doc, at = keys + 1, end = keys + Node_Index(doc.nodes[keys].n), name = name, rec = obj}
	}
	return {doc = doc, at = obj + 1, end = obj + Node_Index(doc.nodes[obj].n), name = name, rec = NO_NODE}
}

// Returns the next member and is inlined at `member`, so the object step needs no iterator load or store between
// members. A headed record is passed to `member_next_shared`.
member_next :: #force_inline proc(it: ^Member_Iter) -> (Node_Index, bool) {
	if it.rec != NO_NODE {
		return member_next_shared(it)
	}
	for !it.done {
		j := int(it.at)
		if j >= int(it.end) {
			it.done = true
			break
		}
		// An object's children alternate key and value, and a key is one node, so the value follows the key
		// directly and the next member's key follows the value's own span.
		v := j + 1
		it.at = Node_Index(v + subtree_size(it.doc, Node_Index(v)))
		if key_equals(it.doc, Node_Index(j), it.name) {
			return Node_Index(v), true
		}
	}
	return NO_NODE, false
}

// A `Pair_Iter` walks every (key, value) member pair of an `Object` container. `pairs` starts it and `pair_next` returns
// each pair in source order.
Pair_Iter :: struct {
	doc:     ^Document,
	key_at:  Node_Index,
	val_at:  Node_Index,
	key_end: Node_Index,
	val_end: Node_Index,
	shared:  bool,
	done:    bool,
}
