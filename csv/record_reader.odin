package csv

import "core:bytes"
import "core:io"
import core_pkg "../core"

// How far past its block's end the scan reads a UTF-8 sequence that opens in the block.
@(private)
READ_AHEAD :: 3

// A pull over the records of an `io.Reader` (`next_record`).
//
//	- `records` over a window of the stream, so the records, their offsets (from the stream's first byte) and
//	  the fault are those `records` gives the whole input, whatever the sizes of the reads.
//	- A record's fields index its `src`, the window, which moves at the next `next_record`.
//	- The fields are the iterator's own but `chunk`, `err` and `read_err`.
Record_Reader :: struct {
	// The window, `buf[:hi]`. The bytes read before a failure of the reader (`read_err`) are read as the
	// input, but for those past their last LF: the record they end is not yielded, and a fault among them is
	// not reported.
	using window: core_pkg.Stream_Window,
	begun:        bool,
	// The records of the window.
	it:           Records,
	// The fault, at its stream offset: `.Bad_Option` for a dialect or limit the scanner refuses, or
	// `.Out_Of_Memory` where the window or a record's fields could not grow.
	err:          Maybe(Error),
}

// The records of `r` as `records` reads them, `chunk` bytes at a time. The window and the fields are
// allocated with `allocator` and freed by `records_destroy`. The window holds the line being read, from its
// first byte, and a chunk, grown by doubling; `limits.max_record_bytes` caps the line, and so the window.
@(require_results)
records_from :: proc(
	r: io.Reader,
	dialect := Dialect{},
	strictness := Strictness.Strict,
	limits := Limits{},
	allocator := context.allocator,
) -> Record_Reader {
	s, ok := scan_setup(dialect, limits, strictness)
	rr := Record_Reader{window = {reader = r, allocator = allocator, chunk = core_pkg.READER_CHUNK}}
	rr.it = records_of(nil, s, allocator)
	if !ok {
		rr.err = Error{kind = .Bad_Option}
	}
	return rr
}

@(private, require_results)
next_reader_record :: proc(rr: ^Record_Reader) -> (rec: Record, ok: bool) {
	if rr.err != nil || !rr.begun && !reader_begin(rr) {
		return
	}
	for {
		if rec, ok = next_slice_record(&rr.it); ok {
			if rr.read_err != nil && rr.it.ended {
				return {}, false
			}
			rec.at += rr.base
			return
		}
		if !rr.it.starved {
			if e, bad := rr.it.err.?; bad && !(rr.read_err != nil && past_last_lf(rr, e)) {
				if e.kind != .Out_Of_Memory {
					e.offset += rr.base
				}
				rr.err = e
			}
			return
		}
		rr.it.starved = false
		if !reader_fill(rr) {
			if rr.err != nil || rr.read_err == nil {
				return
			}
			// The bytes read are the input from here on.
			rr.it.more, rr.it.stop = false, 0
		}
	}
}

// Whether the window's fault `e` lies past its last LF.
@(private = "file")
past_last_lf :: proc(rr: ^Record_Reader, e: Error) -> bool {
	return e.kind != .Out_Of_Memory && bytes.index_byte(rr.buf[min(int(e.offset), rr.hi):rr.hi], '\n') < 0
}

@(private)
reader_destroy :: proc(rr: ^Record_Reader) {
	records_free(&rr.it)
	delete(rr.buf, rr.allocator)
	rr.buf = nil
}

// Read the stream's first bytes, enough to see a BOM, and start the window's records. A reader that fails
// first leaves the bytes it handed over as the input. False when the window could not grow.
@(private)
reader_begin :: proc(rr: ^Record_Reader) -> bool {
	rr.begun = true
	for rr.hi < 3 && !rr.eof && rr.read_err == nil {
		if !reader_fill(rr) && rr.err != nil {
			return false
		}
	}
	it := records_of(rr.buf[:rr.hi], rr.it.scan, rr.allocator)
	it.more, it.stop = !rr.eof && rr.read_err == nil, 0
	rr.it = it
	return true
}

// Drop the bytes before the line being read, which no later block reads, make room for a chunk (doubling the
// window if need be), and read once. False once a read failed, or the stream had ended.
@(private)
reader_fill :: proc(rr: ^Record_Reader) -> bool {
	if rr.eof || rr.read_err != nil {
		return false
	}
	it := &rr.it
	if keep := it.rec_lo; keep > 0 {
		core_pkg.window_drop(rr, keep)
		it.block -= keep
		it.field_lo -= keep
		it.rec_lo -= keep
		for &f in it.fields {
			f.lo -= u64(keep)
			f.hi -= u64(keep)
		}
	}
	progress, oom := core_pkg.window_fill(rr)
	if oom != nil {
		rr.err = oom
		return false
	}
	it.src, it.more, it.stop = rr.buf[:rr.hi], !rr.eof, 0
	return progress
}
