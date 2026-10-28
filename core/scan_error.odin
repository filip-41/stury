package core

import "core:io"

// One enum for every format, so code using several formats handles one `Error`, `Unmarshal_Error` and
// `Path_Error`. Every kind is format-neutral. A format tells its own faults apart within a kind by `detail`, a value
// of the format's own enum, and names them with its `Fault_Name`. Each format's docs list the kinds and details it
// reports.
//
// A syntax fault reports the first byte that cannot extend the construct, or
// `len(src)` when input ended (`Truncated`: appending bytes could still make it
// valid). A budget fault (`Limit_*`, `Too_Deep`) reports the construct's first
// byte, since no single byte is wrong. An over-cap digit run refuses as
// `Limit_Digits` as soon as it is counted, before the rest of the token is read.
//
// No kind is 0: an `Error` is always in a `Maybe`, and a walk may use 0 as its own no-fault value.
Error_Kind :: enum {
	Truncated = 1, // input ended mid-construct — SYNTAX, at len(src)
	Bad_Char, // unexpected byte — SYNTAX
	Bad_Escape, // an escape the format does not define, or a lone surrogate half (at its backslash) — SYNTAX
	Bad_Number, // malformed number — SYNTAX
	Limit_Digits, // mantissa digit count past MAX_SCALAR_DIGITS — BUDGET
	Limit_Scale, // |exponent| or |scale| past MAX_SCALAR_SCALE — BUDGET
	Too_Deep, // nesting past the format's `max_depth` (MAX_DEPTH by default) — BUDGET
	Trailing, // bytes after the document — SYNTAX
	// The next two arms are faults no byte is at. `build` raises both.
	Source_Too_Wide, // `build`: source past MAX_ROW_SOURCE, which node offsets cannot address. `offset` is that limit
	Out_Of_Memory, // `build`: the allocator refused a row or a decoded string. `offset` is 0, since the walk reads on past a refused append. Any walk under a `max_depth` past MAX_DEPTH: it refused the frames past MAX_DEPTH, at the bracket that needed them
	Duplicate_Key, // `Duplicates.Refuse`: a member key that, decoded, repeats an earlier key of its own object (at the repeat's opening quote)
	Bad_Option, // an option the call does not take, refused before any byte is read (`build`: `.Refuse` built without it; a `Request`: see `scan`). No byte is at it, and `offset` is 0
	Bad_Structure, // well-formed text breaking a rule of the format's structure (`detail` says which), at the construct's first byte
	Limit_Format, // past a cap of the format's own limits (`detail` says which), at the construct's first byte — BUDGET
}

Error :: struct {
	offset: u64,
	kind:   Error_Kind,
	detail: u8, // the format's own fault within `kind`, 0 for none
}

// Names a format's fault: a sentence for `kind` with `detail`, or "" where the format adds nothing to
// `FAULT_TEXT[kind]`. Each format has one, and its `render_error` passes it.
Fault_Name :: #type proc(kind: Error_Kind, detail: u8) -> string

// A sentence for each kind: the text where a format's `Fault_Name` has none.
@(rodata)
FAULT_TEXT := [Error_Kind]string {
	.Truncated       = "Unfinished input",
	.Bad_Char        = "Unexpected character",
	.Bad_Escape      = "Invalid escape",
	.Bad_Number      = "Invalid number",
	.Limit_Digits    = "Number has too many digits",
	.Limit_Scale     = "Number's exponent is out of range",
	.Too_Deep        = "Exceeds depth limit for parsing",
	.Trailing        = "Unexpected text after the value",
	.Source_Too_Wide = "Input is too large to read",
	.Out_Of_Memory   = "Out of memory",
	.Duplicate_Key   = "Duplicate key",
	.Bad_Option      = "Unsupported option",
	.Bad_Structure   = "Text breaks a rule of its format",
	.Limit_Format    = "Exceeds a limit of the format",
}

// The text of fault `kind` with `detail`: `name`'s, where it has one, or `FAULT_TEXT[kind]`.
fault_text :: proc(kind: Error_Kind, detail: u8, name: Fault_Name = nil) -> string {
	if name != nil {
		if text := name(kind, detail); text != "" {
			return text
		}
	}
	return FAULT_TEXT[kind]
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
