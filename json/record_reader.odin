package json

import "core:bytes"
import "core:io"
import core_pkg "../core"
import scan_pkg "scan"

// A pull over the records of an `io.Reader` (`next_record`).
//
//	- It runs `records` over a window of the stream. The records, their offsets (from the stream's first byte)
//	  and the fault are the ones `records` gives for the whole input under the same options, whatever the read
//	  sizes.
//	- A record's bytes are the window's, which moves at the next `next_record`. `judge_record` of the reader
//	  judges a record as `judge_record` of the whole input does.
//	- Under `.NDJSON`, `.JSON_Seq` and `.Concatenated` the window holds the record being read and the whitespace
//	  before it, plus one chunk, and `max_record_bytes` bounds it. Under `.None` and `.Root_Entries` it holds the
//	  whole input, read before the first record is yielded.
//	- Every field is internal except `chunk`, `err` and `read_err`; `record_window` says where it stands.
//	- Made by `records_pushed`, it reads no stream: the caller hands it each window (`record_push`), and the
//	  records and faults are the same.
Record_Reader :: struct {
	// The window, `buf[:hi]`. The bytes read before a reader failure (`read_err`) are input as far as they frame
	// whole records: under `.NDJSON` up to the last line feed, under `.JSON_Seq` up to the last separator, under
	// `.Concatenated` up to the last text that ends before them, and none under `.None` and `.Root_Entries`. A
	// record past that is not yielded and a fault in it is not reported.
	using window: core_pkg.Stream_Window,
	begun:        bool,
	// The windows are the caller's (`record_push`): `buf` is neither read into nor freed.
	pushed:       bool,
	// The records of the window's framed bytes, `it.src`.
	it:           Records,
	// The fault, at its stream offset: what `records` reports, `.Out_Of_Memory` where the window could not
	// grow, or `.Bad_Option` for a negative cap.
	err:          Maybe(Error),
}

// The records of `r` as `records` reads them under `opts.framing` and `opts.max_record_bytes`, `chunk` bytes at a
// time; no other field is read. The window is allocated with `allocator`, grows by doubling, and is freed by
// `destroy`.
@(require_results)
records_from :: proc(r: io.Reader, opts := Record_Opts{}, allocator := context.allocator) -> Record_Reader {
	rr := Record_Reader{window = {reader = r, allocator = allocator, chunk = core_pkg.READER_CHUNK}}
	rr.it = records(nil, opts)
	rr.err = rr.it.err
	return rr
}

// A `Record_Reader` the caller hands windows to rather than one reading an `io.Reader`, under `opts.framing` and
// `opts.max_record_bytes`. `next_record` is false when the records end or when they want the next window, which
// `record_carry` tells apart.
@(require_results)
records_pushed :: proc(opts := Record_Opts{}) -> Record_Reader {
	rr := Record_Reader{pushed = true}
	rr.it = records(nil, opts)
	rr.err = rr.it.err
	return rr
}

// Hands `rr` its next window: the bytes `record_carry` gave last (none at first), then the stream's next bytes;
// `ended` when the stream ends with them. The window is the caller's, unchanged until the next `record_carry`.
record_push :: proc(rr: ^Record_Reader, window: []byte, ended: bool) {
	rr.buf, rr.hi, rr.eof = window, len(window), ended
	reader_frame(rr)
}

// The bytes of the window the next window must start with: those the records yielded so far have not passed.
// `more` is false when no window is wanted: the stream has ended, or the records ended on a fault in `err`.
@(require_results)
record_carry :: proc(rr: ^Record_Reader) -> (carry: []byte, more: bool) {
	if rr.err != nil || rr.eof {
		return nil, false
	}
	keep := 0
	if rr.begun {
		keep = reader_keep(rr) or_return
	}
	rr.base += u64(keep)
	return rr.buf[keep:rr.hi], true
}

// The window the records of `rr` are slices of, and the stream offset of its first byte.
record_window :: core_pkg.record_window

@(private, require_results)
next_reader_record :: proc(rr: ^Record_Reader) -> (rec: Record, ok: bool) {
	return reader_next(rr, false)
}

@(private, require_results)
next_open_reader_record :: proc(rr: ^Record_Reader) -> (rec: Record, ok: bool) {
	return reader_next(rr, true)
}

@(private = "file", require_results)
reader_next :: #force_inline proc(rr: ^Record_Reader, $OPEN: bool) -> (rec: Record, ok: bool) {
	if rr.err != nil || !rr.begun && !reader_begin(rr) {
		return
	}
	if !rr.eof && reads_whole(rr) {
		// The stream failed before its end: no record of it is framed.
		return
	}
	for {
		when OPEN {
			rec, ok = next_open_slice_record(&rr.it)
		} else {
			rec, ok = next_slice_record(&rr.it)
		}
		if ok {
			rec.at += rr.base
			return
		}
		if !reader_failed(rr) && !rr.pushed && reader_fill(rr) {
			continue
		}
		return
	}
}

// Whether the records ended on a fault, which is then `err`, at its stream offset.
@(private = "file")
reader_failed :: proc(rr: ^Record_Reader) -> bool {
	e, bad := rr.it.err.?
	if bad {
		e.offset += rr.base
		rr.err = e
	}
	return bad
}

@(private)
end_reader_record :: proc(rr: ^Record_Reader, read: Maybe(Error)) -> (rec: Record, cut: bool) {
	rec, cut = end_slice_record(&rr.it, read)
	if rec.bytes != nil {
		rec.at += rr.base
	}
	reader_failed(rr)
	return
}

