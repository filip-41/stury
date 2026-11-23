package tape

import "base:runtime"

// Documents are stury's parsed form of a text. Queries, writes, edits and format conversions read them, and a path
// query returns a partial one holding only the nodes it reached.

// Nodes and facts over the source bytes of parsed text. Immutable, so threads share it without locks.
Document :: struct {
	src:        []u8, // borrowed unless `.Owns_Src`
	// The root value's subtree starts at 0 and has `nodes[0].n` nodes. A format whose document holds more than the root
	// value stores it after the subtree, in no container, as a table's header is (see `Tabular_Ext`), so a loop over all
	// of `nodes` is no walk of the root's subtree.
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
	destroy_children,
	destroy_pieces,
}

// Frees what `doc` holds and leaves it zero. The source is freed only under `.Owns_Src`.
destroy_document :: proc(doc: ^Document) {
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
}

Doc_Flags :: bit_set[Doc_Flag; u8]

// What a document holds beside its nodes, facts and counts, in one block with the lists it names, which `destroy` frees
// whole.
Doc_Ext :: struct {
	// Under `.Held`, where the bytes of each token are in `Document.src`, sorted by offset: a token's span starts at the
	// last `lo` at or before its own.
	held:   []Held_Span,
	format: Format_Ext,
}

// Per-format data beside the nodes, nil for formats that store none.
Format_Ext :: union {
	Tabular_Ext,
	Yaml_Ext,
}

// dsv's tables and their key lookup slots. A table's header is an `Array` of role `Key` stored past the root value's
// subtree, which no reader reaches from the root: they take the header's keys by its node.
Tabular_Ext :: struct {
	tables:  []Table,
	slots:   []u32,
	// The policy the build took a header's repeated keys by, which says which cells of a repeated name a row keeps.
	dups:    Duplicates,
	// The options the text was read with, its delimiter the spec's own byte when the build left it 0.
	options: Dsv_Options,
}

// An array whose elements are rows, each an object of scalar cells and no keys, which the header's keys name by
// place: cell `j` of a row is the member whose key is the header's element `j`, and a row of fewer cells lacks the
// members past them. The header, when there is one, is an array of keys in no container: a build stores it past the
// root value's nodes. Tables are sorted by node, and an object inside a table's node is one of its rows.
Table :: struct {
	node:        Node_Index,
	header:      Node_Index, // the keys' `Array` node, 0 for none
	first_row:   Node_Index, // row `k` is at `first_row + k * (width + 1)`
	width:       u32, // 0 for ragged rows
	// This table's key slots, `Tabular_Ext.slots[slots_lo:][:slots_len]`, a power of two of them or none: a key's
	// column plus one, by `Format.key_hash` of its text, 0 for an empty slot.
	slots_lo:    u32,
	slots_len:   u32,
	unique_keys: b32, // no two keys decode equal, so a lookup stops at the first match
}

Yaml_Ext :: struct {
	// The first key whose text another key of its object of another kind has (`1` and `"1"`), 0 for none, so the
	// readers look for such a pair only in a document that has one.
	clash: u64,
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
	Ambiguous, // keys of two kinds read as the name, as YAML's `1` and `"1"`, so a read by name under `.Last` refuses it
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
