package xml

import "core:io"
import "stury:lib/ops/write"

// The token writer: a caller writes an XML text one token at a time, the tokens of an object of one member, the root
// element, as `write` takes it. An element is laid out by all its children, so the tokens are held as a document, the
// whole text, and `write` lays it out at `writer_end`. A refusal of `token` and of an unfinished text counts every
// token from 0, closes too. A refusal of `write` at the end names a node of the document, which counts every token but
// a close.

// A text being written token by token. It points into itself, so it is not copied once `writer_start` returns.
Writer :: struct {
	tw: write.Tape_Writer,
}

// Starts `w` to write a text of `spec` under `opts` into `sink`, or into a buffer from `allocator` when `sink` has no
// procedure, which `writer_end` returns. `opts.node`, `opts.framing` and `opts.format` are `Bad_Option`, and so are
// options `write` refuses.
@(require_results)
writer_start :: proc(w: ^Writer, spec := Spec.Xml, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	write_check(u8(spec), opts) or_return
	return write.tape_writer_start(&w.tw, u8(spec), opts, sink, allocator, write_out)
}

// Writes `kind` with its `text`: the decoded text of a `.Key` or `.String`, which must be UTF-8, and the decimal text of a
// `.Number`, which must be a JSON number. The other kinds take none. A token the sequence cannot take here is
// `Refused{index, .Malformed}`, and a text with no spelling `Refused{index, .No_Spelling}`; neither is taken, and the
// writer takes the next token.
@(require_results)
token :: proc(w: ^Writer, kind: Token_Kind, text := "") -> Write_Error {
	return write.token_tape_take(&w.tw.tokens, kind, text)
}

// Ends the text and writes it. The bytes of a buffer writer are returned, which the caller owns and frees with its
// allocator, and a sink writer returns none. A text that is no whole sequence is `Refused{index, .Malformed}`, and a
// value with no XML spelling is refused as `write` refuses it. `w` is not used again.
@(require_results)
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	return write.tape_writer_end(&w.tw)
}

// Aborts `w` and frees its buffers without writing text. `w` is not used again.
writer_drop :: proc(w: ^Writer) {
	write.tape_writer_drop(&w.tw)
}
