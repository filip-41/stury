package records

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:sync"
import core ".."
import "../kernel"
import engine "../build"

// Returns the fault of each refused record of `src` read from byte `at`, in source order, and last the fault that ended
// the records, if any. The slice is allocated with `allocator`. An allocation that fails returns its error and no
// faults. With a `runner`, a long text is read in pieces on its threads, with the same answer.
check :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator, runner: ^core.Runner = nil, at: u64 = 0) -> (faults: []core.Fault, err: runtime.Allocator_Error) {
	out := make([dynamic]core.Fault, allocator)
	if err = judge_all(src, as, framing, at, runner, &out); err != nil {
		delete(out)
		return nil, err
	}
	return out[:], nil
}

// Returns the fault of `src` as one whole text of format `as`, which is the fault the format's `validate` gives, or nil.
// A format that does not take it answers `.Bad_Option`. With a `runner`, a long text is read in pieces on its threads,
// with the same answer.
validate :: proc(src: []u8, as: core.As, runner: ^core.Runner = nil) -> Maybe(core.Fault) {
	services := (^Services)(as.spelling.records) if as.spelling != nil else nil
	if services == nil || services.whole == nil {
		return core.Fault{kind = .Bad_Option}
	}
	whole, framing, at := services.whole(src, as)
	// A whole text's records are judged by the walk that frames them, so only the fault that ends them is given.
	first: [1]core.Fault
	out := slice.into_dynamic(first[:])
	if judge_all(src, whole, framing, at, runner, &out) != nil {
		return core.Fault{kind = .No_Memory}
	}
	return Maybe(core.Fault)(first[0]) if len(out) > 0 else nil
}

// The bytes each piece of a text read on threads spans. The tests set it to 1, so that every byte is a cut.
@(private)
SLICE :: #config(RECORDS_SLICE, 64 * 1024)

// What the chain of records from a piece's first guess found: the offset of its first record, 0 when no chain reached
// the piece's end or the text's with no fault, where it arrived past its last record, and the faults of its records.
@(private)
Piece :: struct {
	first:  u64,
	pos:    u64,
	state:  [8]u8,
	faults: [dynamic]core.Fault,
}

@(private)
Chain :: struct {
	start:   Reader,
	pieces:  []Piece,
	claimed: int,
}

// Appends to `out` the fault of each refused record of `src` from `at` and the fault that ended the records. Past the
// first record, on a runner's threads, each piece guesses where a record starts and chains records from there. Then
// the records are read in source order, and a piece whose first record is the next one read gives its faults and the
// place its chain arrived at, which the reading jumps to. So a guess counts only where a chain from a true start
// reached it, and the answer is the one a serial read gives.
@(private)
judge_all :: proc(src: []u8, as: core.As, framing: core.Framing, at: u64, runner: ^core.Runner, out: ^[dynamic]core.Fault) -> runtime.Allocator_Error {
	it := open(src, as, framing, at)
	defer close(&it)
	// The first record comes alone, so the pieces can start past it.
	to := it.pos + 1
	c: Chain
	// Run in reverse: the faults go before the pieces that hold them.
	defer delete(c.pieces, runtime.heap_allocator())
	defer for &p in c.pieces {
		delete(p.faults)
	}
	for {
		rec, more := next_span(&it, to)
		fault := it.fault
		if more {
			// A record before the pieces' start wraps `k` past them.
			k := (rec.at - c.start.pos) / SLICE
			if k < u64(len(c.pieces)) && c.pieces[k].first == rec.at {
				append(out, ..c.pieces[k].faults[:]) or_return
				it.pos, it.state = c.pieces[k].pos, c.pieces[k].state
				continue
			}
			fault = it.services.judge(&it, rec)
			// The pieces start past the first record, where the reader knows the framing's state.
			if c.pieces == nil && runner != nil && runner.threads > 0 && it.services.guess != nil && u64(len(src)) >= it.pos + 2 * SLICE {
				c.start = it
				c.pieces = make([]Piece, (u64(len(src)) - it.pos + SLICE - 1) / SLICE, runtime.heap_allocator()) or_return
				fan(runner, chain_pieces, &c)
			}
			// A record comes alone at a piece's start, where it may be the piece's first, and the text before the next
			// piece's start comes as one, or with no pieces the rest of the text.
			to = max(u64)
			if c.pieces != nil {
				to = c.start.pos + (k + 1) * SLICE if rec.at >= c.start.pos else c.start.pos
			}
		}
		if f, bad := fault.?; bad {
			append(out, f) or_return
		}
		if !more {
			return nil
		}
	}
}

