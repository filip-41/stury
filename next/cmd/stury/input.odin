package main

// Reading the files and stdin a run names, as jq reads them: the files one after another, each a run of texts (jq's
// default, `.Concatenated`), of lines (--from ndjson, `.Lines`) or of records after 0x1E (--seq, `.Seq`), or under -R of
// lines read as strings. A text ends within its file, and a JSONC or JSON5 file is one text. A file that does not open is told and counted, and a text that
// does not parse is told in jq's form.
//
// A regular file is read whole. Any other (a pipe, a terminal) is read as a stream (`Pipe`) a window of whole lines at
// a time, so a text is answered once its line has come.

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "core:time"
import "core:sys/posix"
import core "../../core"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

@(rodata)
STDIN_ONLY := []string{"-"}

// The longest piece jq's fgets reads under -R: its 4096-byte buffer, less room to finish a UTF-8 sequence.
FGETS_MAX :: 4091

// The most a pipe's window takes of what comes at once.
READ_AHEAD :: 8 << 20

// A text cut short at least this long waits for as many bytes again before it is read again.
READ_BLOCK :: 1 << 16

// A pipe's window is taken once no byte comes for this long, so a writer that streams fills windows long enough to
// read in pieces, and a line typed at a terminal is answered at once.
PIPE_WAIT :: time.Millisecond

// How long --follow waits at a file's end before it reads again: short enough that an appended record is answered
// before anyone looks, long enough that an idle run is a few dozen stat calls a second.
FOLLOW_POLL :: 50 * time.Millisecond

// Set by SIGINT and SIGTERM (`catch_stop`) for a --follow run, which then ends as if its file ended.
stopped: bool

// The file whose mapping is read, which a SIGBUS on POSIX names.
mapped_input_name: string

// How the inputs are read: `as`, the format's handle, which `core.build` and `core.validate` read a text through
// whatever the format is, and how a file's texts follow each other.
Source :: struct {
	as:      core.As,
	framing: core.Framing,
	spec:    Maybe(json.Spec), // the JSON-like format's, none for a delimited one
}

Inputs :: struct {
	using source: Source,
	files:     []string, // "-" is stdin
	next_file: int,
	name:      string, // the file opened last, "" before the first
	failures:  int, // files that did not open or read
	has_text:  bool, // a file before this one held a text, so a byte order mark opening this one is no mark
	slurp:     bool,
	run:       ^Run, // under the path scan, a text it answers is printed and passed over
	// The open file. `data` is its bytes in memory, whole (`last`) or a window of whole lines, and the inputs own them:
	// once read past they are freed, or, while a value the main loop read lies in them (`pinned`), kept in `spent`
	// until that value's outputs are printed (`release_spent`). `texts` reads its texts, past the first when the file
	// is whole: most files hold one, which one build reads.
	open:      bool,
	data:      []byte,
	mapped:    bool, // data is the file's mapping (`map_file`), not the heap's
	last:      bool,
	pipe:      ^Pipe,
	texts:     records.Reader,
	several:   bool,
	parallel_from: u64, // where pieces may start again, past a record they stopped at
	skip_below: u64, // a delimited text's records before it are answered by pieces
	rows_end:   u64, // a delimited window's records read end here, past their line ends
	pinned:    bool,
	header_judged: bool, // --from csv or tsv: the open file's first record is read
	// --follow with a delimited format: the header's bytes through its line end, which every window after the first
	// opens with so that it reads as the header of a file of its own, and whether the open window does.
	head:      []byte,
	headed:    bool,
	fresh:     bool, // --follow: the file was truncated, so what follows the last window taken is a new file
	spent:     [dynamic]Spent,
	raw_at:    int, // -R: where the next line starts in data
	raw_done:  bool, // -R -s: the one string is read
	// Where jq's parser stands at data[0], counted over every byte read before it, and the lines of the open file
	// before data[0], which `input_line_number` counts on from.
	parsed:    struct {
		line, column: int,
	},
	file_lines: int,
	pieces:     struct {
		at, lines: int,
	}, // `lines_read`'s place: past the line end it counted through, and the line ends before it
	line:       int, // the lines of the open file jq's parser has read
	text_end:   int, // the end in data of the text read last, while `line` does not count its lines yet, else 0
	line_end:   int, // --stream: the byte after the newline `line` counts last
	// --stream: the open text's events while some are left: a document's, whose text starts at `events_at`, or those
	// jq's parser makes of the bytes before a fault, which plain --stream ends with the fault's message
	events:      ^jq.Events,
	events_at:   int,
	walk:        ^Fault_Walk,
	walk_at:     int,
	walk_spare:  ^Fault_Walk, // a walk that has ended, whose memory the next one takes
	fault_error: string,
	bom_broken:  bool, // --stream-errors --seq: a cut byte order mark began the stream, so jq's parser restarts at every call
	note:        string, // what the parse error that ends the run adds on the lines after it
}

