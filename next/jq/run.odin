package jq

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/query"

// Running a compiled program on inputs. A run holds no state of its own past its machine: the heap, the inputs and
// what the program reaches outside are the caller's, through `Hooks`.

// Reads one RFC 8259 JSON value from `src` into a tape document, honoring `budget`.
Json_Parser :: #type proc(data: rawptr, src: []u8, budget: tape.Budget, allocator: runtime.Allocator) -> (doc: tape.Document, err: tape.Error)

// What a program reaches outside its input, each nil for none.
Hooks :: struct {
	data:              rawptr,
	// The next input of `input` and `inputs`, `ok` false past the last.
	input:             proc(data: rawptr, h: ^query.Heap) -> (v: query.Value, ok: bool, status: query.Status),
	// `debug` and `stderr`'s messages: the value, which the hook does not keep.
	debug:             proc(data: rawptr, v: query.Value, h: ^query.Heap),
	stderr:            proc(data: rawptr, v: query.Value, h: ^query.Heap),
	input_filename:    proc(data: rawptr, h: ^query.Heap) -> (v: query.Value, status: query.Status),
	input_line_number: proc(data: rawptr) -> i64,
	// The time `now` gives, in seconds since the Unix epoch.
	now:               proc(data: rawptr) -> f64,
	// Fills `bytes` with random bytes, for `uuid_v4` and `uuid_v7`.
	random:            proc(data: rawptr, bytes: []u8),
	// The zone in force at an instant, in seconds since the Unix epoch, which `localtime`, `strflocaltime` and
	// `strptime`'s `%s` read in. `ok` false when it cannot be had. Without it local time is UTC.
	zone:              proc(data: rawptr, secs: i64) -> (zone: query.Zone, ok: bool),
	// How `css` reads a document of a markup format: how it reads attributes and whether names fold case. `ok` false for a
	// document of no markup format. Without it `css` selects from nothing.
	markup:            proc(data: rawptr, doc: ^tape.Document) -> (opts: css.Options, ok: bool),
	// Parses JSON text for `fromjson`. Without it `fromjson` fails.
	parse_json:        Json_Parser,
	// Where a value came from in the run's input, for the `where` builtin (and `--where` callers).
	// `ok` false for none. When nil, `where` falls back to `query.value_place` and `input_filename`.
	place:             proc(data: rawptr, v: query.Value, h: ^query.Heap) -> (file: string, place: tape.Place, ok: bool),
}

Run :: struct {
	m: Machine,
}

Run_End :: enum u8 {
	Done,    // every output given
	Failed,  // an error nothing caught, in the heap
	Halted,  // `halt` or `halt_error`: `run_halt` says how
	Stopped, // the output sink asked to stop
	Tainted, // a read reached a value a partial document did not keep (uncatchable)
}

Run_Options :: struct {
	hooks:  ^Hooks, // optional host callbacks
	steps:  int,    // evaluations each `run_value` may take, 0 for no bound
	cancel: ^u32,   // optional external cancellation flag; non-zero aborts uncatchably
}

// Prepares a run of `prog` over heap `h`, its variables `globals` by slot of `Program.globals`, a missing one null.
// The run borrows the globals, the hooks, the cancel flag and the program.
// `steps` bounds the evaluations of each `run_value`, 0 for no bound.
run_init_steps :: proc(run: ^Run, prog: ^Program, h: ^query.Heap, globals: []query.Value, hooks: ^Hooks = nil, steps := 0, cancel: ^u32 = nil) {
	run.m = {h = h, prog = prog, hooks = hooks, empty = prog.empty, budget = steps, cancel = cancel}
	g := make([]query.Value, len(prog.globals), h.allocator)
	for &x, i in g {
		x = query.retain(globals[i]) if i < len(globals) else query.NULL
	}
	run.m.globals = g
}

run_init_opts :: proc(run: ^Run, prog: ^Program, h: ^query.Heap, globals: []query.Value, opts: Run_Options) {
	run_init_steps(run, prog, h, globals, opts.hooks, opts.steps, opts.cancel)
}

