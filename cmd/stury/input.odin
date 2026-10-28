package main

// Reads the command's input as jq does.
//
// Input as jq 1.8.2 reads it (util.c): the files one after another as a single stream, a file that does not
// open reported and counted, and a text that does not parse told in jq's form. The texts are the library's
// to validate (jq/read.odin): a text ends within its file, and a literal at the first space, quote or bracket.
//
// The library reads a regular file whole, a text at a time. A file that is not a regular one (a pipe, a terminal),
// stdin under --unbuffered, any file under -n, and a regular file past STREAM_FILE_MIN whose first line looks like
// one record (`streams`), it reads a window of whole lines at a time (`next_window`), so a text is answered once its
// line has come, and memory holds a window and the longest text. --seq reads a record from each run of separators to
// the next, --stream makes each text's events (`jq.Events`).

import "base:runtime"
import "core:bytes"
import "core:slice"
import "core:strings"
import json "../../json"
import "jq"

// The longest piece jq's fgets reads: its 4096-byte buffer, less room to finish a UTF-8 sequence.
FGETS_MAX :: 4091

// How much of a stream its reader takes in at once.
READ_BLOCK :: 1 << 16

RS :: 0x1e // --seq's record separator

@(rodata)
UTF8_BOM := [3]byte{0xef, 0xbb, 0xbf}

@(rodata)
STDIN_ONLY := []string{"-"}

// The file mapped last, which the SIGBUS handler names when it shrinks under its mapping (platform_posix.odin). It is ""
// until a file is mapped.
mapped_input_name: string

Inputs :: struct {
	run:                ^Run,
	files:              []string, // "-" is stdin
	next_file:          int,
	name:               string, // the file opened last, "" before the first
	open:               bool,
	failures:           int, // files that did not open or read
	slurped:            ^jq.Array, // -s: the values so far
	// The library's: the open file, read whole.
	data:               []byte,
	mapped:             bool, // data is the file's mapping (`map_file`), not the heap's
	spent:              [dynamic]Spent, // files read past, which a value may still be read from
	pinned:             bool, // a value read from data may lie in it
	skip:               int, // the byte order mark at its start
	pos:                int, // where its next text starts
	seen:               int, // the byte jq would have read last for the last value
	lines:              struct {
		start, end, count: int,
	}, // fgets_lines' place in data
	bom_done:           bool, // past the stream's start, the one place a byte order mark is dropped
	raw_slurped:        bool, // -R -s: the stream's one string has been read
	at_line, at_column: int, // where data starts, as jq's parser counts lines and columns
	fault_at:           struct {
		at, line, column: int,
	}, // the last fault's place in data, so the next is counted from there (line 0: none yet)
	// A stream, read a window at a time: data is the window's whole lines. Its reader holds the rest.
	may_stream:         bool, // the run reads a stream so; check reads every file whole
	reader:             ^Stream_Reader, // the open file's while more of it may follow the window, else nil
	lines_before:       int, // the lines of the open file before data
	window_lines:       int, // the newlines in data, which its stream's reader counted
	texts_follow:       bool, // a text of the open file had another after it
	lines_tried:        bool, // the open file's lines, or its window's, were read as records (`records_after`)
	line_records:       bool, // some of the open file's lines were read as records
	resume:             bool, // a batch of records left one after reading far: the lines after it are tried again
	line:               int, // -R: jq's current_line, the lines it has read of the open file
	events:             ^jq.Events, // --stream: the events of the text read last, while some are left
	fault_note:         string, // text_fault's caret and flag hint for the message it returned ("" for none)
	fault_walk:         ^Fault_Walk, // --stream: jq's parser over the faulty text at data[fault_text:], while it has events left
	fault_spare:        ^Fault_Walk, // the walk that ended last, made anew for the next faulty text
	fault_text:         int,
	fault_end:          int, // where the stream reads on: --stream-errors' record end, or plain --stream's fault
	fault_error:        string, // plain --stream: the message the text ends with, given after its events before the fault
	bom_broken:         bool, // --seq --stream-errors: a cut byte order mark began the stream, so jq's parser restarts at every call
	cells:              ^Cells, // --from csv or tsv: the open file's text and header
	seq_joined:         bool, // --seq: data is a record and the texts after it, read on from the files after its own (`seq_join`)
	// The library's reader of the open file's texts, over data: where a text ends, and the bytes a stream's next
	// window carries over (`next_window`).
	texts:              json.Record_Reader,
	seq_head:           enum u8 {
		Unread, // --seq: the open file's first text is yet to be found
		Bare, // found with no separator before it, and yet to be refused
		Read,
	},
}

