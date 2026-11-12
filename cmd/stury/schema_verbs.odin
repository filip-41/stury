package main

// `stury schema infer FILES` writes the JSON Schema that every record of the inputs passes, `stury schema sample
// SCHEMA` writes values that pass a schema, or with --invalid values that do not, and `stury schema gen SCHEMA` writes
// the Odin types of its values. The inputs are read as `stury check` reads them, and a sample is written as --to says.

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import core "../../core"
import "../../core/rules"
import "../../core/schema"
import dsv "../../dsv"
import json "../../json"
import "message"

// The options of the schema verbs.
Verb_Options :: struct {
	ranges:   bool, // infer: keep the bounds of numbers, lengths and counts
	invalid:  bool, // sample: values that fail the schema
	comments: bool, // sample: a node's description as a comment where the format has comments
	seed:     u64,
	count:    int,
	package_name: string, // gen: the package the types are written in
}

// Takes the option `args[i]` and its parameter.
verb_option :: proc(v: ^Verb_Options, args: []string, i: int) {
	switch a := args[i]; a {
	case "--ranges":   v.ranges = true
	case "--invalid":  v.invalid = true
	case "--comments": v.comments = true
	case "--package":
		if i + 1 >= len(args) {
			usage_error("--package takes a package name")
		}
		v.package_name = args[i + 1]
	case "--seed", "--count":
		n, ok := parse_digits(args[i + 1] if i + 1 < len(args) else "", 1 << 31)
		if !ok || a == "--count" && n < 1 {
			usage_error("%s takes a number%s", a, " from 1" if a == "--count" else "")
		}
		if a == "--seed" {
			v.seed = n
		} else {
			v.count = int(n)
		}
	}
}

// Whether the command is `schema gen`, which writes Odin and takes no layout.
generates_odin :: proc(cli: ^Cli) -> bool {
	return cli.schema_verb && len(cli.files) > 0 && cli.files[0] == "gen"
}

// Runs the verb that `cli.files` opens with and exits.
schema_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	verb := cli.files[0] if len(cli.files) > 0 else ""
	if verb != "infer" && verb != "sample" && verb != "gen" {
		usage_error("schema takes infer, sample or gen")
	}
	if verb != "infer" && run.opts.max_depth != 0 {
		usage_error("--max-depth has no use with schema %s: it reads no input", verb)
	}
	files := cli.files[1:]
	switch verb {
	case "infer":
		infer_main(run, cli, files)
	case "sample":
		sample_main(run, cli, files)
	}
	gen_main(cli, files)
}

// Refuses a table that `d` describes no rows of: one written, `format` being --to, or read, `format` being --from.
refuse_unlisted :: proc(d: ^rules.Description, format: Format, verb: string) {
	if !FORMATS[format].cells {
		return
	}
	n := d.root
	for hops := 0; hops <= len(d.nodes) && rules.ref_only(&d.nodes[n]); hops += 1 {
		n = d.nodes[n].ref.?
	}
	if .Array not_in d.nodes[n].kinds {
		usage_error("%s %s a table: the schema describes no array of rows", FORMATS[format].name, verb)
	}
}

// Reads the records of `data`, the file `path`, into `inf`. A fault is told on stderr as the plain check tells it, and
// gives false.
infer_read :: proc(inf: ^schema.Inferred, src: Source, path: string, data: []byte, o: ^Opts, runner: ^core.Runner = nil) -> bool {
	err := schema.infer_records(inf, data, src.as, src.framing, runner)
	if err == nil {
		return true
	}
	if bad, is_fault := first_fault(data, src.as, src.framing, nil, 0).?; is_fault {
		tell_operand_fault(o, src, path, data, bad)
	} else {
		message.write_stderr("stury: parse error: %s: %s\n", file_name(path), edit_error_text(data, err))
	}
	return false
}

// The description of the records of `files`, or of the standard input, written as JSON as the layout options say. Exits 5
// after a text that does not read or runs out of memory, and 2 after a file that does not open.
@(private = "file")
infer_main :: proc(run: ^Run, cli: ^Cli, files: []string) -> ! {
	if cli.formats.to != nil {
		usage_error("--to is sample's: schema infer writes JSON Schema")
	}
	if cli.schema.draft != nil {
		usage_error("--schema-draft is schema sample's and schema gen's: schema infer reads no schema")
	}
	if len(files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
		usage(EXIT_USAGE, true)
	}
	src := input_source(&run.opts, cli.json_reading)
	inf := schema.Inferred {
		ranges = cli.verbs.ranges,
	}
	failures, faults := 0, 0
	for path in (files if len(files) > 0 else STDIN_ONLY) {
		spent, read := file_bytes(path, "schema infer")
		if !read {
			failures += 1
			continue
		}
		data := spent.data
		// A text with no value in it is the fault check calls it, not a value of every kind.
		if msg := blank_told(file_name(path), data, src, &run.opts); msg != "" {
			message.write_stderr("stury: parse error: %s", msg)
			faults += 1
			free_spent(spent)
			continue
		}
		runner: ^core.Runner
		if len(data) >= POOLED_BYTES {
			runner = run_pool(run)
		}
		if !infer_read(&inf, src, path, data, &run.opts, runner) {
			faults += 1
		}
		free_spent(spent)
	}
	if failures > 0 || faults > 0 {
		os.exit(EXIT_USAGE if failures > 0 else EXIT_INPUT)
	}
	d, derr := schema.inferred(&inf)
	if derr != nil {
		message.write_stderr("stury: error: out of memory\n")
		os.exit(EXIT_INPUT)
	}
	text, err := schema.write(&d, json.as(.Json), output_layout(run).opts)
	if e, refused := err.(core.Typed_Error); refused && e.kind == .Too_Deep {
		// A schema nests a level or two for each level of its values, so one of a deep input may pass the writer's limit.
		message.write_stderr("stury: error: schema infer: the schema of the input nests past %d levels, which a schema written as JSON may not\n", core.MAX_DEPTH)
		os.exit(EXIT_INPUT)
	}
	if err != nil {
		message.write_stderr("stury: error: %s\n", edit_error_text(nil, err))
		os.exit(EXIT_USAGE)
	}
	message.write_stdout("%s\n", string(text))
	exit_closing_stdout(0)
}

