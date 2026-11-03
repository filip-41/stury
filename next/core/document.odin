package core

import "base:runtime"
import "core:io"
import spell "./spell"

// A document holds a walk's tokens in walk order, 16 bytes per node, plus the facts beside them. `core/build`'s
// builder writes one from a walk's hooks, instantiated per format and spec by the format's `build`, so every format
// shares the document and reader code.

// A document node is the token the walk gave, with a container's `n` and `spelling` patched at its close:
//
//	- a scalar is its token, `n` its byte length,
//	- a container's `n` is its subtree's node count, its own node included, and the document holds no close node,
//	  so its next sibling is `i + n`,
//	- a container's `spelling` is its child count, where a member counts once, not its key and value.
//	  The count saturates at `MAX_CHILDREN`, and `Document.counts` holds the true count when it does.
//	- a document holds no `End` node: the walk still emits one, and the builder consumes it.
Node :: Token

// The largest child count a container's `spelling` holds. A container with more children stores this value.
MAX_CHILDREN :: u16(0xFFFF)

// A node's index in a document's `nodes` array.
Node_Index :: distinct u32

// "No such node": answer on a miss. A node index never takes it.
NO_NODE :: Node_Index(max(u32))
// The root value's node is node 0.
ROOT :: Node_Index(0)

// Bit 0 of a string, key or dsv cell's `spelling` is set when its text is read through the format's `text`, which
// decodes it or, for a quoted dsv cell with no `""`, returns its inner span. A reader tests it before the call. An unmarked node's span is its text: a JSON string's token leaves its quote pair out,
// an unquoted JSON5 key is bare, and a dsv cell's span is its source bytes.
SPELLING_DECODE :: u16(1)
// Bit 1 of a JSON string or a dsv cell is set when the token is quoted. A JSON string's token span is the bytes
// between its quotes, so `span` adds the pair back. A quoted dsv cell's span already holds them.
SPELLING_QUOTED :: u16(2)
// Bit 2 of a JSON string is set when it holds an ill-formed UTF-8 sequence that `Invalid_Utf8` reads as U+FFFD, so its
// decode may grow past its span.
SPELLING_LAX :: u16(4)

// A `Fact` holds a comment token, the node it belongs to and its role. Facts are sorted by the node they belong to,
// and two facts of one node keep their source order. `lo` is the first byte and `n` the span's length, markers
// included. `spelling`'s low byte is the marker's lead length and the next byte its tail length, so core slices a body
// without knowing a format's markers. A `//` comment leads with two bytes and trails none, a `/* */` comment leads and
// trails with two, and a delimited text's comment line leads with one.
Fact :: struct {
	lo:       u64,
	node:     Node_Index,
	n:        u32,
	role:     Role,
	spelling: u16,
}

// A container's true child count, kept when `spelling` saturates at `MAX_CHILDREN`. `Document.counts` holds these,
// sorted by node.
Child_Count :: struct {
	node:  Node_Index,
	count: u32,
}

// How the text was read: its spec, three opaque format option bytes, and the build's depth. Every edit service
// reads it to judge a text and to spell its output.
Read_As :: struct {
	// The spec the text was read as, which the edit dispatcher reads. A format may point every spec at one spelling
	// table and dispatch its edit services on this byte.
	spec: u8,
	// Opaque format bytes, passed along unread by core. A format packs its run-time options into these bytes.
	opts: [3]u8,
	// The build's `Options.max_depth`, 0 for the default. The edit services read a value text at this depth, and a
	// text built deeper than the default can be edited.
	max_depth: u32,
}

// 8 bytes: the spec, the three option bytes and the depth word.
#assert(size_of(Read_As) == 8)

// A `Pair_Iter` walks every (key, value) member pair of a `Map` container. `pairs` starts it and `pair_next` returns
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

