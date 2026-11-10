package records

import "base:runtime"
import "core:sync"
import core ".."
import typed "../typed"

// A check of one record's text: adds the failures it finds to `sink`, nil for a verdict only, with offsets from the text's
// first byte and the record index `sink.record`, and returns the first failure. A `.Walk` failure ends the records. It runs
// on any thread of a run, so it holds no state of its own.
Record_Check :: #type proc(data: rawptr, text: []u8, sink: ^typed.Sink) -> core.Typed_Error

// What one piece of a check found: its records' failures, the records it read, the first failure it met and whether it
// stopped on a `.Walk` failure, which an earlier failure of the piece does not hide.
@(private)
Checked :: struct {
	sink:    typed.Sink,
	records: i64,
	failure: core.Typed_Error,
	ended:   bool,
}

@(private)
Check_Job :: struct {
	check:  Record_Check,
	data:   rawptr,
	collect: bool,
	max:    int,
	allocator: runtime.Allocator,
	lock:   sync.Mutex,
	pieces: [dynamic]Checked,
}

// Checks each record of `src` read from byte `at` under `framing` by `check`, on the threads of `runner` when it has
// any, and gives the answer one thread gives. The failures go to `sink` in source order with record indexes counted from
// the first record, up to its `max_errors`, and with a runner the sink's entries are allocated with the heap, so a sink
// with an allocator of its own is checked on this thread. The result is the number of records read and the first failure,
// whose kind is `.None` for none, and whether the records ended on a fault, which is a `.Walk` entry after the failures
// before it. With no sink the check stops at the first failure.
check_each :: proc(src: []u8, as: core.As, framing: core.Framing, check: Record_Check, data: rawptr, sink: ^typed.Sink = nil, runner: ^core.Runner = nil, at: u64 = 0) -> (records: i64, failure: core.Typed_Error, ended: bool) {
	heap := runtime.heap_allocator()
	runner := runner
	if sink != nil && sink.entries.allocator.procedure != nil && sink.entries.allocator.procedure != heap.procedure {
		runner = nil
	}
	if sink != nil && sink.entries.allocator.procedure == nil {
		sink.entries.allocator = heap if runner != nil else context.allocator
	}
	job := Check_Job{check = check, data = data, collect = sink != nil, max = sink.max_errors if sink != nil else 0}
	if sink != nil {
		job.allocator = sink.entries.allocator
	}
	job.pieces.allocator = heap
	defer {
		for &p in job.pieces {
			typed.sink_destroy(&p.sink)
		}
		delete(job.pieces)
	}
	fault := each_piece(src, as, nil, framing, cast(proc(data: rawptr, piece: ^Reader, k: int) -> bool)check_piece, &job, runner, at)
	cut := max(u64)
	if f, bad := fault.?; bad {
		cut = f.at
	}
	for &p in job.pieces {
		for &e in p.sink.entries {
			if e.start >= cut {
				continue
			}
			e.record += records
			if sink == nil || len(sink.entries) >= (sink.max_errors if sink.max_errors != 0 else 100) {
				if sink != nil {
					sink.truncated = true
				}
				continue
			}
			if _, err := append(&sink.entries, e); err != nil {
				sink.truncated = true
				continue
			}
			e = {}
		}
		if sink != nil {
			sink.truncated ||= p.sink.truncated
		}
		records += p.records
		if failure.kind == .None {
			failure = p.failure
		}
		if p.ended {
			return records, failure, true
		}
	}
	if f, bad := fault.?; bad {
		walk := core.Typed_Error{kind = .Walk, inner = f, at = f.at}
		failure = walk if failure.kind == .None else failure
		if sink != nil && len(sink.entries) < (sink.max_errors if sink.max_errors != 0 else 100) {
			append(&sink.entries, core.Error_Entry{kind = .Walk, start = f.at, end = f.at, record = records})
		}
		return records, failure, true
	}
	return
}

// A piece's task: checks its records in order, and keeps what it finds for the merge.
@(private)
check_piece :: proc(job: ^Check_Job, it: ^Reader, k: int) -> bool {
	p := Checked{}
	p.sink.max_errors = job.max
	p.sink.entries.allocator = job.allocator
	for {
		rec, more := next(it)
		if !more {
			break
		}
		first := len(p.sink.entries)
		p.sink.record = p.records
		e := job.check(job.data, rec.text, &p.sink if job.collect else nil)
		for &x in p.sink.entries[first:] {
			x.start += rec.at
			x.end += rec.at
		}
		p.records += 1
		if e.kind == .None {
			continue
		}
		core.move_typed_error(&e, rec.at)
		p.failure = e if p.failure.kind == .None else p.failure
		p.ended = e.kind == .Walk
		if !job.collect || p.ended {
			break
		}
	}
	more := p.failure.kind == .None || job.collect && !p.ended
	sync.guard(&job.lock)
	if k >= len(job.pieces) {
		resize(&job.pieces, k + 1)
	}
	job.pieces[k] = p
	return more
}

// The entries of the root array of `src` as `check_each` reads them, when the array's bulk is cut exactly so that its
// entries can be checked in pieces: the handle to check them with and the byte they start from. False for any other text.
entries_of :: proc(src: []u8, as: core.As) -> (whole: core.As, at: u64, ok: bool) {
	services := services_of(as)
	if services == nil || services.whole == nil {
		return
	}
	framing: core.Framing
	whole, framing, at = services.whole(src, as)
	return whole, at, framing == .Entries && entries_cut(src, whole, framing, at)
}