// Claims pieces until none is left, and chains records from each piece's first guess until the next record starts past
// the piece, then from the next guess past where a chain that a fault ended stopped.
@(private)
chain_pieces :: proc(arg: rawptr) {
	c := (^Chain)(arg)
	for {
		k := sync.atomic_add(&c.claimed, 1)
		if k >= len(c.pieces) {
			return
		}
		p := &c.pieces[k]
		p.faults.allocator = runtime.heap_allocator()
		lo := c.start.pos + u64(k) * SLICE
		hi := min(lo + SLICE, u64(len(c.start.src)))
		for from := lo; from < hi; {
			it := c.start
			it.pos, it.guessed = from, true
			if !it.services.guess(&it, hi) {
				break
			}
			from = it.pos + 1
			first: u64
			clear(&p.faults)
			for {
				pos, state := it.pos, it.state
				rec, more := next_span(&it, hi)
				if !more || rec.at >= hi {
					it.pos, it.state = pos, state
					break
				}
				first = first if first != 0 else rec.at
				if f, bad := it.services.judge(&it, rec).?; bad {
					if _, e := append(&p.faults, f); e != nil {
						it.fault = core.Fault{kind = .No_Memory}
						break
					}
				}
			}
			if it.fault == nil {
				p.first, p.pos, p.state = first, it.pos, it.state
				break
			}
			from = max(from, it.pos)
		}
	}
}

// Returns the next record, or with the format's `span` service the records up to the first at or past `to` as one.
@(private)
next_span :: #force_inline proc(it: ^Reader, to: u64) -> (Record, bool) {
	if it.fault != nil || it.services.span == nil {
		return next(it)
	}
	return it.services.span(it, to)
}

// Runs `task(arg)` on the calling thread and on `runner`'s, and returns once every call has.
@(private)
fan :: proc(runner: ^core.Runner, task: proc(arg: rawptr), arg: rawptr) {
	runner.start(runner.data, runner.threads, task, arg)
	task(arg)
	runner.finish(runner.data)
}

// Runs `task` on pieces of the records of `src` in format `as` under `framing` from byte `at`, each a reader over whole
// records, and returns the first fault in source order that ended a piece's records, or nil. Each piece is handed out
// once and closed after its task returns, and `k` numbers them in source order with gaps. With a `runner` they run on
// its threads, cut where the format finds a record's end by a scan from the first record's, and with none, or no such
// cut in the format, the whole text is piece 0. Once a task returns false or a piece's records end on a fault, no
// further piece is handed out. A piece's own memory comes from the heap.
//
// A piece's cuts are found as if the text before them were well-formed, so a piece that starts past the returned
// fault's `at`, which a thread started before the fault was found, may give records that are no records of the text.
// The caller drops what tasks found at or past that byte. What they found before it is each record `next` gives there,
// once.
each :: #force_inline proc(src: []u8, as: core.As, framing: core.Framing, task: proc(data: ^$D, piece: ^Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0) -> Maybe(core.Fault) {
	return each_piece(src, as, framing, cast(proc(data: rawptr, piece: ^Reader, k: int) -> bool)task, data, runner, at)
}

