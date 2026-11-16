package core

import "base:runtime"
import "core:slice"

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
// A key or text that no span of the source spells: the format's `text` and `key_equals` make it, as a markup format's
// `#text` member and `@name` attribute keys, whose span is `n` bytes of the name or none. Both bits are set, so the
// decode may be longer than the span and a writer does not copy the span as authored.
SPELLING_SYNTHETIC :: SPELLING_DECODE | SPELLING_LAX
// The bytes a decode of a `SPELLING_LAX` token may hold past three times its span.
DECODE_SLACK :: 8

// The spelling bits of a text that holds an escape (`escaped`) or a sequence a tolerance accepted (`lax`):
// `SPELLING_DECODE` for either and `SPELLING_LAX` for the latter.
text_spelling :: #force_inline proc "contextless" (escaped, lax: bool) -> u16 {
	return (SPELLING_DECODE if escaped || lax else 0) | (SPELLING_LAX if lax else 0)
}

// A number token's `spelling`. Kinds are even, so bit 0 (`SPELLING_DECODE`) is clear.
//
//	bits 0 to 3   the format's number kind: 0 for its plain decimal, `NUMBER_DECIMAL` for a decimal it writes with a
//	              sign or a point of its own, and above that a number whose text is not a decimal
//	bits 4 to 8   the integer digit count (saturated at 31)
//	bits 9 to 13  the fraction digit count (saturated at 31, 0 for no fraction)
//	bit 14        `NUMBER_EXP`
//	bit 15        `NUMBER_POINT`, a point with no digit after it (JSON5's and YAML's `5.`), which makes a float
NUMBER_KIND_MASK :: u16(0xF)
NUMBER_DECIMAL :: u16(2)
NUMBER_EXP :: u16(1 << 14)
NUMBER_POINT :: u16(1 << 15)
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

// Returns a number token's integer digit count, and the count plus 32 or more when it has a point or an exponent.
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

// What a format's token readers need besides the token: the source it spans and the handle it was read with. A document
// starts with one, and a typed read holds one for the walk's tokens.
Token_View :: struct {
	src:      []u8,
	using as: As,
	// The format's own tables for `src`, which a token's text may need past its span and the handle, as an XML text's
	// entity and attribute declarations are. Empty for a format or a text with none. A document's are in its
	// allocator: `destroy` frees them and `clone` copies them.
	state:    []u8,
}

// A `Document` holds the walk's tokens over the caller's bytes, the facts beside them, and the format's `Readers`
// table. `src` is borrowed and must outlive the document, unless `owns_src` says it is the document's. `nodes_alloc` is
// the allocation behind `nodes`, whose length is its capacity, so `destroy` frees it after `nodes` shrank to the node
// count.
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
	// The first byte of the first key with the text of another key of its object, as YAML's `1` and `"1"` are, which a
	// read by name refuses under every `dups` but `.First` and `.All`. 0 when no key is.
	clash:        u64,
	partial:      bool,
	stopped:      bool,
	// Set by a build that gave every cell its kind, so a `Plain` cell is a string or null and resolves no further.
	kinds_stored: bool,
	// Set by a build whose tokens spell a tag in their spelling, as a TOML datetime's does, see `has_tags`.
	spelled_tags: bool,
	// Set by a build that sent no node's tokens again in another place, as a YAML alias or merge key does, so every
	// container's children follow it in the text.
	in_order:     bool,
	// Set when `src` is the document's own allocation, as a stream's record built over bytes its window no longer holds
	// is.
	owns_src:     bool,
	// The tables at `tables_at`: a dsv text has one.
	n_tables:     u16,
}

// A byte more in `Document` makes every copy and every walk's frame larger, as the bools and this count fill a word.
#assert(size_of(Document) == 304)

// A container whose members are rows of cells. Rows are stored row by row: a row is its own node and then its `width`
// cells, so row `k` is at `first_row + k * (width + 1)` when `width` is not 0. `header` is the node of the `Array` of
// the shared keys, 0 for a table with none. A `width` of 0 means the rows have no common width (a ragged table, or a
// partial document's records), and `first_row` is then not read. The records of a table answer an `Index` as the cells
// of a dsv record do. `unique_keys` says no two of the header's keys decode to one name, so a member lookup stops at its
// first match under any duplicate policy. `key_slots`, which `index_keys` builds and the table owns, finds a key's column.
Table :: struct {
	node:        Node_Index,
	header:      Node_Index,
	first_row:   Node_Index,
	width:       u32,
	unique_keys: bool,
	// Open-addressed by `key_hash`: a slot holds a column plus one, and 0 is empty. Empty, or a power of two at least
	// twice the key count long.
	key_slots:   []u16,
}

// The narrowest header `index_keys` indexes. Below it the walk over the keys costs no more than a probe.
@(private)
MIN_INDEXED_KEYS :: 2

