package core

// Fault positions and messages (`line:col: text`) for every format's `Error`, `Unmarshal_Error` and `Path_Error`.

import "core:io"
import "core:mem"
import "core:strings"

// The 1-based line and column of `err` in `src`, counting bytes, or (0, 0) when `err` has no byte position in
// `src`: an offset past `src`, or a kind whose offset is no byte of the text (`render_error` writes those
// `offset N: ` or bare). A `Marshal_Error` has none.
error_position :: proc {
	syntax_error_position,
	unmarshal_error_position,
	path_error_position,
	marshal_error_position,
}

// An `Error`'s: none for `.Source_Too_Wide` (a limit), `.Out_Of_Memory` or `.Bad_Option`.
@(require_results)
syntax_error_position :: proc(src: []byte, err: Error) -> (line, col: int) {
	#partial switch err.kind {
	case .Source_Too_Wide, .Out_Of_Memory, .Bad_Option:
		return 0, 0
	}
	line, col, _ = line_col(src, err.offset)
	return
}

// An `Unmarshal_Error`'s: none for a refusal before any byte, or an `.Out_Of_Memory` at offset 0.
@(require_results)
unmarshal_error_position :: proc(src: []byte, err: Unmarshal_Error) -> (line, col: int) {
	if unmarshal_before_any_byte(err.kind) || err.kind == .Out_Of_Memory && err.offset == 0 {
		return 0, 0
	}
	line, col, _ = line_col(src, err.offset)
	return
}

// A `Path_Error`'s: `.Bad_Source`'s, and `.Encode`'s or `.Unplaceable`'s at a nonzero offset.
@(require_results)
path_error_position :: proc(src: []byte, err: Path_Error) -> (line, col: int) {
	if !path_error_at_byte(err) {
		return 0, 0
	}
	line, col, _ = line_col(src, err.offset)
	return
}

@(require_results)
marshal_error_position :: proc(src: []byte, err: Marshal_Error) -> (line, col: int) {
	return 0, 0
}

// The unmarshal refusals raised before any byte is read, with no offset to show.
@(private = "file")
unmarshal_before_any_byte :: proc(kind: Unmarshal_Error_Kind) -> bool {
	#partial switch kind {
	case .Unsupported, .Ambiguous_Union, .Bad_Option, .Plan_Mismatch, .Bad_Tag:
		return true
	}
	return false
}

// Whether a path refusal's offset is a byte of the source it read.
@(private = "file")
path_error_at_byte :: proc(err: Path_Error) -> bool {
	#partial switch err.kind {
	case .Bad_Source:
		return true
	case .Encode, .Unplaceable:
		return err.offset > 0
	}
	return false
}

// Formats `err` as `line:col: <text>`, with the fault's text (`fault_text`, spelled by the format's `name`), or as
// `write_no_byte_fault` spells a fault at no byte of `src`. An `Unmarshal_Error` and a `Path_Error` are formatted
// the same way, with `src` the text their offset refers to; a `Marshal_Error` has no text and reads as its kind
// and path. The text is allocated with `allocator`.
@(require_results)
render_error :: proc(src: []byte, err: $E, allocator := context.allocator, name: Fault_Name = nil) -> string where E == Error || E == Unmarshal_Error || E == Path_Error || E == Marshal_Error {
	text: Text
	render_error_to_writer(text_open(&text, allocator), src, err, name)
	return text_string(&text)
}

// Writes `render_error`'s text to `w` without allocating. Returns `w`'s error, after which part of the text may
// have been written.
render_error_to_writer :: proc(w: io.Writer, src: []byte, err: $E, name: Fault_Name = nil) -> io.Error where E == Error || E == Unmarshal_Error || E == Path_Error || E == Marshal_Error {
	return write_error(w, src, err, name)
}

// `render_error` builds its text here: a generic body that used `strings` alone would leave the import unused
// under `-vet` in a package that never instantiates it.
@(private = "file")
Text :: strings.Builder

@(private = "file")
text_open :: proc(t: ^Text, allocator: mem.Allocator) -> io.Writer {
	t^ = strings.builder_make(allocator)
	return strings.to_writer(t)
}

@(private = "file")
text_string :: proc(t: ^Text) -> string {
	return strings.to_string(t^)
}

@(private = "file")
write_error :: proc {
	write_syntax_error,
	write_unmarshal_error,
	write_path_error,
	write_marshal_error,
}

// Writes an `Error`.
@(private = "file")
write_syntax_error :: proc(w: io.Writer, src: []byte, err: Error, name: Fault_Name = nil) -> io.Error {
	text := fault_text(err.kind, err.detail, name)
	line, col := syntax_error_position(src, err)
	if line > 0 {
		return write_fault(w, line, col, err.offset, text)
	}
	return write_no_byte_fault(w, text, err.offset, true)
}