// `each`'s pieces: piece 0 runs from the text's start and piece k past it from the first cut in slice k - 1 of the text
// past the first record, each up to the next cut. `cuts` holds where a quoted cut stands at each slice's start, for the
// first `folded` slices, and a slice's own run past them. `state` is where a cut stands past the folded slices.
// `fault_piece` is the first piece whose records ended on a fault, `max(int)` before one, and `fault` that fault.
@(private)
Each :: struct {
	start:       Reader,
	rule:        kernel.Quotes,
	cuts:        []Cut,
	state:       kernel.Quotes,
	folded:      int,
	sliced:      int,
	base:        u64,
	slices:      int,
	task:        proc(data: rawptr, piece: ^Reader, k: int) -> bool,
	data:        rawptr,
	claimed:     int,
	stop:        bool,
	lock:        sync.Mutex,
	fault_piece: int,
	fault:       Maybe(core.Fault),
}

@(private)
Cut :: struct {
	quotes: kernel.Quotes,
	read:   bool,
}

@(private)
each_piece :: proc(src: []u8, as: core.As, framing: core.Framing, task: proc(data: rawptr, piece: ^Reader, k: int) -> bool, data: rawptr, runner: ^core.Runner, at: u64) -> Maybe(core.Fault) {
	e := Each{start = open(src, as, framing, at, runtime.heap_allocator()), task = task, data = data, fault_piece = max(int)}
	defer close(&e.start)
	if e.start.fault != nil {
		return e.start.fault
	}
	if runner != nil && runner.threads > 0 && e.start.services.exact != nil {
		exact: bool
		e.rule, exact = e.start.services.exact(&e.start)
		// The slices start past the first record, where the reader knows the framing's state.
		if rec, ok := next(&e.start); exact && ok && u64(len(src)) >= rec.at + u64(len(rec.text)) + 2 * SLICE {
			e.base = rec.at + u64(len(rec.text))
			e.slices = int((u64(len(src)) - e.base + SLICE - 1) / SLICE)
		}
	}
	defer delete(e.cuts, runtime.heap_allocator())
	if e.slices > 0 && e.rule.quote != 0 {
		cuts, err := make([]Cut, e.slices, runtime.heap_allocator())
		if err != nil {
			return core.Fault{kind = .No_Memory}
		}
		e.cuts = cuts
		e.state = e.rule
		e.state.depth[0] = e.rule.want
	}
	if e.slices > 0 {
		fan(runner, run_pieces, &e)
	} else {
		run_pieces(&e)
	}
	return e.fault
}

@(private)
slice_of :: proc(e: ^Each, k: int) -> []u8 {
	lo := e.base + u64(k) * SLICE
	return e.start.src[lo:min(lo + SLICE, u64(len(e.start.src)))]
}

// Keeps slice `k`'s `raw` run, read from an even escape run under both starts, then turns each run that follows the folded
// slices into the state its slice starts at: the one the slices before it leave, read again when an escape run crosses
// into it.
@(private)
fold :: proc(e: ^Each, k: int, raw: kernel.Quotes) {
	sync.guard(&e.lock)
	e.cuts[k] = {raw, true}
	st := &e.state
	for f := e.folded; f < len(e.cuts) && e.cuts[f].read; f += 1 {
		r := &e.cuts[f].quotes
		if st.odd != 0 {
			r^ = e.rule
			r.odd = st.odd
			kernel.quote_run(slice_of(e, f), r)
		}
		run, g := r^, int(st.quoted)
		r^ = st^
		// A level that fell below the first record's ends the cuts.
		st.depth[0] = st.depth[0] + run.depth[g] if st.depth[0] + run.low[g] >= st.want else min(int) / 2
		st.quoted = run.quoted != st.quoted
		st.odd = run.odd
		sync.atomic_store(&e.folded, f + 1)
	}
}

