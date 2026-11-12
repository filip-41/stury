package main

// --explain writes `stury: explain: KEY: SENTENCE` lines to stderr: how the filter will run before the run, what the
// run did after it. The code that takes each decision records its reason in `Route`, so the report never derives one
// again.

import "core:strings"
import "core:time"
import core "../../core"
import "jq"
import "message"

Explain :: struct {
	on:          bool,
	began, ran:  time.Tick, // the filter was known, the route was chosen
	scanned:     int, // texts the path scan answered
	interpreted: int, // inputs the interpreter ran on
	fallback:    struct {
		text: int, // the first text the scan left to the interpreter, 1 for the first, 0 when none
		why:  Fallback,
	},
	input:       int, // bytes read
	pieces:      int, // pieces answered on the pool's threads
}

// Why a filter builds each input, as `because` says it.
@(rodata, private = "file")
WHY_WORDS := [Route_Why]string {
	.Null_Input       = "-n reads no input",
	.Slurp            = "-s holds the whole input as one array",
	.Sort_Keys        = "-S sorts the keys of every object",
	.Raw_Input        = "-R reads each line as a string",
	.Seq              = "--seq writes a record separator before each output",
	.Stream           = "--stream turns each text into jq's path events",
	.Exit_Status      = "-e looks at each output",
	.Raw0             = "--raw-output0 ends each output with a NUL",
	.Ascii            = "-a writes ASCII only",
	.Cells_Out        = "--to csv or tsv writes each output as a record",
	.Comments_Out     = "--to jsonc prints a value's comments, which reading a path does not keep",
	.Text_Out         = "--to writes each output as a text of its format, which the format's writer makes of a built document",
	.Not_Path         = "the filter is not a path, and not select(PATH op LITERAL)",
	.Dialect_Select   = "--from jsonc reads only a plain path without building, as a text prints with its comments",
	.Select_Redefined = "select is redefined, by the filter or by ~/.jq",
	.Select_Compare   = "select(F): F is not PATH op LITERAL with a scalar LITERAL",
	.Select_Path      = "select(F): its PATH has a [] or is not a path stury reads without building",
	.Not_Columns      = "the filter does not name only columns of the record",
	.Object_Key       = "an object key is not a constant, or repeats",
	.Object_Member    = "an object member is not a column of the input",
	.Select_Columns   = "select(F): F reads more than named columns",
	.No_Header        = "--no-header makes each record an array",
	.Infer            = "--infer reads each cell's kind from its text",
	.Comments_In      = "--comment lines above a record are written with it, which the column route does not hold",
	.Own_Spelling     = "--from json5 would print a path's answer as written ('a', 0x1F), not as JSON",
}

// Why an input that was read by its path was built after all, as `fallback` says it.
@(rodata, private = "file")
FALLBACK_WORDS := [Fallback]string {
	.Step_Kind      = "a step met a value it does not apply to (.a over a number), where jq's rules answer",
	.Bad_Text       = "it does not parse, and the filter run reports the fault",
	.Object_Members = "a [] met an object, whose repeated keys jq gives once",
}

@(private = "file")
explain_line :: proc(format: string, args: ..any) {
	message.write_stderr("stury: explain: %s\n", message.build_temp(format, ..args))
}

// Before the filter is compiled, so one that fails still shows.
explain_filter :: proc(run: ^Run) {
	if run.route.on {
		run.route.began = time.tick_now()
		explain_line("filter: %q", strings.trim_space(run.program.text))
	}
}