// Starts a `Pair_Iter` over the key/value pairs of `obj`. On a non-`Map` container, a scalar, or an index past the last
// node, returns an empty iterator.
pairs :: proc(doc: ^Document, obj: Node_Index) -> Pair_Iter {
	if int(obj) >= len(doc.nodes) {
		return {doc = doc, done = true}
	}
	n := doc.nodes[obj]
	if n.kind != .Map {
		return {doc = doc, done = true}
	}
	if doc.shared_keys != 0 {
		h := doc.nodes[doc.shared_keys]
		it := Pair_Iter{
			doc     = doc,
			key_at  = doc.shared_keys + 1,
			val_at  = obj + 1,
			key_end = doc.shared_keys + Node_Index(h.n),
			val_end = obj + Node_Index(n.n),
			shared  = true,
		}
		if it.key_at >= it.key_end || it.val_at >= it.val_end {
			it.done = true
		}
		return it
	}
	it := Pair_Iter{
		doc     = doc,
		key_at  = obj + 1,
		val_at  = obj + 2,
		key_end = obj + Node_Index(n.n),
		val_end = obj + Node_Index(n.n),
		shared  = false,
	}
	if it.key_at >= it.key_end {
		it.done = true
	}
	return it
}

// Returns the next key and value node of the `Map`. For an inline-key `Map`, key and value alternate in preorder.
// For a shared-key `Map`, keys come from `doc.shared_keys` while values advance within `obj`.
pair_next :: #force_inline proc(it: ^Pair_Iter) -> (key, val: Node_Index, ok: bool) {
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
		if n.kind == .Array || n.kind == .Map {
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
	if n.kind == .Array || n.kind == .Map {
		next_k = subtree_step(int(v), n.n)
	}
	it.key_at = Node_Index(next_k)
	return k, v, true
}

// What a format's token readers need besides the token: the source it spans, the format's table and how the text was
// read. A document starts with one, and a typed read holds one for the walk's tokens.
Token_View :: struct {
	src:      []u8,
	spelling: ^Spelling,
	read:     Read_As,
}

// A `Document` holds the walk's tokens over the caller's bytes, the facts beside them, and the format's `Spelling`
// table. `src` is borrowed and must outlive the document. `nodes_alloc` is the allocation behind `nodes`, whose length
// is its capacity, so `destroy` frees it after `nodes` shrank to the node count.
//
// A format whose root members share their keys keeps those keys as the root's first child, an `Array` of role `Key`, so
// the root's readers step over it as they step over a member's key. `shared_keys` is that `Array`'s node, and its
// children, at `shared_keys + 1` on, are the keys of every member `Map`: a `Map`'s `i`th value has key `i`. It is 0 for
// a document with no shared keys, for every JSON text, and for a dsv text read without a header.
Document :: struct {
	using view:  Token_View,
	nodes:       []Node,
	nodes_alloc: []Node,
	facts:       []Fact,
	facts_alloc: []Fact,
	allocator:   runtime.Allocator,
	shared_keys: Node_Index,
	// The byte just past the root value's authored bytes: the close of a root container, or the end of a root scalar,
	// quotes included. 0 when the build did not record it. `span(ROOT)` and a whole-document writer read it instead
	// of calling the format's `close_end`.
	root_close:  u64,
	// The true child count of every container whose count saturated `MAX_CHILDREN`, sorted by node, and the
	// allocation behind it. It is empty when no container is that wide.
	counts:       []Child_Count,
	counts_alloc: []Child_Count,
	// What a read by paths gives beside its nodes, in one block. `partial` says the document holds only what the paths
	// reached, and `stopped` that the read stopped early, so the containers it left open have a `Partial` role, the count
	// of what was read, and text past the stop that no walk judged. See `core/path.odin`.
	answers:      []Answer,
	kept:         []Kept_Child,
	missing:      []Missing_Name,
	reads_block:  []u8,
	partial:      bool,
	stopped:      bool,
	// The records of a partial document are positional, as a dsv record's cells are. A built document says it by `shared_keys`.
	positional:   bool,
}

