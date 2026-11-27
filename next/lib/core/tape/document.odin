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
	format:     ^Format,
	partial:    ^Partial, // what a path read kept and knows it lacks, nil for a document of every value
	ext:        ^Doc_Ext, // nil for a document that holds nothing beside its lists
	present:    Facts, // fact kinds in `facts`
	flags:      Doc_Flags,
	facts:      []Fact, // sorted by node, then source order
	counts:     []Child_Count, // sorted by node, only containers whose `spelling` saturated
	root_close: u64, // end of the root value, so writing the root needs no scan
	allocator:  runtime.Allocator,
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
	if doc == nil {
		return
	}
	a := doc.allocator
	if .Borrowed in doc.flags {
		if doc.partial != nil {
			free(doc.partial, a)
		}
		doc^ = {}
		return
	}
	if p := raw_data(doc.nodes); p != nil {
		if .Mapped_Nodes in doc.flags {
			nodes_unmap(doc.nodes)
		} else {
			free(p, a)
		}
	}
	if p := raw_data(doc.facts); p != nil {
		free(p, a)
	}
	if p := raw_data(doc.counts); p != nil {
		free(p, a)
	}
	if doc.ext != nil {
		free(doc.ext, a)
	}
	if .Owns_Src in doc.flags && raw_data(doc.src) != nil {
		free(raw_data(doc.src), a)
	}
	if doc.partial != nil {
		free(doc.partial, a)
	}
	doc^ = {}
}

