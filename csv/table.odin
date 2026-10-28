package csv

// A table written from values one at a time, as records: objects under a header, or rows of cells.
//
//	- The first object's keys make the header (in byte order under `opts.sort_keys`), written before its record. A
//	  later object's cells follow the header, a key it lacks an empty cell.
//	- A key the header lacks is `.Unknown_Key`, unless `grow`: then each object's record is held, the header
//	  lists every key in first-seen order (byte order under `opts.sort_keys`), and `table_finish` writes them all.
//	- A row of cells (`table_row`) is written as it is. A table is all objects or all rows: `.Mixed_Shapes`.
//	- `opts` is how each record is written: under `no_header` the header's record is not written.
//	- A record `write_record` refuses is `.Unwritable`, with its kind; nothing of it is written or held, the
//	  header included, and the table is as it was.

import "base:runtime"
import "core:slice"
import "core:strings"
import core_pkg "../core"

Table_Shape :: enum u8 {
	Unset,
	Objects,
	Rows,
}

// The table's state. Its header and held cells are copies owned in `allocator`; `destroy` frees them.
Table :: struct {
	using opts: Marshal_Opts,
	grow:       bool,
	shape:      Table_Shape,
	header:     [dynamic]string,
	slot:       map[string]int, // header name to cell index
	held:       [dynamic][]Maybe(string), // `grow`'s records, each as wide as the header when it was held
	finished:   int, // the parts `table_finish` wrote: the header, then the held records
	allocator:  runtime.Allocator,
}

Table_Error_Kind :: enum u8 {
	None,
	Mixed_Shapes, // an object after rows, or a row after objects
	Unknown_Key,  // `key` is the index of the object's key the header lacks
	Unwritable,   // `record` says why `write_record` refused the record
}

Table_Error :: struct {
	kind:   Table_Error_Kind,
	record: Marshal_Error_Kind,
	key:    int,
}

@(require_results)
table_make :: proc(opts := Marshal_Opts{}, grow := false, allocator := context.allocator) -> Table {
	t := Table{opts = opts, grow = grow, allocator = allocator}
	t.header.allocator, t.held.allocator = allocator, allocator
	t.slot = make(map[string]int, allocator)
	return t
}

// Starts a table of objects under the header `keys` and writes the header's record onto `out`. `at_start` is
// `write_record`'s.
@(require_results)
table_open :: proc(t: ^Table, out: ^[dynamic]u8, keys: []string, at_start := true) -> Maybe(Table_Error) {
	table_accepts(t, nil, true) or_return
	from, names := len(t.header), keys
	// A growing header is sorted once it is complete.
	if t.sort_keys && !t.grow {
		names = slice.clone(keys, context.temp_allocator)
		slice.sort(names)
	}
	for k in names {
		add_column(t, k)
	}
	t.shape = .Objects
	if t.grow {
		return nil
	}
	if err := put_header(t, out, at_start); err != nil {
		drop_columns(t, from)
		t.shape = .Unset
		return err
	}
	return nil
}

// The refusal a value of `keys` (an object when `object`) would meet, before its cells are known: `.Mixed_Shapes`,
// or the first of `keys` the header lacks.
@(require_results)
table_accepts :: proc(t: ^Table, keys: []string, object: bool) -> Maybe(Table_Error) {
	if t.shape != .Unset && (t.shape == .Objects) != object {
		return Table_Error{kind = .Mixed_Shapes}
	}
	if object && t.shape == .Objects && !t.grow {
		for k, i in keys {
			if k not_in t.slot {
				return Table_Error{kind = .Unknown_Key, key = i}
			}
		}
	}
	return nil
}

// Appends the record of an object, `cells[i]` being the value of `keys[i]`, onto `out` (held under `grow`). The
// first object opens the table.
@(require_results)
table_object :: proc(t: ^Table, out: ^[dynamic]u8, keys: []string, cells: []Maybe(string), at_start := true) -> Maybe(Table_Error) {
	assert(len(keys) == len(cells))
	table_accepts(t, nil, true) or_return
	mark, from, opened := len(out), len(t.header), t.shape == .Unset
	if opened {
		table_open(t, out, keys, at_start) or_return
	}
	row := make([]Maybe(string), len(t.header) + len(keys), context.temp_allocator)
	for k, i in keys {
		at, known := t.slot[k]
		if !known {
			if !t.grow {
				return Table_Error{kind = .Unknown_Key, key = i}
			}
			at = add_column(t, k)
		}
		row[at] = cells[i]
	}
	row = row[:len(t.header)]
	if t.grow {
		hold(t, row)
		return nil
	}
	fault, refused := write_record(out, row, t.opts, at_start && !opened).?
	if refused {
		resize(out, mark)
		if opened {
			drop_columns(t, from)
			t.shape = .Unset
		}
		return Table_Error{kind = .Unwritable, record = fault.kind}
	}
	return nil
}

