package csv

// Paths into a CSV text. `find` and `find_column` read the fields a path names from the start of the text.
// The path edits (edit.odin) locate their targets the same way.

import "base:runtime"
import "core:strings"
import core_pkg "../core"

// A built path: a chain of steps.
Path :: core_pkg.Path

// A path as `find`, `find_column` and the path edits take it: text in core's path syntax, or a built `Path`.
//
//	.[3].name   row 3, the column the header names `name`
//	.[3][1]     row 3, column 1
//	.[].name    that column of every row
//	.[3]        the record of row 3 (`remove` only)
//
// Rows count from the first record after the header, columns from 0. A step that is not one of these (a
// negative index, `limit(...)`, a name without a header) is `.Unsupported_Path`.
Path_Spec :: core_pkg.Path_Spec

// Why a path procedure refused: core's `Path_Error_Kind`, shared with JSON. CSV never reports
// `Over_Capacity`, `Type_Mismatch`, `Too_Deep`, `Exists`, `Bad_Comment` or `Internal`.
Path_Error_Kind :: core_pkg.Path_Error_Kind

// A refusal. `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result`. `offset` is set for
// `.Bad_Path` and `.Bad_Row`, and for `.Unplaceable` and `.Encode` (the record, or 0). `encode` is set for
// `.Encode`. Both this package's and JSON's `render_error` write it.
Path_Error :: core_pkg.Path_Error

