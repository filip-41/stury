package csv

// The edits `set`, `insert`, `remove` and the span edit `splice`. Each returns a new buffer that keeps every
// byte of the source it did not target unchanged.
//
// `set`, `insert` and `remove` judge the source as `records` reads it under `opts`: dialect, strictness,
// limits and `no_header`; a fault is `.Bad_Source`. A header name two columns share follows `opts.duplicates`,
// refused under `.Default` as under `.Refuse` (`.Bad_Source` with `syntax = .Duplicate_Key` at the repeated
// header cell); `.All` edits every column of the name.

import "base:runtime"
import core_pkg "../core"

// One edit: `src[lo:hi]` becomes `bytes`.
Edit :: core_pkg.Edit

// Where `insert` puts its record: a row index (a name is `.Unplaceable`, as a CSV text's rows have none).
Insert_At :: core_pkg.Insert_At

// `insert`'s `at` for after the last row, whatever the count.
APPEND :: core_pkg.APPEND

// `src` with every edit applied.
//
//	- Edits must be sorted by `lo` and disjoint (`edits[i].hi <= edits[i+1].lo`, every `hi <= len(src)`).
//	- The result is validated `.Strict` in `opts.dialect`, since a span need not be a whole field; no other field
//	  of `opts` is read. A result that is not CSV is `.Bad_Result`, with the scan's fault in `syntax` and `offset`.
@(require_results)
splice :: proc(src: []byte, edits: []Edit, opts := Read_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	if _, ok := scan_setup(opts.dialect, {}); !ok {
		return nil, Path_Error{kind = .Bad_Option}
	}
	out = core_pkg.edits_apply_checked(src, edits, allocator) or_return
	return core_pkg.judged_result(out, validate(out, {dialect = opts.dialect}), allocator)
}

