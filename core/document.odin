package core

import "base:runtime"
import "core:io"
import "core:slice"
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

// A node of a document as a `Value`.
Node_Ref :: struct {
	doc:  ^Document,
	node: Node_Index,
}

// "No such node": answer on a miss. A node index never takes it.
NO_NODE :: Node_Index(max(u32))
// The root value's node is node 0.
ROOT :: Node_Index(0)

// Bit 0 of a string, key or dsv cell's `spelling` is set when its text is read through the format's `text`, which
// decodes it or, for a quoted dsv cell with no `""`, returns its inner span. A reader tests it before the call. An
// unmarked node's span is its text: a JSON string's token leaves its quote pair out, an unquoted JSON5 key is bare, and
// a dsv cell's span is its source bytes.
SPELLING_DECODE :: u16(1)
// Bit 1 of a JSON string or a dsv cell is set when the token is quoted. A JSON string's token span is the bytes
// between its quotes, so `span` adds the pair back. A quoted dsv cell's span already holds them.
SPELLING_QUOTED :: u16(2)
// Bit 2 is set on a JSON string or a dsv cell that holds an ill-formed UTF-8 sequence `Invalid_Utf8` reads as U+FFFD,
// so its decode may grow past its span.
SPELLING_LAX :: u16(4)

// The spelling bits of a text that holds an escape (`escaped`) or a sequence a tolerance accepted (`lax`):
// `SPELLING_DECODE` for either and `SPELLING_LAX` for the latter.
text_spelling :: #force_inline proc "contextless" (escaped, lax: bool) -> u16 {
	return (SPELLING_DECODE if escaped || lax else 0) | (SPELLING_LAX if lax else 0)
}

// The `spelling` of a comment token, from the length of its leading marker and of its trailing one. `Fact` documents
// the layout.
comment_spelling :: #force_inline proc "contextless" (lead, tail: u8) -> u16 {
	return u16(lead) | u16(tail) << 8
}

// The length of the leading marker of a comment token whose spelling is `spelling`.
comment_lead :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling & 0xFF)
}

// The length of the trailing marker of a comment token whose spelling is `spelling`.
comment_tail :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling >> 8)
}

// A `Fact` holds a comment or attribute token, the node it belongs to and its role. Facts are sorted by the node they
// belong to, and two facts of one node keep their source order. `lo` is the first byte and `n` the span's length,
// markers included. A comment's `spelling` has the marker's lead length in its low byte and its tail length in the
// next, so core slices a body without knowing a format's markers. A `//` comment leads with two bytes and trails none, a
// `/* */` comment leads and trails with two, and a delimited text's comment line leads with one. An attribute's
// `spelling` has the same layout: it leads through the value's opening quote and trails with the closing one, so its
// body is the value as written, and a valueless attribute leads with its whole span. Only a comment role is a comment:
// a writer or an edit that walks facts by their markers tests the role first.
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

