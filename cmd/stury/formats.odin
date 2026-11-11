package main

// The formats `--from` reads and `--to` writes, one row of FORMATS each, and the options a format refuses.

import core "../../core"
import dsv "../../dsv"
import json "../../json"

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
	// The spec its JSON texts are read in: `--argjson`, `fromjson` and a JSON-like format's input.
	spec:       json.Spec,
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json"},
	.Jsonc  = {name = "jsonc", comments = true, spec = .Jsonc},
	.Json5  = {name = "json5", comments = true, written_as = .Jsonc, spec = .Json5},
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

// How the inputs are read, as --from, --seq and the CSV options say. A JSON-like format's texts are read as `json_reading` reads them.
input_source :: proc(o: ^Opts, json_reading: core.As) -> Source {
	if reads_cells(o) {
		return {as = dsv.as(cells_spec(o.from), o.cells_in), framing = .Lines}
	}
	return {as = json_reading, framing = .Seq if o.seq else .Lines if reads_lines(o) else .Concatenated, spec = json.Spec(json_reading.spec)}
}

// How the delimited outputs are written, as --to and the CSV options say.
cells_written_as :: proc(o: ^Opts) -> core.As {
	return dsv.as(cells_spec(o.to), o.cells_out)
}

@(private = "file")
cells_spec :: #force_inline proc(f: Format) -> dsv.Spec {
	return .Csv if f == .Csv else .Tsv
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
	// schema sample takes --infer for a table it writes, whose cells it draws as --infer reads them.
	if cli.cells_flag != "" && !reads_cells(o) && !(cli.schema_verb && cli.cells_flag == "--infer" && writes_cells(o)) {
		usage_error("%s applies to --from csv or tsv", cli.cells_flag)
	}
	// check and edit refuse the options that write a table as options they have no use for.
	if cli.cells_out_flag != "" && !writes_cells(o) && !cli.validating && !cli.editing {
		usage_error("%s applies to --to csv or tsv", cli.cells_out_flag)
	}
	if reads_cells(o) {
		refuse_cell_bytes(cells_spec(o.from), o.cells_in, from, "--delimiter", "--comment")
	}
	if writes_cells(o) {
		refuse_cell_bytes(cells_spec(o.to), o.cells_out, to, "--out-delimiter" if cli.out_delimiter != nil else "--delimiter", "--out-comment" if cli.out_comment != nil else "--comment")
	}
}

// Refuses a delimiter or comment character that `format` cannot read, as the library's walk refuses it.
@(private = "file")
refuse_cell_bytes :: proc(spec: dsv.Spec, opts: dsv.Options, format, delimiter_flag, comment_flag: string) {
	if core.validate(nil, dsv.as(spec, {delimiter = opts.delimiter})) != nil {
		usage_error("%s %q is not a byte %s can separate cells with", delimiter_flag, string([]byte{opts.delimiter}), format)
	}
	if core.validate(nil, dsv.as(spec, opts)) != nil {
		usage_error("%s %q is not a byte %s can start a comment line with", comment_flag, string([]byte{opts.comment}), format)
	}
}
