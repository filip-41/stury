package main

// Printing what the filter outputs as jq prints it: the scan's answers, copied from the source where that is
// jq's format, and the interpreter's values. Output is held in `Run.out` and written in large pieces.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import host "../../host"
import json "../../json"
import "jq"

// The filter's outputs over a text, from its path's `answers` (`Path.per_element`): one `.Type_Mismatch` answer
// when jq errors on the text, which `print_answers` leaves whole to the interpreter before any of it prints.
// `settled` when each output is found or missing, which a pool thread prints as the main thread would.
jq_outputs :: proc(answers: []json.Answer) -> (outputs: []json.Answer, settled: bool) {
	settled = true
	for a, i in answers {
		if a.outcome == .Type_Mismatch {
			return answers[i:i + 1], false
		}
		settled &&= a.outcome == .Found || a.outcome == .Missing
	}
	return answers, settled
}

// Print the scan's `answers` over the text `src`, `base` bytes into the input.
print_answers :: proc(run: ^Run, answers: []json.Answer, src: []byte, base: u64) {
	// jq's result for the text, when nothing is printed.
	run.ret = JQ_OK_NO_OUTPUT
	for a in answers {
		switch {
		case run.select.op != .None && (a.outcome == .Found || a.outcome == .Missing):
			if selects(run, src, a) {
				print_spelled(run, src)
			}
		case a.outcome == .Found:
			print_answer(run, src, a)
		case a.outcome == .Missing:
			print_jq(run, nil)
		case:
			// A step that does not apply (`.a` on a number, `.[0]` on an object): jq's rules decide.
			run_text(run, src, base)
		}
	}
	flush_some(run)
	free_all(context.temp_allocator)
}

// One answer, printed as `print_jq` prints its value. A string with nothing jq would escape differently
// and a number are copied from the source.
print_answer :: proc(run: ^Run, src: []byte, a: json.Answer) {
	span := src[a.lo:a.hi]
	switch a.kind {
	case .Array, .Object:
		if json.plain_json(run.req.dialect) {
			print_spelled(run, span)
		} else {
			print_text(run, span)
		}
	case .String:
		if !run.opts.raw && !run.opts.color && !jq.escaped(span) {
			run.ret = JQ_OK
			append(&run.out, ..span)
			append(&run.out, '\n')
			flush_some(run)
			break
		}
		// Freed once printed: a text's answers may decode to as much as the text.
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		d, _, ok := json.decode_span(src, a.lo, a.hi, .String, context.temp_allocator)
		if !ok {
			if run.held {
				run.faulted = true
				return
			}
			fmt.eprintf("stury: error: %s: a string that does not decode\n", run.name)
			finish(run, EXIT_INPUT)
		}
		print_jq(run, d.(string))
	case .Number:
		print_jq(run, jq.Number{lit = string(span)})
	case .Null, .False, .True:
		print_jq(run, jq.span_value(src, a.lo, a.hi, a.kind))
	}
}

// A JSON text, such as a record `select` kept, printed as `print_jq` prints it: laid out from the text when
// that is in jq's format.
print_spelled :: proc(run: ^Run, record: []byte) {
	if !run.held && print_root_pieces(run, record) {
		return
	}
	layout := output_layout(run)
	if (record[0] == '{' || record[0] == '[') && jq.write_spelled(&run.out, record, layout) {
		end_output(run)
		return
	}
	print_text(run, record, respell = false)
}

// Output that is in jq's format ends here: its result, a newline unless -j, and the output flushed in pieces.
end_output :: proc(run: ^Run) {
	run.ret = JQ_OK
	if !run.opts.join {
		append(&run.out, '\n')
	}
	flush_some(run)
}

// A JSON text the library has already read, read again and printed as `print_jq` prints it. `respell` is
// false for a text `write_spelled` has refused.
print_text :: proc(run: ^Run, text: []byte, respell := true) {
	doc, err := jq.build_rows(text, run.req.dialect)
	if e, bad := err.?; bad {
		if run.held {
			run.faulted = true
			return
		}
		fmt.eprintf("stury: error: %s: an answer could not be read again: %s\n", run.name, jq.FAULT_TEXT[e.kind])
		finish(run, EXIT_INPUT)
	}
	defer json.destroy(&doc)
	print_jq(run, jq.Ref{&doc, json.ROOT}, respell)
}

