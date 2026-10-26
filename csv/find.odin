package csv

// Paths into a CSV text. `query` answers a path over a `Document`'s field spans; `find` and `find_column`
// stream a path over the text from its start, with no document. The path edits (edit.odin) locate their
// targets the same way.

import "base:runtime"
import "core:strings"
import core_pkg "../core"

// A built path: a chain of steps.
Path :: core_pkg.Path

// A path as `query`, `find`, `find_column` and the path edits take it: text in core's path syntax, or a built
// `Path`.
//
//	.[3].name   row 3, the column the header names `name`
//	.[3][1]     row 3, column 1
//	.[], .[3]   every row, or row 3: the record's own span
//	.[].name    that column of every row
//
// A text path starts at the root `.`, as in `json`. Rows count from the first record after the header, columns
// from 0. `query`, `find` and `find_column` take `limit(...)`, which cuts the answers (0 is every one).
//
// A step that is not one of these (a negative index, `.[][]`, a name without a header) is `.Unsupported_Path`
// from `query` and `.Bad_Option` from `find` and `find_column`; those two also report `.Bad_Path`,
// `.Over_Capacity` and `.Out_Of_Memory`, and the scan's fault with the kind and offset it was found at.
//
// A header name two columns share follows `opts.duplicates` (`query`: the `duplicates` `build` was given):
// the first column under `.Default` and `.First`, the last under `.Last` and `.All`, and under `.Refuse`
// `.Duplicate_Key` at the repeated header cell (from `query`, `.Bad_Source` with `syntax = .Duplicate_Key`).
//
// A path that lands nothing appends nothing, and a ragged row too short for the column adds nothing. Answers
// borrow `src` (`query`: `doc.src`).
Path_Spec :: core_pkg.Path_Spec

// Why a path procedure refused: core's `Path_Error_Kind`, shared with JSON. `query` reports `.Bad_Path`,
// `.Unsupported_Path`, `.Over_Capacity`, `.Bad_Source` and `.Out_Of_Memory`; the edits report only the kinds
// their docs list.
Path_Error_Kind :: core_pkg.Path_Error_Kind

// A refusal. `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result`. `offset` is set for
// `.Bad_Path` and `.Bad_Row` (the byte of the path text), and for `.Unplaceable` and `.Encode` (the record, or
// 0). `encode` is set for `.Encode`. Both this package's and JSON's `render_error` write it.
Path_Error :: core_pkg.Path_Error

// One answer: a span of the text, the record whose span holds it (`NO_OWNER` when none does), and how the path
// landed.
Answer :: core_pkg.Answer

// `Answer.owner` of an answer no record holds: a miss of the header or of the text as a whole.
NO_OWNER :: core_pkg.NO_OWNER

