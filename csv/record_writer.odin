package csv

import "base:runtime"
import core_pkg "../core"

// Appends one record of text cells to `out`, in `opts.dialect`, ended by CRLF under `opts.crlf` and else LF;
// `opts.no_header` is not read. Each cell is spelled as `marshal` spells a string: nil is an empty cell that
// reads back absent, and a present text is quoted when it holds the delimiter, a quote, CR or LF.
//
//	- Under `Quoting.Quotes` a present empty text is written `""` and reads back present. Without quotes
//	  it is an empty cell like a nil one, and `Quoting.Backslash` escapes each delimiter, CR, LF, NUL and
//	  backslash.
//	- A first cell starting with the comment byte is quoted or escaped. When the dialect can do neither, the
//	  record is `.Unwritable`. The same holds for a cell the dialect cannot spell and for a BOM at the start of
//	  the output.
//	- A record with no cells, or one empty cell, would be a blank line, which reads back as no record:
//	  `.Unwritable`.
//	- `at_start` is false when `out` continues a text already written elsewhere. The BOM guard then does not
//	  apply, even when `out` is empty.
//
// A refusal leaves `out` as it was on entry; its capacity may have grown.
@(require_results)
write_record :: proc(out: ^[dynamic]u8, cells: []Maybe(string), opts := Marshal_Opts{}, at_start := true) -> Maybe(Marshal_Error) {
	fault: Marshal_Error
	return core_pkg.marshal_error_of(put_record(out, cells, opts, at_start, &fault), fault)
}

@(private = "file")
put_record :: proc(out: ^[dynamic]u8, cells: []Maybe(string), opts: Marshal_Opts, at_start: bool, fault: ^Marshal_Error) -> (err: Marshal_Error_Kind) {
	w, ok := spell_writer(opts.dialect, nil, out^)
	if !ok {
		return .Bad_Option
	}
	w.at_start, w.fault = at_start, fault
	start := len(w.buf)
	defer {
		if err != .None {
			(^runtime.Raw_Dynamic_Array)(&w.buf).len = start
		}
		out^ = w.buf
	}
	put_strings(&w, cells) or_return
	if len(w.buf) == start {
		return .Unwritable
	}
	return put_break(&w, opts.crlf)
}