// Appends the record of `cells`, a row without a header, onto `out`.
@(require_results)
table_row :: proc(t: ^Table, out: ^[dynamic]u8, cells: []Maybe(string), at_start := true) -> Maybe(Table_Error) {
	table_accepts(t, nil, false) or_return
	if fault, refused := write_record(out, cells, t.opts, at_start).?; refused {
		return Table_Error{kind = .Unwritable, record = fault.kind}
	}
	t.shape = .Rows
	return nil
}

// Writes the next part of a `grow` table onto `out`: the header of every key, then one held record per call, so
// the caller may flush between them. `more` is false when nothing was left to write; the table then writes as it
// would without `grow`. A table that held no record writes nothing, not even its header. A refused record ends
// the finish, and the records after it are dropped.
@(require_results)
table_finish :: proc(t: ^Table, out: ^[dynamic]u8, at_start := true) -> (more: bool, err: Maybe(Table_Error)) {
	if !t.grow || t.finished > len(t.held) || len(t.held) == 0 {
		end_finish(t)
		return false, nil
	}
	if t.finished == 0 {
		if t.sort_keys {
			sort_held(t)
		}
		if err = put_header(t, out, at_start); err != nil {
			end_finish(t)
			return
		}
	} else {
		row := t.held[t.finished - 1]
		cells := make([]Maybe(string), len(t.header), context.temp_allocator)
		copy(cells, row)
		if fault, refused := write_record(out, cells, t.opts, false).?; refused {
			end_finish(t)
			return false, Table_Error{kind = .Unwritable, record = fault.kind}
		}
	}
	t.finished += 1
	return true, nil
}

// Write `doc`, an array of objects or of arrays, as CSV into a new buffer from `allocator`, through a `grow` table:
// the objects' keys make the header, in first-seen order, and an array is a record of its cells.
//
//	- A cell is a string, a number as its text, `true` or `false`; null is an empty cell, which reads back absent.
//	- A root that is not an array, a record that is neither an object nor an array, a nested object or array, and
//	  objects mixed with arrays are `.Unsupported`, with the path to the value.
//	- A record the dialect cannot write is `.Unwritable`; one of objects, which are held until the header is
//	  complete, carries no path.
@(private, require_results)
marshal_document :: proc(doc: ^Document, opts := Marshal_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Marshal_Error)) {
	buf := make([dynamic]u8, allocator)
	if err = marshal_document_append(&buf, doc, opts); err != nil {
		delete(buf)
		return nil, err
	}
	return buf[:], nil
}

// `marshal_document` appended to `out`, as `marshal_append` appends a list.
@(private, require_results)
marshal_document_append :: proc(out: ^[dynamic]u8, doc: ^Document, opts := Marshal_Opts{}) -> (err: Maybe(Marshal_Error)) {
	if root, _ := core_pkg.kind(doc, ROOT); root != .Array {
		return Marshal_Error{kind = .Unsupported}
	}
	t := table_make(opts, grow = true, allocator = out.allocator)
	defer table_destroy(&t)
	start := len(out)
	defer if err != nil {
		resize(out, start)
	}
	keys := make([dynamic]string, context.temp_allocator)
	cells := make([dynamic]Maybe(string), context.temp_allocator)
	records := core_pkg.children(doc, ROOT)
	for i := 0; ; i += 1 {
		rec := core_pkg.children(&records) or_break
		fault := Marshal_Error{kind = .Unsupported, n_steps = 1}
		fault.steps[0] = core_pkg.Index(i)
		clear(&keys)
		clear(&cells)
		kind, _ := core_pkg.kind(doc, rec)
		it := core_pkg.children(doc, rec)
		#partial switch kind {
		case .Object:
			for k, n in core_pkg.members(&it) {
				append(&keys, k)
				cell, ok := document_cell(doc, n)
				if !ok && fault.n_steps == 1 {
					fault.steps[1], fault.n_steps = core_pkg.Name(k), 2
				}
				append(&cells, cell)
			}
		case .Array:
			for n in core_pkg.children(&it) {
				cell, ok := document_cell(doc, n)
				if !ok && fault.n_steps == 1 {
					fault.steps[1], fault.n_steps = core_pkg.Index(len(cells)), 2
				}
				append(&cells, cell)
			}
		}
		if fault.n_steps > 1 || kind != .Object && kind != .Array {
			return fault
		}
		refused: Maybe(Table_Error)
		if kind == .Object {
			refused = table_object(&t, out, keys[:], cells[:], len(out) == 0)
		} else {
			refused = table_row(&t, out, cells[:], len(out) == 0)
		}
		if e, bad := refused.?; bad {
			fault.kind = e.record if e.kind == .Unwritable else .Unsupported
			return fault
		}
	}
	for {
		more, refused := table_finish(&t, out, len(out) == 0)
		if e, bad := refused.?; bad {
			return Marshal_Error{kind = e.record}
		}
		if !more {
			break
		}
	}
	return nil
}

