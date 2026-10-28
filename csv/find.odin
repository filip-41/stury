package csv

// Paths into a CSV text. `find` and a `Request` stream paths over the text from its start, with no document; the
// path edits (edit.odin) locate their targets the same way. `query` answers a path over a `Document` as it does
// over any format's.

import "base:runtime"
import core_pkg "../core"

// A built path: a chain of steps.
Path :: core_pkg.Path

// The most steps a text path names wherever the library parses one, the same in every format.
MAX_PATH_STEPS :: core_pkg.MAX_PATH_STEPS

// The most paths a `Request` is sure to answer, the same in every format. CSV answers any number.
MAX_PATH_QUERIES :: core_pkg.MAX_PATH_QUERIES

// Parse `text` in core's path syntax into `steps`, a quoted name's escapes decoded into `names` (`len(text)`
// bytes always suffice). Allocates nothing; a fault is `.Bad_Path` at the byte the parser stopped on, or
// `.Over_Capacity` when `steps` or `names` is too small.
@(require_results)
parse_path :: #force_inline proc(text: string, steps: []Step, names: []u8 = nil) -> (p: Path, err: Maybe(Path_Error)) {
	return core_pkg.parse_path(text, steps, names)
}

// A path as `query`, `find`, `Request` and the path edits take it: text in core's path syntax, or a built
// `Path`. `query` reads it over the document's rows, as over any format's (`core.query`): a record is an object
// under a header, so `.[3][1]` is an index into an object there. `find`, `Request` and the edits read it as
// rows and columns:
//
//	.[3].name   row 3, the column the header names `name`
//	.[3][1]     row 3, column 1
//	.[], .[3]   every row, or row 3: the record's own span
//	.[].name    that column of every row
//
// A text path starts at the root `.`, as in `json`. Rows count from the first record after the header, columns
// from 0. `find` and `Request` take `limit(...)`, which cuts the answers (0 is every one).
//
// A step that is not one of these (a negative index, `.[][]`, a name without a header) is `.Unsupported_Path`
// from `find` and `scan`. They also report `.Bad_Path`, `.Over_Capacity` and `.Out_Of_Memory`, and the text's
// fault as `.Bad_Source`.
//
// A header name two columns share follows `opts.duplicates`: the last column under `.Default` and `.Last`, the
// first under `.First`, every one under `.All`, and under `.Refuse` `.Bad_Source` with `syntax = .Duplicate_Key`
// at the repeated header cell.
//
// A path naming one row that does not land answers `.Missing`: owned by its record when the row is too short for
// the column, else by none (`NO_OWNER`). A path over every row answers only where it lands. Answers borrow `src`;
// a cell is a `.String`, a record an `.Array`.
Path_Spec :: core_pkg.Path_Spec

// Why a path procedure refused: core's `Path_Error_Kind`, shared with JSON. `request_init`, `scan`, `find` and
// `query` report `.Bad_Path`, `.Unsupported_Path`, `.Over_Capacity`, `.Bad_Option`, `.Bad_Source` and
// `.Out_Of_Memory`; the edits report only the kinds their docs list.
Path_Error_Kind :: core_pkg.Path_Error_Kind

// A refusal. `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result`. `offset` is set for
// `.Bad_Path` and `.Bad_Entry` (the byte of the path text), and for `.Unplaceable` and `.Encode` (the record, or
// 0). `encode` is set for `.Encode`. Both this package's and JSON's `render_error` write it.
Path_Error :: core_pkg.Path_Error

// One answer: a span of the text, the record whose span holds it (`NO_OWNER` when none does), how the path
// landed and the value's kind. `node` is the value's row in a `Document` (`query`), else `NO_NODE`.
Answer :: core_pkg.Answer

// Whether a path landed: `.Found`, `.Missing` or `.Type_Mismatch`, the same in every format.
Answer_Outcome :: core_pkg.Answer_Outcome

// `Answer.owner` of an answer no record holds: a miss of the header or of the text as a whole.
NO_OWNER :: core_pkg.NO_OWNER

// What an answer's value is: a cell is a `.String`, a record an `.Array`.
Kind :: core_pkg.Kind

