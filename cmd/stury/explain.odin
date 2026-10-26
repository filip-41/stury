package main

// --explain: the plan a filter runs under and what the run did, on stderr, while the filter runs as it would without
// the flag.
//
// Every line is `stury: explain: KEY: FACTS`, the facts `key=value` tokens of the code's own enum names, and each
// token is explained in docs/cli.md. The plan block (program, input, route, path or columns or refused, compile_time)
// is written once the route is chosen, before any input is read; engine and demand follow when the first text and the
// first large root are met, as they depend on the bytes. The run block (run, fallback, run_time, cost) is written when
// the run ends, by `finish`. The reasons are recorded by the code that takes each decision (`choose_scan`,
// `choose_columns`, `scan_inputs`), not derived again here, so they are the run's own.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import json "../../json"
import "jq"

// Why the interpreter answers a filter. The plan block lists every reason that holds, in this order.
Explain_Why :: enum u8 {
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

Explain_Whys :: bit_set[Explain_Why]

// Why the scan handed a text back to the interpreter.
Explain_Fallback :: enum u8 {
	Step_Kind, // a step met a value of another kind
	Jsonc_Slash, // --from jsonc: the text holds a `/`, which the interpreter prints with its comments
	Scan_Limit, // the scan refused the text at one of its limits
	Bad_Text, // the text does not parse as the scan reads it
}

// What the batch pool read in pieces.
Explain_Piece :: enum u8 {
	Root, // a large root array
	Lines, // a file of one record per line
	Csv, // a CSV file's records
}

// The bytes the run took in and wrote out. Pool threads add to them, so they are atomic.
Explain_Bytes :: struct {
	input, output: int,
}

Explain :: struct {
	on:          bool,
	routed:      bool, // the plan block is written
	whys:        Explain_Whys,
	began, ran:  time.Tick, // the filter was known; the route was chosen
	scanned:     int, // texts the scan answered
	interpreted: int, // texts the interpreter ran on
	files:       int, // CSV files opened by the columns route
	pieces:      bit_set[Explain_Piece],
	engines:     bool, // the engine lines are written
	fallback:    struct {
		text: int, // the first text the scan handed back, 1 for the first; 0 when none
		why:  Explain_Fallback,
		rest: bool, // the interpreter took the texts after it too
	},
	bytes:       Explain_Bytes,
}

// Where the threads add the bytes of input and output, set once the route is chosen: nil without --explain.
@(private = "file")
counted: ^Explain_Bytes

explain_input :: proc(n: int) {
	if counted != nil {
		sync.atomic_add(&counted.input, n)
	}
}

explain_output :: proc(n: int) {
	if counted != nil {
		sync.atomic_add(&counted.output, n)
	}
}

// The options that keep a filter from the path scan, as `choose_scan` reads them.
scan_stops :: proc(o: ^Opts) -> (stops: Explain_Whys) {
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
column_stops :: proc(o: ^Opts) -> (stops: Explain_Whys) {
	if o.null_input {stops += {.Null_Input}}
	if o.slurp {stops += {.Slurp}}
	if o.exit_status {stops += {.Exit_Status}}
	if o.raw0 {stops += {.Raw0}}
	if o.ascii {stops += {.Ascii}}
	if o.color {stops += {.Color}}
	return
}

// Records `whys` under --explain, which then wants every reason that holds: true there, and the caller goes on
// to find the others. False otherwise, and the caller stops at the first.
explain_why :: proc(run: ^Run, whys: Explain_Whys) -> (more: bool) {
	if run.explain.on {
		run.explain.whys += whys
	}
	return run.explain.on
}

@(private = "file")
explain_line :: proc(format: string, args: ..any) {
	fmt.eprint("stury: explain: ")
	fmt.eprintfln(format, ..args)
}

// An enum value as its name in lower case: the token the report gives it.
@(private = "file")
token :: proc(v: $T) -> string {
	return strings.to_lower(fmt.tprint(v), context.temp_allocator)
}

// The members of `set` as tokens, comma-joined in declaration order, or `none`.
@(private = "file")
tokens :: proc(set: bit_set[$E]) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in E {
		if e in set {
			strings.write_string(&b, "," if strings.builder_len(b) > 0 else "")
			strings.write_string(&b, token(e))
		}
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}

@(private = "file")
yes :: proc(v: bool) -> string {
	return "yes" if v else "no"
}

// The filter, before anything can refuse it: a filter that does not compile still shows what was run.
explain_filter :: proc(run: ^Run) {
	if run.explain.on {
		run.explain.began = time.tick_now()
		explain_line("program: %q", strings.trim_space(run.program.text))
	}
}

// The plan block, once the route is chosen.
explain_route :: proc(run: ^Run) {
	e := &run.explain
	if !e.on {
		return
	}
	o := &run.opts
	if reads_cells(o) {
		explain_line("input: format=%s", token(o.from))
	} else {
		// The library's JSON default is the last of a repeated key.
		dup := run.req.duplicates
		explain_line("input: format=%s dialect=%s records=%s duplicates=%s", token(o.from), token(run.req.dialect), records_of(o), token(.Last if dup == .Default else dup))
	}
	switch {
	case run.columns != nil:
		explain_line("route: columns")
		explain_columns(run.columns)
	case run.scanning:
		explain_line("route: path_scan")
		explain_path(run)
	case:
		explain_line("route: interpreter")
		explain_line("refused: %s", tokens(e.whys))
	}
	explain_line("compile_time: %dus", i64(time.duration_microseconds(time.tick_since(e.began))))
	e.routed, e.ran = true, time.tick_now()
	counted = &e.bytes
}

// How the input is cut into texts, as the options say.
@(private = "file")
records_of :: proc(o: ^Opts) -> string {
	switch {
	case o.null_input:
		return "none"
	case o.from == .Ndjson:
		return "ndjson"
	case o.seq:
		return "seq"
	case o.raw_input:
		return "raw_lines"
	}
	return "whole"
}

@(private = "file")
explain_columns :: proc(cols: ^Columns) {
	read := cols.watch if cols.selecting else cols.names
	shape := "all" if cols.all else "object" if cols.object else "array" if cols.array else "column"
	explain_line("columns: read=%s shape=%s selecting=%s", strings.join(read, ",", context.temp_allocator) if len(read) > 0 else "*", shape, yes(cols.selecting))
}

@(private = "file")
explain_path :: proc(run: ^Run) {
	sel := "none"
	if run.select.op != .None {
		sel = fmt.tprintf("%s literal=%s", token(run.select.op), jq.to_json(run.select.literal))
	}
	any_at := fmt.tprint(run.any_at) if run.any_at >= 0 else "none"
	explain_line("path: %s any_at=%s select=%s limit=%d tried=%s", spell(run.paths[1].steps), any_at, sel, run.paths[1].limit, yes(run.tried))
}

// A path's steps in jq's spelling: `.a`, `."a-b"`, `[0]`, `[]`.
@(private = "file")
spell :: proc(steps: []json.Step) -> string {
	if len(steps) == 0 {
		return "."
	}
	b := strings.builder_make(context.temp_allocator)
	if _, named := steps[0].(json.Name); !named {
		strings.write_byte(&b, '.')
	}
	for s in steps {
		switch v in s {
		case json.Name:
			bare := len(v) > 0 && !('0' <= v[0] && v[0] <= '9')
			for c in transmute([]byte)string(v) {
				bare &&= c == '_' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
			}
			fmt.sbprintf(&b, ".%s" if bare else ".%q", string(v))
		case json.Index:
			fmt.sbprintf(&b, "[%d]", i64(v))
		case json.Any:
			strings.write_string(&b, "[]")
		}
	}
	return strings.to_string(b)
}

// What `json.route_of` says of each path the scan runs, over the first text: the engine an answer comes from
// depends on the root being an object, which only the bytes show. Written once.
explain_engines :: proc(run: ^Run, src: []byte) {
	e := &run.explain
	if !e.on || e.engines {
		return
	}
	e.engines = true
	say_engine(run, src, run.paths[:1])
	if run.tried {
		say_engine(run, src, run.paths[1:])
	}
}

@(private = "file")
say_engine :: proc(run: ^Run, src: []byte, paths: []json.Path) {
	route, err := json.route_of(src, paths, 0, run.req.read)
	engine: string
	switch {
	case err != nil:
		engine = fmt.tprintf("refused why=%s", token(err.?.kind))
	case route == .Matcher || route == .Tape:
		engine = token(route)
	case:
		engine = fmt.tprintf("automaton why=%s", token(route))
	}
	explain_line("engine: %s per_element=%s engine=%s", spell(paths[0].steps), yes(paths[0].per_element), engine)
}

// The entries of a large root array the filter reads (`jq.entry_demand`), when the root is built in pieces.
explain_demand :: proc(run: ^Run, d: jq.Entry_Demand) {
	if run.explain.on {
		explain_line("demand: head=%d tail=%d counted=%s", d.head, d.tail, yes(d.counted))
	}
}

// The scan answered a text whose `answers` are in: the interpreter runs on it when a step met a value of another
// kind (`print_answers` hands it to `run_text`), and takes the texts after it too when `rest`.
explain_answered :: proc(run: ^Run, answers: []json.Path_Answer, rest: bool) {
	if !run.explain.on {
		return
	}
	for a in answers {
		if a.outcome == .Type_Mismatch {
			explain_fallback(run, .Step_Kind, rest)
			return
		}
	}
	run.explain.scanned += 1
}

// The scan hands the text it is at back to the interpreter, the first time with its reason.
explain_fallback :: proc(run: ^Run, why: Explain_Fallback, rest: bool) {
	e := &run.explain
	if e.on && e.fallback.text == 0 {
		e.fallback = {e.scanned + e.interpreted + 1, why, rest}
	}
}

// The interpreter runs on a text.
explain_interpreted :: proc(run: ^Run) {
	if run.explain.on {
		run.explain.interpreted += 1
	}
}

// The batch pool answered `answers`, one record per line: each is a text the scan answered.
explain_records :: proc(run: ^Run, answered: []byte) {
	if !run.explain.on {
		return
	}
	run.explain.pieces += {.Lines}
	it := json.records(answered, .NDJSON)
	for _ in json.next_record(&it) {
		run.explain.scanned += 1
	}
}

// A large root was read in pieces, and `interpreted` is the count before: the text was the scan's unless the
// interpreter ran on it.
explain_root :: proc(run: ^Run, interpreted: int) {
	e := &run.explain
	if e.on {
		e.pieces += {.Root}
		e.scanned += int(e.interpreted == interpreted)
	}
}

// The batch pool read `piece` of the input.
explain_piece :: proc(run: ^Run, piece: Explain_Piece) {
	if run.explain.on {
		run.explain.pieces += {piece}
	}
}

// A CSV file opened by the columns route.
explain_file :: proc(run: ^Run) {
	if run.explain.on {
		run.explain.files += 1
	}
}

// The run block, at the end of the run. A pool thread's copy of the run writes none.
explain_end :: proc(run: ^Run) {
	e := &run.explain
	if !e.on || !e.routed || run.held {
		return
	}
	if run.columns != nil {
		explain_line("run: files=%d pieces=%s workers=%d", e.files, tokens(e.pieces), run.pool_width)
	} else {
		explain_line("run: texts=%d scanned=%d interpreted=%d pieces=%s workers=%d", e.scanned + e.interpreted, e.scanned, e.interpreted, tokens(e.pieces), run.pool_width)
	}
	if f := e.fallback; f.text > 0 {
		explain_line("fallback: text=%d why=%s rest=%s", f.text, token(f.why), yes(f.rest))
	}
	explain_line("run_time: %dus", i64(time.duration_microseconds(time.tick_since(e.ran))))
	explain_line("cost: peak_rss=%d input=%d output=%d", peak_rss(), sync.atomic_load(&e.bytes.input), sync.atomic_load(&e.bytes.output))
}
