package core

import "base:runtime"
import "core:io"

// What a written text is spelled with, for every format. A field a format has no use for is ignored.
Write_Options :: struct {
	pretty:          bool, // one member or element a line. With `indent` 0 the lines carry no indent
	indent:          u8, // pretty: spaces per level
	tab:             bool, // pretty: one tab per level, in place of `indent`
	ascii:           bool, // a rune past U+007F is written as `\uXXXX`
	escape_html:     bool, // `<`, `>`, `&`, U+2028 and U+2029 are written as `\uXXXX`
	sort_keys:       bool, // a struct's fields and a document's keys in byte order. A map's keys are always sorted
	partial:         bool, // a partial document is written, as JSON, from the nodes its read kept. JSON only
	infer:           bool, // a delimited document written as JSON: a cell is the null, boolean or number it reads as, not a string
	respell_strings: bool, // a string read from a source is written in the writer's own escapes, as a computed one is
}

// Pretty with two spaces per level.
PRETTY :: Write_Options{pretty = true, indent = 2}

// The format a text is written as: its spelling, and the spec and layout bytes it dispatches on, as `Document.read` holds
// them for a text that was read. A format's `as` procedure makes one.
As :: struct {
	spelling: ^Spelling,
	read:     Read_As,
}

// Writes node `node` of `doc`, the root by default, as text in format `as`, as `opts` says, into new bytes from
// `allocator`. A node is written with its subtree and its comments, as a text of its own. A nil `as` is the format and
// layout `doc` was read in. A text read from a source keeps the spelling of its numbers and strings. A node the document
// does not hold, a key, a partial document without `opts.partial` and a document the format's writer does not write are
// `.Unsupported`. `dropped` counts the facts the format cannot hold, which is not an error. See `docs/writer.md`.
write :: proc(doc: ^Document, opts := Write_Options{}, as: Maybe(As) = nil, node := ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: Typed_Error) {
	return write_to(doc, opts, as, node, {}, allocator)
}

// `write` to `w`, as the text is made. On a refusal `w` may hold a prefix of the text.
write_stream :: proc(w: io.Stream, doc: ^Document, opts := Write_Options{}, as: Maybe(As) = nil, node := ROOT, allocator := context.allocator) -> (dropped: int, err: Typed_Error) {
	_, dropped, err = write_to(doc, opts, as, node, w, allocator)
	return
}

@(private)
write_to :: proc(doc: ^Document, opts: Write_Options, as: Maybe(As), node: Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, int, Typed_Error) {
	target := as.? or_else As{doc.spelling, doc.read}
	if target.spelling == nil || target.spelling.write == nil || int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, {kind = .Unsupported}
	}
	return target.spelling.write(doc, opts, target.read, node, stream, allocator)
}
