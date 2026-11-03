package main

// The formats `--from` reads and `--to` writes, one row of FORMATS each, and the options a format refuses.

import "core:strings"
import "message"

Format :: enum u8 {
	Json,
	Jsonc,
	Json5, // read only: --to jsonc writes its values and comments
	Ndjson,
	Csv,
	Tsv,
}

Format_Spec :: struct {
	name:       string,
	// A delimited format: the first record is the header, and each later record is an object keyed by it.
	cells:      bool,
	// Each line is one text.
	lines:      bool,
	// The format keeps the comments read with a value.
	comments:   bool,
	// The format a read-only format is written as, by default and by `--to`. Such a format is not itself written.
	written_as: Maybe(Format),
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json"},
	.Jsonc  = {name = "jsonc", comments = true},
	.Json5  = {name = "json5", comments = true, written_as = .Jsonc},
	.Ndjson = {name = "ndjson", lines = true},
	.Csv    = {name = "csv", cells = true},
	.Tsv    = {name = "tsv", cells = true},
}

format_named :: proc(name: string) -> (f: Format, ok: bool) {
	for spec, k in FORMATS {
		if spec.name == name {
			return k, true
		}
	}
	return
}

// Returns the comma-separated format names for `--from` and `--to` messages: a read-only format is not written.
format_names :: proc(writing: bool) -> string {
	b := make([dynamic]byte, context.temp_allocator)
	for spec, k in FORMATS {
		if writing && spec.written_as != nil {
			continue
		}
		if k != .Json {
			append(&b, ", ")
		}
		append(&b, spec.name)
	}
	return string(b[:])
}

// Reports whether the input format is a delimited one.
reads_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.from].cells
}

// Reports whether the output format is a delimited one.
writes_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].cells
}

// Reports whether each line of the input is one text.
reads_lines :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.from].lines
}

// Reports whether each output is written on a line of its own.
writes_lines :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].lines
}

// Reports whether the outputs, written, keep the comments read with their values.
writes_comments :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].comments
}

// Refuses options that conflict with the chosen formats. A non-JSON input format splits the input itself, so -R,
// --seq and --stream do not apply. A delimited output writes no JSON text, so JSON layout options do not apply.
refuse_format_clashes :: proc(o: ^Opts, cli: ^Cli) {
	from, to := FORMATS[o.from].name, FORMATS[o.to].name
	if o.from != .Json {
		other := "--seq" if o.seq else "-R" if o.raw_input else "--stream" if o.stream && !reads_lines(o) else ""
		if other != "" {
			usage_error("--from %s cannot be combined with %s", from, other)
		}
	}
	if o.to != .Json {
		if cli.validating {
			usage_error("check writes nothing: --to %s has no use there", to)
		}
		other := cli.json_flag if writes_cells(o) else "--seq" if o.seq else cli.layout_flag if writes_lines(o) else ""
		if other != "" {
			usage_error("%s cannot be combined with --to %s", other, to)
		}
	}
	if o.grow_header && !writes_cells(o) {
		usage_error("--grow-header applies to --to csv or tsv")
	}
}

// What `check` says an input with nothing in it lacks: "No JSON text", "No CSV text".
no_text :: proc(o: ^Opts) -> string {
	return message.build_temp("No %s text", "JSON" if !reads_cells(o) else strings.to_upper(FORMATS[o.from].name, context.temp_allocator))
}
