package jq

import "stury:lib/core/tape"
import "stury:lib/ops/css"
import "stury:lib/query"

// Running a compiled program on inputs. A run holds no state of its own past its machine: the heap, the inputs and
// what the program reaches outside are the caller's, through `Hooks`.

// What a program reaches outside its input, each nil for none.
Hooks :: struct {
	data:           rawptr,
	// The next input of `input` and `inputs`, `ok` false past the last.
	input:          proc(data: rawptr, h: ^query.Heap) -> (v: query.Value, ok: bool, status: query.Status),
	// `debug` and `stderr`'s messages: the value, which the hook does not keep.
	debug:          proc(data: rawptr, v: query.Value, h: ^query.Heap),
	stderr:         proc(data: rawptr, v: query.Value, h: ^query.Heap),
	input_filename: proc(data: rawptr, h: ^query.Heap) -> (v: query.Value, status: query.Status),
	// The time `now` gives, in seconds since the Unix epoch.
	now:            proc(data: rawptr) -> f64,
	// Fills `bytes` with random bytes, for `uuid_v4` and `uuid_v7`.
	random:         proc(data: rawptr, bytes: []u8),
	// The zone in force at an instant, in seconds since the Unix epoch, which `localtime`, `strflocaltime` and
	// `strptime`'s `%s` read in. `ok` false when it cannot be had. Without it local time is UTC.
	zone:           proc(data: rawptr, secs: i64) -> (zone: query.Zone, ok: bool),
	// How `css` reads a document of a markup format: how it reads attributes and whether names fold case. `ok` false for a
	// document of no markup format. Without it `css` selects from nothing.
	markup:         proc(data: rawptr, doc: ^tape.Document) -> (opts: css.Options, ok: bool),
}

Run :: struct {
	m: Machine,
}

Run_End :: enum u8 {
	Done, // every output given
	Failed, // an error nothing caught, in the heap
	Halted, // `halt` or `halt_error`: `run_halt` says how
	Stopped, // the output sink asked to stop
}

// Prepares a run of `prog` over heap `h`, its variables `globals` by slot of `Program.globals`, a missing one null.
// The run borrows the globals, the hooks and the program.
// `steps` bounds the evaluations of each `run_value`, 0 for no bound.
run_init :: proc(run: ^Run, prog: ^Program, h: ^query.Heap, globals: []query.Value, hooks: ^Hooks = nil, steps := 0) {
	run.m = {h = h, prog = prog, hooks = hooks, empty = prog.empty, budget = steps}
	g := make([]query.Value, len(prog.globals), h.allocator)
	for &x, i in g {
		x = query.retain(globals[i]) if i < len(globals) else query.NULL
	}
	run.m.globals = g
}

// Runs the program on `input`, which it takes, each output to `out`, which takes it.
run_value :: proc(run: ^Run, input: query.Value, out: Output, data: rawptr) -> Run_End {
	m := &run.m
	m.out, m.out_data = out, data
	m.brk, m.through, m.over = nil, nil, false
	m.steps = m.budget if m.budget > 0 else -1
	switch drive(m, m.prog.body, input, nil) {
	case .Go:
		return .Done
	case .Fail:
		return .Failed
	case .Halt:
		return .Failed if m.over else .Halted
	case .Break:
		return .Stopped
	}
	return .Done
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
