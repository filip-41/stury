package main

// A filter that is only columns of a --from csv or --from tsv file (`.name`, `.a, .b`, `[.a, .b]` under -c or --to
// csv or tsv; `{a, b: .c}` under -c or --to csv or tsv, and `.` under -c) answers from each record's cells, printed
// as the interpreter prints the same filter on the record's object: no object is built.
// `select(F)`, when F reads only named columns, runs the interpreter on an object of just those, and prints the
// whole record for each output (`select_cell`).
// A whole file past two workers' worth is read in `csv.each_record`'s pieces on the batch pool, each piece printed
// into a buffer of its own and written as soon as the pieces before it are. Any other filter runs on the interpreter
// (`next_cells`).

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import csv "../../csv"
import "jq"

// The columns a filter prints, in the order it prints them.
Columns :: struct {
	names:  []string,
	array:  bool, // `[...]`: one output, an array of the cells
	object: bool, // `{...}` or `.`: one output, an object of the cells under `keys`
	all:    bool, // `.`: the object of every column of the open file, `names` and `keys` its header
	// An object's member keys, in the order printed (sorted under -S), and each one's `"key":` as it is printed.
	keys:   []string,
	heads:  []string,
	// Each name's place in the open file's header, -1 when the header lacks it (the output is then null).
	at:     []int,
	sorted: bool, // -S: `all` prints the header's names in byte order
	// `select(F)`: F's columns, which the interpreter sees as the record's object, and where they are in the header.
	selecting: bool,
	watch:     []string,
	watch_at:  []int,
	arena:     virtual.Arena, // the interpreter's memory for one record
}

// The record `select(F)` has found an output for, which the sink prints whole.
Selected :: struct {
	cols:    ^Columns,
	rec:     csv.Record,
	dialect: csv.Dialect,
}

// Whether the filter `text` is only columns, kept in `run.columns` when it is, with a command line that prints
// strings as `print_cells` does.
choose_columns :: proc(run: ^Run, text: string, files: int) {
	o := &run.opts
	if !reads_cells(o) || o.null_input || o.slurp || o.exit_status || o.color || o.ascii || o.raw0 {
		return
	}
	parsed, errors := jq.parse(text)
	if len(errors) > 0 || len(parsed.deps) > 0 || parsed.body == nil {
		return
	}
	body := parsed.body
	if body.kind == .Call && body.name == "select" {
		run.columns = select_columns(run, body, files)
		return
	}
	if body.kind == .Object || body.kind == .Identity {
		run.columns = object_columns(o, body)
		return
	}
	array := body.kind == .Array
	if array {
		body = body.a
	}
	names: [dynamic]string
	if (array && !o.compact && !writes_cells(o)) || !add_columns(&names, body) {
		return
	}
	run.columns = new_clone(Columns{names = names[:], array = array, at = make([]int, len(names))})
}

// The columns of `{...}`, whose members are each a constant key and the input's member of that name or of another
// (`{a, b: .c}`), or of `.`, which is all of them: nil when `body` is not either, or the output is not one that is
// printed here. A table's header is the keys, so --grow-header (which holds the rows) and a key twice (which the
// interpreter keeps once) are left to the interpreter, as is any layout of JSON but the compact one.
@(private = "file")
object_columns :: proc(o: ^Opts, body: ^jq.Node) -> ^Columns {
	if writes_cells(o) ? o.grow_header : !o.compact {
		return nil
	}
	if body.kind == .Identity {
		return nil if writes_cells(o) else new_clone(Columns{object = true, all = true, sorted = o.sort_keys})
	}
	Member :: struct {
		key, name: string,
	}
	members: [dynamic]Member
	for i := 0; i < len(body.args); i += 2 {
		key, value := body.args[i], body.args[i + 1]
		k, is_key := key.value.(string)
		if key.kind != .Literal || !is_key {
			return nil
		}
		for m in members {
			if m.key == k {
				return nil
			}
		}
		switch {
		case value == nil:
			append(&members, Member{k, k})
		case value.kind == .Field && !value.opt && value.a.kind == .Identity:
			append(&members, Member{k, value.name})
		case:
			return nil
		}
	}
	if o.sort_keys {
		slice.sort_by(members[:], proc(a, b: Member) -> bool {return a.key < b.key})
	}
	cols := Columns{object = true, names = make([]string, len(members)), keys = make([]string, len(members)), at = make([]int, len(members))}
	for m, i in members {
		cols.names[i], cols.keys[i] = m.name, m.key
	}
	cols.heads = object_heads(cols.keys)
	return new_clone(cols)
}