// jq's next_input: the next value, or under -s every value as one array once the files are read, or a parse error as
// soon as there is one. A --stream-errors error that jq gives after the event the text's last byte left pending comes
// after the array. An `own` value, which `input` reads, holds a copy of its text, so the bytes it was read from can go
// while it lives on.
next_input :: proc(ins: ^Inputs, own := false) -> (jq.Value, string, jq.Parse_Status) {
	if !ins.slurp {
		return next_value(ins, own)
	}
	if ins.run.opts.raw_input {
		ins.slurp = false
		return next_raw(ins, true)
	}
	all := jq.new_array()
	read: for {
		if ins.walk != nil && ins.fault_error == "" {
			if ev, more := fault_peek(ins.walk); more && ev.late {
				break
			}
		}
		v, msg, status := next_value(ins, own)
		switch status {
		case .Error:
			if !ins.run.opts.seq {
				return nil, msg, .Error
			}
			tell_ignored(ins, msg)
		case .Value:
			append(&all.items, v)
		case .More:
			break read
		}
	}
	ins.slurp = false
	return all, "", .Value
}

// Tells the parse error `msg` of a --seq record, which is passed over, as jq's parser goes on at the next separator.
tell_ignored :: proc(ins: ^Inputs, msg: string) {
	flush_some(&ins.run.output, force = true)
	message.write_stderr("stury: ignoring parse error: %s\n%s", msg, ins.note)
}

// The next text, or under --stream its next event, passing over a file that does not open or holds only space.
@(private = "file")
next_value :: proc(ins: ^Inputs, own: bool) -> (jq.Value, string, jq.Parse_Status) {
	if ins.run.opts.raw_input {
		return next_raw(ins, false)
	}
	if ins.events != nil {
		if v, more := jq.next_event(ins.events); more {
			lines_through(ins, ins.events_at + jq.event_trigger(ins.events))
			return v, "", .Value
		}
		ins.events = nil
	}
	if ins.walk != nil {
		ev, more := fault_event(ins.walk)
		if more && (ins.fault_error == "" || !ev.error && ev.at < len(ins.walk.p.src)) {
			lines_through(ins, ins.walk_at + ev.at)
			return ev.value, "", .Value
		}
		msg := ins.fault_error
		ins.walk, ins.walk_spare, ins.fault_error = nil, ins.walk, ""
		if msg != "" {
			return nil, msg, .Error
		}
	}
	for {
		if !ins.open && !open_next(ins) {
			return nil, "", .More
		}
		if k := cut_bom_len(ins.data); k > 0 && ins.run.opts.stream_errors && ins.framing != .Lines && ins.next_file == 1 && !ins.has_text && ins.file_lines == 0 && !ins.bom_broken {
			// jq's parser drops the bytes of the mark it matched, and refuses the stream whole when more follow, but
			// under --seq it starts afresh at every call, and tells a stream of the mark alone that it was abandoned.
			switch {
			case ins.framing == .Seq && k < len(ins.data):
				// The mark's bytes are not counted in jq's columns.
				ins.bom_broken, ins.parsed.column = true, -k
				records.close(&ins.texts)
				ins.texts = records.open(ins.data, ins.as, .Seq, u64(k), runtime.heap_allocator())
				continue
			case ins.framing == .Seq:
				close_file(ins)
				return abandoned(ins, nil)
			case k < len(ins.data):
				return nil, "Malformed BOM", .Error
			}
			close_file(ins)
			continue
		}
		if !ins.several {
			ins.several = true
			v, msg, status, read := first_text(ins)
			if read {
				return v, msg, status
			}
			continue
		}
		if !own && records_pieces(ins) {
			continue
		}
		// A window that opens with the header is carried on from past it. A delimited text's reader frames rows ahead of
		// the one it gave last, so its window is carried on from past that row.
		from := max(ins.rows_end if reads_cells(&ins.run.opts) else ins.texts.pos, u64(len(ins.head)) if ins.headed else 0)
		route := &ins.run.route
		// The path's read frames the record it answers.
		scanned := route.scanning && scans(route.path) && !reads_cells(&ins.run.opts)
		rec: records.Record
		ok: bool
		part: core.Document
		read: core.Path_Error
		if scanned {
			rec, part, read, ok = records.scan(&ins.texts, route.path)
		} else {
			rec, ok = records.next(&ins.texts)
		}
		// A text the window cuts short, or one --seq's separator may yet end, waits for the next window, and --seq reads
		// the files as one stream, so such a record in a file's last window runs on into the next file.
		unended := ok && ins.framing == .Seq && bytes.index_byte(ins.data[rec.at:], 0x1e) < 0
		if unended || !ok && !ins.last && cut_short(ins) {
			// The reader has passed the record's separator, which the next window must start with.
			if ok {
				rs := bytes.last_index_byte(ins.data[:rec.at], 0x1e)
				from = u64(rs) if rs >= 0 else ins.texts.from
			}
			if !ins.last {
				next_window(ins, int(from))
				continue
			}
			if seq_join(ins, int(from)) {
				continue
			}
		}
		if !ok {
			if f, bad := ins.texts.fault.?; bad {
				if route.scanning {
					explain_fallback(route, .Bad_Text)
				}
				return text_fault(ins, f, int(from))
			}
			if !ins.last {
				next_window(ins, len(ins.data))
				continue
			}
			close_file(ins)
			continue
		}
		if rec.at < ins.skip_below {
			continue
		}
		if ins.bom_broken {
			// jq's parser, started afresh at every call, reads each record as a faulty one.
			return text_fault(ins, {at = rec.at, kind = .Bad_Char}, int(rec.at))
		}
		ins.has_text = true
		if reads_cells(&ins.run.opts) {
			v, msg, status, answered := cells_value(ins, rec)
			if !answered {
				return v, msg, status
			}
			if ins.failures > 0 || ins.run.halted {
				return nil, "", .More
			}
			continue
		}
		if route.scanning && (answer(ins.run, &part, part.answers, read, rec.text, ins.as) if scanned else answer_path(ins.run, rec.text, ins.as)) {
			// As jq's main loop, which reads one input past a file that did not open.
			if ins.failures > 0 {
				return nil, "", .More
			}
			continue
		}
		// --stream's document lives until its last event, past the memory of the input that reads it.
		stream := ins.run.opts.stream
		if own && !stream {
			rec.text = bytes.clone(rec.text)
		}
		// An own scalar's document is let go once its value is taken, so `[inputs]` of numbers holds only the numbers.
		own_scalar := own && !stream && len(rec.text) > 0 && rec.text[0] != '[' && rec.text[0] != '{'
		built, err := records.build(&ins.texts, rec, runtime.heap_allocator() if stream || own_scalar else context.allocator)
		doc, fault := jq.judge_build(built, err, rec.at)
		if f, bad := fault.?; bad {
			return text_fault(ins, f, int(rec.at), int(rec.at) + len(rec.text) if ins.framing == .Lines else -1)
		}
		if own_scalar {
			ins.text_end = int(rec.at) + int(doc.nodes[0].lo) + len(core.span(&doc, core.ROOT))
			heap := runtime.heap_allocator()
			d := new_clone(doc, heap)
			v := jq.scalar(jq.Ref{d, core.ROOT})
			core.destroy(d)
			free(d, heap)
			return v, "", .Value
		}
		return text_value(ins, doc, int(rec.at), own)
	}
}