inputs_init :: proc(ins: ^Inputs, run: ^Run, files: []string) {
	o := run.opts
	ins^ = {
		run     = run,
		files   = files,
		spent   = make([dynamic]Spent, runtime.heap_allocator()),
		at_line = 1,
	}
	// jq's raw reader keeps a byte order mark, and each CSV file's header reads its own (`cells_message`).
	ins.bom_done = o.raw_input || reads_cells(&o)
	if o.raw_input {
		return
	}
	if o.slurp {
		ins.slurped = jq.new_array()
	}
}

// What `input`, `inputs`, `input_filename` and `input_line_number` read.
bind_inputs :: proc(run: ^Run, ins: ^Inputs) {
	run.ip.inputs = {
		data = ins,
		next = proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
			return next_input((^Inputs)(data), own = true)
		},
		position = proc(data: rawptr) -> (string, int) {
			return input_position((^Inputs)(data))
		},
	}
}

// jq's next_input: the next value, or under -s every value as one array once the stream ends, or a parse error as
// soon as there is one. With `prog`, the value is the input `prog` runs on, and holds only what it reads of a large
// text (see `build_root_pieces`). An `own` value, which `input` reads, holds a copy of its text, unless the text is
// most of what was read with it, so that under -n what was read can be freed once read past while the value lives on
// (`retire`).
next_input :: proc(ins: ^Inputs, prog: ^jq.Node = nil, own := false) -> (jq.Value, string, jq.Parse_Status) {
	if ins.slurped == nil {
		return next_value(ins, prog, own)
	}
	for {
		if ins.fault_walk != nil && ins.fault_error == "" {
			if ev, ok := fault_peek(ins.fault_walk); ok && ev.late {
				break
			}
		}
		v, msg, status := next_value(ins, own = own)
		if status == .Error {
			return nil, msg, .Error
		}
		if status == .Value {
			append(&ins.slurped.items, v)
		}
		if status == .More {
			break
		}
	}
	all := ins.slurped
	ins.slurped = nil
	return all, "", .Value
}