// Returns the byte past the first cut from slice `k`'s start, within the slice unless `on`, or false when there is none.
@(private)
cut_from :: proc(e: ^Each, k: int, on: bool) -> (u64, bool) {
	lo := e.base + u64(k) * SLICE
	i := kernel.quote_cut(e.start.src[lo:] if on else slice_of(e, k), e.cuts[k].quotes if e.cuts != nil else e.rule)
	return lo + u64(i) + 1, i >= 0
}

// Claims slices until none is left, then pieces until none is left or one stops the run, and runs the task on each
// that starts at a cut, once the slices it starts and ends in are folded.
@(private)
run_pieces :: proc(arg: rawptr) {
	e := (^Each)(arg)
	for k := sync.atomic_add(&e.sliced, 1); k < len(e.cuts); k = sync.atomic_add(&e.sliced, 1) {
		raw := e.rule
		kernel.quote_run(slice_of(e, k), &raw)
		fold(e, k, raw)
	}
	// A piece claimed before the one that stops the run still runs, so every piece before a fault runs.
	for !sync.atomic_load(&e.stop) {
		k := sync.atomic_add(&e.claimed, 1)
		// A piece past a piece that faulted has cuts found as if the text before were well-formed.
		if k > e.slices || sync.atomic_load(&e.fault_piece) < k {
			return
		}
		// Every slice is claimed, so each one waited for is being read.
		for sync.atomic_load(&e.folded) <= min(k, len(e.cuts) - 1) {
			intrinsics.cpu_relax()
		}
		lo, hi: u64 = 0, u64(len(e.start.src))
		if k > 0 {
			ok: bool
			if lo, ok = cut_from(e, k - 1, false); !ok {
				continue
			}
		}
		if k < e.slices {
			hi = cut_from(e, k, true) or_else hi
		}
		piece := e.start if k > 0 else open(e.start.src, e.start.as, e.start.framing, e.start.from, runtime.heap_allocator())
		if e.slices > 0 && !piece.services.piece(&piece, lo, hi) {
			piece.fault = core.Fault{kind = .No_Memory}
		}
		more := piece.fault == nil && e.task(e.data, &piece, k)
		if f, bad := piece.fault.?; bad || !more {
			sync.atomic_store(&e.stop, true)
			sync.guard(&e.lock)
			if bad && k < e.fault_piece {
				e.fault = f
				sync.atomic_store(&e.fault_piece, k)
			}
		}
		close(&piece)
	}
}

// Builds a record's document, or a whole text's.
build :: proc {build_record, build_whole}

// Builds `src` as one whole text of format `as`, as `core.build` does. With a `runner`, a long text whose bulk is the
// entries of one array, its `whole` records, has them built in pieces on the runner's threads and joined into the
// document `core.build` gives, node for node. A text that is not so, or that does not build so, is built on the
// calling thread, which gives its refusal. `pieces`, when given, is set to the pieces a joined build cut, and left
// alone by a build on the calling thread.
@(private)
build_whole :: proc(src: []u8, as: core.As, refuse_duplicates := false, allocator := context.allocator, runner: ^core.Runner = nil, pieces: ^int = nil) -> (core.Document, core.Document_Error) {
	services := (^Services)(as.spelling.records) if as.spelling != nil else nil
	if runner != nil && runner.threads > 0 && services != nil && services.build_next != nil && u64(len(src)) >= 4 * SLICE {
		whole, framing, at := services.whole(src, as)
		if !entries_unkeyed(src, whole, framing, at) {
			return core.build(src, as, refuse_duplicates, allocator)
		}
		job := Build_Job{refuse = refuse_duplicates}
		job.pieces.allocator = runtime.heap_allocator()
		// The joined nodes take the room a serial build reserves.
		depth := core.reserve_depth(as.max_depth, len(src))
		room, refused := runtime.mem_alloc_non_zeroed(((len(src) + depth) / 2 + 16) * size_of(core.Node), align_of(core.Node), allocator)
		if refused != nil {
			return core.build(src, as, refuse_duplicates, allocator)
		}
		job.nodes = ([^]core.Node)(raw_data(room))[:len(room) / size_of(core.Node)]
		defer {
			for &p in job.pieces {
				core.destroy(&p.doc)
			}
			delete(job.pieces)
		}
		if each(src, whole, framing, build_piece, &job, runner, at) == nil && !job.failed {
			if doc, ok := join(src, as, &job, allocator, runner); ok {
				if pieces != nil {
					pieces^ = len(job.pieces)
				}
				return doc, {}
			}
		}
		delete(job.nodes, allocator)
	}
	return core.build(src, as, refuse_duplicates, allocator)
}

