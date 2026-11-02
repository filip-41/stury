package dsv

import core "../core"
import scan "../core/build"

// Reads `path` over `src` as spec `S`, into a partial document holding what the path reached and `Document.answers` in
// text order. `.[i]` is a record, `.[i].name` a cell by its header name, and `.[i][j]` a cell by position. The partial
// document keeps a kept cell's key beside it, so it holds no shared keys. Everything the walk passes is still judged,
// unless `read.stop_early` ends it. `core.destroy` frees the document, which borrows `src` and the path. With
// `read.refuse_duplicates` the document holds the whole text.
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
	h: scan.Scan
	// A record is a container inside the document's array, so a dsv text nests at most two containers.
	frames: [8]u64 = ---
	if e := scan.scan_start(&h, src, &SPELLING, paths, read, true, allocator, 8, frames[:]); e.kind != .None {
		return {}, e
	}
	h.b.doc.read.spec = u8(S)
	h.b.doc.read.opts = {delimiter_of(S, opts), opts.comment, 1 if opts.no_header else 0}
	regs := scan.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	if h.many == nil {
		hi, fault = walk(src, 0, S, opts, &h, &regs, scan.scan_hook)
	} else {
		records: Record_Read
		hi, fault = walk_many(src, S, opts, &h, &records, &regs, scan.many_hook)
	}
	return scan.scan_end(&h, regs, hi, fault)
}

query :: proc {query_one, query_many}

// Calls `on` with each answer of `paths` as it becomes known, with no document, as `json.each_answer`.
each_answer :: proc(src: []u8, $S: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, opts := Options{}, read := core.Path_Options{}, allocator := context.allocator) -> core.Path_Error {
	if read.refuse_duplicates {
		built, e := build(src, S, opts, true, allocator)
		core.destroy(&built)
		if e.kind != .None {
			return core.path_error(e)
		}
	}
	h: scan.Scan
	frames: [8]u64 = ---
	if e := scan.scan_start(&h, src, &SPELLING, paths, read, true, allocator, 8, frames[:], true, state, on); e.kind != .None {
		return e
	}
	regs := scan.BUILDER_REGS
	records: Record_Read
	hi, fault := walk_many(src, S, opts, &h, &records, &regs, scan.stream_hook)
	doc, err := scan.scan_end(&h, regs, hi, fault)
	core.destroy(&doc)
	return err
}

// What a re-walk of one record needs: the header's cells, which the record's own walk does not read, and the hook.
@(private = "file")
Record_Read :: struct {
	h:      ^scan.Scan,
	opts:   Options,
	keys:   []core.Token,
	on:     proc "contextless" (h: ^scan.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action),
	opened: bool, // the walk's array for the text has passed
	cell:   int,
}

// Runs the first walk of a `$MANY` read, keeping the header's cells for the records it reads again.
@(private = "file")
walk_many :: proc(src: []u8, $S: Spec, opts: Options, h: ^scan.Scan, read: ^Record_Read, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^scan.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	if _, bad := option_fault(S, opts).?; bad {
		return walk(src, 0, S, opts, h, regs, on)
	}
	read^ = {h = h, opts = opts, on = on}
	if !opts.no_header {
		read.keys = make([]core.Token, header_cells(src, int(core.text_start(src, 0)), S, opts))
	}
	defer delete(read.keys)
	h.opts = read
	h.rewalk = proc "contextless" (h: ^scan.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
		one := (^Record_Read)(h.opts)^
		one.opts.no_header = true
		walk(h.b.doc.src, lo, S, one.opts, &one, s, record_hook)
	}
	return walk_keys(src, 0, S, opts, h, regs, on, read.keys)
}

// Gives the hook one record as the text's own walk gave it: a walk from a record's first byte reads it as a headerless
// text, so the text's array goes, the record is a `Map` again when the text has a header, each cell gets its key back,
// and the walk stops at the record's `End`.
@(private = "file")
record_hook :: proc "contextless" (r: ^Record_Read, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	s, t := s, t
	action: core.Action
	if t.role > .Key {
		return s, .Next
	}
	if !r.opened {
		r.opened = true
		return s, .Next
	}
	if t.kind == .End {
		s, action = r.on(r.h, s, t)
		return s, .Stop
	}
	if t.kind == .Array {
		if len(r.keys) > 0 {
			t.kind = .Map
		}
		s, action = r.on(r.h, s, t)
		return s, .Stop if action != .Next else .Next
	}
	r.cell += 1
	if len(r.keys) > 0 {
		s, action = r.on(r.h, s, r.keys[r.cell - 1])
		if action != .Next {
			return s, action if action == .Stop else .Next
		}
	}
	return r.on(r.h, s, t)
}

// Reads the first answer of `path`, as `query` with a limit of one. `answer` is nil when the path gives none.
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

// Writes `text` as the value at every answer of `path` over `src`, in one call: a read of the path, one edit per answer and
// a commit. A `Name` the path ends in that its container lacks is inserted after the container's last member. The result
// is the new text, which the caller frees with `allocator`.
set :: proc(src: []u8, $S: Spec, path: string, text: string, opts := Options{}, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error) {
	parsed, perr := core.parse_path(path, allocator)
	if perr.kind != .None {
		return nil, perr
	}
	defer core.path_destroy(&parsed)
	doc, qerr := query_one(src, S, parsed, opts, allocator = allocator)
	defer core.destroy(&doc)
	if qerr.kind != .None {
		return nil, qerr
	}
	return scan.set_answers(&doc, parsed, text, allocator)
}

@(private)
edit_whole :: proc(doc: ^core.Document, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	delimiter, comment, no_header := read_opts(doc)
	opts := Options{no_header = no_header, delimiter = delimiter, comment = comment, tolerate = {.Invalid_Utf8, .Ragged, .Bare_Quote}}
	switch Spec(doc.read.spec) {
	case .Csv:   return build(doc.src, .Csv, opts, false, allocator)
	case .Tsv:   return build(doc.src, .Tsv, opts, false, allocator)
	case .Plain: return build(doc.src, .Plain, opts, false, allocator)
	}
	return {}, {kind = .Bad_Index}
}
