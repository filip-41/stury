package main

// Answers a filter that selects only columns of a --from csv or --from tsv file directly from each record's cells,
// without building an object. The filters are `.name`, `.a, .b` and `[.a, .b]` under -c or --to csv/tsv,
// `{a, b: .c}` under -c or --to csv/tsv, and `.` under -c. The output bytes equal the interpreter's on the record's
// object.
// For `select(F)` where F reads only named columns, the interpreter runs F on an object of those columns, and each
// output prints the whole record (`select_cell`).
// A whole file larger than two workers' share is read in `csv.each_record` pieces on the batch pool. Each piece
// prints into its own buffer, which is written once all earlier pieces are written. Any other filter runs on the
// interpreter (`next_cells`).

import "base:runtime"
import "core:bytes"
import "core:mem/virtual"
import "core:slice"
import core_pkg "../../core"
import csv "../../csv"
import scan "../../json/scan"
import "jq"

// The columns a filter prints, in the order it prints them.
Columns :: struct {
	names:  []string,
	array:  bool, // `[...]`: one output, an array of the cells
	object: bool, // `{...}` or `.`: one output, an object of the cells under `keys`
	all:    bool, // `.`: an object of every column of the open file; `names` and `keys` are its header
	// The object's member keys in output order (sorted under -S), and each key's printed `"key":`.
	keys:   []string,
	heads:  Heads,
	// The index of each name in the open file's header, or -1 when the header lacks it (the output is null).
	at:     []int,
	sorted: bool, // -S: `all` prints the header's names in byte order
	// `select(F)`: the columns F reads, which form the object F runs on, and their indices in the header.
	selecting: bool,
	watch:     []string,
	watch_at:  []int,
	watch_heads: Heads, // the watched names printed as `"name":`
	arena:     virtual.Arena, // the interpreter's memory for one record
}

// A record for which `select(F)` produced an output. The sink prints the whole record.
Selected :: struct {
	cols:    ^Columns,
	rec:     csv.Record,
	dialect: csv.Dialect,
}

// Sets `run.columns` when the filter `text` selects only columns and the options print strings as `print_cells`
// does.
choose_columns :: proc(run: ^Run, text: string, files: int) {
	o := &run.opts
	stops := column_stops(o)
	if stops != {} && !explain_why(run, stops) {
		return
	}
	parsed, errors := jq.parse(text)
	if len(errors) > 0 || parsed.body == nil {
		return
	}
	imports := len(parsed.deps) > 0
	if imports && !explain_why(run, {.Imports}) {
		return
	}
	cols := columns_of(run, parsed.body, files)
	if stops == {} && !imports {
		run.columns = cols
	}
}

@(private = "file")
columns_of :: proc(run: ^Run, filter: ^jq.Node, files: int) -> ^Columns {
	o := &run.opts
	if filter.kind == .Call && filter.name == "select" {
		return select_columns(run, filter, files)
	}
	if filter.kind == .Object || filter.kind == .Identity {
		return object_columns(run, filter)
	}
	array := filter.kind == .Array
	listed := filter.a if array else filter
	names: [dynamic]string
	laid_out := array && !o.compact && !writes_cells(o)
	named := add_columns(&names, listed)
	if laid_out || !named {
		explain_why(run, ({.Layout} if laid_out else {}) + ({.Not_Columns} if !named else {}))
		return nil
	}
	return new_clone(Columns{names = names[:], array = array, at = make([]int, len(names))})
}