// A number token's `spelling` holds these fields. A format's spelling kinds are even, so bit 0 (`SPELLING_DECODE`) is
// always clear.
//
//	bits 0 to 3   the format's number kind, 0 for its plain decimal
//	bits 4 to 8   the integer digit count (saturated at 31)
//	bits 9 to 13  the fraction digit count (saturated at 31, 0 for no fraction)
//	bit 14        `NUMBER_EXP`
//
// A pure integer is a decimal with no fraction and no exponent, so a reader folds its significand without lexing the
// span.
NUMBER_KIND_MASK :: u16(0xF)
NUMBER_INT_SHIFT :: 4
NUMBER_FRAC_SHIFT :: 9
NUMBER_FRAC_MAX :: 31
NUMBER_FRAC_MASK :: u16(NUMBER_FRAC_MAX) << NUMBER_FRAC_SHIFT
NUMBER_EXP :: u16(1 << 14)
NUMBER_DIGITS_MAX :: 31

// Returns a number token's integer digit count, and the count plus 32 or more when it has a fraction or an exponent.
number_shape :: #force_inline proc "contextless" (spelling: u16) -> u16 {
	return spelling >> NUMBER_INT_SHIFT
}

// Returns a number token's fraction digit count and its integer and fraction digit counts' sum, or at least 256 for the
// sum when it has an exponent.
number_digits :: #force_inline proc "contextless" (spelling: u16) -> (frac, sum: u16) {
	frac = spelling >> NUMBER_FRAC_SHIFT & u16(NUMBER_FRAC_MAX)
	sum = (spelling >> NUMBER_INT_SHIFT & u16(NUMBER_DIGITS_MAX)) + frac
	return frac, sum | (spelling & NUMBER_EXP) >> 6
}

// How a reader treats an object's repeated keys. `.Last` is the default.
Duplicates :: enum u8 {
	First,
	Last,
}

// Holds the options `resolve` reads besides the node.
Resolve_Options :: struct {
	// dsv: an unquoted cell that is empty, `true`, `false` or exactly a JSON number reads as Null, True, False or
	// Number. False, the default, makes every value cell a String.
	infer: bool,
}

// A `Spelling` holds a format's read services, in its rodata. `text` decodes a node's text into `buf` and returns false
// when `buf` is too short, so a read never allocates. A node whose `SPELLING_DECODE` bit is clear is its span without
// the quotes that surround it. `key_equals` compares a key without allocating. `number` reads a number token.
// `resolve` returns what a `Plain` node is. `close_end` returns the byte just past a container's closing bytes, found
// from its last descendant or its open, over the whitespace and comments the format allows there, the root's close is
// `Document.root_close`, so a service may return it without a scan. `edit` points at the
// format's edit services, nil for a format that accepts no edits. `tag_key` is the format's own struct tag key, and
// `key_open` and `key_close` are what a key is written between, empty for a format whose keys a typed read does not
// compare as text. `write` writes a node of the document as text of the spec and layout `read` names, into a buffer from `allocator` or to
// `stream`, nil for a format with no document writer, see `core.write`. `tokens` is the format's `^write.Token_Spelling`,
// nil for a format with no token writer. `records` is the format's `^records.Services`, nil for a format with no record
// reader. Both are a `rawptr` since `core/write` and `core/records` import `core`, and each is cast back to that type
// unchecked, so a format sets them to a table of exactly that type or leaves them nil.
Spelling :: struct {
	text:       proc(v: ^Token_View, t: Token, buf: []u8) -> (s: string, ok: bool),
	key_equals: proc "contextless" (v: ^Token_View, t: Token, name: string) -> bool,
	number:     proc(v: ^Token_View, t: Token) -> Number,
	resolve:    proc(doc: ^Document, i: Node_Index, opts: Resolve_Options) -> Kind,
	close_end:  proc(doc: ^Document, i: Node_Index) -> u64,
	query:      proc(doc: ^Document, paths: []Path, read: Query_Options, allocator: runtime.Allocator) -> (answers: []Answer, err: Path_Error),
	edit:       ^Edit_Spelling,
	write:      proc(doc: ^Document, opts: Write_Options, read: Read_As, node: Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, int, Typed_Error),
	tokens:     rawptr,
	records:    rawptr,
	tag_key:    string,
	key_open:   string,
	key_close:  string,
}

