package main

// A long input answered on the threads of a pool. The records of a file, or the entries of the array a whole JSON text
// holds at its root or in a root object, are cut into pieces that `records.each` hands out. Each piece answers its
// records as the serial route does, into its own buffer, and the buffers are written in source order, so the output,
// the exit status and `--explain`'s counts are a serial run's. A piece stops at the first record it cannot answer
// alone: one whose text is refused, one the filter fails on, or one whose row the table refuses. Records then go on
// serially from there, and the serial route tells the fault. Entries are all or nothing: the text goes to the serial
// route whole when a piece stops, or when the keys that lead to the array are not the filter's.

import "base:runtime"
import "core:mem/virtual"
import "core:sync"
import core "../../core"
import host "../../host"
import "../../core/write"
import records "../../core/records"
import "../../jq"

// The least input read on the pool's threads: on a shorter one, starting them costs more than they save.
POOLED_BYTES :: #config(STURY_POOLED_BYTES, 1 << 20)

// The run's pool, started at its first use. A pool that could not start runs every piece on the caller.
run_pool :: proc(run: ^Run) -> ^core.Runner {
	if run.pool == nil {
		jq.share(&run.ip, run.prog)
		run.pool = new(host.Pool, runtime.heap_allocator())
		host.pool_init(run.pool, run.opts.threads)
	}
	return &run.pool.runner
}

// The run's pool for an input of `data`, or nil for one too short to share.
pool_for :: proc(run: ^Run, data: []byte) -> ^core.Runner {
	return run_pool(run) if len(data) >= POOLED_BYTES else nil
}

// What a piece's records came to, merged into the run's in source order. `cursor` is the bytes its outputs hold.
Piece_Sum :: struct {
	cursor, ret, last_result, records, rows: int,
	explain:                                 Explain,
}

// The piece's records answered start at `lo` and end before `hi`, and its last record or entry ends at `end`.
Piece_Slot :: struct {
	lo, hi, end:   u64,
	out:           []u8,
	room, k:       int, // the bytes `out`'s buffer holds, and the piece's number
	sum:           Piece_Sum,
	done, stopped: bool,
	crossed:       bool, // it stopped on a text that runs past its end
	// A spine piece's: the text of `out` between the innermost brackets, its entries, and a collect's outputs, in the
	// thread's piece arena.
	inner:         []u8,
	entries:       int,
	items:         [dynamic]core.Value,
}

Pieces :: struct {
	run:      ^Run,
	template: Run, // what each piece's run starts as: the run with no counts and no messages of its own
	plain:    core.As, // how a record's text reads on its own
	framing:  core.Framing, // how a piece's records are read, whatever cut the pieces
	start:    u64, // records before it are answered already
	ins:      ^Inputs, // the records' file, whose pages read past are let go as the pieces are written
	entries:  bool,
	lock:     sync.Mutex,
	slots:    [dynamic]Piece_Slot,
	next:     int, // the first slot not written
	at:       u64, // the records written end here
	// A piece stopped, and that piece is written, and it stopped on a text that runs past its end.
	stopped, ended, crossed: bool,
}

// Whether the filter can run on pieces of the input, decided at its first use. A filter that reads inputs, writes
// messages, halts, recurses or runs a deep input needs the serial run's state or the stack it runs on.
parallel :: proc(run: ^Run) -> bool {
	if p, known := run.parallel.?; known {
		return p
	}
	o := &run.opts
	// A piece builds its records alone, without the comment lines above them that the interpreter's filter may read.
	comments := reads_cells(o) && o.cells_in.comment != 0 && run.route.columns == nil
	p := !(o.null_input || o.slurp || o.raw_input || o.stream || o.stream_errors || o.unbuffered || o.grow_header || o.attributes || comments || writes_texts(o)) && o.max_depth <= core.MAX_DEPTH && !run.shape.serial
	run.parallel = p
	return p
}

// The output buffers of the pieces written, kept by piece number for the next file's pieces, which are cut alike and so
// need buffers of the same sizes. A buffer is allocated and doubled once, however many files follow, so the allocator
// does not hold a run's freed doublings.
Spare_Outs :: struct {
	lock: sync.Mutex,
	bufs: [dynamic][]u8,
}

