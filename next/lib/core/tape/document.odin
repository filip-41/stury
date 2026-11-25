package tape

import "base:runtime"

// Documents are stury's parsed form of a text. Queries, writes, edits and format conversions read them, and a path
// query returns a partial one holding only the nodes it reached.

// Nodes and facts over the source bytes of parsed text. Immutable, so threads share it without locks.
Document :: struct {
	src:        []u8, // borrowed unless `.Owns_Src`
	// The root value's preorder: its subtree starts at 0 and has `nodes[0].n` nodes, and no node lies past it, so a loop
	// over `nodes` walks the root. What a format keeps beside the root value, as a table's header keys, is in `ext`.
	nodes:      []Node,
	facts:      []Fact, // sorted by node, then source order
	counts:     []Child_Count, // sorted by node, only containers whose `spelling` saturated
	ext:        ^Doc_Ext, // nil for a document that holds nothing beside its lists
	format:     ^Format,
	allocator:  runtime.Allocator,
	root_close: u64, // end of the root value, so writing the root needs no scan
	partial:    ^Partial, // what a path read kept and knows it lacks, nil for a document of every value
	present:    Facts, // fact kinds in `facts`
	flags:      Doc_Flags,
}

destroy :: proc {
	destroy_document,
	destroy_demand,
	destroy_index,
	destroy_line_index,
	destroy_children,
	destroy_pieces,
	destroy_records,
}

// Frees what `doc` holds and leaves it zero. The source is freed only under `.Owns_Src`, and under `.Borrowed` only the
// answers are.
destroy_document :: proc(doc: ^Document) {
	if .Borrowed in doc.flags {
		free(doc.partial, doc.allocator)
		doc^ = {}
		return
	}
	free(raw_data(doc.nodes), doc.allocator)
	free(raw_data(doc.facts), doc.allocator)
	free(raw_data(doc.counts), doc.allocator)
	free(doc.ext, doc.allocator)
	if .Owns_Src in doc.flags {
		free(raw_data(doc.src), doc.allocator)
	}
	free(doc.partial, doc.allocator)
	doc^ = {}
}

// A copy of `doc` in `allocator` that holds its own nodes, facts, counts, extension and answers, as a document a read
// gives does, and the source too under `.Owns_Src`. A copy of a `query`'s document borrows the nodes it read still. A
// refused allocation is the error, with nothing left allocated.
clone_document :: proc(doc: ^Document, allocator := context.allocator) -> (c: Document, err: runtime.Allocator_Error) {
	c = doc^
	c.allocator, c.partial = allocator, nil
	if .Borrowed not_in doc.flags {
		c.nodes, c.facts, c.counts, c.ext = nil, nil, nil, nil
		if .Owns_Src in doc.flags {
			c.src = nil
		}
	}
	defer if err != nil {
		destroy_document(&c)
	}
	if .Borrowed not_in doc.flags {
		c.nodes = clone_list(doc.nodes, allocator) or_return
		c.facts = clone_list(doc.facts, allocator) or_return
		c.counts = clone_list(doc.counts, allocator) or_return
		if .Owns_Src in doc.flags {
			c.src = clone_list(doc.src, allocator) or_return
		}
		if doc.ext != nil {
			c.ext = ext_make(doc.ext.held, doc.ext.format, allocator) or_return
			c.ext.origin = doc.ext.origin
		}
	}
	if x := doc.partial; x != nil {
		owned := .Borrowed not_in doc.flags
		y := partial_block(len(x.starts) - 1, len(x.answers), len(x.kept) if owned else 0, len(x.missing) if owned else 0, len(x.names) if owned else 0, x.dups, allocator) or_return
		y.facts = x.facts
		copy(y.answers, x.answers)
		copy(y.starts, x.starts)
		if owned {
			copy(y.kept, x.kept)
			copy(y.missing, x.missing)
			copy(y.names, x.names)
		} else {
			y.kept, y.missing, y.names = x.kept, x.missing, x.names
		}
		c.partial = y
	}
	return
}

