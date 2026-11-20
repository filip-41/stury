package tape

import "base:runtime"

// Documents are stury's parsed form of a text. Queries, writes, edits and format conversions read them, and a path
// query returns a partial one holding only the nodes it reached.

// Nodes and facts over the source bytes of parsed text. Immutable, so threads share it without locks. Array
// elements hold no pointers, so the arrays save and map as raw bytes.
Document :: struct {
	src:        []u8, // borrowed unless `.Owns_Src`
	nodes:      []Node,
	facts:      []Fact, // sorted by node, then source order
	counts:     []Child_Count, // sorted by node; only containers whose `spelling` saturated
	ext:        Format_Ext,
	format:     ^Format,
	allocator:  runtime.Allocator,
	root_close: u64, // end of the root value, so writing the root needs no scan
	origin:     u64, // offset of `src[0]` in the whole input
	present:    Facts, // fact kinds in `facts`
	flags:      Doc_Flags,
}

// How a document was built.
Doc_Flag :: enum u8 {
	Kinds_Stored, // every cell has its final kind: a `Plain` cell is a string or null
	Spelled_Tags, // some token carries a tag in its spelling (TOML datetimes)
	In_Order, // no aliases or merge keys, so children follow their container
	Owns_Src,
	Partial, // a path read kept only part of the text
	Stopped, // the read stopped early; the text past the stop was not validated
}

Doc_Flags :: bit_set[Doc_Flag; u8]

// Per-format data beside the nodes, nil for formats that store none.
Format_Ext :: union {
	^Tabular_Ext,
	^Yaml_Ext,
}

// dsv's tables and their key lookup slots.
Tabular_Ext :: struct {
	tables: []Table,
	slots:  []u16,
}

// A container whose members are rows of cells.
Table :: struct {
	node:        Node_Index,
	header:      Node_Index, // the keys' `Array` node, 0 for none
	first_row:   Node_Index, // row `k` is at `first_row + k * (width + 1)`
	width:       u32, // 0 for ragged rows
	slots_lo:    u32, // this table's key slots: `Tabular_Ext.slots[slots_lo:][:slots_len]`
	slots_len:   u32,
	unique_keys: b32, // no two keys decode equal, so a lookup stops at the first match
}

Yaml_Ext :: struct {
	clash: u64, // first key whose text equals another key's in its object (`1` and `"1"`), 0 for none
}

// A document of only the nodes a path query reached, with each path's answers.
Partial_Result :: struct {
	doc:     Document,
	answers: []Answer,
	kept:    []Kept_Child, // sorted by node
	missing: []Missing_Name, // sorted by node
	block:   []u8, // backs the three lists and the missing names' bytes
}

// Whether a path read found a value.
Presence :: enum u8 {
	Found,
	Missing,
	Wrong_Kind, // a step cannot enter this value
	Not_Loaded, // a partial read did not keep it, so it may or may not exist
}

// One value a path reached.
Answer :: struct {
	node:    Node_Index, // set only for `.Found`
	// The found value's container (`NO_NODE` at the root), the deepest container reached for `.Missing`, or the value a
	// step could not enter for `.Wrong_Kind`.
	owner:   Node_Index,
	path:    u32,
	outcome: Presence,
}

// A kept child's position in its original container.
Kept_Child :: struct {
	node:  Node_Index,
	index: u32,
}

// A name looked up in `node` and not found.
Missing_Name :: struct {
	node: Node_Index,
	lo:   u32, // the name is `block[lo:][:n]`
	n:    u32,
}