// The open file's first text, when the file is whole: as one build reads it when it is the file's only text, which
// most files are. Returns false when there is none, or when another text follows it, which `texts` then reads.
@(private = "file")
first_text :: proc(ins: ^Inputs) -> (v: jq.Value, msg: string, status: jq.Parse_Status, read: bool) {
	data := ins.data
	if ins.framing != .Concatenated || !ins.last {
		return
	}
	if json.blank(data, ins.spec.?) {
		close_file(ins)
		return
	}
	stray_bom := ins.has_text && bytes.has_prefix(data, BOM)
	ins.has_text = true
	run := ins.run
	route := &run.route
	dot := route.scanning && len(route.path.steps) == 0 && route.path.limit == nil && route.select.op == .None
	// A file of several texts is no text the scan left, its texts are each scanned in turn.
	fallback := route.fallback
	if !stray_bom && (dot && spine_print(ins, put_dot) || spine_length(ins) || entries_pieces(ins) || collect_pieces(ins) || route.scanning && answer_path(run, data, ins.as)) {
		close_file(ins)
		return nil, "", .More, ins.failures > 0
	}
	doc: core.Document
	fault: Maybe(core.Fault)
	if stray_bom {
		fault = core.Fault{kind = .Bad_Char}
	} else {
		doc, fault = jq.build_text(data, ins.as, runtime.heap_allocator() if run.opts.stream else context.allocator)
	}
	if f, bad := fault.?; bad {
		if !stray_bom && f.rules == &json.RULES && f.detail == u8(json.Detail.Trailing) && ins.spec == .Json {
			route.fallback = fallback
			return
		}
		v, msg, status = text_fault(ins, f, 0)
		return v, msg, status, true
	}
	v, msg, status = text_value(ins, doc, 0, false)
	// The file's one text: it is read past whole.
	close_file(ins)
	return v, msg, status, true
}

// Whether the records of a window that is not the file's last ended on a text cut short at the window's end. A
// delimited record's open quote is a fault at the quote, where the record starts.
@(private = "file")
cut_short :: proc(ins: ^Inputs) -> bool {
	f, bad := ins.texts.fault.?
	return !bad || f.kind == .Truncated && (int(f.at) >= len(ins.data) || reads_cells(&ins.run.opts))
}

// The value of the document `doc` of a text at data[at:], or its first --stream event.
@(private = "file")
text_value :: proc(ins: ^Inputs, built: core.Document, at: int, own: bool) -> (jq.Value, string, jq.Parse_Status) {
	doc := built
	if ins.run.opts.stream {
		ins.pinned = true
		ins.events, ins.events_at = jq.events_start(doc), at
		return next_value(ins, own)
	}
	ins.pinned ||= !own
	ins.text_end = at + int(doc.nodes[0].lo) + len(core.span(&doc, core.ROOT))
	return jq.document_value(doc), "", .Value
}

// jq's message for the fault `f` of `data`, a record of which ends at `end`, but a later file's fault is told in that
// file, as `fault_told` tells it, since jq's line and column count from the first file's start.
@(private = "file")
fault_message :: proc(ins: ^Inputs, data: []byte, f: core.Fault, end := -1) -> string {
	if ins.next_file > 1 {
		return fault_told(ins.name, data, f, ins.spec, ins.file_lines)
	}
	return jq.parse_message(data, f, ins.parsed.line, ins.parsed.column, "", end)
}

