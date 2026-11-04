package main

// `stury check` judges each input as `stury .` reads it and prints nothing. The run ends at the first fault, told as
// the filter run tells a JSONC text's, and an input with no text in it fails, as the library refuses an empty
// document. --from ndjson and --seq judge each record as a text, and a long input is judged on the threads of a pool.

import "base:runtime"
import "core:os"
import "core:strings"
import core "../../core"
import records "../../core/records"
import json "../../json"
import "jq"
import "message"

// Each file in turn, until one holds a fault. Exits 0, 2 after a file that did not open or read, or 5 at a fault.
check_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	if len(cli.files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
		// As stury with no filter, rather than wait on the keyboard.
		usage(EXIT_USAGE, true)
	}
	src := input_source(o, cli.json_reading)
	failures := 0
	for path in (cli.files[:] if len(cli.files) > 0 else STDIN_ONLY) {
		f, read := open_file(path)
		data: []byte
		if read {
			data, read = read_file(f)
		}
		if !read {
			failures += 1
			continue
		}
		runner: ^core.Runner
		if len(data) >= POOLED_BYTES {
			runner = run_pool(run)
		}
		if msg := check_text(file_name(path), data, src, o, runner); msg != "" {
			message.write_stderr("stury: error: %s", msg)
			os.exit(EXIT_USAGE if failures > 0 else EXIT_INPUT)
		}
		delete(data, runtime.heap_allocator())
	}
	os.exit(EXIT_USAGE if failures > 0 else 0)
}

// The first fault of the text `data` of file `name`, read as `src` reads it, told with its note and a newline, or "".
@(private = "file")
check_text :: proc(name: string, data: []byte, src: Source, o: ^Opts, runner: ^core.Runner) -> string {
	cells := reads_cells(o)
	if cells && len(strings.trim_prefix(string(data), "\xef\xbb\xbf")) == 0 ||!cells && !o.seq && json.blank(data, json.Spec(src.as.spec)) {
		line, col := core.locate(data, u64(len(data)))
		return message.build_temp("%s:%d:%d: %s\n", name, line, col, no_text(o))
	}
	fault: Maybe(core.Fault)
	switch {
	case cells:
		if msg := header_fault(name, data, src.as); msg != "" {
			return msg
		}
		fault = records.validate(data, src.as, runner)
	case src.framing == .Concatenated:
		fault = records.validate(data, src.as, runner)
		// Strict JSON reads texts one after another, which `validate`, judging one, refuses as trailing text. A byte no
		// text starts with, right after a text, stays trailing text, as the reader of the texts from the first tells it.
		if f, bad := fault.?; bad && json.Spec(src.as.spec) == .Json && f.rules == &json.RULES && f.detail == u8(json.Detail.Trailing) {
			if next, more := first_fault(data, src.as, .Concatenated, runner, f.at).?; !more || next.at != f.at || jq.is_space(data[f.at - 1]) {
				fault = next if more else nil
			}
		}
	case:
		fault = first_fault(data, src.as, src.framing, runner, 0)
	}
	f, bad := fault.?
	if !bad {
		return ""
	}
	f = literal_cut(data, f, src.framing)
	return message.build_temp("%s\n%s", fault_told(name, data, f, src.as), fault_note(data, f, src.as, o))
}

// The first fault of the records of `data` from byte `at`, framed by `framing`.
@(private = "file")
first_fault :: proc(data: []byte, as: core.As, framing: core.Framing, runner: ^core.Runner, at: u64) -> Maybe(core.Fault) {
	heap := runtime.heap_allocator()
	faults, err := records.check(data, as, framing, heap, runner, at)
	defer delete(faults, heap)
	if err != nil {
		return core.Fault{kind = .No_Memory}
	}
	return faults[0] if len(faults) > 0 else nil
}

// A header that names a column twice, told with a newline, or "". A header the format refuses is `validate`'s to tell.
@(private = "file")
header_fault :: proc(name: string, data: []byte, as: core.As) -> string {
	it := records.open(data, as, .Lines, allocator = runtime.heap_allocator())
	defer records.close(&it)
	rec, more := records.next(&it)
	if !more {
		return ""
	}
	doc, err := records.build(&it, rec, context.temp_allocator)
	if err.kind != .None {
		return ""
	}
	msg, twice := repeated_header(name, data, &doc)
	return message.build_temp("%s\n", msg) if twice else ""
}
