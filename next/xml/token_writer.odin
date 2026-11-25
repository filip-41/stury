package xml

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The token writer: a caller writes an XML text one token at a time, as the object of one member `write` takes. An element
// is a member whose value holds its children, so the tokens are held as a document and `write` lays it out at
// `writer_end`. A refusal at the end names a node of that document, which counts each token but a close.

// A text being written token by token. It points into itself, so it is not copied once `writer_start` returns.
Writer :: struct {
	tape:      write.Token_Tape,
	spec:      Spec,
	opts:      Write_Options,
	sink:      io.Writer,
	allocator: runtime.Allocator,
}

// Starts `w` to write a text of `spec` under `opts` into `sink`, or into a buffer from `allocator` when `sink` has no
// procedure, which `writer_end` returns. `opts.framing` and `opts.format` are `Bad_Option`, and so are options `write`
// refuses.
writer_start :: proc(w: ^Writer, spec := Spec.Xml, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator) -> Write_Error {
	if opts.format != nil || opts.framing != .None || opts.ascii {
		return tape.Bad_Option{"format" if opts.format != nil else "options"}
	}
	w^ = {spec = spec, opts = opts, sink = sink, allocator = allocator}
	if e := write.token_tape_start(&w.tape, false, 0, allocator); e != nil {
		write.token_tape_drop(&w.tape)
		return e
	}
	return nil
}

// Writes `kind` with its `text`: the decoded text of a `.Key` or `.String`, which must be UTF-8, and the decimal text of a
// `.Number`, which must be a JSON number. The other kinds take none. A token the sequence cannot take here is
// `Refused{index, .Malformed}`, and a text with no spelling `Refused{index, .No_Spelling}`; neither is taken, and the
// writer takes the next token.
token :: proc(w: ^Writer, kind: write.Token_Kind, text := "") -> Write_Error {
	return write.token_tape_take(&w.tape, kind, text)
}

// Ends the text and writes it. The bytes of a buffer writer are returned, which the caller owns and frees with its
// allocator, and a sink writer returns none. A text that is no whole sequence is `Refused{index, .Malformed}`, and a
// value with no XML spelling is refused as `write` refuses it. `w` is not used again.
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	defer write.token_tape_drop(&w.tape)
	if !write.token_tape_done(&w.tape) {
		return nil, write.Refused{tape.Node_Index(w.tape.seq.taken), .Malformed}
	}
	doc := write.token_tape_document(&w.tape, as(w.spec))
	if w.sink.procedure != nil {
		_, err = write.to_sink(w.sink, &doc, u8(w.spec) | FROM_TOKENS, w.opts, w.allocator, write_out)
		return nil, err
	}
	text, _, err = write.to_buffer(&doc, u8(w.spec) | FROM_TOKENS, w.opts, w.allocator, write_out)
	return
}
