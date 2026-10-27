package main

// The formats `--from` reads and `--to` writes. A format is one row of FORMATS: its grammar, how its input is cut
// into texts, whether it is cells, and who answers a filter on it. print.odin and output_cells.odin write the
// outputs.

import csv "../../csv"
import json "../../json"

Format :: enum u8 {
	Json,
	Jsonc,
	Json5, // read only: --to jsonc writes its values and comments
	Ndjson,
	Csv,
	Tsv,
}

// How a JSON-like format's input is cut into texts: one after another as jq reads them, one a line, or the whole
// input one document.
Framing :: enum u8 {
	Texts,
	Lines,
	Whole,
}

Format_Spec :: struct {
	name:    string,
	// The grammar the text is spelled in, for a JSON-like format.
	source:  json.Dialect,
	framing: Framing,
	// The format a read-only format is written as, by default and by `--to`. Such a format is not itself written.
	written_as: Maybe(Format),
	// Written, its values keep the comments read with them.
	keeps_comments: bool,
	// A CSV-like format: the first record is the header, and each later record is an object keyed by it.
	cells:   bool,
	dialect: csv.Dialect, // for a format with `cells`
	// Chooses who answers the filter on an input of the format (`Run.scanning`, `Run.columns`).
	route:   proc(run: ^Run, text: string, files: int),
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json", route = choose_scan},
	.Jsonc  = {name = "jsonc", source = .Jsonc, framing = .Whole, keeps_comments = true, route = choose_scan},
	.Json5  = {name = "json5", source = .Json5, framing = .Whole, written_as = .Jsonc, route = choose_scan},
	.Ndjson = {name = "ndjson", framing = .Lines, route = choose_scan},
	.Csv    = {name = "csv", cells = true, route = choose_columns},
	.Tsv    = {name = "tsv", cells = true, dialect = csv.TSV, route = choose_columns},
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

// Reports whether the input format is CSV-like.
reads_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.from].cells
}

// Reports whether the output format is CSV-like.
writes_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].cells
}

// Refuses options that conflict with the chosen formats. A non-JSON input format splits the input itself, so -R,
// --seq and --stream do not apply. A CSV-like output writes no JSON text, so JSON layout options do not apply.
refuse_format_clashes :: proc(o: ^Opts, cli: ^Cli) {
	from, to := FORMATS[o.from].name, FORMATS[o.to].name
	if o.from != .Json {
		other := "--seq" if o.seq else "-R" if o.raw_input else "--stream" if o.stream && o.from != .Ndjson else ""
		if other != "" {
			usage_error("--from %s cannot be combined with %s", from, other)
		}
	}
	if o.to != .Json {
		if cli.validating {
			usage_error("check writes nothing: --to %s has no use there", to)
		}
		other := cli.json_flag if writes_cells(o) else "--seq" if o.seq else cli.layout_flag if o.to == .Ndjson else ""
		if other != "" {
			usage_error("%s cannot be combined with --to %s", other, to)
		}
	}
	if o.grow_header && !writes_cells(o) {
		usage_error("--grow-header applies to --to csv or tsv")
	}
}
