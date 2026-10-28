package main

// CSV lanes, named `csv_<job>[_<shape>]`, over gen.py's fixtures (`table.csv`, `text.csv`, `wide.csv`,
// `table.tsv`). `--fixture` picks another file; a `.tsv` name is read as `csv.TSV`. Every lane prints
// `gb_per_s` and `ns` over the fixture's bytes. The lanes that walk records also print `records`, `fields`
// and `bytes` (the decoded cells' total length, header record included), which bench/compare.py checks the
// other libraries' totals against. With STURY_DUMP set, a typed lane writes the rows it read there as JSON
// and a marshal lane writes the CSV it produced.
//
//	csv_validate              `validate` at `.Strict`
//	csv_records               every field of every record, decoded
//	csv_document              `build`
//	csv_document_read         `build`, then every cell read as a string
//	csv_unmarshal_<shape>     `unmarshal` into []Csv_<Shape>_Row, strings copied; `_borrow`: strings slice the input
//	csv_marshal_<shape>       `marshal` of the rows `unmarshal` read

import csv "stury:csv"
import json "stury:json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:time"

// A row of table.csv (numeric).
Csv_Table_Row :: struct {
	id, ts:         i64,
	lat, lon:       f64,
	qty:            i64,
	price, score:   f64,
	ok:             bool,
	code:           string,
}

// A row of text.csv (quoted cells, UTF-8, LFs inside cells).
Csv_Text_Row :: struct {
	id:                        i64,
	name, city, quote, note:   string,
}

// Totals from one pass over a document. `bytes` is the decoded cells' total length.
Csv_Tally :: struct {
	records, fields, bytes: u64,
}

csv_dialect :: proc(fixture: string) -> csv.Dialect {
	return csv.TSV if strings.has_suffix(fixture, ".tsv") else csv.Dialect{}
}

csv_report :: proc(data: []byte, ns: i64, extra: string) {
	fmt.printf("gb_per_s=%.4g ns=%d %s rss_bytes=%d\n", f64(len(data)) / f64(ns), ns, extra, rss_growth(RSS_MARK))
}

csv_tally_text :: proc(t: Csv_Tally) -> string {
	return fmt.tprintf("records=%d fields=%d bytes=%d", t.records, t.fields, t.bytes)
}

// Decodes every field of every record. A quoted cell's text slices the input unless it contains `""`; then
// `field_text` decodes it into `scratch`, which is reset after each such cell.
csv_walk_records :: proc(data: []byte, dialect: csv.Dialect, scratch: ^mem.Arena) -> (t: Csv_Tally, ok: bool) {
	it := csv.records(data, {dialect = dialect})
	defer csv.destroy(&it)
	a := mem.arena_allocator(scratch)
	for rec in csv.next_record(&it) {
		t.records += 1
		t.fields += u64(len(rec.fields))
		for _, k in rec.fields {
			text, escaped, err := csv.field_text(rec, k, a)
			if err != nil {
				return t, false
			}
			t.bytes += u64(len(text))
			if escaped {
				mem.arena_free_all(scratch)
			}
		}
	}
	return t, it.err == nil
}

// Reads the header's names as the first record's keys, and every cell through `get_string`, a null cell as empty.
csv_read_document :: proc(doc: ^csv.Document) -> (t: Csv_Tally, ok: bool) {
	t.records = u64(csv.child_count(doc, csv.ROOT)) + 1
	head := csv.members(doc, csv.child(doc, csv.ROOT, 0))
	for name in csv.members(&head) {
		t.fields += 1
		t.bytes += u64(len(name))
	}
	all := csv.children(doc, csv.ROOT)
	for rec in csv.children(&all) {
		cells := csv.children(doc, rec)
		for c in csv.children(&cells) {
			s, _ := csv.get_string(doc, c)
			t.fields += 1
			t.bytes += u64(len(s))
		}
	}
	return t, true
}

bench_csv_validate :: proc(data: []byte, dialect: csv.Dialect) -> bool {
	once :: proc(data: []byte, dialect: csv.Dialect) -> bool {
		return csv.validate(data, {dialect = dialect}) == nil
	}
	ns, ok := time_median(data, dialect, once)
	if ok {
		csv_report(data, ns, "")
	}
	return ok
}

bench_csv_records :: proc(data: []byte, dialect: csv.Dialect) -> bool {
	scratch: mem.Arena
	buf := make([]byte, 1 << 20)
	defer delete(buf)
	mem.arena_init(&scratch, buf)
	tally: Csv_Tally
	times: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		t := time.tick_now()
		seen, ok := csv_walk_records(data, dialect, &scratch)
		d := i64(time.tick_since(t))
		if !ok {
			return false
		}
		tally = seen
		keep_timed(&times, i, d)
	}
	csv_report(data, median(times), csv_tally_text(tally))
	return true
}

