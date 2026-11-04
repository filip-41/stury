package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import engine "../core/build"
import records "../core/records"

// The path reads of `core/build` over JSON's handle. `scan`, `each_answer`, `find` and `set` take `spec` and `opts` and
// forward to the same names in `core/build` with `as(spec, opts)`.

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
	case .Json:  return scan_spec(src, .Json, handle, paths, read, state, on, allocator)
	case .Jsonc: return scan_spec(src, .Jsonc, handle, paths, read, state, on, allocator)
	case .Json5: return scan_spec(src, .Json5, handle, paths, read, state, on, allocator)
	}
	return {}, {kind = .Unsupported}
}

// Walks `src` as spec `S` with the scan's hook, the stream's when `on` is set, judges what the walk leaves and ends the
// read.
@(private)
scan_spec :: proc(src: []u8, $S: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	q, sep := document_start(src, 0, S)
	if sep != nil {
		return {}, sep_error(src, sep)
	}
	opts := options_of(handle)
	// The scan's room as words, which an uninitialized declaration leaves unwritten where a struct's padding would not.
	room: [size_of(engine.Scan) / 8]u64 = ---
	h := (^engine.Scan)(rawptr(&room))
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(h, src, handle, paths, read, false, allocator, core.reserve_depth(opts.max_depth, len(src)), frames[:], on != nil, state, on); e.kind != .None {
		return {}, e
	}
	err = scan_walk(h, src, q, S, opts, on != nil, &doc)
	return
}

@(private)
sep_error :: proc(src: []u8, sep: [^]u8) -> core.Path_Error {
	at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
	return {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
}

// Walks the text at `q` of `src` with the hook of the read `h` started on `src`, the stream's when `stream` is set,
// judges what the walk leaves and ends the read into `doc`.
@(private)
scan_walk :: proc(h: ^engine.Scan, src: []u8, q: [^]u8, $S: Spec, opts: Options, stream: bool, doc: ^core.Document) -> core.Path_Error {
	regs := engine.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	opts := opts
	h.opts = &opts
	defer h.opts = nil
	if stream {
		h.rewalk = rewalk(S, engine.scan_hook_stream)
		hi, fault, stopped = walk_from(src, q, S, opts, h, &regs, engine.scan_hook_stream)
	} else if h.many == nil {
		hi, fault, stopped = walk_from(src, q, S, opts, h, &regs, engine.scan_hook)
	} else {
		h.rewalk = rewalk(S, engine.scan_hook_many)
		hi, fault, stopped = walk_from(src, q, S, opts, h, &regs, engine.scan_hook_many)
	}
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
	return engine.scan_end(h, regs, hi, fault, doc)
}

// The scan's `rewalk` with the hook `on`: a walk from `lo` of the text the scan reads.
@(private)
rewalk :: proc "contextless" ($S: Spec, $on: proc "contextless" (h: ^engine.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, at: core.Node_Index) {
	return proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
		src := h.b.doc.src
		walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, on)
	}
}

// The record service `scan`. A text of concatenated strict JSON is framed by the walk that reads it, and any other
// record is framed first and then read in place.
@(private)
scan_record :: proc(it: ^records.Reader, h: ^engine.Scan, last: ^core.Document, path: core.Path, read: core.Path_Options) -> (records.Record, core.Path_Error, bool) {
	switch Spec(it.as.spec) {
	case .Json:  return scan_record_spec(it, h, last, path, read, .Json)
	case .Jsonc: return scan_record_spec(it, h, last, path, read, .Jsonc)
	case .Json5: return scan_record_spec(it, h, last, path, read, .Json5)
	}
	return {}, {}, false
}

@(private)
scan_record_spec :: proc(it: ^records.Reader, h: ^engine.Scan, last: ^core.Document, path: core.Path, read: core.Path_Options, $S: Spec) -> (rec: records.Record, err: core.Path_Error, ok: bool) {
	opts := options_of(it.as)
	walked := it.framing == .Concatenated && S == .Json
	src := it.src
	q: [^]u8
	pos, state := it.pos, it.state
	if !walked {
		if rec, ok = it.services.next[it.framing](it); !ok {
			return
		}
		src = src[:rec.at + u64(len(rec.text))]
		sep: [^]u8
		if q, sep = document_start(src, rec.at, S); sep != nil {
			return rec, sep_error(src, sep), true
		}
	}
	if it.framing == .Seq && it.state[1] == UNFRAMED {
		f := seq_fault(it, rec, nil).?
		return rec, {kind = .Walk, at = f.at, inner = f}, true
	}
	frames: [core.MAX_DEPTH]u64 = ---
	// The builder keeps `room` past the read, unread until `scan_again` replaces it.
	room := ([^]u64)(rawptr(&frames))[:core.MAX_DEPTH]
	if started := scan_begin(h, it, src, last, path, read, opts, room); started.kind != .None {
		if walked {
			rec, ok = RECORDS.next[it.framing](it)
		}
		return rec, started, ok || !walked
	}
	if !walked {
		err = scan_walk(h, src, q, S, opts, false, last)
		if it.framing == .Seq && err.kind != .Walk {
			// A number the walk passed may have been cut short whatever the path asks of it.
			if f, bad := seq_fault(it, rec, nil).?; bad {
				err = {kind = .Walk, at = f.at, inner = f}
			}
		}
		return rec, err, true
	}
	regs := engine.BUILDER_REGS
	stopped: bool
	h.opts = &opts
	defer h.opts = nil
	if h.many == nil {
		rec, ok, stopped = frame_walked(it, .Json, opts, h, &regs, engine.scan_hook)
	} else {
		h.rewalk = rewalk(.Json, engine.scan_hook_many)
		rec, ok, stopped = frame_walked(it, .Json, opts, h, &regs, engine.scan_hook_many)
	}
	// A stop leaves the record's end to a walk with no hook.
	if stopped {
		it.pos, it.state = pos, state
		rec, ok = RECORDS.next[it.framing](it)
	}
	// The input's end, which ends the records with no fault, ends the read with one and is no error.
	fault := it.fault
	if !ok && fault == nil {
		fault = core.fault_of(core.fault_at(u64(len(src)), .Truncated), &RULES)
	}
	e := engine.scan_end(h, regs, rec.at + u64(len(rec.text)) if ok && !stopped else 0, fault, last)
	if !ok && it.fault == nil {
		return rec, {}, false
	}
	return rec, e, ok
}

// Starts the read `h` of the record text `src`, again on the path it holds when it can.
@(private)
scan_begin :: proc(h: ^engine.Scan, it: ^records.Reader, src: []u8, last: ^core.Document, path: core.Path, read: core.Path_Options, opts: Options, room: []u64) -> core.Path_Error {
	depth := core.reserve_depth(opts.max_depth, len(src))
	if h.again {
		return engine.scan_again(h, src, it.as, it.allocator, room[:depth])
	}
	core.destroy(last)
	started := engine.scan_start(h, src, it.as, []core.Path{path}, read, false, it.allocator, depth, room)
	h.again = started.kind == .None && h.many == nil && int(opts.max_depth) <= core.MAX_DEPTH
	return started
}
