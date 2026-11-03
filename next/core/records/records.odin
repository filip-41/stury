// A text that holds a list of records, read one record at a time for every format: `open`, then `next` until it
// returns false, then `it.fault`. A format gives its services through the `as` value, so the calls name no format.
// See `docs/records.md`.
package records

import "base:runtime"
import core ".."

// One record of the input. `text` is its bytes in the input and `at` the offset of its first byte from the input's
// first byte. `key` is the key of an object member under `.Entries`, as written, and nil otherwise.
Record :: struct {
	text: []u8,
	key:  []u8,
	at:   u64,
}

// Reads the records of `src`. `open` makes one, and `close` frees what its reads allocated. `fault` is the fault that
// ended the records, nil when the input ended. `pos` is the byte the next record is looked for from. `state` is the
// format's own framing state.
Reader :: struct {
	src:      []u8,
	pos:      u64,
	as:       core.As,
	services: ^Services,
	fault:    Maybe(core.Fault),
	framing:  core.Framing,
	state:    [2]u8,
}

// A format's record services, in its rodata, which `core.Spelling.records` points at. `next` frames the next record
// and returns false at the input's end or on a fault, which it stores in `it.fault`. `judge` returns the fault of a
// record `next` gave, or nil, as the format's validate of the record's text at its place in the input says.
Services :: struct {
	next:  proc(it: ^Reader) -> (Record, bool),
	judge: proc(it: ^Reader, rec: Record) -> Maybe(core.Fault),
}

// Opens the records of `src` in format `as` under `framing`. A UTF-8 byte order mark at the input's first byte is
// passed over. A format with no record reader, or one that does not take `framing`, ends the records with the fault
// `.Bad_Option` before any is read.
open :: proc(src: []u8, as: core.As, framing := core.Framing.Lines) -> Reader {
	it := Reader{src = src, pos = core.text_start(src, 0), as = as, framing = framing}
	if as.spelling == nil || as.spelling.records == nil {
		it.fault = core.Fault{kind = .Bad_Option}
		return it
	}
	it.services = (^Services)(as.spelling.records)
	return it
}

// Returns the next record, or false at the input's end or on a fault in `it.fault`. Under `.Lines` and `.Seq` in JSON
// it only frames: a record's fault comes from what reads its text.
next :: #force_inline proc(it: ^Reader) -> (Record, bool) {
	if it.fault != nil {
		return {}, false
	}
	return it.services.next(it)
}

// Frees what the reads of `it` allocated.
close :: proc(it: ^Reader) {
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