// A copy of `doc` in `allocator` that holds its own nodes, facts, counts, extension and answers, as a document a read
// gives does, and the source too under `.Owns_Src`. A copy of a `query`'s document borrows the nodes it read still. A
// refused allocation is the error, with nothing left allocated.
clone_document :: proc(doc: ^Document, allocator := context.allocator) -> (c: Document, err: runtime.Allocator_Error) {
	c = doc^
	c.allocator, c.partial = allocator, nil
	if .Borrowed not_in doc.flags {
		c.flags -= {.Mapped_Nodes}
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
			c.ext = ext_make(doc.ext.held, doc.ext.format, allocator, doc.ext.origin) or_return
		}
	}
	if x := doc.partial; x != nil {
		owned := .Borrowed not_in doc.flags
		y := partial_block(max(len(x.starts) - 1, 0), len(x.answers), len(x.kept) if owned else 0, len(x.missing) if owned else 0, len(x.names) if owned else 0, x.dups, allocator) or_return
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
	if paths < 0 || answers < 0 || kept < 0 || missing < 0 || names < 0 {
		return nil, .Invalid_Argument
	}
	starts_at := u64(size_of(Partial)) + u64(answers) * size_of(Answer)
	kept_at := starts_at + (u64(paths) + 1) * size_of(u32)
	missing_at := kept_at + u64(kept) * size_of(Kept_Child)
	names_at := missing_at + u64(missing) * size_of(Missing_Name)
	total := names_at + u64(names)
	if answers > max(int) / size_of(Answer) || paths >= max(int) / size_of(u32) || kept > max(int) / size_of(Kept_Child) || missing > max(int) / size_of(Missing_Name) || total > u64(max(int)) || total < names_at || names_at < missing_at || missing_at < kept_at || kept_at < starts_at {
		return nil, .Out_Of_Memory
	}
	block := runtime.mem_alloc_non_zeroed(int(total), align_of(Partial), allocator) or_return
	// An empty allocator gives no block and no error, or a shorter one, either read as a refusal.
	if len(block) < int(total) || raw_data(block) == nil {
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

@(private = "file")
clone_list :: proc(list: []$T, allocator: runtime.Allocator) -> (out: []T, err: runtime.Allocator_Error) {
	if len(list) == 0 {
		return nil, nil
	}
	if size_of(T) > 0 && len(list) > max(int) / size_of(T) {
		return nil, .Out_Of_Memory
	}
	need := len(list) * size_of(T)
	data := runtime.mem_alloc_non_zeroed(need, align_of(T), allocator) or_return
	if len(data) < need || raw_data(data) == nil {
		return nil, .Out_Of_Memory
	}
	out = ([^]T)(raw_data(data))[:len(list)]
	copy(out, list)
	return
}

// A `Doc_Ext` of `held`, `format` and `origin` in one block of `allocator`, with copies of the lists they name, which
// `destroy` frees whole.
ext_make :: proc(held: []Held_Span, format: Format_Ext, allocator: runtime.Allocator, origin := Origin{}) -> (ext: ^Doc_Ext, err: runtime.Allocator_Error) {
	f := format
	size := ext_lists(nil, held, &f)
	if size < 0 {
		return nil, .Out_Of_Memory
	}
	raw := runtime.mem_alloc_non_zeroed(size, align_of(Doc_Ext), allocator) or_return
	// An empty allocator gives no block and no error, or a shorter one, either read as a refusal.
	if len(raw) < size || raw_data(raw) == nil {
		return nil, .Out_Of_Memory
	}
	ext = (^Doc_Ext)(raw_data(raw))
	ext.origin, ext.format = origin, f
	ext_lists(raw_data(raw), held, &ext.format)
	return
}

// Places the lists of `held` and `format` in `base`, or only sizes them when `base == nil` (negative on overflow).
@(private = "file")
ext_lists :: proc "contextless" (base: [^]u8, held: []Held_Span, format: ^Format_Ext) -> int {
	size := size_of(Doc_Ext)
	if h := ext_list(&size, base, held); base != nil {
		(^Doc_Ext)(base).held = h
	}
	switch &f in format {
	case Tabular_Ext:
		f.tables, f.keys, f.slots = ext_list(&size, base, f.tables), ext_list(&size, base, f.keys), ext_list(&size, base, f.slots)
	case Markup_Ext:
		f.scopes, f.uris, f.uri_text = ext_list(&size, base, f.scopes), ext_list(&size, base, f.uris), ext_list(&size, base, f.uri_text)
		f.dtd.entities, f.dtd.attrs = ext_list(&size, base, f.dtd.entities), ext_list(&size, base, f.dtd.attrs)
		f.dtd.slots, f.dtd.bytes = ext_list(&size, base, f.dtd.slots), ext_list(&size, base, f.dtd.bytes)
	case Html_Ext:
		f.ends, f.texts, f.pieces = ext_list(&size, base, f.ends), ext_list(&size, base, f.texts), ext_list(&size, base, f.pieces)
	case nil:
	}
	return size
}

// Places a copy of `list` in `base`, aligned for its entries, or only advances `size^` when `base == nil`.
@(private = "file")
ext_list :: proc "contextless" (size: ^int, base: [^]u8, list: []$T) -> []T {
	if len(list) == 0 || size^ < 0 {
		return nil
	}
	pad := (-size^) & (align_of(T) - 1)
	if pad > max(int) - size^ || len(list) > (max(int) - size^ - pad) / size_of(T) {
		size^ = -1
		return nil
	}
	at := size^ + pad
	size^ = at + len(list) * size_of(T)
	if base == nil {
		return list
	}
	placed := ([^]T)(base[at:])[:len(list)]
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
	// `nodes` was reserved directly from the OS virtual memory manager (`nodes_reserve`) and is released via
	// `nodes_unmap` rather than `allocator`.
	Mapped_Nodes,
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
	Html_Ext,
}

// Per-document state of an HTML5 document: element closing offsets, multi-piece text spans (merged across comments or
// foster-parented runs), and whether scalar type inference was enabled.
Html_Ext :: struct {
	ends:   []Html_End, // sorted by node
	texts:  []Html_Text, // sorted by lo
	pieces: []Html_Span,
	infer:  bool,
}

// An HTML element container's closing offset in the document's source: `node` is its `.Object` node index, and `end`
// is the byte offset past its closing tag (or implied close).
Html_End :: struct {
	node: Node_Index,
	end:  u64,
}

#assert(size_of(Html_End) == 16)

// A multi-piece HTML text value's slice of `Html_Ext.pieces`: `lo` is the text node's start offset, and its spans are
// `Html_Ext.pieces[first:][:count]`.
Html_Text :: struct {
	lo:    u64,
	first: u32,
	count: u32,
}

#assert(size_of(Html_Text) == 16)

// One source span of a multi-piece HTML text value, with its HTML tokenizer mode and decode flags.
Html_Span :: struct {
	lo:    u64,
	n:     u32,
	mode:  u8,
	flags: u8,
}

#assert(size_of(Html_Span) == 16)

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
