package main

// A filter the path scan cannot answer runs on the jq interpreter, on each input in turn as jq's main loop
// runs it, and each output is printed as jq prints it.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
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
	if virtual.arena_init_growing(&arena) != nil {
		fmt.eprintln("stury: error: out of memory")
		os.exit(EXIT_INPUT)
	}
	context.allocator = virtual.arena_allocator(&arena)
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
		switch status {
		case .Value:
			run_once(run, v)
			ran = true
		case .Error:
			flush_some(run, force = true)
			if !run.opts.seq {
				fmt.eprintf("stury: parse error: %s\n%s", msg, ins.fault_note)
				run.ret = EXIT_INPUT
				return
			}
			fmt.eprintf("stury: ignoring parse error: %s\n%s", msg, ins.fault_note)
			ins.fault_note = ""
			ran = ins.slurped == nil // the message's memory goes back before the next input, as a value's does
		case .More:
			return
		}
	}
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

// jq's process(): the filter on one input, its outputs printed, its error reported.
run_once :: proc(run: ^Run, v: jq.Value) {
	s := Print_Sink{sink = {emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
				run := ((^Print_Sink)(s)).run
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
	if len(ip.messages) > 0 {
		flush_some(run, force = true)
		os.write(os.stderr, ip.messages[:])
		clear(&ip.messages)
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