// `select(F)` whose F reads only columns of the record, so that the interpreter can run F on an object of those and
// the record, printed as `.` is, stands for the output. A table's header is the file's, so a table is of one file.
@(private = "file")
select_columns :: proc(run: ^Run, body: ^jq.Node, files: int) -> ^Columns {
	o := &run.opts
	if run.home_module || len(body.args) != 1 || (writes_cells(o) ? o.grow_header || files > 1 : !o.compact) {
		return nil
	}
	watch: [dynamic]string
	if !only_columns(body.args[0], &watch) {
		return nil
	}
	cols := Columns{object = true, all = true, sorted = o.sort_keys, selecting = true, watch = watch[:]}
	cols.watch_at = make([]int, len(watch))
	return new_clone(cols)
}

// Whether the expression `n`, run on a record, reads the record only as `.name`, appending the names to `watch`.
// What a `|` pipes on is not the record, so its right side is not looked at; any other use of `.`, a call that takes
// it implicitly, a binding or an else-less `if` is refused. A `select` passes on its input, so its argument is `n`'s.
@(private = "file")
only_columns :: proc(n: ^jq.Node, watch: ^[dynamic]string) -> bool {
	if n == nil {
		return true
	}
	switch n.kind {
	case .Field:
		if n.a.kind != .Identity {
			return only_columns(n.a, watch)
		}
		if !slice.contains(watch[:], n.name) {
			append(watch, n.name)
		}
		return true
	case .Literal, .Var:
		return true
	case .Pipe, .Try:
		return only_columns(n.a, watch)
	case .Index, .Slice, .Iterate, .Array, .Neg, .Comma, .Binary, .And, .Or, .Alt:
		return only_columns(n.a, watch) && only_columns(n.b, watch) && only_columns(n.c, watch)
	case .If:
		return n.c != nil && only_columns(n.a, watch) && only_columns(n.b, watch) && only_columns(n.c, watch)
	case .Call:
		if n.name != "select" || len(n.args) != 1 {
			return false
		}
		return only_columns(n.args[0], watch)
	case .Identity, .String, .Format, .Object, .Reduce, .Foreach, .Def, .Bind, .Label, .Break, .Update:
	}
	return false
}

// Each key as an object prints it before its value.
@(private = "file")
object_heads :: proc(keys: []string) -> []string {
	heads := make([]string, len(keys))
	buf: [dynamic]byte
	for k, i in keys {
		clear(&buf)
		jq.write_string(&buf, k)
		append(&buf, ':')
		heads[i] = string(slice.clone(buf[:]))
	}
	delete(buf)
	return heads
}

// The names of the columns `n` is, in order, appended to `names`: false when `n` is anything else.
@(private = "file")
add_columns :: proc(names: ^[dynamic]string, n: ^jq.Node) -> bool {
	switch {
	case n == nil:
	case n.kind == .Comma:
		return add_columns(names, n.a) && add_columns(names, n.b)
	case n.kind == .Field && !n.opt && n.a.kind == .Identity:
		append(names, n.name)
		return true
	}
	return false
}

