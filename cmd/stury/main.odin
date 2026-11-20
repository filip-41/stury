package main

// The stury command line: a jq filter over JSON files.
//
//	stury [OPTIONS] [FILTER] [FILE...]
//	stury check [--from format|--seq] [--max-depth n] [FILE...]
//	stury fmt [--from format] [--to format] [--in-place|--check] [--indent n|--tab] [--max-depth n] [FILE...]
//	stury edit [--from format|--seq] [--in-place|--check|--diff] FILTER [FILE...]
//	stury diff [--set|--position|--key K] [--facts] [--json] OLD NEW
//	stury diff --old-schema S1 --new-schema S2 [--compat backward|forward|full]
//
// FILTER is a jq program, and the output is what jq 1.8 prints for it. The options are listed in HELP_OPTIONS
// (usage.odin). With no FILE it reads stdin, and with no FILTER it runs `.` unless stdin and stdout are both a
// terminal. The exit codes are jq's: 2 for a usage or file error, 3 for a filter that does not compile, 5 for invalid
// input or an error the filter raises. Under `-e`, 1 when the last output is false or null and 4 when there is none.

import "core:crypto"
import "core:os"
import "core:slice"
import "core:time"
import "../../core/spell"
import core "../../core"
import host "../../host"
import "../../jq"
import "message"

EXIT_USAGE :: 2
EXIT_COMPILE :: 3
EXIT_INPUT :: 5

Run :: struct {
	opts:        Opts,
	colors:      [8]string, // when opts.color, jq's colours (DEFAULT_COLORS) as $JQ_COLORS sets them
	prog:        jq.Program,
	shape:       jq.Shape, // the program's, which the routes read
	// The filter and the command line's variables, which `ready_interpreter` parses, checks and binds.
	program:     struct {
		text:               string,
		names:              []string,
		values, positional: []core.Value,
		named:              int, // the first `named` of names are $ARGS.named
		typed:              bool, // the filter is --filter's, which no mistyped command gives
	},
	route:       Route,
	ip:          jq.Interp,
	output:      Output,
	halted:      bool,
	// `run_pool`'s, started at its first use. Held by pointer: a piece copies the run while helpers still start.
	pool:        ^host.Pool,
	spares:      Spare_Outs, // the pieces' output buffers, kept from one file to the next
	parallel:    Maybe(bool), // whether the filter runs on pieces, once `parallel` has decided it
	collects:    int, // the collect jobs started, which number them from 1
	convert:     ^Conversion, // fmt --schema: the schema a conversion follows
	labels:      bool, // --each: each file's outputs open with its name, as more than one file is read
}

