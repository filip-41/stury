package main

// --explain writes `stury: explain: KEY: FACTS` lines to stderr: the filter and its route before the run, what the run
// did after it. The code that takes each decision records its reason in `Route`, so the report never derives one again.

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

@(private = "file")
explain_line :: proc(format: string, args: ..any) {
	message.write_stderr("stury: explain: %s\n", message.build_temp(format, ..args))
}

// The lowercase name of an enum value, as the report spells it.
@(private = "file")
token :: proc(v: $T) -> string {
	return strings.to_lower(message.build_temp("%v", v), context.temp_allocator)
}

// Before the filter is compiled, so one that fails still shows.
explain_filter :: proc(run: ^Run) {
	if run.route.on {
		run.route.began = time.tick_now()
		explain_line("program: %q", strings.trim_space(run.program.text))
	}
}

explain_route :: proc(run: ^Run) {
	r := &run.route
	if !r.on {
		return
	}
	o := &run.opts
	records := "none" if o.null_input else "ndjson" if reads_lines(o) else "seq" if o.seq else "raw_lines" if o.raw_input else "whole"
	if reads_cells(o) {
		explain_line("input: format=%s", FORMATS[o.from].name)
	} else {
		explain_line("input: format=%s dialect=%s records=%s duplicates=last", FORMATS[o.from].name, token(FORMATS[o.from].spec), records)
	}
	if cols := r.columns; cols != nil {
		explain_line("route: columns")
		read := "*" if cols.every else strings.join(cols.names[:], ",", context.temp_allocator)
		shape := "all" if cols.every || cols.shape == .Select else token(cols.shape)
		explain_line("columns: read=%s shape=%s selecting=%s", read, shape, "yes" if cols.shape == .Select else "no")
	} else if r.scanning {
		explain_line("route: path_scan")
		sel := "none"
		if r.select.op != .None {
			sel = message.build_temp("%s literal=%s", token(r.select.op), jq.to_json(r.select.literal))
		}
		any_at := "none"
		for s, i in r.path.steps {
			if _, every := s.(core.All); every {
				any_at = message.build_temp("%d", i)
				break
			}
		}
		explain_line("path: %s any_at=%s select=%s limit=%d", spell_path(r.path), any_at, sel, r.path.limit.? or_else 0)
	} else {
		explain_line("route: interpreter")
		b := strings.builder_make(context.temp_allocator)
		for why in Route_Why {
			if why in r.whys {
				strings.write_string(&b, "," if strings.builder_len(b) > 0 else "")
				strings.write_string(&b, token(why))
			}
		}
		explain_line("refused: %s", strings.to_string(b))
	}
	explain_line("compile_time: %dus", i64(time.duration_microseconds(time.tick_since(r.began))))
	r.ran = time.tick_now()
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
	pieces := message.build_temp("%d", r.pieces) if r.pieces > 0 else "none"
	if r.columns != nil {
		explain_line("run: files=%d pieces=%s", r.columns.files, pieces)
	} else {
		explain_line("run: texts=%d scanned=%d interpreted=%d pieces=%s", r.scanned + r.interpreted, r.scanned, r.interpreted, pieces)
	}
	if r.fallback.text > 0 {
		explain_line("fallback: text=%d why=%s", r.fallback.text, token(r.fallback.why))
	}
	explain_line("run_time: %dus", i64(time.duration_microseconds(time.tick_since(r.ran))))
	explain_line("cost: peak_rss=%d input=%d output=%d", peak_rss(), r.input, run.output.written)
}
