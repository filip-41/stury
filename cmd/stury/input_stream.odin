package main

// File opening, background `Stream_Reader` windowing, spent buffers, and `fgets` line/piece framing for
// `input.odin`.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:io"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import json "../../json"
import "jq"

// Open the next file for the library and read it whole. It returns false if none is left. A file that does not open
// or read is reported as jq reports it and counted, and the stream goes on.
open_next :: proc(ins: ^Inputs) -> bool {
	if ins.reader != nil {
		next_window(ins, len(ins.data))
		return true
	}
	if ins.next_file == len(ins.files) {
		return false
	}
	place_past(ins, len(ins.data))
	retire(ins, ins.data)
	ins.data, ins.mapped, ins.lines_before, ins.window_lines = nil, false, 0, 0
	ins.skip, ins.pos, ins.seen, ins.lines, ins.open, ins.texts_follow, ins.lines_tried, ins.line_records = 0, 0, 0, {}, true, false, false, ins.run.opts.from == .Ndjson
	ins.fault_at, ins.seq_head = {}, .Unread
	file, ok := open_file(ins)
	if !ok {
		return true
	}
	if ins.may_stream && streams(ins, file) {
		ins.reader = start_reader(file)
		next_window(ins, 0)
	} else if data, mapped := map_file(file); mapped {
		close_file(file)
		ins.data, ins.mapped = data, true
		mapped_input_name = ins.name
	} else {
		all, err := read_whole(file, runtime.heap_allocator())
		close_file(file)
		if err != nil {
			read_failed(ins, err)
			return true
		}
		ins.data = all
	}
	data := ins.data
	if !ins.bom_done && len(data) > 0 {
		if bytes.has_prefix(data, UTF8_BOM[:]) {
			ins.skip, ins.pos = len(UTF8_BOM), len(UTF8_BOM)
		}
		ins.bom_done = true
	}
	return true
}

// Whether file `f` is read a window at a time: one that is not a regular file, whose end is not known until
// it comes, a regular file past STREAM_FILE_MIN bytes (JSON only when its first line looks like one record,
// unless `records` is false), stdin under --unbuffered, and any under -n, where `input` reads it and each window
// read past is freed (`retire`).
streams :: proc(ins: ^Inputs, f: ^os.File, records := true) -> bool {
	if f == os.stdin && ins.run.opts.unbuffered || ins.run.opts.null_input || !is_regular_file(f) {
		return true
	}
	size, err := os.file_size(f)
	return err == nil && size > STREAM_FILE_MIN && (!records || starts_with_record(f))
}

// A regular file of records past this is read in windows. Below it, windows cost more than they save.
STREAM_FILE_MIN :: 64 << 20

// Whether regular file `f`'s first line looks like one whole record, `{...}` or `[...]`. A document longer
// than a line, as a pretty one, is not read in windows, which would each hold it again. A head that does
// not read is read whole, whose read reports it.
// A guess from the line's ends, which costs only time and memory when wrong: a first line such as
// `{"a": 1}, {"b": [2]}` passes.
@(private = "file")
starts_with_record :: proc(f: ^os.File) -> bool {
	head: [1 << 16]byte
	n, _ := os.read_at(f, head[:], 0)
	nl := bytes.index_byte(head[:n], '\n')
	if nl < 0 {
		return false
	}
	line := bytes.trim_space(bytes.trim_prefix(head[:nl], UTF8_BOM[:]))
	if len(line) < 2 {
		return false
	}
	first, last := line[0], line[len(line) - 1]
	return first == '{' && last == '}' || first == '[' && last == ']'
}

