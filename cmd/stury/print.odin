package main

// Printing what the filter outputs as jq prints it, and what the outputs come to, which jq's exit status is from.
// Output is held in `Output.buf` and written in large pieces.

import "base:runtime"
import "core:os"
import "core:strings"
import core "../../core"
import "../../core/write"
import records "../../core/records"
import json "../../json"
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
	held:        bool, // fmt --check and --in-place: the output is kept whole and not written
	// A piece's output, which a failure or a refused row does not end the run on but marks `refused`.
	piece:       bool,
	refused:     bool,
	// jq's: what the input being run has come to so far, JQ_OK_NO_OUTPUT or its last output's result, and what the
	// last input came to, a JQ_OK result or an exit status.
	result, ret: int,
	last_result: int, // jq's: -1 before any output, else whether the last input with outputs ended truthy
	table:       ^Table, // under --to csv or tsv
	// The column route's `select(F)`: the record each output of F stands for.
	whole:       struct {
		it:  ^records.Reader,
		rec: records.Record,
	},
}

init_output :: proc(o: ^Output, run: ^Run) {
	o^ = {
		ip = &run.ip,
		opts = &run.opts,
		layout = output_layout(run),
		result = JQ_OK_NO_OUTPUT,
		ret = JQ_OK_NO_OUTPUT,
		last_result = -1,
		table = table_start(run) if writes_cells(&run.opts) else nil,
	}
	o.emit = proc(s: ^jq.Sink, it: jq.Item) -> jq.Signal {
		o := (^Output)(s)
		// jq's message goes to stderr at once and its output waits in a buffer: an output's messages come before it,
		// never after all of the run's output.
		jq.flush_messages(o.ip)
		if !emit(o, it.v) {
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
// one: false then, with nothing printed and the reason in the interpreter's error. Under a `--to` format with a writer
// of its own the output is a text of that format.
emit :: proc(o: ^Output, v: jq.Value) -> bool {
	v := v
	if o.whole.it != nil {
		built, _ := records.build(o.whole.it, o.whole.rec, context.allocator)
		v = jq.document_value(built)
	}
	if o.table != nil {
		emit_row(o, v)
		return true
	}
	opts := o.opts
	out := &o.buf
	o.result = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	if writes_texts(opts) {
		return emit_text(o, v)
	}
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
			o.ip.err = "Cannot dump a string containing NUL with --raw-output0 option"
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
	end_output(o, ended)
	return true
}

// One output as a text of the output format, which the format's document writer makes: of a value that is a node of a
// document, which keeps what the document spells beyond JSON, and of any other value written as JSON and read back as
// a document. A value the format has no spelling for fails the run, with the reason.
@(private = "file")
emit_text :: proc(o: ^Output, v: jq.Value) -> bool {
	as := text_written_as(o.opts)
	built: core.Document
	doc, node := &built, core.ROOT
	if ref, is_ref := v.(jq.Ref); is_ref {
		doc, node = ref.doc, ref.node
	} else {
		frame: write.Out
		spare: [write.ROOM_MAX]u8
		write.init(&frame, &spare, context.temp_allocator)
		jq.write_value(&frame, v, jq.Layout{})
		json_text, _ := write.finish(&frame)
		fault: Maybe(core.Fault)
		if built, fault = jq.build_text(json_text, json.as(.Json), context.temp_allocator); fault != nil {
			o.ip.err = text_refusal(o.opts.to, nil)
			return false
		}
	}
	text, _, err := core.write(doc, o.layout.opts, as, node, context.temp_allocator)
	if err != nil {
		o.ip.err = text_refusal(o.opts.to, err)
		return false
	}
	put_format_text(o, as, text, true)
	return true
}

// Why the writer of format `to` refused a value, in the format's own words where its row has them.
text_refusal :: proc(to: Format, err: core.Error) -> string {
	if refusal := FORMATS[to].refusal; refusal != nil {
		if why := refusal(write_refusal_kind(err)); why != "" {
			return why
		}
	}
	return strings.concatenate({"cannot write the value as ", FORMATS[to].name}, context.temp_allocator)
}

// A `text` the writer of the output format `as` made, written after what parts it from the text before it when
// `parted` and it is not the output's first, and a newline after it unless it ends with one, is empty, or is an item of
// a binary format, which ends itself.
put_format_text :: proc(o: ^Output, as: core.As, text: []u8, parted: bool) {
	if between := FORMATS[o.opts.to].parted; parted && between != nil && o.written + o.buf.cursor > 0 {
		write.put_text(&o.buf, between(text))
	}
	write.put_text(&o.buf, string(text))
	if !as.readers.binary && len(text) > 0 && text[len(text) - 1] != '\n' {
		jq.put_byte(&o.buf, '\n')
	}
	flush_some(o)
}

// Ends an output written into `o.buf`: a newline but under -j or when a line comment `ended` its line, and a NUL
// under --raw-output0.
end_output :: proc(o: ^Output, ended := false) {
	if !o.opts.join && !ended {
		jq.put_byte(&o.buf, '\n')
	}
	if o.opts.raw0 {
		jq.put_byte(&o.buf, 0)
	}
	flush_some(o)
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
	if o.held {
		return
	}
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
		output_failed(err)
	}
}

// Exit with `code` once stdout is closed, as jq's fclose(stdout) at its exit does: a stdout that was not open, or one
// whose close fails, ends the run as a failed write does, whatever `code` was and whether or not anything was written.
exit_closing_stdout :: proc(code: int) -> ! {
	if err := close_stdout(); err != nil {
		output_failed(err)
	}
	os.exit(code)
}

@(private = "file")
output_failed :: proc(err: os.Error) -> ! {
	message.write_stderr("stury: error: writing output failed: %s\n", strerror(err))
	os.exit(EXIT_USAGE)
}
