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
	inputs, temp: virtual.Arena
	if virtual.arena_init_growing(&inputs) != nil || virtual.arena_init_growing(&temp) != nil {
		message.write_stderr("stury: error: out of memory\n")
		finish(run, EXIT_INPUT)
	}
	context.allocator = jq.arena_allocator(&inputs)
	context.temp_allocator = jq.arena_allocator(&temp)
	if run.opts.null_input {
		run_once(run, nil)
		return
	}
	// jq's main loop: until a file has failed, the files end, a text does not parse, or the filter halts. The first
	// input is fetched whatever the files before it did, as jq tests its errors before a fetch and not in it.
	for fetched := false; (ins.failures == 0 || !fetched) && !run.halted; fetched = true {
		v, msg, status := next_input(ins)
		// A text that does not parse is the interpreter's, which tells its fault.
		run.route.interpreted += int(status != .More)
		switch status {
		case .Value:
			run_once(run, v)
		case .Error:
			if !run.opts.seq {
				flush_some(&run.output, force = true)
				message.write_stderr("stury: parse error: %s\n%s", msg, ins.note)
				finish_input(&run.output, EXIT_INPUT)
				return
			}
			tell_ignored(ins, msg)
		case .More:
			return
		}
		free_all(context.allocator)
		free_all(context.temp_allocator)
		release_spent(ins)
	}
}

// Runs the filter on one input, prints its outputs and reports its error, as jq's process() does.
run_once :: proc(run: ^Run, v: jq.Value) {
	ip := &run.ip
	ip.free_envs = nil // the last input's, emptied with its memory
	ip.printer = &run.output
	sig := jq.eval(ip, run.prog, {v = v}, ip.globals, false, &run.output)
	ip.printer = nil
	if run.output.piece && (sig == .Fail || ip.halted != nil) {
		run.output.refused = true
		return
	}
	if len(ip.messages) > 0 {
		jq.flush_messages(ip)
		flush_some(&run.output, force = true)
	}
	ended: Maybe(int)
	#partial switch sig {
	case .Fail:
		flush_some(&run.output, force = true)
		tell_filter_error(ip, (^Inputs)(ip.inputs.data))
		ended = EXIT_INPUT
	case .Break:
		if code, halted := ip.halted.?; halted {
			ended, run.halted = code, true
		}
	}
	finish_input(&run.output, ended)
}

// The error the filter stopped with, told at the input's position as jq's process() tells it. `ins` is the run's
// inputs when `input` reads them, nil when an edit's reader does.
tell_filter_error :: proc(ip: ^jq.Interp, ins: ^Inputs) {
	name, line := ip.inputs.position(ip.inputs.data)
	// No input, as under -n, is no place, where jq says `(at <unknown>)`.
	at := message.build_temp(" (at %s:%d)", name, line) if name != "" else ""
	if msg, is_str := jq.string_of(ip.err); is_str {
		// jq prints the message as a C string, so it ends at a NUL.
		if nul := strings.index_byte(msg, 0); nul >= 0 {
			msg = msg[:nul]
		}
		// What `input` raises past the last input, for `inputs` to catch, which jq prints as it is.
		if msg == "break" {
			msg = "No more inputs"
		}
		if ins != nil && ins.told != "" && msg == ins.told {
			message.write_stderr("stury: parse error: %s\n%s", msg, ins.note)
		} else {
			message.write_stderr("stury: error%s: %s\n", at, msg)
		}
	} else {
		message.write_stderr("stury: error%s (not a string): %s\n", at, jq.to_json(ip.err))
	}
}