run_init_hooks_opts :: proc(run: ^Run, prog: ^Program, h: ^query.Heap, globals: []query.Value, hooks: ^Hooks, opts: Run_Options) {
	run_init_steps(run, prog, h, globals, hooks if hooks != nil else opts.hooks, opts.steps, opts.cancel)
}

run_init :: proc {
	run_init_steps,
	run_init_opts,
	run_init_hooks_opts,
}

// Whether the last run was aborted by its external cancellation flag.
run_cancelled :: proc "contextless" (run: ^Run) -> bool {
	return run.m.cancelled
}

// Runs the program on `input`, which it takes, each output to `out`, which takes it.
run_value :: proc(run: ^Run, input: query.Value, out: Output, data: rawptr) -> Run_End {
	_, end := run_exec(run, input, out, data, count_only = false)
	return end
}

// Runs the program on `input`, which it takes, counting outputs without materializing or emitting them.
run_count :: proc(run: ^Run, input: query.Value) -> (count: u64, end: Run_End) {
	return run_exec(run, input, nil, nil, count_only = true)
}

@(private = "file")
run_exec :: proc(run: ^Run, input: query.Value, out: Output, data: rawptr, count_only: bool) -> (count: u64, end: Run_End) {
	m := &run.m
	query.release(m.h, m.halt.value)
	m.halt = {}
	if m.h.tainted {
		query.release(m.h, input)
		return 0, .Tainted
	}
	m.out, m.out_data = out, data
	m.count_mode = count_only
	m.out_count = 0
	m.brk, m.through, m.over, m.cancelled = nil, nil, false, false
	if m.cancel != nil {
		if intrinsics.atomic_load_explicit(m.cancel, .Relaxed) != 0 {
			m.cancelled = true
			query.release(m.h, input)
			_ = fail_budget(m)
			return 0, .Failed
		}
		if m.budget > 0 {
			chunk := min(m.budget, CANCEL_CHECK_CHUNK)
			m.steps = chunk
			m.steps_rem = m.budget - chunk
		} else {
			m.steps = CANCEL_CHECK_CHUNK
			m.steps_rem = -1
		}
	} else {
		m.steps = m.budget if m.budget > 0 else -1
		m.steps_rem = 0
	}
	m.track_origin = m.prog.uses_where || (m.hooks != nil && m.hooks.place != nil)
	prev_keep := m.h.keep_origins
	if m.track_origin {
		m.h.keep_origins = true
		m.origin = query.retain(input) if query.has_doc_origin(input) else query.ABSENT
	}
	defer {
		m.out, m.out_data = nil, nil
		m.count_mode = false
		if m.track_origin {
			query.release(m.h, m.origin)
			m.origin = query.ABSENT
			m.h.keep_origins = prev_keep
			m.track_origin = false
		}
	}
	sig := drive(m, m.prog.body, input, nil)
	if m.h.tainted || sig == .Taint {
		return m.out_count, .Tainted
	}
	switch sig {
	case .Go:
		return m.out_count, .Done
	case .Fail:
		return m.out_count, .Failed
	case .Halt:
		return m.out_count, .Failed if m.over else .Halted
	case .Break:
		return m.out_count, .Stopped
	case .Taint:
		return m.out_count, .Tainted
	}
	return m.out_count, .Done
}

// How `halt` or `halt_error` ended the last run: the exit code and halt_error's value, held by the run.
run_halt :: proc(run: ^Run) -> Halt_State {
	return run.m.halt
}

run_destroy :: proc(run: ^Run) {
	m := &run.m
	for x in m.globals {
		query.release(m.h, x)
	}
	delete(m.globals, m.h.allocator)
	query.release(m.h, m.halt.value)
	stack_destroy(m)
	query.regex_cache_destroy(&m.regexes)
	selector_cache_destroy(&m.css)
	run^ = {}
}
