package csv

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import core_pkg "../core"
import "../core/bits"

// What `unmarshal` does with a column the struct does not name: `.Ignore` checks its cells as CSV and does not
// read them; `.Refuse` refuses it, `.Unknown_Field` at its header cell.
Unknown_Fields :: core_pkg.Unknown_Fields

// What `unmarshal` does with a header name that two columns spell: core's `Duplicates`.
//
//	.Default  `.Refuse`
//	.Refuse   `.Duplicate_Key` at the second column's header cell
//	.First    the first column fills the field, the later ones are read as unknown columns
//	.Last     the last column fills the field, the earlier ones are read as unknown columns
//	.All      every column fills the field in order, so the last one's cell stays and each is judged as
//	          the field's type
Duplicates :: core_pkg.Duplicates

// How `unmarshal` and `unmarshal_check` read: the zero value reads RFC 4180 with a header, judges every byte,
// refuses a repeated header name, ignores unknown columns and copies strings.
Unmarshal_Opts :: struct {
	dialect:        Dialect,
	// `.Lazy` judges the UTF-8 of every cell a field reads, and of the header, and not of the others.
	strictness:     Strictness,
	limits:         Limits,
	// Which column a repeated header name fills. A column the field does not take is read as unknown
	// (`unknown_fields`: `.Refuse` refuses only a name the struct lacks).
	duplicates:     Duplicates,
	// The first record is data: column k is the struct's field k, and columns past its last field are unknown.
	no_header:      bool,
	unknown_fields: Unknown_Fields,
	// A string with no `""` or escape slices `src` instead of being copied. One with either is decoded into the
	// allocator, and a `cstring` is always copied.
	borrow_strings: bool,
}

// What `unmarshal` refused: its kinds are JSON's. A cell's fault is at the cell, its path `[row].field`, the
// row counted from the first record after the header. A header's fault has the field alone.
Unmarshal_Error_Kind :: core_pkg.Unmarshal_Error_Kind
Unmarshal_Error :: core_pkg.Unmarshal_Error

// Read the records of `src` into `ptr^`, a slice or dynamic array of a struct: one element per record, from
// zero, replacing what `ptr^` held. The header names each column's field (`csv:"name"`, or the field's own
// name).
//
// What a cell is:
//
//	- An empty cell, not quoted, is absent: its field keeps its zero, or is `.Missing_Field` when tagged
//	  `csv:",required"`, as is a required field no column names (at the header). A quoted `""` is a present
//	  empty text. Under `Quoting.None` every empty cell is absent. In a `ragged` dialect a record's cells past
//	  the header's are unknown columns, and the cells it lacks are absent.
//	- A field reads the cell's text (`field_text`), a quoted cell's without its quotes and with each `""` as
//	  one quote, an escaped cell's with each escape as the byte it spells:
//	  `true` or `false` into a bool, `[+-]?digits` into an integer (`.Out_Of_Range` when it does not fit),
//	  a decimal (`1.5`, `.5` or `1.`, with an optional exponent) into an f32 or f64, an enum's member name (or, under
//	  `Plan_Opts.enums = .Int`, its integer), one code point into a rune, any text into a string. Other text is
//	  `.Wrong_Kind`.
//	- A `Maybe` of one of those is set when its cell is present.
//
// A refusal before the read starts (`.Bad_Option`, `.Plan_Mismatch`, `.Unsupported` for a field of any other
// type, `.Out_Of_Memory` lowering the plan) leaves `ptr^` untouched. A later one leaves the records read
// before it, the one refused last. Everything is allocated from `allocator` and nothing is freed: read into an
// arena freed whole. With `plan` nil the plan is this thread's cached one for `T`.
@(require_results)
unmarshal :: proc(
	src: []byte,
	ptr: ^$T,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> (err: Maybe(Unmarshal_Error)) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	if ptr == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	return read_records(src, ptr, T, opts, plan, allocator, false)
}

// Whether `src` reads as a `T` under `opts`: the same judgements and results as `unmarshal`, but that no hook
// runs. It keeps nothing: one record's cells are read into one scratch element, so it allocates the
// element, the record's fields and the column table, whatever the input's size, and the plan with
// `plan` nil.
@(require_results)
unmarshal_check :: proc(
	src: []byte,
	$T: typeid,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
) -> (err: Maybe(Unmarshal_Error)) where intrinsics.type_is_slice(T) || intrinsics.type_is_dynamic_array(T) {
	return read_records(src, (^[dynamic]u8)(nil), T, opts, plan, runtime.nil_allocator(), true)
}

