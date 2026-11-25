package dsv

import "base:runtime"
import "core:io"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// The token writer and record writer: a caller writes the rows of a delimited text as values, one token at a time or a
// record's value at a time. The rows are written in batches as they come, under a header that is the caller's or the
// first row's keys, so a row that lacks a key has an empty cell and a row with a key the header lacks is
// `Refused{.Row_Keys}`, and the memory held is a batch. Under `opts.grow_header` every row is held and written at
// `writer_end` under a header of every key in first-seen order. A table of objects is the root array of them, or under
// `opts.framing` of `.Lines` each root value is a row. A refusal names the token of the row, counting each token but a
// close from 0, and comes from the token that fills a batch or from `writer_end`.

// A batch ends at the first row that closes once it holds this many nodes or bytes of text.
@(private)
BATCH_NODES :: 8192
@(private)
BATCH_BYTES :: 256 * 1024

// A text being written token by token. It points into itself, so it is not copied once `writer_start` returns.
Writer :: struct {
	tape:      write.Token_Tape, // every token under `grow_header`, else the rows of the batch
	spec:      Spec,
	opts:      Write_Options,
	sink:      io.Writer,
	allocator: runtime.Allocator,
	out:       write.Out, // of a table written in batches
	stream:    write.Table_Stream,
	seq:       write.Sequence, // the order of the tokens of a table written in batches
	streaming: bool,
	rows_root: bool, // the root array holds the rows, which the batches do not take as a row
	base:      int, // the token the batch's first row is
	carried:   int, // the nodes of the batch's carrier of the header
	err:       Write_Error, // the first failure, which ends the writer
}

// Starts `w` to write a text of `spec` under `opts` into `sink`, or into a buffer from `allocator` when `sink` has no
// procedure, which `writer_end` returns. `opts.framing` is `.None` for the tokens of one array of rows, or `.Lines`
// for any number of root values, each a row. `.Seq` and `opts.node` have no meaning for rows, and `.Seq` is
// `Bad_Option{"framing"}`. `header` names the keys of the rows' header, which a first row's keys are when it is empty,
// and `Bad_Option{"header"}` under `opts.grow_header` or when a key repeats.
writer_start :: proc(w: ^Writer, spec := Spec.Csv, opts := Write_Options{}, sink := io.Writer{}, allocator := context.allocator, header: []string = nil) -> Write_Error {
	if opts.framing == .Seq {
		return tape.Bad_Option{"framing"}
	}
	if opts.grow_header && len(header) > 0 {
		return tape.Bad_Option{"header"}
	}
	w^ = {spec = spec, opts = opts, sink = sink, allocator = allocator, streaming = !opts.grow_header}
	w.opts.framing = .None
	framed := opts.framing == .Lines
	if w.streaming {
		write.table_stream_start(&w.stream, header, opts.sort_keys, allocator) or_return
		if e := write.out_start(&w.out, allocator, sink, 0); e != nil {
			write.table_stream_drop(&w.stream)
			return e
		}
		write.sequence_start(&w.seq, framed, 0, allocator)
	}
	if e := write.token_tape_start(&w.tape, framed || w.streaming, 0, allocator); e != nil {
		writer_drop(w)
		return e
	}
	if w.streaming {
		if e := batch_start(w); e != nil {
			writer_drop(w)
			return e
		}
	}
	return nil
}

