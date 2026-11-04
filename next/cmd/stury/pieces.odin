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
import "core:slice"
import "core:sync"
import core "../../core"
import host "../../host"
import "../../core/write"
import records "../../core/records"
import json "../../json"
import "jq"

// The pool's width, the calling thread counted, 0 for one thread per core.
THREADS :: #config(STURY_THREADS, 0)

// The least input read on the pool's threads: on a shorter one, starting them costs more than they save.
POOLED_BYTES :: #config(STURY_POOLED_BYTES, 1 << 20)

// The run's pool, started at its first use. A pool that could not start runs every piece on the caller.
run_pool :: proc(run: ^Run) -> ^core.Runner {
	if run.pool == nil {
		run.pool = new(host.Pool, runtime.heap_allocator())
		host.pool_init(run.pool, THREADS)
	}
	return &run.pool.runner
}

// What a piece's records came to, merged into the run's in source order. `cursor` is the bytes its outputs hold.
Piece_Sum :: struct {
	cursor, ret, last_result, records, rows: int,
	explain:                                 Explain,
}

// The piece's records answered start at `lo` and end before `hi`, and its last record ends at `end`.
Piece_Slot :: struct {
	lo, hi, end:   u64,
	out:           []u8,
	room, k:       int, // the bytes `out`'s buffer holds, and the piece's number
	sum:           Piece_Sum,
	done, stopped: bool,
	crossed:       bool, // it stopped on a text that runs past its end
}

Pieces :: struct {
	run:      ^Run,
	template: Run, // what each piece's run starts as: the run with no counts and no messages of its own
	plain:    core.As, // how a record's text reads on its own
	framing:  core.Framing, // how a piece's records are read, whatever cut the pieces
	start:    u64, // records before it are answered already
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
	walk: Serial_Walk
	defer delete(walk.on)
	defer delete(walk.done)
	p := !(o.null_input || o.slurp || o.raw_input || o.stream || o.stream_errors || o.unbuffered || o.grow_header) && o.max_depth <= core.MAX_DEPTH && !serial_node(&run.prog, &walk)
	run.parallel = p
	return p
}

@(rodata)
SERIAL_CALLS := []string{"input", "inputs", "debug", "stderr", "halt", "halt_error", "input_filename", "input_line_number"}

Serial_Walk :: struct {
	on, done: [dynamic]^jq.Func, // the functions whose bodies are being walked, and those walked
}

