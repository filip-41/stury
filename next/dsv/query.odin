package dsv

import core "../core"
import scan "../core/build"

// Reads `path` over `src` as spec `S`, into a partial document holding what the path reached and `Document.answers` in
// text order. `.[i]` is a record, `.[i].name` a cell by its header name, and `.[i][j]` a cell by position. The partial
// document keeps a kept cell's key beside it, so it holds no shared keys. Everything the walk passes is still judged,
// unless `read.stop_early` ends it. `core.destroy` frees the document, which borrows `src` and the path. With
// `read.refuse_duplicates` the document holds the whole text.
query :: proc(src: []u8, $S: Spec, path: core.Path, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> (doc: core.Document, err: core.Path_Error) {
	if read.refuse_duplicates {
		built, e := build(src, S, opts, true, allocator)
		if e.kind != .None {
			return {}, core.path_error(e)
		}
		return scan.query_built(&built, path, read)
	}
	h: scan.Scan
	// A record is a container inside the document's array, so a dsv text nests at most two containers.
	frames: [8]u64 = ---
	if e := scan.scan_start(&h, src, &SPELLING, path, read, true, allocator, 8, frames[:]); e.kind != .None {
		return {}, e
	}
	h.b.doc.read.spec = u8(S)
	h.b.doc.read.opts = {delimiter_of(S, opts), opts.comment, 1 if opts.no_header else 0}
	regs := scan.BUILDER_REGS
	hi, fault := walk(src, 0, S, opts, &h, &regs, scan.scan_hook)
	return scan.scan_end(&h, regs, hi, fault)
}

// Reads the first answer of `path`, as `query` with a limit of one. `answer` is nil when the path gives none.
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
