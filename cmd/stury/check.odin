package main

// `stury check` validates each input as `stury .` reads it and prints nothing. An input of no text fails, as the
// library refuses an empty document. Its caps are the library's with the digit and scale caps lifted (`jq.lifted`),
// or held under --strict-limits, and nesting is capped at --max-depth either way. --from ndjson and --seq validate each
// record as one text, and --from jsonc reads JSONC as the library does, which jq does not.

import "core:bytes"
import core_pkg "../../core"
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
	// No text: no document, as the library's `.Truncated` for an empty one. Under --seq an empty input is no
	// records, as jq reads it.
	cells := reads_cells(&run.opts)
	body := ins.data[core_pkg.bom_len(ins.data):]
	if cells && len(body) == 0 || !cells && !run.opts.seq && skip_blank(body, 0, false, json.grammar_of(run.read.dialect) != {}) == len(body) {
		fail_input(run, {kind = .Truncated, offset = u64(len(ins.data))}, no_text(&run.opts))
	}
	switch {
	case cells:
		if msg := check_cells_text(ins, cells_in(&run.opts), batch_runner(run, len(ins.data))); msg != "" {
			fail_message(run, msg)
		}
	case reads_lines(&run.opts) || run.opts.seq:
		check_records(run, ins.data)
	case json.grammar_of(run.read.dialect) != {}:
		if e, bad := json.validate(ins.data, {dialect = source_dialect(&run.opts), limits = check_limits(run)}).?; bad {
			fail_input(run, e)
		}
	case:
		check_texts(run, ins)
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
		read := json.validate(ins.data[at:limit], {limits = limits}, batch_runner(run, limit - at))
		e, bad := read.?
		if bad && (e.kind != .Trailing || !trailing) {
			rec := json.Record{bytes = ins.data[at:limit], at = u64(at)}
			_, judged := json.judge_record(ins.data, rec, e, {read = {limits = limits}})
			e = judged.?
			e.offset += u64(at)
			fail_input(run, e)
		}
		// An array, object or string ends where its read stops, and the file is read whole, so no read is cut.
		ins.pos = at + int(e.offset) if bad else limit
	}
}

// Every record of `src`, validated in parallel by `validate_records` against the library's own caps: a record it
// refuses is validated again against check's, and the first fault that stands ends the run.
@(private = "file")
check_records :: proc(run: ^Run, src: []byte) {
	framing := json.Framing.NDJSON if reads_lines(&run.opts) else .JSON_Seq
	// A buffer of one NDJSON record has nothing to share among workers: the caller validates it alone.
	nl := bytes.index_byte(src, '\n')
	lone := reads_lines(&run.opts) && (nl < 0 || nl + 1 == len(src))
	faults, err := json.validate_records(src, {framing = framing}, nil if lone else batch_runner(run, len(src)))
	defer delete(faults)
	limits := check_limits(run)
	// The framing fault stands unless a record before it does.
	first := err
	for f in faults {
		if e, bad := json.validate(src[f.lo:f.hi], {limits = limits}).?; bad {
			rec := json.Record{bytes = src[f.lo:f.hi], at = f.lo}
			_, judged := json.judge_record(src, rec, e, {read = {limits = limits}, framing = framing})
			e = judged.?
			e.offset += f.lo
			first = e
			break
		}
	}
	if e, bad := first.?; bad {
		fail_input(run, e)
	}
}
