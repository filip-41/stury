package main

// A filter that is only columns of a --from csv or --from tsv file (`.name`, `.a, .b`, `[.a, .b]` under -c or --to
// csv or tsv) answers from each record's cells, printed as the interpreter prints the same filter on the record's
// object: no object is built.
// A whole file past two workers' worth is read in `csv.each_record`'s pieces on the batch pool, each piece printed
// into a buffer of its own and written as soon as the pieces before it are. Any other filter runs on the interpreter
// (`next_cells`).

import "base:runtime"
import "core:bytes"
import "core:fmt"
import csv "../../csv"
import "jq"

// The columns a filter prints, in the order it prints them.
Columns :: struct {
	names: []string,
	array: bool, // `[...]`: one output, an array of the cells
	// Each name's place in the open file's header, -1 when the header lacks it (the output is then null).
	at:    []int,
}

// Whether the filter `text` is only columns, kept in `run.columns` when it is, with a command line that prints
// strings as `print_cells` does.
choose_columns :: proc(run: ^Run, text: string) {
	o := &run.opts
	if !reads_cells(o) || o.null_input || o.slurp || o.exit_status || o.color || o.ascii || o.raw0 {
		return
	}
	parsed, errors := jq.parse(text)
	if len(errors) > 0 || len(parsed.deps) > 0 || parsed.body == nil {
		return
	}
	body := parsed.body
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
	for name, i in cols.names {
		cols.at[i] = -1
		for h, j in header {
			if h == name {
				cols.at[i] = j
				break
			}
		}
	}
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
				if runner := batch_runner(run, len(c.data)); runner != nil && !opens_with_bom(run, c, cols) {
					print_cells_in_pieces(run, c, cols, runner)
					fetched = true
					if msg = cells_ended(ins, c); msg != "" {
						cells_failed(run, msg)
						return
					}
					continue
				}
			}
		}
		if rec, ok := next_cell(c); ok {
			print_cells(run, cols, rec, c.dialect)
			fetched = true
		} else if msg := cells_ended(ins, c); msg != "" {
			cells_failed(run, msg)
			return
		}
	}
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
	raw, out := run.opts.raw && !cols.array, &run.out
	if cols.array {
		append(out, '[')
	}
	for at, i in cols.at {
		if cols.array && i > 0 {
			append(out, ',')
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
	if cols.array {
		cells := make([]Maybe(string), len(cols.at), context.temp_allocator)
		for at, i in cols.at {
			cells[i] = column_cell(rec, at, dialect)
		}
		if !put_row_or_stop(run, cells) {
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

// Print the open whole file's records, on the pool, in order. A fault the pieces meet is found again by reading the
// file through from its start (printing nothing), so that `cells_ended` tells it as a read of the file does.
@(private = "file")
print_cells_in_pieces :: proc(run: ^Run, c: ^Cells, cols: ^Columns, runner: ^csv.Batch_Runner) {
	job := Cells_Scan{cols = cols, dialect = c.dialect}
	start_pieces(&job, run)
	defer end_pieces(&job)
	fault := csv.each_record(c.data, c.dialect, print_cells_piece, &job, runner)
	// A write a pool thread met failing ends the run here.
	check_output()
	if job.stop == TABLE_STOP {
		table_fail(run, "%s", row_refusal(run.table, .Unwritable))
	}
	if _, bad := fault.?; bad {
		csv.records_destroy(&c.whole)
		c.whole = csv.records(c.data, c.dialect, allocator = runtime.heap_allocator())
		c.it = &c.whole
		for _ in csv.next_record(&c.whole) {}
	}
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
	for rec in csv.next_record(piece) {
		if header {
			header = false
			continue
		}
		p.answered = true
		if !print_cells(&run, job.cols, rec, job.dialect) {
			p.stop = TABLE_STOP
			break
		}
	}
	if _, bad := piece.err.?; bad && p.stop < 0 {
		p.stop = 0
	}
	p.out, p.ret = run.out, run.ret
	return publish_piece(job, k, p)
}