// A stream's reader: a thread that reads it as it comes, so a window's texts are answered while the next window's
// bytes arrive, and a window holds what came meanwhile. It stops READ_AHEAD bytes ahead of what is taken once those
// hold a newline. A line longer than that it reads whole.
Stream_Reader :: struct {
	file:    ^os.File,
	mutex:   sync.Mutex,
	cond:    sync.Cond, // signalled when bytes are read or taken
	// Read and not yet taken, from `taken` on. Between windows it starts with the last window's tail, the
	// bytes after its last newline.
	pending: [dynamic]byte,
	taken:   int,
	newline: bool, // pending holds a newline
	lines:   int, // the newlines in pending: counted here, where the thread would otherwise wait, not by the window's taker
	ended:   bool,
	err:     os.Error, // the read that ended it, if it failed
	thread:  ^thread.Thread,
}

READ_AHEAD :: 8 << 20

// Start reading the stream `f` on a thread of its own.
@(private = "file")
start_reader :: proc(f: ^os.File) -> ^Stream_Reader {
	// Not an input's arena, which is emptied while the thread runs.
	context.allocator = runtime.heap_allocator()
	r := new(Stream_Reader)
	r.file = f
	r.pending = make([dynamic]byte, 0, READ_AHEAD + READ_BLOCK)
	r.thread = thread.create_and_start_with_poly_data(r, proc(r: ^Stream_Reader) {
		block := make([]byte, READ_BLOCK, runtime.heap_allocator())
		for {
			n, err := read_some(r.file, block)
			lines := count_newlines(block[:n])
			sync.mutex_lock(&r.mutex)
			append(&r.pending, ..block[:n])
			r.lines += lines
			r.newline ||= lines > 0
			if err != nil || n == 0 {
				r.ended, r.err = true, nil if err == io.Error.EOF else err
			}
			sync.cond_broadcast(&r.cond)
			for !r.ended && r.newline && len(r.pending) - r.taken >= READ_AHEAD {
				sync.cond_wait(&r.cond, &r.mutex)
			}
			ended := r.ended
			sync.mutex_unlock(&r.mutex)
			if ended {
				delete(block, runtime.heap_allocator())
				return
			}
		}
	})
	return r
}

// Wait for the reader, whose mutex is held: the first time, the output so far is written, as what is
// waited for may be a while coming.
@(private = "file")
wait_reader :: proc(ins: ^Inputs, r: ^Stream_Reader, waited: ^bool) {
	if waited^ {
		sync.cond_wait(&r.cond, &r.mutex)
		return
	}
	waited^ = true
	sync.mutex_unlock(&r.mutex)
	flush_some(ins.run, force = true)
	sync.mutex_lock(&r.mutex)
}

// The end of the open stream: its read error reported, if it failed, and its reader stopped.
@(private = "file")
end_stream :: proc(ins: ^Inputs) {
	r := ins.reader
	thread.destroy(r.thread)
	if r.err != nil {
		read_failed(ins, r.err)
	}
	delete(r.pending)
	free(r, runtime.heap_allocator())
	ins.reader = nil
}

// The run is over with the stream not read to its end, as `input` leaves it: its reader is left to
// the process's exit, detached, as it may wait on a pipe that never ends, and one that ended unjoined is a
// thread never released (TSan's "thread leak").
abandon_reader :: proc(ins: ^Inputs) {
	when ODIN_OS != .Windows {
		if ins.reader != nil {
			posix.pthread_detach(ins.reader.thread.unix_thread)
		}
	}
}