// Values for the schema in the one file `files` names, a line each in the format --to names.
@(private = "file")
sample_main :: proc(run: ^Run, cli: ^Cli, files: []string) -> ! {
	o := &run.opts
	if len(files) != 1 {
		usage_error("schema sample takes one schema file")
	}
	if cli.formats.from != nil {
		usage_error("--from is infer's: a schema is read as JSON")
	}
	if cli.verbs.comments && !writes_comments(o) {
		usage_error("--comments writes a description as a comment, and %s has no comments", FORMATS[o.to].name)
	}
	sc := schema_read({file = files[0], refs = cli.schema.refs, draft = cli.schema.draft}, "schema sample")
	d, text := sc.compiled.description, sc.text
	if writes_cells(o) && cli.verbs.count > 1 {
		usage_error("--count above 1 writes one table for each value, which is not one %s: use --count 1", FORMATS[o.to].name)
	}
	if writes_texts(o) {
		usage_error("schema sample writes json, jsonc, ndjson, csv or tsv, not %s", FORMATS[o.to].name)
	}
	refuse_unlisted(d, o.to, "writes")
	// A table is drawn as --infer reads one, so a column the schema types holds that type's cells.
	o.cells_out.infer = o.cells_in.infer
	as := cells_written_as(o) if writes_cells(o) else json.as(FORMATS[FORMATS[o.to].written_as.? or_else o.to].spec)
	// A value is a line, so the text is compact unless a layout option asks for more.
	layout := output_layout(run).opts
	layout.pretty = layout.pretty && cli.layout_flag != ""
	// A value is written as it is made, so the run holds one value and one chunk of output.
	Out :: struct {
		text:  strings.Builder,
		lines: bool,
	}
	out := Out {
		text  = strings.builder_make(runtime.heap_allocator()),
		lines = !writes_cells(o),
	}
	serr := schema.sample_each(d, as, {reads = dsv.checks_for(as), seed = cli.verbs.seed, count = cli.verbs.count, invalid = cli.verbs.invalid, comments = cli.verbs.comments, write = layout}, proc(text: []u8, user: rawptr) {
		out := (^Out)(user)
		strings.write_bytes(&out.text, text)
		if out.lines {
			strings.write_byte(&out.text, '\n')
		}
		flush_out(&out.text, false)
	}, &out)
	flush_out(&out.text, true)
	if serr != nil {
		message.write_stderr("stury: error: schema sample %s: %s\n", files[0], edit_error_text(text, serr))
		os.exit(1)
	}
	exit_closing_stdout(0)
}

// The Odin types of the values of the schema in the one file `files` names, in the package --package names or else the
// one the file's stem spells in snake case, with formats asserting under --format-assert. Exits 1 when the schema holds
// a keyword no Odin type spells.
@(private = "file")
gen_main :: proc(cli: ^Cli, files: []string) -> ! {
	if len(files) != 1 {
		usage_error("schema gen takes one schema file")
	}
	if cli.formats.from != nil || cli.formats.to != nil {
		usage_error("--%s has no use with schema gen: a schema is read as JSON and the types are written as Odin", "from" if cli.formats.from != nil else "to")
	}
	name := cli.verbs.package_name
	if name == "" {
		name = strings.to_snake_case(filepath.short_stem(files[0]))
	}
	sc := schema_read({file = files[0], refs = cli.schema.refs, draft = cli.schema.draft}, "schema gen")
	text := sc.text
	source, err := schema.write_odin(sc.compiled.description, name, json.as(.Json), cli.schema.format_assert)
	if e, typed := err.(core.Typed_Error); typed && e.kind == .Bad_Option {
		usage_error("%q cannot name the package: it is no Odin identifier, or a package the types import%s", name, "" if cli.verbs.package_name != "" else ": name one with --package")
	}
	if err != nil {
		message.write_stderr("stury: error: %s\n", edit_error_text(text, err))
		os.exit(1)
	}
	message.write_stdout("%s", source)
	exit_closing_stdout(0)
}