// An `Edit_Spelling` holds a format's edit services. A document's `Spelling` points at one table, and the services
// dispatch on the document's `spec` and `opts`. `value` checks a text as exactly one value of the format and
// spec, and `key_text` writes a decoded member name in the format's own spelling, quotes and escapes included. A member
// insert's key and a key set take a decoded name, so no service judges a key. `reads` is the format's own read of a text
// with or without its tolerance set, for the check a commit makes, under the output spec `spec`. Each service receives
// the document, so it reads the run-time options the document holds. A text that is no value answers `.Bad_Value`, with
// the walk's fault in `inner` where there is one, and `.No_Memory` when the service could not allocate.
//
// `member_sep` is what is written between two members of a container, and `key_sep` between a member's key and its
// value. `comment` says how the output spells a comment under `spec` and is nil for a format that accepts no comment.
// `insert_check` holds a format's rules on what a container takes.
//
// `commit` writes a list's edits as spec byte `spec`, which `core.commit` passes as the document's own: a format points it
// at `core/compose`'s commit. `flat` says a text has no brackets, so a container has no bytes of its own.
//
// A flat format also supplies the rest. `interior` returns the bytes a container's members lie in, `fact_slot` says whether the output holds a fact of a role on a node, and `emptied` whether a list
// removes every member of the root. `plan` runs first on a commit and may turn the whole list into plain edits, which
// `out` receives with their texts borrowed or allocated with `allocator`, and it returns false to keep the list as it is.
Edit_Spelling :: struct {
	value:         proc(v: ^Token_View, src: []u8, allocator: runtime.Allocator) -> Document_Error,
	key_text:      proc(doc: ^Document, name: []u8, text: ^[dynamic]u8) -> bool,
	reads:         proc(doc: ^Document, src: []u8, tolerate: bool, spec: u8) -> (fault: Fault, faulted: bool),
	comment:       proc(doc: ^Document, spec: u8) -> (style: Comment_Spelling, b: u8),
	member_sep:    proc(doc: ^Document) -> string,
	key_sep:       string,
	insert_check:  proc(doc: ^Document, container: Node_Index, text: string, allocator: runtime.Allocator) -> Document_Error,
	interior:      proc(doc: ^Document, c: Node_Index) -> (lo, hi: u64),
	fact_slot:     proc(doc: ^Document, node: Node_Index, role: Role, emptied: bool) -> bool,
	emptied:       proc(doc: ^Document, list: ^Edit_List) -> bool,
	plan:          proc(doc: ^Document, list: ^Edit_List, out: ^[dynamic]Edit, allocator: runtime.Allocator) -> (changed: bool, err: Document_Error),
	commit:        proc(list: ^Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: Document_Error),
	flat:          bool,
}

// A `Comment_Spelling` names how a format spells a comment in an output: `//` for a JSON spec that has comments, the
// document's comment byte for a delimited text, or none. Under `Line`, a body holding a line end is written in the
// block form `/* */`, so a line comment's body cannot end its line early.
Comment_Spelling :: enum u8 {
	None,
	Line,
	Byte,
}

// Frees `doc`'s node, fact and child-count allocations and sets `doc` to the zero value.
destroy :: proc(doc: ^Document) {
	if doc.nodes_alloc != nil {
		delete(doc.nodes_alloc, doc.allocator)
	}
	if doc.facts_alloc != nil {
		delete(doc.facts_alloc, doc.allocator)
	}
	if doc.counts_alloc != nil {
		delete(doc.counts_alloc, doc.allocator)
	}
	if doc.reads_block != nil {
		delete(doc.reads_block, doc.allocator)
	}
	doc^ = {}
}

// Returns the kind of node `i`, or `.Null` when `i` is past the last node.
kind :: #force_inline proc(doc: ^Document, i: Node_Index) -> Kind {
	if int(i) >= len(doc.nodes) {
		return .Null
	}
	return doc.nodes[i].kind
}