// The field a path names. `found` is false, with no fault, when the text has no such row or column. `path`
// names one cell: `.[row].name` or `.[row][col]`.
//
// The scan stops at the end of the named record, so the cost is the bytes before it, and nothing is kept for
// the rows it passes. The text after that record is not judged. The record's own bytes are judged at
// `opts.strictness` as `records` judges them; `opts.duplicates` is not read. A fault before the named record is `.Bad_Source`.
@(require_results)
find :: proc(
	src: []byte,
	path: Path_Spec,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (field: Field, found: bool, err: Maybe(Path_Error)) {
	buf: Path_Buf
	t := parse_target(path, &buf, allocator) or_return
	defer delete(t.scratch, allocator)
	header := !opts.no_header
	if t.every_row || t.col == COL_NONE || t.col == COL_NAME && !header {
		return {}, false, Path_Error{kind = .Unsupported_Path}
	}
	it := records(src, opts, allocator)
	defer destroy(&it)
	if it.err != nil {
		return {}, false, finished(&it)
	}
	col, _, has_col := seek_header(&it, t, header, opts.dialect)
	if !has_col {
		return {}, false, finished(&it)
	}
	rec, has_row := seek_row(&it, t.row)
	if !has_row || col >= len(rec.fields) {
		return {}, false, finished(&it)
	}
	return rec.fields[col], true, nil
}

// Append to `out` the field of the column `path` names, from every row that has one: `.[].name` or
// `.[][col]`. A ragged row too short for the column adds nothing.
//
// The fields go in `out`, not in an allocation of the call, so the caller bounds the result and can reuse
// the buffer across calls. The whole text is scanned. A fault is `.Bad_Source` and leaves in `out` the fields before it. A
// header that lacks the name leaves `out` unchanged.
@(require_results)
find_column :: proc(
	src: []byte,
	path: Path_Spec,
	out: ^[dynamic]Field,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (err: Maybe(Path_Error)) {
	buf: Path_Buf
	t := parse_target(path, &buf, allocator) or_return
	defer delete(t.scratch, allocator)
	header := !opts.no_header
	if !t.every_row || t.col == COL_NONE || t.col == COL_NAME && !header {
		return Path_Error{kind = .Unsupported_Path}
	}
	it := records(src, opts, allocator)
	defer destroy(&it)
	if it.err != nil {
		return finished(&it)
	}
	col, _, has_col := seek_header(&it, t, header, opts.dialect)
	if !has_col {
		return finished(&it)
	}
	for rec in next_record(&it) {
		if col < len(rec.fields) {
			if _, aerr := append(out, rec.fields[col]); aerr != nil {
				return core_pkg.PATH_OUT_OF_MEMORY
			}
		}
	}
	return finished(&it)
}

// `COL_NONE`: the path stops at a row. `COL_NAME`: the column is the one `Target.name` names.
@(private)
COL_NONE :: -1
@(private)
COL_NAME :: -2

// What a `Path_Spec` names: row `row` (or `every_row`), and column `col`.
@(private)
Target :: struct {
	row:       int,
	every_row: bool,
	col:       int, // an index, `COL_NONE` or `COL_NAME`
	name:      string, // `COL_NAME`: borrowed from the path text or the buffer a parse decoded into
	scratch:   []u8, // the heap buffer a long escaped name decoded into, if any: the caller frees it
}

// Where a text path is parsed into: its steps and its decoded escaped names. Decoded names never need more
// than `len(text)` bytes.
@(private)
Path_Buf :: struct {
	steps: [core_pkg.MAX_PATH_STEPS]Step,
	names: [256]u8,
}

// The target of `path`, borrowing `buf`. A path of one step names a row, of two a cell or a column.
@(private)
parse_target :: proc(path: Path_Spec, buf: ^Path_Buf, allocator: runtime.Allocator) -> (t: Target, err: Maybe(Path_Error)) {
	p: Path
	switch v in path {
	case string:
		names := buf.names[:]
		if len(v) > len(names) && strings.index_byte(v, '\\') >= 0 {
			heap, aerr := make([]u8, len(v), allocator)
			if aerr != nil {
				return {}, core_pkg.PATH_OUT_OF_MEMORY
			}
			t.scratch, names = heap, heap
		}
		perr: Maybe(Path_Error)
		if p, perr = core_pkg.parse_path(v, buf.steps[:], names); perr != nil {
			delete(t.scratch, allocator)
			// A path with more steps than the buffer holds is not a CSV path.
			if perr.?.kind == .Over_Capacity {
				return {}, Path_Error{kind = .Unsupported_Path}
			}
			return {}, perr
		}
	case Path:
		p = v
	}
	t.col = COL_NONE
	if p.limit != 0 || p.per_element || len(p.steps) < 1 || len(p.steps) > 2 {
		delete(t.scratch, allocator)
		return {}, Path_Error{kind = .Unsupported_Path}
	}
	supported := true
	switch s in p.steps[0] {
	case Index:
		t.row, supported = int(s), s >= 0
	case Any:
		t.every_row = true
	case Name:
		supported = false
	}
	if len(p.steps) == 2 {
		switch s in p.steps[1] {
		case Name:
			t.col, t.name = COL_NAME, string(s)
		case Index:
			t.col, supported = int(s), supported && s >= 0
		case Any:
			supported = false
		}
	}
	if !supported {
		delete(t.scratch, allocator)
		return {}, Path_Error{kind = .Unsupported_Path}
	}
	return
}

// Reads the header record from `it` when there is one, and returns the index of the column `t` names, or
// false when the header lacks the name or there is no record. The header record is `head`, valid until the
// next record. Without a header the column is `t`'s index. A row-only path (`COL_NONE`) names column 0.
@(private)
seek_header :: proc(it: ^Records, t: Target, header: bool, dialect: Dialect) -> (col: int, head: Record, ok: bool) {
	col = max(t.col, 0)
	if header {
		head = next_record(it) or_return
		if t.col == COL_NAME {
			col = column_of(it.src, head.fields, dialect, t.name) or_return
		}
	}
	return col, head, true
}

// The data row `row` of `it`, reading on from where `seek_header` left it.
@(private)
seek_row :: proc(it: ^Records, row: int) -> (rec: Record, ok: bool) {
	for _ in 0 ..= row {
		rec = next_record(it) or_return
	}
	return rec, true
}

// The first of `names`, a header's fields, whose text is `name`.
@(private)
column_of :: proc(src: []byte, names: []Field, dialect: Dialect, name: string) -> (col: int, ok: bool) {
	for f, c in names {
		if text_is(src, f, dialect, name) {
			return c, true
		}
	}
	return -1, false
}

// The scan's fault on `it`, as a path error, or nil when it ended without one.
@(private)
finished :: proc(it: ^Records) -> Maybe(Path_Error) {
	if e, faulted := it.err.?; faulted {
		return path_error_of(e)
	}
	return nil
}

// A scan's fault `e` as a path error.
@(private)
path_error_of :: proc(e: Error) -> Path_Error {
	#partial switch e.kind {
	case .Out_Of_Memory:
		return core_pkg.PATH_OUT_OF_MEMORY
	case .Bad_Option:
		return Path_Error{kind = .Bad_Option}
	}
	return Path_Error{kind = .Bad_Source, syntax = e.kind, offset = e.offset}
}
