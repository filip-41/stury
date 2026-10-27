package main

// The path scan over the input stream: each text answered by the scan, a large file's root read in pieces, and lines
// of records handed to `scan_records`. A text the scan cannot answer leaves the rest of the stream to the
// interpreter.

import "core:bytes"
import "core:mem/virtual"
import json "../../json"
import "jq"

// Whether the record `src`, whose path answer `a` was found or missing, is one `select` keeps.
selects :: proc(run: ^Run, src: []byte, a: json.Answer) -> bool {
	x: jq.Value
	if a.outcome == .Found {
		if a.kind == .Array || a.kind == .Object {
			// Above every literal the filter may hold.
			return jq.compared(run.select.op, 1)
		}
		x = jq.span_value(src, a.lo, a.hi, a.kind, context.temp_allocator)
	}
	return jq.compared(run.select.op, jq.compare(x, run.select.literal, eq = run.select.op == .Eq || run.select.op == .Ne))
}

// Answer the path over each text of the stream. From a text the scan cannot answer or that does not parse, the
// interpreter reads the rest of the stream, and tells the fault as jq does.
scan_inputs :: proc(run: ^Run, ins: ^Inputs) {
	pieces := json.plain_json(run.req.dialect) && !run.held
	built: virtual.Arena // the last text built in pieces, emptied once another is
	// As jq's main loop, each text is read only while no file has failed.
	for ins.failures == 0 {
		// A path's answers are printed as they are found, so no value outlives its text.
		free_spent(ins)
		at, limit, trailing, found := next_text(ins)
		if !found {
			break
		}
		run.name, run.whole = ins.name, ins.data
		explain_engines(run, ins.data[at:limit])
		// A stream's window after one read as records starts with records too: they go to the pool from its
		// first line, which a scan of the window alone would index whole.
		if ins.line_records && !ins.lines_tried && (at == 0 || ins.data[at - 1] == '\n') {
			ins.lines_tried = true
			ins.pos = records_from(run, ins, at)
			continue
		}
		src := ins.data[at:limit]
		if pieces && trailing && limit == len(ins.data) {
			// Set before the filter runs, as its error tells the line jq's reader is on (`input_position`).
			ins.seen = last_read(ins.data, at, limit)
			interpreted := run.explain.interpreted
			if spine_pieces(run, ins.data, at, &built) {
				explain_root(run, interpreted)
				ins.pos = limit
				continue
			}
		}
		// A JSONC text's comments print with the values they are attached to, which only the interpreter's
		// values know: a text with a `/` in it, a comment's or a string's, is the interpreter's.
		if json.has_comments(run.req.dialect) && bytes.index_byte(src, '/') >= 0 {
			explain_fallback(run, .Comment_Slash, rest = true)
			run_filter(run, ins)
			return
		}
		answers, end, err, refused := scan_outputs(run, src, trailing)
		if refused {
			explain_fallback(run, .Scan_Limit, rest = true)
			run_filter(run, ins)
			return
		}
		if err == nil {
			ins.pos, ins.seen = at + end, last_read(ins.data, at, at + end)
			// A `[]` path's texts are alike more often than not: once jq's rules settle one, they read the rest,
			// which the scan would only read first.
			mismatch := run.any_at >= 0 && len(answers) == 1 && answers[0].outcome == .Type_Mismatch
			explain_answered(run, answers, mismatch)
			print_answers(run, answers, src[:end], u64(at))
			if mismatch {
				run_filter(run, ins)
				return
			}
			if (ins.resume || !ins.lines_tried) && json.plain_json(run.req.dialect) {
				ins.resume = false
				records_after(run, ins)
			}
			continue
		}
		if read_on(ins, at) {
			continue
		}
		if !json.plain_json(run.req.dialect) {
			jsonc_fault(ins, err.?, at)
		}
		explain_fallback(run, .Bad_Text, rest = true)
		run_filter(run, ins)
		return
	}
}

