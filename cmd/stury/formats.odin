package main

// The formats `--from` reads and `--to` writes. Adding a format takes one row of FORMATS, one case in input.odin
// (splitting the input into texts) and one in print.odin or output_cells.odin (writing the outputs).

import csv "../../csv"

Format :: enum u8 {
	Json,
	Jsonc,
	Ndjson,
	Csv,
	Tsv,
}

Format_Spec :: struct {
	name:    string,
	// A CSV-like format: the first record is the header, and each later record is an object keyed by it.
	cells:   bool,
	dialect: csv.Dialect, // for a format with `cells`
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json"},
	.Jsonc  = {name = "jsonc"},
	.Ndjson = {name = "ndjson"},
	.Csv    = {name = "csv", cells = true},
	.Tsv    = {name = "tsv", cells = true, dialect = csv.TSV},
}

format_named :: proc(name: string) -> (f: Format, ok: bool) {
	for spec, k in FORMATS {
		if spec.name == name {
			return k, true
		}
	}
	return
}

// Returns the comma-separated format names for `--from` and `--to` messages.
format_names :: proc() -> string {
	b := make([dynamic]byte, context.temp_allocator)
	for spec, k in FORMATS {
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
