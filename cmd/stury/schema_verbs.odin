package main

// `stury schema infer FILES` writes the JSON Schema that every record of the inputs passes, `stury schema sample
// SCHEMA` writes values that pass a schema, or with --invalid values that do not, and `stury schema gen SCHEMA` writes
// the Odin types of its values. The inputs are read as `stury check` reads them, and a sample is written as --to says.

import "core:os"
import "core:path/filepath"
import "core:strings"
import core "../../core"
import "../../core/rules"
import "../../core/schema"
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
	flag:     string, // the first of these given
	given:    [Schema_Verb]string, // the first option of each verb given
}

Schema_Verb :: enum u8 {
	Infer,
	Sample,
	Gen,
}

@(rodata)
SCHEMA_VERBS := [Schema_Verb]string {
	.Infer  = "infer",
	.Sample = "sample",
	.Gen    = "gen",
}

// Takes the option `args[i]` and its parameter.
verb_option :: proc(v: ^Verb_Options, args: []string, i: int) {
	if v.flag == "" {
		v.flag = args[i]
	}
	if verb := verb_of_option(args[i]); v.given[verb] == "" {
		v.given[verb] = args[i]
	}
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

// The schema verb that takes `option`, one of Verb_Options'.
verb_of_option :: proc(option: string) -> Schema_Verb {
	switch option {
	case "--ranges":
		return .Infer
	case "--package":
		return .Gen
	}
	return .Sample
}

// Whether the command is `schema gen`, which writes Odin and takes no layout.
generates_odin :: proc(cli: ^Cli) -> bool {
	return cli.schema_verb && len(cli.files) > 0 && cli.files[0] == "gen"
}

// Runs the verb that `cli.files` opens with and exits.
schema_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	verb, named := Schema_Verb.Infer, false
	for name, v in SCHEMA_VERBS {
		if len(cli.files) > 0 && cli.files[0] == name {
			verb, named = v, true
		}
	}
	if !named {
		usage_error("schema takes infer, sample or gen")
	}
	for flag, other in cli.verbs.given {
		if other != verb && flag != "" {
			usage_error("%s is %s's", flag, SCHEMA_VERBS[other])
		}
	}
	files := cli.files[1:]
	switch verb {
	case .Infer:
		infer_main(run, cli, files)
	case .Sample:
		sample_main(run, cli, files)
	case .Gen:
	}
	gen_main(cli, files)
}

// Reads the records of `data`, the file `path`, into `inf`. A fault is told on stderr and gives false, after the line of
// the first fault of the bytes when `told_by` is given, which exits.
infer_read :: proc(inf: ^schema.Inferred, src: Source, path: string, data: []byte, runner: ^core.Runner = nil, told_by: ^Opts = nil) -> bool {
	err := schema.infer_records(inf, data, src.as, src.framing, runner)
	if err == nil {
		return true
	}
	if told_by != nil {
		exit_on_fault(told_by, src, path, data)
	}
	message.write_stderr("stury: parse error: %s: %s\n", file_name(path), edit_error_text(data, err))
	return false
}

// The description of the records of `files`, or of the standard input, written as JSON as the layout options say. Exits 5
// after a text that does not read or runs out of memory, and 2 after a file that does not open.
@(private = "file")
infer_main :: proc(run: ^Run, cli: ^Cli, files: []string) -> ! {
	if cli.formats.to != nil {
		usage_error("--to is sample's: schema infer writes JSON Schema")
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
		f, opened := open_file(path, "schema infer")
		if !opened {
			failures += 1
			continue
		}
		data, _, mapped := map_file(f)
		read := true
		if mapped {
			if f != os.stdin {
				os.close(f)
			}
		} else {
			data, read = read_file(f)
		}
		if !read {
			failures += 1
			continue
		}
		runner: ^core.Runner
		if len(data) >= POOLED_BYTES {
			runner = run_pool(run)
		}
		if !infer_read(&inf, src, path, data, runner) {
			faults += 1
		}
		free_spent({data, mapped})
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
	d, text := read_schema_file(files[0], "schema sample")
	if writes_cells(o) && cli.verbs.count > 1 {
		usage_error("--count above 1 writes one table for each value, which is not one %s: use --count 1", FORMATS[o.to].name)
	}
	as := cells_written_as(o) if writes_cells(o) else json.as(FORMATS[FORMATS[o.to].written_as.? or_else o.to].spec)
	// A value is a line, so the text is compact unless a layout option asks for more.
	layout := output_layout(run).opts
	layout.pretty = layout.pretty && cli.layout_flag != ""
	values, serr := schema.sample(&d, as, {reads = checks_of(as, writes_cells(o)), seed = cli.verbs.seed, count = cli.verbs.count, invalid = cli.verbs.invalid, comments = cli.verbs.comments, write = layout})
	if serr != nil {
		message.write_stderr("stury: error: %s\n", edit_error_text(text, serr))
		os.exit(1)
	}
	for v in values {
		message.write_stdout("%s%s", string(v), "" if writes_cells(o) else "\n")
	}
	exit_closing_stdout(0)
}

// The description of the schema in the file `path`, and the file's text. A file that does not open, read or describe
// is a usage error.
@(private = "file")
read_schema_file :: proc(path, verb: string) -> (rules.Description, []byte) {
	f, opened := open_file(path, verb)
	if !opened {
		os.exit(EXIT_USAGE)
	}
	text, read := read_file(f)
	if !read {
		os.exit(EXIT_USAGE)
	}
	// The description's values are nodes of the document, which outlives this call.
	doc := new(core.Document)
	err: core.Error
	doc^, err = core.build(text, json.as(.Json))
	if err != nil {
		usage_error("%s: %s", path, edit_error_text(text, err))
	}
	res := schema.Resolver {
		as   = json.as(.Json),
		root = schema_directory(path),
	}
	d, rerr := schema.read(doc, core.ROOT, "", &res)
	if rerr != nil {
		usage_error("%s: %s", path, edit_error_text(text, rerr))
	}
	return d, text
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
	d, text := read_schema_file(files[0], "schema gen")
	source, err := schema.write_odin(&d, name, cli.schema.format_assert)
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