// The fault `found` of the text at or after data[at:] as jq tells it, or under --stream the events jq's parser makes of
// the text before it. An NDJSON record ends at `end`.
@(private = "file")
text_fault :: proc(ins: ^Inputs, found: core.Fault, at: int, end := -1) -> (jq.Value, string, jq.Parse_Status) {
	data := ins.data
	if reads_cells(&ins.run.opts) {
		return cells_fault(ins, found)
	}
	if ins.spec != .Json {
		fail_dialect(ins, data, found)
	}
	f := literal_cut(data, found, ins.framing)
	ins.note = fault_note(data, f, ins.spec, &ins.run.opts)
	if !ins.run.opts.stream {
		ins.line, ins.text_end = lines_read(ins, int(f.at) + 1), 0
		msg := fault_message(ins, data, f, end)
		// Under --seq the reader goes on at the next record, and jq's parser elsewhere from the line after the fault,
		// which `input` reads next.
		if ins.framing == .Seq {
			return nil, msg, .Error
		}
		stop := min(int(f.at), len(data))
		nl := bytes.index_byte(data[stop:], '\n')
		records.close(&ins.texts)
		ins.texts = records.open(data, ins.as, ins.framing, u64(len(data) if nl < 0 else stop + nl + 1), runtime.heap_allocator())
		ins.several = true
		return nil, msg, .Error
	}
	// jq's parser gives the events of the bytes before the fault, and with --stream-errors the fault as one, then
	// goes on from the line after the fault, or under --seq at the next record, where the reader is.
	seq, errors := ins.framing == .Seq, ins.run.opts.stream_errors
	stop := min(int(f.at), len(data))
	nl := bytes.index_byte(data[stop:], '\n')
	resume := len(data) if nl < 0 else stop + nl + 1
	if seq {
		rs := bytes.index_byte(data[at:], 0x1e)
		resume = len(data) if rs < 0 else at + rs
	}
	if seq && errors && f.rules == &json.RULES && f.detail == u8(json.Detail.Unframed) {
		// jq passes over what comes before the first separator, and tells a stream with none that it was abandoned.
		if resume < len(data) {
			return next_value(ins, false)
		}
		return abandoned(ins, data)
	}
	text := data[at:resume]
	if !errors {
		text = data[at:max(at, stop)]
		ins.fault_error = strings.clone(fault_message(ins, data, f), runtime.heap_allocator())
	}
	l, c := ins.parsed.line, ins.parsed.column
	jq.advance(&l, &c, data[:at])
	ins.pinned = true
	ins.walk, ins.walk_at = fault_walk(text, l, c, seq && errors, seq && errors && resume < len(data), ins.bom_broken, ins.walk_spare), at
	if !seq && errors {
		records.close(&ins.texts)
		ins.texts = records.open(data, ins.as, ins.framing, u64(resume), runtime.heap_allocator())
		ins.several = true
	} else if !seq {
		close_file(ins)
	}
	return next_value(ins, false)
}

// --stream-errors under --seq: the event jq gives at the end of a stream with no separator, its place past `counted`.
@(private = "file")
abandoned :: proc(ins: ^Inputs, counted: []byte) -> (jq.Value, string, jq.Parse_Status) {
	l, c := ins.parsed.line, ins.parsed.column
	jq.advance(&l, &c, counted)
	ev := jq.new_array(2)
	append(&ev.items, message.build("Unfinished abandoned text at EOF at line %d, column %d", l, c), jq.new_array())
	return ev, "", .Value
}

// -R: the next line of the input as a string, as jq's raw reader reads it: the bytes before a newline, a line running
// on from one file into the next, and each piece fgets reads made valid UTF-8 on its own. The last line without its
// newline. With `whole`, all of the input as one string.
@(private = "file")
next_raw :: proc(ins: ^Inputs, whole: bool) -> (jq.Value, string, jq.Parse_Status) {
	if ins.raw_done {
		return nil, "", .More
	}
	line := strings.builder_make()
	read := false
	for {
		if !ins.open || ins.raw_at == len(ins.data) {
			if ins.open && !ins.last {
				next_window(ins, len(ins.data))
				continue
			}
			close_file(ins)
			if !open_next(ins) {
				break
			}
			continue
		}
		n, newline := next_piece(ins.data[ins.raw_at:])
		piece := string(ins.data[ins.raw_at:][:n])
		ins.raw_at += n
		ins.line += int(newline)
		read = true
		if newline && !whole {
			jq.write_valid_utf8(&line, piece[:n - 1])
			return strings.to_string(line), "", .Value
		}
		jq.write_valid_utf8(&line, piece)
	}
	ins.raw_done = whole
	if !read && !whole {
		return nil, "", .More
	}
	return strings.to_string(line), "", .Value
}

// The length of the piece fgets reads from `left`, and whether it ends a line.
@(private = "file")
next_piece :: proc(left: []byte) -> (n: int, newline: bool) {
	window := left[:min(len(left), FGETS_MAX)]
	if i := bytes.index_byte(window, '\n'); i >= 0 {
		return i + 1, true
	}
	if len(window) < FGETS_MAX {
		return len(window), false
	}
	// jq's reader takes on the bytes that finish a UTF-8 sequence the piece ends inside.
	i := len(window) - 1
	for i >= 0 && window[i] & 0xc0 == 0x80 {
		i -= 1
	}
	missing := 0 if i < 0 else max(jq.utf8_length(window[i]) - (len(window) - i), 0)
	return FGETS_MAX + min(missing, len(left) - FGETS_MAX), false
}