// Returns the columns of `.` (all of them) or of `{...}` whose members each pair a constant key with a field of
// the input (`{a, b: .c}`). Returns nil for any other `body` or an output not printed here. A table's header is
// the keys, so the interpreter handles --grow-header, a repeated key and any JSON layout but the compact one.
@(private = "file")
object_columns :: proc(run: ^Run, body: ^jq.Node) -> ^Columns {
	o := &run.opts
	whys: Explain_Whys
	if writes_cells(o) ? o.grow_header : !o.compact {
		whys += {.Grow_Header} if writes_cells(o) else {.Layout}
		if !explain_why(run, whys) {
			return nil
		}
	}
	if body.kind == .Identity {
		if writes_cells(o) {
			whys += {.Dot_To_Cells}
		}
		explain_why(run, whys)
		return nil if whys != {} else new_clone(Columns{object = true, all = true, sorted = o.sort_keys})
	}
	Member :: struct {
		key, name: string,
	}
	members: [dynamic]Member
	for i := 0; i < len(body.args); i += 2 {
		key, value := body.args[i], body.args[i + 1]
		k, is_key := key.value.(string)
		constant := key.kind == .Literal && is_key
		repeats := false
		for m in members {
			repeats ||= m.key == k
		}
		if !constant || repeats {
			whys += {.Object_Key}
		}
		if value != nil && (value.kind != .Field || value.opt || value.a.kind != .Identity) {
			whys += {.Object_Member}
		}
		if whys != {} && !explain_why(run, whys) {
			return nil
		}
		if constant {
			append(&members, Member{k, k if value == nil else value.name})
		}
	}
	if whys != {} {
		return nil
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

// Returns the columns of `select(F)` when F reads only columns of the record. The interpreter then runs F on an
// object of those columns, and each output prints the record as `.` would. A table takes its header from the file,
// so --to csv/tsv applies only to a single file.
@(private = "file")
select_columns :: proc(run: ^Run, body: ^jq.Node, files: int) -> ^Columns {
	o := &run.opts
	whys: Explain_Whys
	if run.home_module {
		whys += {.Home_Module}
	}
	if writes_cells(o) {
		whys += ({.Grow_Header} if o.grow_header else {}) + ({.Several_Files} if files > 1 else {})
	} else if !o.compact {
		whys += {.Layout}
	}
	if whys != {} && !explain_why(run, whys) {
		return nil
	}
	watch: [dynamic]string
	if len(body.args) != 1 {
		whys += {.Not_Columns}
	} else if !only_columns(body.args[0], &watch) {
		whys += {.Select_Columns}
	}
	if whys != {} {
		explain_why(run, whys)
		return nil
	}
	cols := Columns{object = true, all = true, sorted = o.sort_keys, selecting = true, watch = watch[:]}
	cols.watch_at = make([]int, len(watch))
	return new_clone(cols)
}

// Reports whether the expression `n`, run on a record, reads the record only as `.name`, and appends those names
// to `watch`. The right side of a `|` does not run on the record and is not inspected. Any other use of `.`, a call
// that reads `.` implicitly, a binding, or an `if` without `else` fails the check. A nested `select` runs its
// argument on the same input as `n`.
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

// The members' leads of the objects `cells_object` writes: each key printed, `{"key":` for the first, `,"key":` for the
// rest.
Heads :: struct {
	leads:       []string,
	key_escaped: bool, // a key's printed form has an escape
}

// Returns each key printed as the lead of its member.
object_heads :: proc(keys: []string, allocator := context.allocator) -> (heads: Heads) {
	heads.leads = make([]string, len(keys), allocator)
	buf: [dynamic]byte
	for k, i in keys {
		clear(&buf)
		append(&buf, '{' if i == 0 else ',')
		jq.write_string(&buf, k)
		append(&buf, ':')
		heads.key_escaped |= bytes.index_byte(buf[:], '\\') >= 0
		heads.leads[i] = string(slice.clone(buf[:], allocator))
	}
	delete(buf)
	return
}

// Appends the column names of `n` (`.a` or `.a, .b`) to `names` in order. Returns false for any other `n`.
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

// Sets the header indices of `cols`' names.
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
				cols.at[i], _ = slice.linear_search(header, k)
			}
		}
		cols.heads = object_heads(cols.keys)
	}
	for name, i in cols.watch {
		cols.watch_at[i], _ = slice.linear_search(header, name)
	}
	cols.watch_heads = object_heads(cols.watch)
	if !cols.all {
		for name, i in cols.names {
			cols.at[i], _ = slice.linear_search(header, name)
		}
	}
}

