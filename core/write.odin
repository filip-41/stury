package core

import "base:runtime"
import "core:io"

// What a written text is spelled with, for every format. A field a format has no use for is ignored: a delimited text
// reads `sort_keys` alone, and a token write puts keys in the order of its calls.
Write_Options :: struct {
	pretty:          bool, // one member or element a line. With `indent` 0 the lines carry no indent
	indent:          u8, // pretty: spaces per level
	tab:             bool, // pretty: one tab per level, in place of `indent`
	ascii:           bool, // a rune past U+007F is written as `\uXXXX`
	escape_html:     bool, // `<`, `>`, `&`, U+2028 and U+2029 are written as `\uXXXX`
	escape_del:      bool, // DEL is written as `\u007f`, which `ascii` does as well. A string keeps it otherwise
	sort_keys:       bool, // a struct's fields and a document's keys in byte order. A map's keys are always sorted
	respell_strings: bool, // a string read from a source is written in the writer's own escapes, as a computed one is
	jq_numbers:      bool, // a built value's number that is not finite is written as jq writes it: NaN as null, an infinity as the largest double of its sign
}

// Pretty with two spaces per level.
PRETTY :: Write_Options{pretty = true, indent = 2}

// The handle of a format: its readers, and the spec, depth, tolerance and option bytes a text is read or written with. A
// format's `as` procedure makes one, and a document holds the one it was read with.
As :: struct {
	readers:   ^Readers,
	// The deepest nesting a read takes, 0 for `MAX_DEPTH`. An edit reads a value text at this depth.
	max_depth: u32,
	// The format's spec, which its services dispatch on.
	spec:      u8,
	// The rules a text read in the format may break.
	tolerate:  bit_set[Tolerance; u8],
	// The format's own bytes, opaque to core.
	opts:      [10]u8,
}

#assert(size_of(As) == 24)

// Writes node `node` of `doc`, the root by default, as text in format `as`, as `opts` says, into new bytes from
// `allocator`. A node is written with its subtree and its comments, as a text of its own. A nil `as` is the format and
// layout `doc` was read in. A text read from a source keeps the spelling of its numbers and strings. A node the document
// does not hold, a key and a document the format's writer does not write are
// `.Unsupported`. `dropped` counts the facts the format cannot hold, which is not an error. See `docs/writer.md`.
write :: proc(doc: ^Document, opts := Write_Options{}, as: Maybe(As) = nil, node := ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: Error) {
	out, cut, refusal := write_to(doc, opts, as, node, {}, allocator)
	return out, cut, error_of(refusal)
}

// `write` to `w`, as the text is made. On a refusal `w` may hold a prefix of the text.
write_stream :: proc(w: io.Stream, doc: ^Document, opts := Write_Options{}, as: Maybe(As) = nil, node := ROOT, allocator := context.allocator) -> (dropped: int, err: Error) {
	_, cut, refusal := write_to(doc, opts, as, node, w, allocator)
	return cut, error_of(refusal)
}

// Reads `src` as `as` says and writes it back in `as` as `opts` says, into new bytes from `allocator`, as `build` then
// `write` do. A text that is not a document of `as` is `.Walk` with the fault in `inner`, a refused allocation
// `.No_Memory`, and a handle with no format's build `.Unsupported`.
format :: proc(src: []u8, as: As, opts := Write_Options{}, allocator := context.allocator) -> ([]u8, Error) {
	doc, err := build(src, as, allocator = allocator)
	if err != nil {
		if _, refused := err.(Document_Error); refused {
			return nil, error_of(Typed_Error{kind = .Unsupported})
		}
		return nil, err
	}
	defer destroy(&doc)
	text, _, refusal := write_to(&doc, opts, nil, ROOT, {}, allocator)
	return text, error_of(refusal)
}

@(private)
write_to :: proc(doc: ^Document, opts: Write_Options, as: Maybe(As), node: Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, int, Typed_Error) {
	target := as.? or_else doc.as
	services := services_of(target)
	if services == nil || services.write == nil || int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, {kind = .Unsupported}
	}
	return services.write(doc, opts, target, node, stream, allocator)
}
