package csv

// What the edits write: a value or a record spelled as `marshal` spells it, by the same cell writers. A cell
// starting with a BOM is quoted, or refused when the dialect cannot quote, only at the start of the text.

import core_pkg "../core"

// The op for values of type `id` in `p`, a plan made for `id`. `.Unsupported` unless `put_cell` writes it as
// one cell.
@(private)
value_op :: proc(p: ^Format_Plan, id: typeid) -> (op: ^Plan_Op, err: Marshal_Error_Kind) {
	if id == nil {
		return nil, .Unsupported
	}
	idx := core_pkg.plan_op_m(p, type_info_of(id)) or_return
	if !is_cell(&p.base, p.ops[idx], p.writes) {
		return nil, .Unsupported
	}
	return &p.ops[idx], .None
}

// The struct op for `id` in `p`, a plan made for `id`. Every field must be one cell `put_cell` writes.
@(private)
struct_op :: proc(p: ^Format_Plan, id: typeid) -> (op: Plan_Op, err: Marshal_Error_Kind) {
	return cell_struct(p, core_pkg.plan_op_m(p, type_info_of(id)) or_return)
}

// One cell written from `w.buf`'s end by the dialect's quoting.
@(private)
put_value_by_dialect :: proc(w: ^Writer, op: ^Plan_Op, data: rawptr) -> Marshal_Error_Kind {
	if w.quotes {
		return put_value(w, op, data, true)
	}
	return put_value(w, op, data, false)
}

// One text as a cell written from `w.buf`'s end.
@(private)
put_string :: proc(w: ^Writer, s: string) -> Marshal_Error_Kind {
	if w.quotes {
		return put_text(w, s, true) if len(s) > 0 else put_empty(w, true)
	}
	return put_text(w, s, false)
}

// The record of `cells` written from `w.buf`'s end. A nil cell is an empty cell.
@(private)
put_strings :: proc(w: ^Writer, cells: []Maybe(string)) -> Marshal_Error_Kind {
	from := len(w.buf)
	for cell, k in cells {
		if k > 0 {
			put(w, w.delim) or_return
		}
		if text, present := cell.?; present {
			if err := put_string(w, text); err != .None {
				return core_pkg.plan_refused_at_index(w, k, err)
			}
		}
	}
	return guard_record(w, from)
}

// The record of the struct at `data` written from `w.buf`'s end, one cell per column. `columns` are header
// fields of `src`; each cell is the field of `row` with the column's name, or empty when no field has it.
// Without `columns`, the struct's fields are written in order. `matched[k]` is set for each field written.
@(private)
put_struct :: proc(w: ^Writer, row: Plan_Op, data: rawptr, src: []byte, dialect: Dialect, columns: []Field, matched: []bool) -> (err: Marshal_Error_Kind) {
	p := w.plan
	from := len(w.buf)
	n := len(columns) if columns != nil else int(row.count)
	for c in 0 ..< n {
		// Sliced per cell: a hook that compiles a new type may move `p.fields`.
		fields := p.fields[row.elem:][:row.count]
		if c > 0 {
			put(w, w.delim) or_return
		}
		k := c
		if columns != nil {
			k = -1
			for f, j in fields {
				if text_is(src, columns[c], dialect, string(p.keys[f.key_lo:f.key_hi])) {
					k = j
					break
				}
			}
		}
		if k < 0 {
			continue
		}
		matched[k] = true
		put_value_by_dialect(w, &p.ops[fields[k].op], rawptr(uintptr(data) + fields[k].offset)) or_return
	}
	return guard_record(w, from)
}
