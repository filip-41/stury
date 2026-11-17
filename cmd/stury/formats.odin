package main

// The formats `--from` reads and `--to` writes, one row of FORMATS each, and the options a format refuses.

import "core:reflect"
import "core:strings"
import core "../../core"
import cbor "../../cbor"
import dsv "../../dsv"
import html "../../html"
import json "../../json"
import toml "../../toml"
import xml "../../xml"
import yaml "../../yaml"

Format :: enum u8 {
	Json,
	Jsonc,
	Json5,
	Ndjson,
	Csv,
	Tsv,
	Toml,
	Yaml,
	Xml,
	Cbor,
	Html,
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
	// The spec its JSON texts are read in: `--argjson`, `fromjson` and a JSON-like format's input.
	spec:       json.Spec,
	// What the format's library offers: the write options its writer honours, so that the flags of the others are
	// refused, its specs, and whether an input of it is a stream of texts.
	caps:       core.Capabilities,
	// A tree format that is not JSON: the handle a whole text of it is read with, as the options say, and nil for
	// every other. Its input is one document built whole, unless `caps.follows` makes it a stream of them.
	whole_as:   proc "contextless" (o: ^Opts) -> core.As,
	// With `whole_as` and `caps.follows`: whether a document that ends a window of a followed file is closed there, so that
	// no later line continues it. Nil for a format whose document ends where its record is cut.
	ended:      proc "contextless" (text: []byte) -> bool,
	// With `whole_as`: a path is answered from a text of the format without building it.
	scans:      bool,
	// The handle `--to` writes each output with as a text of the format, through the format's document writer, which
	// takes a document of any format. Nil for a format written as JSON or as cells.
	written:    proc "contextless" (o: ^Opts) -> core.As,
	// With `written`: what stands between a text of a run and `text`, the next one, and nil for nothing.
	parted:     proc "contextless" (text: []u8) -> string,
}

@(rodata)
FORMATS := [Format]Format_Spec {
	.Json   = {name = "json", title = "JSON", caps = json.CAPABILITIES},
	.Jsonc  = {name = "jsonc", title = "JSON with comments", spec = .Jsonc, caps = json.CAPABILITIES},
	.Json5  = {name = "json5", title = "JSON5", spec = .Json5, caps = json.CAPABILITIES},
	.Ndjson = {name = "ndjson", title = "NDJSON", framing = .Lines, caps = json.CAPABILITIES},
	.Csv    = {name = "csv", title = "CSV", cells = true, framing = .Lines, caps = dsv.CAPABILITIES},
	.Tsv    = {name = "tsv", title = "TSV", cells = true, framing = .Lines, caps = dsv.CAPABILITIES},
	.Toml   = {name = "toml", title = "TOML", framing = .Concatenated, caps = toml.CAPABILITIES, whole_as = toml_reading, written = toml_written, parted = toml_parted},
	.Yaml   = {name = "yaml", title = "YAML", framing = .Concatenated, caps = yaml.CAPABILITIES, whole_as = yaml_reading, ended = yaml_ended, scans = true, written = yaml_written, parted = yaml_parted},
	.Xml    = {name = "xml", title = "XML", framing = .Concatenated, caps = xml.CAPABILITIES, whole_as = xml_reading, written = xml_written},
	.Cbor   = {name = "cbor", title = "CBOR", framing = .Concatenated, caps = cbor.CAPABILITIES, whole_as = cbor_reading, scans = true, written = cbor_written},
	.Html   = {name = "html", title = "HTML", framing = .Concatenated, caps = html.CAPABILITIES, whole_as = html_reading, written = html_written},
}

// TOML 1.1 reads every form 1.0 does, and there is no name for strict 1.0.
@(private = "file")
toml_reading :: proc "contextless" (o: ^Opts) -> core.As {
	return toml.as(toml.Spec(o.from_spec.? or_else u8(toml.Spec.Toml_1_1)), {max_depth = o.max_depth})
}

// TOML 1.0, which every reader takes.
@(private = "file")
toml_written :: proc "contextless" (o: ^Opts) -> core.As {
	return toml.as(toml.Spec(o.to_spec.? or_else u8(toml.Spec.Toml_1_0)), {max_depth = o.max_depth})
}

// A TOML text of a run follows a blank line.
@(private = "file")
toml_parted :: proc "contextless" (text: []u8) -> string {
	return "\n"
}

// YAML 1.2 with the core schema. A `%YAML 1.1` directive reads with the same rules.
@(private = "file")
yaml_reading :: proc "contextless" (o: ^Opts) -> core.As {
	return yaml.as(yaml.Spec(o.from_spec.? or_else u8(yaml.Spec.Yaml_1_2)), {max_depth = o.max_depth, alias_limit = o.alias_limit, merge_keys = o.merge_keys})
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
	return yaml.as(yaml.Spec(o.to_spec.? or_else u8(yaml.Spec.Yaml_1_2)), {max_depth = o.max_depth})
}

