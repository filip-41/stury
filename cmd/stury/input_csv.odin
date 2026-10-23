package main

// --from csv and --from tsv: each file's first record names the fields, and every later record is one input, an
// object of the header's names and the cells' text as strings, null for a cell with no bytes (a quoted `""` is
// the empty string). A regular file is read whole (`csv.records`); a pipe, a
// terminal, a file past STREAM_FILE_MIN and any file under -n are read through `csv.records_from`, whose window
// holds the longest record. Each file has its own header; a duplicated header name, a record of another width
// and a fault in the text end the file, reported as `FILE:LINE:COLUMN: fault`.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import core_pkg "../../core"
import csv "../../csv"
import "jq"

// The bytes a regular file adds to a window at a time.
CELLS_CHUNK :: 1 << 20

// The stream a window is read from: it counts the newlines it hands over, which a fault's place and
// `input_line_number` need once the window has moved past them.
Cells_Source :: struct {
	ins:      ^Inputs,
	file:     ^os.File,
	regular:  bool,
	newlines: int,
	err:      os.Error, // the read that failed
}

// The cells of the file being read. Everything it holds but the arena's values is the heap's: a header's names
// outlive their file, as the objects built from them may (-s, -n).
Cells :: struct {
	dialect:  csv.Dialect,
	file:     ^os.File, // nil between files
	streamed: bool, // read through `rr`, else `whole` over `data`
	data:     []byte,
	mapped:   bool, // data is the file's mapping
	whole:    csv.Records,
	rr:       csv.Record_Reader,
	source:   Cells_Source,
	it:       ^csv.Records, // `whole` or `rr`'s: the iterator whose `field_lo` says where a quoted field began
	header:   []string, // nil until the file's first record is read
	line_at:  int, // the last line count `cells_line` told: its stream offset and the count
	line_no:  int,
}

// The next input of the files read as records of cells (jq's next_input with the file's header applied), or its
// parse error: the fault told with its file, line and column.
next_cells :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	rec, msg, status := next_row(ins)
	if status != .Value {
		return nil, msg, status
	}
	return record_object(ins.cells, rec), "", .Value
}