// The open stream's next window: data[from:], a text the last window cut short, then what the stream brings after it,
// `want` bytes at least and a newline past it, and all that has come meanwhile, up to its last newline. At the
// stream's end, all of it. With nothing cut short, the window is the reader's bytes, handed over whole. A text with
// no newline stays in the window until one comes, as jq's fgets holds a line.
next_window :: proc(ins: ^Inputs, from: int, want := 0) {
	place_past(ins, from)
	spent, cut := ins.data, ins.data[from:]
	cut_lines := count_newlines(cut)
	ins.lines_before += ins.window_lines - cut_lines
	window_lines := cut_lines
	r := ins.reader
	sync.mutex_lock(&r.mutex)
	waited := false
	window: [dynamic]byte
	if len(cut) == 0 && want == 0 {
		for !r.newline && !r.ended {
			wait_reader(ins, r, &waited)
		}
		window, r.pending = r.pending, nil
		window_lines, r.lines = r.lines, 0
	} else {
		// Taken as it comes, as the reader stops READ_AHEAD bytes ahead.
		window = make([dynamic]byte, 0, len(cut) + len(r.pending), runtime.heap_allocator())
		append(&window, ..cut)
		for {
			for len(r.pending) == 0 && !r.ended {
				wait_reader(ins, r, &waited)
			}
			append(&window, ..r.pending[:])
			clear(&r.pending)
			window_lines, r.lines = window_lines + r.lines, 0
			sync.cond_broadcast(&r.cond)
			if r.ended || r.newline && len(window) >= want {
				break
			}
		}
	}
	ended := r.ended
	ins.data, ins.window_lines = window[:], window_lines
	if !ended {
		end := bytes.last_index_byte(window[:], '\n') + 1
		if r.pending == nil {
			r.pending = make_unzeroed(READ_AHEAD + READ_BLOCK + len(window) - end)
		}
		append(&r.pending, ..window[end:])
		ins.data = window[:end]
	}
	r.newline = false
	sync.cond_broadcast(&r.cond)
	sync.mutex_unlock(&r.mutex)
	if ended {
		close_file(r.file)
		end_stream(ins)
	}
	retire(ins, spent)
	ins.skip, ins.pos, ins.seen, ins.lines, ins.lines_tried, ins.open = 0, 0, 0, {}, false, true
	ins.fault_at = {}
}

// An empty buffer of room for `cap` bytes, which the heap does not zero: the reader fills it.
@(private = "file")
make_unzeroed :: proc(cap: int) -> [dynamic]byte {
	heap := runtime.heap_allocator()
	room, err := runtime.mem_alloc_non_zeroed(cap, 1, heap)
	if err != nil {
		return make([dynamic]byte, 0, cap, heap)
	}
	return transmute([dynamic]byte)runtime.Raw_Dynamic_Array{data = raw_data(room), cap = cap, allocator = heap}
}

// The newlines in `b`: a search per line, which finds each at the speed of a memory scan.
count_newlines :: proc(b: []byte) -> (n: int) {
	for rest := b; ; n += 1 {
		i := bytes.index_byte(rest, '\n')
		if i < 0 {
			return
		}
		rest = rest[i + 1:]
	}
}

// The data read past: under -n, where only `input` reads, freed unless a value read may lie in it (see `next_input`).
// Otherwise it is kept for `free_spent`.
@(private = "file")
retire :: proc(ins: ^Inputs, data: []byte) {
	switch {
	case data == nil:
	case ins.run.opts.null_input && !ins.pinned:
		free_data({data, ins.mapped})
	case:
		append(&ins.spent, Spent{data, ins.mapped})
	}
	ins.pinned = false
}

// Whether the text at data[at:], which the library did not read, may run on past the window into what the
// stream has yet to bring: then the window is read on, from the line the text starts on, until the text
// ends or the stream does, and the text is to be read again from `ins.pos`.
read_on :: proc(ins: ^Inputs, at: int) -> bool {
	at := at
	if !unfinished(ins, at) {
		return false
	}
	for {
		from := max(bytes.last_index_byte(ins.data[:at], '\n') + 1, ins.skip) // a byte order mark stays behind
		next_window(ins, from, 2 * (len(ins.data) - from))
		at -= from
		if !unfinished(ins, at) {
			break
		}
	}
	ins.pos = at
	return true
}

// Whether the text at data[at:] is cut short by the window's end, with more of the stream to come. Under
// --seq a record runs to the next separator, so one with none after it in the window is cut short.
@(private = "file")
unfinished :: proc(ins: ^Inputs, at: int) -> bool {
	if ins.reader == nil || ins.run.opts.from == .Ndjson {
		return false
	}
	if ins.run.opts.seq {
		return bytes.index_byte(ins.data[at:], RS) < 0
	}
	e, bad := json.validate(ins.data[at:], ins.run.req.dialect, limits = ins.run.req.limits).?
	return bad && e.kind == .Truncated
}

