package main

// Printing what the filter outputs as jq prints it. Output is held in `Run.out` and written in large pieces.

import "core:os"
import "core:strings"
import core "../../core"
import "../../core/write"
import "jq"
import "message"

// Output is held here and written once it passes FLUSH_AT bytes, and at exit.
FLUSH_AT :: 1 << 20

// One output: jq's JSON, after a record separator under --seq, or under -r and -j a string's own text (with -a, its
// JSON in ASCII). After it a newline, but under -j, and a NUL under --raw-output0, which refuses a string that holds
// one: false then, with nothing printed.
print_jq :: proc(run: ^Run, v: jq.Value) -> bool {
	o := &run.opts
	out := &run.out
	run.ret = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	s: string
	is_str: bool
	if o.raw {
		s, is_str = jq.string_of(v)
	}
	switch {
	case is_str && o.ascii:
		jq.put_string(out, s, {ascii = true})
	case is_str:
		if o.raw0 && strings.index_byte(s, 0) >= 0 {
			return false
		}
		write.put_text(out, s)
	case:
		if o.seq {
			jq.put_byte(out, 0x1e)
		}
		l := output_layout(run)
		l.spill = &run.spill
		jq.write_value(out, v, l)
	}
	if !o.join {
		jq.put_byte(out, '\n')
	}
	if o.raw0 {
		jq.put_byte(out, 0)
	}
	flush_some(run)
	return true
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
	return {opts = opts, colors = &run.colors if o.color else nil}
}

// The output held so far written, when it passes FLUSH_AT bytes, when `force`d, and under --unbuffered.
flush_some :: proc(run: ^Run, force := false) {
	n := run.out.cursor
	if n >= FLUSH_AT || (force || run.opts.unbuffered) && n > 0 {
		write_out(run.out.buf[:n])
		run.route.output += n
		run.out.cursor = 0
	}
}

// What `run.spill` calls: the output held so far written, if it has passed FLUSH_AT.
spill_out :: proc(data: rawptr) {
	flush_some((^Run)(data))
}

// `p` written to stdout in full, or the run ended as jq ends it when its output cannot be written: its message, and
// the exit status of a system error.
write_out :: proc(p: []byte) {
	if err := write_stdout(p); err != nil {
		message.write_stderr("stury: error: writing output failed: %s\n", strerror(err))
		os.exit(EXIT_USAGE)
	}
}