// One output: jq's JSON, after a record separator under --seq, or under -r and -j a string's own text (with
// -a, its JSON in ASCII). After it a newline, but under -j, and a NUL under --raw-output0, which refuses a
// string that holds one: false then, with nothing printed.
print_jq :: proc(run: ^Run, v: jq.Value, respell := true) -> bool {
	if run.table != nil {
		return print_row(run, v)
	}
	o := &run.opts
	if text, large := source_text(run, v); large && print_root_pieces(run, text) {
		return true
	}
	run.ret = JQ_OK if jq.truthy(v) else JQ_OK_NULL_KIND
	// Only -r and -j print a string other than as JSON.
	s: string
	is_str: bool
	if o.raw {
		s, is_str = jq.string_of(v)
	}
	ended := false // by a line comment, which ends its line itself
	switch {
	case is_str && o.raw && o.ascii:
		jq.write_string(&run.out, s, true)
	case is_str && o.raw:
		if o.raw0 && strings.index_byte(s, 0) >= 0 {
			return false
		}
		append(&run.out, s)
	case:
		if o.seq {
			append(&run.out, 0x1e)
		}
		l := output_layout(run)
		if !run.held {
			// A deep value's layout is written as it goes (`jq.Spill`), not held whole.
			l.spill = &run.spill
		}
		jq.write_answer(&run.out, v, l, respell)
		ended = FORMATS[o.to].keeps_comments && run.out[len(run.out) - 1] == '\n'
	}
	if !o.join && !ended {
		append(&run.out, '\n')
	}
	if o.raw0 {
		append(&run.out, 0)
	}
	flush_some(run)
	return true
}

// The text an output reads as, when it is an array or object of the input, past what one thread lays out
// sooner than the pool, and jq's layout is that text's own (no -a, -S, --seq or --raw-output0): a
// document's, or the root built in pieces or its spine's array.
@(private = "file")
source_text :: proc(run: ^Run, v: jq.Value) -> (text: []byte, large: bool) {
	switch x in v {
	case jq.Ref:
		if len(json.get_raw(x.doc, x.node)) < 2 * BATCH_BYTES_PER_FIRST_WORKERS {
			return
		}
		k, _ := json.kind(x.doc, x.node)
		if json.plain_json(x.doc.dialect) && (k == .Array || k == .Object) {
			text = json.get_raw(x.doc, x.node)
		}
	case ^jq.Array:
		if rawptr(x) == run.pieces_root.items {
			text = run.pieces_root.items_text
		}
	case ^jq.Object:
		if rawptr(x) == run.pieces_root.root {
			text = run.pieces_root.text
		}
	case nil, bool, jq.Number, string, jq.Path:
	}
	o := &run.opts
	large = len(text) >= 2 * BATCH_BYTES_PER_FIRST_WORKERS && !run.held && !run.silent && !o.ascii && !o.sort_keys && !o.seq && !o.raw0
	return
}

// How jq prints the outputs.
output_layout :: proc(run: ^Run) -> jq.Layout {
	o := run.opts
	return {pretty = !o.compact, indent = int(o.indent), sort_keys = o.sort_keys, ascii = o.ascii, colors = &run.colors if o.color else nil, drop_comments = !FORMATS[o.to].keeps_comments}
}

// The output held so far written, when it passes FLUSH_AT bytes, when `force`d, and under --unbuffered.
flush_some :: proc(run: ^Run, force := false) {
	if output_due(run, force) {
		write_out(run.out[:])
		clear(&run.out)
	}
}

// Whether the run's output is to be written now (`flush_some`).
output_due :: #force_inline proc(run: ^Run, force := false) -> bool {
	return !run.held && !run.silent && (len(run.out) >= FLUSH_AT || ((force || run.opts.unbuffered) && len(run.out) > 0))
}

// What `run.spill` calls: the output held so far written, if it has passed FLUSH_AT.
spill_out :: proc(data: rawptr) {
	flush_some((^Run)(data))
}

// The first failed write to stdout, which jq ends the run on. Process-wide, as stdout is.
@(private = "file")
output_failed: bool
@(private = "file")
output_error: os.Error
@(private = "file")
output_lock: sync.Mutex

// `p` written to stdout in full (`write_stdout`). A failed write is kept (the first), and nothing more is written
// after it. The main thread, which `worker` is not, ends the run.
write_out :: proc(p: []byte, worker := false, pool: ^host.Batch_Pool = nil) {
	if !sync.atomic_load(&output_failed) {
		if pool != nil {
			host.batch_writing(pool, true)
		}
		err := write_stdout(p)
		explain_output(len(p))
		if pool != nil {
			host.batch_writing(pool, false)
		}
		if err != nil {
			sync.guard(&output_lock)
			output_error = err
			sync.atomic_store(&output_failed, true)
		}
	}
	if !worker {
		check_output()
	}
}

// End the run as jq does when its output cannot be written: its message, and the exit status of a system error.
check_output :: proc() {
	if sync.atomic_load(&output_failed) {
		fmt.eprintf("stury: error: writing output failed: %s\n", strerror(output_error))
		os.exit(EXIT_USAGE)
	}
}