// Returns the byte span of node `i`: a scalar's token, or a container's opening through its closing bytes. The
// close is not a node, so it comes from `root_close` for the root and the format's `close_end` otherwise, which
// skips the whitespace and comments after the container's last descendant. A node past the last returns nil.
span :: #force_inline proc(doc: ^Document, i: Node_Index) -> []u8 {
	if int(i) >= len(doc.nodes) {
		return nil
	}
	n := doc.nodes[i]
	#partial switch n.kind {
	case .Array, .Map:
		if i == ROOT && doc.root_close != 0 {
			return doc.src[n.lo:doc.root_close]
		}
		return doc.src[n.lo:doc.spelling.close_end(doc, i)]
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

// Returns one past the line end at `pos`: LF, CR, or U+2028 or U+2029. Returns `pos` when no line end starts there.
// The edit list uses this rule.
line_end_len :: proc(src: []u8, pos: u64) -> u64 {
	if pos >= u64(len(src)) {
		return pos
	}
	switch src[pos] {
	case '\n':
		return pos + 1
	case '\r':
		return pos + 2 if pos + 1 < u64(len(src)) && src[pos+1] == '\n' else pos + 1
	}
	if pos + 2 < u64(len(src)) && src[pos] == 0xE2 && src[pos+1] == 0x80 && src[pos+2] | 1 == 0xA9 {
		return pos + 3
	}
	return pos
}

// Returns the number of members in container `i`, from its `spelling`, or 0 for a scalar or a node past the last.
// A count that saturated `MAX_CHILDREN` is read from `Document.counts`.
length :: #force_inline proc(doc: ^Document, i: Node_Index) -> int {
	if int(i) >= len(doc.nodes) {
		return 0
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Map {
		return 0
	}
	if n.spelling != MAX_CHILDREN {
		return int(n.spelling)
	}
	return wide_length(doc, i)
}

// Returns the true child count of container `i` from `Document.counts`, which holds it because `spelling` saturated.
@(private, cold)
wide_length :: #force_no_inline proc(doc: ^Document, i: Node_Index) -> int {
	at := lower_node(doc.counts, i)
	return int(doc.counts[at].count) if at < len(doc.counts) && doc.counts[at].node == i else 0
}

// Returns the distance from node `i` to the next node in preorder: its subtree size for a container, 1 for a
// scalar.
@(private)
skip :: #force_inline proc(doc: ^Document, i: Node_Index) -> int {
	n := doc.nodes[i]
	return int(n.n) if n.kind == .Array || n.kind == .Map else 1
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
	if int(i) >= len(doc.nodes) {
		return false
	}
	n := doc.nodes[i]
	if n.role != .Key {
		return false
	}
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
	return doc.spelling.key_equals(&doc.view, doc.nodes[i], name)
}

// Returns the first source byte of node `n`. A quoted string's token starts one byte past its opening quote.
node_start :: #force_inline proc(n: Node) -> u64 {
	if n.kind == .String && n.spelling & SPELLING_QUOTED != 0 {
		return n.lo - 1
	}
	return n.lo
}

// Returns container `i`'s `k`th member value, counted from 0: for an inline-key `Map`, the value after its `k`th key,
// which is the node after the key. A `k` past the last member, a negative `k`, and a node that holds no members return no
// node. A container whose members are one node each is indexed, since its subtree size gives the stride: an
// `Array`'s is its member count plus one, a shared-key `Map`'s its count plus one, and an inline-key `Map`'s twice its count plus one. Any other container is walked,
// stepping one subtree size per member. A count that saturated `MAX_CHILDREN` is read from `Document.counts`, so
// the stride test uses the true member count.
child_at :: #force_inline proc(doc: ^Document, i: Node_Index, k: int) -> (Node_Index, bool) {
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
	#partial switch n.kind {
	case .Map:
		if doc.shared_keys == 0 {
			if int(n.n) == 2 * count + 1 {
				return i + Node_Index(2 + 2 * k), true
			}
		} else {
			if int(n.n) == count + 1 {
				return i + Node_Index(1 + k), true
			}
		}
	case .Array:
		// The dsv header row is a child of the root that names no member, so a root with one is walked.
		if int(n.n) == count + 1 {
			return i + Node_Index(1 + k), true
		}
	case:
		return NO_NODE, false
	}
	return child_at_walk(doc, i, k)
}