// Prints the columns of the files' records with the same results as `run_filter`. The run stops at a fault in a
// file, at a halt, and after the first record read once a file has failed to open.
scan_cells :: proc(run: ^Run, ins: ^Inputs) {
	c, cols := cells_of(ins), run.columns
	fetched := false
	for (ins.failures == 0 || !fetched) && !run.halted {
		if c.file == nil {
			msg, status := open_cells(ins, c)
			if status != .Value {
				if status == .Error {
					parse_failed(run, msg)
				}
				return
			}
			place_columns(cols, c.header)
			explain_file(run)
			if ins.failures == 0 && !c.streamed {
				if runner := batch_runner(run, len(c.data)); runner != nil && (cols.object || !opens_with_bom(run, c, cols)) && table_openable(run, cols) {
					fetched = true
					if print_cells_in_pieces(run, c, cols, runner) {
						continue // the main thread reads the rest of the file
					}
					if msg = cells_ended(ins, c); msg != "" {
						parse_failed(run, msg)
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
			parse_failed(run, msg)
			return
		}
	}
}

// Runs the filter on the record's watched columns as `run_filter` would. Each output prints the whole record.
@(private = "file")
select_cell :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) {
	if cols.arena.curr_block == nil {
		input_arena(run, &cols.arena)
	}
	context.allocator = virtual.arena_allocator(&cols.arena)
	defer virtual.arena_free_all(&cols.arena)
	selected := Selected{cols, rec, dialect}
	run.selected = &selected
	run_once(run, record_doc(cols.watch_heads, cols.watch_at, rec, dialect))
	run.selected = nil
}

Select_Result :: enum {
	Done,
	Failed, // an error, a halt, or a message the main thread reports instead; the record's outputs are dropped
}

// Runs `select_cell` on a pool thread's copy of the run. It reports nothing; the caller stops at a failure.
@(private = "file")
select_record :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect, arena: ^virtual.Arena) -> Select_Result {
	context.allocator = virtual.arena_allocator(arena)
	defer virtual.arena_free_all(arena)
	selected := Selected{cols, rec, dialect}
	run.selected = &selected
	sig := eval_input(run, record_doc(cols.watch_heads, cols.watch_at, rec, dialect))
	run.selected = nil
	failed := sig == .Fail || sig == .Break || len(run.ip.messages) > 0 || run.faulted
	return .Failed if failed else .Done
}

// Reports whether the first output record would start with a byte order mark: the first cell of the first record
// after the header, when the table has not begun. Only the sequential print handles that case.
@(private = "file")
opens_with_bom :: proc(run: ^Run, c: ^Cells, cols: ^Columns) -> bool {
	if run.table == nil || run.rows_begun || cols.at[0] < 0 {
		return false
	}
	probe := csv.records(c.data, {dialect = c.dialect}, context.temp_allocator)
	defer free_all(context.temp_allocator)
	_, _ = csv.next_record(&probe)
	rec, ok := csv.next_record(&probe)
	if !ok || cols.at[0] >= len(rec.fields) {
		return false
	}
	text, _, _ := csv.field_text(rec.src, rec.fields[cols.at[0]], c.dialect, context.temp_allocator)
	return bytes.has_prefix(text, UTF8_BOM[:])
}

// Prints the record's output as `print_jq` would: each cell on its own line, or all cells in one array or object.
// Under --to csv/tsv each output is a table record. Returns false when a pool thread's copy refuses a record; the
// main thread then takes over the run.
print_cells :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) -> bool {
	if run.table != nil {
		return print_cell_rows(run, cols, rec, dialect)
	}
	if cols.object {
		cells_object(&run.out, cols.heads, cols.at, rec, dialect)
		end_output(run)
		return true
	}
	raw, out := run.opts.raw && !cols.array, &run.out
	if cols.array {
		append(out, '[')
	}
	for at, i in cols.at {
		if i > 0 && cols.array {
			append(out, ',')
		}
		null := put_cell(out, rec, at, dialect, raw)
		if !cols.array {
			end_output(run)
			run.ret = JQ_OK_NULL_KIND if null else JQ_OK
		}
	}
	if cols.array {
		append(out, ']')
		end_output(run)
	}
	return true
}

