package records

import "base:runtime"
import "core:slice"
import "core:sync"
import core ".."
import "../kernel"

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
	state:  [2]u8,
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
	it.to = 1
	c: Chain
	// Run in reverse: the faults go before the pieces that hold them.
	defer delete(c.pieces, runtime.heap_allocator())
	defer for &p in c.pieces {
		delete(p.faults)
	}
	for {
		rec, more := next(&it)
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
			it.to = max(u64)
			if c.pieces != nil {
				it.to = c.start.pos + (k + 1) * SLICE if rec.at >= c.start.pos else c.start.pos
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
			it.pos, it.to = from, hi
			if !it.services.guess(&it, hi) {
				break
			}
			from = it.pos + 1
			first: u64
			clear(&p.faults)
			for {
				pos, state := it.pos, it.state
				rec, more := it.services.next[it.framing](&it)
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
each :: #force_inline proc(src: []u8, as: core.As, framing: core.Framing, task: proc(data: ^$D, piece: ^Reader, k: int) -> bool, data: ^D, runner: ^core.Runner = nil, at: u64 = 0) -> Maybe(core.Fault) {
	return each_piece(src, as, framing, cast(proc(data: rawptr, piece: ^Reader, k: int) -> bool)task, data, runner, at)
}

// `each`'s pieces: piece 0 runs from the text's start and piece k past it from the first cut in slice k - 1 of the text
// past the first record, each up to the next cut. `cuts` holds where a quoted cut stands at each slice's start.
@(private)
Each :: struct {
	start:   Reader,
	rule:    kernel.Quotes,
	cuts:    []kernel.Quotes,
	base:    u64,
	slices:  int,
	task:    proc(data: rawptr, piece: ^Reader, k: int) -> bool,
	data:    rawptr,
	claimed: int,
	stop:    bool,
	lock:    sync.Mutex,
	first:   int,
	fault:   Maybe(core.Fault),
}

@(private)
each_piece :: proc(src: []u8, as: core.As, framing: core.Framing, task: proc(data: rawptr, piece: ^Reader, k: int) -> bool, data: rawptr, runner: ^core.Runner, at: u64) -> Maybe(core.Fault) {
	e := Each{start = open(src, as, framing, at, runtime.heap_allocator()), task = task, data = data, first = max(int)}
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
		cuts, err := make([]kernel.Quotes, e.slices, runtime.heap_allocator())
		if err != nil {
			return core.Fault{kind = .No_Memory}
		}
		e.cuts = cuts
		fan(runner, run_slices, &e)
		e.claimed = 0
		// Each slice's state is the one the slices before it leave, read again when an escape run crosses into it.
		st := e.rule
		st.depth[0] = st.want
		for &r, k in e.cuts {
			if st.odd != 0 {
				r = e.rule
				r.odd = st.odd
				kernel.quote_run(slice_of(&e, k), &r)
			}
			run, g := r, int(st.quoted)
			r = st
			// A level that fell below the first record's ends the cuts.
			st.depth[0] = st.depth[0] + run.depth[g] if st.depth[0] + run.low[g] >= st.want else min(int) / 2
			st.quoted = run.quoted != st.quoted
			st.odd = run.odd
		}
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

// Claims slices until none is left, and reads each from an even escape run under both starts.
@(private)
run_slices :: proc(arg: rawptr) {
	e := (^Each)(arg)
	for k := sync.atomic_add(&e.claimed, 1); k < e.slices; k = sync.atomic_add(&e.claimed, 1) {
		e.cuts[k] = e.rule
		kernel.quote_run(slice_of(e, k), &e.cuts[k])
	}
}

// Returns the byte past the first cut from slice `k`'s start, within the slice unless `on`, or false when there is none.
@(private)
cut_from :: proc(e: ^Each, k: int, on: bool) -> (u64, bool) {
	lo := e.base + u64(k) * SLICE
	i := kernel.quote_cut(e.start.src[lo:] if on else slice_of(e, k), e.cuts[k] if e.cuts != nil else e.rule)
	return lo + u64(i) + 1, i >= 0
}

// Claims pieces until none is left or one stops the run, and runs the task on each that starts at a cut.
@(private)
run_pieces :: proc(arg: rawptr) {
	e := (^Each)(arg)
	// A piece claimed before the one that stops the run still runs, so every piece before a fault runs.
	for !sync.atomic_load(&e.stop) {
		k := sync.atomic_add(&e.claimed, 1)
		if k > e.slices {
			return
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
			if bad && k < e.first {
				e.first, e.fault = k, f
			}
		}
		close(&piece)
	}
}