// A container's member value nodes as `index_children` lists them: `members[k]` is what `child_at` returns for `k`.
// `members` is nil for a container `index_children` could not list.
Child_Index :: struct {
	node:    Node_Index,
	members: []Node_Index,
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

// What a format's token readers need besides the token: the source it spans and the handle it was read with. A document
// starts with one, and a typed read holds one for the walk's tokens.
Token_View :: struct {
	src:      []u8,
	using as: As,
}

// A `Document` holds the walk's tokens over the caller's bytes, the facts beside them, and the format's `Readers`
// table. `src` is borrowed and must outlive the document. `nodes_alloc` is the allocation behind `nodes`, whose length
// is its capacity, so `destroy` frees it after `nodes` shrank to the node count.
//
// A format whose root members share their keys keeps those keys as the root's first child, an `Array` of role `Key`, so
// the root's readers step over it as they step over a member's key. A `Table` says where that `Array` is, and its
// children, at `header + 1` on, are the keys of every member `Object`: an `Object`'s `i`th value has key `i`. `tables_of`
// is empty for every JSON text. A dsv text has one table, with no header when it is read without one.
Document :: struct {
	using view:  Token_View,
	nodes:       []Node,
	nodes_alloc: []Node,
	facts:       []Fact,
	facts_alloc: []Fact,
	allocator:   runtime.Allocator,
	tables_at:   [^]Table,
	// The byte just past the root value's authored bytes: the close of a root container, or the end of a root scalar,
	// quotes included. 0 when the build did not record it. `span(ROOT)` and a whole-document writer read it instead
	// of calling the format's `close_end`.
	root_close:  u64,
	// The true child count of every container whose count saturated `MAX_CHILDREN`, sorted by node, and the
	// allocation behind it. It is empty when no container is that wide.
	counts:       []Child_Count,
	counts_alloc: []Child_Count,
	// The containers `index_children` listed, sorted by node, in `allocator`. Each `members` is its own allocation.
	indexed:      [dynamic]Child_Index,
	// What a read by paths gives beside its nodes, in one block. `partial` says the document holds only what the paths
	// reached, and `stopped` that the read stopped early, so the containers it left open have a `Partial` role, the count
	// of what was read, and text past the stop that no walk judged. See `core/path.odin`.
	answers:      []Answer,
	kept:         []Kept_Child,
	missing:      []Missing_Name,
	reads_block:  []u8,
	partial:      bool,
	stopped:      bool,
	// Set by a build that gave every cell its kind, so a `Plain` cell is a string or null and resolves no further.
	kinds_stored: bool,
	n_tables:     u32,
}

// A container whose members are rows of cells. Rows are stored row by row: a row is its own node and then its `width`
// cells, so row `k` is at `first_row + k * (width + 1)` when `width` is not 0. `header` is the node of the `Array` of
// the shared keys, 0 for a table with none. A `width` of 0 means the rows have no common width (a ragged table, or a
// partial document's records), and `first_row` is then not read. The records of a table answer an `Index` as the cells
// of a dsv record do.
Table :: struct {
	node:      Node_Index,
	header:    Node_Index,
	first_row: Node_Index,
	width:     u32,
}

// The tables of a partial document, whose records are positional and whose rows have no common width.
@(rodata)
POSITIONAL_TABLES := [1]Table{{node = ROOT}}

// Returns the table whose rows are the members of container `node`, and whether `node` has one. The slice is empty for
// JSON, so the test is a length check.
table_of :: #force_inline proc "contextless" (doc: ^Document, node: Node_Index) -> (found: Table, ok: bool) {
	for table in tables_of(doc) {
		if table.node == node {
			return table, true
		}
	}
	return {}, false
}

// Returns the node of the shared keys `Array` that every `Object` of `doc` takes its keys from, or 0 when no `Object`
// has shared keys: every JSON text, and a dsv text read without a header.
header_of :: #force_inline proc "contextless" (doc: ^Document) -> Node_Index {
	return doc.tables_at[0].header if doc.n_tables != 0 else 0
}

// Returns the tables of `doc`. A document keeps a pointer and a count, which a slice's length would double in size.
tables_of :: #force_inline proc "contextless" (doc: ^Document) -> []Table {
	return doc.tables_at[:doc.n_tables]
}

// Sets the tables of `doc` to `tables`, which `doc` owns unless they are `POSITIONAL_TABLES`.
set_tables :: #force_inline proc "contextless" (doc: ^Document, tables: []Table) {
	doc.tables_at, doc.n_tables = raw_data(tables), u32(len(tables))
}

// Returns whether the tables of `doc` are an allocation of the document, which is every table slice but the rodata one of a
// partial document.
owns_tables :: #force_inline proc "contextless" (doc: ^Document) -> bool {
	return doc.n_tables != 0 && doc.tables_at != raw_data(POSITIONAL_TABLES[:])
}

// Returns whether the `Object`s of `doc` answer an `Index`, as a dsv record's cells do, which is whether `doc` has a table.
@(private)
positional :: #force_inline proc "contextless" (doc: ^Document) -> bool {
	return doc.n_tables != 0
}

