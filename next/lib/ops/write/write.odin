package write

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"

// Writes of a built document as a text of a format. A format gives its grammar and spelling: its layout loop over the
// steps `tree_next` gives, or for a delimited format the rules of its cells, and how it spells a scalar. This package
// holds what every format shares: the walk over a document's values, the output, the text of a node, and which facts a
// write drops. A format forwards the write under its own name, `json.write`, `dsv.write`.

// Options of a write of any format.
Options :: struct {
	// Spaces a level, one value or member a line. 0 with `tab` false is compact text.
	indent: u8,
	tab:    bool, // a tab a level in place of `indent` spaces
	// The value written as a text of its own, the root by default. A key is no value, and `Bad_Option{"node"}`.
	node:   tape.Node_Index,
	// An object's members in the order of their keys' texts, byte by byte, and a table's columns by their names.
	sort_keys: bool,
	// A JSON target spells each character past ASCII in a string, key or comment as a `\u` escape, a surrogate pair
	// past U+FFFF.
	ascii:  bool,
	// Each value written is a record of its own: a line (NDJSON, a compact text only) or an RFC 7464 sequence's, which
	// starts with a record separator and ends with a line feed. A token writer takes any number of root values then.
	framing: Record_Framing,
	// A delimited token writer holds every row and writes the header of every key in first-seen order at its end. Without
	// it the header is the caller's, else the first row's keys, rows are written as they come, and a later row's key the
	// header lacks is `Refused{.Row_Keys}`. A write of a document writes the union of its keys either way.
	grow_header: bool,
	// The target's own options, as a read takes them: a delimited target's `Dsv_Options`. Nil takes those a delimited
	// document was read with, else the target's defaults. Another family's options are `Bad_Option{"format"}`.
	format: tape.Format_Options,
}

// How a text of values frames each one, as `Options.framing` says.
Record_Framing :: enum u8 {
	None,
	Lines,
	Seq,
}

// Why a write refused a value, which `Refused` names with its node.
Refusal :: enum u8 {
	// The target has no spelling that reads back as the value: a non-finite number in JSON, a byte string, a key that
	// is a container, a number wider than 64 bits with no decimal text, a cell a delimited spec cannot hold.
	No_Spelling,
	// A delimited target takes an array of rows, each an object of scalars or an array of scalars.
	Not_A_Table,
	// A row's keys are not the first row's, so its cells have no column.
	Row_Keys,
	// A container a path read kept only part of, or that a text cut inside its root left open, which would be written
	// as less than the text holds. A text cut inside a scalar root is this refusal at the root.
	Partial,
	// A token the sequence cannot take at that place, or one that opens past the depth a caller holds, with the index
	// of the token as `node`.
	Malformed,
}

// A value the target cannot write as the document holds it, and the node it is.
Refused :: struct {
	node: tape.Node_Index,
	why:  Refusal,
}

// The error of a write. A sink's failure is its `io.Error`, and the sink may hold a prefix of the text.
Error :: union {
	Refused,
	runtime.Allocator_Error,
	io.Error,
	tape.Bad_Option,
}

// Whether `opts` asks for compact text.
compact :: #force_inline proc "contextless" (opts: Options) -> bool {
	return opts.indent == 0 && !opts.tab
}

// The bytes a target text of `doc` under `opts` is likely to need, which a buffer output starts with, so a write seldom
// grows it: the source's length, which a compact write of a compact text matches, the room a write of whole blocks asks
// for past its last byte, and in indented text a line of eight levels for each node.
@(private)
size_hint :: proc "contextless" (doc: ^tape.Document, opts: Options) -> int {
	unit := 1 if opts.tab else int(opts.indent)
	return len(doc.src) + ROOM_MAX + (0 if compact(opts) else len(doc.nodes) * (3 + 8 * unit))
}