// Piece `k`'s spare buffer given to `out`, if there is one.
take_spare :: proc(spares: ^Spare_Outs, out: ^write.Out, k: int) {
	sync.guard(&spares.lock)
	if k < len(spares.bufs) && spares.bufs[k] != nil {
		out.buf, out.size = raw_data(spares.bufs[k]), len(spares.bufs[k])
		spares.bufs[k] = nil
	}
}

// Piece `k`'s `out`, which holds `room` bytes, kept as its spare.
give_spare :: proc(spares: ^Spare_Outs, out: []u8, room: int, k: int) {
	if out == nil {
		return
	}
	sync.guard(&spares.lock)
	spares.bufs.allocator = runtime.heap_allocator()
	if k >= len(spares.bufs) {
		resize(&spares.bufs, k + 1)
	}
	if spares.bufs[k] != nil {
		delete(spares.bufs[k], runtime.heap_allocator())
	}
	spares.bufs[k] = raw_data(out)[:room]
}

// The run each piece starts as, and the slots its pieces write into.
pieces_init :: proc(ps: ^Pieces, run: ^Run, plain: core.As, framing: core.Framing) {
	ps.run, ps.template, ps.plain, ps.framing = run, run^, plain, framing
	ps.template.route.explain = {on = run.route.on}
	ps.slots.allocator = runtime.heap_allocator()
}

// The pieces' output buffers kept as spares, and `slots` freed.
free_slots :: proc(run: ^Run, slots: [dynamic]Piece_Slot) {
	for s in slots {
		give_spare(&run.spares, s.out, s.room, s.k)
	}
	delete(slots)
}

// Answers the open file's records past those read on the pool's threads, when they are long and the filter runs per
// record, and leaves the serial route the records from where the pieces stopped. False, with nothing read, when they
// are not read so.
records_pieces :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	cells := reads_cells(&run.opts)
	// A delimited text's reader frames records ahead of the one it gave last.
	from := u64(ins.text_end) if cells else ins.texts.pos
	if ins.framing == .Seq || !ins.last && ins.framing != .Lines || u64(len(ins.data)) < from + POOLED_BYTES || from < ins.parallel_from || ins.failures > 0 || run.halted || cells && !ins.header_judged || run.output.table != nil && run.output.table.wr.table.shape == .Unset || !parallel(run) {
		return false
	}
	flush_some(&run.output, force = true)
	// Strict JSON texts are cut at line ends, with no pass over the text to find the cuts, and read as texts. A cut
	// inside a text ends the piece before it on the text it cuts short, and the pieces past that cut are not written.
	// The text past it is then cut where the texts end.
	at, crossed := records_run(ins, .Lines if ins.framing == .Concatenated && ins.spec == .Json else ins.framing, from, cells)
	if crossed {
		at, _ = records_run(ins, ins.framing, at, cells)
	}
	ins.has_text ||= at > from
	// The serial route goes on at the first record no piece answered.
	at = max(at, from)
	if cells && ins.last && at == u64(len(ins.data)) {
		// The pieces answered every record.
		close_file(ins)
	} else if cells {
		// Opened anywhere but at its start, a delimited text's reader takes its first record for the header.
		ins.skip_below, ins.rows_end = at, at
	} else {
		records.close(&ins.texts)
		ins.texts = records.open(ins.data, ins.as, ins.framing, at, runtime.heap_allocator())
	}
	// Past the record a piece stopped at, which the serial route reads first.
	ins.parallel_from = at + max(POOLED_BYTES, 1)
	return true
}

// Answers the open file's records from `from` in pieces cut under `framing`, and returns where the records they wrote
// end, and whether the last piece written stopped on a text its cut ran through.
@(private = "file")
records_run :: proc(ins: ^Inputs, framing: core.Framing, from: u64, cells: bool) -> (at: u64, crossed: bool) {
	ps: Pieces
	pieces_init(&ps, ins.run, ins.as, ins.framing)
	defer free_slots(ps.run, ps.slots)
	// A delimited text's pieces read its header at its start.
	ps.start, ps.at, ps.ins = from, 0 if cells else from, ins
	records.each(ins.data, ins.as, framing, piece_task, &ps, run_pool(ins.run), ps.at)
	return ps.at, ps.crossed
}