// The rest of a large file, the text data[at:], read in its root's pieces, in parallel, where a scan would read it on
// one thread: when the path names its spine's array (`.`, or `.a.b` of `{"a": {"b": [...]}}`), that array validated
// and printed from the text. Under any other filter the root built and the filter run on it. It returns false, with
// nothing printed, when the text is not one the pieces read.
spine_pieces :: proc(run: ^Run, data: []byte, at: int, built: ^virtual.Arena) -> bool {
	steps := run.paths[0].steps
	if run.any_at >= 0 {
		// Over the spine's entries in pieces. Any other `[]` reads quicker on one thread's scan than built in pieces
		// and run on the interpreter.
		spine, ok := root_spine(data, at)
		defer spine_free(&spine)
		over_spine := ok && spine_named(&spine, steps[:run.any_at])
		return over_spine && iterate_root_pieces(run, data, spine.lo, spine.z, spine.levels)
	}
	if run.select.op == .None && len(steps) == 0 {
		return print_root_pieces(run, data[at:], validate = true)
	}
	if run.select.op == .None {
		spine, ok := root_spine(data, at)
		defer spine_free(&spine)
		if ok && spine.levels > 0 && spine_named(&spine, steps) {
			return print_root_pieces(run, data[spine.lo:spine.z + 1], validate = true, above = spine.levels)
		}
	}
	return run_root_pieces(run, data, at, built)
}

// `scan_records` from `from`. When it leaves a record after reading at least a first worker's worth, the lines after
// that record are tried again once it is answered (`resume`), so one odd record among many leaves only itself to the
// scan. A batch that leaves one at once is not tried again.
records_from :: proc(run: ^Run, ins: ^Inputs, from: int) -> (stop: int) {
	stop = scan_records(run, ins, from)
	ins.resume = stop < len(ins.data) && stop - from >= BATCH_BYTES_PER_FIRST_WORKERS
	return
}

// The lines of the open file after the text just answered, read as NDJSON records, in parallel, when
// that text ends its line and the next line holds a text of its own: jq reads such lines as texts one after
// another, so the answers are the same. The records go up to one that is anything else (`scan_records`),
// and the stream goes on from there.
records_after :: proc(run: ^Run, ins: ^Inputs) {
	data := ins.data
	// The scan may have read on through the space after the text.
	from := ins.pos
	for from > 0 && jq.is_space(data[from - 1]) {
		from -= 1
	}
	for from < len(data) && (data[from] == ' ' || data[from] == '\t' || data[from] == '\r') {
		from += 1
	}
	if from == len(data) || data[from] != '\n' {
		return
	}
	from += 1
	it := json.records(data[from:], {framing = .NDJSON})
	rec, found := json.next_record(&it)
	n := len(data) - from
	// A stream comes a window at a time: once a window pays for the pool, it is sized for the windows to come.
	if ins.reader != nil && n >= 2 * BATCH_BYTES_PER_FIRST_WORKERS {
		n = max(n, 2 * READ_AHEAD)
	}
	if !found || json.validate(rec.bytes, {limits = jq.lifted}) != nil || batch_runner(run, n) == nil {
		return
	}
	ins.lines_tried, ins.line_records = true, true
	ins.pos = records_from(run, ins, from)
}

// The filter's outputs over the JSON text `src` starts with, as `scan_text` scans it. A root array's `[]`
// path is tried first without `per_element`, as `iterate_chunk` tries a chunk's: with a found answer for
// each entry, the per-element scan, on the automaton, has nothing to add.
scan_outputs :: proc(run: ^Run, src: []byte, trailing: bool) -> (answers: []json.Answer, end: int, err: Maybe(json.Error), refused: bool) {
	if run.tried {
		run.req.paths = run.paths[1:]
		end, err, refused = scan_text(run, src, trailing)
		run.req.paths = run.paths[:1]
		if err == nil && !refused && array_entries_answered(run.req.answers[:], src[:end]) {
			return run.req.answers[:], end, nil, false
		}
	}
	end, err, refused = scan_text(run, src, trailing)
	answers, _ = jq_outputs(run.req.answers[:])
	return answers, end, err, refused
}

// Scan the JSON text `src` starts with for the path: where the text ends, which is before the end of `src`
// only if `trailing`, or why the text is refused, which leaves it to the interpreter. A scan that meets another
// text after the first has read the first whole, and answered it. `refused` when the library will not scan
// it at all (a fixed limit of its engine), which leaves the text to the interpreter.
scan_text :: proc(run: ^Run, src: []byte, trailing: bool) -> (end: int, err: Maybe(json.Error), refused: bool) {
	end = len(src)
	if e, bad := json.scan(src, &run.req).?; bad {
		#partial switch e.kind {
		// A refusal, or short answers that say nothing about the text: the interpreter reads it.
		case .Over_Capacity, .Bad_Option, .Source_Too_Wide, .Out_Of_Memory:
			return 0, nil, true
		case .Trailing:
			if trailing {
				return int(e.offset), nil, false
			}
		}
		return 0, e, false
	}
	return end, nil, false
}