// The next record of the files past its file's header, or `.Error` with the fault that ended the file, or
// `.More` when no file is left.
next_row :: proc(ins: ^Inputs) -> (rec: csv.Record, msg: string, status: jq.Parse_Status) {
	c := cells_of(ins)
	for {
		if c.file == nil {
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

// The cells of the files, made on first use.
cells_of :: proc(ins: ^Inputs) -> ^Cells {
	if ins.cells == nil {
		ins.cells = new(Cells, runtime.heap_allocator())
		ins.cells.dialect = csv.TSV if ins.run.opts.from == .Tsv else csv.Dialect{}
	}
	return ins.cells
}

// The next record of the open file's text.
next_cell :: proc(c: ^Cells) -> (csv.Record, bool) {
	if c.streamed {
		return csv.next_record(&c.rr)
	}
	return csv.next_record(&c.whole)
}

// Open the next file that opens and has a header, and read the header. `.More` when no file is left.
open_cells :: proc(ins: ^Inputs, c: ^Cells) -> (msg: string, status: jq.Parse_Status) {
	for ins.next_file < len(ins.files) {
		f, ok := open_file(ins)
		if !ok || !start_cells(ins, c, f) {
			continue
		}
		rec, got := next_cell(c)
		if !got {
			if msg = cells_ended(ins, c); msg != "" {
				return msg, .Error
			}
			continue
		}
		if msg = read_header(ins, c, rec); msg != "" {
			end_cells_file(c)
			return msg, .Error
		}
		return "", .Value
	}
	return "", .More
}

// Ready `c` to read file `f`. It returns false, with `f` closed, when `f` cannot be read.
@(private = "file")
start_cells :: proc(ins: ^Inputs, c: ^Cells, f: ^os.File) -> bool {
	heap := runtime.heap_allocator()
	c^ = {
		dialect = c.dialect,
		file    = f,
	}
	if !streams(ins, f, records = false) {
		if data, mapped := map_file(f); mapped {
			c.data, c.mapped = data, true
			mapped_input_name = ins.name
		} else {
			all, err := read_whole(f, heap)
			if err != nil {
				close_file(f)
				c.file = nil
				read_failed(ins, err)
				return false
			}
			c.data = all
		}
		c.whole = csv.records(c.data, c.dialect, allocator = heap)
		c.it = &c.whole
		return true
	}
	c.streamed = true
	c.source = {ins, f, is_regular_file(f), 0, nil}
	c.rr = csv.records_from({cells_read, &c.source}, c.dialect, allocator = heap)
	if c.source.regular {
		c.rr.chunk = CELLS_CHUNK
	}
	c.it = &c.rr.it
	return true
}

// What `records_from` reads the open file through. A stream that may be a while coming has the output so far
// written first.
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

// The file's names from its first record, `.Error`'s message when one is repeated.
@(private = "file")
read_header :: proc(ins: ^Inputs, c: ^Cells, rec: csv.Record) -> string {
	heap := runtime.heap_allocator()
	names := make([]string, len(rec.fields), heap)
	seen := make(map[string]struct{}, len(rec.fields), context.temp_allocator)
	for f, i in rec.fields {
		text, escaped, _ := csv.field_text(rec.src, f, c.dialect, heap)
		if !escaped {
			text = bytes.clone(text, heap)
		}
		name := string(text)
		if name in seen {
			e := csv.Error{offset = f.lo, kind = .Duplicate_Key}
			return cells_message(ins, c, e, fmt.tprintf("Duplicate header name %q", name))
		}
		seen[name] = {}
		names[i] = name
	}
	c.header = names
	return ""
}

// The object of the header's names and the record's cells, the text of each in the arena: a cell's bytes are
// copied together, and one with a doubled quote or an escape is decoded into it. A cell of no bytes is null.
@(private = "file")
record_object :: proc(c: ^Cells, rec: csv.Record) -> jq.Value {
	n, total := len(rec.fields), 0
	for f in rec.fields {
		total += int(f.hi - f.lo)
	}
	text := make([]byte, total)
	keys := make([dynamic]string, n)
	vals := make([dynamic]jq.Value, n)
	copy(keys[:], c.header)
	at := 0
	for f, i in rec.fields {
		if f.lo == f.hi {
			continue
		}
		cell, decoded, _ := csv.field_text(rec.src, f, c.dialect)
		if !decoded {
			at += copy(text[at:], cell)
			cell = text[at - len(cell):at]
		}
		vals[i] = string(cell)
	}
	return jq.object_from(keys, vals)
}

// `check` on a whole text of records of cells: the message a filter run on it gives, or "" when it reads through. The
// text is judged by `csv.validate`, which does not allocate and, with a `runner`, reads in parallel; the header is
// read for its repeated names, which validate leaves to the reader, and the text is read again only for the fault
// validate found, so that it is told as a filter run tells it.
check_cells_text :: proc(ins: ^Inputs, dialect: csv.Dialect, runner: ^csv.Batch_Runner) -> string {
	c := Cells{dialect = dialect, data = ins.data}
	c.whole = csv.records(c.data, dialect, allocator = runtime.heap_allocator())
	c.it = &c.whole
	defer csv.records_destroy(&c.whole)
	if rec, ok := csv.next_record(&c.whole); ok {
		if msg := read_header(ins, &c, rec); msg != "" {
			return msg
		}
	}
	e, bad := csv.validate(c.data, dialect, runner = runner).?
	if !bad {
		return ""
	}
	for _ in csv.next_record(&c.whole) {}
	if read, failed := cells_err(&c); failed {
		e = read
	}
	return cells_fault(ins, &c, e)
}

// The open file's records have ended: the message of the fault that ended them, "" when they were read through
// or a read failed (reported here), and the file closed either way.
cells_ended :: proc(ins: ^Inputs, c: ^Cells) -> (msg: string) {
	if e, bad := cells_err(c); bad {
		msg = cells_fault(ins, c, e)
	} else if c.streamed && c.rr.read_err != nil {
		read_failed(ins, c.source.err)
	}
	end_cells_file(c)
	return
}

// The fault that ended the open file's records, at its place in the window.
@(private = "file")
cells_err :: proc(c: ^Cells) -> (e: csv.Error, bad: bool) {
	if !c.streamed {
		e, bad = c.whole.err.?
		return
	}
	if e, bad = c.rr.err.?; bad && e.kind != .Out_Of_Memory {
		e.offset -= u64(c.rr.base)
	}
	return
}

// The window the open file's records are read in: its text whole, or what `records_from` holds.
@(private = "file")
cells_text :: proc(c: ^Cells) -> []byte {
	return c.rr.buf[:c.rr.hi] if c.streamed else c.data
}

// The lines of the open file before `window`.
@(private = "file")
cells_lines_before :: proc(c: ^Cells, window: []byte) -> int {
	return c.source.newlines - count_newlines(window) if c.streamed else 0
}

// The fault `e` of the open file's text as a message.
@(private = "file")
cells_fault :: proc(ins: ^Inputs, c: ^Cells, e: csv.Error) -> string {
	e, window := e, cells_text(c)
	what := cells_fault_text(c, window, e)
	// A quoted field that never ends is told where it begins.
	if f := c.it.field_lo; e.kind == .Truncated && c.dialect.quoting == .Quotes && f < len(window) && window[f] == '"' {
		e.offset, what = u64(f), "Unfinished quoted field"
	}
	return cells_message(ins, c, e, what)
}

// `what` told at `e`'s place in the open file: `FILE:LINE:COLUMN: what`. The place counts from past a byte order
// mark, as the JSON reader's does.
@(private = "file")
cells_message :: proc(ins: ^Inputs, c: ^Cells, e: csv.Error, what: string) -> string {
	window := cells_text(c)
	skip := core_pkg.bom_len(window) if c.rr.base == 0 else 0
	at := e
	at.offset -= u64(min(skip, int(e.offset)))
	return fault_in_file(ins.name, window[skip:], at, what, cells_lines_before(c, window))
}

// What is wrong at the fault `e`, in CSV's words.
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
	case .Bad_Escape:
		return "Invalid escape"
	case .Field_Count:
		return fmt.tprintf("Record has the wrong number of fields (the header has %d)", len(c.header))
	}
	return jq.FAULT_TEXT[e.kind]
}

// The file read through, or given up on at a fault: closed, and its text and header dropped.
@(private = "file")
end_cells_file :: proc(c: ^Cells) {
	if c.streamed {
		csv.records_destroy(&c.rr)
	} else {
		csv.records_destroy(&c.whole)
		free_data({c.data, c.mapped})
	}
	close_file(c.file)
	c.file, c.header, c.data, c.streamed = nil, nil, nil, false
}

// The line `input_line_number` tells: the newlines up to the end of the record read last. Asked again, it counts
// on from the last answer.
cells_line :: proc(ins: ^Inputs) -> int {
	c := ins.cells
	if c == nil || c.file == nil {
		return 0
	}
	window := cells_text(c)
	base, upto := int(c.rr.base), min(c.it.rec_lo, len(window))
	if from := c.line_at - base; from >= 0 && from <= upto {
		c.line_no += count_newlines(window[from:upto])
	} else {
		c.line_no = cells_lines_before(c, window) + count_newlines(window[:upto])
	}
	c.line_at = base + upto
	return c.line_no
}
