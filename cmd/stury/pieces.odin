package main

// A long input answered on the threads of a pool. The records of a file, or the entries of the array a whole JSON text
// holds at its root or in a root object, are cut into pieces that `records.each` hands out. Each piece answers its
// records as the serial route does, into its own buffer, and the buffers are written in source order, so the output,
// the exit status and `--explain`'s counts are a serial run's. A piece stops at the first record it cannot answer
// alone: one whose text is refused, one the filter fails on, or one whose row the table refuses. Records then go on
// serially from there, and the serial route tells the fault. Entries are all or nothing: the text goes to the serial
// route whole when a piece stops, or when the keys that lead to the array are not the filter's.
//
// A long JSON text whose bulk is its spine array (`json.spine`) is also printed whole, that array's length counted, or a
// collect over its entries answered, with no document of the whole text. Each piece of the array's entries is built
// alone as an array inside as many arrays as the spine is deep, so its entries print at the depth they have in the
// text, and its text between the innermost brackets is kept. The text with the entries cut out, the frame, is built and
// printed with a marker in the array, and the pieces' texts are written in its place in source order, joined by
// commas. Any piece that does not build, or a frame that does not print its array, leaves the text to the serial route,
// with nothing printed.

import "base:runtime"
import "core:bytes"
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
		// Indexed before any thread starts, so the threads' reads of these values write nothing.
		for v in run.program.values {
			jq.index_shared(v)
		}
		for v in run.program.positional {
			jq.index_shared(v)
		}
		for v in run.ip.data {
			jq.index_shared(v)
		}
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
	items:         [dynamic]jq.Value,
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
	walk: Serial_Walk
	defer delete(walk.on)
	defer delete(walk.done)
	// A piece builds its records alone, without the comment lines above them that the interpreter's filter may read.
	comments := reads_cells(o) && o.cells_in.comment != 0 && run.route.columns == nil
	p := !(o.null_input || o.slurp || o.raw_input || o.stream || o.stream_errors || o.unbuffered || o.grow_header || comments) && o.max_depth <= core.MAX_DEPTH && !serial_node(&run.prog, &walk)
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
	ps.template.route.explain = {on = run.route.on}
	jq.detach_memory(&ps.template.ip)
	ps.slots.allocator = runtime.heap_allocator()
}

