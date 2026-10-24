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

// Formats `err` as `line:col: <kind>`, with the kind's enum name, or as `offset N: <kind>` when it has no
// position (`error_position`). An `Unmarshal_Error` (`render_unmarshal_error_to_writer`) and a `Path_Error`
// (`render_path_error_to_writer`) are formatted the same way, with `src` the text their offset refers to. The
// text is allocated with `allocator`.
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

render_syntax_error_to_writer :: proc(w: io.Writer, src: []byte, err: Error) -> io.Error {
	line, col := error_position(src, err)
	return write_fault(w, line, col, err.offset, reflect.enum_string(err.kind))
}

// Writes `line:col: <kind>`, followed by `: <syntax>` for `.Syntax`, or the bare kind when there is no byte
// position. Then writes the path as ` at .a[3]."b c"`, with `[]` for a map value or for an element of any index,
// and a leading `…` when `truncated`.
render_unmarshal_error_to_writer :: proc(w: io.Writer, src: []byte, err: Unmarshal_Error) -> io.Error {
	name := reflect.enum_string(err.kind)
	#partial switch err.kind {
	case .Unsupported, .Ambiguous_Union, .Bad_Option, .Plan_Mismatch: // before any byte
		io.write_string(w, name) or_return
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

// Writes a `Path_Error` as its kind's name with its position. The prefix is `line:col: ` in `src` for
// `.Bad_Source`, and for `.Encode` and `.Unplaceable` when `offset` is not 0. It is `offset N: ` for `.Bad_Path`
// and `.Bad_Result`, whose offsets are into the path or the edited text rather than `src`. `.Bad_Row` is followed
// by ` (N)`. `.Bad_Source` and `.Bad_Result` are followed by the scan's `syntax` unless it is `.None`, and
// `.Encode` by the `encode` error.
render_path_error_to_writer :: proc(w: io.Writer, src: []byte, err: Path_Error) -> io.Error {
	name := reflect.enum_string(err.kind)
	#partial switch err.kind {
	case .Bad_Source:
		write_fault_at(w, src, err.offset, name) or_return
	case .Bad_Path, .Bad_Result:
		write_fault(w, 0, 0, err.offset, name) or_return
	case .Encode, .Unplaceable:
		if err.offset > 0 {
			write_fault_at(w, src, err.offset, name) or_return
		} else {
			io.write_string(w, name) or_return
		}
	case .Bad_Row:
		io.write_string(w, name) or_return
		io.write_string(w, " (") or_return
		io.write_u64(w, err.offset) or_return
		io.write_byte(w, ')') or_return
	case:
		io.write_string(w, name) or_return
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
