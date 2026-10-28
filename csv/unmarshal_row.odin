package csv

// Reading one record's cells into the struct, list or map at `dest`: the fast arms for the kinds most cells have,
// the required-field check, and the lazy/ragged adjustments to a record's cells.

import "base:runtime"
import core_pkg "../core"

// `-?digits`, up to 18 of them, whose value an i64 holds.
@(private)
small_int :: #force_inline proc(text: []byte) -> (v: i64, ok: bool) {
	digits := text
	neg := len(digits) > 0 && digits[0] == '-'
	if neg {
		digits = digits[1:]
	}
	if len(digits) == 0 || len(digits) > 18 {
		return
	}
	m: u64
	for c in digits {
		d := c - '0'
		if d > 9 {
			return
		}
		m = m * 10 + u64(d)
	}
	return -i64(m) if neg else i64(m), true
}

// `-?digits(.digits)?` with at most 15 digits. Those digits and the power of ten are exact in an f64
// (Clinger's fast path), so their quotient is correctly rounded.
@(private)
short_decimal :: #force_inline proc(text: []byte) -> (v: f64, ok: bool) {
	digits := text
	neg := len(digits) > 0 && digits[0] == '-'
	if neg {
		digits = digits[1:]
	}
	if len(digits) == 0 || len(digits) > 16 {
		return
	}
	m: u64
	n, frac := 0, -1
	for c in digits {
		if c == '.' {
			if frac >= 0 {
				return
			}
			frac = 0
			continue
		}
		d := c - '0'
		if d > 9 {
			return
		}
		m = m * 10 + u64(d)
		n += 1
		if frac >= 0 {
			frac += 1
		}
	}
	if n == 0 || n > 15 {
		return
	}
	v = f64(m) / core_pkg.POW10_F64[max(frac, 0)]
	return -v if neg else v, true
}

// Reads one record's cells, at most one per column, into the struct at `dest`, or returns why the cell at `at`
// of field `name` was refused. A ragged record's missing cells, at its end, are absent.
@(private)
read_row :: proc(r: ^Reader, cells: []Field, dest: rawptr) -> (kind: Unmarshal_Error_Kind, at: u64, name: string, refused: bool) {
	for cell, c in cells {
		col := &r.cols[c]
		if col.op == nil || cell.lo == cell.hi {
			continue
		}
		to := rawptr(uintptr(dest) + col.offset)
		switch col.fast {
		case .Int64, .Int64_Maybe:
			if v, ok := small_int(r.src[cell.lo:cell.hi]); ok {
				(^i64)(to)^ = v
				if col.fast == .Int64_Maybe {
					core_pkg.shape_union_tag(to, col.union_op, col.tag)
				}
				continue
			}
		case .Float64:
			if v, ok := short_decimal(r.src[cell.lo:cell.hi]); ok {
				(^f64)(to)^ = v
				continue
			}
		case .String:
			if r.src[cell.lo] != '"' {
				(^string)(to)^ = string(r.src[cell.lo:cell.hi])
				continue
			}
		case .None:
		}
		if fault := read_cell(r, col.op, cell, to); fault != .None {
			return Unmarshal_Error_Kind(fault), cell.lo, col.name, true
		}
	}
	for req in r.required {
		cell := cells[len(cells) - 1]
		if int(req[1]) < len(cells) {
			cell = cells[req[1]]
		} else {
			cell.lo = cell.hi
		}
		if cell.lo == cell.hi && !read_by_later_column(r, cells, req[0]) {
			return .Missing_Field, cell.lo, r.shape.fields[r.row.elem + req[0]].name, true
		}
	}
	return
}

// Reads every cell of record `row` into a new list at `dest`, an absent cell as the zero value. Under `check` each
// cell is read into `dest` itself, one scratch cell.
@(private)
read_list_row :: proc(r: ^Reader, cells: []Field, dest: rawptr, row: int) -> Maybe(Unmarshal_Error) {
	op := &r.shape.ops[r.row.elem]
	stride := uintptr(r.row.stride)
	data := dest
	if !r.check {
		buf, aerr := runtime.mem_alloc(len(cells) * int(stride), int(r.row.align), r.allocator)
		if aerr != nil {
			return cell_error(.Out_Of_Memory, cells[0].lo, row, nil)
		}
		data = raw_data(buf)
		if r.row.kind == .Slice {
			(^runtime.Raw_Slice)(dest)^ = {data, len(cells)}
		} else {
			(^runtime.Raw_Dynamic_Array)(dest)^ = {data, len(cells), len(cells), r.allocator}
		}
	}
	for cell, c in cells {
		if cell.lo == cell.hi {
			continue
		}
		to := data if r.check else rawptr(uintptr(data) + uintptr(c) * stride)
		if fault := read_cell(r, op, cell, to); fault != .None {
			err := Unmarshal_Error{kind = Unmarshal_Error_Kind(fault), offset = cell.lo}
			core_pkg.error_path_prepend(&err, core_pkg.Index(c))
			core_pkg.error_path_prepend(&err, core_pkg.Index(row))
			return err
		}
	}
	return nil
}