// Replace the cell `path` names, or that column's cell in every row, with `value`, spelled as `marshal` spells
// a cell. `value` is a bool, integer, float, string, enum, rune, or a `Maybe` of one.
//
//	- The cell is quoted or escaped as the dialect needs. An empty string is `""` where cells are quoted.
//	- A value the dialect cannot spell is `.Encode` with `Marshal_Error.Unwritable`: a delimiter, CR or LF the
//	  dialect can neither quote nor escape, or an empty cell that would leave a record of one empty field,
//	  which reads back as no record.
//	- A first cell starting with the comment byte is quoted or escaped, or else `.Encode`.
//	- A path naming a row or column the text lacks is `.Not_Found`. `.[row].name` needs the header; set
//	  `no_header` for a text whose first record is data.
@(require_results)
set :: proc(
	src: []byte,
	path: Path_Spec,
	value: any,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_set(src, path, value, opts, core_pkg.watched(&watch))
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_set :: proc(
	src: []byte,
	path: Path_Spec,
	value: any,
	opts: Read_Opts,
	allocator: runtime.Allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	dialect, header := opts.dialect, !opts.no_header
	buf: core_pkg.Path_Buf
	t := parse_target(path, &buf, allocator) or_return
	defer target_free(&t, allocator)
	if t.col == COL_NONE || t.col == COL_NAME && !header {
		return nil, Path_Error{kind = .Unsupported_Path}
	}
	if value.id == nil {
		return nil, Path_Error{kind = .Encode, encode = .Unsupported}
	}
	check_source(src, opts) or_return
	sites := make([dynamic]Site, allocator)
	defer delete(sites)
	sites_of(src, &t, opts, header, false, &sites) or_return
	core_pkg.edit_found(len(sites)) or_return
	tmp: Type_Plan = ---
	p, _ := plan_for(nil, value.id, &tmp)
	merr: Marshal_Error
	defer plan_done(p, nil, &tmp, merr == .Out_Of_Memory)
	op: ^Plan_Op
	if op, merr = value_op(p, value.id); merr != .None {
		return nil, Path_Error{kind = .Encode, encode = merr}
	}
	w, _ := spell_writer(dialect, p, make([dynamic]u8, allocator))
	defer delete(w.buf)
	// Only the text's first field can start the text with a BOM.
	w.at_start = sites[0].field.lo == u64(core_pkg.bom_len(src))
	if merr = put_value_by_dialect(&w, op, value.data); merr == .None && sites[0].col == 0 {
		merr = guard_record(&w, 0)
	}
	if merr != .None {
		return nil, Path_Error{kind = .Encode, encode = merr}
	}
	edits := make([dynamic]Edit, 0, len(sites), allocator)
	defer delete(edits)
	for s in sites {
		if len(w.buf) == 0 && s.n == 1 {
			return nil, Path_Error{kind = .Encode, encode = .Unwritable, offset = s.rec_at}
		}
		append(&edits, Edit{lo = s.field.lo, hi = s.field.hi, bytes = w.buf[:]})
	}
	return edited(src, edits[:], allocator)
}

// Add `row` as data row `at` of the records `path` names, which is `.` (any other path is `.Unsupported_Path`):
// before the row now at `at`, or after the last row when `at` is the row count or `APPEND`. The record ends with
// the same line break as the text's first record, or LF when that has none.
//
//	- `row` is a struct or a `[]string`. A struct's fields fill the header's columns by name (`csv:"name"` or
//	  the field's name), with an empty cell for a column no field names. Without a header (`header` false) its
//	  fields are the columns in order. A `[]string` gives one cell per column.
//	- Cells are spelled as `set` spells them. A first cell starting with the comment byte is quoted or
//	  escaped, or else `.Encode`.
//	- A record whose cells do not match the columns (a `[]string` of another length, a struct field no column
//	  names) is `.Bad_Row`, with the cell count or the field's index in `offset`. A `ragged` dialect accepts a
//	  `[]string` of any length.
//	- A name, a negative `at`, one past the row count, and a text with no header record when `header` is set are
//	  `.Unplaceable`.
//	- Appended to a text that does not end in a line break, the record gets a break before it and none after.
//	- `opts.duplicates` is not read: the row's fields find their columns by name, and every column of that name is
//	  written.
@(require_results)
insert :: proc(
	src: []byte,
	path: Path_Spec,
	at: Insert_At,
	row: any,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_insert(src, path, at, row, opts, core_pkg.watched(&watch))
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_insert :: proc(
	src: []byte,
	path: Path_Spec,
	at: Insert_At,
	row: any,
	opts: Read_Opts,
	allocator: runtime.Allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	dialect := opts.dialect
	buf: core_pkg.Path_Buf
	p := core_pkg.path_resolve(path, &buf, allocator) or_return
	delete(buf.heap, allocator)
	if len(p.steps) > 0 || p.limit != 0 {
		return nil, Path_Error{kind = .Unsupported_Path}
	}
	index, is_index := at.(int)
	if !is_index {
		return nil, Path_Error{kind = .Unplaceable}
	}
	check_source(src, opts) or_return
	spot := insert_spot(src, index, opts, allocator) or_return
	defer delete(spot.columns, allocator)
	text := spell_record(row, src, dialect, spot, allocator) or_return
	defer delete(text, allocator)
	return edited(src, {{lo = spot.pos, hi = spot.pos, bytes = text}}, allocator)
}

// Remove the record `path` names (`.[row]`) with its line break, or remove the field it names (`.[].name`,
// `.[][col]`) from every record, the header included, with one adjacent delimiter.
//
//	- A record with no such field keeps its bytes. A row or column the text lacks is `.Not_Found`.
//	- Removing a record that is the last leaves the one before it as the text's end.
//	- A column removal that would leave a record reading as no record is `.Unplaceable`, with the record in
//	  `offset`. That happens when removing the only column, when one empty field is left, or when the new first
//	  field starts with the comment byte.
@(require_results)
remove :: proc(
	src: []byte,
	path: Path_Spec,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_remove(src, path, opts, core_pkg.watched(&watch))
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_remove :: proc(
	src: []byte,
	path: Path_Spec,
	opts: Read_Opts,
	allocator: runtime.Allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	dialect, header := opts.dialect, !opts.no_header
	buf: core_pkg.Path_Buf
	t := parse_target(path, &buf, allocator) or_return
	defer target_free(&t, allocator)
	whole_record := !t.every_row && t.col == COL_NONE
	if !whole_record && !(t.every_row && t.col != COL_NONE) || t.col == COL_NAME && !header {
		return nil, Path_Error{kind = .Unsupported_Path}
	}
	check_source(src, opts) or_return
	sites := make([dynamic]Site, allocator)
	defer delete(sites)
	sites_of(src, &t, opts, header, !whole_record, &sites) or_return
	core_pkg.edit_found(len(sites)) or_return
	if len(t.cols) > 1 {
		return remove_columns(src, t.cols, opts, allocator)
	}
	edits := make([dynamic]Edit, 0, len(sites), allocator)
	defer delete(edits)
	for s in sites {
		switch {
		case whole_record:
			append(&edits, Edit{lo = s.rec_at, hi = line_end(src, s.rec_hi)})
		case s.n == 1 || leaves_blank(s) || s.col == 0 && opens_comment(src, s.second, dialect.comment):
			return nil, Path_Error{kind = .Unplaceable, offset = s.rec_at}
		case s.col + 1 < s.n:
			append(&edits, Edit{lo = s.field.lo, hi = s.after})
		case:
			append(&edits, Edit{lo = s.before, hi = s.field.hi})
		}
	}
	return edited(src, edits[:], allocator)
}

// `remove` of each column in `cols` of every record, a column of a repeated name under `.All`: one pass per column,
// the last first, so the earlier ones keep their index.
@(private = "file")
remove_columns :: proc(src: []byte, cols: []int, opts: Read_Opts, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	out = src
	for i := len(cols) - 1; i >= 0; i -= 1 {
		steps := [2]Step{Any{}, Index(cols[i])}
		next, nerr := watched_remove(out, Path{steps = steps[:]}, opts, allocator)
		if raw_data(out) != raw_data(src) {
			delete(out, allocator)
		}
		out = next
		nerr or_return
	}
	return
}

// Whether the field `f` of `src` starts with the comment byte `comment`, which a record's first field must not.
@(private)
opens_comment :: proc(src: []byte, f: Field, comment: byte) -> bool {
	return comment != 0 && f.lo < f.hi && src[f.lo] == comment
}

// Whether removing the field of `s` leaves a record of one empty field, which reads as no record.
@(private)
leaves_blank :: proc(s: Site) -> bool {
	rest := s.second if s.col == 0 else s.first
	return s.n == 2 && rest.lo == rest.hi
}

// A field of one record, with what removing or replacing it needs to know about the record.
@(private)
Site :: struct {
	field:  Field,
	before: u64,   // where the previous field ends
	after:  u64,   // where the next field starts
	first:  Field, // the record's first field
	second: Field, // the record's second field
	rec_at: u64,   // where the record's line starts
	rec_hi: u64,   // where its last field ends
	n:      int,   // its field count
	col:    int,
}

// The sites of what `t` names: the fields of its columns (`target_columns`) in the data row, or in every row
// (with the header when `with_header`). A row-only path (`COL_NONE`) names the row's first field.
@(private)
sites_of :: proc(src: []byte, t: ^Target, opts: Read_Opts, header, with_header: bool, out: ^[dynamic]Site) -> Maybe(Path_Error) {
	it := records(src, opts, out.allocator)
	defer destroy(&it)
	head: Record
	if header {
		more: bool
		if head, more = next_record(&it); !more {
			return finished(&it)
		}
	}
	if e, bad := target_columns(t, src, head.fields, opts.dialect, opts.duplicates, .Refuse, out.allocator).?; bad {
		return core_pkg.path_error_of(e)
	}
	if header && with_header {
		add_sites(out, head, t.cols) or_return
	}
	if t.every_row {
		for rec in next_record(&it) {
			add_sites(out, rec, t.cols) or_return
		}
	} else if rec, ok := seek_row(&it, t.row); ok {
		add_sites(out, rec, t.cols) or_return
	}
	return finished(&it)
}

@(private)
add_sites :: proc(out: ^[dynamic]Site, rec: Record, cols: []int) -> Maybe(Path_Error) {
	for c in cols {
		add_site(out, rec, max(c, 0)) or_return
	}
	return nil
}

@(private)
add_site :: proc(out: ^[dynamic]Site, rec: Record, col: int) -> Maybe(Path_Error) {
	n := len(rec.fields)
	if col >= n {
		return nil
	}
	s := Site{field = rec.fields[col], first = rec.fields[0], rec_at = rec.at, rec_hi = rec.fields[n - 1].hi, n = n, col = col}
	if col > 0 {
		s.before = rec.fields[col - 1].hi
	}
	if col + 1 < n {
		s.after = rec.fields[col + 1].lo
	}
	if n > 1 {
		s.second = rec.fields[1]
	}
	if _, err := append(out, s); err != nil {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	return nil
}

// Where `insert` puts its record.
@(private)
Spot :: struct {
	pos:      u64,     // the record's first byte
	crlf:     bool,    // the first record ends in CRLF
	width:    int,     // the first record's field count, 0 for no record
	columns:  []Field, // the header's fields, nil without a header
	// The record goes at the end of a text with no final line break: the break goes before the record.
	unbroken: bool,
}

// The caller frees `columns`.
@(private)
insert_spot :: proc(src: []byte, at: int, opts: Read_Opts, allocator: runtime.Allocator) -> (spot: Spot, err: Maybe(Path_Error)) {
	if at < 0 {
		return {}, Path_Error{kind = .Unplaceable}
	}
	header := !opts.no_header
	it := records(src, opts, allocator)
	defer destroy(&it)
	rows, first := 0, true
	for rec in next_record(&it) {
		if first {
			first = false
			last := rec.fields[len(rec.fields) - 1].hi
			spot.width, spot.crlf = len(rec.fields), last < u64(len(src)) && src[last] == '\r'
			if header {
				cols, aerr := make([]Field, len(rec.fields), allocator)
				if aerr != nil {
					return {}, core_pkg.PATH_OUT_OF_MEMORY
				}
				copy(cols, rec.fields)
				spot.columns = cols
				continue
			}
		}
		if rows == at {
			spot.pos = rec.at
			return
		}
		rows += 1
	}
	err = finished(&it)
	if err == nil && (header && spot.columns == nil || at != APPEND && at != rows) {
		err = Path_Error{kind = .Unplaceable}
	}
	if err != nil {
		delete(spot.columns, allocator)
		return {}, err
	}
	spot.pos = u64(len(src))
	spot.unbroken = len(src) > core_pkg.bom_len(src) && src[len(src) - 1] != '\n'
	return
}

// The bytes `insert` puts at `spot`: the record `row` spells, and its line break.
@(private)
spell_record :: proc(row: any, src: []byte, dialect: Dialect, spot: Spot, allocator: runtime.Allocator) -> (text: []byte, err: Maybe(Path_Error)) {
	if row.id == nil {
		return nil, encode_error(.Unsupported)
	}
	cells, is_cells := row.([]string)
	tmp: Type_Plan = ---
	p: ^Type_Plan
	if !is_cells {
		p, _ = plan_for(nil, row.id, &tmp)
	}
	defer if p != nil {
		plan_done(p, nil, &tmp, is_oom(err))
	}
	w, _ := spell_writer(dialect, p, make([dynamic]u8, allocator))
	w.at_start = spot.pos == u64(core_pkg.bom_len(src))
	if spot.unbroken {
		append(&w.buf, line_break(spot.crlf))
	}
	from := len(w.buf)
	if is_cells {
		err = put_cells(&w, cells, dialect, spot)
	} else {
		err = put_struct_row(&w, row, src, dialect, spot)
	}
	if err == nil && len(w.buf) == from {
		err = encode_error(.Unwritable, spot.pos)
	}
	if err != nil {
		delete(w.buf)
		return nil, err
	}
	if !spot.unbroken {
		append(&w.buf, line_break(spot.crlf))
	}
	return w.buf[:], nil
}

// The record of `cells`, whose count must equal the column count.
@(private)
put_cells :: proc(w: ^Writer, cells: []string, dialect: Dialect, spot: Spot) -> Maybe(Path_Error) {
	if len(cells) != spot.width && spot.width > 0 && !dialect.ragged {
		return Path_Error{kind = .Bad_Row, offset = u64(len(cells))}
	}
	if merr := put_strings(w, cells); merr != .None {
		return encode_error(merr)
	}
	return nil
}

// The struct at `row.data` as a record of the header's columns, or of its fields in order without a header.
@(private)
put_struct_row :: proc(w: ^Writer, row: any, src: []byte, dialect: Dialect, spot: Spot) -> Maybe(Path_Error) {
	op, merr := struct_op(w.plan, row.id)
	if merr != .None {
		return encode_error(merr)
	}
	if spot.columns == nil && int(op.count) != spot.width && spot.width > 0 && !dialect.ragged {
		return Path_Error{kind = .Bad_Row, offset = u64(op.count)}
	}
	matched, aerr := make([]bool, op.count)
	if aerr != nil {
		return encode_error(.Out_Of_Memory)
	}
	defer delete(matched)
	if merr = put_struct(w, op, row.data, src, dialect, spot.columns, matched); merr != .None {
		return encode_error(merr)
	}
	for ok, k in matched {
		if !ok {
			return Path_Error{kind = .Bad_Row, offset = u64(k)}
		}
	}
	return nil
}

@(private)
encode_error :: proc(e: Marshal_Error, at: u64 = 0) -> Path_Error {
	return Path_Error{kind = .Encode, encode = e, offset = at}
}

@(private)
is_oom :: proc(err: Maybe(Path_Error)) -> bool {
	e, faulted := err.?
	return faulted && (e.kind == .Out_Of_Memory || e.kind == .Encode && e.encode == .Out_Of_Memory)
}

// The path error when `src` is not CSV as `records` reads it under `opts`.
@(private)
check_source :: proc(src: []byte, opts: Read_Opts) -> Maybe(Path_Error) {
	if e, bad := validate(src, opts).?; bad {
		return path_error_of(e)
	}
	return nil
}

// Where the line break after a record ending at `hi` ends: CRLF, LF or the end of `src`.
@(private)
line_end :: proc(src: []byte, hi: u64) -> u64 {
	i := hi
	if i < u64(len(src)) && src[i] == '\r' {
		i += 1
	}
	if i < u64(len(src)) && src[i] == '\n' {
		i += 1
	}
	return i
}

@(private)
line_break :: proc(crlf: bool) -> string {
	return "\r\n" if crlf else "\n"
}

// `edits` applied to `src`. An edit that makes the result start with a BOM `src` did not have is refused,
// since the BOM would be read as the text's own.
@(private)
edited :: proc(src: []byte, edits: []Edit, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	out, err = core_pkg.edits_apply_checked(src, edits, allocator)
	if err == nil && core_pkg.bom_len(out) != core_pkg.bom_len(src) {
		delete(out, allocator)
		return nil, Path_Error{kind = .Unplaceable}
	}
	return
}
