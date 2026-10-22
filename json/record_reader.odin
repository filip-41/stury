package json

import "core:bytes"
import "core:io"
import "core:mem"

// The bytes `records_from` asks of its reader at a time, unless `chunk` says otherwise.
@(private)
READER_CHUNK :: 64 * 1024

// A pull over the records of an `io.Reader` (`next_record`).
//
//	- `records` over a window of the stream, so the records, their offsets (from the stream's first byte)
//	  and the framing fault are those `records` gives the whole input, whatever the sizes of the reads.
//	- The fields are the iterator's own but `chunk`, `err` and `read_err`.
Record_Reader :: struct {
	reader:   io.Reader,
	allocator: mem.Allocator,
	// The bytes asked of the reader at a read.
	chunk:    int,
	// The window: the bytes not yet framed are `buf[lo:hi]`, `base` is the stream offset of `buf[0]`, and
	// the first `scanned` of them have been searched for a place to cut.
	buf:      []byte,
	lo, hi:   int,
	scanned:  int,
	base:     u64,
	eof:      bool,
	// The framed part of the window.
	it:       Records,
	// The framing fault, `.Bad_Option` for `.Root_Entries`, or `.Out_Of_Memory` at the stream's offset where
	// the window could not grow.
	err:      Maybe(Error),
	// The reader's failure other than `.EOF` (`.No_Progress` for a read of no bytes and no error). The
	// records framed before it are yielded, the bytes after them are not.
	read_err: io.Error,
}

// The records of `r` under `.NDJSON` or `.JSON_Seq`, read `chunk` bytes at a time. `.Root_Entries` needs the
// whole root, so it reads nothing and is `.Bad_Option` on `err`. The window is allocated with `allocator`
// and freed by `destroy`. It holds the longest record and a chunk, grown by doubling, so at most twice that.
records_from :: proc(r: io.Reader, framing: Framing, allocator := context.allocator) -> Record_Reader {
	rr := Record_Reader{reader = r, allocator = allocator, chunk = READER_CHUNK, it = {framing = framing}}
	if framing == .Root_Entries {
		rr.err = Error{kind = .Bad_Option}
	}
	return rr
}

@(private)
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
		rr.hi = copy(rr.buf, rr.buf[rr.lo:rr.hi])
		rr.base += u64(rr.lo)
		rr.lo = 0
	}
	if len(rr.buf) - rr.hi < rr.chunk {
		grown, aerr := mem.alloc_bytes_non_zeroed(max(2 * len(rr.buf), rr.hi + rr.chunk), allocator = rr.allocator)
		if aerr != nil {
			rr.err = Error{kind = .Out_Of_Memory, offset = rr.base + u64(rr.hi)}
			return false
		}
		copy(grown, rr.buf[:rr.hi])
		delete(rr.buf, rr.allocator)
		rr.buf = grown
	}
	n, rerr := io.read(rr.reader, rr.buf[rr.hi:])
	rr.hi += n
	switch {
	case rerr == .EOF:
		rr.eof = true
	case rerr == nil && n == 0:
		rr.read_err = .No_Progress
	case rerr != nil:
		rr.read_err = rerr
	}
	return n > 0 || rr.read_err == nil
}
