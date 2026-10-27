package csv

// Paths into a CSV text. `query` answers a path over a `Document`'s field spans; `find` and a `Request` stream
// paths over the text from its start, with no document. The path edits (edit.odin) locate their
// targets the same way.

import "base:runtime"
import core_pkg "../core"

// A built path: a chain of steps.
Path :: core_pkg.Path

// A path as `query`, `find`, `Request` and the path edits take it: text in core's path syntax, or a built
// `Path`.
//
//	.[3].name   row 3, the column the header names `name`
//	.[3][1]     row 3, column 1
//	.[], .[3]   every row, or row 3: the record's own span
//	.[].name    that column of every row
//
// A text path starts at the root `.`, as in `json`. Rows count from the first record after the header, columns
// from 0. `query`, `find` and `Request` take `limit(...)`, which cuts the answers (0 is every one).
//
// A step that is not one of these (a negative index, `.[][]`, a name without a header) is `.Unsupported_Path`
// from `query` and `.Bad_Option` from `find` and `scan`; those two also report `.Bad_Path`,
// `.Over_Capacity` and `.Out_Of_Memory`, and the scan's fault with the kind and offset it was found at.
//
// A header name two columns share follows `opts.duplicates` (`query`: the `duplicates` `build` was given): the
// last column under `.Default` and `.Last`, the first under `.First`, every one under `.All`, and under `.Refuse`
// `.Duplicate_Key` at the repeated header cell (from `query`, `.Bad_Source` with `syntax = .Duplicate_Key`).
//
// A path naming one row that does not land answers `.Missing`: owned by its record when the row is too short for
// the column, else by none (`NO_OWNER`). A path over every row answers only where it lands. Answers borrow `src`
// (`query`: `doc.src`); a cell is a `.String`, a record an `.Array`.
Path_Spec :: core_pkg.Path_Spec

// Why a path procedure refused: core's `Path_Error_Kind`, shared with JSON. `query` reports `.Bad_Path`,
// `.Unsupported_Path`, `.Over_Capacity`, `.Bad_Source` and `.Out_Of_Memory`; the edits report only the kinds
// their docs list.
Path_Error_Kind :: core_pkg.Path_Error_Kind

// A refusal. `syntax` and `offset` are set for `.Bad_Source` and `.Bad_Result`. `offset` is set for
// `.Bad_Path` and `.Bad_Row` (the byte of the path text), and for `.Unplaceable` and `.Encode` (the record, or
// 0). `encode` is set for `.Encode`. Both this package's and JSON's `render_error` write it.
Path_Error :: core_pkg.Path_Error

// One answer: a span of the text, the record whose span holds it (`NO_OWNER` when none does), how the path
// landed and the value's kind. `node` is the cell's index among a `Document`'s fields (`query`), else `NO_NODE`.
Answer :: core_pkg.Answer

// `Answer.owner` of an answer no record holds: a miss of the header or of the text as a whole.
NO_OWNER :: core_pkg.NO_OWNER

// What an answer's value is: a cell is a `.String`, a record an `.Array`.
Kind :: core_pkg.Kind

