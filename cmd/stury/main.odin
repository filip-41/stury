package main

// The stury command line: a jq filter over JSON, NDJSON, JSON text sequences or JSONC files.
//
//	stury [OPTIONS] [FILTER] [FILE...]
//	stury check [--from format|--seq] [--strict-limits] [FILE...]
//	stury fmt [--from format] [--to format] [--in-place|--check] [--indent n|--tab] [--max-depth n] [FILE...]
//
// FILTER is a jq program, and the output is what jq 1.8 prints for it. The options are listed in HELP_OPTIONS
// (options.odin). With no FILE it reads stdin, and with no FILTER it runs `.` unless stdin and stdout are both a
// terminal. The files are read as jq reads them, one stream, and a fault gets jq's message (input.odin). Texts one
// per line are read in parallel with or without `--from ndjson`, which says they are.
//
// A filter that is a path (`json.parse_path`'s jq subset) with at most one `[]` is answered by the path scan,
// which reads only what it needs (a `[]`'s outputs settled as jq's in `iterate_root_pieces`, root_spine.odin
// and root_pieces.odin). Any other filter, and a path whose step does not apply to what it reaches, runs on
// the jq interpreter (package `jq`). `check` (or `validate`) only validates the input, as `.` reads it
// (check.odin), and `fmt` reads it and writes it back in the printer's layout, or in the `--to` format (fmt.odin).
//
// The exit codes are jq's: 2 for a usage or file error, 3 for a filter that does not compile, 5 for invalid input or
// an error the filter raises. Under `-e`, 1 when the last output is false or null and 4 when there is none. `fmt
// --check` adds 1: a file that is not already formatted.
//
// Where things live in cmd/stury:
//
//	options.odin                     the command line
//	formats.odin                     the formats --from reads and --to writes
//	input.odin, input_stream.odin    reading files and stdin as jq does, whole or in line windows
//	input_csv.odin                   --from csv and tsv input: each record after the header as an object
//	scan_cells.odin                  column-only filters on --from csv and tsv input, answered from the cells
//	scan_inputs.odin                 the path scan over the input stream
//	record_scan.odin                 a file's one-per-line records scanned on the batch pool
//	root_pieces.odin,
//	root_spine.odin                  a large root array built, printed or scanned in pieces on the pool
//	filter.odin                      the jq interpreter over each input
//	print.odin                       output as jq prints it, buffered in `Run.out`
//	output_cells.odin                --to csv and tsv output
//	pool.odin                        the batch pool and its claims
//	check.odin                       `stury check`
//	fmt.odin                         `stury fmt`
//	stream_fault.odin                --stream for a text that does not parse
//	platform_posix.odin,
//	platform_windows.odin            the calls into the system, one file per platform
//	jq/                              the jq interpreter (package `jq`)
//	regex/                           the Oniguruma-compatible matcher behind `test`, `match` and `sub`
//	test/                            smoke.sh, jq_suite.py with cli.tsv, jq-1.8.2/ and modules/, and the
//	                                 jq_diff.py and regex_diff.py comparisons with jq

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import host "../../host"
import json "../../json"
import "jq"

EXIT_USAGE :: 2
EXIT_COMPILE :: 3
EXIT_INPUT :: 5

// Output is held here and written once it passes FLUSH_AT bytes, and at exit.
FLUSH_AT :: 1 << 20

Select :: struct {
	op:      jq.Op,
	literal: jq.Value,
}