// The next file opened and its first bytes read, passing over one that does not open or read. Returns false when none
// is left.
@(private = "file")
open_next :: proc(ins: ^Inputs) -> bool {
	for ins.next_file < len(ins.files) {
		path := ins.files[ins.next_file]
		ins.next_file += 1
		ins.name, ins.line, ins.line_end, ins.file_lines, ins.text_end = file_name(path), 0, 0, 0, 0
		delete(ins.head, runtime.heap_allocator())
		ins.head = nil
		f, opened := open_file(path)
		if !opened {
			ins.failures += 1
			continue
		}
		// A JSONC or JSON5 file is one text, its comments around it, so it is read whole.
		follow := ins.run.opts.follow
		if follow || !is_regular_file(f) && (reads_cells(&ins.run.opts) || ins.spec == .Json) {
			ins.pipe = pipe_start(f, follow, ins.name, ins.run)
			ins.open = true
			take_data(ins, nil)
			return true
		}
		data, mapped := map_file(f)
		read := mapped
		if mapped {
			mapped_input_name = ins.name
			if f != os.stdin {
				os.close(f)
			}
		} else {
			data, read = read_file(f)
		}
		if !read {
			ins.failures += 1
			continue
		}
		ins.run.route.input += len(data)
		ins.open, ins.last = true, true
		set_data(ins, data, mapped)
		return true
	}
	return false
}

// The name messages give the file `path` names, "-" being stdin.
file_name :: proc(path: string) -> string {
	return "<stdin>" if path == "-" else path
}

// The file `path` names opened, "-" being stdin, or false, told, when it does not open.
open_file :: proc(path: string) -> (f: ^os.File, ok: bool) {
	if path == "-" {
		return os.stdin, true
	}
	err: os.Error
	if f, err = open_input(path); err != nil {
		message.write_stderr("stury: error: Could not open file %s: %s\n", path, strerror(err))
		return nil, false
	}
	return f, true
}

// All of `f`, on the heap, and `f` closed but for stdin, or false, told, when it does not read.
read_file :: proc(f: ^os.File) -> (data: []byte, ok: bool) {
	heap := runtime.heap_allocator()
	err: os.Error
	data, err = read_whole(f, heap)
	if f != os.stdin {
		os.close(f)
	}
	if err != nil {
		message.write_stderr("stury: error: %s\n", strerror(err))
		delete(data, heap)
		return nil, false
	}
	return data, true
}

// `data` as the open file's bytes in memory, with its texts read from the start.
@(private = "file")
set_data :: proc(ins: ^Inputs, data: []byte, mapped := false) {
	retire(ins)
	// A window that opens with the header is a file's whose header is judged.
	ins.data, ins.mapped, ins.raw_at, ins.pieces, ins.header_judged, ins.parallel_from, ins.skip_below, ins.rows_end = data, mapped, 0, {}, ins.headed, 0, 0, 0
	ins.several = ins.framing != .Concatenated || !ins.last
	ins.texts = records.open(data, ins.as, ins.framing, allocator = runtime.heap_allocator())
	// jq counts a column from past the input's byte order mark.
	if ins.parsed == {line = 1} {
		ins.parsed.column = -int(core.text_start(data, 0))
	}
}

// The open file's next window: data[from:], a text the last window cut short, then the pipe's next whole lines.
@(private = "file")
next_window :: proc(ins: ^Inputs, from: int) {
	advance_past(ins, from)
	// --stream's lines are counted to `line_end`, which the window moves.
	if ins.run.opts.stream {
		ins.line +=bytes.count(ins.data[min(ins.line_end, from):from], {'\n'})
		ins.line_end = max(ins.line_end - from, 0)
	}
	take_data(ins, ins.data[from:])
}

// The open file's bytes from `from`, a --seq record no 0x1E ends, leading the next file that opens, as the open file's
// bytes. False when no file opens.
@(private = "file")
seq_join :: proc(ins: ^Inputs, from: int) -> bool {
	if ins.next_file == len(ins.files) {
		return false
	}
	heap := runtime.heap_allocator()
	carry := bytes.clone(ins.data[from:], heap)
	defer delete(carry, heap)
	advance_past(ins, from)
	if !open_next(ins) {
		return false
	}
	joined := make([]byte, len(carry) + len(ins.data), heap)
	copy(joined, carry)
	copy(joined[len(carry):], ins.data)
	set_data(ins, joined)
	return true
}