// Walks a container whose members are not all one node. `child_at` calls it for a container whose subtree size does
// not give one node per member.
@(private, cold)
child_at_walk :: #force_no_inline proc(doc: ^Document, i: Node_Index, k: int) -> (Node_Index, bool) {
	it := children(doc, i)
	for _ in 0 ..< k {
		if _, ok := child_next(&it); !ok {
			return NO_NODE, false
		}
	}
	v, ok := child_next(&it)
	return v, ok
}

// A `Child_Iter` walks one container's member values. `children` starts it and `child_next` returns the next value.
// For a `Map`, a value's key is the node before it.
Child_Iter :: struct {
	doc:    ^Document,
	parent: Node_Index,
	at:     Node_Index,
	end:    Node_Index,
	// The container is an inline-key `Map`, whose children are key/value pairs with a key of one node. A step skips the
	// value's span and then one node for the next key, with no role test: only a pair's first node is a key.
	pairs:  bool,
	done:   bool,
}

children :: proc(doc: ^Document, i: Node_Index) -> Child_Iter {
	if int(i) >= len(doc.nodes) {
		return {doc = doc, parent = i, done = true}
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Map {
		return {doc = doc, parent = i, done = true}
	}
	it := Child_Iter{doc = doc, parent = i, end = i + Node_Index(n.n), pairs = n.kind == .Map && doc.shared_keys == 0}
	j := int(i) + 1
	if it.pairs {
		// The first member's key is one node.
		j += 1
	} else if n.role != .Key && j < int(it.end) && doc.nodes[j].role == .Key {
		// The dsv header row a root holds first. The key-role `Array` is that row, and it holds key cells, not
		// members.
		j += skip(doc, Node_Index(j))
	}
	if j >= int(it.end) {
		it.done = true
	} else {
		it.at = Node_Index(j)
	}
	return it
}

// Returns the step from `v` over a container's subtree, to the node after it. The call makes the kind test a
// `b.eq` with the load of `n` in the taken block: inlined, LLVM computes the stride with `csinc` from a load of
// `n` that the next member's address waits for.
@(private)
subtree_step :: #force_no_inline proc(v: int, n: u32) -> int {
	return v + int(n)
}

// Returns the next value of a container and is inlined at every call, so a call does not spill the iterator and
// re-read it per member.
child_next :: #force_inline proc(it: ^Child_Iter) -> (Node_Index, bool) {
	if it.done {
		return NO_NODE, false
	}
	v := it.at
	doc := it.doc
	n := doc.nodes[v]
	j := int(v) + 1
	if n.kind == .Array || n.kind == .Map {
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

// Returns the value of the member of `obj` whose key decodes to `name`, under `.First` or `.Last`. `members_named` yields
// every match. A headed dsv record's members are its cells, named by the header's cells.
member :: #force_inline proc(doc: ^Document, obj: Node_Index, name: string, dups := Duplicates.Last) -> (Node_Index, bool) {
	// A single loop handles both shapes: `member_next` is inlined, so an object's step uses this frame's registers.
	it := members_named(doc, obj, name)
	found := NO_NODE
	for {
		v, ok := member_next(&it)
		if !ok {
			return found, found != NO_NODE
		}
		if dups == .First {
			return v, true
		}
		found = v
	}
}

// A `Member_Iter` walks every member of `obj` whose key decodes to `name`, in source order. A headed dsv record is a
// `Map`, and its members are its cells. Column `i`'s key is header cell `i`, and a cell past the header's last
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
	if int(obj) >= len(doc.nodes) {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	n := doc.nodes[obj]
	if n.kind != .Map {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	if doc.shared_keys != 0 {
		h := doc.nodes[doc.shared_keys]
		return {doc = doc, at = doc.shared_keys + 1, end = doc.shared_keys + Node_Index(h.n), name = name, rec = obj}
	}
	return {doc = doc, at = obj + 1, end = obj + Node_Index(n.n), name = name, rec = NO_NODE}
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
		it.at = Node_Index(v + skip(it.doc, Node_Index(v)))
		if key_equals(it.doc, Node_Index(j), it.name) {
			return Node_Index(v), true
		}
	}
	return NO_NODE, false
}

