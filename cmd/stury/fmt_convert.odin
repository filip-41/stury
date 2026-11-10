package main

// `stury fmt --schema S` converts each text to the output format through S: the input must pass S, every member S
// leaves open is kept, and the output must pass S as the output format reads it.

import "base:runtime"
import "core:strings"
import core "../../core"
import "../../core/typed"
import "../../core/write"
import "../../core/schema"
import "jq"
import "message"

// What a run of `fmt --schema` holds: the schema, the formats it is bound to, the memory each conversion reuses and the
// failures of the last one.
Conversion :: struct {
	check:     ^Schema_Check,
	converter: schema.Converter,
	from, to:  core.As,
	bound:     bool,
	sink:      typed.Sink,
}

conversion_open :: proc(check: ^Schema_Check, max_errors: int) -> ^Conversion {
	c := new(Conversion, runtime.heap_allocator())
	c.check = check
	c.sink = {
		entries    = make([dynamic]core.Error_Entry, runtime.heap_allocator()),
		max_errors = max_errors,
	}
	return c
}

// The text of `doc`, the record of the open file at byte `at`, converted and written in place of the document written
// by the library's writer. A text that fails S is told and leaves exit status 1, and false is a schema that does not
// bind to the formats.
convert_put :: proc(run: ^Run, ins: ^Inputs, doc: ^core.Document, as: core.As, at: u64) -> bool {
	out, c := &run.output, run.convert
	if !c.bound || c.from != ins.as || c.to != as {
		if c.bound {
			schema.converter_destroy(&c.converter)
		}
		c.bound = false
		if err := schema.converter_init(&c.converter, &c.check.compiled, ins.as, as, checks_of(ins.as, ins.spec == nil), checks_of(as, writes_cells(&run.opts))); err != nil {
			message.write_stderr("stury: error: %s: %s\n", ins.name, edit_error_text(ins.data, err))
			return false
		}
		c.bound, c.from, c.to = true, ins.as, as
	}
	typed.sink_restore(&c.sink, {})
	text, stage, err := schema.convert(&c.converter, doc, out.layout.opts, &c.sink, context.temp_allocator)
	if err == nil {
		write.put_text(&out.buf, string(text))
		if !strings.has_suffix(string(text), "\n") {
			jq.put_byte(&out.buf, '\n')
		}
		flush_some(out)
		return true
	}
	flush_some(out, force = true)
	out.ret = max(out.ret, 1)
	switch {
	case len(c.sink.entries) == 0:
		message.write_stderr("stury: error: %s: %s\n", ins.name, edit_error_text(ins.data, err))
	case stage == .Input:
		for &e in c.sink.entries {
			e.start, e.end = e.start + at, e.end + at
		}
		told(ins.name, ins.data, c.sink.entries[:])
	case:
		told(strings.concatenate({ins.name, " (output)"}, context.temp_allocator), text, c.sink.entries[:])
	}
	return true
}
