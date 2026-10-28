package json

import scan_pkg "scan"

// The fault of `rec`, a record of `src` cut under `opts.framing`, as the framing tells it, given `read`: what a
// read of `rec.bytes` alone reported (`validate`, `build`, `scan`), nil when it read the record whole. A fault is
// at an offset into `rec.bytes`. Reads `rec.bytes` again only when `read` is a fault.
//
//	- The framing refuses some records whatever they hold: one led by a byte order mark past the input's first
//	  byte (`.Bad_Char` at 0), and a `.JSON_Seq` record that is a number alone (`.Truncated` with
//	  `Fault.Cut_Number` at its end).
//	- A record that ends inside a literal is `.Truncated` alone, but the byte after it in `src` ended it: a
//	  `.Bad_Char` with `Fault.Literal`, as a read of the whole input reports it, at the same offset.
//	- A `.JSON_Seq` record can hold a complete value and then bytes that belong to no record, as `[1]` then `]`
//	  before the next separator. `end` is then the value's length, and `err` the fault after it. A bare number
//	  or literal is not split: `nullx` and `true,` are one faulty token. `end` is 0 otherwise.
//	- `opts.duplicates` is not read.
//
// For a record of a `Record_Reader`, pass the reader instead of `src`: its window holds the byte after the record.
judge_record :: proc {
	judge_slice_record,
	judge_reader_record,
}

@(private, require_results)
judge_slice_record :: #force_inline proc(src: []byte, rec: Record, read: Maybe(Error), opts := Record_Opts{}) -> (end: int, err: Maybe(Error)) {
	// Most records are read whole and open with neither a byte order mark nor a number: nothing to judge.
	if read == nil && (len(rec.bytes) == 0 || rec.bytes[0] != 0xEF && (opts.framing != .JSON_Seq || rec.bytes[0] != '-' && (rec.bytes[0] < '0' || rec.bytes[0] > '9'))) {
		return
	}
	return judge_framed(src, rec, read, opts)
}

@(private, require_results)
judge_reader_record :: #force_inline proc(rr: ^Record_Reader, rec: Record, read: Maybe(Error), opts := Record_Opts{}) -> (end: int, err: Maybe(Error)) {
	in_window := rec
	in_window.at -= rr.base
	return judge_slice_record(rr.buf[:rr.hi], in_window, read, opts)
}

@(private = "file")
judge_framed :: proc(src: []byte, rec: Record, read: Maybe(Error), opts: Record_Opts) -> (end: int, err: Maybe(Error)) {
	text := rec.bytes
	if rec.at > 0 && scan_pkg.bom_len(text) > 0 {
		return 0, Error{kind = .Bad_Char}
	}
	if opts.framing == .JSON_Seq && len(text) > 0 && scan_pkg.seq_truncated_number(text) {
		return 0, Error{kind = .Truncated, detail = u8(Fault.Cut_Number), offset = u64(len(text))}
	}
	e, bad := read.?
	if !bad {
		return
	}
	at := int(rec.at)
	err = scan_pkg.cut_by_next_byte(src, at, at + len(text), e, opts.dialect, opts.limits)
	if opts.framing == .JSON_Seq {
		end = complete_prefix(text, opts.read)
	}
	return
}

// The length of the complete JSON text `rec` starts with when more bytes follow it, else 0.
@(private = "file")
complete_prefix :: proc(rec: []byte, opts: Read_Opts) -> int {
	e, bad := validate(rec, opts).?
	if !bad || e.offset == 0 || e.offset > u64(len(rec)) {
		return 0
	}
	// The fault's offset is where the text stops: when the bytes before it are a text of their own, the record
	// carries a value and a fault, not one faulty text. A bare number or literal ends only where a delimiter says
	// so; only a text that closes itself, an array, object or string, stands apart.
	end := scan_pkg.skip_space_back(rec, 0, int(e.offset))
	if end == 0 || (rec[end - 1] != ']' && rec[end - 1] != '}' && rec[end - 1] != '"') {
		return 0
	}
	if _, prefix_bad := validate(rec[:int(e.offset)], opts).?; prefix_bad {
		return 0
	}
	return int(e.offset)
}
