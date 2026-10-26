package main

// Answers a path over a file of one record per line in parallel, and prints the answers in input order.
//
// A path the scan answers, once a file's texts are seen one per line (`records_after`): the open file's records
// scanned on the batch pool in `json.each_record`'s pieces of whole lines, each piece's answers printed into a buffer
// of its own and written as soon as the pieces before it are. A record that is anything but a well-formed text whose
// answers are found or missing (a fault, a byte order mark, a lone high surrogate, a step that does not apply, a
// literal that may run on into the next file) ends its piece there, and the records from it on are left to
// `scan_inputs`, one at a time. `select(P op LITERAL)` is scanned as P, and each record its answer keeps
// is printed in place of answers.

import "base:runtime"
import json "../../json"

Record_Scan :: struct {
	using output: Piece_Output,
	src:          []byte, // the file's data from the first record on
	more:         bool, // another file follows
}

// Answer the open file's records from byte `from` on, on the pool, up to the first record `scan_inputs` must
// read itself: where that one starts, or the file's end. Below two batch workers' worth, `from`.
scan_records :: proc(run: ^Run, ins: ^Inputs, from: int) -> (stop: int) {
	src := ins.data[from:]
	runner := batch_runner(run, len(src))
	if runner == nil {
		return from
	}
	job := Record_Scan{src = src, more = ins.next_file < len(ins.files)}
	start_pieces(&job, run)
	defer end_pieces(&job)
	// The fault it returns is a piece's `err`, which `scan_piece` turns into a stop for the main thread's read.
	_ = json.each_record(src, .NDJSON, scan_piece, &job, runner)
	// A write that failed on a pool thread ends the run here.
	check_output()
	stop = from + job.stop if job.stop >= 0 else len(ins.data)
	explain_records(run, ins.data[from:stop])
	return
}

// Piece `k`'s records, answered into its buffer by a copy of the run that holds its output, then the pieces now in
// turn printed. It returns false once a record is left to `scan_inputs`.
@(private = "file")
scan_piece :: proc(data: rawptr, piece: ^json.Records, k: int) -> bool {
	job := (^Record_Scan)(data)
	p := Record_Piece{done = true, stop = -1}
	run := begin_piece(job, k, len(piece.src) - piece.pos)
	req: json.Request({.Path})
	req.dialect, req.limits, req.paths = run.req.dialect, run.req.limits, run.req.paths
	req.allocator = runtime.heap_allocator()
	defer json.destroy(&req)
	// Planned once for the piece's records. A refusal is each record's scan's too, which leaves the record to
	// `scan_inputs`.
	_ = json.prepare(&req)
	// The path without `per_element`, tried first as `scan_outputs` tries it. On the heap, as a request zeroed on
	// the stack cost each piece of a path with no trial.
	trial: ^json.Request({.Path})
	if run.tried {
		trial = new(json.Request({.Path}), req.allocator)
		trial^ = {dialect = req.dialect, limits = req.limits, paths = run.paths[1:], allocator = req.allocator}
		_ = json.prepare(trial)
	}
	defer if trial != nil {
		json.destroy(trial)
		free(trial, req.allocator)
	}
	src := job.src
	for rec in json.next_record(piece) {
		lo := int(rec.at)
		hi := lo + len(rec.bytes)
		answers, settled := answers_settled(&req, trial, src[lo:hi], job.more && hi == len(src))
		if !settled {
			p.stop = lo
			break
		}
		before := len(run.out)
		print_answers(&run, answers, src[lo:hi], u64(lo))
		if run.faulted {
			// An answer a pool thread cannot print: the record is left, unprinted, to the main thread's read.
			resize(&run.out, before)
			p.stop = lo
			break
		}
		p.answered = true
	}
	// A record the framing refuses (a BOM past the first byte) is left to `scan_inputs`, which reports it.
	if e, bad := piece.err.?; bad && p.stop < 0 {
		p.stop = int(e.offset)
	}
	p.out, p.ret = run.out, run.ret
	return publish_piece(job, k, p)
}

// Scan `record` into `req`, or first `trial`'s (`trial_answered`): its outputs (`jq_outputs`), and whether it
// is a text the scan reads whole with every output found or missing, which print as `scan_inputs` would print them,
// `last` when it ends the file and another file follows.
@(private = "file")
answers_settled :: proc(req, trial: ^json.Request({.Path}), record: []byte, last: bool) -> (answers: []json.Path_Answer, ok: bool) {
	if record[0] == UTF8_BOM[0] || last && is_literal_byte(record[len(record) - 1]) {
		return
	}
	if trial != nil && trial_answered(trial, record) {
		return trial.answers[:], true
	}
	if json.scan(record, req) != nil {
		return
	}
	answers = jq_outputs(req.answers[:])
	for a in answers {
		if a.outcome != .Found && a.outcome != .Missing {
			return
		}
	}
	return answers, true
}

// Whether `trial`'s scan of `record`, the path without `per_element`, answers each entry of its root array, as
// `scan_outputs` tries a text.
@(private = "file")
trial_answered :: proc(trial: ^json.Request({.Path}), record: []byte) -> bool {
	return json.scan(record, trial) == nil && array_entries_answered(trial.answers[:], record)
}
