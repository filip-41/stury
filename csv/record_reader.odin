package csv

import "core:bytes"
import "core:io"
import core_pkg "../core"

// How far past its block's end the scan reads a UTF-8 sequence that starts in the block.
@(private)
READ_AHEAD :: 3

// A pull over the records of an `io.Reader` (`next_record`).
//
//	- It runs `records` over a window of the stream. The records, their offsets (from the stream's first byte)
//	  and the fault are the ones `records` gives for the whole input, whatever the read sizes.
//	- A record's fields index its `src`, the window, which moves at the next `next_record`.
//	- Every field is internal except `chunk`, `err` and `read_err`.
Record_Reader :: struct {
	// The window, `buf[:hi]`. The bytes read before a reader failure (`read_err`) are input, except those past
	// the last LF: their record is not yielded and a fault in them is not reported.
	using window: core_pkg.Stream_Window,
	begun:        bool,
	// The records of the window.
	it:           Records,
	// The fault, at its stream offset: `.Bad_Option` for a dialect or limit the scanner refuses, or
	// `.Out_Of_Memory` where the window or a record's fields could not grow.
	err:          Maybe(Error),
}

// The records of `r` as `records` reads them, `chunk` bytes at a time. The window and the fields are
// allocated with `allocator` and freed by `destroy`. The window holds the line being read, from its
// first byte, plus one chunk, and grows by doubling. `opts.limits.max_record_bytes` caps the line and so the window.
@(require_results)
records_from :: proc(r: io.Reader, opts := Read_Opts{}, allocator := context.allocator) -> Record_Reader {
	s, ok := scan_setup(opts.dialect, opts.limits, opts.strictness)
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

// Reads the stream's first bytes, enough to see a BOM, and starts the window's records. If the reader fails
// first, the bytes it returned are the input. False when the window could not grow.
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

// Drops the bytes before the line being read, which no later block reads, makes room for a chunk (doubling
// the window if needed), and reads once. False once a read has failed or the stream has ended.
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
		// A deferred UTF-8 fault is a window position too; -1 and max(int) are not.
		if it.carry.utf8 >= 0 && it.carry.utf8 != max(int) {
			it.carry.utf8 = max(it.carry.utf8 - keep, 0)
		}
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
