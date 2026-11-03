package main

// Reading the files and stdin a run names.

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/posix"
import core "../../core"
import json "../../json"
import "jq"
import "message"

@(rodata)
STDIN_ONLY := []string{"-"}

// The inputs a run reads: each file one JSON text, read whole.
Inputs :: struct {
	reading:   core.As,
	files:     []string, // "-" is stdin
	next_file: int,
	name:      string, // the file opened last, "" before the first
	line:      int, // the lines of it jq's parser has read
	line_end:  int, // --stream: the byte after the newline `line` counts last
	failures:  int, // files that did not open or read
	has_text:  bool, // a file before this one held a text, so a byte order mark opening this one is no mark
	slurp:     bool,
	run:       ^Run, // under the path scan, a text it answers is printed and passed over
	// --stream: the open file's text, and its events while some are left: a document's, or those jq's parser makes of
	// the bytes before a fault, which plain --stream ends with the fault's message
	data:        []byte,
	events:      ^jq.Events,
	walk:        ^Fault_Walk,
	walk_spare:  ^Fault_Walk, // a walk that has ended, whose memory the next one takes
	fault_error: string,
	note:        string, // what the parse error that ends the run adds on the lines after it
}

// jq's next_input: the next value, or under -s every value as one array once the files are read, or a parse error as
// soon as there is one. A --stream-errors error that jq gives after the event the text's last byte left pending comes
// after the array.
next_input :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	if !ins.slurp {
		return next_value(ins)
	}
	all := jq.new_array()
	read: for {
		if ins.walk != nil && ins.fault_error == "" {
			if ev, more := fault_peek(ins.walk); more && ev.late {
				break
			}
		}
		v, msg, status := next_value(ins)
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

// The next file's text, or under --stream its next event, passing over a file that does not open or holds only space.
@(private = "file")
next_value :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	if ins.events != nil {
		if v, more := jq.next_event(ins.events); more {
			lines_through(ins, jq.event_trigger(ins.events))
			return v, "", .Value
		}
		ins.events = nil
	}
	if ins.walk != nil {
		ev, more := fault_event(ins.walk)
		if more && (ins.fault_error == "" || !ev.error && ev.at < len(ins.walk.p.src)) {
			lines_through(ins, ev.at)
			return ev.value, "", .Value
		}
		msg := ins.fault_error
		ins.walk, ins.walk_spare, ins.fault_error = nil, ins.walk, ""
		if msg != "" {
			return nil, msg, .Error
		}
	}
	stream := ins.run.opts.stream
	for ins.next_file < len(ins.files) {
		data, ok := read_next_file(ins)
		if !ok || blank(data, json.Spec(ins.reading.spec)) {
			continue
		}
		stray_bom := ins.has_text && bytes.has_prefix(data, {0xef, 0xbb, 0xbf})
		ins.has_text = true
		if ins.run.route.scanning && !stray_bom && answer_path(ins.run, data, ins.reading) {
			continue
		}
		if k := cut_bom_len(data); ins.run.opts.stream_errors && ins.next_file == 1 && k > 0 {
			// jq's parser drops the bytes of the mark it matched, and refuses the stream whole when more follow.
			if k == len(data) {
				continue
			}
			return nil, "Malformed BOM", .Error
		}
		// --stream's document lives until its last event, past the memory of the input that reads it.
		doc: core.Document
		fault: Maybe(core.Fault)
		if stray_bom {
			fault = core.Fault{kind = .Bad_Char}
		} else {
			doc, fault = jq.build_text(data, ins.reading, runtime.heap_allocator() if stream else context.allocator)
		}
		ins.data = data
		if f, bad := fault.?; bad {
			if json.Spec(ins.reading.spec) != .Json {
				fail_dialect(ins, data, f)
			}
			ins.note = fault_note(data, f, ins)
			if !stream {
				ins.line = lines_read(data, int(f.at) + 1)
				return nil, jq.parse_message(data, f), .Error
			}
			// jq's parser gives the events of the bytes before the fault, and with --stream-errors the fault as one.
			if !ins.run.opts.stream_errors {
				data = data[:min(int(f.at), len(data))]
				ins.fault_error = strings.clone(jq.parse_message(ins.data, f), runtime.heap_allocator())
			}
			ins.walk = fault_walk(data, 1, 0, false, false, false, ins.walk_spare)
			return next_value(ins)
		}
		if stream {
			ins.events = jq.events_start(doc)
			return next_value(ins)
		}
		ins.line = lines_read(data, int(doc.nodes[0].lo) + len(core.span(&doc, core.ROOT)))
		return jq.document_value(doc), "", .Value
	}
	return nil, "", .More
}

