package core

import "core:io"

// One enum for every format, so that code over several reads one `Error`, `Unmarshal_Error` and `Path_Error`: a
// kind marked CSV is CSV's only, the others are JSON's or shared, and each format's docs list the kinds it never
// reports.
//
// A syntax fault reports the first byte that cannot extend the construct, or
// `len(src)` when input ended (`Truncated`: appending bytes could still make it
// valid). A budget fault (`Limit_*`, `Too_Deep`) reports the construct's first
// byte, since no single byte is wrong. An over-cap digit run refuses as
// `Limit_Digits` as soon as it is counted, before the rest of the token is read.
Error_Kind :: enum {
	None,
	Truncated, // input ended mid-construct — SYNTAX, at len(src)
	Bad_Char, // unexpected byte — SYNTAX
	Bad_Escape, // illegal escape inside a string, or a lone surrogate half (at its backslash); CSV: a backslash escape other than `\t` `\n` `\r` `\\` — SYNTAX
	Bad_Literal, // malformed true/false/null — SYNTAX
	Bad_Number, // malformed number — SYNTAX
	Limit_Digits, // mantissa digit count past MAX_SCALAR_DIGITS — BUDGET
	Limit_Scale, // |exponent| or |scale| past MAX_SCALAR_SCALE — BUDGET
	Too_Deep, // nesting past `Limits.max_depth` (MAX_DEPTH by default) — BUDGET, with the two Limit_* arms
	Trailing, // bytes after the document — SYNTAX
	// The next two arms are faults no byte is at. `build` raises both.
	Source_Too_Wide, // `build`: source past TAPE_MAX_SOURCE, which node offsets cannot address. `offset` is that limit
	Out_Of_Memory, // `build`: the allocator refused a row or a decoded string. `offset` is 0, since the walk reads on past a refused append. Any walk under a `max_depth` past MAX_DEPTH: it refused the frames past MAX_DEPTH, at the bracket that needed them
	Duplicate_Key, // `Duplicates.Refuse`: a member key that, decoded, repeats an earlier key of its own object (at the repeat's opening quote)
	Bad_Option, // `build`: a `duplicates` it does not take (`.First`, `.All`), refused before any byte is read. No byte is at it, and `offset` is 0
	Field_Count, // CSV: a record with more or fewer fields than the first (at the record's first byte)
	Limit_Fields, // CSV: a record with more fields than `Limits.max_fields` (at the record's first byte) — BUDGET
	Limit_Record, // CSV: a line longer than `Limits.max_record_bytes` (at the line's first byte) — BUDGET
}

Error :: struct {
	offset: u64,
	kind:   Error_Kind,
}

// The 1-based line and column of `offset` in `src`. `col` counts bytes, not runes. A line break is `\n`, so
// `\r\n` is one break and a lone `\r` is none: it is a byte of the line it sits on. `offset == len(src)` is
// valid (an `Error` at end of input). Past that, `ok` is false.
line_col :: proc(src: []byte, offset: u64) -> (line, col: int, ok: bool) {
	if offset > u64(len(src)) {
		return 0, 0, false
	}
	line = 1
	line_start := 0
	for b, i in src[:int(offset)] {
		if b == '\n' {
			line += 1
			line_start = i + 1
		}
	}
	return line, int(offset) - line_start + 1, true
}

// Writes a fault text, `line:col: kind`, or `offset N: kind` when `line` is 0 (`line_col` found no position).
write_fault :: proc(w: io.Writer, line, col: int, offset: u64, kind: string) -> io.Error {
	if line > 0 {
		io.write_int(w, line) or_return
		io.write_byte(w, ':') or_return
		io.write_int(w, col) or_return
	} else {
		io.write_string(w, "offset ") or_return
		io.write_u64(w, offset) or_return
	}
	io.write_string(w, ": ") or_return
	_, err := io.write_string(w, kind)
	return err
}