// A YAML text of a run starts its own document, as `---`, or as `...` before the directives of one that has them. The
// text's head comments stand before either.
@(private = "file")
yaml_parted :: proc "contextless" (text: []u8) -> string {
	at := 0
	for at < len(text) && (text[at] == '#' || text[at] == '\n') {
		for at < len(text) && text[at] != '\n' {
			at += 1
		}
		at += 1
	}
	rest := text[min(at, len(text)):]
	switch {
	case len(rest) > 0 && rest[0] == '%':
		return "...\n"
	case len(rest) >= 3 && string(rest[:3]) == "---":
		return ""
	}
	return "---\n"
}

// XML 1.0 with Namespaces and the internal subset. A text value is a string unless --infer.
@(private = "file")
xml_reading :: proc "contextless" (o: ^Opts) -> core.As {
	tolerate: bit_set[core.Tolerance; u8]
	if o.unread_entities {
		tolerate = {.Unread_Entity}
	}
	return xml.as(xml.Spec(o.from_spec.? or_else u8(xml.Spec.Xml)), {max_depth = o.max_depth, infer = o.cells_in.infer, tolerate = tolerate, max_expansion = o.expansion_limit})
}

@(private = "file")
xml_written :: proc "contextless" (o: ^Opts) -> core.As {
	return xml.as(xml.Spec(o.to_spec.? or_else u8(xml.Spec.Xml)), {max_depth = o.max_depth})
}

// An HTML document, or a fragment in `body`, as a browser with scripting disabled reads it. A text value is a string unless --infer.
@(private = "file")
html_reading :: proc "contextless" (o: ^Opts) -> core.As {
	return html.as(html.Spec(o.from_spec.? or_else u8(html.Spec.Document)), {max_depth = o.max_depth, infer = o.cells_in.infer})
}

@(private = "file")
html_written :: proc "contextless" (o: ^Opts) -> core.As {
	return html.as(html.Spec(o.to_spec.? or_else u8(html.Spec.Document)), {max_depth = o.max_depth})
}

// Any well-formed and valid item, in whatever serialization, unless a spec names one.
@(private = "file")
cbor_reading :: proc "contextless" (o: ^Opts) -> core.As {
	return cbor.as(cbor.Spec(o.from_spec.? or_else u8(cbor.Spec.Cbor)), {max_depth = o.max_depth})
}

// Each output one item in preferred serialization, unless a spec names another.
@(private = "file")
cbor_written :: proc "contextless" (o: ^Opts) -> core.As {
	return cbor.as(cbor.Spec(o.to_spec.? or_else u8(cbor.Spec.Preferred)), {max_depth = o.max_depth})
}

// The spec of format `f` that `text` names after `--from f:` or `--to f:`. Only a format whose own procs choose its
// spec takes one.
spec_named :: proc(f: Format, text: string) -> (spec: u8, ok: bool) {
	if FORMATS[f].whole_as == nil {
		return
	}
	values := reflect.enum_field_values(FORMATS[f].caps.specs)
	for name, i in reflect.enum_field_names(FORMATS[f].caps.specs) {
		if spec_spelling(f, name) == text {
			return u8(values[i]), true
		}
	}
	return
}

// The comma-separated spec names of format `f`, for a `spec_named` refusal.
spec_names :: proc(f: Format) -> string {
	b := make([dynamic]string, context.temp_allocator)
	for name in reflect.enum_field_names(FORMATS[f].caps.specs) {
		append(&b, spec_spelling(f, name))
	}
	return strings.join(b[:], ", ", context.temp_allocator)
}

// Spec `name` of format `f` as the command line spells it: in lower case, without the format's name before an
// underscore, and with a `.` for each underscore of a version.
@(private = "file")
spec_spelling :: proc(f: Format, name: string) -> string {
	s := strings.to_lower(name, context.temp_allocator)
	s = strings.trim_prefix(s, strings.concatenate({FORMATS[f].name, "_"}, context.temp_allocator))
	if len(s) > 0 && '0' <= s[0] && s[0] <= '9' {
		s, _ = strings.replace_all(s, "_", ".", context.temp_allocator)
	}
	return s
}

format_named :: proc(name: string) -> (f: Format, ok: bool) {
	for spec, k in FORMATS {
		if spec.name == name {
			return k, true
		}
	}
	return
}

// The format the extension of file `name` names, as `.yml` is YAML and `.jsonl` NDJSON, and none for any other.
format_of_file :: proc(name: string) -> (f: Format, ok: bool) {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 {
		return
	}
	switch ext := strings.to_lower(name[dot + 1:], context.temp_allocator); ext {
	case "yml":   return .Yaml, true
	case "jsonl": return .Ndjson, true
	case "htm":   return .Html, true
	case:         return format_named(ext)
	}
}

// The one format the extensions of `files` name, as a run with no --from reads them, and none when they name no format
// but JSON. A file of any other extension names JSON, and "-" names none. Files that name two formats are a usage error.
format_of_files :: proc(files: []string) -> (f: Format, ok: bool) {
	first: string
	for name in files {
		if name == "-" {
			continue
		}
		named, _ := format_of_file(name)
		switch {
		case first == "":
			f, first = named, name
		case named != f:
			usage_error("%s reads as %s and %s as %s: --from FORMAT reads every file as one", first, FORMATS[f].name, name, FORMATS[named].name)
		}
	}
	return f, f != .Json
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

// Reports whether the input format reads one document from each input, with a handle of its own.
reads_whole :: #force_inline proc(o: ^Opts) -> bool {
	return source_whole(o.from)
}