// `unmarshal` into `ptr^` (a `P` whose element is the record), or with `CHECK` into a scratch element
// and no `ptr`.
@(private)
read_records :: proc(
	src: []byte,
	ptr: ^$P,
	root: typeid,
	opts: Unmarshal_Opts,
	plan: ^Type_Plan,
	allocator: runtime.Allocator,
	$CHECK: bool,
) -> (err: Maybe(Unmarshal_Error)) {
	// A lazy read has the scan find the UTF-8 faults and refuses only those in the cells it reads (`judge_utf8`).
	s, dialect_ok := scan_setup(opts.dialect, opts.limits, .Structural if opts.strictness == .Structural else .Strict)
	if !dialect_ok {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	tmp: Type_Plan = ---
	p, ok := plan_for(plan, root, &tmp)
	if !ok {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	defer {
		e, refused := err.?
		plan_done(p, plan, &tmp, refused && e.kind == .Out_Of_Memory)
	}
	r: Reader
	r.src, r.borrow, r.enum_ints, r.allocator = src, opts.borrow_strings || CHECK, p.opts.enums == .Int, allocator
	r.dialect, r.check = opts.dialect, CHECK
	row_reader(&r, p) or_return

	it := records_of(src, s, context.allocator)
	defer records_destroy(&it)
	defer delete(r.columns)
	defer delete(r.cols)
	defer delete(r.required)
	defer delete(r.req_more)
	lazy := opts.strictness == .Lazy
	if lazy {
		it.carry.utf8 = max(int)
	}
	refuse := opts.unknown_fields == .Refuse
	if !opts.no_header {
		header, more := next_record(&it)
		if !more {
			return records_fault(&it, -1)
		}
		if lazy && it.carry.utf8 <= int(header.fields[len(header.fields) - 1].hi) {
			judge_utf8(&r, &it, header, -1) or_return
		}
		read_header(&r, header, refuse, opts.duplicates) or_return
	}
	when CHECK {
		// One element for every record to be read over.
		scratch_bytes, aerr := runtime.mem_alloc(int(r.row.size), int(r.shape.ops[r.shape.root].align), context.allocator)
		if aerr != nil {
			return Unmarshal_Error{kind = .Out_Of_Memory}
		}
		scratch := raw_data(scratch_bytes)
		defer free(scratch, context.allocator)
		rows := 0
	} else {
		list := make([dynamic]intrinsics.type_elem_type(P), allocator)
		defer {
			when intrinsics.type_is_slice(P) {
				ptr^ = list[:]
			} else {
				ptr^ = list
			}
		}
	}
	// Only a lazy or ragged read has work per record past its cells.
	per_record := lazy || opts.dialect.ragged
	for rec in next_record(&it) {
		if r.columns == nil {
			columns_in_order(&r, rec, refuse) or_return
		}
		when CHECK {
			row := rows
			rows += 1
			dest := scratch
		} else {
			row := len(list)
		}
		cells := rec.fields
		if per_record {
			cells = record_cells(&r, &it, rec, row, lazy, refuse) or_return
		}
		when !CHECK {
			if _, aerr := append(&list, intrinsics.type_elem_type(P){}); aerr != nil {
				return Unmarshal_Error{kind = .Out_Of_Memory, offset = rec.at}
			}
			dest := &list[row]
		}
		if kind, at, name, refused := read_row(&r, cells, dest); refused {
			return cell_error(kind, at, row, core_pkg.Name(name))
		}
	}
	when CHECK {
		return records_fault(&it, rows)
	} else {
		return records_fault(&it, len(list))
	}
}

// What one `unmarshal` reads with.
@(private)
Reader :: struct {
	src:       []byte,
	shape:     ^core_pkg.Read_Shape,
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

// The plan's read shape, held to a list of a struct whose fields are cells.
@(private)
row_reader :: proc(r: ^Reader, p: ^Type_Plan) -> Maybe(Unmarshal_Error) {
	shape, serr := core_pkg.read_shape_of(&p.base)
	if serr != nil {
		return serr
	}
	root := &shape.ops[shape.root]
	row := &shape.ops[root.elem]
	if row.kind != .Struct {
		return Unmarshal_Error{kind = .Unsupported}
	}
	for f in shape.fields[row.elem:][:row.count] {
		if !is_cell(shape, &shape.ops[f.op]) {
			err := Unmarshal_Error{kind = .Unsupported}
			core_pkg.unmarshal_path_prepend(&err, core_pkg.Name(f.name))
			core_pkg.unmarshal_path_prepend(&err, core_pkg.Any{})
			return err
		}
	}
	r.shape, r.row = shape, row
	r.required.allocator, r.req_more.allocator = context.allocator, context.allocator
	return nil
}

@(private)
is_cell :: proc(shape: ^core_pkg.Read_Shape, op: ^core_pkg.Shape_Op) -> bool {
	if op.kind == .Union {
		// A `Maybe` of a cell: one arm, with a tag.
		return op.count == 1 && op.tag_size > 0 && is_cell(shape, &shape.ops[shape.fields[op.elem].op])
	}
	return is_cell_kind(op.kind, op.width)
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
			case .Default, .Refuse:
				return cell_error(.Duplicate_Key, cell.lo, -1, core_pkg.Name(fields[k].name))
			case .First:
				continue column
			case .Last:
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
// record's width, since a later record may be wider.
@(private)
columns_in_order :: proc(r: ^Reader, first: Record, refuse: bool) -> (err: Maybe(Unmarshal_Error)) {
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

// Each required field and its column: one no column reads is `.Missing_Field` at the header. A field several
// columns read (`.All`) is present when any of them is, so its later columns go to `req_more`.
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
		} else if core_pkg.shape_field_required(r.shape, r.row, int(k)) {
			if _, err := append(&r.req_more, [2]u32{k, u32(c)}); err != nil {
				return Unmarshal_Error{kind = .Out_Of_Memory, offset = at}
			}
		}
	}
	for f, k in fields {
		if !core_pkg.shape_field_required(r.shape, r.row, k) {
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

// How `read_row` reads a column's cells without `read_cell`: the field types that most cells are.
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

// `-?digits(.digits)?` of at most 15 digits, which is exact in an f64 as the digits over a power of ten
// (Clinger's fast path), so the quotient is the correctly rounded value.
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

// One record's cells, no more than the columns, into the struct at `dest`, or why the cell at `at` of field
// `name` was refused. A ragged record's missing cells are absent, at its end.
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

// A lazy or ragged record's cells: its UTF-8 judged when lazy, cut to the columns when ragged.
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

// Under `.Lazy`: the UTF-8 fault the scan passed is refused when it is in `rec`, in a cell a field reads (or
// any cell of the header, `row` -1). The scan is then pointed at its next fault past `rec`.
@(cold, private)
judge_utf8 :: proc(r: ^Reader, it: ^Records, rec: Record, row: int) -> Maybe(Unmarshal_Error) {
	for cell, c in rec.fields {
		if row >= 0 && (c >= len(r.cols) || r.cols[c].op == nil) {
			continue
		}
		if at, k := utf8_fault(r.src, int(cell.lo), int(cell.hi)); at >= 0 {
			err := Unmarshal_Error{kind = .Syntax, syntax = k, offset = u64(at)}
			if row >= 0 {
				core_pkg.unmarshal_path_prepend(&err, core_pkg.Index(row))
			}
			return err
		}
	}
	// The scan kept only the first fault of the bytes it read, which run to its block's end.
	from := int(rec.fields[len(rec.fields) - 1].hi) + 1
	it.carry.utf8 = max(int)
	if from < len(r.src) {
		if at, _ := utf8_fault(r.src, from, it.block + 64); at >= 0 {
			it.carry.utf8 = at
		}
	}
	return nil
}

// The iterator's fault, if it ended on one, at record `row` (-1 for the header).
@(private)
records_fault :: proc(it: ^Records, row: int) -> Maybe(Unmarshal_Error) {
	e, faulted := it.err.?
	if !faulted {
		return nil
	}
	#partial switch e.kind {
	case .Out_Of_Memory:
		return Unmarshal_Error{kind = .Out_Of_Memory}
	case .Bad_Option:
		return Unmarshal_Error{kind = .Bad_Option}
	}
	err := Unmarshal_Error{kind = .Syntax, syntax = e.kind, offset = e.offset}
	if row >= 0 {
		core_pkg.unmarshal_path_prepend(&err, core_pkg.Index(row))
	}
	return err
}

@(private)
cell_error :: proc(kind: Unmarshal_Error_Kind, at: u64, row: int, name: Maybe(core_pkg.Name)) -> Unmarshal_Error {
	err := Unmarshal_Error{kind = kind, offset = at}
	if n, ok := name.?; ok {
		core_pkg.unmarshal_path_prepend(&err, n)
	}
	if row >= 0 {
		core_pkg.unmarshal_path_prepend(&err, core_pkg.Index(row))
	}
	return err
}

// A cell's text as written, a quoted one's without its quotes: what a path names it by.
@(private)
authored :: proc(r: ^Reader, cell: Field) -> string {
	text := r.src[cell.lo:cell.hi]
	if len(text) > 0 && text[0] == '"' && r.dialect.quoting == .Quotes {
		text = text[1:len(text) - 1]
	}
	return string(text)
}

// A present cell into the field op `op` at `dest`. The common kinds have their own small procs, so a cell
// pays for the frame of the one kind it is.
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

// `text`, an integer of at most 64 bits, into the `width`-byte `signed` or unsigned integer at `dest`.
@(private)
store_int :: #force_inline proc(text: string, dest: rawptr, width: u8, signed: bool) -> core_pkg.Shape_Fault {
	mag, over, neg := read_int(text) or_return
	if over || mag > u128(max(u64)) {
		return .Out_Of_Range
	}
	return core_pkg.shape_int_store(u64(mag), neg, dest, width, signed)
}

@(private)
read_float_cell :: proc(r: ^Reader, op: ^core_pkg.Shape_Op, cell: Field, dest: rawptr) -> core_pkg.Shape_Fault {
	text := authored(r, cell)
	if !is_decimal(text) {
		return .Wrong_Kind
	}
	if op.width == 4 {
		x, _ := strconv.parse_f32(text)
		if math.is_inf(x) {
			return .Out_Of_Range
		}
		(^f32)(dest)^ = x
	} else {
		x, _ := strconv.parse_f64(text)
		if math.is_inf(x) {
			return .Out_Of_Range
		}
		(^f64)(dest)^ = x
	}
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
		if r.dialect.escapes == .Backslash && len(text) == 2 && text[0] == '\\' {
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
		fault, refused := r.shape.hooks[op.elem](transmute([]byte)s, dest, r.allocator).?
		if quote {
			delete(s, r.allocator)
		}
		return fault if refused else .None
	}
	return .None
}

// A quote in the text of a quoted cell is a `""`: only a string, a cstring or the rune `"` holds one.
@(private)
has_pair :: #force_inline proc(cell: Field, text: string) -> bool {
	return cell.hi - cell.lo != u64(len(text)) && holds(text, '"')
}

// Whether the cell's text holds a `""` or an escape, which `field_text` decodes.
@(private)
needs_decoding :: #force_inline proc(r: ^Reader, cell: Field, text: string) -> bool {
	// `text` is `authored`'s, a slice of `src`.
	lo := int(uintptr(raw_data(text)) - uintptr(raw_data(r.src)))
	if cell.hi - cell.lo != u64(len(text)) && holds_span(r.src, lo, len(text), '"') {
		return true
	}
	return r.dialect.escapes == .Backslash && holds_span(r.src, lo, len(text), '\\')
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
	// 16-byte windows, the last one overlapping its neighbour.
	for i := 0; i + 16 < n; i += 16 {
		if bits.any_eq(bits.load(p[i:]), c) {
			return true
		}
	}
	return bits.any_eq(bits.load(p[n - 16:]), c)
}

// The cell's text as a string: decoded when it holds a `""` or an escape, else borrowed or copied.
@(private)
cell_string :: proc(r: ^Reader, cell: Field, text: string, quote, borrow: bool) -> (string, runtime.Allocator_Error) {
	if quote && !r.check {
		decoded, _, err := field_text(r.src, cell, r.dialect, r.allocator)
		return string(decoded), err
	}
	if borrow {
		return text, nil
	}
	return strings.clone(text, r.allocator)
}

// `[+-]?digits` as a magnitude and a sign. `over`: it passed 128 bits. A text that is not one is `.Wrong_Kind`.
@(private)
read_int :: proc(text: string) -> (mag: u128, over, neg: bool, fault: core_pkg.Shape_Fault) {
	digits := text
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {
		neg = digits[0] == '-'
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return 0, false, false, .Wrong_Kind
	}
	if len(digits) <= 19 {
		// 19 digits are below 10^19, which a u64 holds: no overflow to track.
		small: u64
		for c in transmute([]byte)digits {
			d := c - '0'
			if d > 9 {
				return 0, false, false, .Wrong_Kind
			}
			small = small * 10 + u64(d)
		}
		return u128(small), false, neg, .None
	}
	digits_only: bool
	if mag, over, digits_only = core_pkg.fold_digits(transmute([]byte)digits, 0, u64(len(digits)), u128); !digits_only {
		return 0, false, false, .Wrong_Kind
	}
	return mag, over, neg, .None
}

// `[+-]?(digits(.digits?)?|.digits)([eE][+-]?digits)?`: what a float cell may be, `.5` and `1.` as other
// writers spell them.
@(private)
is_decimal :: proc(text: string) -> bool {
	i := 0
	digits :: proc(text: string, i: ^int) -> bool {
		start := i^
		for i^ < len(text) && text[i^] - '0' <= 9 {
			i^ += 1
		}
		return i^ > start
	}
	if i < len(text) && (text[i] == '-' || text[i] == '+') {
		i += 1
	}
	whole := digits(text, &i)
	fraction := false
	if i < len(text) && text[i] == '.' {
		i += 1
		fraction = digits(text, &i)
	}
	if !whole && !fraction {
		return false
	}
	if i < len(text) && (text[i] == 'e' || text[i] == 'E') {
		i += 1
		if i < len(text) && (text[i] == '-' || text[i] == '+') {
			i += 1
		}
		if !digits(text, &i) {
			return false
		}
	}
	return i == len(text)
}

