package csv

// Reading one present cell into a field of one of the cell kinds: the typed stores, the decode a quoted or
// escaped string needs, and the rare kinds' hook.

import "base:runtime"
import "core:strings"
import "core:unicode/utf8"
import core_pkg "../core"

// Reads a present cell into the field op `op` at `dest`. The common kinds have their own small procs, so a
// cell pays only for its own kind's frame.
@(private)
read_cell :: proc(r: ^Reader, op: ^core_pkg.Shape_Op, cell: Field, dest: rawptr) -> core_pkg.Shape_Fault {
	#partial switch op.kind {
	case .Int, .Uint:
		return read_int_cell(r, op, cell, dest)
	case .String:
		return read_string_cell(r, cell, dest)
	case .Float:
		return read_float_cell(r, op, cell, dest)
	case .Union:
		// A `Maybe` of a cell: one arm, whose tag is set once the arm is read.
		arm := &r.shape.fields[op.elem]
		read_cell(r, &r.shape.ops[arm.op], cell, dest) or_return
		core_pkg.shape_union_tag(dest, op, arm.offset)
		return .None
	}
	return read_rare_cell(r, op, cell, dest)
}

@(private)
read_int_cell :: proc(r: ^Reader, op: ^core_pkg.Shape_Op, cell: Field, dest: rawptr) -> core_pkg.Shape_Fault {
	return store_int(authored(r, cell), dest, op.width, op.kind == .Int)
}

@(private)
read_float_cell :: proc(r: ^Reader, op: ^core_pkg.Shape_Op, cell: Field, dest: rawptr) -> core_pkg.Shape_Fault {
	text := transmute([]byte)authored(r, cell)
	n, ok := core_pkg.number_of_loose_text(text)
	switch {
	case !ok:
		return .Wrong_Kind
	case n.exactness == .None:
		return .Out_Of_Range
	case op.width == 4:
		return core_pkg.shape_f32_store(core_pkg.shape_off_halfway(text, n, 24, -126), dest)
	case op.width == 2:
		return core_pkg.shape_f16_store(core_pkg.shape_off_halfway(text, n, 11, -14), dest)
	}
	(^f64)(dest)^ = n.value
	return .None
}

@(private)
read_string_cell :: proc(r: ^Reader, cell: Field, dest: rawptr) -> core_pkg.Shape_Fault {
	text := authored(r, cell)
	s, err := cell_string(r, cell, text, needs_decoding(r, cell, text), r.borrow)
	if err != nil {
		return .Out_Of_Memory
	}
	(^string)(dest)^ = s
	return .None
}

@(private)
read_rare_cell :: proc(r: ^Reader, op: ^core_pkg.Shape_Op, cell: Field, dest: rawptr) -> core_pkg.Shape_Fault {
	text := authored(r, cell)
	#partial switch op.kind {
	case .Bool:
		switch text {
		case "true":
			core_pkg.shape_bool_store(true, dest, op.width)
		case "false":
			core_pkg.shape_bool_store(false, dest, op.width)
		case:
			return .Wrong_Kind
		}
	case .Wide_Int, .Wide_Uint:
		mag, over, neg := read_int(text) or_return
		return core_pkg.shape_wide_store(mag, over, neg, dest, op.kind == .Wide_Int)
	case .Enum_Int, .Enum_Uint:
		if r.enum_ints {
			v: u64
			store_int(text, &v, op.width, op.kind == .Enum_Int) or_return
			return core_pkg.shape_enum_store(v, dest, op)
		}
		for name, k in op.enum_info.names {
			if name == text {
				core_pkg.shape_enum_member_store(op, k, dest)
				return .None
			}
		}
		return .Not_A_Member
	case .Rune:
		if r.dialect.quoting == .Backslash && len(text) == 2 && text[0] == '\\' {
			(^rune)(dest)^ = rune(unescaped(text[1]))
			return .None
		}
		if has_pair(cell, text) {
			if text != `""` {
				return .Wrong_Kind
			}
			(^rune)(dest)^ = '"'
			return .None
		}
		c, size := utf8.decode_rune(text)
		if size == 0 || size != len(text) {
			return .Wrong_Kind
		}
		(^rune)(dest)^ = c
	case .Cstring:
		if holds_nul(r, text) {
			return .Out_Of_Range
		}
		if r.check {
			return .None
		}
		quote := needs_decoding(r, cell, text)
		s, err := cell_string(r, cell, text, quote, true)
		if err != nil {
			return .Out_Of_Memory
		}
		c, cerr := strings.clone_to_cstring(s, r.allocator)
		if quote {
			delete(s, r.allocator)
		}
		if cerr != nil {
			return .Out_Of_Memory
		}
		(^cstring)(dest)^ = c
	case .Hook:
		if r.check {
			return .None
		}
		quote := needs_decoding(r, cell, text)
		s, err := cell_string(r, cell, text, quote, true)
		if err != nil {
			return .Out_Of_Memory
		}
		fault, refused := r.shape.hooks[op.elem]({kind = .String, text = string(r.src[cell.lo:cell.hi]), decoded = s}, dest, r.allocator).?
		if quote {
			delete(s, r.allocator)
		}
		return fault if refused else .None
	}
	return .None
}

// Whether the cell's text decodes to one holding a NUL, a raw one or `\0`, which a cstring cannot hold.
@(private)
holds_nul :: proc(r: ^Reader, text: string) -> bool {
	for i := 0; i < len(text); i += 1 {
		if text[i] == 0 {
			return true
		}
		if text[i] == '\\' && r.dialect.quoting == .Backslash && i + 1 < len(text) {
			i += 1
			if text[i] == '0' {
				return true
			}
		}
	}
	return false
}

// A quote in a quoted cell's text comes from a `""`. Only a string, a cstring or the rune `"` can hold one.
@(private)
has_pair :: #force_inline proc(cell: Field, text: string) -> bool {
	return cell.hi - cell.lo != u64(len(text)) && holds(text, '"')
}

// Whether the cell's text holds a `""` or an escape, which `cell_text` decodes.
@(private)
needs_decoding :: #force_inline proc(r: ^Reader, cell: Field, text: string) -> bool {
	// `text` is `authored`'s, a slice of `src`.
	lo := int(uintptr(raw_data(text)) - uintptr(raw_data(r.src)))
	if cell.hi - cell.lo != u64(len(text)) && holds_span(r.src, lo, len(text), '"') {
		return true
	}
	return r.dialect.quoting == .Backslash && holds_span(r.src, lo, len(text), '\\')
}

@(private)
holds :: #force_inline proc(text: string, c: byte) -> bool {
	p := raw_data(text)
	n := len(text)
	if n < 16 {
		for b in transmute([]byte)text {
			if b == c {
				return true
			}
		}
		return false
	}
	// 16-byte windows, the last one overlapping the one before.
	for i := 0; i + 16 < n; i += 16 {
		if core_pkg.any_eq(core_pkg.load(p[i:]), c) {
			return true
		}
	}
	return core_pkg.any_eq(core_pkg.load(p[n - 16:]), c)
}

// The cell's text as a string: decoded when it holds a `""` or an escape, else borrowed or copied.
@(private)
cell_string :: proc(r: ^Reader, cell: Field, text: string, quote, borrow: bool) -> (string, runtime.Allocator_Error) {
	if quote && !r.check {
		decoded, _, err := cell_text(r.src, cell, r.dialect, r.allocator)
		return decoded, err
	}
	if borrow {
		return text, nil
	}
	return strings.clone(text, r.allocator)
}
