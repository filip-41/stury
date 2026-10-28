package main

// Values and programs the command line names: a JSON text given to an option, a file loaded as jq's jv_load_file
// loads it, and the filter file of -f.

import "core:os"
import "core:strings"
import core_pkg "../../core"
import json "../../json"
import "jq"
import "message"

// A JSON text given to `option` on the command line: exactly one value.
json_arg :: proc(text, option: string) -> jq.Value {
	v, err := jq.read_text(transmute([]byte)text)
	if e, bad := err.?; bad {
		usage_error("invalid JSON text passed to %s: %s", option, jq.parse_message(transmute([]byte)text, e))
	}
	return v
}

// jq's jv_load_file: file `path` as one string (`raw`) or as the array of its JSON texts, or jq's message
// for why not.
load_file :: proc(path: string, raw: bool) -> (v: jq.Value, msg: string) {
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
	all := jq.new_array()
	// Positions count from past a byte order mark, as the input reader counts them.
	start := core_pkg.bom_len(data)
	jsonc := json.grammar_of(jq.read_dialect) != {}
	texts := json.records(data, {framing = .Concatenated})
	for {
		text, ok := json.next_record_open(&texts)
		if !ok {
			e, framed := texts.err.?
			if !framed {
				return all, ""
			}
			text = {bytes = data[e.offset:][:1], at = e.offset} // a byte order mark past the start: a text of its own
		}
		if jsonc { // one document per input, as for the files
			text.bytes = data[text.at:]
		} else if ended, _ := json.end_record(&texts, json.validate(text.bytes, {dialect = jq.read_dialect, limits = jq.lifted})); ended.bytes != nil {
			text = ended // an array, object or string, ended where its read stops
		}
		x, err := jq.read_text(text.bytes)
		if e, bad := err.?; bad {
			line, column := 1, 0
			jq.advance(&line, &column, data[start:text.at])
			return nil, jq.parse_message(data[text.at:], e, line, column)
		}
		append(&all.items, x)
		if jsonc {
			return all, ""
		}
	}
}

// -f: the filter in file `path` as jq loads it, or jq's message and exit 2. The file's directory is where
// `get_prog_origin` says the filter came from.
program_file :: proc(run: ^Run, path: string) -> string {
	v, msg := load_file(path, true)
	if msg != "" {
		message.write_stderr("stury: %s\n", msg)
		os.exit(EXIT_USAGE)
	}
	text, _ := jq.string_of(v)
	if strings.index_byte(text, 0) >= 0 {
		message.write_stderr("stury: program file contains NUL bytes\n")
		os.exit(EXIT_USAGE)
	}
	run.ip.prog_origin = jq.real_path(jq.dir_name(path))
	return text
}
