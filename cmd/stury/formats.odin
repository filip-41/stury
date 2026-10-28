package main

// The formats `--from` reads and `--to` writes. A format is one row of FORMATS, named as the library's format
// variant that reads and writes it: the variant's options block, which holds the dialect and the framing, and
// what the CLI does with the format. The CLI calls the library's typed procedures. print.odin and
// output_cells.odin write the outputs.

import csv "../../csv"
import "core:strings"
import json "../../json"
import "message"

Format :: enum u8 {
	Json,
	Jsonc,
	Json5, // read only: --to jsonc writes its values and comments
	Ndjson,
	Csv,
	Tsv,
}

// A format's options block: the own block of its variant, a JSON variant's or a CSV variant's (the other is zero).
Format_Opts :: struct {
	json: json.Record_Opts,
	csv:  csv.Read_Opts,
}

Format_Spec :: struct {
	// The library variant's name.
	name:       string,
	// The variant's options block as its preset fills it.
	opts:       Format_Opts,
	// A CSV variant: the first record is the header, and each later record is an object keyed by it.
	cells:      bool,
	// The format a read-only format is written as, by default and by `--to`. Such a format is not itself written.
	written_as: Maybe(Format),
	// Chooses who answers the filter on an input of the format (`Run.scanning`, `Run.columns`).
	route:      proc(run: ^Run, text: string, files: int),
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json", route = choose_scan},
	.Jsonc  = {name = "jsonc", opts = {json = {dialect = .Jsonc}}, route = choose_scan},
	.Json5  = {name = "json5", opts = {json = {dialect = .Json5}}, written_as = .Jsonc, route = choose_scan},
	.Ndjson = {name = "ndjson", opts = {json = {framing = .NDJSON}}, route = choose_scan},
	.Csv    = {name = "csv", opts = {csv = {}}, cells = true, route = choose_columns},
	.Tsv    = {name = "tsv", opts = {csv = {dialect = csv.TSV}}, cells = true, route = choose_columns},
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

// Sets `o.from` and `o.to`, with their options blocks.
set_formats :: proc(o: ^Opts, from, to: Format) {
	o.from, o.to = from, to
	o.from_opts, o.to_opts = FORMATS[from].opts, FORMATS[to].opts
}

// Reports whether the input format is CSV-like.
reads_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.from].cells
}

// Reports whether the output format is CSV-like.
writes_cells :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].cells
}

// The grammar a JSON-like input is spelled in, JSON for a CSV-like one.
source_dialect :: #force_inline proc(o: ^Opts) -> json.Dialect {
	return .Json if reads_cells(o) else o.from_opts.json.dialect
}

// Reports whether each line of the input is one text.
reads_lines :: #force_inline proc(o: ^Opts) -> bool {
	return !reads_cells(o) && o.from_opts.json.framing == .NDJSON
}

// Reports whether each output is written on a line of its own.
writes_lines :: #force_inline proc(o: ^Opts) -> bool {
	return !writes_cells(o) && o.to_opts.json.framing == .NDJSON
}

// Reports whether the outputs, written, keep the comments read with their values.
writes_comments :: #force_inline proc(o: ^Opts) -> bool {
	return !writes_cells(o) && .Comments in json.grammar_of(o.to_opts.json.dialect)
}

// The dialect of a CSV-like input.
cells_in :: #force_inline proc(o: ^Opts) -> csv.Dialect {
	return o.from_opts.csv.dialect
}

// The dialect of a CSV-like output.
cells_out :: #force_inline proc(o: ^Opts) -> csv.Dialect {
	return o.to_opts.csv.dialect
}

// Refuses options that conflict with the chosen formats. A non-JSON input format splits the input itself, so -R,
// --seq and --stream do not apply. A CSV-like output writes no JSON text, so JSON layout options do not apply.
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
