package main

// The stury command line: a jq filter over JSON files.
//
//	stury [OPTIONS] [FILTER] [FILE...]
//	stury check [--from format|--seq] [--max-depth n] [FILE...]
//	stury fmt [--from format] [--to format] [--in-place|--check] [--indent n|--tab] [--max-depth n] [FILE...]
//	stury edit [--from format|--seq] [--in-place|--check] FILTER [FILE...]
//
// FILTER is a jq program, and the output is what jq 1.8 prints for it. The options are listed in HELP_OPTIONS
// (usage.odin). With no FILE it reads stdin, and with no FILTER it runs `.` unless stdin and stdout are both a
// terminal. The exit codes are jq's: 2 for a usage or file error, 3 for a filter that does not compile, 5 for invalid
// input or an error the filter raises. Under `-e`, 1 when the last output is false or null and 4 when there is none.
//
// Where things live in cmd/stury:
//
//	options.odin                     the command line
//	usage.odin                       the help, the version and the usage error
//	load_values.odin                 JSON texts and files the options name, and the -f program
//	colors.odin                      jq's output colours and when a run uses them
//	formats.odin                     the formats --from reads and --to writes
//	input.odin                       reading files and stdin
//	stream_fault.odin                --stream for a text that does not parse
//	route.odin                       the path scan or the interpreter, which answers the filter
//	explain.odin                     --explain's report of the route and the run
//	check.odin                       `stury check`, which judges the inputs
//	fmt.odin                         `stury fmt`, which writes the inputs back in the printer's layout
//	edit.odin                        `stury edit`, which splices the filter's value into the input's bytes
//	filter.odin                      the jq interpreter over each input
//	print.odin                       output as jq prints it, and what it comes to (`Output`)
//	message/                         the text of every message, built from a format and its values (package `message`)
//	platform_posix.odin,
//	platform_windows.odin            the calls into the system, one file per platform
//	jq/                              the jq interpreter (package `jq`)
//	regex/                           the Oniguruma-compatible matcher behind `test`, `match` and `sub`

import "core:os"
import "core:slice"
import "core:strings"
import host "../../host"
import "jq"
import "message"

EXIT_USAGE :: 2
EXIT_COMPILE :: 3
EXIT_INPUT :: 5

Run :: struct {
	opts:        Opts,
	colors:      [8]string, // when opts.color, jq's colours (DEFAULT_COLORS) as $JQ_COLORS sets them
	prog:        ^jq.Node,
	// The filter and the command line's variables, which `ready_interpreter` parses, checks and binds.
	program:     struct {
		text:               string,
		names:              []string,
		values, positional: []jq.Value,
		named:              int, // the first `named` of names are $ARGS.named
	},
	home_module: bool, // `~/.jq`, or what stands for it, is a module every filter includes
	route:       Route,
	ip:          jq.Interp,
	output:      Output,
	halted:      bool,
	// `run_pool`'s, started at its first use. Held by pointer: a piece copies the run while helpers still start.
	pool:        ^host.Pool,
	spares:      Spare_Outs, // the pieces' output buffers, kept from one file to the next
	parallel:    Maybe(bool), // whether the filter runs on pieces, once `parallel` has decided it
	collects:    int, // the collect jobs started, which number them from 1
}

main :: proc() {
	// Before any thread but this one runs.
	jq.set_origin()
	run: Run
	run.opts.indent = 2
	cli := parse_args(&run.opts, command_args()[1:])
	set_colors(&run, cli)
	run.route.on = run.opts.explain
	o := &run.opts
	if cli.editing {
		refuse_edit(o)
	}
	refuse_format_clashes(o, &cli)
	validating := cli.validating
	switch {
	case (o.in_place || o.check) && !cli.formatting && !cli.editing:
		usage_error("%s is fmt's and edit's: a filter run has no use for it", "--in-place" if o.in_place else "--check")
	case !validating && cli.schema.flag != "":
		usage_error("%s is check's: a schema judges the inputs of stury check", cli.schema.flag)
	case !cli.schema_verb && cli.verbs.flag != "":
		usage_error("%s is schema's: stury schema infer and stury schema sample take it", cli.verbs.flag)
	case validating || cli.formatting || cli.editing || cli.schema_verb:
		if flag := command_refused_option(o, &cli); flag != "" {
			usage_error("%s has no use with %s: %s", flag, command_name(&cli), "it runs no filter and prints nothing" if validating else "it runs no filter and writes each input's own format" if cli.formatting else "it runs no filter and writes a schema or samples" if cli.schema_verb else "it writes each input back in its own bytes")
		}
	}
	if o.follow {
		refuse_follow(o, &cli)
	}
	if validating {
		check_main(&run, &cli)
	}
	if cli.formatting {
		fmt_main(&run, &cli)
	}
	if cli.schema_verb {
		schema_main(&run, &cli)
	}
	if dirs, given := cli.lib_dirs.?; given {
		run.ip.search_list = dirs[:]
	}
	run.ip.reading = cli.json_reading
	run.ip.load_file = load_file
	run.ip.debug_layout = output_layout(&run)
	run.ip.debug_layout.opts.pretty = false
	text, has := cli.filter.?
	switch {
	case has && o.from_file:
		text = program_file(&run.ip, text)
	case !has && !o.from_file && !(is_terminal(os.stdin) && is_terminal(os.stdout)):
		// As jq: no filter is `.`, unless both stdin and stdout are a terminal.
		text = "."
	case !has:
		usage(EXIT_USAGE, true)
	}
	// Defined as jq defines it, but not one of $ARGS.named.
	named := len(cli.var_names)
	if !slice.contains(cli.var_names[:], "JQ_BUILD_CONFIGURATION") {
		append(&cli.var_names, "JQ_BUILD_CONFIGURATION")
		append(&cli.var_values, string(BUILD_CONFIGURATION))
	}
	run.program = {text, cli.var_names[:], cli.var_values[:], cli.positional[:], named}
	explain_filter(&run)
	run.home_module = jq.home_module(&run.ip)
	ready_interpreter(&run)
	if cli.editing {
		edit_main(&run, &cli)
	}
	choose_route(&run, text)
	ins := Inputs {
		source  = input_source(o, cli.json_reading),
		parsed  = {line = 1},
		files   = cli.files[:] if len(cli.files) > 0 else STDIN_ONLY,
		slurp   = o.slurp,
		run     = &run,
	}
	explain_route(&run, ins.framing)
	if o.follow {
		catch_stop()
	}
	bind_inputs(&run.ip, &ins)
	init_output(&run.output, &run)
	reserve(&run.ip.messages, 1 << 12)
	// The interpreter recurses, and so does printing an answer.
	run_deep(&run, &ins, run_filter)
	// jq's exit status: the last input's result, 5 after a text that does not parse, 2 after a file that did not
	// open. Under -e, from the last output when the last input had none.
	code := EXIT_USAGE if ins.failures > 0 else run.output.ret
	if o.exit_status {
		if code == JQ_OK_NO_OUTPUT {
			last := run.output.last_result
			code = JQ_OK_NO_OUTPUT if last < 0 else JQ_OK_NULL_KIND if last == 0 else JQ_OK
		}
		finish(&run, abs(code))
	}
	finish(&run, max(code, 0))
}

