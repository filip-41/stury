package main

// `stury check` judges each input as `stury .` reads it and prints nothing. Each file's first fault is told, as the
// filter run tells a JSONC text's, and a JSON input with no text in it fails, as the library refuses an
// empty document. An empty table is valid, as the library takes it. --from ndjson and --seq judge each record as a
// text, and a long input is judged on the threads of a pool.

import "base:runtime"
import "core:os"
import core "../../core"
import records "../../core/records"
import "jq"
import "message"

// Each file in turn. Exits 0, 2 after a file that did not open or read, or else 5 after a fault, or else 1 after a schema failure.
check_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	if len(cli.files) == 0 && is_terminal(os.stdin) && is_terminal(os.stdout) {
		// As stury with no filter, rather than wait on the keyboard.
		usage(EXIT_USAGE, true)
	}
	src := input_source(o, cli.json_reading)
	failures, faults, invalid := 0, 0, 0
	sc: ^Schema_Check
	if cli.schema.flag != "" {
		sc = schema_open(cli.schema, src)
	}
	for path in (cli.files[:] if len(cli.files) > 0 else STDIN_ONLY) {
		spent, read := file_bytes(path, "check")
		if !read {
			failures += 1
			continue
		}
		data := spent.data
		runner: ^core.Runner
		if len(data) >= POOLED_BYTES {
			runner = run_pool(run)
		}
		verdict, why := Verdict.Fault, core.Error(nil)
		if sc != nil && !(reads_cells(o) && header_fault(file_name(path), data, src.as) != "") {
			verdict, why = schema_judge(sc, cli.schema, file_name(path), data, src, runner)
		}
		switch verdict {
		case .Valid:
		case .Invalid:
			invalid += 1
		case .Refused:
			failures += 1
		case .Fault:
			if msg := check_text(file_name(path), data, src, o, runner); msg != "" {
				message.write_stderr("stury: parse error: %s", msg)
				faults += 1
			} else if why != nil {
				message.write_stderr("stury: parse error: %s: %s\n", file_name(path), edit_error_text(data, why))
				faults += 1
			}
		}
		free_spent(spent)
		free_all(context.temp_allocator)
	}
	os.exit(EXIT_USAGE if failures > 0 else EXIT_INPUT if faults > 0 else 1 if invalid > 0 else 0)
}

// The first fault of the text `data` of file `name`, read as `src` reads it, told with its note and a newline, or "".
@(private = "file")
check_text :: proc(name: string, data: []byte, src: Source, o: ^Opts, runner: ^core.Runner) -> string {
	if msg := blank_told(name, data, src, o); msg != "" {
		return msg
	}
	fault: Maybe(core.Fault)
	switch {
	case reads_cells(o):
		if msg := header_fault(name, data, src.as); msg != "" {
			return msg
		}
		fault = records.validate_parallel(data, src.as, runner)
	case reads_own(o):
		fault = records.validate_parallel(data, src.as, runner)
	case src.framing == .Concatenated:
		fault = records.validate_parallel(data, src.as, runner)
		// A byte no text starts with, right after a text, stays trailing text, as the reader of the texts from the first
		// tells it. So does a text that runs on into the next, which only the reader from a scalar first text sees.
		if f, bad := fault.?; bad && texts_follow(f, src.format) {
			from := f.at if closed_first(data) else 0
			if next, more := first_fault(data, src.as, .Concatenated, runner, from).?; !more || next.at != f.at || jq.is_space(data[f.at - 1]) {
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
	return message.build_temp("%s\n%s", fault_told(name, data, f), fault_note(name, data, f, src.spec, o))
}

// The fault of a JSON input with no text in it, `data` of file `name`, told with a newline, or "".
blank_told :: proc(name: string, data: []byte, src: Source, o: ^Opts) -> string {
	if reads_cells(o) || o.seq || !blank_input(data, src.spec) {
		return ""
	}
	line, col := core.locate(data, u64(len(data)))
	return message.build_temp("%s:%d:%d: No JSON text\n", name, line, col)
}

// Whether the first text of `data` is a container or a string, which no byte after its close runs on from.
@(private = "file")
closed_first :: proc(data: []byte) -> bool {
	for c in data {
		if !jq.is_space(c) {
			return c == '[' || c == '{' || c == '"'
		}
	}
	return false
}

// The first fault of the records of `data` from byte `at`, framed by `framing`.
first_fault :: proc(data: []byte, as: core.As, framing: core.Framing, runner: ^core.Runner, at: u64) -> Maybe(core.Fault) {
	heap := runtime.heap_allocator()
	faults, err := records.check(data, as, framing, heap, runner, at)
	defer delete(faults, heap)
	if err != nil {
		return core.Fault{kind = .No_Memory}
	}
	return faults[0] if len(faults) > 0 else nil
}