// The arenas a thread's pieces share, mapped at its first piece and emptied after each record, so a piece does not map
// and unmap its own. They are not freed, the process ends with its threads.
@(private = "file", thread_local)
piece_values, piece_temp: virtual.Arena

// The interpreter a thread's pieces run on, each a copy of the run's made over the last (`jq.clone`), so a filter's
// patterns compile once per thread and not once per piece. Not freed, as the arenas above.
@(private = "file", thread_local)
piece_ip: jq.Interp

// The calling thread's piece arenas as allocators, false when they could not be mapped.
piece_arenas :: proc() -> (values, temp: runtime.Allocator, ok: bool) {
	if piece_temp.curr_block == nil && (virtual.arena_init_growing(&piece_values) != nil || virtual.arena_init_growing(&piece_temp) != nil) {
		return
	}
	return jq.run_allocator(&piece_values), jq.run_allocator(&piece_temp), true
}

// A piece's records answered as the serial route answers them, into the piece's own output, up to the first it cannot
// answer alone. After a refused text it stops at the record before, so the serial route reads that text as it follows
// a record and not a cut.
piece_task :: proc(ps: ^Pieces, it: ^records.Reader, k: int) -> bool {
	r := ps.template
	jq.clone(&ps.run.ip, &piece_ip)
	r.ip = piece_ip
	o := &r.output
	table := o.table
	init_output(o, &r)
	o.held, o.piece = true, true
	o.buf.hint = 1 << 16
	take_spare(&ps.run.spares, &o.buf, k)
	if table != nil {
		o.table.wr.table.shape, o.table.wr.table.header = table.wr.table.shape, table.wr.table.header
	}
	values, temp, mapped := piece_arenas()
	failed := !mapped
	context.allocator, context.temp_allocator = values, temp
	it.framing = ps.framing
	lo, end := it.pos, it.pos
	// A piece's records end at its text's end, or at `to` for a format that reads past it.
	stop := min(it.to, u64(len(it.src))) if it.to != 0 else u64(len(it.src))
	scanned := r.route.scanning && scans(r.route.path) && !reads_cells(&r.opts)
	n, before_at, stopped, crossed := 0, lo, failed, false
	before := piece_sum(&r, n)
	for !stopped {
		rec: records.Record
		more: bool
		part: core.Document
		read: core.Error
		if scanned {
			rec, part, read, more = records.scan(it, r.route.path)
		} else {
			rec, more = records.next(it)
		}
		if !more {
			if f, bad := it.fault.?; bad {
				stop, stopped = before_at, true
				crossed = f.kind == .Truncated && f.at == u64(len(it.src))
			}
			break
		}
		if rec.at < ps.start {
			continue
		}
		before, before_at = piece_sum(&r, n), rec.at
		if !piece_record(&r, it, rec, &part, read, scanned, ps.plain) {
			stop, stopped = rec.at, true
		}
		n += 1
		end = rec.at + u64(len(rec.text))
		// The column route's records most often allocate nothing.
		if piece_values.total_used > 0 {
			free_all(context.allocator)
		}
		if piece_temp.total_used > 0 {
			free_all(context.temp_allocator)
		}
	}
	if stopped {
		// The records past those `before` counts undone.
		o.buf.cursor, o.ret, o.last_result, r.route.explain, n = before.cursor, before.ret, before.last_result, before.explain, before.records
		o.refused = false
		if o.table != nil {
			o.table.wr.table.rows = before.rows
		}
	}
	slot := Piece_Slot{lo = lo, hi = stop, end = end, sum = piece_sum(&r, n), stopped = stopped, crossed = crossed}
	if o.table != nil {
		// The header is the run's table's.
		o.table.wr.table.header = {}
		records.writer_destroy(&o.table.wr)
		free(o.table, runtime.heap_allocator())
	}
	slot.room, slot.k = o.buf.size, k
	out, err := write.finish(&o.buf)
	if err.kind != .None {
		slot.hi, slot.stopped = lo, true
	}
	slot.out = out
	piece_ip = r.ip
	publish(ps, k, slot)
	return !slot.stopped
}

