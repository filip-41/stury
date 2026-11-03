package main

// Values the command line names: a JSON text given to an option, and a file loaded as jq's jv_load_file loads it.

import "core:os"
import core "../../core"
import json "../../json"
import "message"

// A JSON text given to `option` on the command line: exactly one value.
json_arg :: proc(text, option: string) -> string {
	if f, bad := json.validate(transmute([]byte)text, .Json).?; bad {
		usage_error("invalid JSON text passed to %s: %s", option, core.rule_of(f).message)
	}
	return text
}

// jq's jv_load_file: file `path` whole, or jq's message for why not.
load_file :: proc(path: string, raw: bool) -> (text: string, msg: string) {
	f, err := open_input(path)
	if err != nil {
		return "", message.build_temp("Could not open %s: %s", path, strerror(err))
	}
	defer os.close(f)
	if fi, ferr := os.fstat(f, context.temp_allocator); ferr != nil || fi.type == .Directory {
		return "", message.build_temp("Could not open %s: It's a directory", path)
	}
	data, rerr := read_whole(f, context.allocator)
	if rerr != nil {
		return "", message.build_temp("Error reading from %s", path)
	}
	return string(data), ""
}