// Where `cols`' names are in `header`.
@(private = "file")
place_columns :: proc(cols: ^Columns, header: []string) {
	if cols.all {
		cols.names, cols.keys = header, header
		cols.at = make([]int, len(header))
		for &at, i in cols.at {
			at = i
		}
		if cols.sorted {
			cols.keys = slice.clone(header)
			slice.sort(cols.keys)
			for k, i in cols.keys {
				cols.at[i] = column_of(header, k)
			}
		}
		cols.heads = object_heads(cols.keys)
	}
	for name, i in cols.watch {
		cols.watch_at[i] = column_of(header, name)
	}
	if !cols.all {
		for name, i in cols.names {
			cols.at[i] = column_of(header, name)
		}
	}
}

// Where `name` is in `header`, or -1.
@(private = "file")
column_of :: proc(header: []string, name: string) -> int {
	for h, j in header {
		if h == name {
			return j
		}
	}
	return -1
}

// Print the columns of the files' records, as `run_filter` runs the filter on them: until a file has failed to
// open (after the record that met it), a file's fault ends the run, and a halt.
scan_cells :: proc(run: ^Run, ins: ^Inputs) {
	c, cols := cells_of(ins), run.columns
	fetched := false
	for (ins.failures == 0 || !fetched) && !run.halted {
		if c.file == nil {
			msg, status := open_cells(ins, c)
			if status != .Value {
				if status == .Error {
					cells_failed(run, msg)
				}
				return
			}
			place_columns(cols, c.header)
			if ins.failures == 0 && !c.streamed {
				if runner := batch_runner(run, len(c.data)); runner != nil && (cols.object || !opens_with_bom(run, c, cols)) && table_openable(run, cols) {
					fetched = true
					if print_cells_in_pieces(run, c, cols, runner) {
						continue // the rest of the file is the main thread's
					}
					if msg = cells_ended(ins, c); msg != "" {
						cells_failed(run, msg)
						return
					}
					continue
				}
			}
		}
		if rec, ok := next_cell(c); ok {
			if cols.selecting {
				select_cell(run, cols, rec, c.dialect)
			} else {
				print_cells(run, cols, rec, c.dialect)
			}
			fetched = true
		} else if msg := cells_ended(ins, c); msg != "" {
			cells_failed(run, msg)
			return
		}
	}
}

// The object of the record's watched columns, in the context allocator.
@(private = "file")
watched_object :: proc(cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) -> jq.Value {
	keys := make([dynamic]string, len(cols.watch))
	vals := make([dynamic]jq.Value, len(cols.watch))
	copy(keys[:], cols.watch)
	for at, i in cols.watch_at {
		if at >= 0 && rec.fields[at].lo != rec.fields[at].hi {
			text, _, _ := csv.field_text(rec.src, rec.fields[at], dialect)
			vals[i] = string(text)
		}
	}
	return jq.object_from(keys, vals)
}

// The filter on the record's watched columns, as `run_filter` runs it on the record: each output prints the record.
@(private = "file")
select_cell :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) {
	if cols.arena.curr_block == nil && virtual.arena_init_growing(&cols.arena) != nil {
		fmt.eprintln("stury: error: out of memory")
		finish(run, EXIT_INPUT)
	}
	context.allocator = virtual.arena_allocator(&cols.arena)
	defer virtual.arena_free_all(&cols.arena)
	selected := Selected{cols, rec, dialect}
	run.selected = &selected
	run_once(run, watched_object(cols, rec, dialect))
	run.selected = nil
}

Select_Result :: enum {
	Done,
	Failed, // an error, a halt, or a message the main thread tells in its place: the record's outputs are not kept
}

// `select_cell` for a pool thread's copy of the run, which tells nothing: a failure is the caller's to stop at.
@(private = "file")
select_record :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect, arena: ^virtual.Arena) -> Select_Result {
	context.allocator = virtual.arena_allocator(arena)
	defer virtual.arena_free_all(arena)
	selected := Selected{cols, rec, dialect}
	run.selected = &selected
	sig := eval_input(run, watched_object(cols, rec, dialect))
	run.selected = nil
	failed := sig == .Fail || sig == .Break || len(run.ip.messages) > 0 || run.faulted
	return .Failed if failed else .Done
}