// Reports whether an input of format `f` is one document of a handle of its own.
source_whole :: #force_inline proc(f: Format) -> bool {
	return FORMATS[f].whole_as != nil && FORMATS[f].caps.follows == nil
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

// How a whole text of the tree format `f` is read under `o`.
tree_reading :: proc(f: Format, o: ^Opts) -> core.As {
	if whole_as := FORMATS[f].whole_as; whole_as != nil {
		return whole_as(o)
	}
	return json.as(FORMATS[f].spec, {max_depth = o.max_depth})
}

// Reports whether each output is written as a text of the output format, by the format's own writer.
writes_texts :: #force_inline proc(o: ^Opts) -> bool {
	return FORMATS[o.to].written != nil
}

// How the library writes the texts of `writes_texts`.
text_written_as :: proc(o: ^Opts) -> core.As {
	return FORMATS[o.to].written(o)
}

// Reports whether the outputs are JSON texts that keep the comments read with their values.
writes_comments :: #force_inline proc(o: ^Opts) -> bool {
	return !writes_texts(o) && !writes_cells(o) && .Comment in json.as(FORMATS[o.to].spec).readers.holds
}

// The facts a text of the output format holds.
holds_out :: proc(o: ^Opts) -> bit_set[core.Fact_Kind] {
	switch {
	case writes_texts(o):
		return text_written_as(o).readers.holds
	case writes_cells(o):
		return cells_written_as(o).readers.holds
	}
	return json.as(FORMATS[o.to].spec).readers.holds
}

// Refuses options that conflict with the chosen formats. A format with its own framing splits the input itself, and
// any format but JSON reads its own text, so --seq and -R do not apply. A delimited output writes no JSON text, so JSON
// layout options do not apply.
refuse_format_clashes :: proc(o: ^Opts, cli: ^Cli) {
	from, to := FORMATS[o.from].name, FORMATS[o.to].name
	if o.from != .Json {
		other := "--seq" if o.seq && FORMATS[o.from].framing != nil else "-R" if o.raw_input else ""
		if other != "" {
			usage_error("--from %s cannot be combined with %s", from, other)
		}
	}
	if o.to != .Json {
		if cli.command == .Check {
			usage_error("check writes nothing: --to %s has no use there", to)
		}
		other := unhonoured_flag(cli, FORMATS[o.to].caps.writes) if writes_cells(o) || writes_texts(o) else "--seq" if o.seq else cli.layout_flag if writes_lines(o) else ""
		if other != "" {
			usage_error("%s cannot be combined with --to %s", other, to)
		}
	}
	if o.grow_header && !writes_cells(o) {
		usage_error("--grow-header applies to --to csv or tsv")
	}
	if o.attributes && o.from != .Xml && o.from != .Html && o.to != .Xml && o.to != .Html {
		usage_error("--attributes applies to --from or --to xml or html")
	}
	if o.attributes && o.stream {
		usage_error("--attributes cannot be combined with --stream, whose events are each a leaf")
	}
	if cli.cells_flag != "" && !reads_cells(o) {
		usage_error("%s applies to --from csv or tsv", cli.cells_flag)
	}
	// schema sample takes --infer for a table it writes, whose cells it draws as --infer reads them.
	if cli.infer_flag != "" && !reads_cells(o) && o.from != .Xml && o.from != .Html && !(cli.command >= .Schema && writes_cells(o)) {
		usage_error("%s applies to --from csv, tsv, xml or html", cli.infer_flag)
	}
	if cli.yaml_flag != "" && o.from != .Yaml {
		usage_error("%s applies to --from yaml", cli.yaml_flag)
	}
	if cli.xml_flag != "" && o.from != .Xml {
		usage_error("%s applies to --from xml", cli.xml_flag)
	}
	// check and edit refuse the options that write a table as options they have no use for.
	if cli.cells_out_flag != "" && !writes_cells(o) && cli.command != .Check && cli.command != .Edit {
		usage_error("%s applies to --to csv or tsv", cli.cells_out_flag)
	}
	if reads_cells(o) {
		refuse_cell_bytes(cells_spec(o.from), o.cells_in, from, "--delimiter", "--comment")
	}
	if writes_cells(o) {
		refuse_cell_bytes(cells_spec(o.to), o.cells_out, to, "--out-delimiter" if cli.out_delimiter != nil else "--delimiter", "--out-comment" if cli.out_comment != nil else "--comment")
	}
}

// The first option given that a writer honouring `writes` has no use for, or "".
@(private = "file")
unhonoured_flag :: proc(cli: ^Cli, writes: bit_set[core.Write_Option; u8]) -> string {
	if cli.text_flag != "" {
		return cli.text_flag
	}
	for flag, option in cli.option_flags {
		if flag != "" && option not_in writes {
			return flag
		}
	}
	return ""
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