// Gives table `t` of `doc` its `key_slots` when its keys are all different and at least `MIN_INDEXED_KEYS`, so a record's
// member lookup probes for its column rather than walk the keys. The slots are allocated from `doc.allocator`.
index_keys :: proc(doc: ^Document, t: ^Table) -> runtime.Allocator_Error {
	if !t.unique_keys || t.header == 0 {
		return nil
	}
	count := length(doc, t.header)
	if count < MIN_INDEXED_KEYS || count >= int(max(u16)) {
		return nil
	}
	n := 2
	for n < 2 * count {
		n <<= 1
	}
	slots := make([]u16, n, doc.allocator) or_return
	mask := u32(n - 1)
	for col in 0 ..< count {
		// A unique key needs no decoding, so its text is its span.
		k := doc.nodes[int(t.header) + 1 + col]
		h := key_hash(string(doc.src[k.lo:][:k.n])) & mask
		for slots[h] != 0 {
			h = (h + 1) & mask
		}
		slots[h] = u16(col + 1)
	}
	t.key_slots = slots
	return nil
}

// Hashes a key by its length and its first and last bytes, which tell most header names apart.
@(private)
key_hash :: #force_inline proc "contextless" (s: string) -> u32 {
	h := u32(len(s))
	if len(s) > 0 {
		h = h * 0x9E3779B1 ~ u32(s[0]) << 8 ~ u32(s[len(s) - 1])
	}
	return (h * 0x9E3779B1) >> 16
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
	doc.tables_at, doc.n_tables = raw_data(tables), u16(len(tables))
}

// Returns whether the tables of `doc` are an allocation of the document, which is every table slice but the rodata one
// of a partial document.
owns_tables :: #force_inline proc "contextless" (doc: ^Document) -> bool {
	return doc.n_tables != 0 && doc.tables_at != raw_data(POSITIONAL_TABLES[:])
}

// Returns whether the `Object`s of `doc` answer an `Index`, as a dsv record's cells do, which is whether `doc` has a
// table.
@(private)
positional :: #force_inline proc "contextless" (doc: ^Document) -> bool {
	return doc.n_tables != 0
}

// How a read treats an object's repeated keys. `.Default` is the zero value and takes the format's own policy, which a
// format whose policy is not `.Last` resolves in its own entry points. `.Last` answers the last and `.First` the first.
// `.All` answers each of them, and `.Refuse` fails at a key that repeats one of its object's, at the second key's first
// byte. A read of one member, as `member` is, picks under `.All` and `.Refuse` as under `.Last`.
Duplicates :: enum u8 {
	Default,
	Last,
	First,
	All,
	Refuse,
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

// Frees `doc`'s text when it owns it, its node, fact, child-count and child-index allocations, and sets `doc` to the
// zero value.
destroy :: proc(doc: ^Document) {
	// A nil slice frees nothing.
	if doc.owns_src {
		delete(doc.src, doc.allocator)
	}
	delete(doc.nodes_alloc, doc.allocator)
	delete(doc.facts_alloc, doc.allocator)
	delete(doc.counts_alloc, doc.allocator)
	if owns_tables(doc) {
		for t in tables_of(doc) {
			delete(t.key_slots, doc.allocator)
		}
		delete(tables_of(doc), doc.allocator)
	}
	for x in doc.indexed {
		delete(x.members, doc.allocator)
	}
	delete(doc.indexed)
	delete(doc.reads_block, doc.allocator)
	delete(doc.state, doc.allocator)
	doc^ = {}
}

// Returns a copy of `doc` whose nodes, facts, child counts, path answers and format tables are new allocations from
// `allocator`, so `doc` may be destroyed while the copy lives. The text is copied only when `doc` owns it, and else the
// copy borrows `doc.src` as `doc` does. The copy has no child index.
clone :: proc(doc: ^Document, allocator := context.allocator) -> (c: Document, err: runtime.Allocator_Error) {
	c = doc^
	c.allocator = allocator
	c.nodes_alloc, c.facts_alloc, c.counts_alloc, c.reads_block, c.state = nil, nil, nil, nil, nil
	c.indexed = nil
	if owns_tables(doc) {
		c.tables_at, c.n_tables = nil, 0
	}
	defer if err != nil {
		destroy(&c)
	}
	if len(doc.state) > 0 {
		// A format's tables hold words of up to 8 bytes.
		c.state = runtime.mem_alloc_bytes(len(doc.state), 16, allocator) or_return
		copy(c.state, doc.state)
	}
	if doc.owns_src {
		c.src = slice.clone(doc.src, allocator) or_return
	}
	c.nodes_alloc = slice.clone(doc.nodes, allocator) or_return
	c.facts_alloc = slice.clone(doc.facts, allocator) or_return
	c.counts_alloc = slice.clone(doc.counts, allocator) or_return
	c.nodes, c.facts, c.counts = c.nodes_alloc, c.facts_alloc, c.counts_alloc
	if owns_tables(doc) {
		tables := slice.clone(tables_of(doc), allocator) or_return
		for &t in tables {
			t.key_slots = nil
		}
		set_tables(&c, tables)
		for &t, i in tables {
			t.key_slots = slice.clone(tables_of(doc)[i].key_slots, allocator) or_return
		}
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

// Returns the index of the first entry of `entries`, which are sorted by `node`, whose node is not below `node`.
lower_node :: proc(entries: []$E, node: $N) -> int {
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
