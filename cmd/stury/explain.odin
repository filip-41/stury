package main

// --explain writes `stury: explain: KEY: FACTS` lines to stderr (docs/cli.md lists the keys). The code that takes
// each decision records its reason here, so the report never derives one again.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import core_pkg "../../core"
import json "../../json"
import "jq"

Explain_Why :: enum u8 {
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
	Not_Path,
	Dialect_Select,
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
	Layout,
	Grow_Header,
	Several_Files,
	Own_Spelling,
}

Explain_Whys :: bit_set[Explain_Why]

Explain_Fallback :: enum u8 {
	Step_Kind,
	Comment_Slash,
	Scan_Limit,
	Bad_Text,
}

Explain_Piece :: enum u8 {
	Root,
	Lines,
	Csv,
}

// Pool threads add to these, atomically.
Explain_Bytes :: struct {
	input, output: int,
}

Explain :: struct {
	on:          bool,
	routed:      bool,
	whys:        Explain_Whys,
	began, ran:  time.Tick, // the filter was known; the route was chosen
	scanned:     int,
	interpreted: int,
	files:       int,
	pieces:      bit_set[Explain_Piece],
	engines:     bool,
	fallback:    struct {
		text: int, // the first text the scan handed back, 1 for the first; 0 when none
		why:  Explain_Fallback,
		rest: bool,
	},
	bytes:       Explain_Bytes,
}

// nil without --explain.
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
	if json.own_spelling(FORMATS[o.from].source) {stops += {.Own_Spelling}}
	return
}

column_stops :: proc(o: ^Opts) -> (stops: Explain_Whys) {
	if o.null_input {stops += {.Null_Input}}
	if o.slurp {stops += {.Slurp}}
	if o.exit_status {stops += {.Exit_Status}}
	if o.raw0 {stops += {.Raw0}}
	if o.ascii {stops += {.Ascii}}
	if o.color {stops += {.Color}}
	return
}

// Whether the caller goes on to find the other reasons: only --explain wants them all.
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

@(private = "file")
token :: proc(v: $T) -> string {
	return strings.to_lower(fmt.tprint(v), context.temp_allocator)
}

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

// Before the filter is compiled, so one that fails still shows.
explain_filter :: proc(run: ^Run) {
	if run.explain.on {
		run.explain.began = time.tick_now()
		explain_line("program: %q", strings.trim_space(run.program.text))
	}
}

explain_route :: proc(run: ^Run) {
	e := &run.explain
	if !e.on {
		return
	}
	o := &run.opts
	if reads_cells(o) {
		explain_line("input: format=%s", token(o.from))
	} else {
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

@(private = "file")
records_of :: proc(o: ^Opts) -> string {
	switch {
	case o.null_input:
		return "none"
	case FORMATS[o.from].framing == .Lines:
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
		core_pkg.write_step(strings.to_writer(&b), s)
	}
	return strings.to_string(b)
}

// At the first text: the engine depends on whether the root is an object.
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
	engine := fmt.tprintf("%s why=%s", token(route.class), token(route.why))
	if e, refused := err.?; refused {
		engine = fmt.tprintf("refused why=%s", token(e.kind))
	}
	explain_line("engine: %s per_element=%s engine=%s", spell(paths[0].steps), yes(paths[0].per_element), engine)
}

explain_demand :: proc(run: ^Run, d: jq.Entry_Demand) {
	if run.explain.on {
		explain_line("demand: head=%d tail=%d counted=%s", d.head, d.tail, yes(d.counted))
	}
}

// A `.Type_Mismatch` answer sends the text to the interpreter (`print_answers`).
explain_answered :: proc(run: ^Run, answers: []json.Answer, rest: bool) {
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

explain_fallback :: proc(run: ^Run, why: Explain_Fallback, rest: bool) {
	e := &run.explain
	if e.on && e.fallback.text == 0 {
		e.fallback = {e.scanned + e.interpreted + 1, why, rest}
	}
}

explain_interpreted :: proc(run: ^Run) {
	if run.explain.on {
		run.explain.interpreted += 1
	}
}

explain_records :: proc(run: ^Run, answered: []byte) {
	if !run.explain.on {
		return
	}
	run.explain.pieces += {.Lines}
	it := json.records(answered, {framing = .NDJSON})
	for _ in json.next_record(&it) {
		run.explain.scanned += 1
	}
}

// `interpreted` is the count before the root was read: the text was the scan's unless it grew.
explain_root :: proc(run: ^Run, interpreted: int) {
	e := &run.explain
	if e.on {
		e.pieces += {.Root}
		e.scanned += int(e.interpreted == interpreted)
	}
}

explain_piece :: proc(run: ^Run, piece: Explain_Piece) {
	if run.explain.on {
		run.explain.pieces += {piece}
	}
}

explain_file :: proc(run: ^Run) {
	if run.explain.on {
		run.explain.files += 1
	}
}

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
