package main

// Reads --from csv and --from tsv input. Each file's first record is its header. Every later record is one input:
// an object mapping header names to the cells' text as strings (`csv.record_document`). An empty cell is null; a
// quoted `""` is the empty string. A regular file is read whole (`csv.records`). A pipe, a terminal, a file larger than STREAM_FILE_MIN and
// any file under -n are read through `csv.records_from`, whose window holds the longest record. A duplicate header
// name, a record of a different width and a syntax fault end the file and are reported as `FILE:LINE:COLUMN: fault`.

import "base:runtime"
import "core:io"
import "core:os"
import core_pkg "../../core"
import csv "../../csv"
import "jq"
import "message"

// The bytes read from a regular file into the window per read.
CELLS_CHUNK :: 1 << 20

// The stream a window is read from. It counts the newlines it has returned, because fault positions and
// `input_line_number` need them after the window has dropped those bytes.
Cells_Source :: struct {
	ins:      ^Inputs,
	file:     ^os.File,
	regular:  bool,
	newlines: int,
	err:      os.Error, // the read that failed
}

// The state of the CSV file being read, heap-allocated. A record's document copies the header's names, so it
// outlives its file (-s, -n).
Cells :: struct {
	dialect:  csv.Dialect,
	open:     bool, // a file's records are being read
	streamed: bool, // read through `rr` from `source`, else `whole` over the input's data
	whole:    csv.Records,
	rr:       csv.Record_Reader,
	source:   Cells_Source,
	header:   csv.Header, // empty until the file's first record is read
	line_at:  int, // the stream offset `cells_line` last counted to; `line_no` is the line count there
	line_no:  int,
}

// Returns the next input object of the CSV files (jq's next_input with the file's header applied), or a parse
// error with the fault's file, line and column.
next_cells :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	rec, msg, status := next_row(ins)
	if status != .Value {
		return nil, msg, status
	}
	return record_value(ins.run, rec, &ins.cells.header), "", .Value
}

// Returns the next record after the current file's header. Returns `.Error` with the fault that ended the file, or
// `.More` when no file is left.
next_row :: proc(ins: ^Inputs) -> (rec: csv.Record, msg: string, status: jq.Parse_Status) {
	c := cells_of(ins)
	for {
		if !c.open {
			if msg, status = open_cells(ins, c); status != .Value {
				return
			}
		}
		if r, ok := next_cell(c); ok {
			return r, "", .Value
		}
		if msg = cells_ended(ins, c); msg != "" {
			return {}, msg, .Error
		}
	}
}

// Returns the CSV read state, creating it on first use.
cells_of :: proc(ins: ^Inputs) -> ^Cells {
	if ins.cells == nil {
		ins.cells = new(Cells, runtime.heap_allocator())
		ins.cells.dialect = cells_in(&ins.run.opts)
	}
	return ins.cells
}

next_cell :: proc(c: ^Cells) -> (csv.Record, bool) {
	if c.streamed {
		return csv.next_record(&c.rr)
	}
	return csv.next_record(&c.whole)
}

// Opens the next readable file that has a header, and reads the header. Returns `.More` when no file is left.
open_cells :: proc(ins: ^Inputs, c: ^Cells) -> (msg: string, status: jq.Parse_Status) {
	for open_next(ins) {
		if !c.streamed {
			if ins.data == nil {
				continue
			}
			c.whole = csv.records(ins.data, {dialect = c.dialect}, runtime.heap_allocator())
		}
		c.open = true
		got: bool
		if _, got, msg = read_header(ins, c); msg != "" {
			end_cells_file(ins, c)
			return msg, .Error
		}
		if !got {
			if msg = cells_ended(ins, c); msg != "" {
				return msg, .Error
			}
			continue
		}
		return "", .Value
	}
	return "", .More
}

// Reads file `f`, which `open_next` opened, through `csv.records_from` a chunk at a time.
stream_cells :: proc(ins: ^Inputs, f: ^os.File) {
	c := cells_of(ins)
	c.streamed = true
	c.source = {ins, f, is_regular_file(f), 0, nil}
	c.rr = csv.records_from({cells_read, &c.source}, {dialect = c.dialect}, runtime.heap_allocator())
	if c.source.regular {
		c.rr.chunk = CELLS_CHUNK
	}
}

