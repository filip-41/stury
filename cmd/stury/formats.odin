package main

// The formats `--from` reads and `--to` writes, one row of FORMATS each, and the options a format refuses.

import core "../../core"
import dsv "../../dsv"
import json "../../json"
import yaml "../../yaml"

Format :: enum u8 {
	Json,
	Jsonc,
	Json5, // read only: --to jsonc writes its values and comments
	Ndjson,
	Csv,
	Tsv,
	Yaml,
}

Format_Spec :: struct {
	name:       string,
	// What --explain calls the format.
	title:      string,
	// A delimited format: the first record is the header, and each later record is an object keyed by it.
	cells:      bool,
	// How the format's texts are split in an input, and nil for a JSON-like format, whose inputs are concatenated
	// documents (`--seq` makes them RFC 7464 records).
	framing:    Maybe(core.Framing),
	// The format keeps the comments read with a value.
	comments:   bool,
	// The format a format that is only read is written as, by default and by `--to`. Such a format is not itself written.
	written_as: Maybe(Format),
	// The spec its JSON texts are read in: `--argjson`, `fromjson` and a JSON-like format's input.
	spec:       json.Spec,
	// A tree format that is not JSON: the handle a whole text of it is read with, as the options say, and nil for
	// every other. Its input is one document built whole, unless `follows` makes it a stream of them.
	whole_as:   proc "contextless" (o: ^Opts) -> core.As,
	// Whether the fault of a text read whole is of a text after its first, so that the input is read as the texts its
	// record reader cuts, one after another. Nil for a format whose input is one text.
	follows:    proc "contextless" (f: core.Fault) -> bool,
	// With `whole_as` and `follows`: whether a document that ends a window of a followed file is closed there, so that
	// no later line continues it. Nil for a format whose document ends where its record is cut.
	ended:      proc "contextless" (text: []byte) -> bool,
	// The handle `--to` writes each output with as a text of the format, through the format's document writer, which
	// takes a document of any format. Nil for a format written as JSON or as cells.
	written:    proc "contextless" (o: ^Opts) -> core.As,
	// With `written`: what stands between a text of a run and `text`, the next one, and nil for nothing.
	parted:     proc "contextless" (text: []u8) -> string,
	// With `written`: why the format's writer refused a value with `kind`, or "" for a kind it has no words for.
	refusal:    proc "contextless" (kind: core.Typed_Error_Kind) -> string,
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json", title = "JSON", follows = json_follows},
	.Jsonc  = {name = "jsonc", title = "JSON with comments", comments = true, spec = .Jsonc},
	.Json5  = {name = "json5", title = "JSON5", comments = true, written_as = .Jsonc, spec = .Json5},
	.Ndjson = {name = "ndjson", title = "NDJSON", framing = .Lines},
	.Csv    = {name = "csv", title = "CSV", cells = true, framing = .Lines},
	.Tsv    = {name = "tsv", title = "TSV", cells = true, framing = .Lines},
	.Yaml   = {name = "yaml", title = "YAML", framing = .Concatenated, whole_as = yaml_reading, follows = yaml_follows, ended = yaml_ended, written = yaml_written, parted = yaml_parted, refusal = yaml_refusal},
}

// A text after the first is the next text of strict JSON, where `validate` and a build, judging one, refuse it as
// trailing text.
@(private = "file")
json_follows :: proc "contextless" (f: core.Fault) -> bool {
	return f.rules == &json.RULES && f.detail == u8(json.Detail.Trailing)
}

// YAML 1.2 with the core schema. A `%YAML 1.1` directive reads with the same rules.
@(private = "file")
yaml_reading :: proc "contextless" (o: ^Opts) -> core.As {
	return yaml.as(.Yaml_1_2, {max_depth = o.max_depth, alias_limit = o.alias_limit, merge_keys = o.merge_keys})
}

