package json

import "core:bytes"
import "core:io"
import core_pkg "../core"

// A pull over the records of an `io.Reader` (`next_record`).
//
//	- `records` over a window of the stream, so the records, their offsets (from the stream's first byte)
//	  and the framing fault are those `records` gives the whole input, whatever the sizes of the reads.
//	- The fields are the iterator's own but `chunk`, `err` and `read_err`.
//	- A `Record`'s `bytes` is a slice of the window, valid until the next `next_record`; its `at` is the offset
//	  in the stream. An offset a read of `bytes` reports is into `bytes`: do not add `at` to render it against
//	  `bytes` (see `Record`).
Record_Reader :: struct {
	// `read_err` is the reader's failure. The records framed before it are yielded; the bytes after them are
	// not.
	using window: core_pkg.Stream_Window,
	// The bytes not yet framed are `buf[lo:hi]`. The first `scanned` of them have been searched for a record
	// boundary.
	lo:       int,
	scanned:  int,
	// The framed part of the window.
	it:       Records,
	// The framing fault, `.Bad_Option` for `.Root_Entries`, or `.Out_Of_Memory` at the stream's offset where
	// the window could not grow.
	err:      Maybe(Error),
}

// The records of `r` under `.NDJSON` or `.JSON_Seq`, read `chunk` bytes at a time. `.Root_Entries` needs the
// whole root, so it reads nothing and is `.Bad_Option` on `err`. The window is allocated with `allocator`
// and freed by `destroy`. It holds the longest record and a chunk, grown by doubling, so at most twice that.
@(require_results)
records_from :: proc(r: io.Reader, framing: Framing, allocator := context.allocator) -> Record_Reader {
	rr := Record_Reader{window = {reader = r, allocator = allocator, chunk = core_pkg.READER_CHUNK}, it = {framing = framing}}
	if framing == .Root_Entries {
		rr.err = Error{kind = .Bad_Option}
	}
	return rr
}

@(private, require_results)
next_reader_record :: proc(rr: ^Record_Reader) -> (rec: Record, ok: bool) {
	for rr.err == nil {
		if rec, ok = next_slice_record(&rr.it); ok {
			return
		}
		if rr.it.err != nil {
			rr.err = rr.it.err
			return
		}
		if !reader_window(rr) {
			break
		}
	}
	return
}

@(private)
reader_destroy :: proc(rr: ^Record_Reader) {
	delete(rr.buf, rr.allocator)
	rr.buf = nil
}

// Frame the next run of whole records as `rr.it`: NDJSON is cut after its last line feed, a JSON text
// sequence where its last run of `0x1E` starts, and at the stream's end everything left is framed. False
// once nothing is left, or a read failed.
@(private)
reader_window :: proc(rr: ^Record_Reader) -> bool {
	for {
		rest := rr.buf[rr.lo:rr.hi]
		cut := len(rest)
		if !rr.eof {
			cut = reader_cut(rr.it.framing, rest, rr.scanned)
			rr.scanned = len(rest)
		}
		if cut > 0 {
			rr.it = records(rest[:cut], rr.it.framing)
			rr.it.base = rr.base + u64(rr.lo)
			rr.lo += cut
			rr.scanned = len(rest) - cut
			return true
		}
		if rr.eof || rr.read_err != nil || !reader_fill(rr) {
			return false
		}
	}
}

// Where `rest` is cut into whole records, or 0 for nowhere. Bytes before `scanned` held no cut when last
// looked at, so only the rest are searched.
@(private)
reader_cut :: proc(framing: Framing, rest: []byte, scanned: int) -> int {
	if framing == .NDJSON {
		k := bytes.last_index_byte(rest[scanned:], '\n')
		return k < 0 ? 0 : scanned + k + 1
	}
	k := bytes.last_index_byte(rest[scanned:], 0x1E)
	if k < 0 {
		return 0
	}
	cut := scanned + k
	for cut > 0 && rest[cut - 1] == 0x1E {
		cut -= 1
	}
	return cut
}

// Drop the framed bytes, make room for a chunk (doubling the window if need be) and read once. A read that
// fails after handing over bytes is still framed: its whole records are yielded before the failure is.
@(private)
reader_fill :: proc(rr: ^Record_Reader) -> bool {
	if rr.lo > 0 {
		core_pkg.window_drop(rr, rr.lo)
		rr.lo = 0
	}
	progress, oom := core_pkg.window_fill(rr)
	if oom != nil {
		rr.err = oom
	}
	return progress
}