// The next value of the stream, or under --stream its next event. A text that does not parse is jq's message
// (`text_fault`).
next_value :: proc(ins: ^Inputs, prog: ^jq.Node = nil, own := false) -> (jq.Value, string, jq.Parse_Status) {
	run := ins.run
	if run.opts.raw_input {
		return next_raw(ins)
	}
	if reads_cells(&run.opts) {
		return next_cells(ins)
	}
	if ins.events != nil {
		if v, ok := jq.next_event(ins.events); ok {
			return v, "", .Value
		}
		ins.events = nil
	}
	if ins.fault_walk != nil {
		ev, ok := fault_event(ins.fault_walk)
		if ok && (ins.fault_error == "" || !ev.error && ins.fault_text + ev.at < ins.fault_end) {
			ins.seen = ins.fault_text + ev.at
			return ev.value, "", .Value
		}
		if msg := end_fault_walk(ins); msg != "" {
			return nil, msg, .Error
		}
	}
	for {
		at, limit, trailing, found := next_text(ins)
		if !found {
			if run.opts.seq && run.opts.stream_errors && ins.seq_head == .Unread {
				ins.seq_head = .Read
				return abandoned_text(ins, len(ins.data))
			}
			return nil, "", .More
		}
		if at == 0 && run.opts.seq && run.opts.stream_errors && cut_bom_len(ins.data) > 0 {
			return stream_errors_fault(ins, at, limit, text_place(ins, at))
		}
		// A record follows a separator: a file's first text without one is refused, as check and the library
		// refuse it, and told, where jq drops it unsaid.
		if ins.seq_head == .Bare {
			ins.seq_head = .Read
			if run.opts.stream_errors { // jq passes over what comes before the first separator, unread
				if limit < len(ins.data) {
					ins.pos = limit
					continue
				}
				return abandoned_text(ins, at)
			}
			return text_fault(ins, at, limit, json.Error{kind = .Bad_Char}, "Text before the first RS")
		}
		if ins.bom_broken {
			return stream_errors_fault(ins, at, limit, text_place(ins, at))
		}
		// The records --seq refuses whatever they hold: one led by a byte order mark, a number alone. Neither reads
		// the dialect or the limits.
		if run.opts.seq {
			rec := json.Record{bytes = ins.data[at:limit], at = u64(at)}
			if _, refused := json.judge_record(ins.data, rec, nil, {framing = .JSON_Seq}); refused != nil {
				return text_fault(ins, at, limit, refused.?)
			}
		}
		if trailing && json.grammar_of(run.read.dialect) == {} && limit == len(ins.data) && !own && !run.opts.stream && !run.verbatim {
			if v, ok := build_root_pieces(run, ins.data, at, prog); ok {
				ins.pos, ins.seen, ins.pinned = limit, last_read(ins.data, at, limit), true
				return v, "", .Value
			}
		}
		// --stream's document lives until its last event, past the arena of the call that reads it.
		doc_allocator := runtime.heap_allocator() if run.opts.stream else context.allocator
		// Once a file has shown a second text, its texts are guessed to end their lines: a line that builds
		// whole is one text, which jq reads the same with the newline after it.
		end := limit
		if trailing && ins.texts_follow {
			if k := bytes.index_byte(ins.data[at:limit], '\n'); k >= 0 {
				end = at + k + 1
			}
		}
		d, err := jq.build_rows(ins.data[at:end], run.read.dialect, allocator = doc_allocator)
		if e, bad := err.?; bad && trailing && (e.kind == .Trailing || end < limit) {
			if e.kind == .Trailing {
				ins.texts_follow = true
				end = at + int(e.offset)
			} else {
				// Found by the framing, as a build sizes its rows by its source: building the rest of the file to find
				// the end would cost every text the rest of the file. A fault lies within the text it frames.
				texts := json.records(ins.data[at:limit], {framing = .Concatenated})
				text, _ := json.next_record(&texts)
				end = at + len(text.bytes)
			}
			d, err = jq.build_rows(ins.data[at:end], run.read.dialect, allocator = doc_allocator)
		}
		read := err
		// The fault as the framing tells it. A --seq record may hold a complete value and then bytes that belong to no
		// record, as `[1]` followed by `]` before the next separator: the value is read, and the bytes after it are
		// the fault the next read reports and resyncs past.
		if e, bad := err.?; bad {
			split: int
			split, err = judge_text(ins, at, limit, e)
			if split > 0 {
				if d2, err2 := jq.build_rows(ins.data[at:][:split], run.read.dialect, allocator = doc_allocator); err2 == nil {
					end = at + split
					d, err = d2, nil
				}
			}
		}
		if err == nil {
			if bad_at, bad := jq.non_finite_at(&d); bad {
				ins.run.name, ins.run.whole = ins.name, ins.data
				fail_input(ins.run, {kind = .Bad_Char, detail = u8(json.Fault.Literal), offset = u64(at) + bad_at}, "Infinity and NaN have no JSON value")
			}
			ins.pos, ins.seen = end, last_read(ins.data, at, end)
			if run.opts.stream {
				ins.pinned = true
				ins.events = jq.events_start(d, at)
				v, _ := jq.next_event(ins.events)
				return v, "", .Value
			}
			if own && 2 * len(d.src) < len(ins.data) {
				d.src = slice.clone(d.src)
			} else {
				ins.pinned = true
			}
			return jq.document_value(d), "", .Value
		}
		if text_cut(ins, at, read.?) {
			continue
		}
		if json.grammar_of(run.read.dialect) != {} {
			jsonc_fault(ins, err.?, at)
		}
		return text_fault(ins, at, limit, err.?)
	}
}