// Whether the output's first record opens with a byte order mark, which only the sequential print guards: the first
// cell of the first record after the header, when the table has not begun.
@(private = "file")
opens_with_bom :: proc(run: ^Run, c: ^Cells, cols: ^Columns) -> bool {
	if run.table == nil || run.rows_begun || cols.at[0] < 0 {
		return false
	}
	probe := csv.records(c.data, c.dialect, allocator = context.temp_allocator)
	defer free_all(context.temp_allocator)
	_, _ = csv.next_record(&probe)
	rec, ok := csv.next_record(&probe)
	if !ok || cols.at[0] >= len(rec.fields) {
		return false
	}
	text, _, _ := csv.field_text(rec.src, rec.fields[cols.at[0]], c.dialect, context.temp_allocator)
	return bytes.has_prefix(text, UTF8_BOM[:])
}

// A fault in the text ends the run with jq's parse error.
@(private = "file")
cells_failed :: proc(run: ^Run, msg: string) {
	flush_some(run, force = true)
	fmt.eprintf("stury: parse error: %s\n", msg)
	run.ret = EXIT_INPUT
}

// The record's output, as `print_jq` prints the interpreter's: each cell its own line, or all in one array. Under
// --to csv or tsv each is a record of the table. False when a record of it is refused in a pool thread's copy, which
// leaves the run to the main thread.
print_cells :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) -> bool {
	if run.table != nil {
		return print_cell_rows(run, cols, rec, dialect)
	}
	raw, out := run.opts.raw && !cols.array && !cols.object, &run.out
	if cols.array {
		append(out, '[')
	} else if cols.object {
		append(out, '{')
	}
	for at, i in cols.at {
		if i > 0 && (cols.array || cols.object) {
			append(out, ',')
		}
		if cols.object {
			append(out, ..transmute([]byte)cols.heads[i])
		}
		null := at < 0 || rec.fields[at].lo == rec.fields[at].hi // a column the header lacks, or a cell of no bytes
		if null {
			append(out, "null")
		} else {
			text, decoded, _ := csv.field_text(rec.src, rec.fields[at], dialect, context.temp_allocator)
			if raw {
				append(out, ..text)
			} else {
				jq.write_string(out, string(text))
			}
			if decoded {
				free_all(context.temp_allocator)
			}
		}
		if !cols.array && !cols.object {
			end_output(run)
			run.ret = JQ_OK_NULL_KIND if null else JQ_OK
		}
	}
	if cols.array || cols.object {
		append(out, ']' if cols.array else '}')
		end_output(run)
	}
	return true
}

// The cell of column `at` of `rec`, in the temporary allocator: nil when the header lacks the column or the cell has
// no bytes.
@(private = "file")
column_cell :: proc(rec: csv.Record, at: int, dialect: csv.Dialect) -> Maybe(string) {
	if at < 0 || rec.fields[at].lo == rec.fields[at].hi {
		return nil
	}
	text, _, _ := csv.field_text(rec.src, rec.fields[at], dialect, context.temp_allocator)
	return string(text)
}

// The record's columns as rows of the table: one row of all the cells, or a row of one cell for each.
@(private = "file")
print_cell_rows :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) -> bool {
	defer free_all(context.temp_allocator)
	if cols.array || cols.object {
		cells := make([]Maybe(string), len(cols.at), context.temp_allocator)
		for at, i in cols.at {
			cells[i] = column_cell(rec, at, dialect)
		}
		if !(put_object_row(run, cols.keys, cells) if cols.object else put_row_or_stop(run, cells)) {
			return false
		}
		run.ret = JQ_OK
		flush_some(run)
		return true
	}
	for at in cols.at {
		one := [1]Maybe(string){column_cell(rec, at, dialect)}
		if !put_row_or_stop(run, one[:]) {
			return false
		}
		run.ret = JQ_OK_NULL_KIND if one[0] == nil else JQ_OK
		flush_some(run)
	}
	return true
}