// Writes `kind` with its `text`, as `json.token` takes them. A token the sequence cannot take here is
// `Refused{index, .Malformed}`, and a text with no spelling `Refused{index, .No_Spelling}`; neither is taken, and the
// writer takes the next token.
token :: proc(w: ^Writer, kind: write.Token_Kind, text := "") -> Write_Error {
	if !w.streaming {
		return write.token_tape_take(&w.tape, kind, text)
	}
	if w.err != nil {
		return w.err
	}
	if !write.token_text_ok(kind, text) {
		return write.Refused{tape.Node_Index(w.seq.taken), .No_Spelling}
	}
	first := w.seq.taken == 0
	place := write.sequence_take(&w.seq, kind) or_return
	if first {
		w.rows_root = w.opts.framing == .None && kind == .Array
		w.base = 1 if w.rows_root else 0
	}
	if w.rows_root && place.root {
		return nil
	}
	if err := write.token_tape_take(&w.tape, kind, text); err != nil {
		w.err = err
		return err
	}
	if w.tape.seq.depth == 0 && (len(w.tape.nodes) >= BATCH_NODES || len(w.tape.texts) >= BATCH_BYTES) {
		w.err = batch_write(w)
		return w.err
	}
	return nil
}

// Writes value `node` of `doc`, a document of any format, as a row, or under no framing the tokens of that value: the
// records a read hands on, one at a time, with the tokens of `token` as their route.
put :: proc(w: ^Writer, doc: ^tape.Document, node := tape.ROOT) -> Write_Error {
	return write.tokens_of(doc, node, w, token, w.allocator)
}

// Ends the text and writes it. The bytes of a buffer writer are returned, which the caller owns and frees with its
// allocator, and a sink writer returns none. A text that is no whole sequence is `Refused{index, .Malformed}`, and a
// row with no delimited spelling is refused as `write` refuses it. `w` is not used again.
writer_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	defer writer_drop(w)
	if w.streaming {
		return streamed_end(w)
	}
	if !write.token_tape_done(&w.tape) {
		return nil, write.Refused{tape.Node_Index(w.tape.seq.taken), .Malformed}
	}
	doc := write.token_tape_document(&w.tape, &FORMATS[w.spec])
	if w.sink.procedure != nil {
		_, err = write.to_sink(w.sink, &doc, u8(w.spec), w.opts, w.allocator, write_out)
		return nil, err
	}
	text, _, err = write.to_buffer(&doc, u8(w.spec), w.opts, w.allocator, write_out)
	return
}

// Frees what `w` holds.
@(private)
writer_drop :: proc(w: ^Writer) {
	write.token_tape_drop(&w.tape)
	if w.streaming {
		write.sequence_drop(&w.seq)
		write.table_stream_drop(&w.stream)
		if w.out.buf != nil {
			write.out_drop(&w.out)
		}
	}
}

// Ends a table written in batches: the rows held, then the output.
@(private)
streamed_end :: proc(w: ^Writer) -> (text: []u8, err: Write_Error) {
	if w.err != nil {
		return nil, w.err
	}
	framed := w.opts.framing == .Lines
	if !(write.sequence_done(&w.seq) || framed && w.seq.depth == 0) {
		return nil, write.Refused{tape.Node_Index(w.seq.taken), .Malformed}
	}
	// A header with no row is a text of its own.
	if len(w.tape.nodes) > 1 + w.carried || w.stream.known && !w.stream.headed {
		if err = batch_write(w); err != nil {
			return nil, err
		}
	}
	text, err = write.out_finish(&w.out)
	w.out = {}
	return
}

// Starts the next batch, which holds the carrier of the header when it is known.
@(private)
batch_start :: proc(w: ^Writer) -> (err: Write_Error) {
	w.carried = write.table_stream_carry(&w.stream, &w.tape) or_return
	return nil
}

// Writes the batch's rows into the output and starts the next batch. A refusal names the token of the row.
@(private)
batch_write :: proc(w: ^Writer) -> Write_Error {
	doc := write.token_tape_document(&w.tape, &FORMATS[w.spec])
	opts := w.opts
	_, err := write_rows(&w.out, &doc, u8(w.spec), opts, w.allocator, &w.stream)
	if refused, ok := err.(write.Refused); ok {
		refused.node = tape.Node_Index(w.base + max(int(refused.node) - 1 - w.carried, 0))
		return refused
	}
	if err != nil {
		return err
	}
	w.base += len(w.tape.nodes) - 1 - w.carried
	write.token_tape_reset(&w.tape)
	return batch_start(w)
}