// The `io.Stream` procedure `records_from` reads the open file through. Before each read of a non-regular file,
// pending output is flushed.
@(private = "file")
cells_read :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, _: i64, _: io.Seek_From) -> (n: i64, err: io.Error) {
	s := (^Cells_Source)(data)
	#partial switch mode {
	case .Read:
		if !s.regular {
			flush_some(s.ins.run, force = true)
		}
		got, rerr := read_some(s.file, p)
		s.newlines += count_newlines(p[:got])
		if got > 0 {
			return i64(got), nil
		}
		if rerr != nil && rerr != io.Error.EOF {
			s.err = rerr
			return 0, .Unknown
		}
		return 0, .EOF
	case .Query:
		return io.query_utility({.Read})
	}
	return 0, .Empty
}

// Reads the open file's first record as its header. Returns the record, false for a file of none, and an error
// message when a name repeats.
@(private)
read_header :: proc(ins: ^Inputs, c: ^Cells) -> (rec: csv.Record, found: bool, msg: string) {
	if rec, found = next_cell(c); !found {
		return
	}
	h, err := csv.header_of(rec, .Refuse, runtime.heap_allocator())
	e, bad := err.?
	if !bad {
		c.header = h
		return
	}
	if e.kind != .Duplicate_Key {
		out_of_memory(ins.run)
	}
	e.offset -= rec.at - rec.fields[0].lo
	for f, k in rec.fields {
		if f.lo == e.offset {
			name, _, _ := csv.field_text(rec, k, context.temp_allocator)
			return rec, true, cells_message(ins, c, e, message.build_temp("Duplicate header name %q", name))
		}
	}
	unreachable()
}

// Returns the record as the document the interpreter reads (`csv.record_document`), in the context allocator,
// which is an arena.
record_value :: proc(run: ^Run, rec: csv.Record, h: ^csv.Header) -> jq.Value {
	doc, err := csv.record_document(rec, h)
	if err != nil {
		out_of_memory(run)
	}
	return jq.Ref{new_clone(doc), core_pkg.ROOT}
}

// Runs `check` on a whole CSV text. Returns the message a filter run would give, or "" when the text is valid.
// `csv.validate` checks the text without allocating, in parallel when `runner` is set. The header is read
// separately for repeated names, which validate does not check. The text is read again only after a fault, to
// report it as a filter run does.
check_cells_text :: proc(ins: ^Inputs, dialect: csv.Dialect, runner: ^csv.Batch_Runner) -> string {
	c := Cells{dialect = dialect, whole = csv.records(ins.data, {dialect = dialect}, runtime.heap_allocator())}
	defer csv.destroy(&c.whole)
	defer csv.destroy(&c.header)
	if _, _, msg := read_header(ins, &c); msg != "" {
		return msg
	}
	e, bad := csv.validate(ins.data, {dialect = dialect}, runner).?
	if !bad {
		return ""
	}
	for _ in csv.next_record(&c.whole) {}
	if read, failed := cells_err(&c); failed {
		e = read
	}
	return cells_fault(ins, &c, e)
}

// Closes the open file after its last record. Returns the message of the fault that ended the records, or "" when
// they were all read or a read failed. A read failure is reported here.
cells_ended :: proc(ins: ^Inputs, c: ^Cells) -> (msg: string) {
	if e, bad := cells_err(c); bad {
		msg = cells_fault(ins, c, e)
	} else if c.streamed && c.rr.read_err != nil {
		read_failed(ins, c.source.err)
	}
	end_cells_file(ins, c)
	return
}

// Returns the fault that ended the open file's records, with its offset into the window.
@(private)
cells_err :: proc(c: ^Cells) -> (e: csv.Error, bad: bool) {
	if !c.streamed {
		e, bad = c.whole.err.?
		return
	}
	if e, bad = c.rr.err.?; bad && e.kind != .Out_Of_Memory {
		_, base := csv.record_window(&c.rr)
		e.offset -= base
	}
	return
}