// A number token's `spelling`. Kinds are even, so bit 0 (`SPELLING_DECODE`) is clear.
//
//	bits 0 to 3   the format's number kind: 0 for its plain decimal, `NUMBER_DECIMAL` for a decimal it writes with a
//	              sign or a point of its own, and above that a number whose text is not a decimal
//	bits 4 to 8   the integer digit count (saturated at 31)
//	bits 9 to 13  the fraction digit count (saturated at 31, 0 for no fraction)
//	bit 14        `NUMBER_EXP`
NUMBER_KIND_MASK :: u16(0xF)
NUMBER_DECIMAL :: u16(2)
NUMBER_EXP :: u16(1 << 14)
@(private)
NUMBER_INT_SHIFT :: 4
@(private)
NUMBER_FRAC_SHIFT :: 9
@(private)
NUMBER_DIGITS_MAX :: 31

#assert(NUMBER_INT_SHIFT + 5 <= NUMBER_FRAC_SHIFT && NUMBER_FRAC_SHIFT + 5 <= 14)

// Packs a decimal's number kind and its integer and fraction digit counts, each saturated at 31, into its `spelling`.
number_spelling :: #force_inline proc "contextless" (kind: u16, int_digits, frac_digits: u64) -> u16 {
	n := u16(min(int_digits, u64(NUMBER_DIGITS_MAX)))
	f := u16(min(frac_digits, u64(NUMBER_DIGITS_MAX)))
	return kind | n << NUMBER_INT_SHIFT | f << NUMBER_FRAC_SHIFT
}

// Returns a number token's integer and fraction digit counts, each saturated at 31.
number_digit_counts :: #force_inline proc "contextless" (spelling: u16) -> (int_digits, frac_digits: int) {
	return int(spelling >> NUMBER_INT_SHIFT & NUMBER_DIGITS_MAX), int(spelling >> NUMBER_FRAC_SHIFT & NUMBER_DIGITS_MAX)
}

// Returns a number token's integer digit count, and the count plus 32 or more when it has a fraction or an exponent.
number_shape :: #force_inline proc "contextless" (spelling: u16) -> u16 {
	return spelling >> NUMBER_INT_SHIFT
}

// Returns a number token's fraction digit count and its integer and fraction digit counts' sum, or at least 256 for the
// sum when it has an exponent.
number_digits :: #force_inline proc "contextless" (spelling: u16) -> (frac, sum: u16) {
	frac = spelling >> NUMBER_FRAC_SHIFT & u16(NUMBER_DIGITS_MAX)
	sum = (spelling >> NUMBER_INT_SHIFT & u16(NUMBER_DIGITS_MAX)) + frac
	return frac, sum | (spelling & NUMBER_EXP) >> 6
}

// How a read treats an object's repeated keys. `.Default` is the zero value and takes the format's own policy, which a
// format whose policy is not `.Last` resolves in its own entry points. `.Last` answers the last and `.First` the first. `.All` answers each of
// them, and `.Refuse` fails at a key that repeats one of its object's, at the second key's first byte. A read of one
// member, as `member` is, picks under `.All` and `.Refuse` as under `.Last`.
Duplicates :: enum u8 {
	Default,
	Last,
	First,
	All,
	Refuse,
}

// `Readers` holds what a read of a value needs of its format, in rodata. `text` decodes a node's text into `buf` and
// returns false when `buf` is too short, so a read never allocates. A node whose `SPELLING_DECODE` bit is clear is its
// span without the quotes that surround it. `key_equals` compares a key without allocating. `number` reads a number
// token, and returns false for a token that is no number of the format's. `number_f32` reads a number token whose kind
// is above `NUMBER_DECIMAL` into an f32 with one rounding, and returns false when narrowing `number`'s binary64 already
// rounds once. It is nil for a format with no such kinds. `resolve` returns what a `Plain` node is, and `resolves`
// whether it can return anything but `.String` for a node with bytes under handle `as`, nil for a format with no
// `Plain` nodes, so a writer asks once per text. `close_end` returns the byte just past a container's closing bytes,
// found from its last descendant or its open, over the whitespace and comments the format allows there, the root's
// close is `Document.root_close`, so a service may return it without a scan. `format` is the format's identity: one
// procedure for every spec of a format, which returns its fault table, so two tables compare equal when they read one
// format. `tag_key` is the format's own struct tag key, and `key_open` and `key_close` are what a key is written
// between, empty for a format whose keys a typed read does not compare as text. `flat` says a text has no brackets, so
// a container has no bytes of its own. `services` points at the run-time services of a handle, nil in a table that
// serves a read only. `attribute` gives an `Attribute` fact's name as a `Key` and its value as a `Value` token, each
// read through `text` and `key_equals` as a node's is: a value with references or one the format normalizes sets
// `SPELLING_DECODE`, and a valueless attribute's value is an empty `String`. It is nil for a format with no attributes,
// and `attributes_of` is its one caller.
Readers :: struct {
	text:       proc(v: ^Token_View, t: Token, buf: []u8) -> (s: string, ok: bool),
	key_equals: proc "contextless" (v: ^Token_View, t: Token, name: string) -> bool,
	number:     proc(v: ^Token_View, t: Token) -> (Number, bool),
	number_f32: proc(v: ^Token_View, t: Token) -> (f32, bool),
	resolve:    proc(doc: ^Document, i: Node_Index) -> Kind,
	resolves:   proc "contextless" (as: As) -> bool,
	close_end:  proc(doc: ^Document, i: Node_Index) -> u64,
	format:     proc "contextless" () -> ^Rules,
	tag_key:    string,
	key_open:   string,
	key_close:  string,
	flat:       bool,
	services:   ^Services,
	attribute:  proc "contextless" (doc: ^Document, f: Fact) -> (name, value: Token),
}