// A `Partial` under `dups` in one block with its lists, which `destroy` frees whole: room for `answers` answers, the
// starts of `paths` paths, zero, `kept` kept children, `missing` missing names and `names` bytes of their names, each
// list of its length and unset. A refused allocation is the error.
partial_block :: proc(paths, answers, kept, missing, names: int, dups: Duplicates, allocator: runtime.Allocator) -> (x: ^Partial, err: runtime.Allocator_Error) {
	starts_at := size_of(Partial) + answers * size_of(Answer)
	kept_at := starts_at + (paths + 1) * size_of(u32)
	missing_at := kept_at + kept * size_of(Kept_Child)
	names_at := missing_at + missing * size_of(Missing_Name)
	block := runtime.mem_alloc_non_zeroed(names_at + names, align_of(Partial), allocator) or_return
	// An empty allocator gives no block and no error, or a shorter one, either read as a refusal.
	if len(block) < names_at + names || raw_data(block) == nil {
		return nil, .Out_Of_Memory
	}
	x = (^Partial)(raw_data(block))
	x^ = {
		answers = ([^]Answer)(raw_data(block[size_of(Partial):]))[:answers],
		starts  = ([^]u32)(raw_data(block[starts_at:]))[:paths + 1],
		kept    = ([^]Kept_Child)(raw_data(block[kept_at:]))[:kept],
		missing = ([^]Missing_Name)(raw_data(block[missing_at:]))[:missing],
		names   = block[names_at:][:names],
		dups    = dups,
	}
	runtime.mem_zero(raw_data(x.starts), len(x.starts) * size_of(u32))
	return
}

@(private)
clone_list :: proc(list: []$T, allocator: runtime.Allocator) -> (out: []T, err: runtime.Allocator_Error) {
	if len(list) == 0 {
		return nil, nil
	}
	data := runtime.mem_alloc_non_zeroed(len(list) * size_of(T), align_of(T), allocator) or_return
	out = ([^]T)(raw_data(data))[:len(list)]
	copy(out, list)
	return
}

// A `Doc_Ext` of `held` and `format` in one block of `allocator`, with copies of the lists they name, which `destroy`
// frees whole.
ext_make :: proc(held: []Held_Span, format: Format_Ext, allocator: runtime.Allocator) -> (ext: ^Doc_Ext, err: runtime.Allocator_Error) {
	sized := Ext_Block{size = size_of(Doc_Ext)}
	scratch: Doc_Ext
	ext_lists(&sized, &scratch, held, format)
	raw := runtime.mem_alloc_non_zeroed(sized.size, align_of(Doc_Ext), allocator) or_return
	// A nil allocator gives no memory and no error.
	if raw == nil {
		return nil, .Out_Of_Memory
	}
	ext = (^Doc_Ext)(raw_data(raw))
	ext^ = {}
	block := Ext_Block{base = raw_data(raw), size = size_of(Doc_Ext)}
	ext_lists(&block, ext, held, format)
	return
}

// The block `ext_make` fills, its lists placed one after another from `size` on. With no `base` it only sizes them.
@(private)
Ext_Block :: struct {
	base: [^]u8,
	size: int,
}

// Gives `ext` `held` and `format` with their lists placed in `b`.
@(private)
ext_lists :: proc "contextless" (b: ^Ext_Block, ext: ^Doc_Ext, held: []Held_Span, format: Format_Ext) {
	ext.held = ext_list(b, held)
	switch f in format {
	case Tabular_Ext:
		placed := f
		placed.tables, placed.keys, placed.slots = ext_list(b, f.tables), ext_list(b, f.keys), ext_list(b, f.slots)
		ext.format = placed
	case Markup_Ext:
		placed := f
		placed.scopes, placed.uris, placed.uri_text = ext_list(b, f.scopes), ext_list(b, f.uris), ext_list(b, f.uri_text)
		placed.dtd.entities, placed.dtd.attrs = ext_list(b, f.dtd.entities), ext_list(b, f.dtd.attrs)
		placed.dtd.slots, placed.dtd.bytes = ext_list(b, f.dtd.slots), ext_list(b, f.dtd.bytes)
		ext.format = placed
	case nil:
	}
}

// Places a copy of `list` in `b`, aligned for its entries.
@(private)
ext_list :: proc "contextless" (b: ^Ext_Block, list: []$T) -> []T {
	at := (b.size + align_of(T) - 1) / align_of(T) * align_of(T)
	b.size = at + len(list) * size_of(T)
	if b.base == nil || len(list) == 0 {
		return nil
	}
	placed := ([^]T)(b.base[at:])[:len(list)]
	copy(placed, list)
	return placed
}

// How a document was built.
Doc_Flag :: enum u8 {
	Owns_Src,
	Stopped, // the read stopped early, and the text past the stop was not validated
	Tolerated, // the text broke a rule the read's tolerances let it break
	// The text ended inside its root value, and the containers `Pieces.open` names were closed at the cut. A scalar
	// cut short is left out, and so is a key whose value had not started.
	Cut,
	// The read copied the bytes of each key, scalar and fact out of the text as it went, so the text may be gone. Their
	// offsets stay the text's, and `src` holds their bytes where `Doc_Ext.held` places them. No byte between them is
	// held.
	Held,
	Dropped, // the duplicate key policy left members of the text out of the nodes
	// The document of a `query`: its source, nodes, facts, counts and extension are those of the document the query
	// read, which outlives it, and it holds only its answers.
	Borrowed,
}