// A YAML text holds a stream of documents: a whole build refuses a second document, and a text with none.
@(private = "file")
yaml_follows :: proc "contextless" (f: core.Fault) -> bool {
	return f.rules == &yaml.RULES && (f.detail == u8(yaml.Detail.Extra_Document) || f.detail == u8(yaml.Detail.No_Document))
}

// Whether YAML document `text` ends with its `...` line, which no line after it continues.
@(private = "file")
yaml_ended :: proc "contextless" (text: []byte) -> bool {
	end := len(text)
	end -= int(end > 0 && text[end - 1] == '\n')
	end -= int(end > 0 && text[end - 1] == '\r')
	line := end
	for line > 0 && text[line - 1] != '\n' {
		line -= 1
	}
	return end - line >= 3 && string(text[line:line + 3]) == "..." && (end - line == 3 || text[line + 3] == ' ' || text[line + 3] == '\t')
}

@(private = "file")
yaml_written :: proc "contextless" (o: ^Opts) -> core.As {
	return yaml.as(.Yaml_1_2, {max_depth = o.max_depth})
}

// A YAML text of a run starts its own document, as `---`, or as `...` before the directives of one that has them.
@(private = "file")
yaml_parted :: proc "contextless" (text: []u8) -> string {
	switch {
	case len(text) > 0 && text[0] == '%':
		return "...\n"
	case len(text) >= 3 && string(text[:3]) == "---":
		return ""
	}
	return "---\n"
}

@(private = "file")
yaml_refusal :: proc "contextless" (kind: core.Typed_Error_Kind) -> string {
	return "cannot write a text YAML has no spelling for" if kind == .Unwritable else ""
}

format_named :: proc(name: string) -> (f: Format, ok: bool) {
	for spec, k in FORMATS {
		if spec.name == name {
			return k, true
		}
	}
	return
}

// Returns the comma-separated format names for `--from` and `--to` messages: a format that is only read is not written.
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
	framing := FORMATS[o.from].framing.? or_else (core.Framing.Seq if o.seq else core.Framing.Concatenated)
	if whole_as := FORMATS[o.from].whole_as; whole_as != nil {
		return {as = whole_as(o), framing = framing, format = o.from}
	}
	if reads_cells(o) {
		return {as = dsv.as(cells_spec(o.from), o.cells_in), framing = framing, format = o.from}
	}
	return {as = json_reading, framing = framing, spec = json.Spec(json_reading.spec), format = o.from}
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

// Reports whether the input format is a tree format that is not JSON, read with a handle of its own.
reads_own :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.from].whole_as != nil
}

// Whether `data` holds no text of a JSON-like format, which has no value. A format read with a handle of its own
// judges an empty file itself, and a delimited one has no JSON spec.
blank_input :: proc(data: []byte, spec: Maybe(json.Spec)) -> bool {
	s, json_like := spec.?
	return json_like && json.blank(data, s)
}

// Reports whether each line of the input is one text of JSON.
reads_lines :: #force_inline proc(o: ^Opts) -> bool {
	return lines_of_json(o.from)
}

// Reports whether each output is written on a line of its own.
writes_lines :: #force_inline proc(o: ^Opts) -> bool {
	return lines_of_json(o.to)
}

@(private = "file")
lines_of_json :: #force_inline proc(f: Format) -> bool {
	return FORMATS[f].framing == .Lines && !FORMATS[f].cells
}

// Reports whether each output is written as a text of the output format, by the format's own writer.
writes_texts :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].written != nil
}

// How the library writes the texts of `writes_texts`.
text_written_as :: proc(o: ^Opts) -> core.As {
	return FORMATS[o.to].written(o)
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
		other := cli.json_flag if writes_cells(o) else cli.text_flag if writes_texts(o) else "--seq" if o.seq else cli.layout_flag if writes_lines(o) else ""
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
	if cli.yaml_flag != "" && o.from != .Yaml {
		usage_error("%s applies to --from yaml", cli.yaml_flag)
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