// The pieces' output buffers kept as spares, and `slots` freed.
@(private = "file")
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
	if ins.framing == .Seq || !ins.last && ins.framing != .Lines || u64(len(ins.data)) < from + POOLED_BYTES || from < ins.parallel_from || ins.failures > 0 || run.halted || cells && !ins.header_judged || run.output.table != nil && run.output.table.shape == .Unset || !parallel(run) {
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

// Answers the whole JSON text `ins.data` through the entries of its spine array on the pool's threads, when the text
// is long and the filter is `.NAME...[]` followed by steps or a pipe, which each entry answers alone. False, with
// nothing printed, when it does not.
entries_pieces :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	data := ins.data
	at, levels, found := spine_of(ins)
	if !found || run.route.select.op != .None {
		return false
	}
	names := make([dynamic]string, context.temp_allocator)
	prog, spined := strip_spine(run.prog, &names)
	if !spined || len(names) != levels {
		return false
	}
	ps: Pieces
	pieces_init(&ps, run, ins.as, .Entries)
	defer free_slots(ps.run, ps.slots)
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
	if records.each(data, ins.as, .Entries, piece_task, &ps, run_pool(run), at) != nil || ps.stopped || !spine_named(data, at, ps.slots[:], ps.plain, names[:]) {
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

// The spine array of the open file's one text, at `at` inside `levels` objects, when the text is a long strict JSON
// text whose entries are cut exactly and the filter can run on pieces.
@(private = "file")
spine_of :: proc(ins: ^Inputs) -> (at: u64, levels: int, ok: bool) {
	if len(ins.data) < POOLED_BYTES || ins.spec != .Json || !parallel(ins.run) {
		return
	}
	at, levels, ok = json.spine(ins.data, ins.as)
	// An array most of whose bytes are one entry has no cuts for pieces to read between.
	if ok && !records.entries_cut(ins.data, ins.as, .Entries, at) {
		return {}, 0, false
	}
	return
}

// `data` with the entries of its spine array at `at`, which the pieces `slots` hold, replaced by `middle`.
@(private = "file")
shell_of :: proc(data: []byte, at: u64, slots: []Piece_Slot, middle: string) -> []byte {
	close := at + 1
	for s in slots {
		close = max(close, s.end)
	}
	for close < u64(len(data)) && data[close] != ']' {
		close += 1
	}
	return bytes.concatenate({data[:at + 1], transmute([]u8)middle, data[close:]}, context.temp_allocator)
}

// Whether `names` lead from the root of `data` to its spine array at `at`, whose entries the pieces `slots` hold, each
// the one key of that name in its object, as jq's last-key-wins reads them.
@(private = "file")
spine_named :: proc(data: []byte, at: u64, slots: []Piece_Slot, plain: core.As, names: []string) -> bool {
	if len(names) == 0 {
		return true
	}
	doc, node, found := spine_walk(data, at, slots, plain, names)
	return found && doc.nodes[node].kind == .Array && u64(doc.nodes[node].lo) == at
}

// The document of `data` with the entries of its spine array at `at`, which the pieces `slots` hold, cut out, and the
// node `names` lead to from its root, each the one key of that name in its object, as jq's last-key-wins reads them.
// False when the text does not build or a name is missing or repeated.
@(private = "file")
spine_walk :: proc(data: []byte, at: u64, slots: []Piece_Slot, plain: core.As, names: []string) -> (doc: core.Document, node: core.Node_Index, found: bool) {
	fault: Maybe(core.Fault)
	if doc, fault = jq.build_text(shell_of(data, at, slots, ""), plain, context.temp_allocator); fault != nil {
		return
	}
	for name in names {
		first, _ := core.member(&doc, node, name, .First)
		node = core.member(&doc, node, name) or_return
		if node != first {
			return
		}
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
	return jq.arena_allocator(&piece_values), jq.arena_allocator(&piece_temp), true
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
			o.table.count = before.rows
		}
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
	jq.free_detached(&r.ip)
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
	} else if cells || !r.route.scanning || !answer_record(r, rec, part, read, scanned, plain) {
		built, err := records.build(it, rec, context.allocator)
		doc, fault := jq.judge_build(built, err)
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

// How a document's text is written into an output, false when it cannot be.
Spine_Put :: #type proc(run: ^Run, doc: ^core.Document, out: ^write.Out) -> bool

// What the pieces of a spine array share. A collect's (`id` above 0) run the collected filter `f` (nil for the
// entries themselves) on an interpreter that starts as `ip`, and print their outputs when `print`. Any other job's
// pieces are put by `put`, or counted when it is nil.
Spine_Job :: struct {
	run:    ^Run,
	plain:  core.As,
	levels: int, // the arrays a piece's entries are built inside: one per object around the spine array, and its own
	put:    Spine_Put,
	ip:     jq.Interp,
	id:     int, // `run.collects` when a collect started
	f:      ^jq.Node,
	print:  bool,
	lock:   sync.Mutex,
	slots:  [dynamic]Piece_Slot,
	failed: bool,
}

// A marker the frame holds in place of the entries: a string whose spelling every printer keeps.
@(private = "file")
MARKER :: `"\u0001stury"`

@(private = "file", rodata)
WHITE := " \t\r\n"

// Reads the entries of the spine array at `at` of the open file's one text in pieces on the pool's threads, as `job`
// says. False when a piece cannot.
@(private = "file")
spine_run :: proc(ins: ^Inputs, job: ^Spine_Job, at: u64) -> bool {
	job.run, job.plain = ins.run, ins.as
	job.slots.allocator = runtime.heap_allocator()
	return records.each(ins.data, ins.as, .Entries, spine_task, job, run_pool(ins.run), at) == nil && !job.failed
}

// The entries the pieces `slots` hold.
@(private = "file")
entries_of :: proc(slots: []Piece_Slot) -> (n: int) {
	for s in slots {
		n += s.entries
	}
	return
}

// Prints the open file's one text by `put` in pieces, when it is a long strict JSON text with a spine: by `put_dot` as
// `.` prints it, or by `put_fmt` as `fmt` writes it. False, with nothing printed, when it is not printed so.
spine_print :: proc(ins: ^Inputs, put: Spine_Put) -> bool {
	run := ins.run
	at, levels, found := spine_of(ins)
	job := Spine_Job{levels = levels + 1, put = put}
	defer free_slots(run, job.slots)
	// An empty spine prints as `[]`, which only the whole text's print gives.
	if !found || !spine_run(ins, &job, at) || entries_of(job.slots[:]) == 0 {
		return false
	}
	doc, fault := jq.build_text(shell_of(ins.data, at, job.slots[:], MARKER), ins.as, context.temp_allocator)
	if fault != nil {
		return false
	}
	frame: write.Out
	spare: [write.ROOM_MAX]u8
	write.init(&frame, &spare, context.temp_allocator)
	if !put(run, &doc, &frame) {
		return false
	}
	text, _ := write.finish(&frame)
	if !put_joined(run, text, job.slots[:], put == put_dot) {
		return false
	}
	run.route.pieces += len(job.slots)
	run.route.scanned += int(put == put_dot)
	return true
}

// Writes the printed frame `text` with the texts of the pieces `slots` in place of its marker, joined by commas, as
// one output of `.` when `dot`, else as `fmt` writes a text. False, with nothing written, when the marker is not one
// array's only entry.
@(private = "file")
put_joined :: proc(run: ^Run, text: []u8, slots: []Piece_Slot, dot: bool) -> bool {
	mark := bytes.index(text, transmute([]u8)string(MARKER))
	if mark < 0 || bytes.index(text[mark + 1:], transmute([]u8)string(MARKER)) >= 0 {
		return false
	}
	head := bytes.trim_right(text[:mark], transmute([]u8)WHITE)
	if len(head) == 0 || head[len(head) - 1] != '[' {
		return false
	}
	o := &run.output
	flush_some(o, force = true)
	write.put_text(&o.buf, string(head))
	first := true
	for &s in slots {
		if len(s.inner) == 0 {
			continue
		}
		if !first {
			jq.put_byte(&o.buf, ',')
		}
		first = false
		// A piece's text is written from its own buffer, but into a held output.
		if o.held {
			write.put_text(&o.buf, string(s.inner))
		} else {
			flush_some(o, force = true)
			write_out(s.inner)
			o.written += len(s.inner)
		}
		give_spare(&run.spares, s.out, s.room, s.k)
		s.out = nil
	}
	write.put_text(&o.buf, string(text[mark + len(MARKER):]))
	if dot {
		o.result = JQ_OK
		end_output(o)
		finish_input(o)
	} else {
		jq.put_byte(&o.buf, '\n')
		flush_some(o)
	}
	return true
}

// Prints the length of the spine array of the open file's one text, counted on the pool's threads, when the filter is
// `length` on a root array or `.NAME... | length` on the array the names lead to. False, with nothing printed, when it
// is not.
spine_length :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	names := make([dynamic]string, context.temp_allocator)
	n := run.prog
	if !jq.is_length(n) && (n.kind != .Pipe || !jq.is_length(n.b) || !names_of(n.a, &names) || len(names) == 0) {
		return false
	}
	at, levels, found := spine_of(ins)
	job := Spine_Job{levels = levels + 1}
	defer free_slots(run, job.slots)
	if !found || len(names) > levels || !spine_run(ins, &job, at) {
		return false
	}
	count := entries_of(job.slots[:])
	if levels > 0 {
		// The names lead to the array or to an object, whose length is its keys.
		doc, node, walked := spine_walk(ins.data, at, job.slots[:], ins.as, names[:])
		if !walked {
			return false
		}
		if t := doc.nodes[node]; t.kind == .Object {
			count = jq.length_of(jq.Ref{&doc, node})
		} else if t.kind != .Array || u64(t.lo) != at {
			return false
		}
	}
	run.route.interpreted += 1
	run.route.pieces += len(job.slots)
	emit(&run.output, jq.num(f64(count)))
	finish_input(&run.output)
	return true
}

// A piece's entries counted, and built and put, or collected, in the pool thread's arena.
@(private = "file")
spine_task :: proc(job: ^Spine_Job, it: ^records.Reader, k: int) -> bool {
	s := Piece_Slot{k = k}
	text, ok := piece_entries(it, &s)
	switch {
	case !ok || s.entries == 0:
	case job.id > 0:
		ok = collect_entries(job, text, &s)
	case job.put != nil:
		ok = spine_put(job, text, &s)
	}
	sync.guard(&job.lock)
	if k >= len(job.slots) {
		resize(&job.slots, k + 1)
	}
	job.slots[k] = s
	job.failed ||= !ok
	return ok
}

// The text of the piece's entries, counted into `s`. False when an entry is a key's value, a repeated key's.
@(private = "file")
piece_entries :: proc(it: ^records.Reader, s: ^Piece_Slot) -> (text: []u8, ok: bool) {
	lo: u64
	for rec in records.next(it) {
		if rec.key != nil {
			return
		}
		lo = lo if s.entries > 0 else rec.at
		s.end = rec.at + u64(len(rec.text))
		s.entries += 1
	}
	return it.src[lo:s.end], true
}

// The entries `text` built inside `job.levels` arrays and written, with the text between the innermost brackets
// kept.
@(private = "file")
spine_put :: proc(job: ^Spine_Job, text: []u8, s: ^Piece_Slot) -> bool {
	values, temp, mapped := piece_arenas()
	if !mapped {
		return false
	}
	context.allocator, context.temp_allocator = values, temp
	defer {
		free_all(values)
		free_all(temp)
	}
	doc, fault := spine_build(text, job.levels, job.plain)
	if fault != nil {
		return false
	}
	out: write.Out
	spare: [write.ROOM_MAX]u8
	piece_out(&out, &spare, job.run, len(text), s.k)
	return job.put(job.run, &doc, &out) && piece_inner(&out, job.levels, s)
}

// Readies piece `k`'s output `out` of a text of `text_bytes`, which takes the piece's spare buffer.
@(private = "file")
piece_out :: proc(out: ^write.Out, spill: ^[write.ROOM_MAX]u8, run: ^Run, text_bytes, k: int) {
	write.init(out, spill, runtime.heap_allocator(), hint = 2 * text_bytes + 1024)
	take_spare(&run.spares, out, k)
}

// Finishes the piece's output `out` into `s`, with the text of `out` within `n` arrays as `s.inner`: past `n` opening
// brackets and before `n` closing ones, the line break before the first entry kept.
@(private = "file")
piece_inner :: proc(out: ^write.Out, n: int, s: ^Piece_Slot) -> bool {
	s.room = out.size
	printed, err := write.finish(out)
	s.out = printed
	if err.kind != .None {
		return false
	}
	inner := printed
	for _ in 0 ..< n {
		inner = bytes.trim(inner, transmute([]u8)WHITE)
		if len(inner) < 2 || inner[0] != '[' || inner[len(inner) - 1] != ']' {
			return false
		}
		inner = inner[1:len(inner) - 1]
	}
	s.inner = bytes.trim_right(inner, transmute([]u8)WHITE)
	return true
}

// The entries `text` of a spine array built inside `n` arrays, so each sits at the depth it has in the text.
@(private = "file")
spine_build :: proc(text: []u8, n: int, plain: core.As) -> (core.Document, Maybe(core.Fault)) {
	wrapped := make([]u8, len(text) + 2 * n)
	for i in 0 ..< n {
		wrapped[i], wrapped[len(wrapped) - 1 - i] = '[', ']'
	}
	copy(wrapped[n:], text)
	return jq.build_text(wrapped, plain)
}

// Answers the open file's one text on the pool's threads when it is a long strict JSON text and the filter collects `f`
// over the entries of its spine array, then runs a tail on the array: `[.NAME...[] | f] | tail` or
// `.NAME... | map(f) | tail`. Each piece runs `f` on its entries, and the pieces' outputs are joined in source order into
// the one array, which the tail runs on as the serial route runs the filter. With no tail, each piece prints its
// outputs, and their texts are joined as the array prints. False, with nothing printed, when the filter is not so, or
// `f` fails, halts or writes a message on an entry, which leaves the text to the serial route whole.
collect_pieces :: proc(ins: ^Inputs) -> bool {
	run := ins.run
	names := make([dynamic]string, context.temp_allocator)
	f, tail, shaped := collect_shape(run.prog, &names)
	if !shaped {
		return false
	}
	at, levels, found := spine_of(ins)
	if !found || levels != len(names) {
		return false
	}
	layout := run.output.layout
	run.collects += 1
	job := Spine_Job{ip = run.ip, id = run.collects, f = f, levels = len(names) + 1}
	job.print = tail == nil && layout.colors == nil && !layout.comments && run.output.table == nil
	jq.detach_memory(&job.ip)
	defer {
		free_slots(run, job.slots)
		run.ip.err = nil // an error the tail raised may lie in a piece arena
	}
	if !spine_run(ins, &job, at) || !spine_named(ins.data, at, job.slots[:], ins.as, names[:]) {
		return false
	}
	n := 0
	for s in job.slots {
		n += len(s.items)
	}
	run.route.interpreted += 1
	run.route.pieces += len(job.slots)
	// An empty array prints with no line break inside, as the joined texts would give it.
	if job.print && n > 0 {
		frame: write.Out
		spare: [write.ROOM_MAX]u8
		write.init(&frame, &spare, context.temp_allocator)
		marked := jq.Array{}
		append(&marked.items, "\x01stury")
		layout.spill = nil
		jq.write_value(&frame, &marked, layout)
		text, _ := write.finish(&frame)
		if put_joined(run, text, job.slots[:], true) {
			return true
		}
	}
	joined := jq.new_array(n)
	for s in job.slots {
		append(&joined.items, ..s.items[:])
	}
	identity := jq.Node{kind = .Identity}
	prog := run.prog
	run.prog = tail if tail != nil else &identity
	run_once(run, joined)
	run.prog = prog
	return true
}

// The filter `n` split into the collected filter `f` and the `tail` run on the array of its outputs, nil for none, the
// names that lead to the iterated array appended to `names`. False when `n` is no such filter.
@(private = "file")
collect_shape :: proc(n: ^jq.Node, names: ^[dynamic]string) -> (f, tail: ^jq.Node, ok: bool) {
	c := n
	for c.kind == .Pipe && names_of(c.a, names) {
		c = c.b
	}
	if c.kind == .Pipe {
		c, tail = c.a, c.b
	}
	switch {
	case c.kind == .Call && c.name == "map" && len(c.args) == 1 && c.def != nil && c.def.in_prelude:
		f = c.args[0]
	case c.kind == .Array && c.a != nil:
		it := c.a
		for it.kind == .Pipe && names_of(it.a, names) {
			it = it.b
		}
		if it.kind == .Pipe {
			it, f = it.a, it.b
		}
		if it.kind != .Iterate || it.opt || !names_of(it.a, names) {
			return
		}
	case:
		return
	}
	return f, tail, true
}

// Whether `n` is `.` or `.NAME...` with no `?`, whose names are appended to `names`.
@(private = "file")
names_of :: proc(n: ^jq.Node, names: ^[dynamic]string) -> bool {
	at := len(names)
	x := n
	for ; x.kind == .Field && !x.opt; x = x.a {
		inject_at(names, at, x.name)
	}
	if x.kind != .Identity {
		resize(names, at)
		return false
	}
	return true
}

// The collect job whose outputs the thread's piece arena holds.
@(private = "file", thread_local)
piece_job: int

// The entries `text` built in the thread's piece arena, as one document, and run through `f` into `s.items`, and
// printed into `s.out` when the job prints. The arena holds them past the job, until a piece of another job empties it.
@(private = "file")
collect_entries :: proc(job: ^Spine_Job, text: []u8, s: ^Piece_Slot) -> bool {
	values, _, mapped := piece_arenas()
	if !mapped {
		return false
	}
	if piece_job != job.id {
		free_all(values)
		piece_job = job.id
	}
	// What `f` makes, temporary or not, lives as long as the serial route keeps it: until the input is answered.
	context.allocator, context.temp_allocator = values, values
	doc := new(core.Document)
	fault: Maybe(core.Fault)
	if doc^, fault = spine_build(text, job.levels, job.plain); fault != nil {
		return false
	}
	ip := job.ip
	node := core.ROOT
	for _ in 1 ..< job.levels {
		c := core.children(doc, node)
		node, _ = core.child_next(&c)
	}
	s.items = make([dynamic]jq.Value, 0, s.entries if job.f == nil else 0)
	collect := jq.region_collect(&ip, job.f, ip.globals, &s.items)
	defer jq.free_regions(&ip)
	sig := jq.Signal.Go
	ch := core.children(doc, node)
	for e in core.child_next(&ch) {
		if job.f == nil {
			append(&s.items, jq.Ref{doc, e})
		} else if sig = collect.emit(&collect, {v = jq.Ref{doc, e}}); sig != .Go {
			break
		}
	}
	if jq.end_region_collect(&collect, sig) != .Go {
		return false
	}
	if len(ip.messages) > 0 || ip.halted != nil {
		return false
	}
	if !job.print || len(s.items) == 0 {
		return true
	}
	layout := job.run.output.layout
	layout.spill = nil
	out: write.Out
	spare: [write.ROOM_MAX]u8
	piece_out(&out, &spare, job.run, len(text), s.k)
	a := jq.Array{items = s.items}
	jq.write_value(&out, &a, layout)
	return out.err == .None && piece_inner(&out, 1, s)
}

// `.` as jq prints it, without the trailing newline.
put_dot :: proc(run: ^Run, doc: ^core.Document, out: ^write.Out) -> bool {
	layout := run.output.layout
	if layout.colors != nil || layout.comments || run.output.table != nil {
		return false
	}
	layout.spill = nil
	jq.write_value(out, jq.Ref{doc, core.ROOT}, layout)
	return out.err == .None
}

// The document as `fmt` writes it, without the trailing newline.
put_fmt :: proc(run: ^Run, doc: ^core.Document, out: ^write.Out) -> bool {
	if writes_cells(&run.opts) || writes_comments(&run.opts) {
		return false
	}
	text, _, err := core.write(doc, run.output.layout.opts, json.as(.Json, {max_depth = run.opts.max_depth}), allocator = context.temp_allocator)
	write.put_text(out, string(text))
	return err.kind == .None
}