// The pipe's next window after `carry`, as the open file's bytes.
@(private = "file")
take_data :: proc(ins: ^Inputs, carry: []byte) {
	carry := carry
	if ins.fresh {
		carry, ins.file_lines, ins.parsed = nil, 0, {line = 1}
		delete(ins.head, runtime.heap_allocator())
		ins.head, ins.headed = nil, false
	}
	if ins.head != nil && !ins.headed {
		// The window's lines are counted from past the header, as the lines before it were.
		ins.file_lines -= bytes.count(ins.head, {'\n'})
	}
	// Each window takes the room the longest takes, so the heap reuses one window's room for the next rather than
	// keeping the rooms a window grew through.
	window := make([dynamic]byte, 0, len(ins.head) + len(carry) + READ_AHEAD + 2 * READ_BLOCK, runtime.heap_allocator())
	append(&window, ..ins.head)
	append(&window, ..carry)
	ended, restarted := pipe_take(ins.pipe, &window, len(carry))
	ins.fresh, ins.headed = restarted, ins.head != nil
	ins.run.route.input += len(window) - len(carry) - len(ins.head)
	ins.last = ended
	if ended {
		if err := pipe_end(ins.pipe); err != nil {
			message.write_stderr("stury: error: %s\n", strerror(err))
			ins.failures += 1
		}
		ins.pipe = nil
	}
	set_data(ins, window[:])
}

// Counts jq's place, and the open file's lines, past data[:to].
@(private = "file")
advance_past :: proc(ins: ^Inputs, to: int) {
	settle_line(ins)
	line := ins.parsed.line
	jq.advance(&ins.parsed.line, &ins.parsed.column, ins.data[min(len(ins.head), to) if ins.headed else 0:to])
	ins.file_lines += ins.parsed.line - line
}

// The open file read past.
close_file :: proc(ins: ^Inputs) {
	if !ins.open {
		return
	}
	// Only a fault in a later file reads the lines of this one.
	settle_line(ins)
	if ins.next_file < len(ins.files) {
		advance_past(ins, len(ins.data))
	}
	ins.open = false
}

// `ins.line` once it counts the lines of the text read last, which wait until something reads them.
@(private = "file")
settle_line :: proc(ins: ^Inputs) {
	if ins.text_end > 0 {
		ins.line, ins.text_end = lines_read(ins, ins.text_end), 0
	}
}

// The bytes of `data` freed, or kept in `spent` while a value lies in them.
@(private = "file")
retire :: proc(ins: ^Inputs) {
	records.close(&ins.texts)
	if ins.pinned || ins.run.opts.stream {
		// --stream's events and the walk of a faulty text read the text as they go, so it is kept for the run.
		append(&ins.spent, Spent{ins.data, ins.mapped})
	} else {
		free_spent({ins.data, ins.mapped})
	}
	ins.data, ins.pinned = nil, false
}

// A file's bytes read past, and whether they are its mapping.
Spent :: struct {
	data:   []byte,
	mapped: bool,
}

@(private = "file")
free_spent :: proc(d: Spent) {
	if d.mapped {
		unmap_file(d.data)
	} else {
		delete(d.data, runtime.heap_allocator())
	}
}

// The bytes read past freed, once the values the main loop read from them are printed.
release_spent :: proc(ins: ^Inputs) {
	if ins.run.opts.stream {
		return
	}
	for d in ins.spent {
		free_spent(d)
	}
	clear(&ins.spent)
	ins.pinned = false
}

// A pipe, or any file that is not a regular one, read as it comes through a stream of `records`, framed at line ends,
// which gives windows of whole lines. A read that would wait first writes the output so far, as what it waits for may
// be a while coming.
Pipe :: struct {
	file:    ^os.File,
	run:     ^Run,
	lines:   records.Reader,
	err:     os.Error, // the read that ended it, if it failed
	// --follow: the file is read on past its end, `name` is told when it shrinks, and `restart` says it did, so the
	// stream has ended on the old file's last lines and the next window starts the new file.
	follow:  bool,
	name:    string,
	read:    i64,
	restart: bool,
	taken:   u64, // the stream's bytes the windows hold end here
}

@(private = "file")
pipe_start :: proc(f: ^os.File, follow: bool, name: string, run: ^Run) -> ^Pipe {
	heap := runtime.heap_allocator()
	p := new(Pipe, heap)
	p.file, p.run, p.follow, p.name = f, run, follow, name
	p.lines = records.open_stream({pipe_read, p}, json.as(.Json), .Lines, allocator = heap)
	return p
}

@(private = "file")
pipe_read :: proc(data: rawptr, mode: io.Stream_Mode, buf: []byte, _: i64, _: io.Seek_From) -> (i64, io.Error) {
	p := (^Pipe)(data)
	if mode != .Read {
		return 0, .Unsupported
	}
	if !p.follow && !readable(p.file) {
		flush_some(&p.run.output, force = true)
	}
	for {
		n, err := read_some(p.file, buf)
		p.read += i64(n)
		switch {
		case p.follow && n == 0 && (err == nil || err == io.Error.EOF):
			if follow_idle(p) {
				return 0, .EOF
			}
		case n == 0 && err == nil || err == io.Error.EOF:
			return i64(n), .EOF
		case err != nil:
			p.err = err
			return i64(n), .Unknown
		case:
			return i64(n), nil
		}
	}
}

// Waits one poll at the end of a followed file, then looks at what ended the wait: a stop, or a file shorter than the
// bytes read, which is read again from its start once the stream has given the old file's lines. Returns true when the
// stream ends.
@(private = "file")
follow_idle :: proc(p: ^Pipe) -> bool {
	flush_some(&p.run.output, force = true)
	time.sleep(FOLLOW_POLL)
	if sync.atomic_load(&stopped) {
		return true
	}
	if size, err := os.file_size(p.file); err == nil && size < p.read {
		message.write_stderr("stury: %s: file truncated\n", p.name)
		os.seek(p.file, 0, .Start)
		p.read, p.restart = 0, true
		return true
	}
	return false
}

