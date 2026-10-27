package csv

// Binding a header's columns to the fields the plan's row shape reads: the column table, the required fields,
// and the per-column op the row read writes through.

import "base:runtime"
import core_pkg "../core"

// What one `unmarshal` reads with.
@(private)
Reader :: struct {
	src:       []byte,
	// The plan's read shape, copied (see `row_reader`).
	shape:     core_pkg.Read_Shape,
	row:       ^core_pkg.Shape_Op, // the element's struct op
	// The field each column reads (`core_pkg.NO_FIELD` for none), and the required fields, each with its
	// column.
	columns:   []u32,
	cols:      []Col, // `columns`, bound to what each column's field reads
	required:  [dynamic][2]u32,
	req_more:  [dynamic][2]u32, // the later columns of a required field that several columns read, each with its field
	allocator: runtime.Allocator,
	dialect:   Dialect,
	borrow:    bool,
	enum_ints: bool,
	// `unmarshal_check`: nothing is kept, so no decoded string, `cstring` or hook result is made.
	check:     bool,
}

// The plan's read shape, whose row must be a struct of cells: `LIST` reads the list's element, else the struct.
@(private)
row_reader :: proc(r: ^Reader, p: ^core_pkg.Type_Plan, $LIST: bool) -> Maybe(Unmarshal_Error) {
	shape, serr := core_pkg.read_shape_of(p)
	if serr != nil {
		return serr
	}
	// Copied so the reader survives a move of the handle that owns the plan.
	r.shape = shape^
	row := &r.shape.ops[r.shape.root]
	when LIST {
		row = &r.shape.ops[row.elem]
	}
	if row.kind != .Struct {
		return Unmarshal_Error{kind = .Unsupported}
	}
	for f in r.shape.fields[row.elem:][:row.count] {
		if !is_cell(p, p.ops[f.op], nil) {
			err := Unmarshal_Error{kind = .Unsupported}
			core_pkg.unmarshal_path_prepend(&err, core_pkg.Name(f.name))
			core_pkg.unmarshal_path_prepend(&err, core_pkg.Any{})
			return err
		}
	}
	r.row = row
	r.required.allocator, r.req_more.allocator = context.allocator, context.allocator
	return nil
}

// The header's columns: each names the field it reads.
@(private)
read_header :: proc(r: ^Reader, header: Record, refuse: bool, duplicates: Duplicates) -> (err: Maybe(Unmarshal_Error)) {
	fields := r.shape.fields[r.row.elem:][:r.row.count]
	r.columns = make_columns(len(header.fields), header.at) or_return
	// The column that last took each field, so a repeated name is found without a scan of the columns.
	taken := make_columns(len(fields), header.at) or_return
	defer delete(taken)
	column: for cell, c in header.fields {
		text, escaped, aerr := field_text(r.src, cell, r.dialect, context.allocator)
		if aerr != nil {
			return Unmarshal_Error{kind = .Out_Of_Memory, offset = cell.lo}
		}
		defer if escaped {
			delete(text)
		}
		k := 0
		for k < len(fields) && fields[k].name != string(text) {
			k += 1
		}
		if k == len(fields) {
			if refuse {
				return cell_error(.Unknown_Field, cell.lo, -1, core_pkg.Name(authored(r, cell)))
			}
			continue
		}
		if taken[k] != core_pkg.NO_FIELD {
			switch duplicates {
			case .Refuse:
				return cell_error(.Duplicate_Key, cell.lo, -1, core_pkg.Name(fields[k].name))
			case .First:
				continue column
			case .Default, .Last:
				r.columns[taken[k]] = core_pkg.NO_FIELD
			case .All:
			}
		}
		taken[k] = u32(c)
		r.columns[c] = u32(k)
	}
	required_columns(r, header.at) or_return
	return bind_cols(r)
}

