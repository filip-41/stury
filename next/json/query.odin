package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import engine "../core/build"

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
scan_spec :: proc(src: []u8, $S: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	q, sep := document_start(src, 0, S)
	if sep != nil {
		at := u64(intrinsics.ptr_sub(sep, raw_data(src)))
		return {}, {kind = .Walk, at = at, inner = {at = at, rules = &RULES, kind = .Bad_Char}}
	}
	opts := options_of(handle)
	h: engine.Scan
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(&h, src, handle, paths, read, false, allocator, core.reserve_depth(opts.max_depth, len(src)), frames[:], on != nil, state, on); e.kind != .None {
		return {}, e
	}
	regs := engine.BUILDER_REGS
	hi: u64
	fault: Maybe(core.Fault)
	stopped: bool
	h.opts = &opts
	if on != nil {
		h.rewalk = proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
			src := h.b.doc.src
			walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, engine.scan_hook_stream)
		}
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, engine.scan_hook_stream)
	} else if h.many == nil {
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, engine.scan_hook)
	} else {
		h.rewalk = proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
			src := h.b.doc.src
			walk_from(src, raw_data(src)[lo:], S, (^Options)(h.opts)^, h, s, engine.scan_hook_many)
		}
		hi, fault, stopped = walk_from(src, q, S, opts, &h, &regs, engine.scan_hook_many)
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
	return engine.scan_end(&h, regs, hi, fault)
}