// Appends the pipe's next whole lines to `window`, which holds `carry` bytes of a text cut short: one window of them,
// then more while they come at once, up to READ_AHEAD, or while a long text cut short is longer than what came, so a
// text spread over many windows is read again only as often as its length doubles. Returns whether the pipe has ended,
// when `window` holds all of it, and whether the file shrank, so the next window starts a new file.
@(private = "file")
pipe_take :: proc(p: ^Pipe, window: ^[dynamic]byte, carry: int) -> (ended, restarted: bool) {
	start := len(window)
	for {
		lines, at, more := records.next_window(&p.lines)
		pipe_append(p, window, lines, at)
		if !more || p.lines.last {
			if !p.restart {
				// The bytes past the last line end.
				pipe_append(p, window, p.lines.held, p.lines.held_at)
				return true, false
			}
			// A line the old file ended without its newline is not the new file's.
			records.close(&p.lines)
			p.lines = records.open_stream({pipe_read, p}, json.as(.Json), .Lines, allocator = runtime.heap_allocator())
			p.restart, p.taken = false, 0
			return false, true
		}
		got := len(window) - start
		// A followed file reads at once up to its end, where it waits. A window READ_AHEAD long takes one block more when
		// it comes, so an input that ends there is one window and its last.
		if got >= READ_AHEAD + READ_BLOCK || (got >= READ_AHEAD || carry < READ_BLOCK || got >= carry) && (p.follow || !readable(p.file, PIPE_WAIT)) {
			return false, false
		}
	}
}

// The stream's bytes at `at` appended to the window. The stream reads past the input's byte order mark, which the
// window keeps, as the texts' reader judges it.
@(private = "file")
pipe_append :: proc(p: ^Pipe, window: ^[dynamic]byte, b: []byte, at: u64) {
	if len(b) == 0 {
		return
	}
	if at > p.taken {
		append(window, ..BOM)
	}
	append(window, ..b)
	p.taken = at + u64(len(b))
}

@(private = "file")
BOM :: []byte{0xef, 0xbb, 0xbf}

// The pipe's stream closed and its memory freed. Returns the error its last read failed with.
@(private = "file")
pipe_end :: proc(p: ^Pipe) -> os.Error {
	records.close(&p.lines)
	err := p.err
	if p.file != os.stdin {
		os.close(p.file)
	}
	free(p, runtime.heap_allocator())
	return err
}

// The lines of the open file read once a text ends at data[end]: through the line end after the text's last byte. jq
// counts through the piece its fgets reads, which on a line past 4 KiB ends before the line does. `ins.pieces` counts
// on from the call before, so a file's texts are counted in one pass.
@(private = "file")
lines_read :: proc(ins: ^Inputs, end: int) -> int {
	data := ins.data
	last := min(max(end - 1, 0), len(data))
	nl := bytes.index_byte(data[last:], '\n')
	stop := len(data) if nl < 0 else last + nl + 1
	c := &ins.pieces
	if stop < c.at {
		c^ = {}
	}
	c.lines += bytes.count(data[c.at:stop], {'\n'})
	c.at = stop
	return ins.file_lines + c.lines
}

@(private = "file")
is_letter :: proc(c: byte) -> bool {
	return c | 0x20 >= 'a' && c | 0x20 <= 'z'
}

// `ins.line` once jq's parser has read the open file's text to byte `at`, counted on from the call before, as --stream's
// events read on through the text.
@(private = "file")
lines_through :: proc(ins: ^Inputs, at: int) {
	if at < ins.line_end {
		return
	}
	data := ins.data
	nl := bytes.index_byte(data[at:], '\n')
	stop := len(data) if nl < 0 else at + nl + 1
	ins.line += bytes.count(data[ins.line_end:stop], {'\n'})
	ins.line_end = stop
}

// The length of the byte order mark's start that `data` opens with when the mark is cut short, else 0.
@(private = "file")
cut_bom_len :: proc(data: []byte) -> int {
	bom := BOM
	k := 0
	for k < len(data) && k < len(bom) && data[k] == bom[k] {
		k += 1
	}
	return k if k < len(bom) else 0
}

// A JSONC or JSON5 text the library refuses, told as `fault_told` tells it, with `fault_note` after. Ends the run.
@(private = "file")
fail_dialect :: proc(ins: ^Inputs, data: []byte, f: core.Fault) -> ! {
	run := ins.run
	flush_some(&run.output, force = true)
	message.write_stderr("stury: error: %s\n%s", fault_told(ins.name, data, f, ins.spec, ins.file_lines), fault_note(data, f, ins.spec, &run.opts))
	finish(run, EXIT_INPUT)
}