// The cell of `n`, absent for null; not ok for an object or an array.
@(private = "file")
document_cell :: proc(doc: ^Document, n: Node) -> (cell: Maybe(string), ok: bool) {
	kind, _ := core_pkg.kind(doc, n)
	switch kind {
	case .Null:
		return nil, true
	case .False:
		return "false", true
	case .True:
		return "true", true
	case .Number:
		return string(core_pkg.get_raw(doc, n)), true
	case .String:
		return core_pkg.get_string(doc, n)
	case .Array, .Object:
	}
	return nil, false
}

@(private = "file")
end_finish :: proc(t: ^Table) {
	t.grow = false
	for row in t.held {
		free_held(t, row)
	}
	clear(&t.held)
}

@(private)
table_destroy :: proc(t: ^Table) {
	for name in t.header {
		delete(name, t.allocator)
	}
	delete(t.header)
	delete(t.slot)
	for row in t.held {
		free_held(t, row)
	}
	delete(t.held)
	t^ = {}
}

@(private = "file")
add_column :: proc(t: ^Table, name: string) -> int {
	at := len(t.header)
	owned := strings.clone(name, t.allocator)
	append(&t.header, owned)
	t.slot[owned] = at
	return at
}

// Truncates the header to its first `columns` names.
@(private = "file")
drop_columns :: proc(t: ^Table, columns: int) {
	for name in t.header[columns:] {
		delete_key(&t.slot, name)
		delete(name, t.allocator)
	}
	resize(&t.header, columns)
}

@(private = "file")
put_header :: proc(t: ^Table, out: ^[dynamic]u8, at_start: bool) -> Maybe(Table_Error) {
	if t.no_header {
		return nil
	}
	names := make([]Maybe(string), len(t.header), context.temp_allocator)
	for h, i in t.header {
		names[i] = h
	}
	if fault, refused := write_record(out, names, t.opts, at_start).?; refused {
		return Table_Error{kind = .Unwritable, record = fault.kind}
	}
	return nil
}

// Holds a copy of `row` until the header is complete.
@(private = "file")
hold :: proc(t: ^Table, row: []Maybe(string)) {
	kept := make([]Maybe(string), len(row), t.allocator)
	for c, i in row {
		if text, present := c.?; present {
			kept[i] = strings.clone(text, t.allocator)
		}
	}
	append(&t.held, kept)
}

@(private = "file")
free_held :: proc(t: ^Table, row: []Maybe(string)) {
	for c in row {
		if text, present := c.?; present {
			delete(text, t.allocator)
		}
	}
	delete(row, t.allocator)
}

// Sorts the header into byte order and each held record's cells with it.
@(private = "file")
sort_held :: proc(t: ^Table) {
	names := slice.clone(t.header[:], context.temp_allocator)
	slice.sort(names)
	order := make([]int, len(names), context.temp_allocator)
	for name, i in names {
		order[i] = t.slot[name]
	}
	copy(t.header[:], names)
	for name, i in names {
		t.slot[name] = i
	}
	for &row in t.held {
		sorted := make([]Maybe(string), len(t.header), t.allocator)
		for at, i in order {
			if at < len(row) {
				sorted[i] = row[at]
			}
		}
		delete(row, t.allocator)
		row = sorted
	}
}
