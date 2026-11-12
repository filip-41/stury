package build

import "base:runtime"
import core ".."

// The largest batch an `Answer_Iter` fills between two walks, the `Answer_Iter.max_batch` a format's `answers` sets.
ANSWER_BATCH :: 64

// An iterator over the answers of a read, which `next` gives one at a time in the order `each_answer` gives them to its
// `on`. A format's `answers` makes it, and nothing is read before the first `next`, which starts the scan on the
// iterator's own storage, so the iterator does not move once a loop has begun. A walk fills `buffer` with a batch of
// answers, stops on the first token past it and saves where it stood in `cursor`, and the next fill resumes it there.
// The batch starts at 1 and doubles up to `max_batch`, so a loop that ends early has read little past what it took.
// When a walk gives a burst of answers at once, as the close of a container under `.Last` does, the buffer holds them
// all. `err` holds the fault or error that ended the read, after every answer read before it. A loop that ends before
// `next` returns false frees the read with `answers_destroy`.
Answer_Iter :: struct {
	err:        core.Error,
	max_batch:  int,
	src:        []u8,
	as:         core.As,
	paths:      []core.Path, // the caller's, read at the first `next`, or nil for `one`
	one:        core.Path,
	read:       core.Path_Options,
	allocator:  runtime.Allocator,
	// The format's walk, which starts the read when `state` is `.Fresh`, resumes it from `cursor` after, and ends it
	// with `answers_end` when the walk ends, faults or stops for good.
	fill:       proc(it: ^Answer_Iter),
	buffer:     [dynamic]core.Token_Answer,
	at:         int, // the next answer of `buffer` to give
	batch:      int,
	state:      Answer_State,
	regs:       core.Hook_Regs,
	held:       []core.Token, // tokens the format's walk keeps across fills, from `allocator`
	// Frees what else the format's walk keeps across fills, nil when it keeps nothing else.
	release:    proc(it: ^Answer_Iter),
	stack:      []u8, // the walk's depth stack, `stack_room` or from `allocator`
	cursor:     [16]u64, // the format's cursor
	scan:       Scan,
	frames:     [core.MAX_DEPTH]u64,
	stack_room: [core.MAX_DEPTH]u8,
}

Answer_State :: enum u8 {
	Fresh,
	Walking,
	Done,
}

// Gives the next answer, false once the read ended, with `it.err` then holding the error that ended it or nil.
answers_next :: #force_inline proc(it: ^Answer_Iter) -> (answer: core.Token_Answer, ok: bool) {
	if it.at < len(it.buffer) {
		it.at += 1
		return it.buffer[it.at - 1], true
	}
	return answers_refill(it)
}

// Fills the buffer with the next batch and gives its first answer, or frees it once the read ended.
@(private)
answers_refill :: #force_no_inline proc(it: ^Answer_Iter) -> (answer: core.Token_Answer, ok: bool) {
	if it.state != .Done {
		clear(&it.buffer)
		it.at = 0
		it.scan.paused = false
		it.fill(it)
		it.batch = min(2 * it.batch, it.max_batch)
	}
	if it.at == len(it.buffer) {
		delete(it.buffer)
		it.buffer, it.at = nil, 0
		return {}, false
	}
	it.at = 1
	return it.buffer[0], true
}

// Frees what the read holds: the scan of a loop that ended early, the buffer and the format's storage.
answers_destroy :: proc(it: ^Answer_Iter) {
	if it.state == .Walking {
		it.scan.stopped = true
		doc: core.Document
		_ = scan_end(&it.scan, it.regs, 0, nil, &doc)
		core.destroy(&doc)
	}
	it.state = .Done
	answers_free(it)
	delete(it.buffer)
	it.buffer, it.at = nil, 0
}

// Starts the scan of a fill whose `state` is `.Fresh`, with the stack `depth` levels deep. Under `.Refuse` the fill has
// built the whole text with its options first, so a fault there comes before any answer. Returns false, with the read
// ended, when the scan cannot start.
answers_start :: proc(it: ^Answer_Iter, positional: bool, depth: int) -> bool {
	it.batch = max(it.batch, 1)
	it.max_batch = max(it.max_batch, it.batch)
	// A batch fits without growing, and only a burst past `max_batch` appends.
	it.buffer = make([dynamic]core.Token_Answer, 0, it.max_batch, it.allocator)
	paths := it.paths if it.paths != nil else ([^]core.Path)(&it.one)[:1]
	if e := scan_start(&it.scan, it.src, it.as, paths, it.read, positional, it.allocator, depth, it.frames[:], true, it, answers_on); e.kind != .None {
		answers_fail(it, core.error_of(e))
		return false
	}
	it.state = .Walking
	return true
}

// Ends the read of a walk that ended at `hi` with `fault`, as `scan_end` does, and gives what it settled.
answers_end :: proc(it: ^Answer_Iter, hi: u64, fault: Maybe(core.Fault)) {
	doc: core.Document
	e := scan_end(&it.scan, it.regs, hi, fault, &doc)
	core.destroy(&doc)
	it.state = .Done
	if it.err == nil {
		it.err = core.error_of(e)
	}
	answers_free(it)
}

// The fill of an iterator over a text its format reads only whole, once its format binds `build` (`Services.build`):
// the first fill builds the text, under `.Refuse` refusing a repeated name, buffers every answer and ends the read.
answers_built :: proc(it: ^Answer_Iter, build: proc(src: []u8, as: core.As, refuse_duplicates: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error)) {
	paths := it.paths if it.paths != nil else ([^]core.Path)(&it.one)[:1]
	it.buffer = make([dynamic]core.Token_Answer, 0, it.max_batch, it.allocator)
	doc, built := build(it.src, it.as, it.read.dups == .Refuse, it.allocator)
	if built.kind != .None && it.read.dups == .Refuse {
		core.destroy(&doc)
		answers_fail(it, core.error_of(built))
		return
	}
	_, err := scan_built(&doc, built, paths, it.read, &it.buffer, proc(state: rawptr, a: core.Token_Answer) -> bool {
		_, e := append((^[dynamic]core.Token_Answer)(state), a)
		return e == nil
	}, it.allocator)
	core.destroy(&doc)
	answers_fail(it, core.error_of(err))
}

// Ends a read that could not start with `e`.
answers_fail :: proc(it: ^Answer_Iter, e: core.Error) {
	it.err = e
	it.state = .Done
	answers_free(it)
}

// The `on` of an iterator's scan, which buffers every answer and asks the walk to pause once a batch is held.
@(private)
answers_on :: proc(state: rawptr, a: core.Token_Answer) -> bool {
	it := (^Answer_Iter)(state)
	n := len(it.buffer)
	if n < cap(it.buffer) {
		(^runtime.Raw_Dynamic_Array)(&it.buffer).len = n + 1
		it.buffer[n] = a
	} else if _, e := append(&it.buffer, a); e != nil {
		it.err = e
		return false
	}
	it.scan.paused = n + 1 >= it.batch
	return true
}

// Frees the format's storage. The buffer lives until its answers are given.
@(private)
answers_free :: proc(it: ^Answer_Iter) {
	delete(it.held, it.allocator)
	it.held = nil
	if it.release != nil {
		it.release(it)
		it.release = nil
	}
	if raw_data(it.stack) != &it.stack_room[0] {
		delete(it.stack, it.allocator)
	}
	it.stack = nil
}
