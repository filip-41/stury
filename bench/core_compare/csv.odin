package main

// The CSV half: stury's csv against Odin's core:encoding/csv, on table.csv and text.csv. The jobs, and how each
// arm is configured:
//
//   Read every field   core: a Reader with reuse_record and reuse_record_buffer, fields_per_record 0 (the first
//                      record sets the width, as stury's does), lazy_quotes false; it makes no UTF-8 check.
//                      stury: `records` and `field_text` on every field at .Strict (structure, UTF-8, field counts).
//   Load all records   core: `read_all` (every field cloned). stury: `build`, then every cell read as a string.
//                      Both arms then add up every field's length.
//   Write all records  core: `Writer` `write` per record into a strings.Builder (`write_all` is that loop plus
//                      a flush, which a Builder's stream refuses as .Unsupported). stury: `write_record` per
//                      record (stury has no writer for [][]string), an empty cell as nil so it is written bare,
//                      as core does. The cells are parsed once, outside the clock.
//
// Before timing, both readers must read the same record count, field count and field bytes (a digest over
// every field's length and bytes), and each writer's text must read back to those cells in both readers.

import "base:runtime"
import core_csv "core:encoding/csv"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import csv "stury:csv"

// Records, fields and field bytes read, and a digest over the field sequence: each field's length and bytes.
Csv_Tally :: struct {
	records, fields, bytes, digest: u64,
}

Csv_Writer :: #type proc(alloc: runtime.Allocator) -> (out: []byte, ok: bool)

// The cells the write arms write, parsed once from the fixture by `core_csv`.
write_cells: [][]string

// Room for the decoded text of one `""`-escaped field, as the probe's csv_records lane gives it.
FIELD_SCRATCH :: 1 << 20

tally_field :: #force_inline proc(t: ^Csv_Tally, s: string, $DIGEST: bool) {
	t.fields += 1
	t.bytes += u64(len(s))
	when DIGEST {
		h := (t.digest ~ u64(len(s))) * 0x100000001b3
		for b in transmute([]byte)s {
			h = (h ~ u64(b)) * 0x100000001b3
		}
		t.digest = h
	}
}

run_csv :: proc(dir: string, rounds: int) -> bool {
	fmt.println()
	fmt.println("| Job | Input | stury ms | core:encoding/csv ms | stury speedup |")
	fmt.println("| --- | --- | ---: | ---: | ---: |")
	ok := true
	for name in ([]string{"table.csv", "text.csv"}) {
		ok &= run_csv_fixture(dir, name, rounds)
	}
	return ok
}

run_csv_fixture :: proc(dir, name: string, rounds: int) -> bool {
	path := fmt.tprintf("%s/%s", dir, name)
	src, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintf("cannot read %s: %v (run `python3 bench/gen.py` first)\n", path, err)
		return false
	}
	defer delete(src)
	if !csv_agrees(src, name) {
		return false
	}
	label := fmt.tprintf("%s, %.1f MB", name, f64(len(src)) / 1e6)
	lanes := []Lane {
		{"Read every field (core: no UTF-8 check)", stury_csv_read, core_csv_read},
		{"Load all records", stury_csv_load, core_csv_load},
		{"Write all records", stury_csv_write, core_csv_write},
	}
	ok := true
	for lane in lanes {
		s, c, lane_ok := time_lane(src, lane, rounds)
		if !lane_ok {
			fmt.eprintf("%s on %s failed\n", lane.name, name)
			ok = false
			continue
		}
		fmt.printf("| %s | %s | %.2f | %.2f | %.1f× |\n", lane.name, label, ms(s), ms(c), f64(c) / f64(s))
	}
	return ok
}

core_csv_read_tally :: proc(src: []byte, alloc: runtime.Allocator, $DIGEST: bool) -> (t: Csv_Tally, ok: bool) {
	context.allocator = alloc
	r: core_csv.Reader
	r.reuse_record, r.reuse_record_buffer = true, true
	core_csv.reader_init_with_string(&r, string(src), alloc)
	for {
		record, err := core_csv.read(&r)
		if core_csv.is_io_error(err, .EOF) {
			return t, true
		}
		if err != nil {
			return t, false
		}
		t.records += 1
		for f in record {
			tally_field(&t, f, DIGEST)
		}
	}
}

stury_csv_read_tally :: proc(src: []byte, alloc: runtime.Allocator, $DIGEST: bool) -> (t: Csv_Tally, ok: bool) {
	it := csv.records(src, {}, alloc)
	scratch: mem.Arena
	mem.arena_init(&scratch, make([]byte, FIELD_SCRATCH, alloc))
	a := mem.arena_allocator(&scratch)
	for rec in csv.next_record(&it) {
		t.records += 1
		for f in rec.fields {
			text, escaped, err := csv.field_text(src, f, {}, a)
			if err != nil {
				return t, false
			}
			tally_field(&t, string(text), DIGEST)
			if escaped {
				mem.arena_free_all(&scratch)
			}
		}
	}
	return t, it.err == nil
}

