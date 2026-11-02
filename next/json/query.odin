package json

import "base:intrinsics"
import core "../core"
import scan "../core/build"

// Reads `path` over `src` as spec `S`, into a partial document holding what the path reached and `Document.answers` in
// text order. Everything the walk passes is still judged, unless `read.stop_early` ends it. `core.destroy` frees the
// document, which borrows `src` and the path. With `read.refuse_duplicates` the document holds the whole text.
query :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error) {
	if read.refuse_duplicates {
		built, e := build(src, S, opts, true, allocator)
		if e.kind != .None {
			return {}, core.path_error(e)
		}
		return scan.query_built(&built, path, read)
	}
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
		return {}, {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	h: scan.Scan
	if e := scan.scan_start(&h, src, &SPELLING, path, read, false, allocator, max(MAX_DEPTH, int(opts.max_depth))); e.kind != .None {
		return {}, e
	}
	h.b.doc.read.spec = u8(S)
	h.b.doc.read.max_depth = opts.max_depth
	regs := scan.BUILDER_REGS
	hi, fault, stopped := walk_from(src, q, S, opts, &h, &regs, scan.scan_hook)
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
	return scan.scan_end(&h, regs, hi, fault)
}

// Reads the first answer of `path`, as `query` with a limit of one. `answer` is nil when the path gives none, as `.[]` of
// an empty array.
find :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error) {
	one := path
	one.limit = min(path.limit.? or_else 1, 1)
	doc, err = query(src, S, one, opts, read, allocator)
	if len(doc.answers) > 0 {
		answer = doc.answers[0]
	}
	return
}

// Answers `path` over a built document with the engine `query` runs. `core.Answer`s name `doc`'s nodes.
query_document :: scan.query_document