// The run-time services of a handle, which a call that chooses its format at run time reaches through
// `Readers.services`. `build` reads a text into a document and `validate` judges one without building, each as the
// handle says, see `core.build` and `core.validate`. `scan` reads paths over a text as the handle says into a partial
// document, or gives each answer to `on` when it is set, see `core/build`'s `scan` and `each_answer`. `edit` points at the format's edit services, nil for a format that accepts no edits. `write`
// writes a node of the document as text of the format `as` names, into a buffer from `allocator` or to `stream`, nil
// for a format with no document writer, see `core.write`. `plans` is the format's `typed.Plan_Make`, nil for a format
// whose plans need nothing past `typed.plan_build`. `reads` is the format's `^typed.Format_Reads`, nil for a format with
// no typed read. `tokens` is the format's `^write.Token_Spelling`, nil for a format with no token writer. `records` is
// the format's `^records.Services`, nil for a format with no record reader. Each pointer is a `rawptr` since
// `core/write`, `core/records` and `core/typed` import `core`, and each is cast back to that type unchecked, so a
// format sets them to exactly that type or leaves them nil.
Services :: struct {
	build:    proc(src: []u8, as: As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (Document, Document_Error),
	validate: proc "contextless" (src: []u8, as: As) -> Maybe(Fault),
	scan:     proc(src: []u8, as: As, paths: []Path, read: Path_Options, state: rawptr, on: proc(state: rawptr, a: Token_Answer) -> bool, allocator: runtime.Allocator) -> (Document, Path_Error),
	write:    proc(doc: ^Document, opts: Write_Options, as: As, node: Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, int, Typed_Error),
	edit:     ^Edit_Services,
	plans:    rawptr,
	reads:    rawptr,
	tokens:   rawptr,
	records:  rawptr, // ^records.Framing_Services
	docs:     rawptr, // ^records.Record_Docs
}

// An `Edit_Services` holds a format's edit services. A document's `Services` points at one table, and the services
// dispatch on the document's `spec` and `opts`. `value` checks a text as exactly one value of the format and
// spec, and `key_text` writes a decoded member name in the format's own spelling, quotes and escapes included. A member
// insert's key and a key set take a decoded name, so no service judges a key. Each service receives the document, so it reads the run-time options the document holds. A text that is no value answers `.Bad_Value`, with
// the walk's fault in `inner` where there is one, and `.No_Memory` when the service could not allocate.
//
// `member_sep` is what is written between two members of container `c`, a flat text's root included, and `key_sep` between a member's key and its
// value. `comment` says how the output spells a comment under `spec` and is nil for a format that accepts no comment.
// `insert_check` holds a format's rules on what a container takes.
//
// A flat format also supplies the rest. `interior` returns the bytes a container's members lie in, `fact_slot` says whether the output holds a fact of a role on a node, and `emptied` whether a list
// removes every member of the root. `plan` runs first on a commit and may turn the whole list into plain edits, which
// `out` receives with their texts borrowed or allocated with `allocator`, and it returns false to keep the list as it is.
Edit_Services :: struct {
	value:         proc(v: ^Token_View, src: []u8, allocator: runtime.Allocator) -> Document_Error,
	key_text:      proc(doc: ^Document, name: []u8, text: ^[dynamic]u8) -> bool,
	comment:       proc(doc: ^Document, spec: u8) -> (style: Comment_Spelling, b: u8),
	separators:    proc(doc: ^Document, spec: u8) -> bool, // `spec` ends a line comment at U+2028 and U+2029, which `doc.as` does not
	member_sep:    proc(doc: ^Document, c: Node_Index) -> string,
	key_sep:       string,
	insert_check:  proc(doc: ^Document, container: Node_Index, text: string, allocator: runtime.Allocator) -> Document_Error,
	interior:      proc(doc: ^Document, c: Node_Index) -> (lo, hi: u64),
	fact_slot:     proc(doc: ^Document, node: Node_Index, role: Role, emptied: bool) -> bool,
	emptied:       proc(doc: ^Document, list: ^Edit_List) -> bool,
	plan:          proc(doc: ^Document, list: ^Edit_List, out: ^[dynamic]Edit, allocator: runtime.Allocator) -> (changed: bool, err: Document_Error),
	// Judges a text of the list's own spec, as a commit checks its output and the document's source.
	validate:      proc "contextless" (src: []u8, as: As) -> Maybe(Fault),
	// Spells a built value as text of the document's format and spec, in a buffer from `allocator`. `opts` and `colon`
	// are the layout, `colon` the bytes between a member's key and its value when they are not the format's own. `at` is
	// the byte the text goes in at. A flat format spells a cell, or with `record` the cells of an array or object as one
	// record without its line end, and refuses a cell it cannot spell as a `Document_Error` that names the cell by `reason`.
	spell:         proc(doc: ^Document, v: Value, opts: Write_Options, colon: string, record: bool, at: u64, allocator: runtime.Allocator) -> ([]u8, Error),
}

// A `Comment_Spelling` names how a format spells a comment in an output: `//` for a JSON spec that has comments, the
// document's comment byte for a delimited text, or none. Under `Line`, a body holding a line end is written in the
// block form `/* */`, so a line comment's body cannot end its line early.
Comment_Spelling :: enum u8 {
	None,
	Line,
	Byte,
}

// Frees `doc`'s node, fact, child-count and child-index allocations and sets `doc` to the zero value.
destroy :: proc(doc: ^Document) {
	// A nil slice frees nothing.
	delete(doc.nodes_alloc, doc.allocator)
	delete(doc.facts_alloc, doc.allocator)
	delete(doc.counts_alloc, doc.allocator)
	if owns_tables(doc) {
		delete(tables_of(doc), doc.allocator)
	}
	for x in doc.indexed {
		delete(x.members, doc.allocator)
	}
	delete(doc.indexed)
	delete(doc.reads_block, doc.allocator)
	doc^ = {}
}

// Returns a copy of `doc` whose nodes, facts, child counts and path answers are new allocations from `allocator`, so
// `doc` may be destroyed while the copy lives. The text is not copied: the copy borrows `doc.src` as `doc` does. The
// copy has no child index.
clone :: proc(doc: ^Document, allocator := context.allocator) -> (c: Document, err: runtime.Allocator_Error) {
	c = doc^
	c.allocator = allocator
	c.nodes_alloc, c.facts_alloc, c.counts_alloc, c.reads_block = nil, nil, nil, nil
	c.indexed = nil
	if owns_tables(doc) {
		c.tables_at, c.n_tables = nil, 0
	}
	defer if err != nil {
		destroy(&c)
	}
	c.nodes_alloc = slice.clone(doc.nodes, allocator) or_return
	c.facts_alloc = slice.clone(doc.facts, allocator) or_return
	c.counts_alloc = slice.clone(doc.counts, allocator) or_return
	c.nodes, c.facts, c.counts = c.nodes_alloc, c.facts_alloc, c.counts_alloc
	if owns_tables(doc) {
		set_tables(&c, slice.clone(tables_of(doc), allocator) or_return)
	}
	err = own_reads(&c)
	return
}

// Copies `doc`'s answers, kept children and missing names, the names' bytes included, into one block `doc` owns, and
// points the lists at it, so the memory they were read into may go. The lists it held are not freed.
own_reads :: proc(doc: ^Document) -> runtime.Allocator_Error {
	a := len(doc.answers) * size_of(Answer)
	k := a + len(doc.kept) * size_of(Kept_Child)
	m := (k + 7) &~ 7
	names := m + len(doc.missing) * size_of(Missing_Name)
	size := names
	for x in doc.missing {
		size += len(x.name)
	}
	if size == 0 {
		doc.answers, doc.kept, doc.missing, doc.reads_block = nil, nil, nil, nil
		return nil
	}
	block := runtime.mem_alloc_non_zeroed(size, 8, doc.allocator) or_return
	answers, kept, missing := doc.answers, doc.kept, doc.missing
	doc.reads_block = block
	doc.answers = ([^]Answer)(raw_data(block))[:len(answers)]
	doc.kept = ([^]Kept_Child)(raw_data(block[a:]))[:len(kept)]
	doc.missing = ([^]Missing_Name)(raw_data(block[m:]))[:len(missing)]
	copy(doc.answers, answers)
	copy(doc.kept, kept)
	w := names
	for x, i in missing {
		copy(block[w:], x.name)
		doc.missing[i] = {x.node, string(block[w:w + len(x.name)])}
		w += len(x.name)
	}
	return nil
}

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
doc_length :: #force_inline proc(doc: ^Document, i: Node_Index) -> int {
	if int(i) >= len(doc.nodes) {
		return 0
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Object {
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
	return doc.readers.key_equals(&doc.view, doc.nodes[i], name)
}

// Returns the first source byte of node `n`. A quoted string's token starts one byte past its opening quote.
node_start :: #force_inline proc(n: Node) -> u64 {
	lo, _ := scalar_ends(n)
	return lo
}

// Returns container `i`'s `k`th member value, counted from 0: for an inline-key `Object`, the value after its `k`th key,
// which is the node after the key. A `k` past the last member, a negative `k`, and a node that holds no members return no
// node. A container whose members are one node each is indexed, since its subtree size gives the stride: an
// `Array`'s is its member count plus one, a shared-key `Object`'s its count plus one, and an inline-key `Object`'s twice its
// count plus one. Any other container is read from its child index when `index_children` built one, else walked,
// stepping one subtree size per member. A count that saturated `MAX_CHILDREN` is read from `Document.counts`, so
// the stride test uses the true member count.
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
@(private)
one_node_stride :: #force_inline proc(doc: ^Document, n: Node, count: int) -> int {
	if n.kind == .Object && header_of(doc) == 0 {
		return 2 if int(n.n) == 2 * count + 1 else 0
	}
	return 1 if int(n.n) == count + 1 else 0
}