Doc_Flags :: bit_set[Doc_Flag; u16]

// What a document holds beside its nodes, facts and counts, in one block with the lists it names, which `destroy` frees
// whole.
Doc_Ext :: struct {
	// Under `.Held`, where the bytes of each token are in `Document.src`, sorted by offset: a token's span starts at the
	// last `lo` at or before its own.
	held:   []Held_Span,
	origin: Origin,
	format: Format_Ext,
}

// Per-format data beside the nodes, nil for formats that store none.
Format_Ext :: union {
	Tabular_Ext,
	Markup_Ext,
}

// A markup document's elements that declare a namespace, by which its format resolves the prefix of a name, and the
// DTD its text declares, by which its texts' entity references decode.
Markup_Ext :: struct {
	scopes:   []Markup_Scope, // sorted by node
	uris:     []Markup_Uri, // sorted by fact
	uri_text: []u8, // the bytes `uris` name
	dtd:      Markup_Dtd,
	// The scopes of a partial document hold every declaration around the nodes it kept, as a scan that keeps facts
	// holds them. A document of every value holds them all.
	whole:  bool,
}

// The internal subset of a markup text: its entities and attribute-list declarations, a table of their names, and the
// bytes they name beside the text's. A record names bytes by offset and length, into `bytes` or into the text. Zero
// for a text with no DTD.
Markup_Dtd :: struct {
	entities: []Markup_Entity,
	attrs:    []Markup_Attribute,
	// A power of two of slots or none, each 0 or a record's index plus one, its kind in the top two bits, by its name's
	// hash.
	slots:    []u32,
	bytes:    []u8,
	flags:    Markup_Dtd_Flags,
}

Markup_Dtd_Flag :: enum u32 {
	Complete, // no external subset and no parameter-entity reference: a reference to an undeclared entity is not well-formed
	Standalone, // the XML declaration says `standalone="yes"`
	Html, // the public identifier is one the HTML standard lists, so its named references read
	Defaults, // an attribute-list declaration gives a default
	Tokenized, // an attribute-list declaration gives a type other than `CDATA`
	In_Place, // a reference was walked over its literal, so some nodes lie in the internal subset
	Stopped, // a parameter entity that was not read was referenced: later entity and attribute-list declarations are not processed
}

Markup_Dtd_Flags :: bit_set[Markup_Dtd_Flag; u32]

// An entity's replacement text is `text_n` bytes at `text_lo`, in the DTD's bytes when `.Stored` and in the text
// otherwise, and its literal is `lit_n` bytes at `lit_lo`, past the opening quote. `size` bounds the bytes its
// expansion decodes to, saturating. A document's entities are all `.Stored`.
Markup_Entity :: struct {
	text_lo: u64,
	lit_lo:  u64,
	size:    u64,
	name_lo: u32,
	text_n:  u32,
	lit_n:   u32,
	name_n:  u16,
	flags:   Markup_Entity_Flags,
}

#assert(size_of(Markup_Entity) == 40)

Markup_Entity_Flag :: enum u16 {
	Parameter, // `%name;`
	External, // a `SYSTEM` or `PUBLIC` entity, never read
	Unparsed, // an external entity with an `NDATA` notation
	Stored, // the replacement text is in the bytes, since it differs from the literal
	Lit_Stored, // the literal is in the bytes, from a parameter entity's stored replacement text
	Measured, // `size` and the flags from `Markup` on are set
	Measuring, // being measured: a reference to it now is a recursion
	Markup, // the replacement text, with the entities it refers to, holds a `<`
	Element, // the replacement text, with the entities it refers to, holds a start tag
	Respelled, // the replacement text holds markup the literal does not spell, so it cannot be walked over the literal
	Cdata_End, // the replacement text holds `]]>`
	External_Ref, // the replacement text refers to an external entity
	Unparsed_Ref, // the replacement text refers to an unparsed entity
	Undeclared_Ref, // the replacement text refers to an entity no declaration names
}

Markup_Entity_Flags :: bit_set[Markup_Entity_Flag; u16]