// Answers one record of a piece, as the serial route does, or returns false with what it printed left to be undone.
@(private = "file")
piece_record :: proc(r: ^Run, it: ^records.Reader, rec: records.Record, part: ^core.Document, read: core.Error, scanned: bool, plain: core.As) -> bool {
	o := &r.output
	cells := reads_cells(&r.opts)
	if cells && r.route.columns != nil {
		answer_columns(r, it, rec)
	} else if cells || !r.route.scanning || !answer_record(r, rec, part, read, scanned, plain) {
		doc, fault := core.refuse_key_clash(records.build(it, rec, context.allocator))
		if fault != nil {
			return false
		}
		r.route.interpreted += 1
		run_once(r, core.document_value(doc))
	}
	return !o.refused
}

// What the piece's `records` so far came to.
@(private = "file")
piece_sum :: proc(r: ^Run, records: int) -> Piece_Sum {
	o := &r.output
	return {o.buf.cursor, o.ret, o.last_result, records, o.table.wr.table.rows if o.table != nil else 0, r.route.explain}
}

// Keeps a piece's slot and writes every slot that follows the written ones in the text. Entries are written once
// every piece has run.
@(private = "file")
publish :: proc(ps: ^Pieces, k: int, slot: Piece_Slot) {
	lo, hi := publish_locked(ps, k, slot)
	// Past the lock, which the other pieces wait on.
	if lo < hi {
		map_afresh(ps.ins.mapping.file, ps.ins.data, ps.ins.mapping.at, int(lo), int(hi))
	}
}

// `publish` under the pieces' lock. It returns the bytes whose mapped pages are then mapped afresh: those before the
// records written, or the piece's own records when they lie far past them, as a piece still running holds those back.
@(private = "file")
publish_locked :: proc(ps: ^Pieces, k: int, slot: Piece_Slot) -> (u64, u64) {
	sync.guard(&ps.lock)
	if k >= len(ps.slots) {
		resize(&ps.slots, k + 1)
	}
	ps.slots[k] = slot
	ps.slots[k].done = true
	ps.stopped ||= slot.stopped
	if ps.entries {
		return 0, 0
	}
	for i := ps.next; i < len(ps.slots) && !ps.ended; i += 1 {
		s := &ps.slots[i]
		if !s.done {
			continue
		}
		if s.lo != ps.at {
			break
		}
		write_piece(ps, s)
		ps.next = i + 1
		ps.ended, ps.crossed = s.stopped, s.crossed
	}
	if ps.ins == nil {
		return 0, 0
	}
	return pages_read_past(ps.ins, ps.at, slot.lo, slot.hi)
}

// Writes a piece's outputs and merges what its records came to into the run's.
write_piece :: proc(ps: ^Pieces, s: ^Piece_Slot) {
	run := ps.run
	o := &run.output
	if !s.done {
		return
	}
	if s.sum.records > 0 {
		o.ret = s.sum.ret
		if s.sum.last_result >= 0 {
			o.last_result = s.sum.last_result
		}
	}
	if o.table != nil {
		o.table.wr.table.rows += s.sum.rows
	}
	r := &run.route
	if p := s.sum.explain; !ps.entries {
		if p.fallback.text > 0 && r.fallback.text == 0 {
			r.fallback = {r.scanned + r.interpreted + p.fallback.text, p.fallback.why}
		}
		r.scanned += p.scanned
		r.interpreted += p.interpreted
	}
	r.pieces += 1
	if len(s.out) > 0 {
		host.writing(run.pool, true)
		write_out(s.out)
		host.writing(run.pool, false)
		o.written += len(s.out)
	}
	give_spare(&run.spares, s.out, s.room, s.k)
	s.out = nil
	ps.at = s.hi
}
