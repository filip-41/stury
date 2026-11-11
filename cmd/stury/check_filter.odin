package main

// `stury check --filter F --schema S` types the filter F against the schema S of its inputs and reads no input. It
// tells each step that no input S describes can take, as a compile error is told, and writes the schema every output
// of F passes. The input options say what F reads: a record of a table under `--from csv` holds the cells it reads.

import "core:os"
import "../../core/schema"
import json "../../json"
import "jq"
import "message"

// Exits 0, or 1 after a refusal, or 2 when the schema or the options do not serve.
check_filter_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o, s := &run.opts, cli.schema
	switch {
	case len(cli.files) > 0:
		usage_error("check --filter reads no input: it types the filter against --schema, and %s is an input", cli.files[0])
	case s.max_errors != 0 || s.reported:
		usage_error("%s judges inputs: check --filter reads none", "--max-errors" if s.max_errors != 0 else "--report")
	}
	sc := schema_read(s)
	refuse_unlisted(sc.compiled.description, o.from, "reads")
	opts := jq.Typing_Input {
		null_input = o.null_input,
		slurp      = o.slurp,
		raw        = o.raw_input,
		cells      = reads_cells(o),
		infer      = o.cells_in.infer,
		no_header  = o.cells_in.no_header,
		names      = run.program.names,
		values     = run.program.values,
		text       = run.program.text,
	}
	typing := jq.type_filter(run.prog, sc.compiled.description, opts)
	for e in typing.refusals {
		message.write_stderr("stury: error: %s\n", jq.locate(run.program.text, e))
	}
	text, err := schema.write(&typing.d, json.as(.Json), output_layout(run).opts)
	if err != nil {
		message.write_stderr("stury: error: %s\n", edit_error_text(nil, err))
		os.exit(EXIT_USAGE)
	}
	message.write_stdout("%s\n", string(text))
	exit_closing_stdout(1 if len(typing.refusals) > 0 else 0)
}
