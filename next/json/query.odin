package json

import "base:intrinsics"
import core "../core"
import engine "../core/build"

// Reads `path` over `src` as spec `S`, into a partial document holding what the path reached and `Document.answers` in
// text order. Everything the walk passes is still judged, unless `read.stop_early` ends it. `core.destroy` frees the
// document, which borrows `src`. With `read.refuse_duplicates` the document holds the whole text.
@(private)
scan_one :: proc(src: []u8, $S: Spec, path: core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error) {
	return scan_many(src, S, []core.Path{path}, read, opts, allocator)
}

// Reads up to 64 `paths` in one read, as `scan_one`. An answer's `path` is its path's number, and the answers of all the
// paths are in one text order.
@(private)
scan_many :: proc(src: []u8, $S: Spec, paths: []core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error) {
	if read.refuse_duplicates {
		built, e := build(src, S, opts, true, allocator)
		return engine.query_built(&built, e, paths, read)
	}
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
		return {}, {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	opts := opts
	h: engine.Scan
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(&h, src, &SPELLING, paths, read, false, allocator, core.reserve_depth(opts.max_depth, len(src)), frames[:]); e.kind != .None {
		return {}, e
	}
	h.b.doc.read.spec = u8(S)
	h.b.doc.read.max_depth = opts.max_depth
	regs := engine.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	if h.many == nil {
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, engine.scan_hook)
	} else {
		h.opts = &opts
		h.rewalk = proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
			src := h.b.doc.src
			walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, engine.scan_hook_many)
		}
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, engine.scan_hook_many)
	}
	return scan_close(src, S, &h, regs, hi, fault, stopped)
}

scan :: proc {scan_one, scan_many}

// Judges what the walk leaves and ends the read.
@(private = "file")
scan_close :: proc(src: []u8, $S: Spec, h: ^engine.Scan, regs: core.Hook_Regs, hi: u64, fault: Maybe(core.Fault), stopped: bool) -> (core.Document, core.Path_Error) {
	hi, fault := hi, fault
	if fault == nil && !stopped {
		fault = tail_fault(src, hi, S)
	}
	// The root is counted whether it was kept or not. A text with no value is no document.
	if fault == nil && !stopped && u32(regs.b) == 0 {
		fault = core.fault_of(core.fault_at(u64(len(src)), .Truncated), &RULES)
	}
	// A spec with comments walks past a comment after the root, so its `hi` is no close.
	when .Comments in FEATURES[S] {
		hi = 0
	}
	return engine.scan_end(h, regs, hi, fault)
}

// Calls `on` with each answer of `path` or `paths` as it becomes known, with no document. `on` returns false to stop
// the read. A
// found container answers at its close. A repeated key can take an answer back under `.Last`, so an answer through a
// `Name` waits for that `Name`'s container to close there, and `.First` gives each as soon as it is read. Answers come in
// the order they are known, and a path with a `Descend` or a negative index that has a limit gives them all at the end.
// `read.refuse_duplicates` reads the whole text first, so a fault there comes before any answer.
@(private)
each_answer_many :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> core.Path_Error {
	if read.refuse_duplicates {
		built, e := build(src, S, opts, true, allocator)
		core.destroy(&built)
		if e.kind != .None {
			return core.path_error(e)
		}
	}
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
		return {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	opts := opts
	h: engine.Scan
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(&h, src, &SPELLING, paths, read, false, allocator, core.reserve_depth(opts.max_depth, len(src)), frames[:], true, state, on); e.kind != .None {
		return e
	}
	h.opts = &opts
	h.rewalk = proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
		src := h.b.doc.src
		walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, engine.scan_hook_stream)
	}
	regs := engine.BUILDER_REGS
	hi, fault, stopped := walk_from(src, q, S, opts, &h, &regs, engine.scan_hook_stream)
	doc, err := scan_close(src, S, &h, regs, hi, fault, stopped)
	core.destroy(&doc)
	return err
}

@(private)
each_answer_one :: proc(src: []u8, $S: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> core.Path_Error {
	return each_answer_many(src, S, []core.Path{path}, state, on, read, opts, allocator)
}

each_answer :: proc {each_answer_one, each_answer_many}

// Reads the first answer of `path`, as `scan` with a limit of one. `answer` is nil when the path gives none, as `.[]` of
// an empty array.
find :: proc(src: []u8, $S: Spec, path: core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = scan_one(src, S, one, read, opts, allocator)
	if len(doc.answers) > 0 {
		answer = doc.answers[0]
	}
	return
}

// Writes `text` as the value at every answer of `path` over `src`, in one call: a build of the text, one edit per answer
// and a commit. A `Name` the path ends in that its container lacks is inserted after the container's last member. The result
// is the new text, which the caller frees with `allocator`. `refuse_duplicates` is
// `build`'s, and `read` picks among a repeated key as `query` does.
set :: proc(src: []u8, $S: Spec, path: core.Path, text: string, read := core.Query_Options{}, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error) {
	doc, berr := build(src, S, opts, refuse_duplicates, allocator)
	defer core.destroy(&doc)
	if berr.kind != .None {
		return nil, {kind = .Edit, edit = berr}
	}
	return engine.set_answers(&doc, path, text, read, allocator)
}
