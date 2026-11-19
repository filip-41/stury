#+private
package jq

// The builtins that read inputs and write messages: `input`, `inputs`, `input_filename`, `input_line_number`, `debug`,
// `stderr` and `halt_error`.

import "base:runtime"
import core_pkg "../core"

// The next input, read into the arena `out` frees it with, if it has one (`item_arena`).
@(private = "file")
read_input :: proc(ip: ^Interp, out: ^Sink) -> (core_pkg.Value, string, Input_Status) {
	a, ok := item_arena(ip, out)
	context.allocator = a if ok else context.allocator
	return ip.hooks.inputs.next(ip.hooks.inputs.data)
}

// What reading an input gave: its value emitted, its error raised, and .Go when none is left.
input_signal :: #force_inline proc(ip: ^Interp, v: core_pkg.Value, msg: string, status: Input_Status, input: Item, track: bool, out: ^Sink) -> Signal {
	switch status {
	case .Value:
		return emit_made(out, input, v, track)
	case .Error:
		return fail(ip, "%s", msg)
	case .End:
	}
	return .Go
}

native_input :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if ip.hooks.inputs.next != nil {
		if v, msg, status := read_input(ip, out); status != .End {
			return input_signal(ip, v, msg, status, input, track, out)
		}
	}
	return fail(ip, "break") // what jq's `input` raises, and `inputs` catches
}

fn_input_position :: proc(ip: ^Interp, name: string, v: core_pkg.Value, args: []core_pkg.Value) -> (core_pkg.Value, Signal) {
	file, line: = "", 0
	if ip.hooks.inputs.position != nil {
		file, line = ip.hooks.inputs.position(ip.hooks.inputs.data)
	}
	if name == "input_line_number" {
		return num(f64(line)), .Go
	}
	// A name that is not UTF-8 reads with U+FFFD, as jq makes a string of it.
	return valid_utf8(file) if file != "" else nil, .Go
}

native_inputs :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	if ip.hooks.inputs.next == nil {
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

// `text` written through the messages hook, as `debug`, `stderr` and `halt_error` write it.
say :: proc(ip: ^Interp, text: string) {
	if ip.hooks.messages != nil {
		ip.hooks.messages(ip.hooks.data, transmute([]byte)text)
	}
}

// `["DEBUG:", .]`, printed as jq's debug callback prints it: with the output's options, compact.
native_debug :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	// The message alone, freed here: a long run's debug messages must not grow the input's arena with the
	// arrays that print them.
	heap := runtime.heap_allocator()
	msg := new(core_pkg.Array, heap)
	msg.items = make([dynamic]core_pkg.Value, 0, 2, heap)
	append(&msg.items, string("DEBUG:"), input.v)
	text := to_json(msg, ip.debug_layout, heap)
	say(ip, text)
	say(ip, "\n")
	delete(text, heap)
	delete(msg.items) // the heap allocator it was made with
	free(msg, heap)
	return out.emit(out, input)
}

// A string's own text, anything else as compact JSON.
native_stderr :: proc(ip: ^Interp, n: ^Node, input: Item, env: ^Env, track: bool, out: ^Sink) -> Signal {
	say(ip, text_of(input.v))
	return out.emit(out, input)
}

gen_halt_error :: proc(ip: ^Interp, input: Item, args: []core_pkg.Value, track: bool, out: ^Sink) -> Signal {
	code, ok := number_of(args[0])
	if !ok {
		return fail(ip, "%s (%s) halt_error/1: number required", type_name(input.v), brief(ip, input.v))
	}
	// jq's main prints a string as it is and null not at all.
	if s, is_str := string_of(input.v); is_str {
		say(ip, s)
	} else if kind(input.v) != .Null {
		say(ip, to_json(input.v))
		say(ip, "\n")
	}
	ip.halted = int(code.f)
	ip.brk = -1
	return .Break
}