// A value's row in a `Document`, as an answer's `node` names it; `NO_NODE` names none.
Node :: core_pkg.Node
NO_NODE :: core_pkg.NO_NODE

// The first answer `path` gives in `src`: the cell `.[row].name` or `.[row][col]` names, the record `.[row]`
// names, or the first of the rows `.[].name`, `.[][col]` and `.[]` read. One scan, no document, and nothing
// kept: a one-path `Request` whose `limit` is 1.
//
//	- On a fault the answer is `.Missing` and bounds nothing.
//	- The answer is `.Found` with `lo` and `hi` bounding the value in `src`, else `.Missing`.
//	- The scan stops at the answer, so the bytes after it are not judged.
@(require_results)
find :: proc(
	src: []byte,
	path: Path_Spec,
	opts := Read_Opts{},
	allocator := context.allocator,
) -> (a: Answer, err: Maybe(Path_Error)) {
	req: Request
	defer destroy(&req)
	return core_pkg.find(src, path, opts, allocator, &req, scan)
}

// The text of answer `a`, a cell a path read from `src` in `opts.dialect`, decoded as `field_text` decodes a
// field: a slice of `src` with `escaped` false, or decoded into `allocator` with `escaped` true, which the caller
// frees. `ok` is false for an answer that is not a found cell (a record, a miss), a span past `src`, or a
// decode `allocator` refuses. JSON's `answer_text` has the same shape.
@(require_results)
answer_text :: proc(src: []byte, a: Answer, opts := Read_Opts{}, allocator := context.allocator) -> (text: string, escaped: bool, ok: bool) {
	if a.outcome != .Found || a.kind == .Array || a.kind == .Object || a.lo > a.hi || a.hi > u64(len(src)) {
		return
	}
	err: runtime.Allocator_Error
	text, escaped, err = cell_text(src, {a.lo, a.hi}, opts.dialect, allocator)
	return text, escaped, err == nil
}

// Many paths read from a text's records in one pass: core's `Request` (`request_init`, `answers`) with CSV's
// `scan`. Each path's answers are one per row that has the named or indexed column, or, for `.[]`, one per
// row; a path naming one row that does not land answers `.Missing`.
Request :: struct {
	using base: core_pkg.Request(Read_Opts),
	// One per path, set by `scan`.
	targets:    [dynamic]Target,
}

// Set `req`'s inputs and parse its text paths (core's `request_init`).
@(require_results)
request_init :: proc(req: ^Request, paths: ..Path_Spec, opts := Read_Opts{}, allocator := context.allocator) -> Maybe(Path_Error) {
	return core_pkg.request_init(req, paths, opts, allocator)
}

answers :: core_pkg.answers

// Read `src`'s records once for every path of `req` and fill `req.answers`, path by path in row order.
//
//	- The walk stops once every path is answered: after the last row a path names, or at a path's `limit`.
//	  The bytes after are not judged.
//	- A path CSV does not answer (`Path_Spec`) or a name under `no_header` is `.Unsupported_Path`, as from
//	  `query`; no paths, or an `answers` made with another allocator than the request's, `.Bad_Option`; a path
//	  past `MAX_PATH_STEPS` steps `.Over_Capacity`; all before any byte is read.
//	- The text's fault is `.Bad_Source`. A fault leaves the answers before it.
@(require_results)
scan :: proc(src: []byte, req: ^Request) -> Maybe(Path_Error) {
	alloc := core_pkg.request_allocator(req)
	clear(&req.answers)
	req.groups.grouped = false
	targets_free(req)
	core_pkg.request_preflight(req, true, alloc) or_return
	core_pkg.adopt_allocator(&req.answers, alloc)
	core_pkg.adopt_allocator(&req.targets, alloc)
	for p in req.inputs.paths {
		t := target_of(p, reader = true) or_return
		if t.col == COL_NAME && req.inputs.read.no_header {
			return Path_Error{kind = .Unsupported_Path}
		}
		if _, err := append(&req.targets, t); err != nil {
			return core_pkg.PATH_OUT_OF_MEMORY
		}
	}
	it := records(src, req.inputs.read, alloc)
	defer destroy(&it)
	if it.err != nil {
		return finished(&it)
	}
	head: Record
	if !req.inputs.read.no_header {
		more: bool
		if head, more = next_record(&it); !more && it.err != nil {
			return finished(&it)
		}
	}
	open := 0
	for &t in req.targets {
		if e, bad := target_columns(&t, src, head.fields, req.inputs.read.dialect, req.inputs.read.duplicates, .Last, alloc).?; bad {
			return core_pkg.path_error_of(e)
		}
		t.done = len(t.cols) == 0
		open += int(!t.done)
	}
	for row := 0; open > 0; row += 1 {
		rec := next_record(&it) or_break
		for &t, q in req.targets {
			if t.done || !t.every_row && t.row != row {
				continue
			}
			if target_take(&t, rec.fields, u32(q), &req.answers) != nil {
				return core_pkg.PATH_OUT_OF_MEMORY
			}
			open -= int(t.done)
		}
	}
	if it.err != nil {
		return finished(&it)
	}
	for &t, q in req.targets {
		if target_miss(&t, u32(q), &req.answers) != nil {
			return core_pkg.PATH_OUT_OF_MEMORY
		}
	}
	return nil
}

