package main

// Reading the files and stdin a run names.

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:os"
import "core:sys/posix"
import core "../../core"
import "jq"
import "message"

@(rodata)
STDIN_ONLY := []string{"-"}

// The inputs a run reads: each file one JSON text, read whole.
Inputs :: struct {
	reading:   jq.Reading,
	files:     []string, // "-" is stdin
	next_file: int,
	name:      string, // the file opened last, "" before the first
	line:      int, // the lines of it jq's parser has read
	failures:  int, // files that did not open or read
	slurp:     bool,
}

// jq's next_input: the next value, or under -s every value as one array once the files are read, or a parse error as
// soon as there is one.
next_input :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	if !ins.slurp {
		return next_value(ins)
	}
	all := jq.new_array()
	for {
		v, msg, status := next_value(ins)
		switch status {
		case .Error:
			return nil, msg, .Error
		case .Value:
			append(&all.items, v)
		case .More:
			ins.slurp = false
			return all, "", .Value
		}
	}
}

// The next file's text, passing over a file that does not open or holds only space.
@(private = "file")
next_value :: proc(ins: ^Inputs) -> (jq.Value, string, jq.Parse_Status) {
	for ins.next_file < len(ins.files) {
		data, ok := read_next_file(ins)
		if !ok || blank(data) {
			continue
		}
		doc, fault := jq.build_text(data, ins.reading)
		if f, bad := fault.?; bad {
			return nil, jq.parse_message(data, f), .Error
		}
		ins.line = lines_read(data, int(doc.nodes[0].lo) + len(core.span(&doc, core.ROOT)))
		return jq.document_value(doc), "", .Value
	}
	return nil, "", .More
}

// The next file whole, from the heap, since the values read from it may outlive any input's memory. A file that does
// not open or read is told as jq tells it and counted.
@(private = "file")
read_next_file :: proc(ins: ^Inputs) -> (data: []byte, ok: bool) {
	path := ins.files[ins.next_file]
	ins.next_file += 1
	ins.name, ins.line = "<stdin>" if path == "-" else path, 0
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
	// Every file read stays on the heap until the run ends, since a value may point into any of them.
	if data, err = read_whole(f, runtime.heap_allocator()); err != nil {
		message.write_stderr("stury: error: %s\n", strerror(err))
		ins.failures += 1
		return
	}
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

// Whether `data` holds no text: only space, after a byte order mark.
blank :: proc(data: []byte) -> bool {
	data := data
	if len(data) >= 3 && data[0] == 0xef && data[1] == 0xbb && data[2] == 0xbf {
		data = data[3:]
	}
	for c in data {
		if !jq.is_space(c) {
			return false
		}
	}
	return true
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

// The name of the input whose file is mapped, which the fault handler reports when the file shrinks under its mapping.
mapped_input_name: string

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