// -R: the next line of the stream as a string, as jq's raw reader reads it (util.c): the bytes before a newline, a
// line running on from one file into the next, and each piece fgets reads made valid UTF-8 on its own. The last line
// without its newline. Under -s, the whole stream as one string, once.
@(private = "file")
next_raw :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	slurp := ins.run.opts.slurp
	if ins.raw_slurped {
		return nil, "", .More
	}
	line := strings.builder_make()
	read := false
	for {
		if !ins.open || ins.pos == len(ins.data) {
			ins.open = false
			if !open_next(ins) {
				break
			}
			continue
		}
		n, newline := next_piece(ins.data[ins.pos:])
		piece := string(ins.data[ins.pos:][:n])
		ins.pos += n
		ins.line += int(newline)
		read = true
		if newline && !slurp {
			jq.write_valid_utf8(&line, piece[:n - 1])
			return strings.to_string(line), "", .Value
		}
		jq.write_valid_utf8(&line, piece)
	}
	ins.raw_slurped = slurp
	if !read && !slurp {
		return nil, "", .More
	}
	return strings.to_string(line), "", .Value
}

// Whether the stream surely holds no more values: the library reads it as JSON, the last file is open, and only
// space is left of it. It returns false whenever another value may follow.
stream_ended :: proc(ins: ^Inputs) -> bool {
	o := &ins.run.opts
	if ins.events != nil || ins.fault_walk != nil || o.raw_input || reads_cells(o) || ins.next_file < len(ins.files) || !ins.open || ins.reader != nil {
		return false
	}
	for c in ins.data[ins.pos:] {
		if !jq.is_space(c) {
			return false
		}
	}
	return true
}

// The first byte of `data` from `at` that is not whitespace, a --seq separator when `seq`, or, when `comments`, part of a
// complete comment. An unclosed block comment stays, for the library to refuse.
skip_blank :: proc(data: []byte, at: int, seq, comments: bool) -> int {
	at := at
	for at < len(data) {
		switch {
		case jq.is_space(data[at]) || seq && data[at] == RS:
			at += 1
		case comments && data[at] == '/' && at + 1 < len(data) && data[at + 1] == '/':
			at += 2
			for at < len(data) && data[at] != '\n' && data[at] != '\r' {
				at += 1
			}
		case comments && data[at] == '/' && at + 1 < len(data) && data[at + 1] == '*':
			end := bytes.index(data[at + 2:], {'*', '/'})
			if end < 0 {
				return at
			}
			at += end + 4
		case:
			return at
		}
	}
	return at
}

// The input jq is reading, and its line: what `input_filename`, `input_line_number` and an error's
// `(at NAME:N)` tell.
input_position :: proc(ins: ^Inputs) -> (string, int) {
	run := ins.run
	if run.opts.raw_input {
		return ins.name, ins.line
	}
	if reads_cells(&run.opts) {
		return ins.name, cells_line(ins)
	}
	seen := jq.event_trigger(ins.events) if ins.events != nil else ins.seen
	_, count := fgets_lines(ins, seen)
	return ins.name, count
}

