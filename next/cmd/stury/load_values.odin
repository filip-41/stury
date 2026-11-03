package main

// Values and programs the command line names: a JSON text given to an option, a file loaded as jq's jv_load_file
// loads it, and the filter file of -f.

import "core:os"
import "core:strings"
import core "../../core"
import records "../../core/records"
import "jq"
import "message"

// A JSON text given to `option` on the command line, read as `r` says: exactly one value.
json_arg :: proc(r: core.As, text, option: string) -> jq.Value {
	v, fault := jq.read_text(transmute([]byte)text, r)
	if f, bad := fault.?; bad {
		usage_error("invalid JSON text passed to %s: %s", option, jq.parse_message(transmute([]byte)text, f))
	}
	return v
}

// jq's jv_load_file: file `path` as one string (`raw`) or as the array of its JSON text, read as `r` says, or jq's
// message for why not.
load_file :: proc(path: string, raw: bool, r: core.As) -> (v: jq.Value, msg: string) {
	f, err := open_input(path)
	if err != nil {
		return nil, message.build_temp("Could not open %s: %s", path, strerror(err))
	}
	defer os.close(f)
	if fi, ferr := os.fstat(f, context.temp_allocator); ferr != nil || fi.type == .Directory {
		return nil, message.build_temp("Could not open %s: It's a directory", path)
	}
	data, rerr := read_whole(f, context.allocator)
	if rerr != nil {
		return nil, message.build_temp("Error reading from %s", path)
	}
	if raw {
		return jq.valid_utf8(string(data)), ""
	}
	// Every text of the file, as jq reads its input.
	all := jq.new_array()
	texts := records.open(data, r, .Concatenated)
	defer records.close(&texts)
	for {
		rec, more := records.next(&texts)
		if !more {
			break
		}
		fault := runs_on(data, rec, r)
		doc: core.Document
		if fault == nil {
			built, err := records.build(&texts, rec)
			doc, fault = jq.judge_build(built, err, rec.at)
		}
		if f, bad := fault.?; bad {
			return nil, jq.parse_message(data, f)
		}
		append(&all.items, jq.document_value(doc))
	}
	if f, bad := texts.fault.?; bad {
		return nil, jq.parse_message(data, f)
	}
	return all, ""
}

// -f: the filter in file `path` as jq loads it, or jq's message and exit 2. The file's directory is where
// `get_prog_origin` says the filter came from.
program_file :: proc(ip: ^jq.Interp, path: string) -> string {
	v, msg := load_file(path, true, {})
	if msg != "" {
		message.write_stderr("stury: %s\n", msg)
		os.exit(EXIT_USAGE)
	}
	text, _ := jq.string_of(v)
	if strings.index_byte(text, 0) >= 0 {
		message.write_stderr("stury: program file contains NUL bytes\n")
		os.exit(EXIT_USAGE)
	}
	ip.prog_origin = jq.real_path(jq.dir_name(path))
	return text
}
