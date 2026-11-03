package main

// Reading the files and stdin a run names, as jq reads them: the files one after another, each a run of texts (jq's
// default, `.Concatenated`), of lines (--from ndjson, `.Lines`) or of records after 0x1E (--seq, `.Seq`), or under -R of
// lines read as strings. A text ends within its file, and a JSONC or JSON5 file is one text. A file that does not open is told and counted, and a text that
// does not parse is told in jq's form.
//
// A regular file is read whole. Any other (a pipe, a terminal) is read by a thread of its own (`Pipe`) and taken a
// window of whole lines at a time, so a text is answered once its line has come.

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import core "../../core"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

@(rodata)
STDIN_ONLY := []string{"-"}

// The longest piece jq's fgets reads under -R: its 4096-byte buffer, less room to finish a UTF-8 sequence.
FGETS_MAX :: 4091

// How far a pipe's thread reads ahead of the window taken last, once what it holds has a line end.
READ_AHEAD :: 8 << 20

// How much a pipe's thread reads at once.
READ_BLOCK :: 1 << 16

// How the inputs are read: `as`, the format's handle, which `core.build` and `core.validate` read a text through
// whatever the format is, and how a file's texts follow each other.
Source :: struct {
	as:      core.As,
	framing: core.Framing,
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
	last:      bool,
	pipe:      ^Pipe,
	texts:     records.Reader,
	several:   bool,
	parallel_from: u64, // where pieces may start again, past a record they stopped at
	skip_below: u64, // a delimited text's records before it are answered by pieces
	pinned:    bool,
	header_judged: bool, // --from csv or tsv: the open file's first record is read
	spent:     [dynamic][]byte,
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
	}, // `lines_read`'s place: the first piece of data fgets has not read, and the line ends before it
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
			return nil, msg, .Error
		case .Value:
			append(&all.items, v)
		case .More:
			break read
		}
	}
	ins.slurp = false
	return all, "", .Value
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
		if k := cut_bom_len(ins.data); k > 0 && ins.run.opts.stream_errors && ins.framing == .Concatenated && ins.next_file == 1 && !ins.has_text && ins.file_lines == 0 {
			// jq's parser drops the bytes of the mark it matched, and refuses the stream whole when more follow.
			if k < len(ins.data) {
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
		from := ins.texts.pos
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
		// A text the window cuts short, or one --seq's separator may yet end, waits for the next window.
		if !ins.last && (ok && ins.framing == .Seq && bytes.index_byte(ins.data[rec.at:], 0x1e) < 0 || !ok && cut_short(ins)) {
			// The reader has passed the record's separator, which the next window must start with.
			if rs := bytes.last_index_byte(ins.data[:rec.at], 0x1e); ok && rs >= 0 {
				from = u64(rs)
			}
			next_window(ins, int(from))
			continue
		}
		if !ok {
			if f, bad := ins.texts.fault.?; bad {
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
	if blank(data, json.Spec(ins.as.spec)) {
		close_file(ins)
		return
	}
	stray_bom := ins.has_text && bytes.has_prefix(data, {0xef, 0xbb, 0xbf})
	ins.has_text = true
	run := ins.run
	if !stray_bom && (entries_pieces(ins) || run.route.scanning && answer_path(run, data, ins.as)) {
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
		if !stray_bom && f.rules == &json.RULES && f.detail == u8(json.Detail.Trailing) && json.Spec(ins.as.spec) == .Json {
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

// Whether the records of a window that is not the file's last ended on a text cut short at the window's end.
@(private = "file")
cut_short :: proc(ins: ^Inputs) -> bool {
	f, bad := ins.texts.fault.?
	return !bad || f.kind == .Truncated && int(f.at) >= len(ins.data)
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

// The fault `f` of the text at or after data[at:] as jq tells it, or under --stream the events jq's parser makes of
// the text before it. An NDJSON record ends at `end`.
@(private = "file")
text_fault :: proc(ins: ^Inputs, f: core.Fault, at: int, end := -1) -> (jq.Value, string, jq.Parse_Status) {
	data := ins.data
	if reads_cells(&ins.run.opts) {
		return cells_fault(ins, f)
	}
	if json.Spec(ins.as.spec) != .Json {
		fail_dialect(ins, data, f)
	}
	ins.note = fault_note(data, f, ins.as, &ins.run.opts)
	if !ins.run.opts.stream {
		ins.line, ins.text_end = lines_read(ins, int(f.at) + 1), 0
		// A record of NDJSON ends at its line's end, where jq ends a literal.
		what := ""
		if end >= 0 && end < len(data) && f.kind == .Truncated && f.at > 0 && is_letter(data[f.at - 1]) {
			what = "Invalid literal"
		}
		msg := jq.parse_message(data, f, ins.parsed.line, ins.parsed.column, what, end)
		// jq's parser goes on from the line after the fault, which `input` reads next.
		stop := min(int(f.at), len(data))
		nl := bytes.index_byte(data[stop:], '\n')
		records.close(&ins.texts)
		ins.texts = records.open(data, ins.as, ins.framing, u64(len(data) if nl < 0 else stop + nl + 1), runtime.heap_allocator())
		ins.several = true
		return nil, msg, .Error
	}
	// jq's parser gives the events of the bytes before the fault, and with --stream-errors the fault as one, then
	// goes on from the line after the fault.
	stop := min(int(f.at), len(data))
	nl := bytes.index_byte(data[stop:], '\n')
	resume := len(data) if nl < 0 else stop + nl + 1
	text := data[at:resume]
	if !ins.run.opts.stream_errors {
		text = data[at:max(at, stop)]
		ins.fault_error = strings.clone(jq.parse_message(data, f, ins.parsed.line, ins.parsed.column), runtime.heap_allocator())
	}
	l, c := ins.parsed.line, ins.parsed.column
	jq.advance(&l, &c, data[:at])
	ins.pinned = true
	ins.walk, ins.walk_at = fault_walk(text, l, c, false, false, false, ins.walk_spare), at
	if ins.run.opts.stream_errors {
		records.close(&ins.texts)
		ins.texts = records.open(data, ins.as, ins.framing, u64(resume), runtime.heap_allocator())
		ins.several = true
	} else {
		close_file(ins)
	}
	return next_value(ins, false)
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
		f, opened := open_file(path)
		if !opened {
			ins.failures += 1
			continue
		}
		// A JSONC or JSON5 file is one text, its comments around it, so it is read whole, and so is a delimited one, whose
		// header heads all of it.
		if !is_regular_file(f) && json.Spec(ins.as.spec) == .Json && !reads_cells(&ins.run.opts) {
			ins.pipe = pipe_start(f)
			ins.open = true
			take_data(ins, nil)
			return true
		}
		data, read := read_file(f)
		if !read {
			ins.failures += 1
			continue
		}
		ins.run.route.input += len(data)
		ins.open, ins.last = true, true
		set_data(ins, data)
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
set_data :: proc(ins: ^Inputs, data: []byte) {
	retire(ins)
	ins.data, ins.raw_at, ins.pieces, ins.header_judged, ins.parallel_from, ins.skip_below = data, 0, {}, false, 0, 0
	ins.several = ins.framing != .Concatenated || !ins.last
	ins.texts = records.open(data, ins.as, ins.framing, allocator = runtime.heap_allocator())
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

// The pipe's next window after `carry`, as the open file's bytes.
@(private = "file")
take_data :: proc(ins: ^Inputs, carry: []byte) {
	window, ended := pipe_take(ins.pipe, carry, ins.run)
	ins.run.route.input += len(window) - len(carry)
	ins.last = ended
	if ended {
		if err := pipe_end(ins.pipe); err != nil {
			message.write_stderr("stury: error: %s\n", strerror(err))
			ins.failures += 1
		}
		ins.pipe = nil
	}
	set_data(ins, window)
}

// Counts jq's place, and the open file's lines, past data[:to].
@(private = "file")
advance_past :: proc(ins: ^Inputs, to: int) {
	settle_line(ins)
	line := ins.parsed.line
	jq.advance(&ins.parsed.line, &ins.parsed.column, ins.data[:to])
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
		append(&ins.spent, ins.data)
	} else {
		delete(ins.data, runtime.heap_allocator())
	}
	ins.data, ins.pinned = nil, false
}

// The bytes read past freed, once the values the main loop read from them are printed.
release_spent :: proc(ins: ^Inputs) {
	if ins.run.opts.stream {
		return
	}
	for d in ins.spent {
		delete(d, runtime.heap_allocator())
	}
	clear(&ins.spent)
	ins.pinned = false
}

// A pipe, or any file that is not a regular one, read on a thread of its own as it comes, so a window's texts are
// answered while the next window's bytes arrive. The thread stops READ_AHEAD bytes ahead of what is taken once those
// hold a line end. A line longer than that it reads whole.
Pipe :: struct {
	file:    ^os.File,
	mutex:   sync.Mutex,
	cond:    sync.Cond, // signalled when bytes are read or taken
	pending: [dynamic]byte, // read and not yet taken
	newline: bool, // pending holds a line end
	ended:   bool,
	err:     os.Error, // the read that ended it, if it failed
	thread:  ^thread.Thread,
}

@(private = "file")
pipe_start :: proc(f: ^os.File) -> ^Pipe {
	context.allocator = runtime.heap_allocator()
	p := new(Pipe)
	p.file = f
	p.pending = make([dynamic]byte, 0, READ_BLOCK)
	p.thread = thread.create_and_start_with_poly_data(p, proc(p: ^Pipe) {
		block := make([]byte, READ_BLOCK, runtime.heap_allocator())
		defer delete(block, runtime.heap_allocator())
		for {
			n, err := read_some(p.file, block)
			sync.mutex_lock(&p.mutex)
			append(&p.pending, ..block[:n])
			p.newline ||= bytes.index_byte(block[:n], '\n') >= 0
			if err != nil || n == 0 {
				p.ended, p.err = true, nil if err == io.Error.EOF || n == 0 && err == nil else err
			}
			sync.cond_broadcast(&p.cond)
			for !p.ended && p.newline && len(p.pending) >= READ_AHEAD {
				sync.cond_wait(&p.cond, &p.mutex)
			}
			ended := p.ended
			sync.mutex_unlock(&p.mutex)
			if ended {
				return
			}
		}
	})
	return p
}

// `carry` and then the pipe's whole lines read so far, waiting for a line end or the pipe's end, and whether the
// pipe has ended, when the window is all of it. Before it first waits, the output so far is written, as what is waited
// for may be a while coming.
@(private = "file")
pipe_take :: proc(p: ^Pipe, carry: []byte, run: ^Run) -> (window: []byte, ended: bool) {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	for waited := false; !p.newline && !p.ended; waited = true {
		if !waited {
			sync.mutex_unlock(&p.mutex)
			flush_some(&run.output, force = true)
			sync.mutex_lock(&p.mutex)
			continue
		}
		sync.cond_wait(&p.cond, &p.mutex)
	}
	end := len(p.pending) if p.ended else bytes.last_index_byte(p.pending[:], '\n') + 1
	window = make([]byte, len(carry) + end, runtime.heap_allocator())
	copy(window, carry)
	copy(window[len(carry):], p.pending[:end])
	remove_range(&p.pending, 0, end)
	p.newline = false
	sync.cond_broadcast(&p.cond)
	return window, p.ended
}

// The pipe's thread joined and its memory freed. Returns the error its last read failed with.
@(private = "file")
pipe_end :: proc(p: ^Pipe) -> os.Error {
	thread.destroy(p.thread)
	err := p.err
	if p.file != os.stdin {
		os.close(p.file)
	}
	delete(p.pending)
	free(p, runtime.heap_allocator())
	return err
}

// The run is over with a pipe not read to its end, as `input` leaves it: its thread is left to the process's exit,
// detached, as it may wait on a pipe that never ends, and one that ended unjoined is a thread never released.
abandon_inputs :: proc(ins: ^Inputs) {
	when ODIN_OS != .Windows {
		if ins.pipe != nil {
			posix.pthread_detach(ins.pipe.thread.unix_thread)
		}
	}
}

// The lines jq's parser has read of the open file once a text ends at data[end]: through the piece fgets reads that
// holds the text's last byte. `ins.pieces` counts on from the call before, so a file's texts are counted in one pass.
@(private = "file")
lines_read :: proc(ins: ^Inputs, end: int) -> int {
	last := max(end - 1, 0)
	c := &ins.pieces
	if last < c.at {
		c^ = {}
	}
	for c.at < len(ins.data) {
		n, newline := next_piece(ins.data[c.at:])
		if c.at + n > last {
			return ins.file_lines + c.lines + int(newline)
		}
		c.at += n
		c.lines += int(newline)
	}
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

// Whether `data` holds no text: only space, after a byte order mark, and under JSONC or JSON5 only space and finished
// comments.
blank :: proc(data: []byte, spec := json.Spec.Json) -> bool {
	data := data
	if len(data) >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf {
		data = data[3:]
	}
	for i := 0; i < len(data); i += 1 {
		switch {
		case jq.is_space(data[i]):
		case spec == .Json || data[i] != '/' || i + 1 == len(data):
			return false
		case data[i + 1] == '/':
			nl := bytes.index_byte(data[i:], '\n')
			i = len(data) if nl < 0 else i + nl
		case data[i + 1] == '*':
			end := bytes.index(data[i + 2:], {'*', '/'})
			if end < 0 {
				return false
			}
			i += end + 3
		case:
			return false
		}
	}
	return true
}

// The length of the byte order mark's start that `data` opens with when the mark is cut short, else 0.
@(private = "file")
cut_bom_len :: proc(data: []byte) -> int {
	BOM := [3]u8{0xef, 0xbb, 0xbf}
	k := 0
	for k < len(data) && k < len(BOM) && data[k] == BOM[k] {
		k += 1
	}
	return k if k < len(BOM) else 0
}

// A JSONC or JSON5 text the library refuses, told as `fault_told` tells it, with `fault_note` after. Ends the run.
@(private = "file")
fail_dialect :: proc(ins: ^Inputs, data: []byte, f: core.Fault) -> ! {
	run := ins.run
	flush_some(&run.output, force = true)
	message.write_stderr("stury: error: %s\n%s", fault_told(ins.name, data, f, ins.as, ins.file_lines), fault_note(data, f, ins.as, &run.opts))
	finish(run, EXIT_INPUT)
}

// The fault `f` of the text `data` of file `name`, read as `as`, told as `NAME:LINE:COLUMN: SENTENCE`, its line counted
// on from the `lines` before `data`, or as `NAME: SENTENCE` when it is at no byte. A JSON text's sentence is the one jq's
// messages use (`jq.fault_sentence`).
fault_told :: proc(name: string, data: []byte, f: core.Fault, as: core.As, lines := 0) -> string {
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
	if json.Spec(as.spec) == .Json5 && f.kind == .Bad_Char && (strings.has_prefix(unsigned, "Infinity") || strings.has_prefix(unsigned, "NaN")) {
		sentence = "Infinity and NaN have no JSON value"
	}
	return message.build_temp("%s:%d:%d: %s", name, line + u64(lines), col, sentence)
}

// The fault `f` of the records of `data` framed by `framing`, but under `.Lines` a word cut short by its line's end,
// where jq ends a literal, is an invalid literal.
literal_cut :: proc(data: []byte, f: core.Fault, framing: core.Framing) -> core.Fault {
	if framing == .Lines && f.kind == .Truncated && f.rules == &json.RULES && f.at > 0 && int(f.at) < len(data) && is_letter(data[f.at - 1]) {
		return {at = f.at, rules = &json.RULES, kind = .Bad_Char, detail = u8(json.Detail.Literal)}
	}
	return f
}

// For the faults whose cure is a flag of stury's own, the line of `data` the fault `f` is at, a caret under its byte,
// and the flag, else "". A trailing comma and a comment are JSONC's, and a nesting past the cap is raised by
// --max-depth, which the hint asks for only when it was not given. The text ends in a newline.
fault_note :: proc(data: []byte, f: core.Fault, as: core.As, o: ^Opts) -> string {
	at := int(f.at)
	hint: string
	switch {
	case f.kind == .Too_Deep:
		hint = "a larger --max-depth reads it" if o.max_depth != 0 else "--max-depth N raises the nesting limit"
	case f.kind != .Bad_Char || at >= len(data) || json.Spec(as.spec) != .Json:
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
