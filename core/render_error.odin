package core

// Where a fault of a text is, and how it reads: `line:col: kind`, shared by the formats whose faults are an
// `Error`, an `Unmarshal_Error` or a `Path_Error`.

import "core:io"
import "core:reflect"
import "core:strings"

// The 1-based line and column `err` points at in `src`. Columns count bytes. It is (0, 0) when `err` points
// at no byte: an offset past `src`, a `.Source_Too_Wide` (a limit), an `.Out_Of_Memory` or a `.Bad_Option`.
@(require_results)
error_position :: proc(src: []byte, err: Error) -> (line, col: int) {
	if err.kind == .Source_Too_Wide || err.kind == .Out_Of_Memory || err.kind == .Bad_Option {
		return 0, 0
	}
	line, col, _ = line_col(src, err.offset)
	return
}

// `err` as `line:col: <kind>`, the kind written as its enum name, or `offset N: <kind>` where it has no
// position (`error_position`). An `Unmarshal_Error` reads the same way, with `src` the text its offset is into
// (`render_unmarshal_error_to_writer`), and a `Path_Error` too (`render_path_error_to_writer`). The text is
// allocated with `allocator`.
@(require_results)
render_error :: proc(src: []byte, err: $E, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	render_error_to_writer(strings.to_writer(&b), src, err)
	return strings.to_string(b)
}

// `render_error`'s text written to `w`, allocating nothing; `w`'s failure is the `io.Error`, with a prefix of
// the text possibly written.
render_error_to_writer :: proc {
	render_syntax_error_to_writer,
	render_unmarshal_error_to_writer,
	render_path_error_to_writer,
}

render_syntax_error_to_writer :: proc(w: io.Writer, src: []byte, err: Error) -> io.Error {
	line, col := error_position(src, err)
	return write_fault(w, line, col, err.offset, reflect.enum_string(err.kind))
}

// `line:col: <kind>` (`: <syntax>` after a `.Syntax`), bare where it points at no byte, then ` at .a[3]."b c"`
// for its path (`[]` for a map value or element of any index, a leading `…` when `truncated`).
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

// A `Path_Error` as its kind's name, led by the position it has: `line:col: ` in `src` for `.Bad_Source`, and
// for `.Encode` and `.Unplaceable` where `offset` is not 0; `offset N: ` for `.Bad_Path` and `.Bad_Result`
// (into the path or the edited text, which `src` is not); ` (N)` after `.Bad_Row`. The scan's `syntax` follows
// `.Bad_Source` and `.Bad_Result` unless it is `.None`, and the `encode` fault follows `.Encode`.
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

// `line:col: text` for the byte `offset` of `src`, `offset N: text` where `src` has none.
write_fault_at :: proc(w: io.Writer, src: []byte, offset: u64, text: string) -> io.Error {
	line, col, _ := line_col(src, offset)
	return write_fault(w, line, col, offset, text)
}

// `: text`, after a fault's kind.
write_detail :: proc(w: io.Writer, text: string) -> io.Error {
	io.write_string(w, ": ") or_return
	_, err := io.write_string(w, text)
	return err
}

// A path step as jq spells it: `.name` (`."quoted"` where the name is not an identifier), `[3]`, `[]` for any.
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
