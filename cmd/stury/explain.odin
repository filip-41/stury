package main

// --explain: the route a filter takes and why, on stderr, while the filter runs as it would without the flag.
//
// Every line is `stury: explain: KEY: VALUE` and holds nothing that varies between runs (no counts of workers,
// timings or file names), so a test can compare the report byte for byte. The reasons are recorded by the code
// that takes each decision (`choose_scan`, `choose_columns`, `scan_inputs`), not derived again here, so they
// are the run's own.

import "core:fmt"
import "core:strings"
import json "../../json"

Route :: enum u8 {
	Interpreter,
	Path_Scan,
	Csv_Columns,
}

@(rodata)
ROUTE_TEXT := [Route]string {
	.Interpreter = "interpreter",
	.Path_Scan   = "path scan",
	.Csv_Columns = "csv columns",
}

// Why the interpreter answers a filter. The report prints every reason that holds, in this order.
Why :: enum u8 {
	// Options that keep a filter from the scan and from the columns.
	Null_Input,
	Slurp,
	Sort_Keys,
	Raw_Input,
	Seq,
	Stream,
	Exit_Status,
	Raw0,
	Ascii,
	Color,
	Cells_Out,
	// What the filter is.
	Not_Path,
	Jsonc_Select,
	Select_Redefined,
	Select_Compare,
	Select_Path,
	Imports,
	Not_Columns,
	Home_Module,
	Dot_To_Cells,
	Object_Key,
	Object_Member,
	Select_Columns,
	// The output's layout, for columns.
	Layout,
	Grow_Header,
	Several_Files,
}

Whys :: bit_set[Why;u32]

@(rodata)
WHY_TEXT := [Why]string {
	.Null_Input       = "--null-input reads no input",
	.Slurp            = "--slurp needs the input whole",
	.Sort_Keys        = "-S sorts keys on output",
	.Raw_Input        = "-R reads lines as strings",
	.Seq              = "--seq writes record separators",
	.Stream           = "--stream reads jq's events",
	.Exit_Status      = "-e reads each output",
	.Raw0             = "--raw-output0 writes NUL",
	.Ascii            = "-a writes ASCII only",
	.Color            = "colour output is on",
	.Cells_Out        = "--to csv|tsv writes each output as a record",
	.Not_Path         = "the filter is not a path and not select(PATH op LITERAL)",
	.Jsonc_Select     = "--from jsonc scans plain paths only",
	.Select_Redefined = "select is redefined",
	.Select_Compare   = "select(F): F is not PATH op LITERAL with a scalar LITERAL",
	.Select_Path      = "select(F): PATH is not a path the scan answers, without []",
	.Imports          = "the filter imports a module",
	.Not_Columns      = "--from csv|tsv: the filter does not name only columns",
	.Home_Module      = "~/.jq is included into the filter",
	.Dot_To_Cells     = "`.` under --to csv|tsv has no columns of its own",
	.Object_Key       = "an object key is not a constant, or repeats",
	.Object_Member    = "an object member is not a column of the input",
	.Select_Columns   = "select(F): F reads more than named columns",
	.Layout           = "-c is absent: the interpreter lays the output out",
	.Grow_Header      = "--grow-header writes a header of every key",
	.Several_Files    = "select to csv|tsv over several files",
}

// The decisions made while the run goes on, each reported once.
Runtime :: enum u8 {
	Root_Pieces,
	Interpreter,
	Step,
	Line_Records,
	Csv_Pieces,
}

Explain :: struct {
	on:    bool,
	whys:  Whys,
	texts: int, // the inputs read so far, which a `text N` line numbers
	said:  bit_set[Runtime;u8],
}

// The options that keep a filter from the path scan, as `choose_scan` reads them.
scan_stops :: proc(o: ^Opts) -> (stops: Whys) {
	if o.null_input {stops += {.Null_Input}}
	if o.slurp {stops += {.Slurp}}
	if o.sort_keys {stops += {.Sort_Keys}}
	if o.raw_input {stops += {.Raw_Input}}
	if o.seq {stops += {.Seq}}
	if o.stream {stops += {.Stream}}
	if o.exit_status {stops += {.Exit_Status}}
	if o.raw0 {stops += {.Raw0}}
	if o.ascii {stops += {.Ascii}}
	if writes_cells(o) {stops += {.Cells_Out}}
	return
}

// The options that keep a filter from the column route, as `choose_columns` reads them.
column_stops :: proc(o: ^Opts) -> (stops: Whys) {
	if o.null_input {stops += {.Null_Input}}
	if o.slurp {stops += {.Slurp}}
	if o.exit_status {stops += {.Exit_Status}}
	if o.raw0 {stops += {.Raw0}}
	if o.ascii {stops += {.Ascii}}
	if o.color {stops += {.Color}}
	return
}

explain_why :: #force_inline proc(run: ^Run, whys: Whys) {
	run.explain.whys += whys
}

@(private = "file")
explain_line :: proc(format: string, args: ..any) {
	fmt.eprintf("stury: explain: %s\n", fmt.tprintf(format, ..args))
}

// The filter, before anything can refuse it: a filter that does not compile still shows what was run.
explain_filter :: proc(run: ^Run) {
	if run.explain.on {
		explain_line("filter: %q", strings.trim_space(run.program.text))
	}
}

// The route, its reasons and what the route does with the filter, once the route is chosen.
explain_route :: proc(run: ^Run) {
	e := &run.explain
	if !e.on {
		return
	}
	route := Route.Csv_Columns if run.columns != nil else .Path_Scan if run.scanning else .Interpreter
	explain_line("route: %s", ROUTE_TEXT[route])
	if route == .Interpreter {
		for why in Why {
			if why in e.whys {
				explain_line("why: %s", WHY_TEXT[why])
			}
		}
		return
	}
	switch {
	case run.columns != nil && run.columns.selecting:
		explain_line("path: select(F): F runs on an object of the columns it reads, and a kept record is printed from its cells")
	case run.columns != nil:
		explain_line("path: the columns are read from each record's cells, and no object is built")
	case run.select.op != .None:
		explain_line("path: select(PATH op LITERAL): the scan answers PATH, and a kept text is printed from the source")
	case run.any_at >= 0:
		explain_line("path: one answer per element of each []")
	case:
		explain_line("path: one answer per input")
	}
}

// A decision about the input being read, once of its kind.
explain_text :: proc(run: ^Run, kind: Runtime, what: string) {
	if run.explain.on && kind not_in run.explain.said {
		run.explain.said += {kind}
		explain_line("text %d: %s", run.explain.texts, what)
	}
}

// A decision about how a file is read, once of its kind.
explain_note :: proc(run: ^Run, kind: Runtime, what: string) {
	if run.explain.on && kind not_in run.explain.said {
		run.explain.said += {kind}
		explain_line("note: %s", what)
	}
}

// The records the pool answered, which later `text N` lines count as inputs read.
explain_records :: proc(run: ^Run, answered: []byte) {
	if !run.explain.on {
		return
	}
	it := json.records(answered, .NDJSON)
	for _ in json.next_record(&it) {
		run.explain.texts += 1
	}
}
