package tape

import "base:runtime"

// A text that holds a list of records, which a format's records read hands on one at a time, each as it closes.

// How a text holds its records.
Framing :: enum u8 {
	// One value per line (NDJSON). A line of white space alone holds no record. A record whose line holds more than one
	// value, or a value that runs on past its line, is refused, and the records go on at the next line.
	Lines,
	// The elements of the root array. A fault ends the records, as the text holds no list past it.
	Elements,
	// The members of the root object. Each member's value is a record, with its key in `Record.key`. Every member is a
	// record, repeated keys too. A fault ends the records, as under `.Elements`, and a root that is no object holds none.
	Members,
	// Values one after another with nothing between them, as a CBOR sequence (RFC 8742). A fault ends the records, as
	// the text holds no place where the next value starts.
	Concatenated,
}

// One record: the records before it, its bytes in the text, and why it does not read, nil when it does. Its bytes run
// from its first byte that is no white space to its line's end less a CR under `.Lines`, and to its value's end under
// the other framings. Every offset, those of `err` included, counts from the text's first byte. Under
// `.Members` `key` is the member's key, a token of role `.Key` that `key_raw` reads, and under the other framings it is
// the zero token, whose role is `.Value`.
Record :: struct {
	index:  u64,
	lo, hi: u64,
	err:    Error,
	key:    Token,
}

// Where the records of a text are, in their framing.
Records_At :: enum u8 {
	Start, // before the first record, or before the container holding them
	Open, // in the container holding them, before the first
	After, // in the container holding them, after a record
	Done,
}

// The state of a read of the records of a text that every format keeps: what is read, and how far. A format's records
// hold it as their first field, with what their walk learns from record to record after it. Each batch reads the next
// records into slices the caller gives, as many as they hold. Once a batch fills fewer than it was given room for the
// records have ended, and `err` says why, nil at the text's end.
//
// Under `.Lines`, the records of a text in pieces are read a window at a time: `Options.pieces` is the read's, the
// window the records open with is the text's first, and `records_window` gives each next window. A batch reads the
// records whose lines the window holds whole and fills fewer than it was given room for once the window holds no more,
// or once the records have ended. It then sets the pieces' `more`, `at` and `keep`, as a read of a window does: a
// record the window's end cut is kept from its first byte, and its framing goes on in the next window where this one
// stopped. Each record's offsets are the whole
// text's, a scan's documents hold the bytes they read (`.Held`), and a find's answers are spans of the window it was
// read in.
Records :: struct {
	src:     []u8,
	opts:    Options,
	framing: Framing,
	at:      Records_At,
	err:     Error,
	pos:     u64, // where the next record is looked for
	index:   u64, // the records read
	key:     Token, // the key of the member being read under `.Members`
	// Set by `Reads.records` for records it made: their reads, the proc that frees them and what they are in.
	reads:     ^Records_Reads,
	release:   proc(r: ^Records),
	allocator: runtime.Allocator,
}

// The batch reads of the records of one spec of a format, as its own records reads read them.
Records_Reads :: struct {
	validate: proc(r: ^Records, out: []Record, allocator: runtime.Allocator) -> int,
	find:     proc(r: ^Records, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int,
	scan:     proc(r: ^Records, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int,
}

// Reads the next records of `r`, which `Reads.records` made, into `out`, judging each as `Reads.validate` judges its
// bytes alone. Returns how many it filled.
records_validate :: proc(r: ^Records, out: []Record, allocator := context.allocator) -> int {
	return r.reads.validate(r, out, allocator)
}

// Reads the next records of `r`, which `Reads.records` made, into `out`, and for each the first value `path` reaches
// in it into the same place of `answers`. Returns how many it filled.
records_find :: proc(r: ^Records, path: []Step, out: []Record, answers: []Span_Answer, read := Read_Options{}, allocator := context.allocator) -> int {
	return r.reads.find(r, path, out, answers, read, allocator)
}

// Reads the next records of `r`, which `Reads.records` made, into `out`, and for each the document of its nodes the
// paths of `demand` reach into the same place of `docs`. Returns how many it filled.
records_scan :: proc(r: ^Records, demand: ^Demand, out: []Record, docs: []Document, read := Read_Options{}, allocator := context.allocator) -> int {
	return r.reads.scan(r, demand, out, docs, read, allocator)
}

// Gives the records `r` of a text in pieces the window `src`, which starts at the pieces' `from`, at or before their
// `keep`, and ends at or after their `at`, else the window is refused with `Piece_Gap`.
records_window :: proc "contextless" (r: ^Records, src: []u8) -> Error {
	p := r.opts.pieces
	piece_window(p, src) or_return
	r.src = piece_src(src, p.from)
	return nil
}

// Frees the records `Reads.records` made.
destroy_records :: proc(r: ^Records) {
	if r != nil && r.release != nil {
		r.release(r)
	}
}