// Returns the next of a shared-key `Map`'s values whose key decodes to `it.name`. The walk runs over the shared keys. A
// key past the `Map`'s last value matches nothing, so a short `Map`'s missing members are absent.
@(private)
member_next_shared :: #force_inline proc(it: ^Member_Iter) -> (Node_Index, bool) {
	width := int(it.doc.nodes[it.rec].n) - 1
	for !it.done {
		j := int(it.at)
		if j >= int(it.end) {
			it.done = true
			break
		}
		it.at = Node_Index(j + 1)
		col := j - int(it.doc.shared_keys) - 1
		if col < width && key_equals(it.doc, Node_Index(j), it.name) {
			return it.rec + Node_Index(1 + col), true
		}
	}
	return NO_NODE, false
}

// Returns the decoded text of string or plain node `i`. A node whose `SPELLING_DECODE` bit is clear is its span
// without its quotes. A node that needs decoding is written into `buf`, and the call returns false when `buf` is too
// short. It allocates nothing, so a caller that has no buffer long enough uses `text_clone`. Returns false for a
// container or a node past the last.
text :: #force_inline proc(doc: ^Document, i: Node_Index, buf: []u8) -> (s: string, ok: bool) {
	if int(i) >= len(doc.nodes) {
		return "", false
	}
	n := doc.nodes[i]
	// Only a scalar carries text: a container's `n` is a node count, not a byte length.
	if n.kind > .Plain {
		return "", false
	}
	if n.spelling & SPELLING_DECODE == 0 {
		return string(node_text(doc.src, n)), true
	}
	return doc.spelling.text(&doc.view, n, buf)
}

// Returns a copy of node `i`'s decoded text, allocated from `allocator`. The result is the allocation the caller frees
// with `delete(s, allocator)`, for a text that needed no decode too, and its length is the allocation's length. A
// decode may write fewer bytes than the buffer it was given, so an over-long allocation is trimmed. Returns false for
// a container, a node past the last, or a refused allocation.
text_clone :: proc(doc: ^Document, i: Node_Index, allocator := context.allocator) -> (s: string, ok: bool) {
	if int(i) >= len(doc.nodes) {
		return "", false
	}
	n := doc.nodes[i]
	if n.kind > .Plain {
		return "", false
	}
	if n.spelling & SPELLING_DECODE == 0 {
		raw, err := runtime.mem_alloc_non_zeroed(int(n.n), 1, allocator)
		if err != nil {
			return "", false
		}
		copy(raw, node_text(doc.src, n))
		return string(raw[:int(n.n)]), true
	}
	// A tolerated ill-formed sequence reads as U+FFFD, three bytes for one source byte, so three bytes per token byte
	// is an upper bound on the decoded length of every format's decode.
	size := 3 * int(n.n) + 4
	raw, err := runtime.mem_alloc_non_zeroed(size, 1, allocator)
	if err != nil {
		return "", false
	}
	s, ok = doc.spelling.text(&doc.view, n, raw)
	if !ok {
		delete(raw, allocator)
		return "", false
	}
	if len(s) > 0 && raw_data(s) != raw_data(raw) {
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

// Returns the number node `i` writes, decoded from its span. A container and an index past the last node return
// `.Wide`. The format's reader refuses a key or a string of its own.
number :: #force_inline proc(doc: ^Document, i: Node_Index) -> Number {
	if int(i) < len(doc.nodes) && doc.nodes[i].kind <= .Plain {
		return doc.spelling.number(&doc.view, doc.nodes[i])
	}
	return {0, .Wide}
}

// Returns what `Plain` node `i` is, through the format's `resolve`. A node of another kind returns its own kind,
// and an index past the last returns `.Null`.
resolve :: #force_inline proc(doc: ^Document, i: Node_Index, opts := Resolve_Options{}) -> Kind {
	if int(i) >= len(doc.nodes) {
		return .Null
	}
	return doc.spelling.resolve(doc, i, opts)
}