// Whether the first of the records at `at` is an array's entry, not an object's member, which no piece of a whole
// text's build joins: a text with no array to split is built on one thread without a run of pieces before it.
@(private)
entries_unkeyed :: proc(src: []u8, as: core.As, framing: core.Framing, at: u64) -> bool {
	it := open(src, as, framing, at, runtime.heap_allocator())
	defer close(&it)
	rec, more := next(&it)
	return more && rec.key == nil
}

// A piece of `build_whole`: the document of its entries, each a root of it, and the bytes from its first entry's
// first byte to its last entry's end. `base` is the node its nodes start at in the joined document.
@(private)
Built :: struct {
	doc:     core.Document,
	entries: int,
	lo, hi:  u64,
	base:    int,
}

// `nodes` is the joined document's, `built` the nodes the built pieces hold, and `faulted` the nodes of `nodes` whose
// pages `fault_ahead` wrote, on the thread that holds `faulting`.
@(private)
Build_Job :: struct {
	refuse:   bool,
	lock:     sync.Mutex,
	pieces:   [dynamic]Built,
	failed:   bool,
	nodes:    []core.Node,
	claimed:  int,
	built:    int,
	faulted:  int,
	faulting: bool,
}

// Builds a piece's entries into one document on the heap, as the roots of a text of values one after another. The
// reader reads the text up to the piece's end alone, so its walk writes at most one node per two of those bytes, as
// a whole text's build reserves, even past a fault whose text the piece's cuts misread.
@(private)
build_piece :: proc(job: ^Build_Job, it: ^Reader, k: int) -> bool {
	if it.to != 0 && it.to < u64(len(it.src)) {
		// The separator at `to` stays, so the entry before it is judged as in the whole text.
		it.src = it.src[:it.to + 1]
	}
	bytes := len(it.src) - int(it.pos)
	depth := core.reserve_depth(it.as.max_depth, bytes)
	b := engine.builder_start(it.src, it.as, job.refuse, runtime.heap_allocator(), (bytes + depth) / 2 + 16, depth)
	regs := engine.BUILDER_REGS
	p: Built
	ok := len(b.doc.nodes) > 0
	for ok {
		rec, more := it.services.build_next(it, &b, &regs)
		if !more {
			break
		}
		// A member's key makes no node, so an object's entries do not join.
		ok = rec.key == nil
		p.lo = p.lo if p.entries > 0 else rec.at
		p.hi = rec.at + u64(len(rec.text))
		p.entries += 1
	}
	err: core.Document_Error
	p.doc, err = engine.builder_end(&b, regs, it.fault if ok else core.Fault{kind = .Bad_Option})
	ok &&= err.kind == .None
	{
		sync.guard(&job.lock)
		if k >= len(job.pieces) {
			resize(&job.pieces, k + 1)
		}
		job.pieces[k] = p
		job.failed ||= !ok
	}
	sync.atomic_add(&job.built, len(p.doc.nodes))
	fault_ahead(job)
	return ok
}