// The first answer `path` gives in `src`: the cell `.[row].name` or `.[row][col]` names, the record `.[row]`
// names, or the first of the rows `.[].name`, `.[][col]` and `.[]` read. One scan, no document, and nothing
// kept.
//
//	- On a fault the answer is `.Missing` and bounds nothing.
//	- The answer is `.Found` with `lo` and `hi` bounding the value in `src`, else `.Missing`. A miss names its
//	  container in `owner` where one holds it (a row too short for the column), and `NO_OWNER` when none does
//	  (no such row, or a header without the name).
//	- `limit` is read as 1, so a path over every row answers its first.
//	- The scan stops at the answer, so the bytes after it are not judged.
@(require_results)
find :: proc(
	src: []byte,
	path: Path_Spec,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (a: Answer, err: Maybe(Error)) {
	a = Answer{outcome = .Missing, owner = NO_OWNER}
	buf: Path_Buf
	t, perr := parse_target(path, &buf, allocator, reader = true)
	defer delete(t.scratch, allocator)
	if e, bad := perr.?; bad {
		return a, reader_refusal(e)
	}
	if t.col == COL_NAME && opts.no_header {
		return a, Error{kind = .Bad_Option}
	}
	t.limit = 1
	return stream_target(src, t, nil, opts, allocator, single = true)
}

// Append to `out` every answer `path` gives in `src`'s records: one per row that has the named or indexed
// column, or, for `.[]`, one per row.
//
//	- `out` is the caller's buffer, reused across calls. A fault leaves in `out` the answers before it.
//	- A `limit` stops the walk at the last answer. Otherwise it stops after the target's rows, so no byte past a
//	  single row is read.
@(require_results)
find_column :: proc(
	src: []byte,
	path: Path_Spec,
	out: ^[dynamic]Answer,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (err: Maybe(Error)) {
	buf: Path_Buf
	t, perr := parse_target(path, &buf, allocator, reader = true)
	defer delete(t.scratch, allocator)
	if e, bad := perr.?; bad {
		return reader_refusal(e)
	}
	if t.col == COL_NAME && opts.no_header {
		return Error{kind = .Bad_Option}
	}
	_, err = stream_target(src, t, out, opts, allocator, single = false)
	return err
}

// Append to `out` every answer `path` gives in `doc`, in row order: the cell `.[row].name` or `.[row][col]`
// names, the record `.[row]` names, or every matching row of `.[].name`, `.[][col]` and `.[]`.
//
//	- The answers are read from `doc`'s field spans; the text is never scanned again. `owner` is the record's
//	  first byte.
//	- `.Out_Of_Memory` is `out` refusing to grow; the answers appended before that stay.
//	- It allocates only for a text path longer than 256 bytes that holds an escaped name, in `allocator`.
@(require_results)
query :: proc(
	doc: ^Document,
	path: Path_Spec,
	out: ^[dynamic]Answer,
	allocator := context.allocator,
) -> (err: Maybe(Path_Error)) {
	buf: Path_Buf
	t, perr := parse_target(path, &buf, allocator, reader = true)
	defer delete(t.scratch, allocator)
	if e, bad := perr.?; bad {
		return e
	}
	col := t.col
	if col == COL_NAME {
		if doc.no_header {
			return Path_Error{kind = .Unsupported_Path}
		}
		c, at, repeated := named_column(doc.src, doc.names[:], doc.dialect, t.name, lookup_policy(doc.duplicates))
		if repeated {
			return Path_Error{kind = .Bad_Source, syntax = .Duplicate_Key, offset = at}
		}
		if c < 0 {
			return nil
		}
		col = c
	}
	first, last := 0, doc.rows
	if !t.every_row {
		if t.row >= doc.rows {
			return nil
		}
		first, last = t.row, t.row + 1
	}
	counted := 0
	for row in first ..< last {
		fields := row_fields(doc, row)
		if col >= len(fields) {
			continue
		}
		if core_pkg.answer_cut(t.limit, &counted, .Found, false) {
			break
		}
		if _, aerr := append(out, record_answer(fields, col)); aerr != nil {
			return core_pkg.PATH_OUT_OF_MEMORY
		}
	}
	return nil
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
	limit:     int, // 0 for every answer
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
//
// `reader` is how the streaming readers read a path: `limit(...)` is kept (an edit refuses it), and a path past
// `MAX_PATH_STEPS` keeps its `.Over_Capacity` (an edit reports `.Unsupported_Path`).
@(private)
parse_target :: proc(
	path: Path_Spec,
	buf: ^Path_Buf,
	allocator: runtime.Allocator,
	reader := false,
) -> (t: Target, err: Maybe(Path_Error)) {
	p: Path
	switch v in path {
	case string:
		text := v
		names := buf.names[:]
		if len(text) > len(names) && strings.index_byte(text, '\\') >= 0 {
			heap, aerr := make([]u8, len(text), allocator)
			if aerr != nil {
				return {}, core_pkg.PATH_OUT_OF_MEMORY
			}
			t.scratch, names = heap, heap
		}
		perr: Maybe(Path_Error)
		if p, perr = core_pkg.parse_path(text, buf.steps[:], names); perr != nil {
			delete(t.scratch, allocator)
			// A path with more steps than the buffer holds is not a CSV path.
			if e, bad := perr.?; bad && e.kind == .Over_Capacity && !reader {
				return {}, Path_Error{kind = .Unsupported_Path}
			}
			return {}, perr
		}
	case Path:
		p = v
	}
	t.col = COL_NONE
	if p.per_element || len(p.steps) < 1 || len(p.steps) > 2 || p.limit != 0 && !reader {
		delete(t.scratch, allocator)
		return {}, Path_Error{kind = .Unsupported_Path}
	}
	t.limit = p.limit
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

// The readers take the first column under `.Default`, where `unmarshal` and the path edits refuse the repeat.
@(private)
lookup_policy :: proc(duplicates: Duplicates) -> Duplicates {
	return .First if duplicates == .Default else duplicates
}

// The answers `t` names, read from `src`'s records. `out` receives every one, or, under `$single`, the walk
// stops at the first and returns it in `first`; `limit` cuts the answers either way. The header is read
// before the rows, and a name it lacks answers nothing.
@(private)
stream_target :: proc(
	src: []byte,
	t: Target,
	out: ^[dynamic]Answer,
	opts: Read_Opts,
	allocator: runtime.Allocator,
	$single: bool,
) -> (first: Answer, err: Maybe(Error)) {
	first = Answer{outcome = .Missing, owner = NO_OWNER}
	it := records(src, opts, allocator)
	defer destroy(&it)
	if it.err != nil {
		return first, it.err
	}
	col := t.col
	if t.col == COL_NAME {
		head, more := next_record(&it)
		if !more {
			return first, it.err
		}
		c, at, repeated := named_column(src, head.fields, opts.dialect, t.name, lookup_policy(opts.duplicates))
		if repeated {
			return first, Error{kind = .Duplicate_Key, offset = at}
		}
		if c < 0 {
			return first, it.err
		}
		col = c
	} else if !opts.no_header {
		if _, more := next_record(&it); !more {
			return first, it.err
		}
	}
	if t.every_row {
		counted := 0
		for rec in next_record(&it) {
			if col >= len(rec.fields) {
				continue
			}
			answer := record_answer(rec.fields, col)
			when single {
				return answer, nil
			}
			if _, aerr := append(out, answer); aerr != nil {
				return first, Error{kind = .Out_Of_Memory}
			}
			if counted += 1; counted == t.limit {
				return first, nil
			}
		}
		return first, it.err
	}
	for row := 0; ; row += 1 {
		rec, more := next_record(&it)
		if !more {
			return first, it.err
		}
		if row < t.row {
			continue
		}
		if col >= len(rec.fields) {
			return Answer{outcome = .Missing, owner = rec.at}, nil
		}
		answer := record_answer(rec.fields, col)
		when single {
			return answer, nil
		} else {
			if _, aerr := append(out, answer); aerr != nil {
				return first, Error{kind = .Out_Of_Memory}
			}
			return first, it.err
		}
	}
}

// The caller checked `col` is one of the record's fields, or `COL_NONE`.
@(private)
record_answer :: #force_inline proc(fields: []Field, col: int) -> Answer {
	if col == COL_NONE {
		return Answer{lo = fields[0].lo, hi = fields[len(fields) - 1].hi, owner = fields[0].lo, outcome = .Found}
	}
	f := fields[col]
	return Answer{lo = f.lo, hi = f.hi, owner = fields[0].lo, outcome = .Found}
}

@(private)
seek_row :: proc(it: ^Records, row: int) -> (rec: Record, ok: bool) {
	for _ in 0 ..= row {
		rec = next_record(it) or_return
	}
	return rec, true
}

@(private)
reader_refusal :: proc(e: Path_Error) -> Error {
	#partial switch e.kind {
	case .Bad_Path:
		return Error{kind = .Bad_Path, offset = e.offset}
	case .Over_Capacity:
		return Error{kind = .Over_Capacity, offset = e.offset}
	case .Out_Of_Memory:
		return Error{kind = .Out_Of_Memory}
	}
	return Error{kind = .Bad_Option}
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
