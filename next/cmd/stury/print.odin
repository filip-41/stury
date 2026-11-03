package main

// Printing what the filter outputs as jq prints it, and what the outputs come to, which jq's exit status is from.
// Output is held in `Output.buf` and written in large pieces.

import "base:runtime"
import "core:os"
import "core:strings"
import core "../../core"
import "../../core/write"
import "jq"
import "message"

// Output is held here and written once it passes FLUSH_AT bytes, and at exit.
FLUSH_AT :: 1 << 20

// The sink the interpreter's outputs go to, and the path scan's. `init_output` readies it, and it does not move after.
Output :: struct {
	using sink:  jq.Sink,
	ip:          ^jq.Interp, // whose messages go to stderr before each output
	opts:        ^Opts,
	layout:      jq.Layout,
	buf:         write.Out, // written to stdout by `flush_some`
	spare:       [write.ROOM_MAX]u8,
	spill:       jq.Spill, // `spill_out`, so a deep value is not held whole
	written:     int, // bytes written to stdout
	// jq's: what the input being run has come to so far, JQ_OK_NO_OUTPUT or its last output's result, and what the
	// last input came to, a JQ_OK result or an exit status.
	result, ret: int,
	last_result: int, // jq's: -1 before any output, else whether the last input with outputs ended truthy
}

init_output :: proc(o: ^Output, run: ^Run) {
	o^ = {
		ip = &run.ip,
		opts = &run.opts,
		layout = output_layout(run),
		result = JQ_OK_NO_OUTPUT,
		ret = JQ_OK_NO_OUTPUT,
		last_result = -1,
	}
	o.emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
		o := (^Output)(s)
		// jq's message goes to stderr at once and its output waits in a buffer: an output's messages come before it,
		// never after all of the run's output.
		jq.flush_messages(o.ip)
		if !emit(o, it.v) {
			o.ip.err = "Cannot dump a string containing NUL with --raw-output0 option"
			return .Fail
		}
		return .Go
	}
	write.init(&o.buf, &o.spare, runtime.heap_allocator(), hint = FLUSH_AT * 2)
	o.spill = {at = FLUSH_AT, flush = proc(data: rawptr) {flush_some((^Output)(data))}, data = o}
	o.layout.spill = &o.spill
}

// One output: jq's JSON, after a record separator under --seq, or under -r and -j a string's own text (with -a, its
// JSON in ASCII). After it a newline, but under -j, and a NUL under --raw-output0, which refuses a string that holds
// one: false then, with nothing printed.
emit :: proc(o: ^Output, v: jq.Value) -> bool {
	opts := o.opts
	out := &o.buf
	o.result = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	s: string
	is_str, ended: bool
	if opts.raw {
		s, is_str = jq.string_of(v)
	}
	switch {
	case is_str && opts.ascii:
		jq.put_string(out, s, {ascii = true})
	case is_str:
		if opts.raw0 && strings.index_byte(s, 0) >= 0 {
			return false
		}
		write.put_text(out, s)
	case:
		if opts.seq {
			jq.put_byte(out, 0x1e)
		}
		jq.write_value(out, v, o.layout)
		// A line comment the value ends with ended its line.
		ended = o.layout.comments && out.cursor > 0 && out.buf[out.cursor - 1] == '\n'
	}
	if !opts.join && !ended {
		jq.put_byte(out, '\n')
	}
	if opts.raw0 {
		jq.put_byte(out, 0)
	}
	flush_some(o)
	return true
}

// Ends an input's outputs: what it came to, its last output's result, or the exit status the filter `ended` it with
// (an error, a halt), and for -e whether its last output was truthy.
finish_input :: proc(o: ^Output, ended: Maybe(int) = nil) {
	o.ret = ended.? or_else o.result
	o.result = JQ_OK_NO_OUTPUT
	if o.ret <= 0 && o.ret != JQ_OK_NO_OUTPUT {
		o.last_result = int(o.ret != JQ_OK_NULL_KIND)
	}
	flush_some(o)
}

// How jq prints the outputs.
output_layout :: proc(run: ^Run) -> jq.Layout {
	o := &run.opts
	opts := core.Write_Options {
		pretty    = !o.compact,
		indent    = u8(max(o.indent, 0)),
		tab       = o.indent < 0,
		ascii     = o.ascii,
		sort_keys = o.sort_keys,
	}
	return {opts = opts, colors = &run.colors if o.color else nil, comments = writes_comments(o)}
}

// The output held so far written, when it passes FLUSH_AT bytes, when `force`d, and under --unbuffered.
flush_some :: proc(o: ^Output, force := false) {
	n := o.buf.cursor
	if n >= FLUSH_AT || (force || o.opts.unbuffered) && n > 0 {
		write_out(o.buf.buf[:n])
		o.written += n
		o.buf.cursor = 0
	}
}

// `p` written to stdout in full, or the run ended as jq ends it when its output cannot be written: its message, and
// the exit status of a system error.
write_out :: proc(p: []byte) {
	if err := write_stdout(p); err != nil {
		message.write_stderr("stury: error: writing output failed: %s\n", strerror(err))
		os.exit(EXIT_USAGE)
	}
}
