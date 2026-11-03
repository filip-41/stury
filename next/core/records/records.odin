// A text that holds a list of records, read one record at a time for every format: `open`, then `next` until it
// returns false, then `it.fault`. A format gives its services through the `as` value, so the calls name no format.
// See `docs/records.md`.
package records

import "base:runtime"
import core ".."
import typed "../typed"

// One record of the input. `text` is its bytes in the input and `at` the offset of its first byte from the input's
// first byte. `key` is the key of an object member under `.Entries`, as written, and nil otherwise.
Record :: struct {
	text: []u8,
	key:  []u8,
	at:   u64,
}

// Reads the records of `src`. `open` makes one, and `close` frees what its reads allocated. `fault` is the fault that
// ended the records, nil when the input ended. `pos` is the byte the next record is looked for from. `state` is the
// format's own framing state, and `format` the memory a format keeps for it. `frames` are the typed reads' open
// containers, allocated with `allocator` by the first.
Reader :: struct {
	src:       []u8,
	pos:       u64,
	as:        core.As,
	services:  ^Services,
	frames:    []typed.Frame,
	format:    rawptr,
	allocator: runtime.Allocator,
	fault:     Maybe(core.Fault),
	framing:   core.Framing,
	state:     [2]u8,
}

// A format's record services, in its rodata, which `core.Spelling.records` points at. `next` frames the next record
// under each framing the format takes, nil for one it does not, and returns false at the input's end or on a fault,
// which it stores in `it.fault`. `judge` returns the fault of a record `next` gave, or nil, as the format's validate of
// the record's text at its place in the input says. `read` is `next` and a typed read of the record into `target`, a
// `T`. `build` builds a record's document. `column` and `cell` are a format's with named columns, nil for another, and
// `close` frees `it.format`, nil for a format that keeps none.
Services :: struct {
	next:   [core.Framing]proc(it: ^Reader) -> (Record, bool),
	judge:  proc(it: ^Reader, rec: Record) -> Maybe(core.Fault),
	read:   proc(it: ^Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool,
	build:  proc(it: ^Reader, rec: Record, allocator: runtime.Allocator) -> (core.Document, core.Document_Error),
	column: proc(it: ^Reader, name: string) -> int,
	cell:   proc(it: ^Reader, rec: Record, column: int, buf: []u8) -> (string, bool),
	close:  proc(it: ^Reader),
}

// Opens the records of `src` in format `as` under `framing`. The reader's own memory comes from `allocator`. A UTF-8
// byte order mark at the input's first byte is passed over. A format with no record reader, or one that does not take
// `framing`, ends the records with the fault `.Bad_Option` before any is read.
open :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator) -> Reader {
	it := Reader{src = src, pos = core.text_start(src, 0), as = as, framing = framing, allocator = allocator}
	it.services = (^Services)(as.spelling.records) if as.spelling != nil else nil
	if it.services == nil || it.services.next[framing] == nil {
		it.fault = core.Fault{kind = .Bad_Option}
	}
	return it
}

// Returns the next record, or false at the input's end or on a fault in `it.fault`. Under `.Lines` and `.Seq` in JSON
// it only frames: a record's fault comes from what reads its text.
next :: #force_inline proc(it: ^Reader) -> (Record, bool) {
	if it.fault != nil {
		return {}, false
	}
	return it.services.next[it.framing](it)
}

// Reads the next record into `target` by `plan`, as the format's `unmarshal` of the record's text reads it, with every
// offset from the input's first byte. Returns false at the input's end, on a fault in `it.fault`, or with
// `.Out_Of_Memory` when the reader's memory is refused. A refused record returns true and its error, and the next read
// goes on after it. When a refused record's value runs past its end, `target` may hold values read past it.
read :: proc(it: ^Reader, target: ^$T, plan: ^typed.Plan, opts := typed.Read_Options{}, allocator := context.allocator) -> (more: bool, err: core.Typed_Error) {
	if it.fault != nil {
		return false, {}
	}
	if it.frames == nil {
		frames, failed := make([]typed.Frame, max(core.MAX_DEPTH, int(it.as.read.max_depth)) + 2, it.allocator)
		if failed != nil {
			return false, {kind = .Out_Of_Memory}
		}
		it.frames = frames
	}
	more = it.services.read(it, target, T, plan, opts, allocator, &err)
	return
}

// Builds the document of `rec`, a record `next` gave, as the format's `build` of its text does, with every offset in
// an error from the input's first byte.
build :: proc(it: ^Reader, rec: Record, allocator := context.allocator) -> (core.Document, core.Document_Error) {
	return it.services.build(it, rec, allocator)
}

// Returns the index of the first column `name` names, or -1 when none does or the format has no named columns. It may
// read the first records, which `next` then gives.
column :: proc(it: ^Reader, name: string) -> int {
	if it.fault != nil || it.services.column == nil {
		return -1
	}
	return it.services.column(it, name)
}

// Returns the text of cell `column` of `rec`, the record `next` gave last, decoded into `buf` when it must be, and false
// when the record has no such cell, `buf` is too short, or the format has no cells.
cell :: proc(it: ^Reader, rec: Record, column: int, buf: []u8) -> (string, bool) {
	if it.services == nil || it.services.cell == nil {
		return "", false
	}
	return it.services.cell(it, rec, column, buf)
}

// Frees what the reads of `it` allocated.
close :: proc(it: ^Reader) {
	if it.services != nil && it.services.close != nil {
		it.services.close(it)
	}
	delete(it.frames, it.allocator)
	it^ = {}
}

// Returns the fault of each refused record of `src`, in source order, and last the fault that ended the records, if
// any. The slice is allocated with `allocator`. An allocation that fails returns its error and no faults.
check :: proc(src: []u8, as: core.As, framing := core.Framing.Lines, allocator := context.allocator) -> (faults: []core.Fault, err: runtime.Allocator_Error) {
	it := open(src, as, framing)
	defer close(&it)
	out := make([dynamic]core.Fault, allocator)
	for {
		rec, more := next(&it)
		fault := it.services.judge(&it, rec) if more else it.fault
		if f, bad := fault.?; bad {
			if _, e := append(&out, f); e != nil {
				delete(out)
				return nil, e
			}
		}
		if !more {
			return out[:], nil
		}
	}
}