@(private)
request_destroy :: proc(req: ^Request) {
	targets_free(req)
	delete(req.targets)
	core_pkg.request_free(req)
}

@(private = "file")
targets_free :: proc(req: ^Request) {
	for &t in req.targets {
		delete(t.many)
	}
	clear(&req.targets)
}

// The engine that answers `paths[which]` when `paths` are scanned together (`scan`): one pass over the
// records, `.Direct` with `why` `"Columns"`, for every path CSV holds, and `.Fallback` with `why`
// `"Unsupported_Path"` for any other, which `scan` refuses. `src` is not read. `.Bad_Option` when `which` is
// not one of `paths`.
@(require_results)
route_of :: proc(src: []byte, paths: []Path, which: int, opts := Read_Opts{}) -> (core_pkg.Route, Maybe(Path_Error)) {
	if which < 0 || which >= len(paths) {
		return {}, Path_Error{kind = .Bad_Option}
	}
	if t, unsupported := target_of(paths[which], reader = true); unsupported != nil || t.col == COL_NAME && opts.no_header {
		return {.Fallback, "Unsupported_Path"}, nil
	}
	return {.Direct, "Columns"}, nil
}

// Append to `out` every answer `path` gives in `doc`, a value of each `node` (`core.query`).
query :: core_pkg.query

// `COL_NONE`: the path stops at a row. `COL_NAME`: the column is the one `Target.name` names.
@(private)
COL_NONE :: -1
@(private)
COL_NAME :: -2

// What a `Path_Spec` names: row `row` (or `every_row`), and column `col`.
// The columns it reads in a record are `cols` (`target_columns`), in order: `col` alone, or the header's columns
// `name` names. `cols` borrows `one`, or `many` under `.All`, so a `Target` is not moved once they are set.
@(private)
Target :: struct {
	row:       int,
	every_row: bool,
	col:       int, // an index, `COL_NONE` or `COL_NAME`
	name:      string, // `COL_NAME`: borrowed from the path text or the buffer a parse decoded into
	limit:     int, // 0 for every answer
	counted:   int, // the answers given
	owner:     u64, // the last record read, `NO_OWNER` before one
	done:      bool, // no later record answers
	cols:      []int,
	one:       [1]int,
	many:      [dynamic]int,
}

// Free what `t` holds: `many`.
@(private)
target_free :: proc(t: ^Target) {
	delete(t.many)
}