// Returns the `i64` an `Int` node writes. Returns false for any other number.
int_value :: #force_inline proc(doc: ^Document, i: Node_Index) -> (i64, bool) {
	n := number(doc, i)
	switch n.kind {
	case .Int:
		return i64(n.bits), true
	case .Uint, .Float, .Wide:
	}
	return 0, false
}

// Returns the `u64` a `Uint` node or a nonnegative `Int` node writes. Unmarshal reads unsigned targets with it.
uint_value :: #force_inline proc(doc: ^Document, i: Node_Index) -> (u64, bool) {
	n := number(doc, i)
	switch n.kind {
	case .Int:
		if i64(n.bits) >= 0 {
			return n.bits, true
		}
	case .Uint:
		return n.bits, true
	case .Float, .Wide:
	}
	return 0, false
}

// Returns the binary64 an `Int`, `Uint` or `Float` node writes. A `Wide` number has no decoded value in this tree, so
// the call returns false for it and the caller reads its span. Returns false for a node that is no number.
float_value :: #force_inline proc(doc: ^Document, i: Node_Index) -> (f64, bool) {
	n := number(doc, i)
	switch n.kind {
	case .Int:
		return f64(i64(n.bits)), true
	case .Uint:
		return f64(n.bits), true
	case .Float:
		return transmute(f64)n.bits, true
	case .Wide:
	}
	return 0, false
}

// Returns a walk over the bodies of node `i`'s facts of `role`, in source order, with `fact_next` giving one at a
// time. `NO_NODE` returns an empty walk. This is the public fact reader. A fact body is a slice of the source, so
// a read allocates nothing.
facts_of :: proc(doc: ^Document, i: Node_Index, role: Role) -> Fact_Iter {
	if i == NO_NODE {
		return {doc = doc, role = role}
	}
	return {doc = doc, at = lower_node(doc.facts, i), end = lower_node(doc.facts, i + 1), role = role}
}

// Returns the facts of node `i` and of every node in its subtree, all the document's for the root.
subtree_facts :: proc(doc: ^Document, i: Node_Index) -> []Fact {
	if i == ROOT {
		return doc.facts
	}
	t := doc.nodes[i]
	end := i + (1 if t.kind < .Array else Node_Index(t.n))
	return doc.facts[lower_node(doc.facts, i):lower_node(doc.facts, end)]
}

// Returns node `i`'s facts of every role, sorted by node and then source order. Core's edit and span code walk
// them, and a caller reads one role at a time through `facts_of`.
all_facts :: #force_inline proc(doc: ^Document, i: Node_Index) -> []Fact {
	if i == NO_NODE {
		return nil
	}
	lo := lower_node(doc.facts, i)
	hi := lower_node(doc.facts, i + 1)
	return doc.facts[lo:hi]
}

// A `Fact_Iter` walk reads the bodies of one node's facts of one role, in source order. `fact_next` returns one at a time.
Fact_Iter :: struct {
	doc:  ^Document,
	at:   int,
	end:  int,
	role: Role,
}

// Returns the next body without the markers its format writes: the fact's `spelling` gives the lead and tail
// lengths, and core reads the bytes between them without knowing any format's marker.
fact_next :: proc(it: ^Fact_Iter) -> (body: string, ok: bool) {
	for it.at < it.end {
		f := it.doc.facts[it.at]
		it.at += 1
		if f.role == it.role {
			return string(fact_body(it.doc, f)), true
		}
	}
	return "", false
}

@(private)
fact_body :: #force_inline proc(doc: ^Document, f: Fact) -> []u8 {
	lead := u64(f.spelling & 0xFF)
	tail := u64(f.spelling >> 8)
	return doc.src[f.lo + lead : f.lo + u64(f.n) - tail]
}

// Returns the index of the first entry of `entries`, which are sorted by `node`, whose node is not below `node`.
@(private)
lower_node :: proc(entries: []$E, node: Node_Index) -> int {
	lo, hi := 0, len(entries)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if entries[mid].node < node {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}