// The next text of the stream: where it starts in data, how far it may reach, and whether another text may follow it
// within that. It returns false at the end of the stream. A text reaches to the end of its file, a literal to the
// first space, quote or bracket, under --seq a record to the next separator, under --from ndjson a line, and under --from jsonc
// the whole input, one document.
next_text :: proc(ins: ^Inputs) -> (at, limit: int, trailing, found: bool) {
	seq, ndjson := ins.run.opts.seq, reads_lines(&ins.run.opts)
	for {
		if !ins.open {
			// A separator seen in an earlier file leaves every later file's text a record, not text before the
			// stream's first separator: --seq reads the files as one stream.
			head := ins.seq_head
			if !open_next(ins) {
				return 0, 0, false, false
			}
			ins.seq_joined = false
			if seq && head == .Read {
				ins.seq_head = .Read
			}
		}
		data := ins.data
		at = ins.pos
		for at < len(data) && (jq.is_space(data[at]) || seq && data[at] == RS) {
			at += 1
		}
		// A comment ahead of a value belongs to it; comments alone are no text.
		if json.grammar_of(ins.run.read.dialect) != {} && skip_blank(data, at, seq, true) == len(data) {
			at = len(data)
		}
		if at == len(data) {
			if seq && ins.seq_head == .Unread && bytes.index_byte(data[ins.pos:], RS) >= 0 {
				ins.seq_head = .Read // a separator among whitespace: the stream is not abandoned, whatever a later window holds
			}
			ins.open, ins.seen = false, len(data)
			continue
		}
		limit = len(data)
		switch {
		case json.grammar_of(ins.run.read.dialect) != {}:
			return at, limit, false, true
		case seq:
			if ins.seq_head == .Unread {
				ins.seq_head = .Bare if bytes.index_byte(data[ins.pos:at], RS) < 0 else .Read
			}
			if k := bytes.index_byte(data[at:], RS); k >= 0 {
				limit = at + k
			} else if ins.reader != nil {
				read_past(ins, at)
				continue
			} else if ins.seq_head == .Read && !seq_text_ends(ins, at) && seq_join(ins, at) {
				continue
			}
			return at, limit, false, true
		case ndjson:
			// A byte order mark past the stream's start is a text of its own, which the library refuses.
			if data[at] == UTF8_BOM[0] {
				return at, at + 1, false, true
			}
			if k := bytes.index_byte(data[at:], '\n'); k >= 0 {
				limit = at + k
			}
			return at, limit, false, true
		}
		// A byte order mark past the stream's start is a text of its own, which the library refuses.
		if data[at] == UTF8_BOM[0] {
			return at, at + 1, false, true
		}
		// An array, object or string runs on to be ended by its read (`text_read`), and anything else ends where
		// the texts' reader ends it: at the first space, quote or bracket, with a `]`, `}`, `,` or `:` right after
		// it, which the library refuses with it, as jq does. A scalar ends within the window, which ends at a line
		// feed.
		switch data[at] {
		case '[', '{', '"':
			return at, limit, true, true
		}
		json.record_skip(&ins.texts, text_offset(ins, at))
		text, _ := json.next_record_open(&ins.texts)
		return at, at + len(text.bytes), false, true
	}
}

// Whether the --seq text at data[at:] ends with its file: it reads whole and its last byte closes it or is whitespace.
// A number or literal there may go on in the next file.
@(private = "file")
seq_text_ends :: proc(ins: ^Inputs, at: int) -> bool {
	src := ins.data[at:]
	if len(src) == 0 {
		return false
	}
	switch src[len(src) - 1] {
	case ']', '}', '"', ' ', '\t', '\n', '\r':
	case:
		return false
	}
	_, bad := json.validate(src, {dialect = ins.run.read.dialect, limits = ins.run.read.limits}).?
	return !bad
}

// A --seq record that no separator ends in the open file goes on in the next file, as in jq's one byte stream: those
// files are read now into one buffer from the record's first byte, which `data` becomes. False when no file followed.
@(private = "file")
seq_join :: proc(ins: ^Inputs, at: int) -> bool {
	start_line, start_column := text_place(ins, at)
	joined := make([dynamic]byte, 0, len(ins.data) - at + READ_BLOCK, runtime.heap_allocator())
	append(&joined, ..ins.data[at:])
	read_any := false
	last_start := 0 // where the file read last begins in `joined`: `input_line_number` counts from there, as jq does
	for ins.next_file < len(ins.files) && bytes.index_byte(joined[:], RS) < 0 {
		if !open_next(ins) {
			break
		}
		read_any, last_start = true, len(joined)
		if ins.reader == nil {
			append(&joined, ..ins.data)
			continue
		}
		for {
			append(&joined, ..ins.data)
			if bytes.index_byte(joined[:], RS) >= 0 || ins.reader == nil {
				break
			}
			next_window(ins, len(ins.data), len(ins.data))
		}
	}
	if !read_any {
		return false
	}
	if ins.data != nil {
		if ins.run.opts.null_input && !ins.pinned {
			free_data({ins.data, ins.mapped})
		} else {
			append(&ins.spent, Spent{ins.data, ins.mapped})
		}
		ins.pinned = false
	}
	ins.data, ins.mapped = joined[:], false
	ins.texts = json.records_pushed({framing = .Concatenated})
	json.record_push(&ins.texts, ins.data, ins.reader == nil)
	ins.open, ins.seq_joined = true, true
	ins.skip, ins.pos, ins.seen, ins.window_lines, ins.texts_follow = 0, 0, 0, 0, false
	ins.at_line, ins.at_column, ins.fault_at = start_line, start_column, {}
	ins.lines_before, ins.lines = 0, {start = last_start, end = last_start}
	ins.seq_head = .Read
	return true
}