// Returns the bytes the open file's records are read from, the whole text or the `records_from` window, and the
// offset of its first byte in the file.
@(private = "file")
cells_text :: proc(c: ^Cells) -> (window: []byte, base: int) {
	if !c.streamed {
		return c.whole.src, 0
	}
	w, b := csv.record_window(&c.rr)
	return w, int(b)
}

// Returns where the open file's record being read starts in its window, and where its field being read starts.
@(private = "file")
cells_open_at :: proc(c: ^Cells) -> (record, field: int) {
	if c.streamed {
		return csv.open_field_at(&c.rr)
	}
	return csv.open_field_at(&c.whole)
}

@(private = "file")
cells_lines_before :: proc(c: ^Cells, window: []byte) -> int {
	return c.source.newlines - count_newlines(window) if c.streamed else 0
}

@(private)
cells_fault :: proc(ins: ^Inputs, c: ^Cells, e: csv.Error) -> string {
	e := e
	window, _ := cells_text(c)
	what := cells_fault_text(c, window, e)
	// An unterminated quoted field is reported at its opening quote.
	if _, f := cells_open_at(c); e.kind == .Truncated && c.dialect.quoting == .Quotes && f < len(window) && window[f] == '"' {
		e.offset, what = u64(f), "Unfinished quoted field"
	}
	return cells_message(ins, c, e, what)
}

// Formats `what` at `e`'s position in the open file as `FILE:LINE:COLUMN: what`. Columns on the first line
// exclude a byte order mark, as in the JSON reader.
@(private = "file")
cells_message :: proc(ins: ^Inputs, c: ^Cells, e: csv.Error, what: string) -> string {
	window, base := cells_text(c)
	skip := core_pkg.bom_len(window) if base == 0 else 0
	at := e
	at.offset -= u64(min(skip, int(e.offset)))
	return fault_in_file(ins.name, window[skip:], at, what, cells_lines_before(c, window))
}

// Returns the CSV-specific description of the fault `e`.
@(private = "file")
cells_fault_text :: proc(c: ^Cells, window: []byte, e: csv.Error) -> string {
	#partial switch e.kind {
	case .Truncated:
		return "Unfinished UTF-8 sequence"
	case .Bad_Char:
		switch b := window[e.offset]; {
		case b >= 0x80:
			return "Invalid UTF-8"
		case b == '\r':
			return "Carriage return not before a line feed"
		case b == '"':
			return "Quote inside an unquoted field"
		}
		return "Character after a closing quote"
	case .Bad_Structure:
		if csv.Fault(e.detail) == .Field_Count {
			return message.build_temp("Record has the wrong number of fields (the header has %d)", c.header.width)
		}
	}
	return core_pkg.fault_text(e.kind, e.detail, csv.fault_name)
}

// Closes the open file and frees its text and header.
@(private = "file")
end_cells_file :: proc(ins: ^Inputs, c: ^Cells) {
	if c.streamed {
		csv.destroy(&c.rr)
		close_file(c.source.file)
	} else {
		csv.destroy(&c.whole)
		free_data({ins.data, ins.mapped})
		ins.data, ins.mapped = nil, false
	}
	csv.destroy(&c.header)
	c^ = {
		dialect = c.dialect,
	}
}

// Returns the line number for `input_line_number`: the newlines before the end of the last record read. A repeated
// call counts on from the previous answer.
cells_line :: proc(ins: ^Inputs) -> int {
	c := ins.cells
	if c == nil || !c.open {
		return 0
	}
	window, base := cells_text(c)
	rec_lo, _ := cells_open_at(c)
	upto := min(rec_lo, len(window))
	if from := c.line_at - base; from >= 0 && from <= upto {
		c.line_no += count_newlines(window[from:upto])
	} else {
		c.line_no = cells_lines_before(c, window) + count_newlines(window[:upto])
	}
	c.line_at = base + upto
	return c.line_no
}
