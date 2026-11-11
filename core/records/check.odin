package records

import "base:runtime"
import "core:sync"
import core ".."
import typed "../typed"

// What one piece of a check found: its records' failures, the records it read, the first failure it met and the fault
// that stopped it, which an earlier failure of the piece does not hide and a limit of entries does not drop.
@(private)
Checked :: struct {
	sink:    typed.Sink,
	records: i64,
	failure: core.Typed_Refusal,
	// The index in the piece of the record `failure` is the first failure of.
	failed:  i64,
	fatal:   core.Typed_Refusal,
}

@(private)
Check_Job :: struct {
	plan:   ^typed.Plan,
	outer:  ^typed.Outer,
	collect: bool,
	max:    int,
	// How a repeated key is judged, as `Read_Options` takes it.
	dups:    core.Duplicates,
	repeats: typed.Repeats,
	allocator: runtime.Allocator,
	lock:   sync.Mutex,
	pieces: [dynamic]Checked,
	// Set when a piece could not keep its result.
	no_memory: bool,
}

// Checks each record of `src` read from byte `at` under `framing` by `plan`, whose paths and keyword paths start with
// `outer` when it is given, on the threads of `runner` when it has
// any, and gives the answer one thread gives. The failures go to `sink` in source order with record indexes counted from
// the first record, up to its `max_errors`, and with a runner the sink's entries are allocated with the heap, so a sink
// with an allocator of its own is checked on this thread. The result is the number of records read and the first failure,
// whose kind is `.None` for none, and the fault the records ended on, whose kind is `.None` for none, which is a `.Walk`
// or a `.No_Memory` and outranks the failures before it. With no sink the check stops at the first failure. The last result
// is the index of the record the failure is the first of. `dups` and `repeats` are the read's, see `typed.Repeats`.
check_each :: proc(src: []u8, as: core.As, framing: core.Framing, plan: ^typed.Plan, outer: ^typed.Outer, sink: ^typed.Sink = nil, runner: ^core.Runner = nil, at: u64 = 0, dups := core.Duplicates.Default, repeats := typed.Repeats.Ignore) -> (records: i64, failure: core.Typed_Refusal, fatal: core.Typed_Refusal, failed: i64) {
	heap := runtime.heap_allocator()
	runner := runner
	if sink != nil && sink.entries.allocator.procedure != nil && sink.entries.allocator.procedure != heap.procedure {
		runner = nil
	}
	if sink != nil && sink.entries.allocator.procedure == nil {
		sink.entries.allocator = heap if runner != nil else context.allocator
	}
	job := Check_Job{plan = plan, outer = outer, collect = sink != nil, max = sink.max_errors if sink != nil else 0, dups = dups, repeats = repeats}
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
			added, err := typed.sink_add(sink, e)
			if err != nil {
				return records, failure, {kind = .No_Memory}, failed
			}
			if added {
				e = {}
			}
		}
		if sink != nil {
			sink.truncated ||= p.sink.truncated
		}
		if failure.kind == .None && p.failure.kind != .None {
			failure, failed = p.failure, records + p.failed
		}
		records += p.records
		if p.fatal.kind != .None {
			return records, failure, p.fatal, failed
		}
	}
	if job.no_memory {
		return records, failure, {kind = .No_Memory}, failed
	}
	if f, bad := fault.?; bad {
		walk := core.Typed_Refusal{kind = .Walk, inner = f, at = f.at}
		failure = walk if failure.kind == .None else failure
		// The entry only places the fault among the failures, the fault itself is returned.
		if sink != nil {
			_, _ = typed.sink_add(sink, core.Error_Entry{kind = .Walk, start = f.at, end = f.at, record = records})
		}
		return records, failure, walk, failed
	}
	return
}

// What the visit of a piece's records needs.
@(private)
Piece_Run :: struct {
	job: ^Check_Job,
	p:   Checked,
}

// A piece's task: checks its records in order, and keeps what it finds for the merge.
@(private)
check_piece :: proc(job: ^Check_Job, it: ^Reader, k: int) -> bool {
	run := Piece_Run{job = job}
	p := &run.p
	p.sink.max_errors = job.max
	p.sink.entries.allocator = job.allocator
	sink := &p.sink if job.collect else nil
	checker: typed.Checker
	defer typed.checker_destroy(&checker)
	read := typed.Read_Options{sink = sink, outer = job.outer, dups = job.dups, repeats = job.repeats, checker = &checker}
	if it.docs != nil && it.docs.check_run != nil && it.framing >= .Concatenated {
		it.docs.check_run(it, job.plan, read, piece_visit, &run)
	} else {
		for {
			rec, more := next(it)
			if !more {
				break
			}
			first := len(p.sink.entries)
			p.sink.record = p.records
			target: u8
			e := job.plan.check(rec.text, job.plan.as, &target, nil, job.plan, read, context.allocator)
			for &x in p.sink.entries[first:] {
				x.start += rec.at
				x.end += rec.at
			}
			core.move_typed_error(&e, rec.at)
			core.move_typed_error(&p.sink.fatal, rec.at)
			if !piece_note(job, p, e) {
				break
			}
		}
	}
	more := p.failure.kind == .None || job.collect && p.fatal.kind == .None
	sync.guard(&job.lock)
	if k >= len(job.pieces) {
		if resize(&job.pieces, k + 1) != nil {
			job.no_memory = true
			typed.sink_destroy(&p.sink)
			return false
		}
	}
	job.pieces[k] = p^
	return more
}

@(private)
piece_visit :: proc(data: rawptr, rec: Record, first: core.Typed_Refusal) -> bool {
	run := (^Piece_Run)(data)
	return piece_note(run.job, &run.p, first)
}

// Takes in the check of one more record, whose failure `e` and entries are from the input's first byte, and says whether
// the piece goes on.
@(private)
piece_note :: proc(job: ^Check_Job, p: ^Checked, e: core.Typed_Refusal) -> bool {
	fatal := p.sink.fatal
	p.sink.fatal = {}
	p.records += 1
	if e.kind == .None {
		return true
	}
	if p.failure.kind == .None {
		p.failure, p.failed = e, p.records - 1
	}
	if fatal.kind == .None && (e.kind == .Walk || e.kind == .No_Memory) {
		fatal = e
	}
	if fatal.kind != .None {
		p.fatal = fatal
		return false
	}
	return job.collect
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