// Appends the cell at column `at` of `rec` as a JSON string, or as its text when `raw`; `null` for a column the
// header lacks and for a cell of no bytes. Returns whether it appended null.
@(private = "file")
put_cell :: proc(out: ^[dynamic]byte, rec: csv.Record, at: int, dialect: csv.Dialect, raw: bool) -> (null: bool) {
	cell, decoded := column_cell(rec, at, dialect)
	text, present := cell.?
	if !present {
		append(out, "null")
		return true
	}
	if raw {
		append(out, text)
	} else {
		jq.write_string(out, text)
	}
	if decoded {
		free_all(context.temp_allocator)
	}
	return false
}

// The bytes of text that `cells_object` writes for the cells at `at` (every field when nil), unless escapes outgrow it.
object_room :: proc(heads: Heads, at: []int, rec: csv.Record) -> int {
	room := 2 + 6 * len(heads.leads)
	for head, i in heads.leads {
		room += len(head)
		if k := i if at == nil else at[i]; k >= 0 {
			room += int(rec.fields[k].hi - rec.fields[k].lo)
		}
	}
	return room
}

// Writes the cells at `at` (every field when nil) as `{"key":"cell",...}` onto `out`, `heads` being the member
// leads as `object_heads` spells them. With `doc`, also its rows for that text, spans counted from where the object
// begins: the object's, then a member's each, and a string with an escape flagged and decoded into `doc.values`.
// `doc.rows` has room for them, zeroed.
cells_object :: proc(out: ^[dynamic]byte, heads: Heads, at: []int, rec: csv.Record, dialect: csv.Dialect, doc: ^core_pkg.Row_Document = nil) {
	base, root := len(out), 0
	row: [^]core_pkg.Row
	if doc != nil {
		root = len(doc.rows)
		row = raw_data(doc.rows)[root:]
	}
	w := base
	for head, i in heads.leads {
		cell, decoded := column_cell(rec, i if at == nil else at[i], dialect)
		lead := w
		w = jq.write_led_cell(out, w, head, cell)
		if doc != nil {
			// The rest of a zeroed row is zero.
			r := &row[i + 1]
			lo := lead + len(head) - base
			r.lo, r.hi, r.key_lo, r.key_hi, r.subtree_size = u32(lo), u32(w - base), u32(lead + 1 - base), u32(lo - 1), 1
			r.kind = .String if cell != nil else .Null
			if text, ok := cell.?; ok && int(r.hi - r.lo) != len(text) + 2 {
				decode_escaped(doc, r, raw_data(out^)[base + lo:w], text)
			}
		}
		if decoded {
			free_all(context.temp_allocator)
		}
	}
	scan.edge_publish(out, w)
	if len(heads.leads) == 0 {
		append(out, '{')
	}
	append(out, '}')
	if doc == nil {
		return
	}
	row[0] = {hi = u32(len(out) - base), key_lo = core_pkg.NO_KEY, key_hi = core_pkg.NO_KEY, subtree_size = u32(len(heads.leads) + 1), kind = .Object, cnt = u32(len(heads.leads))}
	scan.edge_publish(&doc.rows, root + len(heads.leads) + 1)
	if !heads.key_escaped {
		return
	}
	text := out[base:]
	for &r in doc.rows[root + 1:] {
		if bytes.index_byte(text[r.key_lo:r.key_hi], '\\') >= 0 {
			r.flags += {.Key_Escaped}
		}
	}
}

// Flags the string row `r`, whose text `token` was spelled from `decoded` and is longer than it, as an escaped
// string whose decoding is in `doc.values`.
@(private = "file")
decode_escaped :: proc(doc: ^core_pkg.Row_Document, r: ^core_pkg.Row, token: []byte, decoded: string) {
	r.first_esc = u16(min(bytes.index_byte(token, '\\'), int(max(u16))))
	r.payload.str = {u32(len(doc.values)), u32(len(decoded))}
	r.flags += {.Str_Escaped, .Decoded}
	append(&doc.values, decoded)
}