// `child_at` for a container whose members are not all one node, with `k` below the member count. The rows of a table
// with a width are computed. Else it reads the child index if there is one, and walks if not.
@(private, cold)
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
@(private)
indexed_members :: proc(doc: ^Document, i: Node_Index) -> ([]Node_Index, bool) {
	at := lower_node(doc.indexed[:], i)
	if at < len(doc.indexed) && doc.indexed[at].node == i {
		return doc.indexed[at].members, true
	}
	return nil, false
}

// Lists container `i`'s member values in `Document.indexed`, so `child_at` and `children_from` reach any member
// without a walk. Returns whether `i` is now read by position without a walk. A container whose members are one node
// each needs no entry. A scalar, a node past the last, a `Partial` container and a failed allocation give false. A
// container that could not be listed keeps an entry with no members, so a later call writes nothing and gives false.
// It writes the document, so nothing else may read `doc` during the call.
index_children :: proc(doc: ^Document, i: Node_Index) -> bool {
	if int(i) >= len(doc.nodes) {
		return false
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Object || n.role == .Partial {
		return false
	}
	count := int(n.spelling)
	if n.spelling == MAX_CHILDREN {
		count = wide_length(doc, i)
	}
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

doc_children :: proc(doc: ^Document, i: Node_Index) -> Child_Iter {
	if int(i) >= len(doc.nodes) {
		return {doc = doc, parent = i, done = true}
	}
	n := doc.nodes[i]
	if n.kind != .Array && n.kind != .Object {
		return {doc = doc, parent = i, done = true}
	}
	it := Child_Iter{doc = doc, parent = i, end = i + Node_Index(n.n), pairs = n.kind == .Object && header_of(doc) == 0}
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

// Returns the value of the member of `obj` whose key decodes to `name`, the first under `.First` and else the last. `members_named` yields
// every match. A headed dsv record's members are its cells, named by the header's cells.
doc_member :: #force_inline proc(doc: ^Document, obj: Node_Index, name: string, dups := Duplicates.Last) -> (Node_Index, bool) {
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
	if int(obj) >= len(doc.nodes) {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	n := doc.nodes[obj]
	if n.kind != .Object {
		return {doc = doc, rec = NO_NODE, done = true}
	}
	if keys := header_of(doc); keys != 0 {
		return {doc = doc, at = keys + 1, end = keys + Node_Index(doc.nodes[keys].n), name = name, rec = obj}
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

// Returns the next of a shared-key `Object`'s values whose key decodes to `it.name`. The walk runs over the shared keys. A
// key past the `Object`'s last value matches nothing, so a short `Object`'s missing members are absent.
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
		col := j - int(header_of(it.doc)) - 1
		if col < width && key_equals(it.doc, Node_Index(j), it.name) {
			return it.rec + Node_Index(1 + col), true
		}
	}
	return NO_NODE, false
}

// Returns the decoded text of string or plain node `i`. A node whose `SPELLING_DECODE` bit is clear is its span
// without its quotes. A node that needs decoding is written into `buf`, and the call returns false when `buf` is too short,
// which `text_room` bytes never are, and its content is then unspecified. It allocates nothing, so a caller that has no buffer long
// enough uses `text_clone`. Returns false for a container or a node past the last.
doc_text :: #force_inline proc(doc: ^Document, i: Node_Index, buf: []u8) -> (s: string, ok: bool) {
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
	return doc.readers.text(&doc.view, n, buf)
}

// Returns a length of `buf` that always holds `text`'s decode of node `i`, which may pass the text's own length, and 0
// for a node that needs no decode, a container and a node past the last.
text_room :: proc(doc: ^Document, i: Node_Index) -> int {
	if int(i) >= len(doc.nodes) || doc.nodes[i].kind > .Plain || doc.nodes[i].spelling & SPELLING_DECODE == 0 {
		return 0
	}
	return decoded_room(doc.nodes[i].spelling, int(doc.nodes[i].n))
}

// Returns the bytes that hold the decode of a token of `n` span bytes with `spelling`. A decode never yields more
// bytes than its span, except that a tolerated ill-formed sequence reads as U+FFFD, three bytes for one source byte,
// and a token that holds one carries `SPELLING_LAX`.
@(private)
decoded_room :: #force_inline proc "contextless" (spelling: u16, n: int) -> int {
	if spelling & (SPELLING_DECODE | SPELLING_LAX) == SPELLING_DECODE | SPELLING_LAX {
		return 3 * n + 4
	}
	return n
}

// Returns token `t`'s text as `readers.text` gives it: its span when the token needs no decode, else a decode into a
// buffer allocated from `allocator`. Returns false for a refused allocation or a failed decode.
token_text :: proc(readers: ^Readers, view: ^Token_View, t: Token, allocator: runtime.Allocator) -> (s: string, ok: bool) {
	if t.spelling & SPELLING_DECODE == 0 {
		return string(node_text(view.src, t)), true
	}
	room := decoded_room(t.spelling, int(t.n))
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
	if int(i) >= len(doc.nodes) {
		return "", false
	}
	n := doc.nodes[i]
	if n.kind > .Plain {
		return "", false
	}
	size := decoded_room(n.spelling, int(n.n))
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

// Returns the number node `i` writes, decoded from its span, and false for a node that is no number: a container, a
// string, a key, a cell that spells no number, and an index past the last node.
doc_number :: #force_inline proc(doc: ^Document, i: Node_Index) -> (Number, bool) {
	if int(i) < len(doc.nodes) && doc.nodes[i].kind <= .Plain {
		return doc.readers.number(&doc.view, doc.nodes[i])
	}
	return {}, false
}

// Whether `a` and `b` read one format. Two tables of one format differ by spec, so their addresses are no evidence.
same_format :: #force_inline proc "contextless" (a, b: ^Readers) -> bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.format == b.format
}