// Writes `line:col: <kind>`, a `.Syntax` read as its `syntax` fault's text, then the path as ` at .a[3]."b c"`,
// with `[]` for a map value or for an element of any index, and a leading `…` when `truncated`.
@(private = "file")
write_unmarshal_error :: proc(w: io.Writer, src: []byte, err: Unmarshal_Error, name: Fault_Name = nil) -> io.Error {
	kind := "Unknown fault"
	switch {
	case err.kind == .Syntax:
		kind = fault_text(err.syntax, err.detail, name)
	case err.kind >= min(Unmarshal_Error_Kind) && err.kind <= max(Unmarshal_Error_Kind):
		kind = UNMARSHAL_ERROR_TEXT[err.kind]
	}
	// A refused value is located; a refused plan, an `.Out_Of_Memory` at offset 0, is before any byte.
	if line, col := unmarshal_error_position(src, err); line > 0 {
		write_fault(w, line, col, err.offset, kind) or_return
	} else {
		write_no_byte_fault(w, kind, err.offset, !unmarshal_before_any_byte(err.kind)) or_return
	}
	return write_error_path(w, err.steps, err.n_steps, err.truncated)
}

// Writes `<kind>` and the path, as `write_unmarshal_error` writes it. `src` is not read.
@(private = "file")
write_marshal_error :: proc(w: io.Writer, src: []byte, err: Marshal_Error, name: Fault_Name = nil) -> io.Error {
	io.write_string(w, MARSHAL_ERROR_TEXT[err.kind]) or_return
	return write_error_path(w, err.steps, err.n_steps, err.truncated)
}

// ` at .a[3]."b c"`, with `[]` for `Any`, a leading `…` when `truncated`; nothing for no steps.
@(private)
write_error_path :: proc(w: io.Writer, steps: [ERROR_PATH_STEPS]Step, n: u8, truncated: bool) -> io.Error {
	if n == 0 {
		return nil
	}
	io.write_string(w, " at ") or_return
	if truncated {
		io.write_string(w, "…") or_return
	}
	for i in 0 ..< int(n) {
		write_step(w, steps[i]) or_return
	}
	return nil
}

// Writes a `Path_Error`. The kinds with an offset: `line:col: ` in `src` for `.Bad_Source`, and for `.Encode`
// and `.Unplaceable` when `offset` is not 0; `offset N: ` for `.Bad_Path`, `.Bad_Result` and `.Out_Of_Memory`;
// the rest read bare. A `.Bad_Source` with a `syntax` reads as that fault's text. `.Bad_Entry` is followed by
// ` (N)`, `.Bad_Result` by the scan's `syntax`, and `.Encode` by the `encode` error.
@(private = "file")
write_path_error :: proc(w: io.Writer, src: []byte, err: Path_Error, name: Fault_Name = nil) -> io.Error {
	kind := PATH_ERROR_TEXT[err.kind]
	if err.kind == .Bad_Source {
		kind = fault_text(err.syntax, err.detail, name)
	}
	line, col := path_error_position(src, err)
	switch {
	case line > 0:
		write_fault(w, line, col, err.offset, kind) or_return
	case path_error_at_byte(err), err.kind == .Bad_Path, err.kind == .Bad_Result, err.kind == .Out_Of_Memory:
		write_no_byte_fault(w, kind, err.offset, true) or_return
	case err.kind == .Bad_Entry:
		io.write_string(w, kind) or_return
		io.write_string(w, " (") or_return
		io.write_u64(w, err.offset) or_return
		io.write_byte(w, ')') or_return
	case:
		write_no_byte_fault(w, kind, err.offset, false) or_return
	}
	#partial switch err.kind {
	case .Bad_Result:
		write_detail(w, fault_text(err.syntax, err.detail, name)) or_return
	case .Encode:
		write_detail(w, MARSHAL_ERROR_TEXT[err.encode]) or_return
	}
	return nil
}

// Writes a fault that is at no byte of `src`, the one place the three error types spell one. `offset_locates` is
// true where the kind's offset is what says where the fault is (a limit, a byte of another text, a row count, or
// the 0 of a refusal raised before any byte): that reads `offset N: <kind>`. A kind with no offset at all reads as
// its bare name. No fault is given a `line:col` it does not have.
@(private)
write_no_byte_fault :: proc(w: io.Writer, kind: string, offset: u64, offset_locates: bool) -> io.Error {
	if !offset_locates {
		_, err := io.write_string(w, kind)
		return err
	}
	return write_fault(w, 0, 0, offset, kind)
}

// Writes `: text` after a fault's kind.
write_detail :: proc(w: io.Writer, text: string) -> io.Error {
	io.write_string(w, ": ") or_return
	_, err := io.write_string(w, text)
	return err
}

// Writes a path step as jq does: `.name` (`."quoted"` when the name is not an identifier), `[3]`, or `[]` for any.
write_step :: proc(w: io.Writer, step: Step) -> io.Error {
	switch s in step {
	case Name:
		if is_identifier(string(s)) {
			io.write_byte(w, '.') or_return
			_, err := io.write_string(w, string(s))
			return err
		}
		io.write_byte(w, '.') or_return
		_, err := io.write_quoted_string(w, string(s))
		return err
	case Index:
		io.write_byte(w, '[') or_return
		if _, err := io.write_i64(w, i64(s)); err != nil {
			return err
		}
		return io.write_byte(w, ']')
	case Any:
		_, err := io.write_string(w, "[]")
		return err
	}
	return nil
}

@(private = "file")
is_identifier :: proc(s: string) -> bool {
	for c, i in transmute([]u8)s {
		switch {
		case c == '_', 'a' <= c && c <= 'z', 'A' <= c && c <= 'Z':
		case '0' <= c && c <= '9' && i > 0:
		case:
			return false
		}
	}
	return len(s) > 0
}
