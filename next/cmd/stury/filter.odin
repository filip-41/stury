package main

// The jq interpreter over each input, as jq's main loop runs it, each output printed as jq prints it.

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "jq"
import "message"

// jq's process() results, which its exit status comes from.
JQ_OK :: 0
JQ_OK_NULL_KIND :: -1 // the last output was false or null
JQ_OK_NO_OUTPUT :: -4

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

// Run the filter once on null (-n), with the inputs left to `input` and `inputs`, or else on each input.
run_filter :: proc(run: ^Run, ins: ^Inputs) {
	// Each input's values live in an arena emptied once its outputs are printed, and so does the temporary
	// allocator, which nothing holds past a call.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		message.write_stderr("stury: error: out of memory\n")
		finish(run, EXIT_INPUT)
	}
	context.allocator = virtual.arena_allocator(&arena)
	if run.opts.null_input {
		run_once(run, nil)
		return
	}
	// jq's main loop: until a file has failed, the files end, a text does not parse, or the filter halts. The first
	// input is fetched whatever the files before it did, as jq tests its errors before a fetch and not in it.
	for fetched := false; (ins.failures == 0 || !fetched) && !run.halted; fetched = true {
		v, msg, status := next_input(ins)
		switch status {
		case .Value:
			run.route.interpreted += 1
			run_once(run, v)
		case .Error:
			flush_some(run, force = true)
			message.write_stderr("stury: parse error: %s\n%s", msg, ins.note)
			run.ret = EXIT_INPUT
			return
		case .More:
			return
		}
		virtual.arena_free_all(&arena)
		free_all(context.temp_allocator)
		release_spent(ins)
	}
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
				jq.flush_messages(&run.ip)
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
		at := message.build_temp("%s:%d", name, line) if name != "" else "<unknown>"
		if msg, is_str := jq.string_of(ip.err); is_str {
			// jq prints the message as a C string, so it ends at a NUL.
			if nul := strings.index_byte(msg, 0); nul >= 0 {
				msg = msg[:nul]
			}
			message.write_stderr("stury: error (at %s): %s\n", at, msg)
		} else {
			message.write_stderr("stury: error (at %s) (not a string): %s\n", at, jq.to_json(ip.err))
		}
		run.ret = EXIT_INPUT
	case .Break:
		if code, halted := ip.halted.?; halted {
			run.ret, run.halted = code, true
		}
	}
	settle(run)
}

// Records the input's result for `-e`, once its outputs are printed.
settle :: proc(run: ^Run) {
	if run.ret <= 0 && run.ret != JQ_OK_NO_OUTPUT {
		run.last_result = int(run.ret != JQ_OK_NULL_KIND)
	}
	flush_some(run)
}