// Report the filter's compile errors as jq does and exit, if there are any.
compile_errors :: proc(text: string, errors: []jq.Compile_Error) {
	if len(errors) == 0 {
		return
	}
	for e in errors {
		message.write_stderr("stury: error: %s\n", jq.locate(text, e))
	}
	if command := near_command(text); command != "" {
		message.write_stderr("stury: %s is not a command: did you mean stury %s?\n", text, command)
	}
	exit_compile(len(errors))
}

// The command a filter of one word is a letter or two from, as a mistyped `stury chek FILE` gives, or "".
@(private = "file")
near_command :: proc(text: string) -> string {
	for c in transmute([]byte)text {
		if c < 'a' || c > 'z' {
			return ""
		}
	}
	for command in ([]string{"check", "fmt", "edit"}) {
		if d := strings.levenshtein_distance(text, command, context.temp_allocator); d <= (len(command) - 1) / 2 {
			return command
		}
	}
	return ""
}

// jq's count of compile errors, then exit as it does.
exit_compile :: proc(count: int) -> ! {
	message.write_stderr("stury: %d compile error%s\n", count, "" if count == 1 else "s")
	exit_closing_stdout(EXIT_COMPILE)
}

// Parse and check the filter and bind its globals, before the interpreter first runs.
ready_interpreter :: proc(run: ^Run) {
	parsed, errors := jq.parse(run.program.text)
	compile_errors(run.program.text, errors)
	if parsed.body == nil {
		message.write_stderr("stury: error: Top-level program not given (try \".\")\n")
		exit_compile(1)
	}
	// The modules the filter imports, and `~/.jq`, loaded, or exit as jq does when one cannot be.
	linked: jq.Linked
	if len(parsed.deps) > 0 || run.home_module {
		linked = jq.link(&run.ip, parsed.deps, jq.program_origin(&run.ip))
		if linked.errors > 0 {
			message.write_stderr("%s", linked.messages)
			exit_compile(linked.errors)
		}
	}
	prog, check_errors, prelude := jq.check(parsed.body, run.program.names, linked)
	compile_errors(run.program.text, check_errors)
	run.prog = prog
	run.ip.globals = prelude
	bind_cli_vars(run)
	// A module sees the command line's variables, never its importer's.
	for lib in linked.libs {
		if lib.bottom != nil {
			lib.bottom.parent = run.ip.globals
		}
	}
	run.ip.globals = jq.bind_data(run.ip.globals, linked.imports)
}

// The command line's variables, and $ARGS, over the globals so far.
bind_cli_vars :: proc(run: ^Run) {
	names, values, positional := run.program.names, run.program.values, run.program.positional
	named := jq.new_object()
	for name, i in names {
		run.ip.globals = jq.bind_var(&run.ip, run.ip.globals, name, values[i])
		if i < run.program.named {
			jq.object_put(named, name, values[i])
		}
	}
	args := jq.new_object()
	listed := jq.new_array()
	append(&listed.items, ..positional)
	jq.object_put(args, "positional", listed)
	jq.object_put(args, "named", named)
	run.ip.globals = jq.bind_var(&run.ip, run.ip.globals, "ARGS", args)
}

finish :: proc(run: ^Run, code: int) -> ! {
	table_end(&run.output)
	flush_some(&run.output, force = true)
	explain_end(run)
	end_if_stopped()
	// fmt --check and --in-place write nothing to stdout, and do not fail on one that is closed, as check does not.
	if run.output.held {
		os.exit(code)
	}
	exit_closing_stdout(code)
}