// The fault `f` of the text `data` of file `name`, read as `spec` or delimited, told as `NAME:LINE:COLUMN: SENTENCE`, its line counted
// on from the `lines` before `data`, or as `NAME: SENTENCE` when it is at no byte. A JSON text's sentence is the one jq's
// messages use (`jq.fault_sentence`).
fault_told :: proc(name: string, data: []byte, f: core.Fault, spec: Maybe(json.Spec), lines := 0) -> string {
	if f.rules != &json.RULES {
		line, col := core.locate(data, f.at)
		return message.build_temp("%s:%d:%d: %s", name, line + u64(lines), col, core.rule_of(f).message)
	}
	if f.kind in core.AT_NO_BYTE {
		return message.build_temp("%s: %s", name, jq.fault_sentence(f, ""))
	}
	line, col := core.locate(data, f.at)
	rest := string(data[f.at:])
	sentence := jq.fault_sentence(f, rest)
	// JSON5 spells them, JSON has no value for them, and the library refuses them as a literal.
	unsigned := strings.trim_left(rest, "+-")
	if spec == .Json5 && f.kind == .Bad_Char && (strings.has_prefix(unsigned, "Infinity") || strings.has_prefix(unsigned, "NaN")) {
		sentence = "Infinity and NaN have no JSON value"
	}
	return message.build_temp("%s:%d:%d: %s", name, line + u64(lines), col, sentence)
}

// The fault `f` of the records of `data` framed by `framing`, but under `.Lines` and `.Seq` a word cut short by its
// record's end, where jq ends a literal, is an invalid literal.
literal_cut :: proc(data: []byte, f: core.Fault, framing: core.Framing) -> core.Fault {
	if (framing == .Lines || framing == .Seq) && f.kind == .Truncated && f.detail == 0 && f.rules == &json.RULES && f.at > 0 && int(f.at) < len(data) && is_letter(data[f.at - 1]) {
		return {at = f.at, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Literal)}
	}
	return f
}

// For the faults whose cure is a flag of stury's own, the line of `data` the fault `f` is at, a caret under its byte,
// and the flag, else "". A trailing comma and a comment are JSONC's, and a nesting past the cap is raised by
// --max-depth, which the hint asks for only when it was not given. The text ends in a newline.
fault_note :: proc(data: []byte, f: core.Fault, spec: Maybe(json.Spec), o: ^Opts) -> string {
	at := int(f.at)
	hint: string
	switch {
	case f.kind == .Too_Deep:
		hint = "a larger --max-depth reads it" if o.max_depth != 0 else "--max-depth N raises the nesting limit"
	case f.kind != .Bad_Char || at >= len(data) || spec != .Json:
		return ""
	case data[at] == '/' && at + 1 < len(data) && (data[at + 1] == '/' || data[at + 1] == '*'):
		hint = "--from jsonc reads comments"
	case data[at] == ']' || data[at] == '}':
		before := at
		for before > 0 && jq.is_space(data[before - 1]) {
			before -= 1
		}
		if before == 0 || data[before - 1] != ',' {
			return ""
		}
		hint = "--from jsonc reads a trailing comma"
	case:
		return ""
	}
	at = min(at, len(data) - 1)
	// The line, cut to a screenful around the byte.
	first, last := at, at
	for first > 0 && data[first - 1] != '\n' && at - first < 40 {
		first -= 1
	}
	for last < len(data) && data[last] != '\n' && data[last] != '\r' && last - at < 40 {
		last += 1
	}
	// The note outlives the memory of the input whose events come before it.
	heap := runtime.heap_allocator()
	pad := bytes.repeat({' '}, at - first, heap)
	for &c, i in pad {
		if data[first + i] == '\t' {
			c = '\t'
		}
	}
	return message.build("%s\n%s^\n(%s)\n", data[first:last], pad, hint, allocator = heap)
}

// What `input`, `inputs`, `input_filename` and `input_line_number` read.
bind_inputs :: proc(ip: ^jq.Interp, ins: ^Inputs) {
	ip.inputs = {
		data = ins,
		next = proc(data: rawptr) -> (jq.Value, string, jq.Parse_Status) {
			return next_input((^Inputs)(data), own = true)
		},
		position = proc(data: rawptr) -> (string, int) {
			ins := (^Inputs)(data)
			settle_line(ins)
			return ins.name, ins.line
		},
	}
}

// All of file `f`, to its end. os.read_entire_file reads as many bytes as fstat gives, which for a pipe is
// only what is in it so far, so it reads only a regular file.
read_whole :: proc(f: ^os.File, allocator: runtime.Allocator) -> (data: []byte, err: os.Error) {
	if is_regular_file(f) {
		return os.read_entire_file(f, allocator)
	}
	all := make([dynamic]byte, 0, 1 << 16, allocator)
	chunk: [1 << 16]byte
	for {
		n, rerr := read_some(f, chunk[:])
		append(&all, ..chunk[:n])
		if rerr != nil || n == 0 {
			if rerr != io.Error.EOF {
				err = rerr
			}
			break
		}
	}
	return all[:], err
}

// What C's strerror says of `err`, which jq prints.
strerror :: proc(err: os.Error) -> string {
	#partial switch e in err {
	case os.Platform_Error:
		return platform_error_text(e)
	case os.General_Error:
		if e == .Not_Exist {
			return string(posix.strerror(posix.Errno.ENOENT))
		}
	case io.Error:
		if e == .Permission_Denied {
			return string(posix.strerror(posix.Errno.EACCES))
		}
	}
	return os.error_string(err)
}
