package write

import "base:runtime"
import "core:io"
import "core:slice"
import "core:strings"
import "stury:lib/core/tape"

// Streaming and buffered delimited token writer (`Table_Writer`): streams rows in batches under the caller's or first
// row's header, or holds every row under `opts.grow_header` until `table_writer_end`.

// What a table written in batches keeps from one batch to the next, so its rows are written as they come and no union of
// keys is held. Objects whose keys the header lacks are `Refused{.Row_Keys}`, and rows of another shape than the
// first's `Refused{.Not_A_Table}`.
@(private)
Table_Stream :: struct {
	names:     [dynamic]string, // the header's keys in the order they are written
	known:     bool, // `names` is the header
	headed:    bool, // the header line is written
	started:   bool, // a line is written
	shape:     Rows_Shape,
	width:     int, // the cells of each row of `.Cells`
	allocator: runtime.Allocator,
}

// What a table's rows are.
@(private)
Rows_Shape :: enum u8 {
	Unset,
	Objects,
	Cells,
	Scalars,
}

// A batch ends at the first row that closes once it holds this many nodes or bytes of text.
@(private = "file")
BATCH_NODES :: 8192
@(private = "file")
BATCH_BYTES :: 256 * 1024

// A delimited text being written token by token, streaming rows in batches under the caller's or first row's header,
// or holding every row under `opts.grow_header`. It points into itself, so it is not copied once started.
Table_Writer :: struct {
	tokens:    Token_Tape, // every token under `grow_header`, else the rows of the current batch
	target:    ^tape.Format,
	cells:     Cells,
	d:         tape.Dsv_Options,
	opts:      Options,
	sink:      io.Writer,
	allocator: runtime.Allocator,
	out:       Out, // of a table written in batches
	stream:    Table_Stream,
	seq:       Sequence, // the order of the tokens of a table written in batches
	special:   [256]bool,
	lead:      [256]bool,
	probe:     [SPECIAL_MAX]Lanes16,
	framed:    bool, // `opts.framing == .Lines`: each root value is a row
	streaming: bool, // `!opts.grow_header`
	rows_root: bool, // the root array holds the rows, which the batches do not take as a row
	base:      u64, // the token index the batch's first row starts at
	err:       Error, // the first failure, which ends the writer
}

// Starts `w` for a delimited target `target` with cell rules `cells` and validated options `d` (delimiter resolved).
@(require_results)
table_writer_start :: proc(w: ^Table_Writer, target: ^tape.Format, cells: Cells, d: tape.Dsv_Options, opts: Options, sink: io.Writer, allocator: runtime.Allocator) -> Error {
	if opts.node != tape.ROOT {
		return tape.Bad_Option{"node"}
	}
	if opts.framing == .Seq || opts.framing > max(Record_Framing) {
		return tape.Bad_Option{"framing"}
	}
	if opts.indent != 0 || opts.tab {
		return tape.Bad_Option{"indent"}
	}
	if opts.ascii {
		return tape.Bad_Option{"ascii"}
	}
	if opts.grow_header && len(opts.header) > 0 {
		return tape.Bad_Option{"header"}
	}
	framed := opts.framing == .Lines
	streaming := !opts.grow_header
	w^ = {target = target, cells = cells, d = d, opts = opts, sink = sink, allocator = allocator, framed = framed, streaming = streaming}
	w.opts.framing = .None
	if streaming {
		init_cell_tables(&w.special, &w.lead, &w.probe, cells, d)
		table_stream_start(&w.stream, opts.header, opts.sort_keys, allocator) or_return
		if e := out_start(&w.out, allocator, sink, 0); e != nil {
			table_stream_drop(&w.stream)
			return e
		}
		sequence_start(&w.seq, framed, 0, allocator)
	}
	if e := token_tape_start(&w.tokens, framed || streaming, 0, allocator); e != nil {
		table_writer_drop(w)
		return e
	}
	return nil
}

// Takes one token for `w`.
@(require_results)
table_writer_token :: proc(w: ^Table_Writer, kind: Token_Kind, text := "") -> Error {
	if !w.streaming {
		return token_tape_take(&w.tokens, kind, text)
	}
	if w.err != nil {
		return w.err
	}
	spelling, ok := token_text_ok(kind, text)
	if !ok {
		return Refused{tape.Node_Index(w.seq.taken), .No_Spelling}
	}
	first := w.seq.taken == 0
	place := sequence_take(&w.seq, kind) or_return
	if first {
		w.rows_root = !w.framed && kind == .Array
		w.base = 1 if w.rows_root else 0
	}
	if w.rows_root && place.root {
		return nil
	}
	if err := token_tape_push(&w.tokens, kind, text, spelling); err != nil {
		w.err = err
		return err
	}
	if len(w.tokens.open) == 1 && (len(w.tokens.nodes) >= BATCH_NODES || len(w.tokens.texts) >= BATCH_BYTES) {
		w.err = table_batch_write(w)
		return w.err
	}
	return nil
}