// A pool thread works on a shallow copy of the Run (`run^`): the copy shares everything the Run points to (the
// options, the paths' steps, the pool, the interpreter's program and values) and owns only `out`, a buffer of
// its own, with `held` set.
Run :: struct {
	opts:        Opts,
	// paths[0] is `req`'s path, scanned `per_element` for jq-shaped output. paths[1], when `tried`, is the same path
	// without `per_element`, scanned first (`scan_outputs`).
	paths:       [2]json.Path,
	tried:       bool,
	// The step of its first `[]`, -1 when it has none.
	any_at:      int,
	req:         json.Request({.Path}),
	pool:        host.Batch_Pool,
	pool_width:  int, // the workers `pool` was started for, 0 before it is
	scanning:    bool, // the filter is a path the scan answers
	selected:    ^Selected, // while `select_cell` runs the filter: the record each output prints
	columns:     ^Columns, // set when `scan_cells` answers a column-only filter on --from csv or tsv
	table:       ^Table, // --to csv or tsv output table (nil otherwise)
	rows_begun:  bool, // a record has been written, so later records are not at the output's start
	// select(P op LITERAL): the scan answers P, and a record is printed when its answer compares so. `op` is .None
	// for any other filter.
	select:      Select,
	prog:        ^jq.Node, // nil until `ready_interpreter`
	// The filter and the command line's variables, which `ready_interpreter` parses, checks and binds.
	program:     struct {
		text:               string,
		names:              []string,
		values, positional: []jq.Value,
		named:              int, // the first `named` of names are $ARGS.named
	},
	home_module: bool, // `~/.jq`, or what stands for it, is a module every filter includes
	colors:      [8]string, // when opts.color, jq's colours (DEFAULT_COLORS) as $JQ_COLORS sets them
	ip:          jq.Interp,
	out:         [dynamic]byte,
	held:        bool, // a pool thread's copy, whose output the caller writes
	explain:     Explain,
	silent:      bool, // fmt --check and --in-place: the output stays in `out` for the caller
	name_faults: bool, // fmt: a parse fault names its file
	verbatim:    bool, // fmt between JSON-like formats: each value is written from its source text
	faulted:     bool, // a held copy met an answer it cannot print: its caller leaves that text to the main thread, which reports it
	spill:       jq.Spill, // `spill_out`, for a layout that is written into `out`
	unopened:    bool, // a file did not open or read, which jq's exit status says whatever comes after it
	// While the filter runs on a root `build_root_pieces` built: that root and its spine's array, each with
	// its text, which an output that is one of them is printed from (`source_text`).
	pieces_root: struct {
		root, items:      rawptr,
		text, items_text: []byte,
	},
	ret:         int, // jq's: what the last input came to, a JQ_OK result or an exit status
	last_result: int, // jq's: -1 before any output, else whether the last input with outputs ended truthy
	halted:      bool,
	// The input being read, for messages, and its bytes, which an error's line and column count in.
	name:        string,
	whole:       []byte,
}

