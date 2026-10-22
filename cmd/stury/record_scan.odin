package main

// Answers a path over a file of one record per line in parallel, and prints the answers in input order.
//
// A path the scan answers, once a file's texts are seen one per line (`records_after`): the open file's records
// scanned on the batch pool in `json.each_record`'s pieces of whole lines, each piece's answers printed into a buffer
// of its own and written as soon as the pieces before it are. A record that is anything but a well-formed text whose
// answers are found or missing (a fault, a byte order mark, a lone high surrogate, a step that does not apply, a
// literal that may run on into the next file) ends its piece there, and the records from it on are left to
// `scan_inputs`, one at a time, as before. `select(P op LITERAL)` is scanned as P, and each record its answer keeps
// is printed in place of answers.

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import json "../../json"

Record_Piece :: struct {
	out:      [dynamic]byte,
	ret:      int, // jq's result for the piece's last record, when it answered one
	answered: bool,
	done:     bool,
	stop:     int, // the record the piece left to `scan_inputs`, or -1
}

Record_Scan :: struct {
	run:     ^Run,
	src:     []byte, // the file's records: its data from where they start
	more:    bool, // another file follows
	// The pieces by `json.each_record`'s number, each printed once those before it are, up to the first
	// record left to `scan_inputs`, `stop`, or -1. A printed piece's buffer is a spare for another piece,
	// since a fresh one costs more than a piece of small answers.
	lock:    sync.Mutex,
	arena:   virtual.Arena,
	pieces:  [dynamic]Record_Piece,
	spare:   [dynamic][dynamic]byte,
	printed: int,
	stop:    int,
	// The output written while the lock is let go: its holder owns `writing`, with the held output swapped into
	// `wbuf`, so that one thread writes at a time and in order, and the others go on appending to the run's.
	writing: bool,
	wbuf:    [dynamic]byte,
}

// Answer the open file's records from byte `from` on, on the pool, up to the first record `scan_inputs` must
// read itself: where that one starts, or the file's end. Below two batch workers' worth, `from`.
scan_records :: proc(run: ^Run, ins: ^Inputs, from: int) -> (stop: int) {
	src := ins.data[from:]
	runner := batch_runner(run, len(src))
	if runner == nil {
		return from
	}
	job := Record_Scan{run = run, src = src, more = ins.next_file < len(ins.files), stop = -1}
	job.pieces.allocator = virtual.arena_allocator(&job.arena)
	job.spare.allocator = job.pieces.allocator
	defer virtual.arena_destroy(&job.arena)
	defer delete(job.wbuf)
	reserve(&job.wbuf, cap(run.out))
	json.each_record(src, .NDJSON, scan_piece, &job, runner)
	// A write a pool thread met failing ends the run here.
	check_output()
	return from + job.stop if job.stop >= 0 else len(ins.data)
}

// Piece `k`'s records, answered into its buffer by a copy of the run that holds its output, then the pieces now in
// turn printed. It returns false once a record is left to `scan_inputs`.
@(private = "file")
scan_piece :: proc(data: rawptr, piece: ^json.Records, k: int) -> bool {
	job := (^Record_Scan)(data)
	p := Record_Piece{done = true, stop = -1}
	// Copied under the lock, as another piece may be printing through the run.
	sync.lock(&job.lock)
	run := job.run^
	run.out = pop_safe(&job.spare) or_else make([dynamic]byte, 0, len(piece.src) - piece.pos, job.pieces.allocator)
	sync.unlock(&job.lock)
	run.held = true
	req: json.Request({.Path})
	req.dialect, req.limits, req.paths = run.req.dialect, run.req.limits, run.req.paths
	req.allocator = runtime.heap_allocator()
	defer json.destroy(&req)
	// Planned once for the piece's records. A refusal is each record's scan's too, which leaves the record to
	// `scan_inputs`.
	prepared, _ := json.prepare(&req)
	// The path without `per_element`, tried first as `scan_outputs` tries it. On the heap, as a request and plan
	// zeroed on the stack cost each piece of a path with no trial.
	trial: ^Record_Trial
	if run.tried {
		trial = new(Record_Trial, req.allocator)
		trial.req = {dialect = req.dialect, limits = req.limits, paths = run.paths[1:], allocator = req.allocator}
		trial.prepared, _ = json.prepare(&trial.req)
	}
	defer if trial != nil {
		json.destroy(&trial.req)
		free(trial, req.allocator)
	}
	src := job.src
	for rec in json.next_record(piece) {
		lo := int(rec.at)
		hi := lo + len(rec.bytes)
		answers, settled := answers_settled(&prepared, &trial.prepared if trial != nil else nil, src[lo:hi], job.more && hi == len(src))
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
	sync.lock(&job.lock)
	defer sync.unlock(&job.lock)
	if k >= len(job.pieces) {
		resize(&job.pieces, k + 1)
	}
	job.pieces[k] = p
	for ; job.stop < 0 && job.printed < len(job.pieces) && job.pieces[job.printed].done; job.printed += 1 {
		q := &job.pieces[job.printed]
		if q.answered {
			append(&job.run.out, ..q.out[:])
			job.run.ret = q.ret
		}
		clear(&q.out)
		append(&job.spare, q.out)
		job.stop = q.stop
	}
	// The held output is written with the lock let go, so another piece can be printed meanwhile, and only by
	// one thread at a time, so that what is written stays in order.
	for !job.writing && output_due(job.run) {
		job.writing = true
		job.run.out, job.wbuf = job.wbuf, job.run.out
		sync.unlock(&job.lock)
		write_out(job.wbuf[:], worker = true, pool = &job.run.pool)
		clear(&job.wbuf)
		sync.lock(&job.lock)
		job.writing = false
	}
	return p.stop < 0
}

@(private = "file")
Record_Trial :: struct {
	req:      json.Request({.Path}),
	prepared: json.Prepared({.Path}),
}

// Scan `record` into `p`'s request, or first `trial`'s (`trial_answered`): its outputs (`jq_outputs`), and whether it
// is a text the scan reads whole with every output found or missing, which print as `scan_inputs` would print them,
// `last` when it ends the file and another file follows.
@(private = "file")
answers_settled :: proc(p, trial: ^json.Prepared({.Path}), record: []byte, last: bool) -> (answers: []json.Path_Answer, ok: bool) {
	if record[0] == UTF8_BOM[0] || last && is_literal_byte(record[len(record) - 1]) {
		return
	}
	if trial != nil && trial_answered(trial, record) {
		return trial.req.answers[:], true
	}
	if #force_inline json.scan(record, p) != nil {
		return
	}
	answers = jq_outputs(p.req.answers[:])
	for a in answers {
		if a.outcome != .Found && a.outcome != .Missing {
			return
		}
	}
	return answers, true
}

// Whether `trial`'s scan of `record`, the path without `per_element`, answers each entry of its root array, as
// `scan_outputs` tries a text. Out of line, so `answers_settled` inlines only its own scan.
@(private = "file")
trial_answered :: #force_no_inline proc(trial: ^json.Prepared({.Path}), record: []byte) -> bool {
	return json.scan(record, trial) == nil && array_entries_answered(trial.req.answers[:], record)
}