// `framing` is the inputs' own. -n reads no input and -R reads lines whatever the framing, as the main loop and
// `next_value` test them first.
explain_route :: proc(run: ^Run, framing: core.Framing) {
	r := &run.route
	if !r.on {
		return
	}
	o := &run.opts
	format := FORMATS[o.from].title
	switch {
	case o.null_input:
		explain_line("input: none")
	case o.raw_input:
		explain_line("input: lines of text, each a string")
	case reads_cells(o):
		explain_line("input: %s, each record %s", format, "an array of its cells" if o.cells_in.no_header else "an object keyed by the header")
	case reads_own(o):
		explain_line("input: %s, each document of a stream", format)
	case:
		texts := "in RFC 7464 records" if framing == .Seq else "one per line" if framing == .Lines else "one after another"
		explain_line("input: %s texts %s, a repeated key keeping its last value", format, texts)
	}
	if cols := r.columns; cols != nil {
		read := message.build_temp("%s %s", "the column" if len(cols.names) == 1 else "only the columns", strings.join(cols.names[:], ", ", context.temp_allocator))
		switch {
		case cols.every:
			explain_line("plan: writes each record's cells as its object, straight from the text")
		case cols.shape == .Select:
			explain_line("plan: reads %s of each record to decide it, and prints a kept record from its text", read)
		case:
			explain_line("plan: reads %s of each record, straight from the text", read)
		}
		explain_line("decides: the bytes read decide the speed, and memory holds one record")
	} else if r.scanning {
		path := spell_path(r.path)
		if r.select.op != .None {
			explain_line("plan: reads only the path %s of each text, and prints the text whole where %s %s %s holds", path, path, op_text(r.select.op), jq.to_json(r.select.literal))
		} else if len(r.path.steps) == 0 {
			explain_line("plan: prints each text whole, without building it")
		} else {
			explain_line("plan: reads only the path %s of each text, without building the values it passes by", path)
		}
		if n, limited := r.path.limit.?; limited {
			explain_line("plan: stops reading a text after its first %s", "answer" if n == 1 else message.build_temp("%d answers", n))
		}
		explain_line("decides: the bytes read decide the speed, and memory holds only the answers")
	} else {
		switch {
		case o.null_input:
			explain_line("plan: runs the filter once, on null")
		case o.slurp:
			explain_line("plan: builds the whole input as one array and runs the filter on it")
		case:
			explain_line("plan: builds each %s whole and runs the filter on it", "record" if reads_cells(o) else "text")
		}
		for why in Route_Why {
			if why in r.whys {
				explain_line("because: %s", WHY_WORDS[why])
			}
		}
		holds := "what the filter makes" if o.null_input else "the whole input" if o.slurp else "one built input at a time"
		explain_line("decides: the filter's work on each built value decides the speed, and memory holds %s", holds)
	}
	r.ran = time.tick_now()
}

@(private = "file")
op_text :: proc(op: jq.Op) -> string {
	#partial switch op {
	case .Eq:
		return "=="
	case .Ne:
		return "!="
	case .Lt:
		return "<"
	case .Le:
		return "<="
	case .Gt:
		return ">"
	}
	return ">="
}

// `p` as jq text: `.a."b c"[0][]`.
@(private = "file")
spell_path :: proc(p: core.Path) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s, i in p.steps {
		#partial switch v in s {
		case core.Name:
			plain := len(v) > 0 && !('0' <= v[0] && v[0] <= '9')
			for c in transmute([]u8)string(v) {
				plain &&= c == '_' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9'
			}
			strings.write_string(&b, ".")
			strings.write_string(&b, string(v) if plain else jq.to_json(string(v)))
		case core.Index:
			if i == 0 {
				strings.write_byte(&b, '.')
			}
			message.write(&b, "[%d]", int(v))
		case core.All:
			strings.write_string(&b, ".[]" if i == 0 else "[]")
		}
		if i in p.optional {
			strings.write_byte(&b, '?')
		}
	}
	return strings.to_string(b) if len(p.steps) > 0 else "."
}

// Records the first text the scan left to the interpreter.
explain_fallback :: proc(r: ^Route, why: Fallback) {
	if r.on && r.fallback.text == 0 {
		r.fallback = {r.scanned + r.interpreted + 1, why}
	}
}

explain_end :: proc(run: ^Run) {
	r := &run.route
	if !r.on || r.ran == {} {
		return
	}
	if r.columns != nil {
		explain_line("ran: %s, each record read by its columns", plural(r.columns.files, "file"))
	} else if r.scanning {
		explain_line("ran: %s, %d read by path and %d built", plural(r.scanned + r.interpreted, "input"), r.scanned, r.interpreted)
	} else if run.opts.null_input {
		explain_line("ran: no input")
	} else {
		explain_line("ran: %s, each built", plural(r.interpreted, "input"))
	}
	if r.pieces > 0 && run.pool != nil {
		explain_line("threads: %s over %d threads", plural(r.pieces, "piece"), run.pool.runner.threads + 1)
	} else {
		explain_line("threads: one")
	}
	if r.fallback.text > 0 {
		explain_line("fallback: input %d was built, as %s", r.fallback.text, FALLBACK_WORDS[r.fallback.why])
	}
	planned := i64(time.duration_microseconds(time.tick_diff(r.began, r.ran)))
	explain_line("time: planned in %dus, ran in %dus", planned, i64(time.duration_microseconds(time.tick_since(r.ran))))
	explain_line("used: %d bytes of memory at the peak, %d bytes read, %d bytes written", peak_rss(), r.input, run.output.written)
}

@(private = "file")
plural :: proc(n: int, noun: string) -> string {
	return message.build_temp("%d %s%s", n, noun, "" if n == 1 else "s")
}