main :: proc() {
	// Before any thread but this one runs.
	jq.set_origin()
	run: Run
	run.opts.indent = 2
	run.ret, run.last_result = JQ_OK_NO_OUTPUT, -1
	cli := parse_args(&run.opts, command_args()[1:])
	validating := cli.validating
	run.explain.on = run.opts.explain
	set_colors(&run, cli)
	o := &run.opts
	refuse_format_clashes(o, &cli)
	if cli.formatting {
		fmt_main(&run, &cli)
	}
	switch {
	case o.in_place || o.check:
		usage_error("%s is fmt's: a filter run has no use for it", "--in-place" if o.in_place else "--check")
	case o.stream && validating:
		usage_error("--stream makes jq's events of each input; check only judges it")
	case o.strict_limits && !validating:
		usage_error("--strict-limits is check's: a filter reads numbers as far as they can be held")
	case o.explain && validating:
		usage_error("--explain reports a filter's route: check has no filter")
	case o.raw_input && validating:
		usage_error("check reads JSON texts, not -R's lines")
	}
	run.req.dialect = .Jsonc if o.from == .Jsonc else .Json
	run.req.limits = jq.lifted
	names := cli.files[:] if len(cli.files) > 0 else STDIN_ONLY
	if validating {
		if len(cli.files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
			usage(EXIT_USAGE, true) // as stury with no filter, rather than wait on the keyboard
		}
		failures := check_files(&run, names)
		finish(&run, EXIT_USAGE if failures > 0 else 0)
	}

	if dirs, given := cli.lib_dirs.?; given {
		run.ip.search_list = dirs[:]
	}
	run.ip.load_file = load_file
	run.ip.debug_layout = output_layout(&run)
	run.ip.debug_layout.pretty = false
	text, has := cli.filter.?
	switch {
	case has && o.from_file:
		text = program_file(&run, text)
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
		append(&cli.var_values, BUILD_CONFIGURATION)
	}
	// Choose who answers the filter: the path scan when it is a path with at most one `[]` and no option needs the
	// interpreter. The interpreter otherwise, readied here. `~/.jq` is included into every filter, a path too: it is
	// loaded first, as jq fails a run on one that is bad, and a `select` it redefines is not the scan's.
	run.program = {text, cli.var_names[:], cli.var_values[:], cli.positional[:], named}
	explain_filter(&run)
	run.home_module = jq.home_module(&run.ip)
	if run.home_module {
		ready_interpreter(&run)
	}
	choose_scan(&run, text)
	choose_columns(&run, text, len(names))
	if !run.scanning && (run.columns == nil || run.columns.selecting) {
		ready_interpreter(&run)
	}
	explain_route(&run)
	ins: Inputs
	inputs_init(&ins, &run, names)
	// A pipe is read as it comes, but by -s, which needs it all, and --from jsonc, whose faults count lines in it whole.
	ins.may_stream = !o.slurp && o.from != .Jsonc
	bind_inputs(&run, &ins)
	// Here, not in the interpreter's arena, which each input empties.
	reserve(&run.out, FLUSH_AT * 2)
	if writes_cells(o) {
		run.table = table_make(o)
	}
	run.spill = {at = FLUSH_AT, flush = spill_out, data = &run}
	reserve(&run.ip.messages, 1 << 12)
	if run.columns != nil {
		scan_cells(&run, &ins)
	} else if run.scanning && jq.lifted.max_depth <= json.MAX_DEPTH {
		scan_inputs(&run, &ins)
	} else {
		// The interpreter recurses, and so does printing an answer: past MAX_DEPTH, the scan's too.
		run_deep(&run, &ins, scan_inputs if run.scanning else run_filter)
	}
	abandon_reader(&ins)
	// jq's exit status: the last input's result, 5 after a text that does not parse, 2 after a file that did not
	// open. Under -e, from the last output when the last input had none.
	if ins.failures > 0 {
		run.ret = EXIT_USAGE
	}
	code := run.ret
	if o.exit_status {
		if code == JQ_OK_NO_OUTPUT {
			code = JQ_OK_NO_OUTPUT if run.last_result < 0 else JQ_OK_NULL_KIND if run.last_result == 0 else JQ_OK
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
		fmt.eprintf("stury: error: %s\n", jq.locate(text, e))
	}
	exit_compile(len(errors))
}

// jq's count of compile errors, then exit as it does.
exit_compile :: proc(count: int) -> ! {
	fmt.eprintf("stury: %d compile error%s\n", count, "" if count == 1 else "s")
	os.exit(EXIT_COMPILE)
}

// The filter, parsed by jq's grammar, or exit as jq does on a syntax error.
parse_program :: proc(text: string) -> jq.Program {
	parsed, errors := jq.parse(text)
	compile_errors(text, errors)
	if parsed.body == nil {
		fmt.eprintln(`stury: error: Top-level program not given (try ".")`)
		exit_compile(1)
	}
	return parsed
}

// The modules the filter imports, and `~/.jq`, loaded, or exit as jq does when one cannot be.
link_program :: proc(run: ^Run, parsed: jq.Program) -> (linked: jq.Linked) {
	if len(parsed.deps) == 0 && !run.home_module {
		return
	}
	linked = jq.link(&run.ip, parsed.deps, jq.program_origin(&run.ip))
	if linked.errors > 0 {
		fmt.eprint(linked.messages)
		exit_compile(linked.errors)
	}
	return
}

// Parse and check the filter and bind its globals, once, before the interpreter first runs. A path the
// scan answers leaves this until an answer needs jq's rules, which may be never: jq's parser and the
// prelude it checks against are most of a short run's start-up. Such a path is in jq's path subset, which
// parses as itself and names nothing that could be undefined, so doing this late reports nothing doing it
// first would have.
ready_interpreter :: proc(run: ^Run) {
	if run.prog != nil {
		return
	}
	parsed := parse_program(run.program.text)
	linked := link_program(run, parsed)
	prog, errors, prelude := jq.check(parsed.body, run.program.names, linked)
	compile_errors(run.program.text, errors)
	run.prog = prog
	if len(linked.imports) == 0 && prelude == nil {
		bind_cli_vars(run)
		return
	}
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

// Whether the path scan answers the filter `text`, and with what path.
choose_scan :: proc(run: ^Run, text: string) {
	run.any_at = -1
	o := run.opts
	if reads_cells(&o) {
		return
	}
	stops := scan_stops(&o)
	if stops != {} && !explain_why(run, stops) {
		return
	}
	@(static) steps: [json.MAX_PATH_STEPS]json.Step
	p, perr := json.parse_path(text, steps[:], make([]u8, len(text)))
	if perr != nil {
		// `select` is the interpreter's under JSONC, whose texts print with their comments.
		jsonc := o.from == .Jsonc
		if jsonc && !explain_why(run, {.Jsonc_Select}) {
			return
		}
		sel: Select
		why: Explain_Whys
		p, sel, why = selected_path(run, text, steps[:])
		explain_why(run, why)
		if why != {} || jsonc || stops != {} {
			return
		}
		run.select = sel
	}
	if stops != {} {
		return
	}
	for s, i in p.steps {
		if _, is_any := s.(json.Any); is_any && run.any_at < 0 {
			run.any_at = i
		}
	}
	run.scanning = true
	run.paths[1] = p
	run.tried = run.any_at == 0 && len(p.steps) > 1 && p.limit == 0
	if run.tried {
		for s in p.steps[1:] {
			if _, is_any := s.(json.Any); is_any {
				run.tried = false
			}
		}
	}
	p.per_element = true
	run.paths[0] = p
	run.req.paths = run.paths[:1]
}

// The path P of the filter `text` when it is `select(P op LITERAL)`, P a path the scan answers with no `[]` and
// LITERAL no array or object, and the comparison; else why not. The filter is checked here, so `select` is known
// to be jq's.
selected_path :: proc(run: ^Run, text: string, steps: []json.Step) -> (p: json.Path, sel: Select, why: Explain_Whys) {
	ready_interpreter(run)
	n := run.prog
	if n.kind != .Call || n.name != "select" || len(n.args) != 1 {
		return {}, {}, {.Not_Path}
	}
	if b, bound := n.native.?; !bound || b.native != jq.native_select {
		return {}, {}, {.Select_Redefined}
	}
	cmp := n.args[0]
	if cmp.kind != .Binary || cmp.op < .Eq || cmp.op > .Ge || cmp.b.kind != .Literal {
		return {}, {}, {.Select_Compare}
	}
	if k := jq.kind(cmp.b.value); k == .Array || k == .Object {
		return {}, {}, {.Select_Compare}
	}
	for x := cmp.a; x.kind != .Identity; x = x.a {
		if x.kind != .Field && x.kind != .Index || x.opt {
			return {}, {}, {.Select_Path}
		}
	}
	path := text[cmp.a.loc.start:cmp.a.loc.end]
	parsed, perr := json.parse_path(path, steps, make([]u8, len(path)))
	if perr != nil || parsed.limit != 0 || len(parsed.steps) == 0 {
		return {}, {}, {.Select_Path}
	}
	return parsed, {cmp.op, cmp.b.value}, {}
}

// `e` in `src`, the text of the file `name`, as `NAME:line:col: Fault` (or `what`, where it says more), with no
// line and column for a fault no byte is at. `lines_before` are the lines of the file before `src`.
fault_in_file :: proc(name: string, src: []byte, e: json.Error, what := "", lines_before := 0) -> string {
	b := strings.builder_make()
	strings.write_string(&b, name)
	if line, col := json.error_position(src, e); line > 0 {
		fmt.sbprintf(&b, ":%d:%d", line + lines_before, col)
	}
	strings.write_string(&b, ": ")
	strings.write_string(&b, what if what != "" else jq.FAULT_TEXT[e.kind])
	return strings.to_string(b)
}

// For the faults whose cure is a flag of stury's own, the line of `src` the fault `e` is at, a caret under its byte,
// and the flag, else "". A trailing comma and a comment are JSONC's (the grammar `jsonc` already reads has neither
// fault), and a nesting past the cap is raised by --max-depth, which the hint asks for only when it was not given.
// The text ends in a newline.
fault_context :: proc(src: []byte, e: json.Error, opts: ^Opts) -> string {
	jsonc := opts.from == .Jsonc
	at := int(e.offset)
	hint: string
	switch {
	case e.kind == .Too_Deep:
		hint = "a larger --max-depth reads it" if opts.max_depth_given else "--max-depth N raises the nesting limit"
	case e.kind != .Bad_Char || at >= len(src) || jsonc:
		return ""
	case src[at] == '/' && at + 1 < len(src) && (src[at + 1] == '/' || src[at + 1] == '*'):
		hint = "--from jsonc reads comments"
	case src[at] == ']' || src[at] == '}':
		before := at
		for before > 0 && jq.is_space(src[before - 1]) {
			before -= 1
		}
		if before == 0 || src[before - 1] != ',' {
			return ""
		}
		hint = "--from jsonc reads a trailing comma"
	case:
		return ""
	}
	at = min(at, len(src) - 1)
	// The line, cut to a screenful around the byte.
	first, last := at, at
	for first > 0 && src[first - 1] != '\n' && at - first < 40 {
		first -= 1
	}
	for last < len(src) && src[last] != '\n' && src[last] != '\r' && last - at < 40 {
		last += 1
	}
	pad := make([]byte, at - first, context.temp_allocator)
	for i in 0 ..< len(pad) {
		pad[i] = '\t' if src[first + i] == '\t' else ' '
	}
	return fmt.aprintf("%s\n%s^\n(%s)\n", src[first:last], pad, hint)
}

// `e` as `fault_in_file` tells it, then exit as jq does for input it cannot read.
fail_input :: proc(run: ^Run, e: json.Error, what := "") -> ! {
	flush_some(run, force = true)
	fmt.eprintf("stury: error: %s\n%s", fault_in_file(run.name, run.whole, e, what), fault_context(run.whole, e, &run.opts))
	finish(run, EXIT_USAGE if run.unopened else EXIT_INPUT)
}

finish :: proc(run: ^Run, code: int) -> ! {
	code := code
	if !write_held_rows(run) {
		code = EXIT_INPUT
	}
	flush_some(run, force = true)
	check_output()
	explain_end(run)
	os.exit(code)
}