core_csv_load_tally :: proc(src: []byte, alloc: runtime.Allocator, $DIGEST: bool) -> (t: Csv_Tally, ok: bool) {
	context.allocator = alloc
	r: core_csv.Reader
	core_csv.reader_init_with_string(&r, string(src), alloc)
	records, err := core_csv.read_all(&r, alloc)
	if err != nil {
		return t, false
	}
	t.records = u64(len(records))
	for record in records {
		for f in record {
			tally_field(&t, f, DIGEST)
		}
	}
	return t, true
}

stury_csv_load_tally :: proc(src: []byte, alloc: runtime.Allocator, $DIGEST: bool) -> (t: Csv_Tally, ok: bool) {
	doc, err := csv.build(src, {}, alloc)
	if err != nil {
		return t, false
	}
	t.records = u64(csv.row_count(&doc)) + 1
	for col in 0 ..< csv.column_count(&doc) {
		tally_field(&t, csv.get_name(&doc, col) or_return, DIGEST)
	}
	for row in 0 ..< csv.row_count(&doc) {
		for col in 0 ..< csv.column_count(&doc) {
			tally_field(&t, csv.get_string(&doc, row, col) or_return, DIGEST)
		}
	}
	return t, true
}

// The text `write_cells` becomes with core's Writer, allocated with `alloc`.
core_csv_written :: proc(alloc: runtime.Allocator) -> (out: []byte, ok: bool) {
	sb := strings.builder_make(alloc)
	w: core_csv.Writer
	core_csv.writer_init(&w, strings.to_writer(&sb))
	for record in write_cells {
		if core_csv.write(&w, record) != nil {
			return nil, false
		}
	}
	return sb.buf[:], true
}

// The text `write_cells` becomes with `write_record`, allocated with `alloc`. An empty cell is nil: written
// bare, where a present empty text would be written `""`.
stury_csv_written :: proc(alloc: runtime.Allocator) -> (out: []byte, ok: bool) {
	buf := make([dynamic]u8, alloc)
	cells := make([dynamic]Maybe(string), alloc)
	for record, i in write_cells {
		resize(&cells, len(record))
		for s, k in record {
			cells[k] = s if len(s) > 0 else nil
		}
		if csv.write_record(&buf, cells[:], at_start = i == 0) != .None {
			return nil, false
		}
	}
	return buf[:], true
}

stury_csv_read :: proc(src: []byte, alloc: runtime.Allocator) -> bool {
	_, ok := stury_csv_read_tally(src, alloc, false)
	return ok
}

core_csv_read :: proc(src: []byte, alloc: runtime.Allocator) -> bool {
	_, ok := core_csv_read_tally(src, alloc, false)
	return ok
}

stury_csv_load :: proc(src: []byte, alloc: runtime.Allocator) -> bool {
	_, ok := stury_csv_load_tally(src, alloc, false)
	return ok
}

core_csv_load :: proc(src: []byte, alloc: runtime.Allocator) -> bool {
	_, ok := core_csv_load_tally(src, alloc, false)
	return ok
}

stury_csv_write :: proc(_: []byte, alloc: runtime.Allocator) -> bool {
	_, ok := stury_csv_written(alloc)
	return ok
}

core_csv_write :: proc(_: []byte, alloc: runtime.Allocator) -> bool {
	_, ok := core_csv_written(alloc)
	return ok
}

// Checks, outside the clock, that both readers decode `src` to the same fields and that both writers' texts
// read back to those fields in both readers. Sets `write_cells` for the write arms.
csv_agrees :: proc(src: []byte, name: string) -> bool {
	defer virtual.arena_free_all(&arena)
	alloc := virtual.arena_allocator(&arena)
	core_read, c_ok := core_csv_read_tally(src, alloc, true)
	stury_read, s_ok := stury_csv_read_tally(src, alloc, true)
	core_load, cl_ok := core_csv_load_tally(src, alloc, true)
	stury_load, sl_ok := stury_csv_load_tally(src, alloc, true)
	if !(c_ok && s_ok && cl_ok && sl_ok) || core_read != stury_read || core_read != core_load || core_read != stury_load {
		fmt.eprintf("%s: the readers disagree or one failed (core read %v, stury read %v, core load %v, stury load %v); no lane timed\n", name, core_read, stury_read, core_load, stury_load)
		return false
	}
	// The write arms' input outlives every arena reset.
	reader: core_csv.Reader
	core_csv.reader_init_with_string(&reader, string(src))
	cells, err := core_csv.read_all(&reader)
	if err != nil {
		fmt.eprintf("%s: cannot read the cells to write: %v\n", name, err)
		return false
	}
	write_cells = cells
	texts: [2][]byte
	for written, i in ([2]Csv_Writer{stury_csv_written, core_csv_written}) {
		out, ok := written(alloc)
		back_core, bc_ok := core_csv_load_tally(out, alloc, true)
		back_stury, bs_ok := stury_csv_load_tally(out, alloc, true)
		if !(ok && bc_ok && bs_ok) || back_core != core_read || back_stury != core_read {
			fmt.eprintf("%s: writer %d's text does not read back to the fixture's cells (core reads %v, stury reads %v, want %v); no lane timed\n", name, i, back_core, back_stury, core_read)
			return false
		}
		texts[i] = out
	}
	if string(texts[0]) != string(texts[1]) {
		fmt.eprintf("%s: the writers' texts read back the same but differ in bytes (stury %d, core %d)\n", name, len(texts[0]), len(texts[1]))
	}
	return true
}