// Whether the filter `p^` calls one of SERIAL_CALLS, `recurse` with a filter, or a function that calls itself.
@(private = "file")
serial_node :: proc(p: ^^jq.Node, w: ^Serial_Walk) -> bool {
	n := p^
	if n == nil {
		return false
	}
	if n.kind == .Call && (slice.contains(SERIAL_CALLS, n.name) || n.name == "recurse" && len(n.args) > 0) {
		return true
	}
	// A call of a filter parameter runs its argument, which the walk sees where it is passed.
	if f := n.callee; n.kind == .Call && f != nil && !n.is_param && !slice.contains(w.done[:], f) {
		recursive := slice.contains(w.on[:], f)
		append(&w.on, f)
		if recursive || serial_node(&f.body, w) {
			return true
		}
		pop(&w.on)
		append(&w.done, f)
	}
	return jq.any_child(n, w, serial_node)
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
@(private = "file")
pieces_init :: proc(ps: ^Pieces, run: ^Run, plain: core.As, framing: core.Framing) {
	ps.run, ps.template, ps.plain, ps.framing = run, run^, plain, framing
	ps.template.route.explain, ps.template.ip.messages = {on = run.route.on}, {}
	ps.slots.allocator = runtime.heap_allocator()
}

@(private = "file")
pieces_destroy :: proc(ps: ^Pieces) {
	for s in ps.slots {
		give_spare(&ps.run.spares, s.out, s.room, s.k)
	}
	delete(ps.slots)
}

// Answers the open file's records past those read on the pool's threads, when they are long and the filter runs per
// record, and leaves the serial route the records from where the pieces stopped. False, with nothing read, when they
// are not read so.
records_pieces :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	cells := reads_cells(&run.opts)
	// A delimited text's reader frames records ahead of the one it gave last.
	from := u64(ins.text_end) if cells else ins.texts.pos
	if ins.framing == .Seq || !ins.last && ins.framing != .Lines || u64(len(ins.data)) < from + POOLED_BYTES || from < ins.parallel_from || ins.failures > 0 || run.halted || cells && !ins.header_judged || run.output.table != nil && run.output.table.shape == .Unset || !parallel(run) {
		return false
	}
	flush_some(&run.output, force = true)
	// Strict JSON texts are cut at line ends, with no pass over the text to find the cuts, and read as texts. A cut
	// inside a text ends the piece before it on the text it cuts short, and the pieces past that cut are not written.
	// The text past it is then cut where the texts end.
	at, crossed := records_run(ins, .Lines if ins.framing == .Concatenated && json.Spec(ins.as.spec) == .Json else ins.framing, from, cells)
	if crossed {
		at, _ = records_run(ins, ins.framing, at, cells)
	}
	ins.has_text ||= at > from
	// The serial route goes on at the first record no piece answered.
	at = max(at, from)
	if cells {
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
	defer pieces_destroy(&ps)
	// A delimited text's pieces read its header at its start.
	ps.start, ps.at = from, 0 if cells else from
	records.each(ins.data, ins.as, framing, piece_task, &ps, run_pool(ins.run), ps.at)
	return ps.at, ps.crossed
}

// Answers the whole JSON text `ins.data` through the entries of its spine array on the pool's threads, when the text
// is long and the filter is `.NAME...[]` followed by steps or a pipe, which each entry answers alone. False, with
// nothing printed, when it does not.
entries_pieces :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	data := ins.data
	if len(data) < POOLED_BYTES || json.Spec(ins.as.spec) != .Json || run.route.select.op != .None || !parallel(run) {
		return false
	}
	entries, at, found := json.spine(data, ins.as)
	levels := int(entries.opts[0])
	names := make([dynamic]string, context.temp_allocator)
	prog, spined := strip_spine(run.prog, &names)
	if !found || !spined || len(names) != levels {
		return false
	}
	ps: Pieces
	pieces_init(&ps, run, ins.as, .Entries)
	defer pieces_destroy(&ps)
	ps.entries, ps.template.prog = true, prog
	if run.route.scanning {
		path := &ps.template.route.path
		if path.limit != nil || len(path.steps) <= levels {
			return false
		}
		for name, i in names {
			if step, named := path.steps[i].(core.Name); !named || string(step) != name {
				return false
			}
		}
		if _, every := path.steps[levels].(core.All); !every {
			return false
		}
		path.steps = path.steps[levels + 1:]
		path.optional = transmute(bit_set[0 ..< core.MAX_STEPS;u64])(transmute(u64)path.optional >> uint(levels + 1))
	}
	flush_some(&run.output, force = true)
	if records.each(data, entries, .Entries, piece_task, &ps, run_pool(run), at) != nil || ps.stopped || !spine_named(data, at, array_close(data, at, entries_end(ps.slots[:])), ps.plain, names[:]) {
		return false
	}
	answered, interpreted := 0, false
	for &s in ps.slots {
		write_piece(&ps, &s)
		answered += s.sum.records
		interpreted ||= s.sum.explain.interpreted > 0
		if s.sum.explain.fallback.text > 0 {
			explain_fallback(&run.route, s.sum.explain.fallback.why)
		}
	}
	// The pieces answered one text.
	run.route.interpreted += int(interpreted)
	run.route.scanned += int(!interpreted)
	if answered == 0 {
		finish_input(&run.output)
	}
	return true
}

