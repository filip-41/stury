package core

// Fault positions and messages (`line:col: kind`) for every format's `Error`, `Unmarshal_Error` and `Path_Error`.

import "core:io"
import "core:reflect"
import "core:strings"

// The builder `render_error` writes through. The alias is the file's non-generic use of `core:strings`: a
// generic's body is checked only when it is instantiated, so without this a plain `-vet` build of a program
// that never calls `render_error` rejects the import.
@(private)
Text_Builder :: strings.Builder

// Returns the 1-based line and column of `err` in `src`. Columns count bytes. Returns (0, 0) when `err` has no
// byte position in `src`: an offset past `src`, `.Source_Too_Wide` (a limit), `.Out_Of_Memory`, `.Bad_Option`,
// `.Over_Capacity` or `.Bad_Path` (whose offset is into the path text).
@(require_results)
error_position :: proc(src: []byte, err: Error) -> (line, col: int) {
	#partial switch err.kind {
	case .Source_Too_Wide, .Out_Of_Memory, .Bad_Option, .Over_Capacity, .Bad_Path:
		return 0, 0
	}
	line, col, _ = line_col(src, err.offset)
	return
}

// Formats `err` as `line:col: <kind>`, with the kind's enum name, or as `write_no_byte_fault` spells a fault at
// no byte of `src`. An `Unmarshal_Error` and a `Path_Error` are formatted the same way, with `src` the text
// their offset refers to. The text is allocated with `allocator`.
@(require_results)
render_error :: proc(src: []byte, err: $E, allocator := context.allocator) -> string {
	b: Text_Builder = strings.builder_make(allocator)
	render_error_to_writer(strings.to_writer(&b), src, err)
	return strings.to_string(b)
}

// Writes `render_error`'s text to `w` without allocating. Returns `w`'s error, after which part of the text may
// have been written.
render_error_to_writer :: proc {
	render_syntax_error_to_writer,
	render_unmarshal_error_to_writer,
	render_path_error_to_writer,
}

// Writes an `Error`.
render_syntax_error_to_writer :: proc(w: io.Writer, src: []byte, err: Error) -> io.Error {
	name := reflect.enum_string(err.kind)
	line, col := error_position(src, err)
	if line > 0 {
		return write_fault(w, line, col, err.offset, name)
	}
	return write_no_byte_fault(w, name, err.offset, true)
}

// Writes `line:col: <kind>`, followed by `: <syntax>` for `.Syntax`, then the path as ` at .a[3]."b c"`, with
// `[]` for a map value or for an element of any index, and a leading `…` when `truncated`.
render_unmarshal_error_to_writer :: proc(w: io.Writer, src: []byte, err: Unmarshal_Error) -> io.Error {
	name := reflect.enum_string(err.kind)
	#partial switch err.kind {
	case .Unsupported, .Ambiguous_Union, .Bad_Option, .Plan_Mismatch, .Bad_Tag: // before any byte, with no offset to show
		write_no_byte_fault(w, name, err.offset, false) or_return
	case .Out_Of_Memory:
		// A refused value is located; a refused plan, at offset 0, is before any byte.
		if err.offset > 0 {
			write_fault_at(w, src, err.offset, name) or_return
		} else {
			write_no_byte_fault(w, name, err.offset, true) or_return
		}
	case:
		write_fault_at(w, src, err.offset, name) or_return
	}
	if err.kind == .Syntax {
		write_detail(w, reflect.enum_string(err.syntax)) or_return
	}
	if err.n_steps > 0 {
		io.write_string(w, " at ") or_return
		if err.truncated {
			io.write_string(w, "…") or_return
		}
		for i in 0 ..< int(err.n_steps) {
			write_step(w, err.steps[i]) or_return
		}
	}
	return nil
}

// Writes a `Path_Error`. The kinds with an offset: `line:col: ` in `src` for `.Bad_Source`, and for `.Encode`
// and `.Unplaceable` when `offset` is not 0; `offset N: ` for `.Bad_Path`, `.Bad_Result` and `.Out_Of_Memory`;
// the rest read bare. `.Bad_Row` is followed by ` (N)`, `.Bad_Source` and `.Bad_Result` by the scan's `syntax`
// unless it is `.None`, and `.Encode` by the `encode` error.
render_path_error_to_writer :: proc(w: io.Writer, src: []byte, err: Path_Error) -> io.Error {
	name := reflect.enum_string(err.kind)
	#partial switch err.kind {
	case .Bad_Source:
		write_fault_at(w, src, err.offset, name) or_return
	case .Bad_Path, .Bad_Result:
		write_no_byte_fault(w, name, err.offset, true) or_return
	case .Encode, .Unplaceable:
		if err.offset > 0 {
			write_fault_at(w, src, err.offset, name) or_return
		} else {
			write_no_byte_fault(w, name, err.offset, false) or_return
		}
	case .Bad_Row:
		io.write_string(w, name) or_return
		io.write_string(w, " (") or_return
		io.write_u64(w, err.offset) or_return
		io.write_byte(w, ')') or_return
	case .Out_Of_Memory:
		write_no_byte_fault(w, name, err.offset, true) or_return
	case:
		write_no_byte_fault(w, name, err.offset, false) or_return
	}
	#partial switch err.kind {
	case .Bad_Source, .Bad_Result:
		if err.syntax != .None {
			write_detail(w, reflect.enum_string(err.syntax)) or_return
		}
	case .Encode:
		write_detail(w, reflect.enum_string(err.encode)) or_return
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

// Writes `line:col: text` for byte `offset` of `src`, or `offset N: text` when `src` has no such byte.
write_fault_at :: proc(w: io.Writer, src: []byte, offset: u64, text: string) -> io.Error {
	line, col, _ := line_col(src, offset)
	return write_fault(w, line, col, offset, text)
}

// Writes `: text` after a fault's kind.
write_detail :: proc(w: io.Writer, text: string) -> io.Error {
	io.write_string(w, ": ") or_return
	_, err := io.write_string(w, text)
	return err
}

// Writes a path step as jq does: `.name` (`."quoted"` when the name is not an identifier), `[3]`, or `[]` for any.
@(private = "file")
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