// Set `t.cols` from `header`'s names: `t.col` alone, or the columns `t.name` names under `duplicates` (`.Default`
// read as `fallback`), none when no field names it. A second such field under `.Refuse` is `.Duplicate_Key` at
// it; `.All` keeps every one in `t.many`, `allocator`'s, a refusal being `.Out_Of_Memory`. Every record holds
// the header's names, so an explicit `.Refuse` refuses any repeated one whatever the path reads, as JSON's
// readers refuse a repeated key in any object they pass.
@(private)
target_columns :: proc(
	t: ^Target,
	src: []byte,
	header: []Field,
	dialect: Dialect,
	duplicates, fallback: Duplicates,
	allocator: runtime.Allocator,
) -> Maybe(Error) {
	t.one[0] = t.col
	t.cols = t.one[:]
	if t.col != COL_NAME && duplicates != .Refuse {
		return nil
	}
	names, aerr := header_names(src, header, dialect, allocator)
	defer header_names_destroy(&names, allocator)
	if aerr != nil {
		return Error{kind = .Out_Of_Memory}
	}
	if duplicates == .Refuse {
		for earlier, c in names.repeats {
			if earlier >= 0 {
				return Error{kind = .Duplicate_Key, offset = header[c].lo}
			}
		}
	}
	if t.col != COL_NAME {
		return nil
	}
	mode := core_pkg.duplicates_or(duplicates, fallback)
	t.cols = t.one[:0]
	t.many.allocator = allocator
	for name, c in names.names {
		if name != t.name {
			continue
		}
		switch {
		case mode == .All:
			if _, err := append(&t.many, c); err != nil {
				return Error{kind = .Out_Of_Memory}
			}
			t.cols = t.many[:]
		case names.repeats[c] < 0 || mode == .Last:
			t.one[0] = c
			t.cols = t.one[:]
		case mode == .Refuse:
			return Error{kind = .Duplicate_Key, offset = header[c].lo}
		}
	}
	return nil
}

// What `p` names, borrowing its names: a path of one step names a row, of two a cell or a column. Any other is
// `.Unsupported_Path`, and so is a `limit` unless `reader`.
@(private)
target_of :: proc(p: Path, reader: bool) -> (t: Target, err: Maybe(Path_Error)) {
	UNSUPPORTED :: Path_Error{kind = .Unsupported_Path}
	if p.per_element || len(p.steps) < 1 || len(p.steps) > 2 || p.limit != 0 && !reader {
		return {}, UNSUPPORTED
	}
	t.col, t.limit, t.owner = COL_NONE, p.limit, NO_OWNER
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
		return {}, UNSUPPORTED
	}
	return
}

// Append to `out` the answers target `t` (path `query`) gives in one record's `fields`, up to its `limit`.
// `t.done` once no later record answers.
@(private)
target_take :: proc(t: ^Target, fields: []Field, query: u32, out: ^[dynamic]Answer) -> Maybe(Error) {
	t.owner = fields[0].lo
	for c in t.cols {
		if c >= len(fields) {
			continue
		}
		a := Answer{lo = fields[0].lo, hi = fields[len(fields) - 1].hi, owner = fields[0].lo, node = NO_NODE, kind = .Array, query = query}
		if c != COL_NONE {
			a.lo, a.hi, a.kind = fields[c].lo, fields[c].hi, .String
		}
		if _, err := append(out, a); err != nil {
			return Error{kind = .Out_Of_Memory}
		}
		if t.counted += 1; t.counted == t.limit {
			break
		}
	}
	t.done = !t.every_row || t.limit > 0 && t.counted == t.limit
	return nil
}

// The `.Missing` a path naming one row owes when that row gave no answer, owned by the record when it was read.
@(private)
target_miss :: proc(t: ^Target, query: u32, out: ^[dynamic]Answer) -> Maybe(Error) {
	if t.every_row || t.counted > 0 {
		return nil
	}
	a := core_pkg.MISSING
	a.owner, a.query = t.owner, query
	if _, err := append(out, a); err != nil {
		return Error{kind = .Out_Of_Memory}
	}
	return nil
}

@(private)
seek_row :: proc(it: ^Records, row: int) -> (rec: Record, ok: bool) {
	for _ in 0 ..= row {
		rec = next_record(it) or_return
	}
	return rec, true
}

// The scan's fault on `it`, as a path error, or nil when it ended without one.
@(private)
finished :: proc(it: ^Records) -> Maybe(Path_Error) {
	if e, faulted := it.err.?; faulted {
		return core_pkg.path_error_of(e)
	}
	return nil
}