// Writes `nodes` a page at a time up to the nodes the built pieces hold, on one thread at a time. Threads that write
// fresh pages of one allocation at once wait on each other, and each piece's own allocation does not, so the pieces
// build on every thread while the join's copy finds its pages already written.
@(private)
fault_ahead :: proc(job: ^Build_Job) {
	if _, took := sync.atomic_compare_exchange_strong(&job.faulting, false, true); !took {
		return
	}
	for job.faulted < min(sync.atomic_load(&job.built), len(job.nodes)) {
		job.nodes[job.faulted] = {}
		job.faulted += 4096 / size_of(core.Node)
	}
	sync.atomic_store(&job.faulting, false)
}

// The document of `src` with the pieces' entries in its array, or false when the text around them does not build
// with the array empty. That text is built alone, and its nodes past the array move by the bytes cut out.
@(private)
join :: proc(src: []u8, as: core.As, job: ^Build_Job, allocator: runtime.Allocator, runner: ^core.Runner) -> (doc: core.Document, ok: bool) {
	lo, hi := u64(len(src)), u64(0)
	n, entries := 0, 0
	for &p in job.pieces {
		if p.entries > 0 {
			lo, hi = min(lo, p.lo), p.hi
			p.base = n
			n += len(p.doc.nodes)
			entries += p.entries
		}
	}
	if entries == 0 {
		return
	}
	cut := hi - lo
	heap := runtime.heap_allocator()
	shell := make([]u8, u64(len(src)) - cut, heap)
	defer delete(shell, heap)
	copy(shell, src[:lo])
	copy(shell[lo:], src[hi:])
	frame, err := core.build(shell, as, job.refuse, heap)
	defer core.destroy(&frame)
	// The array is the last node to open before the first entry.
	array := 0
	for array < len(frame.nodes) && frame.nodes[array].lo < lo {
		array += 1
	}
	array -= 1
	if err.kind != .None || array < 0 || frame.nodes[array].kind != .Array || frame.nodes[array].n != 1 || len(frame.facts) > 0 {
		return
	}
	if len(frame.nodes) + n > len(job.nodes) {
		return
	}
	nodes := job.nodes[:len(frame.nodes) + n]
	copy(nodes, frame.nodes[:array + 1])
	// The array's subtree and each one around it grow by the entries' nodes.
	for &t, i in nodes[:array + 1] {
		if (t.kind == .Array || t.kind == .Map) && i + int(t.n) > array {
			t.n += u32(n)
		}
	}
	nodes[array].spelling = u16(min(entries, int(core.MAX_CHILDREN)))
	for t, i in frame.nodes[array + 1:] {
		nodes[array + 1 + n + i] = {t.lo + cut, t.n, t.kind, t.role, t.spelling}
	}
	for &p in job.pieces {
		p.base += array + 1
	}
	fan(runner, copy_pieces, job)
	counts := make([dynamic]core.Child_Count, allocator)
	for c in frame.counts {
		append(&counts, core.Child_Count{c.node + core.Node_Index(n) if int(c.node) > array else c.node, c.count})
	}
	if entries >= int(core.MAX_CHILDREN) {
		append(&counts, core.Child_Count{core.Node_Index(array), u32(entries)})
	}
	for p in job.pieces {
		for c in p.doc.counts {
			append(&counts, core.Child_Count{c.node + core.Node_Index(p.base), c.count})
		}
	}
	slice.sort_by(counts[:], proc(a, b: core.Child_Count) -> bool { return a.node < b.node })
	doc = {view = {src, as}, nodes = nodes, nodes_alloc = job.nodes, counts = counts[:], counts_alloc = counts[:], allocator = allocator}
	doc.root_close = frame.root_close + cut if frame.root_close > lo else frame.root_close
	return doc, true
}

// Claims pieces until none is left, and copies each one's nodes to its place in the joined document.
@(private)
copy_pieces :: proc(arg: rawptr) {
	job := (^Build_Job)(arg)
	for k := sync.atomic_add(&job.claimed, 1); k < len(job.pieces); k = sync.atomic_add(&job.claimed, 1) {
		copy(job.nodes[job.pieces[k].base:], job.pieces[k].doc.nodes)
	}
}
