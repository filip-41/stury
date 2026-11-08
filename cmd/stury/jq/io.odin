package jq

// The builtins that read inputs and write messages: `input`, `inputs`, `input_filename`, `input_line_number`, `debug`,
// `stderr` and `halt_error`.

import "base:runtime"
import "core:os"

// The next input, read into the arena `out` frees it with, if it has one (`item_arena`).
@(private = "file")
read_input :: proc(ip: ^Interp, out: ^Sink) -> (Value, string, Parse_Status) {
	a, ok := item_arena(ip, out)
	context.allocator = a if ok else context.allocator
	return ip.inputs.next(ip.inputs.data)
}

// What reading an input gave: its value emitted, its error raised, and .Go when none is left.
input_signal :: #force_inline proc(ip: ^Interp, v: Value, msg: string, status: Parse_Status, input: Item, track: bool, out: ^Sink) -> Signal {
	switch status {
	case .Value:
		return emit_made(out, input, v, track)
	case .Error:
		return fail(ip, "%s", msg)
	case .More:
	}
	return .Go
}

native_input :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if ip.inputs.next != nil {
		if v, msg, status := read_input(ip, out); status != .More {
			return input_signal(ip, v, msg, status, input, track, out)
		}
	}
	return fail(ip, "break") // what jq's `input` raises, and `inputs` catches
}

fn_input_position :: proc(ip: ^Interp, name: string, v: Value, args: []Value) -> (Value, Signal) {
	file, line: = "", 0
	if ip.inputs.position != nil {
		file, line = ip.inputs.position(ip.inputs.data)
	}
	if name == "input_line_number" {
		return num(f64(line)), .Go
	}
	return file if file != "" else nil, .Go
}

native_inputs :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if ip.inputs.next == nil {
		return .Go
	}
	if _, arena := item_arena(ip, out); !track && !arena {
		if sig, recycled := recycled_inputs(ip, input, out); recycled {
			return sig
		}
	}
	for {
		v, msg, status := read_input(ip, out)
		if sig := input_signal(ip, v, msg, status, input, track, out); sig != .Go || status != .Value {
			return sig
		}
	}
}

// Messages held before they are written: a run's memory holds a chunk of its `debug` and `stderr` output, not
// all of it.
MESSAGE_FLUSH :: 1 << 16

// Writes the `debug` and `stderr` messages held so far to stderr and empties the buffer. The caller flushes
// before an output so the two streams interleave as jq's do, and this file flushes a bounded chunk so a long
// run's memory stays flat.
flush_messages :: proc(ip: ^Interp) {
	if len(ip.messages) > 0 {
		os.write(os.stderr, ip.messages[:])
		clear(&ip.messages)
	}
}

// `["DEBUG:", .]`, printed as jq's debug callback prints it: with the output's options, compact.
native_debug :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// The message alone, freed here: a long run's debug messages must not grow the input's arena with the
	// arrays that print them.
	heap := runtime.heap_allocator()
	msg := new(Array, heap)
	msg.items = make([dynamic]Value, 0, 2, heap)
	append(&msg.items, "DEBUG:", input.v)
	text := to_json(msg, ip.debug_layout, heap)
	append(&ip.messages, text)
	append(&ip.messages, '\n')
	delete(text, heap)
	delete(msg.items) // the heap allocator it was made with
	free(msg, heap)
	if len(ip.messages) >= MESSAGE_FLUSH {
		flush_messages(ip)
	}
	return out.emit(out, input)
}

// A string's own text, anything else as compact JSON.
native_stderr :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	append(&ip.messages, text_of(input.v))
	if len(ip.messages) >= MESSAGE_FLUSH {
		flush_messages(ip)
	}
	return out.emit(out, input)
}

gen_halt_error :: proc(ip: ^Interp, input: Item, args: []Value, track: bool, out: ^Sink) -> Signal {
	code, ok := number_of(args[0])
	if !ok {
		return fail(ip, "%s (%s) halt_error/1: number required", type_name(input.v), brief(ip, input.v))
	}
	// jq's main prints a string as it is and null not at all.
	if s, is_str := string_of(input.v); is_str {
		append(&ip.messages, s)
	} else if kind(input.v) != .Null {
		append(&ip.messages, to_json(input.v))
		append(&ip.messages, '\n')
	}
	ip.halted = int(code.f)
	ip.brk = -1
	return .Break
}
