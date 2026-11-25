package dsv

import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The token writer and record writer: a caller writes the rows of a delimited text as values, one token at a time or a
// record's value at a time. The rows are written in batches as they come, under a header that is `opts.header` or the
// first row's keys, so a row that lacks a key has an empty cell and a row with a key the header lacks is
// `Refused{.Row_Keys}`, and the memory held is a batch. Under `opts.grow_header` every row is held and written at
// `writer_end` under a header of every key in first-seen order. A table of objects is the root array of them, or under
// `opts.framing` of `.Lines` each root value is a row. A refusal names the token of the row, counting each token but a
// close from 0, and comes from the token that fills a batch or from `writer_end`.

// A text being written token by token. It points into itself, so it is not copied once `writer_start` returns.
Writer :: struct {
	tw: write.Table_Writer,
}

// Starts `w` to write a text of `spec` under `opts` into `sink`, or into a buffer from `allocator` when `sink` has no
// procedure, which `writer_end` returns. `opts.framing` is `.None` for the tokens of one array of rows, or `.Lines`
// for any number of root values, each a row. `.Seq` is `Bad_Option{"framing"}`. `opts.header` names the keys of the
// rows' header, which a first row's keys are when empty, and `Bad_Option{"header"}` under `opts.grow_header` or when a
// key repeats.
writer_start :: proc(w: ^Writer, spec := Spec.Csv, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	if u8(spec) > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	cells, d, _, err := resolve_options(spec, opts, nil, allocator)
	if err != nil {
		return err
	}
	return write.table_writer_start(&w.tw, &FORMATS[spec], cells, d, opts, sink, allocator)
}

// Writes `kind` with its `text`, as `json.token` takes them. A token the sequence cannot take here is
// `Refused{index, .Malformed}`, and a text with no spelling `Refused{index, .No_Spelling}`; neither is taken, and the
// writer takes the next token.
token :: proc(w: ^Writer, kind: Token_Kind, text := "") -> Write_Error {
	return write.table_writer_token(&w.tw, kind, text)
}

// Writes value `node` of `doc`, a document of any format, as a row, or under no framing the tokens of that value: the
// records a read hands on, one at a time, with the tokens of `token` as their route.
put :: proc(w: ^Writer, doc: ^tape.Document, node := tape.ROOT) -> Write_Error {
	return write.tokens_of(doc, node, w, token, w.tw.allocator)
}

// Ends the text and writes it. The bytes of a buffer writer are returned, which the caller owns and frees with its
// allocator, and a sink writer returns none. A text that is no whole sequence is `Refused{index, .Malformed}`, and a
// row with no delimited spelling is refused as `write` refuses it. `w` is not used again.
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	return write.table_writer_end(&w.tw)
}

// Aborts `w` and frees its buffers without flushing pending rows or returning text. `w` is not used again.
writer_drop :: proc(w: ^Writer) {
	write.table_writer_drop(&w.tw)
}