bench_csv_document :: proc(data: []byte, dialect: csv.Dialect, read: bool) -> bool {
	tally: Csv_Tally
	times: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		t := time.tick_now()
		doc, err := csv.build(data, {dialect = dialect})
		ok := err == nil
		if ok && read {
			tally, ok = csv_read_document(&doc)
		}
		d := i64(time.tick_since(t))
		if ok && !read {
			tally.records = u64(csv.child_count(&doc, csv.ROOT)) + 1
			tally.fields = u64(len(doc.rows)) - 1
		}
		csv.destroy(&doc)
		if !ok {
			return false
		}
		keep_timed(&times, i, d)
	}
	extra := csv_tally_text(tally) if read else fmt.tprintf("records=%d fields=%d", tally.records, tally.fields)
	csv_report(data, median(times), extra)
	return true
}

// Frees `s` when `unmarshal` copied it, that is, when it does not slice `data`.
csv_free_string :: proc(s: string, data: []byte) {
	p, lo := uintptr(raw_data(s)), uintptr(raw_data(data))
	if len(s) > 0 && (p < lo || p >= lo + uintptr(len(data))) {
		delete(s)
	}
}

csv_release :: proc(rows: []$T, data: []byte) {
	for &r in rows {
		when T == Csv_Table_Row {
			csv_free_string(r.code, data)
		} else {
			csv_free_string(r.name, data)
			csv_free_string(r.city, data)
			csv_free_string(r.quote, data)
			csv_free_string(r.note, data)
		}
	}
	delete(rows)
}

// Times `unmarshal` of `data` into a heap `[]T`. The previous rows are freed outside the clock.
bench_csv_unmarshal :: proc(data: []byte, dialect: csv.Dialect, $T: typeid, borrow: bool) -> bool {
	opts := csv.Unmarshal_Opts{dialect = dialect, borrow_strings = borrow}
	plan := csv.type_plan_init([]T)
	defer csv.destroy(&plan)
	rows: []T
	times: [TIMED_ITERS]i64
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		csv_release(rows, data)
		rows = nil
		t := time.tick_now()
		err := csv.unmarshal(data, &rows, opts, &plan, context.allocator)
		d := i64(time.tick_since(t))
		if err != nil {
			fmt.eprintln("csv unmarshal:", err)
			return false
		}
		keep_timed(&times, i, d)
	}
	if path, found := os.lookup_env("STURY_DUMP", context.temp_allocator); found {
		dump, merr := json.marshal(rows, allocator = context.temp_allocator)
		if merr != nil || os.write_entire_file(path, dump) != nil {
			return false
		}
	}
	csv_report(data, median(times), fmt.tprintf("records=%d", len(rows)))
	return true
}

// Times `marshal` of the rows read from `data` before timing. Each output is freed outside the clock.
bench_csv_marshal :: proc(data: []byte, dialect: csv.Dialect, $T: typeid) -> bool {
	rows: []T
	if err := csv.unmarshal(data, &rows, {dialect = dialect, borrow_strings = true}, nil, context.allocator); err != nil {
		fmt.eprintln("csv unmarshal:", err)
		return false
	}
	plan := csv.type_plan_init([]T)
	defer csv.destroy(&plan)
	times: [TIMED_ITERS]i64
	out_len := 0
	dump, dumping := os.lookup_env("STURY_DUMP", context.temp_allocator)
	for i in 0 ..< WARMUP_ITERS + TIMED_ITERS {
		t := time.tick_now()
		out, err := csv.marshal(rows, {dialect = dialect}, &plan)
		d := i64(time.tick_since(t))
		if err != nil {
			return false
		}
		out_len = len(out)
		if dumping && i == 0 && os.write_entire_file(dump, out) != nil {
			return false
		}
		delete(out)
		keep_timed(&times, i, d)
	}
	csv_report(data, median(times), fmt.tprintf("records=%d out_bytes=%d", len(rows), out_len))
	return true
}

// Runs a `csv_` lane over `data`, the bytes of `fixture`. `known` is false for an unknown lane name.
bench_csv :: proc(lane: string, data: []byte, fixture: string) -> (ok: bool, known: bool) {
	dialect := csv_dialect(fixture)
	switch lane {
	case "csv_validate":
		return bench_csv_validate(data, dialect), true
	case "csv_records":
		return bench_csv_records(data, dialect), true
	case "csv_document":
		return bench_csv_document(data, dialect, false), true
	case "csv_document_read":
		return bench_csv_document(data, dialect, true), true
	case "csv_unmarshal_table":
		return bench_csv_unmarshal(data, dialect, Csv_Table_Row, false), true
	case "csv_unmarshal_table_borrow":
		return bench_csv_unmarshal(data, dialect, Csv_Table_Row, true), true
	case "csv_unmarshal_text":
		return bench_csv_unmarshal(data, dialect, Csv_Text_Row, false), true
	case "csv_unmarshal_text_borrow":
		return bench_csv_unmarshal(data, dialect, Csv_Text_Row, true), true
	case "csv_marshal_table":
		return bench_csv_marshal(data, dialect, Csv_Table_Row), true
	case "csv_marshal_text":
		return bench_csv_marshal(data, dialect, Csv_Text_Row), true
	}
	return false, false
}