// Without a header, column k reads field k. A ragged text has columns for every field, whatever the first
// record's width, since a later record may be wider. A refusal binds nothing, so the next record binds again.
@(private)
columns_in_order :: proc(r: ^Reader, first: Record, refuse: bool) -> (err: Maybe(Unmarshal_Error)) {
	defer if err != nil {
		delete(r.columns)
		r.columns = nil
		clear(&r.required)
		clear(&r.req_more)
	}
	width := len(first.fields)
	if r.dialect.ragged {
		width = max(width, int(r.row.count))
	}
	r.columns = make_columns(width, first.at) or_return
	for &col, c in r.columns {
		if c < int(r.row.count) {
			col = u32(c)
		} else if refuse {
			return cell_error(.Unknown_Field, first.fields[c].lo, 0, nil)
		}
	}
	required_columns(r, first.at) or_return
	return bind_cols(r)
}

@(private)
make_columns :: proc(n: int, at: u64) -> (columns: []u32, err: Maybe(Unmarshal_Error)) {
	aerr: runtime.Allocator_Error
	if columns, aerr = make([]u32, n, context.allocator); aerr != nil {
		return nil, Unmarshal_Error{kind = .Out_Of_Memory, offset = at}
	}
	for &col in columns {
		col = core_pkg.NO_FIELD
	}
	return
}

// Each required field and its column. A required field no column reads is `.Missing_Field` at the header. A
// field several columns read (`.All`) is present when any of them is, so its later columns go to `req_more`.
@(private)
required_columns :: proc(r: ^Reader, at: u64) -> Maybe(Unmarshal_Error) {
	fields := r.shape.fields[r.row.elem:][:r.row.count]
	first := make_columns(len(fields), at) or_return
	defer delete(first)
	for k, c in r.columns {
		if k == core_pkg.NO_FIELD {
			continue
		}
		if first[k] == core_pkg.NO_FIELD {
			first[k] = u32(c)
		} else if core_pkg.shape_field_required(&r.shape, r.row, int(k)) {
			if _, err := append(&r.req_more, [2]u32{k, u32(c)}); err != nil {
				return Unmarshal_Error{kind = .Out_Of_Memory, offset = at}
			}
		}
	}
	for f, k in fields {
		if !core_pkg.shape_field_required(&r.shape, r.row, k) {
			continue
		}
		if first[k] == core_pkg.NO_FIELD {
			return cell_error(.Missing_Field, at, -1, core_pkg.Name(f.name))
		}
		if _, err := append(&r.required, [2]u32{u32(k), first[k]}); err != nil {
			return Unmarshal_Error{kind = .Out_Of_Memory, offset = at}
		}
	}
	return nil
}

// The field types most cells have, which `read_row` reads without `read_cell`.
@(private)
Fast :: enum u8 {
	None,
	Int64,       // an i64
	Int64_Maybe, // a `Maybe(i64)`
	Float64,     // an f64
	String,      // a string, read as a slice of `src` when its cell is not quoted
}

@(private)
Col :: struct {
	op:       ^core_pkg.Shape_Op, // the field's op, nil for a column no field reads
	name:     string,
	offset:   uintptr,
	union_op: ^core_pkg.Shape_Op, // `.Int64_Maybe`: the `Maybe`, whose tag is `tag`
	tag:      u32,
	fast:     Fast,
}

@(private)
bind_cols :: proc(r: ^Reader) -> Maybe(Unmarshal_Error) {
	cols, err := make([]Col, len(r.columns), context.allocator)
	if err != nil {
		return Unmarshal_Error{kind = .Out_Of_Memory}
	}
	for k, c in r.columns {
		if k == core_pkg.NO_FIELD {
			continue
		}
		f := &r.shape.fields[r.row.elem + k]
		op := &r.shape.ops[f.op]
		col := Col{op = op, name = f.name, offset = uintptr(f.offset)}
		switch {
		case op.kind == .Int && op.width == 8:
			col.fast = .Int64
		case op.kind == .Float && op.width == 8:
			col.fast = .Float64
		case op.kind == .String && r.borrow && r.dialect.escapes == .None:
			col.fast = .String
		case op.kind == .Union:
			arm := &r.shape.fields[op.elem]
			if inner := &r.shape.ops[arm.op]; inner.kind == .Int && inner.width == 8 {
				col.fast, col.union_op, col.tag = .Int64_Maybe, op, arm.offset
			}
		}
		cols[c] = col
	}
	r.cols = cols
	return nil
}