Cells_Scan :: struct {
	using output: Piece_Output,
	cols:         ^Columns,
	dialect:      csv.Dialect,
}

// What a piece leaves in `Record_Piece.stop` for a record the filter failed on, which the main thread runs again.
SELECT_STOP :: 2

// Whether a table of objects the pieces print can begin with the header `cols` gives it.
@(private = "file")
table_openable :: proc(run: ^Run, cols: ^Columns) -> bool {
	return !cols.object || run.table == nil || run.table.shape != .Unset || header_writable(run, cols.keys)
}

// Print the open whole file's records, on the pool, in order. A fault the pieces meet is found again by reading the
// file through from its start (printing nothing), so that `cells_ended` tells it as a read of the file does.
@(private = "file")
print_cells_in_pieces :: proc(run: ^Run, c: ^Cells, cols: ^Columns, runner: ^csv.Batch_Runner) -> (resumed: bool) {
	job := Cells_Scan{cols = cols, dialect = c.dialect}
	start_pieces(&job, run)
	defer end_pieces(&job)
	// A table of objects begins with the header, put before the first answer.
	if cols.object && run.table != nil && run.table.shape == .Unset {
		job.table_due, job.keys = true, cols.keys
	}
	fault := csv.each_record(c.data, c.dialect, print_cells_piece, &job, runner)
	// A write a pool thread met failing ends the run here.
	check_output()
	if job.stop == TABLE_STOP {
		table_fail(run, "%s", row_refusal(run.table, .Unwritable))
	}
	if job.stop == SELECT_STOP {
		// The filter failed on the next record: the main thread runs it, and what follows, as a read of the file does.
		for _ in 0 ..< job.records {
			_, _ = csv.next_record(&c.whole)
		}
		return true
	}
	if _, bad := fault.?; bad {
		csv.records_destroy(&c.whole)
		c.whole = csv.records(c.data, c.dialect, allocator = runtime.heap_allocator())
		c.it = &c.whole
		for _ in csv.next_record(&c.whole) {}
	}
	return false
}

// Piece `k`'s records, printed into its buffer by a copy of the run, then the pieces now in turn written. A
// fault in the piece's text ends it, and the pieces after it are not printed. Piece 0 starts at the header.
@(private = "file")
print_cells_piece :: proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
	job := (^Cells_Scan)(data)
	run := begin_piece(job, k, len(piece.src) - piece.rec_lo)
	p := Record_Piece{done = true, stop = -1}
	header := k == 0
	run.rows_begun = true // the output's first record is `opens_with_bom`'s: no piece opens it
	arena: virtual.Arena
	selecting := job.cols.selecting
	if selecting {
		_ = virtual.arena_init_growing(&arena)
	}
	defer virtual.arena_destroy(&arena)
	for rec in csv.next_record(piece) {
		if header {
			header = false
			continue
		}
		if selecting {
			before := len(run.out)
			switch select_record(&run, job.cols, rec, job.dialect, &arena) {
			case .Done:
			case .Failed:
				resize(&run.out, before)
				p.stop = TABLE_STOP if run.faulted else SELECT_STOP
			}
			if p.stop >= 0 {
				break
			}
			p.answered ||= len(run.out) > before
		} else {
			p.answered = true
			if !print_cells(&run, job.cols, rec, job.dialect) {
				p.stop = TABLE_STOP
				break
			}
		}
		p.records += 1
	}
	if _, bad := piece.err.?; bad && p.stop < 0 {
		p.stop = 0
	}
	p.out, p.ret = run.out, run.ret
	return publish_piece(job, k, p)
}