// Returns the cell of column `at` of `rec`, and whether it was decoded into the temporary allocator, which the
// caller then frees. Returns nil when the header lacks the column or the cell is empty.
column_cell :: #force_inline proc(rec: csv.Record, at: int, dialect: csv.Dialect) -> (cell: Maybe(string), decoded: bool) {
	if at < 0 || rec.fields[at].lo == rec.fields[at].hi {
		return nil, false
	}
	text, escaped, _ := csv.field_text(rec.src, rec.fields[at], dialect, context.temp_allocator)
	return string(text), escaped
}

// Writes the record's columns as table rows: one row of all cells, or one row per cell.
@(private = "file")
print_cell_rows :: proc(run: ^Run, cols: ^Columns, rec: csv.Record, dialect: csv.Dialect) -> bool {
	defer free_all(context.temp_allocator)
	if cols.array || cols.object {
		cells := make([]Maybe(string), len(cols.at), context.temp_allocator)
		for at, i in cols.at {
			cells[i], _ = column_cell(rec, at, dialect)
		}
		if !(put_object_row(run, cols.keys, cells) if cols.object else put_row(run, cells)) {
			return false
		}
		run.ret = JQ_OK
		flush_some(run)
		return true
	}
	for at in cols.at {
		one: [1]Maybe(string)
		one[0], _ = column_cell(rec, at, dialect)
		if !put_row(run, one[:]) {
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

// The `Record_Piece.stop` value for a record the filter failed on. The main thread runs that record again.
SELECT_STOP :: 2

// Reports whether a table of objects printed by the pieces can start with the header from `cols`.
@(private = "file")
table_openable :: proc(run: ^Run, cols: ^Columns) -> bool {
	return !cols.object || run.table == nil || run.table.shape != .Unset || header_writable(run, cols.keys)
}

// Prints the records of the open, whole file on the pool, in order. On a fault, the file is read again from its
// start without printing, so that `cells_ended` reports the fault as a sequential read does.
@(private = "file")
print_cells_in_pieces :: proc(run: ^Run, c: ^Cells, cols: ^Columns, runner: ^csv.Batch_Runner) -> (resumed: bool) {
	explain_piece(run, .Csv)
	job := Cells_Scan{cols = cols, dialect = c.dialect}
	start_pieces(&job, run)
	defer end_pieces(&job)
	// A table of objects starts with the header, written before the first output.
	if cols.object && run.table != nil && run.table.shape == .Unset {
		job.table_due, job.keys = true, cols.keys
	}
	fault := csv.each_record(c.data, print_cells_piece, &job, {dialect = c.dialect}, runner)
	// A write that failed on a pool thread ends the run here.
	check_output()
	if job.stop == TABLE_STOP {
		table_fail(run, "%s", row_refusal(run.table, .Unwritable))
	}
	if job.stop == SELECT_STOP {
		// The filter failed on the next record. The main thread reruns it and reads the rest sequentially.
		for _ in 0 ..< job.records {
			_, _ = csv.next_record(&c.whole)
		}
		return true
	}
	if _, bad := fault.?; bad {
		csv.destroy(&c.whole)
		c.whole = csv.records(c.data, {dialect = c.dialect}, runtime.heap_allocator())
		c.it = &c.whole
		for _ in csv.next_record(&c.whole) {}
	}
	return false
}

// Prints piece `k`'s records into its buffer with a copy of the run, then writes every piece whose turn has come.
// A fault in the piece's text ends the piece, and later pieces are not printed. Piece 0 starts at the header.
@(private = "file")
print_cells_piece :: proc(data: rawptr, piece: ^csv.Records, k: int) -> bool {
	job := (^Cells_Scan)(data)
	run := begin_piece(job, k, len(piece.src) - piece.rec_lo)
	p := Record_Piece{done = true, stop = -1}
	header := k == 0
	run.rows_begun = true // `opens_with_bom` checked the output's first record, so no piece opens the output
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