// A cell's index among a `Document`'s fields, as an answer's `node` names it; `NO_NODE` names none.
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
) -> (a: Answer, err: Maybe(Error)) {
	a = core_pkg.MISSING
	req: Request
	defer destroy(&req)
	request_init(&req, path, opts = opts, allocator = allocator) or_return
	req.paths[0].limit = 1
	scan(src, &req) or_return
	return core_pkg.request_first(&req), nil
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
request_init :: proc(req: ^Request, paths: ..Path_Spec, opts := Read_Opts{}, allocator := context.allocator) -> Maybe(Error) {
	return core_pkg.request_init(req, paths, opts, allocator)
}

answers :: core_pkg.answers

// Read `src`'s records once for every path of `req` and fill `req.answers`, path by path in row order.
//
//	- The walk stops once every path is answered: after the last row a path names, or at a path's `limit`.
//	  The bytes after are not judged.
//	- A path CSV does not answer (`Path_Spec`), a name under `no_header`, no paths, or an `answers` made
//	  with another allocator than the request's is `.Bad_Option`, and a path past `MAX_PATH_STEPS` steps
//	  `.Over_Capacity`, before any byte is read. A fault leaves the answers before it.
@(require_results)
scan :: proc(src: []byte, req: ^Request) -> Maybe(Error) {
	alloc := core_pkg.request_allocator(req)
	clear(&req.answers)
	req.groups.grouped = false
	targets_free(req)
	if len(req.paths) == 0 || !core_pkg.allocator_ok(req.answers.allocator, alloc) {
		return Error{kind = .Bad_Option}
	}
	core_pkg.adopt_allocator(&req.answers, alloc)
	core_pkg.adopt_allocator(&req.targets, alloc)
	for p in req.paths {
		if len(p.steps) > core_pkg.MAX_PATH_STEPS {
			return Error{kind = .Over_Capacity}
		}
		t, unsupported := target_of(p, reader = true)
		if unsupported != nil || t.col == COL_NAME && req.no_header {
			return Error{kind = .Bad_Option}
		}
		if _, err := append(&req.targets, t); err != nil {
			return Error{kind = .Out_Of_Memory}
		}
	}
	it := records(src, req.read, alloc)
	defer destroy(&it)
	if it.err != nil {
		return it.err
	}
	head: Record
	if !req.no_header {
		more: bool
		if head, more = next_record(&it); !more && it.err != nil {
			return it.err
		}
	}
	open := 0
	for &t in req.targets {
		target_columns(&t, src, head.fields, req.dialect, req.duplicates, .Last, alloc) or_return
		t.done = len(t.cols) == 0
		open += int(!t.done)
	}
	for row := 0; open > 0; row += 1 {
		rec := next_record(&it) or_break
		for &t, q in req.targets {
			if t.done || !t.every_row && t.row != row {
				continue
			}
			target_take(&t, rec.fields, -1, u32(q), &req.answers) or_return
			open -= int(t.done)
		}
	}
	if it.err != nil {
		return it.err
	}
	for &t, q in req.targets {
		target_miss(&t, u32(q), &req.answers) or_return
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
route_of :: proc(src: []byte, paths: []Path, which: int, opts := Read_Opts{}) -> (core_pkg.Route, Maybe(Error)) {
	if which < 0 || which >= len(paths) {
		return {}, Error{kind = .Bad_Option}
	}
	if t, unsupported := target_of(paths[which], reader = true); unsupported != nil || t.col == COL_NAME && opts.no_header {
		return {.Fallback, "Unsupported_Path"}, nil
	}
	return {.Direct, "Columns"}, nil
}

// Append to `out` every answer `path` gives in `doc`, in row order: the cell `.[row].name` or `.[row][col]`
// names, the record `.[row]` names, or every matching row of `.[].name`, `.[][col]` and `.[]`.
//
//	- The answers are read from `doc`'s field spans; the text is never scanned again. `owner` is the record's
//	  first byte.
//	- `.Out_Of_Memory` is `out` refusing to grow; the answers appended before that stay.
//	- It allocates only for a text path longer than 256 bytes that holds an escaped name, and for the columns of
//	  a repeated name under `.All`, in the document's allocator.
@(require_results)
query :: proc(doc: ^Document, path: Path_Spec, out: ^[dynamic]Answer) -> (err: Maybe(Path_Error)) {
	allocator := doc.fields.allocator
	buf: core_pkg.Path_Buf
	t := parse_target(path, &buf, allocator, reader = true) or_return
	defer target_free(&t, allocator)
	if t.col == COL_NAME && doc.no_header {
		return Path_Error{kind = .Unsupported_Path}
	}
	if e, bad := target_columns(&t, doc.src, doc.names[:], doc.dialect, doc.duplicates, .Last, allocator).?; bad {
		return core_pkg.path_error_of(e)
	}
	rows := doc.rows if len(t.cols) > 0 else 0
	for row := 0 if t.every_row else t.row; row < rows && !t.done; row += 1 {
		node, _ := field_index(doc, row, 0)
		if target_take(&t, row_fields(doc, row), node, 0, out) != nil {
			return core_pkg.PATH_OUT_OF_MEMORY
		}
	}
	if target_miss(&t, 0, out) != nil {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	return nil
}

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
	scratch:   []u8, // the heap buffer a long escaped name decoded into, if any
	cols:      []int,
	one:       [1]int,
	many:      [dynamic]int,
}

// Free what `t` holds: `scratch` and `many`.
@(private)
target_free :: proc(t: ^Target, allocator: runtime.Allocator) {
	delete(t.scratch, allocator)
	delete(t.many)
}

// Set `t.cols` from header `names`: `t.col` alone, or the columns `t.name` names under `duplicates` (`.Default`
// read as `fallback`), none when no field names it. A second such field under `.Refuse` is `.Duplicate_Key` at
// it; `.All` keeps every one in `t.many`, `allocator`'s, a refusal being `.Out_Of_Memory`.
@(private)
target_columns :: proc(
	t: ^Target,
	src: []byte,
	names: []Field,
	dialect: Dialect,
	duplicates, fallback: Duplicates,
	allocator: runtime.Allocator,
) -> Maybe(Error) {
	t.one[0] = t.col
	t.cols = t.one[:]
	if t.col != COL_NAME {
		return nil
	}
	mode := core_pkg.duplicates_or(duplicates, fallback)
	t.cols = t.one[:0]
	t.many.allocator = allocator
	for f, c in names {
		if !text_is(src, f, dialect, t.name) {
			continue
		}
		switch {
		case mode == .All:
			if _, err := append(&t.many, c); err != nil {
				return Error{kind = .Out_Of_Memory}
			}
			t.cols = t.many[:]
		case len(t.cols) == 0 || mode == .Last:
			t.one[0] = c
			t.cols = t.one[:]
		case mode == .Refuse:
			return Error{kind = .Duplicate_Key, offset = f.lo}
		}
	}
	return nil
}

// The target of `path`, borrowing `buf` (`target_of`).
//
// `reader` is how the streaming readers read a path: `limit(...)` is kept (an edit refuses it), and a path past
// `MAX_PATH_STEPS` keeps its `.Over_Capacity` (an edit reports `.Unsupported_Path`).
@(private)
parse_target :: proc(
	path: Path_Spec,
	buf: ^core_pkg.Path_Buf,
	allocator: runtime.Allocator,
	reader := false,
) -> (t: Target, err: Maybe(Path_Error)) {
	p, perr := core_pkg.path_resolve(path, buf, allocator)
	// A path with more steps than the buffer holds is not a CSV path.
	if e, bad := perr.?; bad && e.kind == .Over_Capacity && !reader {
		return {}, Path_Error{kind = .Unsupported_Path}
	}
	perr or_return
	if t, err = target_of(p, reader); err != nil {
		delete(buf.heap, allocator)
		return
	}
	t.scratch = buf.heap
	return
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

// Append to `out` the answers target `t` (path `query`) gives in one record's `fields`, the first of them field
// `node` of a document (-1: none), up to its `limit`. `t.done` once no later record answers.
@(private)
target_take :: proc(t: ^Target, fields: []Field, node: int, query: u32, out: ^[dynamic]Answer) -> Maybe(Error) {
	t.owner = fields[0].lo
	for c in t.cols {
		if c >= len(fields) {
			continue
		}
		a := Answer{lo = fields[0].lo, hi = fields[len(fields) - 1].hi, owner = fields[0].lo, node = NO_NODE, kind = .Array, query = query}
		if c != COL_NONE {
			a.lo, a.hi, a.kind = fields[c].lo, fields[c].hi, .String
			a.node = Node(node + c) if node >= 0 else NO_NODE
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
		return path_error_of(e)
	}
	return nil
}

// A scan's fault `e` as a path error.
@(private)
path_error_of :: proc(e: Error) -> Path_Error {
	if e.kind == .Bad_Option {
		return Path_Error{kind = .Bad_Option}
	}
	return core_pkg.path_error_of(e)
}