// Reads record `row`'s present cells into the map at `dest`, each under its column's key. Under `check` each cell
// is read into `dest` itself, one scratch cell.
@(private)
read_map_row :: proc(r: ^Reader, cells: []Field, dest: rawptr, row: int) -> Maybe(Unmarshal_Error) {
	m := (^runtime.Raw_Map)(dest)
	// A map that has an allocator keeps it: its entries were made with it.
	if !r.check && m.allocator.procedure == nil {
		m.allocator = r.allocator
	}
	for cell, c in cells {
		col := &r.cols[c]
		if col.op == nil || cell.lo == cell.hi {
			continue
		}
		to := dest
		if !r.check {
			slot, aerr := runtime.__dynamic_map_set_without_hash(m, r.row.map_info, &r.keys[c], raw_data(r.shape.zero))
			if aerr != nil || slot == nil {
				return cell_error(.Out_Of_Memory, cell.lo, row, core_pkg.Name(col.name))
			}
			to = slot
		}
		if fault := read_cell(r, col.op, cell, to); fault != .None {
			return cell_error(Unmarshal_Error_Kind(fault), cell.lo, row, core_pkg.Name(col.name))
		}
	}
	return nil
}

// Whether a later column that reads required `field` has a present cell.
@(cold, private)
read_by_later_column :: proc(r: ^Reader, cells: []Field, field: u32) -> bool {
	for more in r.req_more {
		if more[0] == field && int(more[1]) < len(cells) && cells[more[1]].lo != cells[more[1]].hi {
			return true
		}
	}
	return false
}

// A lazy or ragged record's cells: UTF-8 is judged when lazy, and the cells are cut to the columns when ragged.
@(cold, private)
record_cells :: proc(r: ^Reader, it: ^Records, rec: Record, row: int, lazy, refuse: bool) -> (cells: []Field, err: Maybe(Unmarshal_Error)) {
	cells = rec.fields
	if lazy && it.carry.utf8 <= int(cells[len(cells) - 1].hi) {
		judge_utf8(r, it, rec, row) or_return
	}
	if len(cells) > len(r.cols) {
		if refuse {
			return nil, cell_error(.Unknown_Field, cells[len(r.cols)].lo, row, nil)
		}
		cells = cells[:len(r.cols)]
	}
	return cells, nil
}

// Under `.Lazy`: refuses the UTF-8 fault the scan passed when it lies in `rec`, in a cell a field reads (or in
// any header cell, `row` -1, or any cell of a list row). The scan is then pointed at its next fault past `rec`.
@(cold, private)
judge_utf8 :: proc(r: ^Reader, it: ^Records, rec: Record, row: int) -> Maybe(Unmarshal_Error) {
	for cell, c in rec.fields {
		if row >= 0 && r.row.kind != .Slice && r.row.kind != .Dynamic && (c >= len(r.cols) || r.cols[c].op == nil) {
			continue
		}
		if at, k := utf8_fault(r.src, int(cell.lo), int(cell.hi)); at >= 0 {
			err := Unmarshal_Error{kind = .Syntax, syntax = k, offset = u64(at)}
			if row >= 0 {
				core_pkg.error_path_prepend(&err, core_pkg.Index(row))
			}
			return err
		}
	}
	// The scan kept only the first fault in the bytes it read, which run to the end of its block.
	from := int(rec.fields[len(rec.fields) - 1].hi) + 1
	it.carry.utf8 = max(int)
	if from < len(r.src) {
		if at, _ := utf8_fault(r.src, from, it.block + 64); at >= 0 {
			it.carry.utf8 = at
		}
	}
	return nil
}

// A cell's text as written, without a quoted cell's quotes: the name a path uses for it.
@(private)
authored :: proc(r: ^Reader, cell: Field) -> string {
	text := r.src[cell.lo:cell.hi]
	if len(text) > 1 && text[0] == '"' && r.dialect.quoting == .Quotes {
		text = text[1 : len(text) - 1]
	}
	return string(text)
}
