package json

import "base:intrinsics"
import core "../core"
import scan "../core/build"

// Reads `path` over `src` as spec `S`, into a partial document holding what the path reached and `Document.answers` in
// text order. Everything the walk passes is still judged, unless `read.stop_early` ends it. `core.destroy` frees the
// document, which borrows `src` and the path. With `read.refuse_duplicates` the document holds the whole text.
query_one :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error) {
	paths := [1]core.Path{path}
	return query_many(src, S, paths[:], opts, read, allocator)
}

// Reads up to 64 `paths` in one read, as `query_one`. An answer's `path` is its path's number, and the answers of all the
// paths are in one text order.
query_many :: proc(src: []u8, $S: Spec, paths: []core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error) {
	if read.refuse_duplicates {
		built, e := build(src, S, opts, true, allocator)
		if e.kind != .None {
			return {}, core.path_error(e)
		}
		return scan.query_built(&built, paths, read)
	}
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
		return {}, {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	opts := opts
	h: scan.Scan
	frames: [MAX_DEPTH]u64 = ---
	if e := scan.scan_start(&h, src, &SPELLING, paths, read, false, allocator, max(MAX_DEPTH, int(opts.max_depth)), frames[:]); e.kind != .None {
		return {}, e
	}
	h.b.doc.read.spec = u8(S)
	h.b.doc.read.max_depth = opts.max_depth
	regs := scan.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	if h.many == nil {
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, scan.scan_hook)
	} else {
		h.opts = &opts
		h.rewalk = proc "contextless" (h: ^scan.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
			src := h.b.doc.src
			walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, scan.many_hook)
		}
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, scan.many_hook)
	}
	return query_end(src, S, &h, regs, hi, fault, stopped)
}

query :: proc {query_one, query_many}

// Judges what the walk leaves and ends the read.
@(private = "file")
query_end :: proc(src: []u8, $S: Spec, h: ^scan.Scan, regs: core.Hook_Regs, hi: u64, fault: Maybe(core.Fault), stopped: bool) -> (core.Document, core.Path_Error) {
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
	return scan.scan_end(h, regs, hi, fault)
}

// Calls `on` with each answer of `paths` as it becomes known, with no document. `on` returns false to stop the read. A
// repeated key can take an answer back under `.Last`, so an answer through a `Name` waits for that `Name`'s container
// to close there, and `.First` gives each as soon as it is read. Answers come in the order they are known, and a path
// with a `Descend` or a negative index that has a limit gives them all at the end.
each_answer :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Path_Error {
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
		return {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	opts := opts
	h: scan.Scan
	frames: [MAX_DEPTH]u64 = ---
	if e := scan.scan_start(&h, src, &SPELLING, paths, read, false, allocator, max(MAX_DEPTH, int(opts.max_depth)), frames[:], true, state, on); e.kind != .None {
		return e
	}
	h.opts = &opts
	h.rewalk = proc "contextless" (h: ^scan.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
		src := h.b.doc.src
		walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, scan.stream_hook)
	}
	regs := scan.BUILDER_REGS
	hi, fault, stopped := walk_from(src, q, S, opts, &h, &regs, scan.stream_hook)
	doc, err := query_end(src, S, &h, regs, hi, fault, stopped)
	core.destroy(&doc)
	return err
}

// Reads the first answer of `path`, as `query` with a limit of one. `answer` is nil when the path gives none, as `.[]` of
// an empty array.
find :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = query_one(src, S, one, opts, read, allocator)
	if len(doc.answers) > 0 {
		answer = doc.answers[0]
	}
	return
}

// Answers one path or several over a built document with the engine `query` runs. `core.Answer`s name `doc`'s nodes.
query_document :: scan.query_document
