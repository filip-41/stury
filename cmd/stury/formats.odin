package main

// The formats `--from` reads and `--to` writes. A format is one row of FORMATS and one case where the input is
// cut into texts (input.odin) and the outputs are written (print.odin, output_cells.odin).

import "core:fmt"
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
	// `--NAME` is `--from NAME --to NAME`.
	alias:   bool,
	// Records of cells: the first names the fields, and each later one is an object of them.
	cells:   bool,
	dialect: csv.Dialect, // of a format of cells
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json"},
	.Jsonc  = {name = "jsonc", alias = true},
	.Ndjson = {name = "ndjson", alias = true},
	.Csv    = {name = "csv", alias = true, cells = true},
	.Tsv    = {name = "tsv", alias = true, cells = true, dialect = csv.TSV},
}

// The format called `name`, by `--from` and `--to`.
format_named :: proc(name: string) -> (f: Format, ok: bool) {
	for spec, k in FORMATS {
		if spec.name == name {
			return k, true
		}
	}
	return
}

// The format that `--name` stands for, when it is an alias.
format_alias :: proc(name: string) -> (f: Format, ok: bool) {
	f, ok = format_named(name)
	return f, ok && FORMATS[f].alias
}

// The names of the formats, as `--from` and `--to` list them.
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

// Whether the input is records of cells.
reads_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.from].cells
}

// Whether the outputs are records of cells.
writes_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].cells
}

// Refuses the options that cannot go with the formats chosen: an input format cuts the input itself, and a
// format of cells writes no JSON text for the options that lay one out.
refuse_format_clashes :: proc(o: ^Opts, cli: ^Cli) {
	from, to := FORMATS[o.from].name, FORMATS[o.to].name
	if o.from != .Json {
		other := "--seq" if o.seq else "-R" if o.raw_input else "--stream" if o.stream && o.from != .Ndjson else ""
		if other != "" {
			usage_error("--from %s cannot be combined with %s", from, other)
		}
	}
	if o.to != .Json {
		if cli.validating && cli.formats.to != nil {
			usage_error("check writes nothing: --to %s has no use there", to)
		}
		other := cli.json_flag if writes_cells(o) else "--seq" if o.seq else cli.layout_flag if o.to == .Ndjson else ""
		if other != "" {
			// An alias chooses the output format without the person naming it.
			via_alias := fmt.tprintf(" (--%s sets both formats; --from %s alone writes JSON)", to, from)
			usage_error("%s cannot be combined with --to %s%s", other, to, via_alias if cli.formats.to == nil else "")
		}
	}
	if o.grow_header && !writes_cells(o) {
		usage_error("--grow-header applies to --to csv or tsv")
	}
}