// `n` with the iteration of the spine array at its start, `.NAME...[]`, made `.`, and the names appended to `names`:
// the filter each entry answers what the text answers through the array. False for any other filter, and for a step
// whose argument is not a literal, which reads the text and not the entry.
@(private = "file")
strip_spine :: proc(n: ^jq.Node, names: ^[dynamic]string) -> (stripped: ^jq.Node, ok: bool) {
	if n == nil {
		return nil, false
	}
	#partial switch n.kind {
	case .Iterate:
		lead := n.a
		for lead.kind == .Field {
			lead = lead.a
		}
		if lead.kind == .Identity {
			for f := n.a; f.kind == .Field; f = f.a {
				inject_at(names, 0, f.name)
			}
			return new_clone(jq.Node{kind = .Identity}, runtime.heap_allocator()), true
		}
	case .Index, .Slice:
		for arg in ([]^jq.Node{n.b, n.c}) {
			if arg != nil && arg.kind != .Literal {
				return nil, false
			}
		}
	case .Pipe, .Field:
	case:
		return nil, false
	}
	a := strip_spine(n.a, names) or_return
	stripped = new_clone(n^, runtime.heap_allocator())
	stripped.a = a
	return stripped, true
}

// The byte past the last entry of the pieces `slots`.
entries_end :: proc(slots: []$S) -> (end: u64) {
	for s in slots {
		end = max(end, s.end)
	}
	return
}

// The byte of the close of the spine array at `at` of `data`, whose last entry ends before `end`.
array_close :: proc(data: []byte, at, end: u64) -> u64 {
	close := max(at + 1, end)
	for close < u64(len(data)) && data[close] != ']' {
		close += 1
	}
	return close
}

// Whether `names` lead from the root of `data` to its spine array at `at`, which closes at `close`, each the one key of
// that name in its object, as jq's last-key-wins reads them.
spine_named :: proc(data: []byte, at, close: u64, plain: core.As, names: []string) -> bool {
	if len(names) == 0 {
		return true
	}
	doc, node, found := spine_walk(data, at, close, plain, names)
	return found && doc.nodes[node].kind == .Array && u64(doc.nodes[node].lo) == at
}

// The document of `data` with the entries of its spine array at `at`, which closes at `close`, cut out, and the node
// `names` lead to from its root, each the one key of that name in its object, as jq's last-key-wins reads them. False
// when the text does not build or a name is missing or repeated.
spine_walk :: proc(data: []byte, at, close: u64, plain: core.As, names: []string) -> (doc: core.Document, node: core.Node_Index, found: bool) {
	shell := make([]byte, int(at) + 1 + len(data) - int(close), context.temp_allocator)
	copy(shell, data[:at + 1])
	copy(shell[at + 1:], data[close:])
	fault: Maybe(core.Fault)
	if doc, fault = jq.build_text(shell, plain, context.temp_allocator); fault != nil {
		return
	}
	for name in names {
		next := core.NO_NODE
		it := core.pairs(&doc, node)
		for k, v in core.pair_next(&it) {
			if jq.node_string(&doc, k) == name {
				if next != core.NO_NODE {
					return
				}
				next = v
			}
		}
		if next == core.NO_NODE {
			return
		}
		node = next
	}
	return doc, node, true
}

// The arenas a thread's pieces share, mapped at its first piece and emptied after each record, so a piece does not map
// and unmap its own. They are not freed, the process ends with its threads.
@(private = "file", thread_local)
piece_values, piece_temp: virtual.Arena

// The calling thread's piece arenas as allocators, false when they could not be mapped.
piece_arenas :: proc() -> (values, temp: runtime.Allocator, ok: bool) {
	if piece_temp.curr_block == nil && (virtual.arena_init_growing(&piece_values) != nil || virtual.arena_init_growing(&piece_temp) != nil) {
		return
	}
	return {scratch_allocator_proc, &piece_values}, {scratch_allocator_proc, &piece_temp}, true
}