// The next file whole, in the memory of the input that reads it, which is emptied with it, but for --stream, whose
// events outlive it. A file that does not open or read is told as jq tells it and counted.
@(private = "file")
read_next_file :: proc(ins: ^Inputs) -> (data: []byte, ok: bool) {
	path := ins.files[ins.next_file]
	ins.next_file += 1
	ins.name, ins.line, ins.line_end = "<stdin>" if path == "-" else path, 0, 0
	f := os.stdin
	if path != "-" {
		err: os.Error
		if f, err = open_input(path); err != nil {
			message.write_stderr("stury: error: Could not open file %s: %s\n", path, strerror(err))
			ins.failures += 1
			return
		}
	}
	defer if f != os.stdin {
		os.close(f)
	}
	err: os.Error
	if data, err = read_whole(f, runtime.heap_allocator() if ins.run.opts.stream else context.allocator); err != nil {
		message.write_stderr("stury: error: %s\n", strerror(err))
		ins.failures += 1
		return
	}
	ins.run.route.input += len(data)
	return data, true
}

// The lines jq's parser has read of `data` once its text ends at `end`: up to the end of the line holding the text's
// last byte, as fgets reads a line whole.
@(private = "file")
lines_read :: proc(data: []byte, end: int) -> int {
	stop := max(end - 1, 0)
	for stop < len(data) && data[stop] != '\n' {
		stop += 1
	}
	return bytes.count(data[:min(stop + 1, len(data))], {'\n'})
}

// `ins.line` once jq's parser has read the open file's text to byte `at`, counted on from the call before, as --stream's
// events read on through the text.
@(private = "file")
lines_through :: proc(ins: ^Inputs, at: int) {
	if at < ins.line_end {
		return
	}
	nl := bytes.index_byte(ins.data[at:], '\n')
	stop := len(ins.data) if nl < 0 else at + nl + 1
	ins.line += bytes.count(ins.data[ins.line_end:stop], {'\n'})
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

// A JSONC or JSON5 text the library refuses, told as `NAME:LINE:COLUMN: SENTENCE`, with the line and a caret under the
// byte when `--max-depth` cures it. Ends the run.
@(private = "file")
fail_dialect :: proc(ins: ^Inputs, data: []byte, f: core.Fault) -> ! {
	run := ins.run
	flush_some(run, force = true)
	if f.kind in core.AT_NO_BYTE {
		message.write_stderr("stury: error: %s: %s\n", ins.name, jq.fault_sentence(f, ""))
		finish(run, EXIT_INPUT)
	}
	line, col := core.locate(data, f.at)
	rest := string(data[f.at:])
	sentence := jq.fault_sentence(f, rest)
	// JSON5 spells them, JSON has no value for them, and the library refuses them as a literal.
	unsigned := strings.trim_left(rest, "+-")
	if json.Spec(ins.reading.spec) == .Json5 && f.kind == .Bad_Char && (strings.has_prefix(unsigned, "Infinity") || strings.has_prefix(unsigned, "NaN")) {
		sentence = "Infinity and NaN have no JSON value"
	}
	message.write_stderr("stury: error: %s:%d:%d: %s\n", ins.name, line, col, sentence)
	message.write_stderr("%s", fault_note(data, f, ins))
	finish(run, EXIT_INPUT)
}

// For the faults whose cure is a flag of stury's own, the line of `data` the fault `f` is at, a caret under its byte,
// and the flag, else "". A trailing comma and a comment are JSONC's, and a nesting past the cap is raised by
// --max-depth, which the hint asks for only when it was not given. The text ends in a newline.
fault_note :: proc(data: []byte, f: core.Fault, ins: ^Inputs) -> string {
	at := int(f.at)
	hint: string
	switch {
	case f.kind == .Too_Deep:
		hint = "a larger --max-depth reads it" if ins.run.opts.max_depth != 0 else "--max-depth N raises the nesting limit"
	case f.kind != .Bad_Char || at >= len(data) || json.Spec(ins.reading.spec) != .Json:
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
			return next_input((^Inputs)(data))
		},
		position = proc(data: rawptr) -> (string, int) {
			ins := (^Inputs)(data)
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
