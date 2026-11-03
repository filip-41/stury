package dsv

import "base:runtime"
import core "../core"
import engine "../core/build"

// The path reads of `core/build` over dsv's handle. `scan`, `each_answer`, `find` and `set` take `spec` and `opts` and
// forward to the same names in `core/build` with `as(spec, opts)`. `.[i]` is a record, `.[i].name` a cell by its header
// name, and `.[i][j]` a cell by position. A partial document keeps a kept cell's key beside it, so it holds no shared
// keys.

@(private)
scan_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (core.Document, core.Path_Error) {
	return engine.scan_one(src, as(spec, opts), path, read, allocator)
}

@(private)
scan_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (core.Document, core.Path_Error) {
	return engine.scan_many(src, as(spec, opts), paths, read, allocator)
}

scan :: proc {scan_one, scan_many}

@(private)
each_answer_one :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> core.Path_Error {
	return engine.each_answer_one(src, as(spec, opts), path, state, on, read, allocator)
}

@(private)
each_answer_many :: #force_inline proc(src: []u8, spec: Spec, paths: []core.Path, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> core.Path_Error {
	return engine.each_answer_many(src, as(spec, opts), paths, state, on, read, allocator)
}

each_answer :: proc {each_answer_one, each_answer_many}

find :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, read := core.Path_Options{}, opts := Options{}, allocator := context.allocator) -> (doc: core.Document, answer: Maybe(core.Answer), err: core.Path_Error) {
	return engine.find(src, as(spec, opts), path, read, allocator)
}

set :: #force_inline proc(src: []u8, spec: Spec, path: core.Path, text: string, read := core.Query_Options{}, opts := Options{}, refuse_duplicates := false, allocator := context.allocator) -> (out: []u8, err: core.Path_Edit_Error) {
	return engine.set(src, as(spec, opts), path, text, read, refuse_duplicates, allocator)
}

// The spelling's `scan`: the walk compiled for the handle's spec.
@(private)
scan_as :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	switch Spec(handle.spec) {
	case .Csv:   return scan_spec(src, .Csv, handle, paths, read, state, on, allocator)
	case .Tsv:   return scan_spec(src, .Tsv, handle, paths, read, state, on, allocator)
	case .Plain: return scan_spec(src, .Plain, handle, paths, read, state, on, allocator)
	}
	return {}, {kind = .Unsupported}
}

// Walks `src` as spec `S` with the scan's hook, the stream's when `on` is set, and ends the read.
@(private)
scan_spec :: proc(src: []u8, $S: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	opts := options_of(handle)
	h: engine.Scan
	// A record is a container inside the document's array, so a dsv text nests at most two containers.
	frames: [8]u64 = ---
	if e := engine.scan_start(&h, src, handle, paths, read, true, allocator, 8, frames[:], on != nil, state, on); e.kind != .None {
		return {}, e
	}
	regs := engine.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	records: Record_Read
	if on != nil {
		hi, fault = walk_many(src, S, opts, &h, &records, &regs, engine.scan_hook_stream)
	} else if h.many == nil {
		hi, fault = walk(src, 0, S, opts, &h, &regs, engine.scan_hook)
	} else {
		hi, fault = walk_many(src, S, opts, &h, &records, &regs, engine.scan_hook_many)
	}
	return engine.scan_end(&h, regs, hi, fault)
}

// What a re-walk of one record needs: the header's cells, which the record's own walk does not read, and the hook.
@(private = "file")
Record_Read :: struct {
	h:      ^engine.Scan,
	opts:   Options,
	keys:   []core.Token,
	on:     proc "contextless" (h: ^engine.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action),
	opened: bool, // the walk's array for the text has passed
	cell:   int,
}

// Runs the first walk of a `$MANY` read, keeping the header's cells for the records it reads again.
@(private = "file")
walk_many :: proc(src: []u8, $S: Spec, opts: Options, h: ^engine.Scan, read: ^Record_Read, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^engine.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	if _, bad := option_fault(S, opts).?; bad {
		return walk(src, 0, S, opts, h, regs, on)
	}
	read^ = {h = h, opts = opts, on = on}
	if !opts.no_header {
		read.keys = make([]core.Token, header_cells(src, int(core.text_start(src, 0)), S, opts))
	}
	defer delete(read.keys)
	h.opts = read
	h.rewalk = proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
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
		s, action = r.on(r.h, s, column_key(r.keys, r.cell - 1))
		if action != .Next {
			return s, action if action == .Stop else .Next
		}
	}
	return r.on(r.h, s, t)
}
