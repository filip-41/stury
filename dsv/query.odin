#+private
package dsv

import "base:runtime"
import core "../core"
import engine "../core/build"

// dsv's `Services.scan` walk, which `core/build`'s path reads run. `.[i]` is a record, `.[i].name` a cell by its header
// name, and `.[i][j]` a cell by position. A partial document keeps a kept cell's key beside it, so it holds no shared
// keys.

// The spelling's `scan`: the walk compiled for the handle's spec.
scan_as :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (core.Document, core.Path_Error) {
	switch Spec(handle.spec) {
	case .Csv:   return scan_spec(src, .Csv, handle, paths, read, state, on, allocator)
	case .Tsv:   return scan_spec(src, .Tsv, handle, paths, read, state, on, allocator)
	case .Plain: return scan_spec(src, .Plain, handle, paths, read, state, on, allocator)
	}
	return {}, {kind = .Unsupported}
}

// Walks `src` as spec `S` with the scan's hook, the stream's when `on` is set, and ends the read.
scan_spec :: proc(src: []u8, $S: Spec, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	opts := options_of(handle)
	// The header's cells come from `allocator`, so the walk takes none from the default heap. An option the spec
	// cannot read leaves them nil and the walk refuses it.
	keys: []core.Token
	if _, bad := option_fault(S, opts).?; !bad && !opts.no_header {
		failed: runtime.Allocator_Error
		if keys, failed = make([]core.Token, header_cells(src, int(core.text_start(src, 0)), S, opts), allocator); failed != nil {
			return {}, {kind = .No_Memory}
		}
	}
	defer delete(keys, allocator)
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
		hi, fault = walk_many(src, S, opts, &h, &records, &regs, engine.scan_hook_stream, keys)
	} else if h.many == nil {
		hi, fault = walk_keys(src, 0, S, opts, &h, &regs, engine.scan_hook, keys)
	} else {
		hi, fault = walk_many(src, S, opts, &h, &records, &regs, engine.scan_hook_many, keys)
	}
	err = engine.scan_end((^engine.Scan)(rawptr(&h)), regs, hi, fault, &doc)
	return
}

// What a re-walk of one record needs: the header's cells, which the record's own walk does not read, and the hook.
Record_Read :: struct {
	h:      ^engine.Scan,
	opts:   Options,
	keys:   []core.Token,
	on:     proc "contextless" (h: ^engine.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action),
	opened: bool, // the walk's array for the text has passed
	cell:   int,
}

// Runs the first walk of a `$MANY` read, keeping the header's cells, `keys`, for the records it reads again.
walk_many :: proc(src: []u8, $S: Spec, opts: Options, h: ^engine.Scan, read: ^Record_Read, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^engine.Scan, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), keys: []core.Token) -> (hi: u64, fault: Maybe(core.Fault)) {
	if _, bad := option_fault(S, opts).?; bad {
		return walk(src, 0, S, opts, h, regs, on)
	}
	read^ = {h = h, opts = opts, keys = keys, on = on}
	h.opts = read
	h.rewalk = proc "contextless" (h: ^engine.Scan, s: ^core.Hook_Regs, lo: u64, _: core.Node_Index) {
		one := (^Record_Read)(h.opts)^
		one.opts.no_header = true
		walk(h.b.doc.src, lo, S, one.opts, &one, s, record_hook)
	}
	return walk_keys(src, 0, S, opts, h, regs, on, read.keys)
}

// Gives the hook one record as the text's own walk gave it: a walk from a record's first byte reads it as a headerless
// text, so the text's array goes, the record is an `Object` again when the text has a header, each cell gets its key back,
// and the walk stops at the record's `End`.
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
			t.kind = .Object
		}
		s, action = r.on(r.h, s, t)
		return s, .Stop if action == .Skip || action == .Stop else .Next
	}
	r.cell += 1
	if len(r.keys) > 0 {
		s, action = r.on(r.h, s, column_key(r.keys, r.cell - 1))
		if action == .Skip || action == .Stop {
			return s, action if action == .Stop else .Next
		}
	}
	return r.on(r.h, s, t)
}