@(private)
skip_reader_records :: proc(rr: ^Record_Reader, to: u64) {
	if to < rr.base {
		return
	}
	skip_slice_records(&rr.it, min(to - rr.base, u64(rr.hi)))
	if rr.it.err == nil {
		rr.err = nil
	}
	// Past the stream's first byte no byte order mark is looked for.
	rr.begun ||= to > 0
}

@(private)
reader_destroy :: proc(rr: ^Record_Reader) {
	if !rr.pushed {
		delete(rr.buf, rr.allocator)
	}
	rr^ = {}
}

// Whether the framing needs the whole input before its first record: a text's end, or its root's close.
@(private = "file")
reads_whole :: #force_inline proc(rr: ^Record_Reader) -> bool {
	return rr.it.framing == .None || rr.it.framing == .Root_Entries
}

// Reads the stream's first bytes, enough to tell whether it opens with a byte order mark, or all of it when the
// framing reads it whole; a pushed reader begins once its window holds them. False on a fault in `err`, or while a pushed reader
// waits for them.
@(private = "file")
reader_begin :: proc(rr: ^Record_Reader) -> bool {
	whole := reads_whole(rr)
	if rr.pushed {
		rr.begun = rr.eof || !whole && !bom_undecided(rr)
		return rr.begun
	}
	rr.begun = true
	for (whole || bom_undecided(rr)) && reader_fill(rr) {}
	return rr.err == nil
}

// Whether the window's bytes, too few to hold a byte order mark whole, may yet open with one.
@(private = "file")
bom_undecided :: proc(rr: ^Record_Reader) -> bool {
	return rr.hi < len(BOM) && bytes.has_prefix(BOM[:], rr.buf[:rr.hi])
}

@(private = "file", rodata)
BOM := [3]byte{0xEF, 0xBB, 0xBF}

// Refuses the record being read once it is past the cap, drops the bytes before it, reads once, and frames
// what the window holds. False once the stream has ended or failed, or on a fault in `err`.
@(private = "file")
reader_fill :: proc(rr: ^Record_Reader) -> bool {
	if rr.eof || rr.read_err != nil {
		return false
	}
	keep, ok := reader_keep(rr)
	if !ok {
		return false
	}
	core_pkg.window_drop(rr, keep)
	progress, oom := core_pkg.window_fill(rr)
	if oom != nil {
		rr.err = oom
		return false
	}
	reader_frame(rr)
	return progress
}

// Refuses the record being read once it is past the cap. Else how many of the window's first bytes, read past,
// may go, which the iterator then no longer counts. False on a fault in `err`.
@(private = "file")
reader_keep :: proc(rr: ^Record_Reader) -> (keep: int, ok: bool) {
	it := &rr.it
	if at, over := open_past_cap(rr); over {
		rr.err = Error{kind = .Limit_Format, detail = u8(Fault.Record_Too_Long), offset = rr.base + u64(at)}
		return 0, false
	}
	keep = it.pos
	if keep == 0 || reads_whole(rr) {
		return 0, true
	}
	it.pos -= keep
	if it.opened {
		it.commas.at -= keep // the `.Concatenated` text being read: where its end is looked for next
	}
	return keep, true
}

// The window's records: its framed bytes, and whether the stream goes on past them.
@(private = "file")
reader_frame :: proc(rr: ^Record_Reader) {
	rr.it.src = rr.buf[:reader_framed(rr)]
	rr.it.more, rr.it.starved, rr.it.resumed = !rr.eof, false, rr.base > 0
}

// How much of the window `records` may frame: all of it once the stream has ended, else under `.NDJSON` its
// whole lines and under `.JSON_Seq` up to its last run of separators, where the record before it ends. A
// `.JSON_Seq` stream led by a byte other than whitespace or a separator is framed at once, as it is refused
// there whatever follows. Under `.Concatenated` all of it: a text it ends before the text's end starves the
// iterator.
@(private = "file")
reader_framed :: proc(rr: ^Record_Reader) -> int {
	if rr.eof {
		return rr.hi
	}
	w := rr.buf[:rr.hi]
	#partial switch rr.it.framing {
	case .Concatenated:
		return len(w)
	case .NDJSON:
		return bytes.last_index_byte(w, '\n') + 1
	case .JSON_Seq:
		if p := scan_pkg.skip_space(w, open_start(rr)); p < len(w) && w[p] != 0x1E {
			return len(w)
		}
		r := bytes.last_index_byte(w, 0x1E)
		for r > 0 && w[r - 1] == 0x1E {
			r -= 1
		}
		return max(r, 0)
	}
	return 0
}

// Where the bytes not yet framed into a record start: past the last record, and past a byte order mark at the
// stream's start.
@(private = "file")
open_start :: proc(rr: ^Record_Reader) -> int {
	if rr.base == 0 && rr.it.pos == 0 {
		return scan_pkg.bom_len(rr.buf[:rr.hi])
	}
	return rr.it.pos
}

// Where the record being read starts in the window, and whether the bytes read of it are already past the cap,
// once `records` has framed every record before it. Under `.Root_Entries` the cap is each entry's, judged once
// the input is whole.
@(private = "file")
open_past_cap :: proc(rr: ^Record_Reader) -> (at: int, over: bool) {
	it := &rr.it
	w := rr.buf[:rr.hi]
	switch it.framing {
	case .NDJSON:
		at = open_start(rr)
	case .Concatenated:
		at = scan_pkg.skip_space(w, open_start(rr))
	case .JSON_Seq:
		at = open_start(rr)
		for at < len(w) && (w[at] == 0x1E || scan_pkg.is_space(w[at])) {
			at += 1
		}
	case .None:
		at = scan_pkg.skip_space(w, scan_pkg.bom_len(w))
	case .Root_Entries:
		return 0, false
	}
	return at, at < len(w) && len(w) - at > it.cap
}