// Ends `w` and writes any remaining rows.
@(require_results)
table_writer_end :: proc(w: ^Table_Writer) -> (text: []u8, err: Error) {
	defer table_writer_drop(w)
	if w.streaming {
		if w.err != nil {
			return nil, w.err
		}
		if !sequence_done(&w.seq) {
			return nil, Refused{tape.Node_Index(w.seq.taken), .Malformed}
		}
		// A header with no row is a text of its own.
		if len(w.tokens.nodes) > 1 || w.stream.known && !w.stream.headed {
			if err = table_batch_write(w); err != nil {
				return nil, err
			}
		}
		return out_finish(&w.out)
	}
	doc := token_tape_finish(&w.tokens) or_return
	out: Out
	hint := 0 if w.sink.procedure != nil else size_hint(&doc, w.opts)
	if e := out_start(&out, w.allocator, w.sink, hint); e != nil {
		return nil, e
	}
	if _, err = table(&out, &doc, w.target, w.cells, w.d, false, w.opts, w.allocator); err != nil {
		out_drop(&out)
		return nil, err
	}
	return out_finish(&out)
}

// Frees every buffer `w` holds without flushing pending rows to its sink or returning text.
table_writer_drop :: proc(w: ^Table_Writer) {
	token_tape_drop(&w.tokens)
	if w.streaming {
		sequence_drop(&w.seq)
		table_stream_drop(&w.stream)
		if w.out.buf != nil {
			out_drop(&w.out)
		}
	}
	w^ = {}
}

// Writes the current batch of `w` into its output and resets the tape for the next batch.
@(private = "file")
table_batch_write :: proc(w: ^Table_Writer) -> Error {
	doc, derr := token_tape_document(&w.tokens)
	if derr != nil {
		return derr
	}
	t := Table_Write{
		out     = &w.out,
		cells   = w.cells,
		d       = w.d,
		stream  = &w.stream,
		whole   = true,
		started = w.stream.started,
		special = w.special,
		lead    = w.lead,
		probe   = w.probe,
	}
	_, err := table_run(&t, &doc, {}, w.opts, w.opts.sort_keys && !w.stream.known, w.allocator)
	w.stream.started = t.started
	if refused, ok := err.(Refused); ok {
		idx := w.base + u64(max(int(refused.node) - 1, 0))
		refused.node = tape.Node_Index(min(idx, u64(max(u32))))
		return refused
	}
	if err != nil {
		return err
	}
	w.base += u64(len(w.tokens.nodes) - 1)
	token_tape_reset(&w.tokens)
	return nil
}

// Starts `s` under `header`, whose keys are copied, in the order of their texts under `sort_keys`, nil for the keys of
// the first row. A key repeated is `Bad_Option{"header"}`.
@(private = "file")
table_stream_start :: proc(s: ^Table_Stream, header: []string, sort_keys: bool, allocator: runtime.Allocator) -> Error {
	s^ = {allocator = allocator, known = len(header) > 0}
	s.names.allocator = allocator
	for k in header {
		name, err := strings.clone(k, allocator)
		if err != nil {
			table_stream_drop(s)
			return err
		}
		if _, err = append(&s.names, name); err != nil {
			delete(name, allocator)
			table_stream_drop(s)
			return err
		}
	}
	if sort_keys {
		slice.stable_sort(s.names[:])
	}
	repeated := false
	if len(header) > 1 {
		copied, cerr := slice.clone(s.names[:], allocator)
		if cerr != nil {
			table_stream_drop(s)
			return cerr
		}
		slice.sort(copied)
		for i in 1 ..< len(copied) {
			repeated ||= copied[i] == copied[i - 1]
		}
		delete(copied, allocator)
	}
	if repeated {
		table_stream_drop(s)
		return tape.Bad_Option{"header"}
	}
	return nil
}

// Frees what `s` holds.
@(private = "file")
table_stream_drop :: proc(s: ^Table_Stream) {
	for name in s.names {
		delete(name, s.allocator)
	}
	delete(s.names)
	s^ = {}
}

// Judges the shape of the rows of a batch as the stream's: the first batch sets it, and a batch of the header's keys
// carries them first.
@(private)
stream_shape :: proc(t: ^Table_Write, root: tape.Node_Index, h: Header, objects: bool) -> bool {
	s := t.stream
	shape := Rows_Shape.Objects if h.node != tape.NO_NODE && objects else Rows_Shape.Scalars if h.scalars else Rows_Shape.Cells
	if s.shape == .Unset {
		s.shape, s.width = shape, h.width
	}
	switch {
	case shape != s.shape:
		t.w.err = Refused{root + 1, .Not_A_Table}
	case shape == .Cells && h.width != s.width:
		t.w.err = Refused{root + 1, .Row_Keys}
	case:
		return true
	}
	return false
}

// Keeps the keys of the first row of a stream whose header is not known, in the order they are written, as its header.
@(private)
stream_names :: proc(t: ^Table_Write, h: Header) -> bool {
	s := t.stream
	if s.known || h.node == tape.NO_NODE {
		return true
	}
	for c in 0 ..< h.width {
		text, ok := text_of(t.w, t.keys_at[column(t, c)])
		if !ok {
			return false
		}
		name, err := strings.clone(text, s.allocator)
		if err != nil {
			t.w.err = err
			return false
		}
		if _, err = append(&s.names, name); err != nil {
			delete(name, s.allocator)
			t.w.err = err
			return false
		}
	}
	s.known = true
	if t.order != nil {
		delete(t.order, t.w.allocator)
		t.order = nil
	}
	return true
}
