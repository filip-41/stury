package main

// A filter the path scan cannot answer runs on the jq interpreter, on each input in turn as jq's main loop
// runs it, and each output is printed as jq prints it.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import json "../../json"
import "jq"

// jq's process() results, which its exit status comes from.
JQ_OK :: 0
JQ_OK_NULL_KIND :: -1 // the last output was false or null
JQ_OK_NO_OUTPUT :: -4

// Run the filter once on null (-n), with the inputs left to `input` and `inputs`, or else on each input.
run_filter :: proc(run: ^Run, ins: ^Inputs) {
	ready_interpreter(run)
	// Each input's values live in an arena emptied once its outputs are printed, and so does the temporary
	// allocator, which nothing holds past a call.
	arena: virtual.Arena
	context.allocator = input_arena(run, &arena)
	if run.opts.null_input {
		run_once(run, nil)
		return
	}
	// jq's main loop: until a file has failed, the stream ends, a text does not parse (under --seq it is
	// passed over), or the filter halts. An input's memory is emptied once the next is wanted, so the last
	// input's goes back with the process rather than unmapped first: emptying zeroes what the arena used.
	ran, fetched := false, false
	// The first input is fetched whatever the files before it did: `scan_inputs` hands over after the fetch that
	// met a file not opening, as jq's loop tests its errors before a fetch and not in it.
	for (ins.failures == 0 || !fetched) && !run.halted {
		if ran {
			if stream_ended(ins) {
				return
			}
			virtual.arena_free_all(&arena)
			free_all(context.temp_allocator)
			free_spent(ins)
		}
		v, msg, status := next_input(ins, run.prog)
		fetched = true
		if status != .More {
			explain_interpreted(run)
		}
		switch status {
		case .Value:
			run_once(run, v)
			ran = true
		case .Error:
			if !run.opts.seq {
				parse_failed(run, msg, ins.fault_note)
				return
			}
			flush_some(run, force = true)
			fmt.eprintf("stury: ignoring parse error: %s\n%s", msg, ins.fault_note)
			ins.fault_note = ""
			ran = ins.slurped == nil // the message's memory goes back before the next input, as a value's does
		case .More:
			return
		}
	}
}

// `arena` started as a growing arena, whose allocator it returns, or the run ended for want of memory.
input_arena :: proc(run: ^Run, arena: ^virtual.Arena) -> runtime.Allocator {
	if virtual.arena_init_growing(arena) != nil {
		fmt.eprintln("stury: error: out of memory")
		finish(run, EXIT_INPUT)
	}
	return virtual.arena_allocator(arena)
}

// Ends the run on a fault in the input: the output so far, then jq's parse error message and the note after it.
parse_failed :: proc(run: ^Run, msg: string, note := "") {
	flush_some(run, force = true)
	fmt.eprintf("stury: parse error: %s\n%s", msg, note)
	run.ret = EXIT_INPUT
}

// The interpreter's stack: 4 GiB of address space reserved, committed only as far as a filter recurses
// (the main thread's 8 MiB gives out near 20000 levels). jq keeps its stack on the heap, so where jq runs
// out of memory this runs out of stack, and the guard below it ends the run as jq does. If the reservation
// or the thread fails (run_deep), the run ends with "cannot allocate memory" and exit 2.
DEEP_STACK :: 4 << 30

// What run_deep hands the thread it starts.
Deep_Job :: struct {
	run:  ^Run,
	ins:  ^Inputs,
	body: proc(run: ^Run, ins: ^Inputs),
	ctx:  runtime.Context,
}

// Run the filter on one input text, `base` bytes into the input: a path whose step does not apply, which
// the scan left to jq's rules.
run_text :: proc(run: ^Run, src: []byte, base: u64) {
	explain_interpreted(run)
	ready_interpreter(run)
	d, err := jq.build_rows(src, run.req.dialect)
	if e, bad := err.?; bad {
		e.offset += base
		fail_input(run, e)
	}
	defer json.destroy(&d)
	run_once(run, jq.Ref{&d, json.ROOT})
}

Print_Sink :: struct {
	using sink: jq.Sink,
	run:        ^Run,
}

// Runs the filter on one input and prints its outputs. Returns the signal the run ended with.
eval_input :: proc(run: ^Run, v: jq.Value) -> jq.Signal {
	s := Print_Sink{sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
				run := ((^Print_Sink)(s)).run
				// jq's message goes to stderr at once and its output waits in a buffer: an output's messages
				// come before it, never after all of the run's output.
				if len(run.ip.messages) > 0 {
					jq.flush_messages(&run.ip)
				}
				if sel := run.selected; sel != nil {
					print_cells(run, sel.cols, sel.rec, sel.dialect)
					return .Go
				}
				if !print_jq(run, it.v) {
					run.ip.err = "Cannot dump a string containing NUL with --raw-output0 option"
					return .Fail
				}
				return .Go
			}}, run = run}
	ip := &run.ip
	ip.free_envs = nil // the last input's, emptied with its memory
	run.ret = JQ_OK_NO_OUTPUT
	ip.printer = &s
	sig := jq.eval(ip, run.prog, {v = v}, ip.globals, false, &s)
	ip.printer = nil
	run.pieces_root = {}
	return sig
}

// Runs the filter on one input, prints its outputs and reports its error, as jq's process() does.
run_once :: proc(run: ^Run, v: jq.Value) {
	ip := &run.ip
	sig := eval_input(run, v)
	if len(ip.messages) > 0 {
		jq.flush_messages(ip)
		flush_some(run, force = true)
	}
	#partial switch sig {
	case .Fail:
		flush_some(run, force = true)
		name, line := ip.inputs.position(ip.inputs.data)
		at := fmt.tprintf("%s:%d", name, line) if name != "" else "<unknown>"
		if msg, is_str := jq.string_of(ip.err); is_str {
			// jq prints the message as a C string, so it ends at a NUL.
			if nul := strings.index_byte(msg, 0); nul >= 0 {
				msg = msg[:nul]
			}
			fmt.eprintf("stury: error (at %s): %s\n", at, msg)
		} else {
			fmt.eprintf("stury: error (at %s) (not a string): %s\n", at, jq.to_json(ip.err))
		}
		run.ret = EXIT_INPUT
	case .Break:
		if code, halted := ip.halted.?; halted {
			run.ret, run.halted = code, true
		}
	}
	if run.ret <= 0 && run.ret != JQ_OK_NO_OUTPUT {
		run.last_result = int(run.ret != JQ_OK_NULL_KIND)
	}
	flush_some(run)
}
