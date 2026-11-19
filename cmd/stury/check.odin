package main

// `stury check` judges each input as `stury .` reads it and prints nothing. Each file's first fault is told, as the
// filter run tells a JSONC text's, and a JSON input with no text in it fails, as the library refuses an
// empty document. An empty table is valid, as the library takes it. --from ndjson and --seq judge each record as a
// text, and a long input is judged on the threads of a pool.

import "base:runtime"
import "core:os"
import kernel "../../core/kernel"
import core "../../core"
import records "../../core/records"
import "message"

// What each file's check reads: the run's source, and the schema bound to each format the files read in.
@(private = "file")
Check_Run :: struct {
	cli: ^Cli,
	src: Source,
	sc:  ^Schema_Check,
}

// Each file in turn, or on the pool's threads. Exits with the worst file's status: 2 after a file that did not open
// or read, or else 5 after a fault, or else 1 after a schema failure.
check_main :: proc(run: ^Run, cli: ^Cli) -> ! {
	o := &run.opts
	cr := Check_Run{cli, input_source(o, cli.json_reading), nil}
	if cli.schema.flag != "" {
		cr.sc = schema_open(cli.schema, cr.src)
		for f in o.froms {
			from := o.from
			o.from = f
			schema_bind(cr.sc, cli.schema, input_source(o, json_reading_of(o)))
			o.from = from
		}
	}
	fc := Files_Call{run = run, files = input_files(cli.files[:], cli.walked), job = check_file, data = &cr}
	each_file(&fc, true)
	os.exit(fc.code)
}

// Judges file `k`, its first fault told, or a schema's failures.
@(private = "file")
check_file :: proc(fc: ^Files_Call, r: ^Run, k: int, slot: ^File_Slot) {
	cr := (^Check_Run)(fc.data)
	o, path := &r.opts, fc.files[k]
	src, _ := file_source(o, path, cr.src)
	spent, read := file_bytes(path)
	if !read {
		slot.code = EXIT_USAGE
		return
	}
	defer free_spent(spent)
	defer free_all(context.temp_allocator)
	data := spent.data
	runner := pool_for(r, data)
	verdict, why := Verdict.Fault, core.Error(nil)
	if sc := cr.sc; sc != nil && !(reads_cells(o) && header_fault(file_name(path), data, src.as) != "") {
		bound := sc^
		bound.bound = sc.bounds[src.format].? or_else sc.bound
		verdict, why = schema_judge(&bound, cr.cli.schema, file_name(path), data, src, runner)
	}
	switch verdict {
	case .Valid:
	case .Invalid:
		slot.code = 1
	case .Refused:
		slot.code = EXIT_USAGE
	case .Fault:
		if msg := check_text(file_name(path), data, src, o, runner); msg != "" {
			message.write_stderr("stury: parse error: %s", msg)
			slot.code = EXIT_INPUT
		} else if why != nil {
			message.write_stderr("stury: parse error: %s: %s\n", file_name(path), edit_error_text(data, why))
			slot.code = EXIT_INPUT
		}
	}
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
	case reads_whole(o):
		fault = whole_fault(data, src.as)
	case reads_own(o):
		fault = records.validate_parallel(data, src.as, runner)
	case src.framing == .Concatenated:
		fault = records.validate_parallel(data, src.as, runner)
		// A byte no text starts with, right after a text, stays trailing text, as the reader of the texts from the first
		// tells it. So does a text that runs on into the next, which only the reader from a scalar first text sees.
		if f, bad := fault.?; bad && texts_follow(f, src.format) {
			from := f.at if closed_first(data) else 0
			if next, more := first_fault(data, src.as, .Concatenated, runner, from).?; !more || next.at != f.at || kernel.is_ws(data[f.at - 1]) {
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

// The fault of `data` as one whole text of the format `as` names, or nil.
whole_fault :: proc(data: []byte, as: core.As) -> Maybe(core.Fault) {
	switch e in core.validate(data, as) {
	case nil:
		return nil
	case core.Fault:
		return e
	case runtime.Allocator_Error, core.Document_Error, core.Path_Error, core.Typed_Error, core.Typed_Error_Kind:
	}
	return core.Fault{kind = .No_Memory}
}

// Whether the first text of `data` is a container or a string, which no byte after its close runs on from.
@(private = "file")
closed_first :: proc(data: []byte) -> bool {
	for c in data {
		if !kernel.is_ws(c) {
			return c == '[' || c == '{' || c == '"'
		}
	}
	return false
}

// The first fault of the records of `data` from byte `at`, framed by `framing`.
first_fault :: proc(data: []byte, as: core.As, framing: core.Framing, runner: ^core.Runner, at: u64) -> Maybe(core.Fault) {
	heap := runtime.heap_allocator()
	faults, err := records.validate(data, as, framing, heap, runner, at)
	defer delete(faults, heap)
	if err != nil {
		return core.Fault{kind = .No_Memory}
	}
	return faults[0] if len(faults) > 0 else nil
}
