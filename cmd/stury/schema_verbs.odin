package main

// `stury schema infer FILES` writes the JSON Schema that every record of the inputs passes, and `stury schema sample
// SCHEMA` writes values that pass a schema, or with --invalid values that do not. The inputs are read as `stury check`
// reads them, and a sample is written as --to says.

import "core:os"
import "core:path/filepath"
import core "../../core"
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
	flag:     string, // the first of these given
}

// Takes the option `args[i]` and its parameter.
verb_option :: proc(v: ^Verb_Options, args: []string, i: int) {
	if v.flag == "" {
		v.flag = args[i]
	}
	switch a := args[i]; a {
	case "--ranges":   v.ranges = true
	case "--invalid":  v.invalid = true
	case "--comments": v.comments = true
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

// Runs the verb that `cli.files` opens with and exits.
schema_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	if len(cli.files) == 0 || cli.files[0] != "infer" && cli.files[0] != "sample" {
		usage_error("schema takes infer or sample")
	}
	verb, files := cli.files[0], cli.files[1:]
	if verb == "infer" {
		infer_main(run, cli, files)
	}
	sample_main(run, cli, files)
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
	if cli.verbs.invalid || cli.verbs.comments || cli.verbs.seed != 0 || cli.verbs.count != 0 {
		usage_error("--invalid, --comments, --seed and --count are sample's")
	}
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
	if cli.verbs.ranges {
		usage_error("--ranges is infer's")
	}
	if cli.formats.from != nil {
		usage_error("--from is infer's: a schema is read as JSON")
	}
	f, opened := open_file(files[0], "schema sample")
	if !opened {
		os.exit(EXIT_USAGE)
	}
	text, read := read_file(f)
	if !read {
		os.exit(EXIT_USAGE)
	}
	doc, err := core.build(text, json.as(.Json))
	if err != nil {
		usage_error("%s: %s", files[0], edit_error_text(text, err))
	}
	res := schema.Resolver {
		as   = json.as(.Json),
		root = filepath.dir(files[0]),
	}
	d, rerr := schema.read(&doc, core.ROOT, "", &res)
	if rerr != nil {
		usage_error("%s: %s", files[0], edit_error_text(text, rerr))
	}
	if writes_cells(o) && cli.verbs.count > 1 {
		usage_error("--count above 1 writes one table for each value, which is not one %s: use --count 1", FORMATS[o.to].name)
	}
	as := cells_written_as(o) if writes_cells(o) else json.as(FORMATS[FORMATS[o.to].written_as.? or_else o.to].spec)
	// A value is a line, so the text is compact unless a layout option asks for more.
	layout := output_layout(run).opts
	layout.pretty = layout.pretty && cli.layout_flag != ""
	values, serr := schema.sample(&d, as, {seed = cli.verbs.seed, count = cli.verbs.count, invalid = cli.verbs.invalid, comments = cli.verbs.comments, write = layout})
	if serr != nil {
		message.write_stderr("stury: error: %s\n", edit_error_text(text, serr))
		os.exit(1)
	}
	for v in values {
		message.write_stdout("%s%s", string(v), "" if writes_cells(o) else "\n")
	}
	exit_closing_stdout(0)
}
