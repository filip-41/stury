package main

// `stury check` validates each input as `stury .` reads it and prints nothing. An input of no text fails, as the
// library refuses an empty document. Its caps are the library's with the digit and scale caps lifted (`jq.lifted`),
// or held under --strict-limits, and nesting is capped at --max-depth either way. --ndjson and --seq validate each
// record as one text, and --jsonc reads JSONC as the library does, which jq does not.

import "core:bytes"
import "core:fmt"
import "core:strings"
import json "../../json"
import "jq"

// check: each file in turn, and how many did not open or read.
check_files :: proc(run: ^Run, files: []string) -> (failures: int) {
	for &f in files {
		ins: Inputs
		inputs_init(&ins, run, ([^]string)(&f)[:1])
		open_next(&ins)
		if ins.failures > 0 {
			failures += 1
			continue
		}
		check_input(run, &ins)
		free_data({ins.data, ins.mapped})
	}
	return
}

// check on one input, read whole.
@(private = "file")
check_input :: proc(run: ^Run, ins: ^Inputs) {
	run.name, run.whole = ins.name, ins.data
	if reads_cells(&run.opts) {
		check_cells(run, ins)
		return
	}
	// No text: no JSON document, as the library's `.Truncated` for an empty one. Under --seq an empty input is
	// no records, as jq reads it.
	blank := !run.opts.seq
	for c in bytes.trim_prefix(ins.data, UTF8_BOM[:]) {
		if !jq.is_space(c) {
			blank = false
			break
		}
	}
	if blank {
		fail_input(run, {kind = .Truncated, offset = u64(len(ins.data))}, "No JSON text")
	}
	switch {
	case run.opts.from == .Ndjson || run.opts.seq:
		check_records(run, ins.data)
	case run.opts.from == .Jsonc:
		if e, bad := json.validate(ins.data, .Jsonc, limits = check_limits(run)).?; bad {
			fail_input(run, e)
		}
	case:
		check_texts(run, ins)
	}
}

// Runs `check` on one CSV input. An input of only a byte order mark fails as an input with no JSON
// text does. A fault is reported with the message a filter run gives.
@(private = "file")
check_cells :: proc(run: ^Run, ins: ^Inputs) {
	dialect := FORMATS[run.opts.from].dialect
	msg: string
	if len(bytes.trim_prefix(ins.data, UTF8_BOM[:])) == 0 {
		e := json.Error {
			kind   = .Truncated,
			offset = u64(len(ins.data)),
		}
		msg = fault_in_file(ins.name, ins.data, e, fmt.tprintf("No %s text", strings.to_upper(FORMATS[run.opts.from].name, context.temp_allocator)))
	} else {
		msg = check_cells_text(ins, dialect, batch_runner(run, len(ins.data)))
	}
	if msg != "" {
		flush_some(run, force = true)
		fmt.eprintf("stury: error: %s\n", msg)
		finish(run, EXIT_USAGE if run.unopened else EXIT_INPUT)
	}
}

// The caps check validates against.
@(private = "file")
check_limits :: proc(run: ^Run) -> json.Limits {
	return {max_depth = jq.lifted.max_depth} if run.opts.strict_limits else jq.lifted
}

// The texts of the open file, until one is refused, which ends the run.
@(private = "file")
check_texts :: proc(run: ^Run, ins: ^Inputs) {
	limits := check_limits(run)
	for {
		at, limit, trailing, found := next_text(ins)
		if !found {
			return
		}
		src := ins.data[at:limit]
		end := len(src)
		e, bad := json.validate(src, limits = limits).?
		if bad && e.kind == .Trailing && trailing {
			end, bad = int(e.offset), false
		}
		if bad {
			e = cut_by_next_byte(ins.data, at, limit, e, .Json, limits)
			e.offset += u64(at)
			fail_input(run, e)
		}
		ins.pos = at + end
	}
}

// Every record of `src`, validated in parallel by `validate_records` against the library's own caps: a record it
// refuses is validated again against check's, and the first fault that stands ends the run.
@(private = "file")
check_records :: proc(run: ^Run, src: []byte) {
	framing := json.Framing.NDJSON if run.opts.from == .Ndjson else .JSON_Seq
	// A buffer of one NDJSON record has nothing to share among workers: the caller validates it alone.
	nl := bytes.index_byte(src, '\n')
	lone := run.opts.from == .Ndjson && (nl < 0 || nl + 1 == len(src))
	faults, err := json.validate_records(src, framing, nil if lone else batch_runner(run, len(src)))
	defer delete(faults)
	limits := check_limits(run)
	// The framing fault stands unless a record before it does. Under --seq a `.Truncated` one is a number the next
	// separator or the input's end may have cut.
	first := err
	for f in faults {
		if e, bad := json.validate(src[f.lo:f.hi], limits = limits).?; bad {
			e = cut_by_next_byte(src, int(f.lo), int(f.hi), e, .Json, limits)
			e.offset += f.lo
			first = e
			break
		}
	}
	if e, bad := first.?; bad {
		fail_input(run, e, jq.TRUNCATED_NUMBER_NOTE if first == err && e.kind == .Truncated else "")
	}
}
