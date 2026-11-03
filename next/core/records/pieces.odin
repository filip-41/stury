package records

import "base:runtime"
import "core:slice"
import "core:sync"
import core ".."

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
				runner.start(runner.data, runner.threads, chain_pieces, &c)
				chain_pieces(&c)
				runner.finish(runner.data)
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
