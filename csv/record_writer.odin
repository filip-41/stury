package csv

import "base:runtime"

// Append one record of text cells to `out`, each cell spelled as `marshal` spells a string: nil is an empty cell
// that reads back absent, and a present text is quoted when it holds the delimiter, a quote, CR or LF.
//
//	- Under `Quoting.Quotes` a present empty text is `""`, so it reads back present. Under `Quoting.None` it is an
//	  empty cell, as a nil one is, and `Escapes.Backslash` escapes each delimiter, CR, LF, NUL and backslash.
//	- A first cell that opens with the comment byte is quoted or escaped, or the record is `.Unwritable`; so is a
//	  cell the dialect cannot spell, and a BOM opening the output.
//	- A record that is empty, or one empty cell, is a blank line, which reads back as no record: `.Unwritable`.
//	- `at_start` is false when `out` is a tail of a text that has been written out already, so a cell opening
//	  with a BOM is not taken for the output's BOM guard when `out` happens to be empty.
//
// A refusal leaves `out` as it was on entry (its capacity may have grown).
@(require_results)
write_record :: proc(out: ^[dynamic]u8, cells: []Maybe(string), dialect := Dialect{}, crlf := false, at_start := true) -> (err: Marshal_Error) {
	w, ok := spell_writer(dialect, nil, context.allocator)
	if !ok {
		return .Bad_Option
	}
	w.buf, w.at_start = out^, at_start
	start := len(w.buf)
	defer {
		if err != .None {
			(^runtime.Raw_Dynamic_Array)(&w.buf).len = start
		}
		out^ = w.buf
	}
	for cell, k in cells {
		if k > 0 {
			put(&w, w.delim) or_return
		}
		if text, present := cell.?; present {
			put_string(&w, text) or_return
		}
	}
	guard_record(&w, start) or_return
	if len(w.buf) == start {
		return .Unwritable
	}
	return put_break(&w, crlf)
}