// A piece's records answered as the serial route answers them, into the piece's own output, up to the first it cannot
// answer alone. After a refused text it stops at the record before, so the serial route reads that text as it follows
// a record and not a cut.
@(private = "file")
piece_task :: proc(ps: ^Pieces, it: ^records.Reader, k: int) -> bool {
	r := ps.template
	o := &r.output
	table := o.table
	init_output(o, &r)
	o.held, o.piece = true, true
	o.buf.hint = 1 << 16
	take_spare(&ps.run.spares, &o.buf, k)
	if table != nil {
		o.table.shape, o.table.header = table.shape, table.header
	}
	values, temp, mapped := piece_arenas()
	failed := !mapped
	context.allocator, context.temp_allocator = values, temp
	it.framing = ps.framing
	lo, end := it.pos, it.pos
	stop := u64(len(it.src))
	scanned := r.route.scanning && scans(r.route.path) && !reads_cells(&r.opts)
	n, before_at, stopped, crossed := 0, lo, failed, false
	before := piece_sum(&r, n)
	for !stopped {
		rec: records.Record
		more: bool
		part: core.Document
		read: core.Path_Error
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
		free_all(context.allocator)
		free_all(context.temp_allocator)
	}
	if stopped {
		n = restore_sum(&r, before)
	}
	slot := Piece_Slot{lo = lo, hi = stop, end = end, sum = piece_sum(&r, n), stopped = stopped, crossed = crossed}
	if o.table != nil {
		records.writer_destroy(&o.table.wr)
		free(o.table, runtime.heap_allocator())
	}
	slot.room, slot.k = o.buf.size, k
	out, err := write.finish(&o.buf)
	if err.kind != .None {
		slot.hi, slot.stopped = lo, true
	}
	slot.out = out
	publish(ps, k, slot)
	return !slot.stopped
}

// Answers one record of a piece, as the serial route does, or returns false with what it printed left to be undone.
@(private = "file")
piece_record :: proc(r: ^Run, it: ^records.Reader, rec: records.Record, part: ^core.Document, read: core.Path_Error, scanned: bool, plain: core.As) -> bool {
	o := &r.output
	cells := reads_cells(&r.opts)
	if cells && r.route.columns != nil {
		answer_columns(r, it, rec)
	} else if cells || !r.route.scanning || !(answer(r, part, part.answers, read, rec.text, plain) if scanned else answer_path(r, rec.text, plain)) {
		built, err := records.build(it, rec, context.allocator)
		doc, fault := jq.judge_build(built, err, rec.at)
		if fault != nil {
			return false
		}
		r.route.interpreted += 1
		run_once(r, jq.document_value(doc))
	}
	return !o.refused
}

// What the piece's `records` so far came to.
@(private = "file")
piece_sum :: proc(r: ^Run, records: int) -> Piece_Sum {
	o := &r.output
	return {o.buf.cursor, o.ret, o.last_result, records, o.table.count if o.table != nil else 0, r.route.explain}
}

// Undoes the records past those `s` counts, and returns their count.
@(private = "file")
restore_sum :: proc(r: ^Run, s: Piece_Sum) -> int {
	o := &r.output
	o.buf.cursor, o.ret, o.last_result, r.route.explain = s.cursor, s.ret, s.last_result, s.explain
	o.refused = false
	if o.table != nil {
		o.table.count = s.rows
	}
	return s.records
}

// Keeps a piece's slot and writes every slot that follows the written ones in the text. Entries are written once
// every piece has run.
@(private = "file")
publish :: proc(ps: ^Pieces, k: int, slot: Piece_Slot) {
	sync.guard(&ps.lock)
	if k >= len(ps.slots) {
		resize(&ps.slots, k + 1)
	}
	ps.slots[k] = slot
	ps.slots[k].done = true
	ps.stopped ||= slot.stopped
	if ps.entries {
		return
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
}

// Writes a piece's outputs and merges what its records came to into the run's.
@(private = "file")
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
		o.table.count += s.sum.rows
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