// Returns the run-time services of `as`'s format, nil for a handle with none: a zero handle, and a table that serves a read only.
services_of :: #force_inline proc "contextless" (as: As) -> ^Services {
	return as.readers.services if as.readers != nil else nil
}

// Reads `src` into a document as `as` says: its format, spec, depth, tolerance and the format's own options.
// `.Refuse` fails at a key that repeats one of its object's, and every other `dups` builds every member. The document
// borrows `src`, which must outlive it, and `destroy` frees it. A handle with no format's build returns `.Bad_Spec`, and
// on any error the document is the zero value.
build :: proc(src: []u8, as: As, dups := Duplicates.Last, allocator := context.allocator) -> (Document, Error) {
	if services_of(as) == nil || services_of(as).build == nil {
		return {}, error_of(Document_Error{kind = .Bad_Spec})
	}
	doc, err := services_of(as).build(src, as, dups == .Refuse, allocator)
	return doc, error_of(err)
}

// Judges `src` as `as` says without building or allocating. Returns the first fault, or nil for a text that reads. A
// handle with no format's validate faults `.Bad_Option` at byte 0.
validate :: proc "contextless" (src: []u8, as: As) -> Error {
	if services_of(as) == nil || services_of(as).validate == nil {
		return error_of(Fault{kind = .Bad_Option})
	}
	return error_of(services_of(as).validate(src, as))
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
	if !ok {
		return 0, false
	}
	switch n.kind {
	case .Int:
		if n.bits == 0 && doc.src[doc.nodes[i].lo] == '-' {
			return -0.0, true
		}
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
	return {doc = doc, facts = all_facts(doc, i), role = role}
}

// A walk over the attributes of the element whose value is node `i`, in source order, with `attribute_next` giving one
// at a time. A check, a load and infer read an element's attributes as members through it.
Attribute_Iter :: struct {
	doc:   ^Document,
	facts: []Fact,
}

// Returns a walk over the attributes of the element whose value is node `i`, none for a format with no attributes.
attributes_of :: proc(doc: ^Document, i: Node_Index) -> Attribute_Iter {
	if doc.readers == nil || doc.readers.attribute == nil {
		return {doc = doc}
	}
	return {doc = doc, facts = all_facts(doc, i)}
}

// Returns the next attribute's name as a `Key` token and its value as a `Value` token, as `Readers.attribute` reads them.
attribute_next :: proc(it: ^Attribute_Iter) -> (name, value: Token, ok: bool) {
	for len(it.facts) > 0 {
		f := it.facts[0]
		it.facts = it.facts[1:]
		if f.role == .Attribute {
			name, value = it.doc.readers.attribute(it.doc, f)
			return name, value, true
		}
	}
	return {}, {}, false
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
	return doc.facts[lower_node(doc.facts, i):lower_node(doc.facts, i + 1)]
}

// A `Fact_Iter` walk reads the bodies of one node's facts of one role, in source order. `fact_next` returns one at a time.
Fact_Iter :: struct {
	doc:   ^Document,
	facts: []Fact,
	role:  Role,
}

// Returns the next body without the markers its format writes: the fact's `spelling` gives the lead and tail
// lengths, and core reads the bytes between them without knowing any format's marker.
fact_next :: proc(it: ^Fact_Iter) -> (body: string, ok: bool) {
	for len(it.facts) > 0 {
		f := it.facts[0]
		it.facts = it.facts[1:]
		if f.role == it.role {
			return string(fact_body(it.doc, f)), true
		}
	}
	return "", false
}

@(private)
fact_body :: #force_inline proc(doc: ^Document, f: Fact) -> []u8 {
	return doc.src[f.lo + comment_lead(f.spelling) : f.lo + u64(f.n) - comment_tail(f.spelling)]
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