// An attribute an attribute-list declaration names. A default's fact spans the text from the attribute's name through
// the default's closing quote, as an attribute in a tag spans its name through its value, and `lead` is the fact's
// lead, the bytes before the default's value, saturated at 255. `size` bounds the bytes the default's value decodes to.
Markup_Attribute :: struct {
	fact_lo:    u64,
	size:       u64,
	element_lo: u32,
	name_lo:    u32,
	fact_n:     u32,
	next:       u32, // the element's next declaration, `max(u32)` for none
	element_n:  u16,
	name_n:     u16,
	tokenized:  bool, // a type other than `CDATA`, whose value collapses its spaces
	defaulted:  bool,
	qualified:  bool, // the name has a prefix, so a tag it is a default of has its names judged again
	lead:       u8,
}

#assert(size_of(Markup_Attribute) == 40)

// An element that declares a namespace: the node of its value, the node past its subtree, and the index in
// `Markup_Ext.scopes` of the nearest element around it that declares one, `NO_SCOPE` for none.
Markup_Scope :: struct {
	node, end: Node_Index,
	parent:    u32,
}

NO_SCOPE :: max(u32)

// The decode of a namespace declaration whose value is not as written: the index of its fact in `Document.facts`, and
// where in `Markup_Ext.uri_text` the decode lies.
Markup_Uri :: struct {
	fact, n: u32,
	lo:      u64,
}

// The tables of a document and their key lookup slots, which any format whose text is rows of cells under a header
// fills: CSV and TSV now. A table is an array of rows whose cells carry no keys, and the table's keys, kept here and in
// no node, name the cells by place. The readers in `navigate` give a row the members of an object with no call into
// the format.
Tabular_Ext :: struct {
	tables:  []Table, // sorted by node
	keys:    []Node, // the keys of every table's header, a table's at `Table.keys_lo`
	slots:   []u32,
	// The policy the build took a header's repeated keys by, which says which cells of a repeated name a row keeps.
	dups:    Duplicates,
	// The options the text was read with, its delimiter the spec's own byte when the build left it 0.
	options: Dsv_Options,
}

// An array whose elements are rows, each an object of scalar cells and no keys, which the table's keys name by
// place: cell `j` of a row is the member whose key is key `j`, and a row of fewer cells lacks the members past them. A
// table with no keys, `keys_n` 0, has rows no readers name: they read as arrays. Tables are sorted by node, and an
// object inside a table's node is one of its rows.
Table :: struct {
	node:        Node_Index,
	keys_lo:     u32, // the keys are `Tabular_Ext.keys[keys_lo:][:keys_n]`
	keys_n:      u32,
	first_row:   Node_Index, // row `k` is at `first_row + k * (width + 1)`
	width:       u32, // 0 for ragged rows
	// This table's key slots, `Tabular_Ext.slots[slots_lo:][:slots_len]`, a power of two of them or none: a key's
	// column plus one, by `Format.key_hash` of its text, 0 for an empty slot.
	slots_lo:    u32,
	slots_len:   u32,
	unique_keys: b32, // no two keys decode equal, so a lookup stops at the first match
}

// The data a path read kept beyond the document's nodes, in one block with its lists and the missing names' bytes. A
// scan's document holds only the nodes its paths reached, with no facts.
Partial :: struct {
	answers: []Answer, // by path, each path's in document order, the order of their nodes
	starts:  []u32, // path `i`'s answers are `answers[starts[i]:starts[i + 1]]`
	kept:    []Kept_Child, // sorted by node
	missing: []Missing_Name, // sorted by node
	names:   []u8, // the missing names' bytes
	dups:    Duplicates, // the policy the read took repeated keys by, never `.Default`
	facts:   bool, // whether the partial read kept facts (`Demand.facts`)
}

// The bytes of one token's authored span, from offset `lo` of the text, at `at` in `Document.src`.
Held_Span :: struct {
	lo, at: u64,
}

// Whether a path read found a value.
Presence :: enum u8 {
	Found,
	Missing,
	Wrong_Kind, // a step cannot enter this value
	Not_Loaded, // a partial read did not keep it, so it may or may not exist
}

// One value a path reached, or the node a path stopped at: the deepest container reached for `.Missing`, or the value
// a step could not enter for `.Wrong_Kind`.
@(private)
Answer :: struct {
	node:    Node_Index,
	outcome: Presence,
}

// A kept child's position in its original container.
@(private)
Kept_Child :: struct {
	node:  Node_Index,
	index: u32,
}

// A name looked up in `node` and not found.
@(private)
Missing_Name :: struct {
	node: Node_Index,
	lo:   u32, // the name is `Partial.names[lo:][:n]`
	n:    u32,
}