// Free the files read past, once no value read from them is left.
free_spent :: proc(ins: ^Inputs) {
	for d in ins.spent {
		free_data(d)
	}
	clear(&ins.spent)
}

// A file's data read past, and whether it is the file's mapping.
Spent :: struct {
	data:   []byte,
	mapped: bool,
}

free_data :: proc(d: Spent) {
	if d.mapped {
		unmap_file(d.data)
	} else {
		delete(d.data, runtime.heap_allocator())
	}
}

// Open the next file as jq opens one, stdin for "-", which names it and starts its line count even when it does not
// open. A file that does not open is reported as jq reports it.
open_file :: proc(ins: ^Inputs) -> (file: ^os.File, ok: bool) {
	f := ins.files[ins.next_file]
	ins.next_file += 1
	ins.line = 0
	if f == "-" {
		ins.name = "<stdin>"
		return os.stdin, true
	}
	ins.name = f
	err: os.Error
	if file, err = os.open(f); err != nil {
		fmt.eprintf("stury: error: Could not open file %s: %s\n", f, strerror(err))
		ins.failures += 1
		ins.run.unopened = true
		return nil, false
	}
	return file, true
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

close_file :: proc(f: ^os.File) {
	if f != nil && f != os.stdin {
		os.close(f)
	}
}

read_failed :: proc(ins: ^Inputs, err: os.Error) {
	fmt.eprintf("stury: error: %s\n", strerror(err))
	ins.failures += 1
	ins.run.unopened = true
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

// The byte jq reads last to finish the value of data[at:end]: an array's, object's or string's last byte, or
// the byte after a literal.
last_read :: proc(data: []byte, at, end: int) -> int {
	e := end
	for e > at && jq.is_space(data[e - 1]) {
		e -= 1
	}
	if c := data[e - 1]; c == ']' || c == '}' || c == '"' {
		return e - 1
	}
	return e
}

// A byte of a literal: none of space, a quote and structure.
is_literal_byte :: proc(c: byte) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '"', '[', ',', ']', '{', ':', '}':
		return false
	}
	return true
}

// Where the piece of the open file holding byte `at` ends, and jq's current_line once it has read it: the
// pieces through it that end a line. Past the end, all of them.
fgets_lines :: proc(ins: ^Inputs, at: int) -> (end, count: int) {
	c := &ins.lines
	if at < c.start {
		c^ = {}
	}
	for c.end < len(ins.data) && c.end <= at {
		n, newline := next_piece(ins.data[c.end:])
		c.start = c.end
		c.end += n
		c.count += int(newline)
	}
	return c.end, ins.lines_before + c.count
}

// The piece of `left` jq's fgets reads next, and whether it ends a line: through the first newline within FGETS_MAX
// bytes, else FGETS_MAX bytes and what finishes a UTF-8 sequence they cut, newline or not. At the end of the file,
// the rest.
next_piece :: proc(left: []byte) -> (n: int, newline: bool) {
	window := left[:min(len(left), FGETS_MAX)]
	if i := bytes.index_byte(window, '\n'); i >= 0 {
		return i + 1, true
	}
	if len(window) < FGETS_MAX {
		return len(window), false
	}
	return FGETS_MAX + min(utf8_missing(window), len(left) - FGETS_MAX), false
}

// How many bytes of the UTF-8 sequence `piece` ends partway through are still to come (jvp_utf8_backtrack).
utf8_missing :: proc(piece: []byte) -> int {
	i := len(piece) - 1
	for i >= 0 && piece[i] & 0xc0 == 0x80 {
		i -= 1
	}
	if i < 0 {
		return 0
	}
	return max(jq.utf8_length(piece[i]) - (len(piece) - i), 0)
}