main :: proc() {
	run: Run
	run.opts.indent = 2
	cli := parse_args(&run.opts, command_args()[1:])
	set_colors(&run, cli)
	run.route.on = run.opts.explain
	o := &run.opts
	if (cli.command == .Edit || cli.command == .Fmt) && o.in_place && o.check {
		usage_error("--in-place rewrites each file; --check only reads it")
	}
	if cli.command == .Edit {
		refuse_edit(o)
	}
	refuse_format_clashes(o, &cli)
	refuse_unowned(&cli)
	if o.each && !o.no_filename && o.to == .Cbor {
		usage_error("--each labels the lines of its output, and --to cbor writes none: add --no-filename")
	}
	if o.no_filename && !o.each {
		usage_error("--no-filename has no use without --each")
	}
	if o.to == .Cbor && !o.in_place && !o.check && !o.diff && is_terminal(os.stdout) {
		usage_error("--to cbor writes raw bytes: redirect the output to a file or a pipe")
	}
	if flag := command_refused_option(o, &cli); flag != "" && cli.command != .Run {
		usage_error("%s has no use with %s: %s", flag, command_name(&cli), command_writes(&cli))
	}
	// Both recurse on the values they read, which --max-depth lets nest past the main thread's stack.
	if cli.command == .Diff {
		run_deep(&run, &Inputs{run = &run, cli = &cli}, diff_main)
	}
	if o.quarantine != "" {
		open_quarantine(o.quarantine)
	}
	if o.follow {
		refuse_follow(o, &cli)
	}
	if cli.command == .Check && cli.schema.filter == nil {
		check_main(&run, &cli)
	}
	if cli.command == .Fmt {
		fmt_main(&run, &cli)
	}
	if cli.command >= .Schema {
		run_deep(&run, &Inputs{run = &run, cli = &cli}, schema_main)
	}
	text, has := cli.filter.?
	typed, typing := cli.schema.filter.?
	if typing {
		text, has = typed, true
	}
	debug := output_layout(&run)
	debug.opts.pretty = false
	interp := jq.Options {
		hooks      = interpreter_hooks(),
		executable = os.args[0],
		name       = "stury",
		reading    = cli.json_reading,
		debug      = debug,
		file       = text if has && o.from_file else "",
	}
	if dirs, given := cli.lib_dirs.?; given {
		interp.search = dirs[:]
	}
	jq.init(&run.ip, interp)
	switch {
	case has && o.from_file:
		text = program_file(text)
	case !has && cli.command == .Edit:
		usage_error("edit needs a filter")
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
	run.program = {text, cli.var_names[:], cli.var_values[:], cli.positional[:], named, typing}
	explain_filter(&run)
	ready_interpreter(&run)
	if cli.command == .Edit {
		edit_main(&run, &cli)
	}
	if cli.command == .Check {
		check_filter_main(&run, &cli)
	}
	choose_route(&run, text)
	ins := Inputs {
		source  = input_source(o, cli.json_reading),
		parsed  = {line = 1},
		files   = cli.files[:] if len(cli.files) > 0 || cli.walked else STDIN_ONLY,
		slurp   = o.slurp,
		run     = &run,
	}
	explain_route(&run, ins.framing)
	if o.follow {
		catch_stop()
	}
	bind_inputs(&run.ip, &ins)
	init_output(&run.output, &run)
	// The interpreter recurses, and so does printing an answer.
	if o.each {
		run.labels = !o.no_filename && (len(ins.files) > 1 || cli.walked)
		run_deep(&run, &ins, each_files)
		finish(&run, run.output.ret)
	}
	run_deep(&run, &ins, run_filter)
	tell_skipped(&run, bad_tally.skipped)
	code := run_status(&run, ins.failures)
	// A run over a directory may have meant each file on its own. Only a failing run says so, and on stderr.
	if cli.walked && (code == EXIT_INPUT || code == EXIT_USAGE) {
		message.write_stderr("stury: hint: --each runs each file on its own\n")
	}
	finish(&run, code)
}

// jq's exit status: the last input's result, 5 after a text that does not parse, 2 after `failures` files that did not
// open. Under -e, from the last output when the last input had none.
run_status :: proc(run: ^Run, failures: int) -> int {
	code := EXIT_USAGE if failures > 0 else skipped_status(run.output.ret, failures)
	if !run.opts.exit_status {
		return max(code, 0)
	}
	if code == JQ_OK_NO_OUTPUT {
		last := run.output.last_result
		code = JQ_OK_NO_OUTPUT if last < 0 else JQ_OK_NULL_KIND if last == 0 else JQ_OK
	}
	return abs(code)
}

// Report the filter's compile errors as jq does and exit, if there are any. A filter that is no --filter's and is a word
// near a command, and that fails as a filter, is told as that command mistyped.
compile_errors :: proc(text: string, errors: []jq.Error, typed: bool) {
	if len(errors) == 0 {
		return
	}
	count := 0
	for e in errors {
		count += 0 if e.uncounted else 1
		switch e.fault {
		case .Filter, .Empty, .Library:
			message.write_stderr("stury: error: %s\n", e.msg)
		case .Module:
			message.write_stderr("stury: error: %s\n\n", e.msg)
		case .Data_File:
			message.write_stderr("stury: error loading data file %s: %s\n\n", e.path, e.msg)
		}
	}
	if command := "" if typed || errors[0].fault != .Filter else near_command(text); command != "" {
		message.write_stderr("stury: %s is not a command: did you mean stury %s?\n", text, command)
	}
	exit_compile(count)
}

// The command a filter of one word is a letter or two from, as a mistyped `stury chek FILE` gives, or "".
@(private = "file")
near_command :: proc(text: string) -> string {
	for c in transmute([]byte)text {
		if c < 'a' || c > 'z' {
			return ""
		}
	}
	return spell.nearest_word({"check", "fmt", "edit", "diff", "schema"}, text)
}

// jq's count of compile errors, then exit as it does.
exit_compile :: proc(count: int) -> ! {
	message.write_stderr("stury: %d compile error%s\n", count, "" if count == 1 else "s")
	exit_closing_stdout(EXIT_COMPILE)
}

// Compile the filter with the command line's variables and $ARGS, before the interpreter first runs, or exit as jq
// does when it does not compile.
ready_interpreter :: proc(run: ^Run) {
	names, values, positional := run.program.names, run.program.values, run.program.positional
	named := core.new_object()
	vars := make([]jq.Var, len(names))
	for name, i in names {
		vars[i] = {name, values[i]}
		if i < run.program.named {
			core.object_put(named, name, values[i])
		}
	}
	args := core.new_object()
	listed := core.new_array()
	append(&listed.items, ..positional)
	core.object_put(args, "positional", listed)
	core.object_put(args, "named", named)
	prog, errors := jq.compile(&run.ip, run.program.text, vars, args)
	compile_errors(run.program.text, errors, run.program.typed)
	run.prog, run.shape = prog, jq.shape(prog)
}

// The interpreter's way to the system: the command line's inputs are bound later (`bind_inputs`).
interpreter_hooks :: proc() -> jq.Hooks {
	return {
		messages = hold_message,
		environ = proc(_: rawptr, allocator := context.allocator) -> ([]string, string) {
			vars, err := os.environ(allocator)
			if err != nil {
				return nil, message.build("%v", err, allocator = allocator)
			}
			return vars, ""
		},
		load_file = load_file,
		path_kind = path_kind,
		real_path = real_path,
		home = home_dir,
		now = proc(_: rawptr) -> f64 {return f64(time.time_to_unix_nano(time.now())) / 1e9},
		random = proc(_: rawptr, buf: []byte) {crypto.rand_bytes(buf)},
	}
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
