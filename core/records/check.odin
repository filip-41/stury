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
	// The piece's records that did not read, under `Check_Job.skip`.
	bad:     [dynamic]Bad_Record,
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
	// Whether a record whose text does not read is one more failure, past which the records go on.
	skip:    bool,
	allocator: runtime.Allocator,
	lock:   sync.Mutex,
	pieces: [dynamic]Checked,
	// Set when a piece could not keep its result.
	no_memory: bool,
}

// Checks each record of `src` read from byte `at` under `framing` by `plan`, whose paths and keyword paths start with
// `outer` when it is given, on the threads of `runner` when it has any, and gives the answer one thread gives. The
// failures go to `sink` in source order with record indexes counted from the first record, up to its `max_errors`. With
// a runner the sink's entries are allocated with the heap, so a sink with an allocator of its own is checked on this
// thread. The results are the number of records read, the first failure, the fault the records ended on, which is a
// `.Walk` or a `.No_Memory` and outranks the failures before it, and the index of the record the first failure is in.
// A result's kind is `.None` for none. With no sink the check stops at the first failure. `dups` and `repeats` are the
// read's, see `typed.Repeats`. With `bad_records`, a record whose text does not read is a failure of kind `.Walk`, which
// goes to `bad_records` with its fault in source order, and the records go on past it wherever `records.skip` does. A
// text whose cuts between pieces pair quotes is then checked on this thread, as such a record may leave them misplaced.
check_each :: proc(src: []u8, as: core.As, framing: core.Framing, plan: ^typed.Plan, outer: ^typed.Outer, sink: ^typed.Sink = nil, runner: ^core.Runner = nil, at: u64 = 0, dups := core.Duplicates.Default, repeats := typed.Repeats.Ignore, bad_records: ^[dynamic]Bad_Record = nil) -> (records: i64, failure: core.Typed_Refusal, fatal: core.Typed_Refusal, failed: i64) {
	heap := runtime.heap_allocator()
	runner := runner
	skip := bad_records != nil
	if sink != nil && sink.entries.allocator.procedure != nil && sink.entries.allocator.procedure != heap.procedure || skip && cuts_pair_quotes(src, as, framing_by(as, plan), framing) {
		runner = nil
	}
	if sink != nil && sink.entries.allocator.procedure == nil {
		sink.entries.allocator = heap if runner != nil else context.allocator
	}
	job := Check_Job{plan = plan, outer = outer, collect = sink != nil, max = sink.max_errors if sink != nil else 0, dups = dups, repeats = repeats, skip = skip}
	if sink != nil {
		job.allocator = sink.entries.allocator
	}
	job.pieces.allocator = heap
	defer {
		for &p in job.pieces {
			typed.sink_destroy(&p.sink)
			delete(p.bad)
		}
		delete(job.pieces)
	}
	fault := each_piece(src, as, framing_by(as, plan), framing, cast(proc(data: rawptr, piece: ^Reader, k: int) -> bool)check_piece, &job, runner, at)
	cut := max(u64)
	if f, bad := fault.?; bad {
		cut = f.at
	}
	for &p in job.pieces {
		typed.order_entries(&p.sink, 0)
		for &e in p.sink.entries {
			// A record the fault cut tells only the fault: its other failures are not among the records before it.
			if e.start >= cut || p.fatal.kind != .None && e.kind != .Walk && e.record == p.records - 1 {
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
		for b in p.bad {
			if b.at >= cut {
				continue
			}
			if _, err := append(bad_records, b); err != nil {
				return records, failure, {kind = .No_Memory}, failed
			}
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
	p.bad.allocator = runtime.heap_allocator()
	sink := &p.sink if job.collect else nil
	checker: typed.Checker
	defer typed.checker_destroy(&checker)
	read := typed.Read_Options{sink = sink, outer = job.outer, dups = job.dups, repeats = job.repeats, checker = &checker}
	make_docs := typed.plan_docs(job.plan)
	docs := (^Record_Docs)(make_docs()) if make_docs != nil else nil
	if docs != nil && docs.check_run != nil && it.framing >= .Concatenated {
		for {
			docs.check_run(it, job.plan, read, piece_visit, &run)
			if !job.skip || !skip_note(job, p, it) {
				break
			}
		}
	} else {
		for {
			rec, more := next(it)
			if !more {
				if job.skip && skip_note(job, p, it) {
					continue
				}
				break
			}
			first := len(p.sink.entries)
			p.sink.record = p.records
			target: u8
			mark := typed.temp_mark(&p.sink)
			e := job.plan.check(rec.text, job.plan.as, &target, nil, job.plan, read, context.allocator)
			// The piece keeps only its first failure's path, which may name a key held in the temp allocator.
			typed.temp_release(mark, e.kind != .None && p.failure.kind == .None)
			for &x in p.sink.entries[first:] {
				x.start += rec.at
				x.end += rec.at
			}
			core.move_typed_error(&e, rec.at)
			core.move_typed_error(&p.sink.fatal, rec.at)
			if job.skip && e.kind == .Walk {
				if _, failed := append(&p.bad, Bad_Record{text = rec.text, at = rec.at, end = rec.at + u64(len(rec.text)), fault = e.inner}); failed != nil {
					p.sink.fatal = {kind = .No_Memory}
				}
			}
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
			delete(p.bad)
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
	if job.skip && fatal.kind == .Walk {
		fatal = {}
	}
	p.records += 1
	if e.kind == .None {
		return true
	}
	if p.failure.kind == .None {
		p.failure, p.failed = e, p.records - 1
	}
	if fatal.kind == .None && (e.kind == .Walk && !job.skip || e.kind == .No_Memory) {
		fatal = e
	}
	if fatal.kind != .None {
		p.fatal = fatal
		return false
	}
	return job.collect
}

// Goes on past the record the piece's records ended on, as one more failure whose entry spans it, and says whether the
// piece goes on.
@(private)
skip_note :: proc(job: ^Check_Job, p: ^Checked, it: ^Reader) -> bool {
	bad := skip(it) or_return
	_, failed := append(&p.bad, bad)
	if job.collect && failed == nil {
		_, failed = typed.sink_add(&p.sink, core.Error_Entry{kind = .Walk, start = bad.at, end = bad.end, record = p.records})
	}
	if failed != nil {
		p.sink.fatal = {kind = .No_Memory}
	}
	more := piece_note(job, p, {kind = .Walk, inner = bad.fault, at = bad.fault.at})
	// A format's `check_run` counts the records of the sink, which go on past the one skipped.
	p.sink.record = p.records
	return more
}

// Whether `each` cuts the records of `src` under `framing` by a scan that pairs quotes.
@(private)
cuts_pair_quotes :: proc(src: []u8, as: core.As, services: ^Framing_Services, framing: core.Framing) -> bool {
	it := open_with(src, as, services, nil, framing, 0, runtime.heap_allocator())
	defer close(&it)
	if it.fault != nil || it.services.exact == nil {
		return false
	}
	rule, exact := it.services.exact(&it)
	return exact && rule.quote != 0
}

// The entries of the root array of `src` as `check_each` reads them, when the array's bulk is cut exactly so that its
// entries can be checked in pieces: the handle to check them with and the byte they start from. False for any other text.
// A handle with no services is framed as `plan`'s record docs say.
entries_of :: proc(src: []u8, as: core.As, plan: ^typed.Plan = nil) -> (whole: core.As, at: u64, ok: bool) {
	services := framing_by(as, plan)
	if services == nil || services.whole == nil {
		return
	}
	framing: core.Framing
	whole, framing, at = services.whole(src, as)
	return whole, at, framing == .Entries && entries_cut(src, whole, framing, at, services)
}
