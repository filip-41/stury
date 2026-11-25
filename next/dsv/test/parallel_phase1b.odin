package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:host"
import "stury:lib/core/tape"
import "stury:testkit"

@(private = "file")
Csv_Row :: struct {
	id:    i64    `csv:"id"`,
	name:  string `csv:"name"`,
	score: f64    `csv:"score"`,
	ok:    bool   `csv:"ok"`,
	note:  string `csv:"note"`,
}

@(private = "file")
make_large_dsv :: proc(rows: int, spec: dsv.Spec, dirty: bool, unclosed_quote: bool, allocator := context.allocator) -> []u8 {
	sep := "\t" if spec == .Tsv else ","
	b := strings.builder_make(0, rows * 64, allocator)
	fmt.sbprintf(&b, "id%sname%sscore%sok%snote\n", sep, sep, sep, sep)
	for i in 0 ..< rows {
		if dirty && (i == 7 || i == rows / 2 || i == rows - 5) {
			// Bad width (too few fields)
			fmt.sbprintf(&b, "%d%srow-%d\n", i, sep, i)
		} else if unclosed_quote && spec == .Csv && i == rows / 3 {
			// Unclosed quote in CSV (triggers astray serial fallback)
			fmt.sbprintf(&b, "%d,\"unclosed,1.5,true,bad\n", i)
		} else if spec == .Csv && i % 17 == 0 {
			// Multi-line quoted CSV cell with escaped quote
			fmt.sbprintf(&b, "%d,\"row \"\"%d\"\"\",%d.25,%v,\"line1\nline2\"\n", i, i, i % 100, i % 2 == 0)
		} else {
			fmt.sbprintf(&b, "%d%srow-%d%s%d.5%s%v%snote-%d\n", i, sep, i, sep, i % 100, sep, i % 2 == 0, sep, i)
		}
	}
	return transmute([]u8)strings.to_string(b)
}

@(test)
dsv_records_quarantine_and_max_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a,b\n1,2\n3\n4,5\n"
	q := make([dynamic]tape.Bad_Record)
	defer delete(q)
	r := dsv.records_open(transmute([]u8)src, .Lines, .Csv)
	defer tape.destroy_records(&r)
	r.quarantine = &q
	out: [8]tape.Record
	ans: [8]tape.Span_Answer
	n := dsv.records_find(&r, {tape.Name("b")}, out[:], ans[:])
	testing.expectf(t, n == 2 && len(q) == 1 && r.err == nil, "dsv quarantine: n=%d bad=%d err=%v", n, len(q), r.err)
	testing.expectf(t, string(q[0].text) == "3" && q[0].err != nil, "dsv bad: %q %v", q[0].text, q[0].err)

	// max_bytes on DSV
	wide_src := "a,b\n1,2\n1234567890,abcdefghij\n3,4\n"
	rm := dsv.records_open(transmute([]u8)wide_src, .Lines, .Csv)
	defer tape.destroy_records(&rm)
	rm.max_bytes = 8
	nm := dsv.records_find(&rm, {tape.Name("a")}, out[:], ans[:])
	f, is_f := rm.err.(tape.Fault)
	testing.expectf(t, nm == 1 && is_f && f.kind == .Too_Wide && tape.fault_rule(f).code == "too_long", "dsv max_bytes: nm=%d err=%v", nm, rm.err)
}

@(test)
parallel_dsv_validate_equals_serial :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in dsv.Spec {
		for dirty in ([]bool{false, true}) {
			src := make_large_dsv(12000, spec, dirty, false)
			defer delete(src)
			want := dsv.validate(src, spec)
			testing.expectf(t, (want == nil) == !dirty, "%v dirty=%v serial=%v", spec, dirty, want)
			for workers in ([]int{1, 2, 4, 18}) {
				pool: host.Pool
				_ = host.pool_init(&pool, workers)
				defer host.pool_destroy(&pool)
				got := dsv.validate(src, spec, {runner = &pool.runner})
				testing.expectf(t, got == want, "%v dirty=%v w=%d: got=%v want=%v", spec, dirty, workers, got, want)
			}
		}
	}
	// CSV with unclosed quote in middle -> parallel detects astray and returns exact serial fault.
	uq := make_large_dsv(12000, .Csv, false, true)
	defer delete(uq)
	want_uq := dsv.validate(uq, .Csv)
	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	got_uq := dsv.validate(uq, .Csv, {runner = &pool.runner})
	testing.expectf(t, got_uq == want_uq && got_uq != nil, "csv unclosed quote: got=%v want=%v", got_uq, want_uq)
}

@(test)
parallel_dsv_records_equal_serial :: proc(t: ^testing.T) {
	testkit.deadline(t)
	path := []tape.Step{tape.Name("score")}
	demand, _ := tape.demand_of({path, {tape.Name("name")}})
	defer tape.destroy_demand(&demand)

	for spec in ([]dsv.Spec{.Csv, .Tsv, .Plain}) {
		for mode in ([]int{0, 1, 2}) {
			if mode == 2 && spec != .Csv {
				continue
			}
			src := make_large_dsv(4500, spec, mode == 1, mode == 2)
			defer delete(src)

			// Serial validate
			rs := dsv.records_open(src, .Lines, spec)
			defer tape.destroy_records(&rs)
			sbad: [16]tape.Record
			sn := dsv.records_validate(&rs, sbad[:])

			// Serial find
			rfs := dsv.records_open(src, .Lines, spec)
			defer tape.destroy_records(&rfs)
			sfout := make([]tape.Record, 4600)
			defer delete(sfout)
			sfans := make([]tape.Span_Answer, 4600)
			defer delete(sfans)
			sfn := dsv.records_find(&rfs, path, sfout, sfans)

			// Serial scan
			rss := dsv.records_open(src, .Lines, spec)
			defer tape.destroy_records(&rss)
			ssout := make([]tape.Record, 4600)
			defer delete(ssout)
			ssdocs := make([]tape.Document, 4600)
			defer delete(ssdocs)
			ssn := dsv.records_scan(&rss, &demand, ssout, ssdocs)

			for workers in ([]int{1, 2, 4, 18}) {
				pool: host.Pool
				_ = host.pool_init(&pool, workers)
				defer host.pool_destroy(&pool)

				// Validate
				rp := dsv.records_open(src, .Lines, spec, {runner = &pool.runner})
				defer tape.destroy_records(&rp)
				pbad: [16]tape.Record
				pn := dsv.records_validate(&rp, pbad[:])
				testing.expectf(t, pn == sn && rp.index == rs.index && rp.err == rs.err, "%v mode=%d w=%d validate: pn=%d/%d idx=%d/%d", spec, mode, workers, pn, sn, rp.index, rs.index)
				for i in 0 ..< min(pn, sn) {
					testing.expectf(t, pbad[i] == sbad[i], "%v mode=%d w=%d bad[%d]: %v vs %v", spec, mode, workers, i, pbad[i], sbad[i])
				}

				// Find
				rfp := dsv.records_open(src, .Lines, spec, {runner = &pool.runner})
				defer tape.destroy_records(&rfp)
				pfout := make([]tape.Record, 4600)
				defer delete(pfout)
				pfans := make([]tape.Span_Answer, 4600)
				defer delete(pfans)
				pfn := dsv.records_find(&rfp, path, pfout, pfans)
				testing.expectf(t, pfn == sfn && rfp.index == rfs.index && rfp.err == rfs.err, "%v mode=%d w=%d find n=%d/%d", spec, mode, workers, pfn, sfn)
				for i in 0 ..< min(pfn, sfn) {
					testing.expectf(t, pfout[i] == sfout[i] && pfans[i] == sfans[i], "%v mode=%d w=%d find[%d]", spec, mode, workers, i)
				}

				// Scan
				rsp := dsv.records_open(src, .Lines, spec, {runner = &pool.runner})
				defer tape.destroy_records(&rsp)
				psout := make([]tape.Record, 4600)
				defer delete(psout)
				psdocs := make([]tape.Document, 4600)
				defer delete(psdocs)
				psn := dsv.records_scan(&rsp, &demand, psout, psdocs)
				testing.expectf(t, psn == ssn && rsp.index == rss.index && rsp.err == rss.err, "%v mode=%d w=%d scan n=%d/%d", spec, mode, workers, psn, ssn)
				for i in 0 ..< min(psn, ssn) {
					testing.expectf(t, psout[i] == ssout[i] && len(psdocs[i].nodes) == len(ssdocs[i].nodes), "%v mode=%d w=%d scan[%d]", spec, mode, workers, i)
				}
			}
		}
	}
}

@(test)
parallel_dsv_typed_unmarshal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in dsv.Spec {
		src := make_large_dsv(14000, spec, false, false)
		defer delete(src)

		va_ref: virtual.Arena
		_ = virtual.arena_init_growing(&va_ref)
		defer virtual.arena_destroy(&va_ref)
		want: []Csv_Row
		testing.expect(t, dsv.unmarshal(src, &want, spec, allocator = virtual.arena_allocator(&va_ref)) == nil)
		testing.expectf(t, len(want) == 14000, "%v want len=%d", spec, len(want))

		for workers in ([]int{1, 2, 4, 18}) {
			pool: host.Pool
			_ = host.pool_init(&pool, workers)
			defer host.pool_destroy(&pool)

			for borrow in ([]bool{false, true}) {
				// Arena (`.Blocks`)
				va: virtual.Arena
				_ = virtual.arena_init_growing(&va)
				defer virtual.arena_destroy(&va)
				got: []Csv_Row
				err := dsv.unmarshal(src, &got, spec, {borrow_strings = borrow}, {runner = &pool.runner}, virtual.arena_allocator(&va))
				testing.expectf(t, err == nil && len(got) == len(want), "%v w=%d borrow=%v arena err=%v len=%d", spec, workers, borrow, err, len(got))
				for i in 0 ..< min(len(got), len(want)) {
					if got[i] != want[i] {
						testing.expectf(t, false, "%v w=%d row[%d]: %v vs %v", spec, workers, i, got[i], want[i])
						break
					}
				}
			}
		}

		// Heap (`.Direct`) + Tracking_Allocator (fallback to serial)
		pool: host.Pool
		_ = host.pool_init(&pool, 4)
		defer host.pool_destroy(&pool)
		heap := runtime.heap_allocator()
		hgot: []Csv_Row
		herr := dsv.unmarshal(src, &hgot, spec, {borrow_strings = false}, {runner = &pool.runner}, heap)
		testing.expectf(t, herr == nil && len(hgot) == len(want), "%v heap err=%v", spec, herr)
		for row in hgot {
			delete(row.name, heap)
			delete(row.note, heap)
		}
		delete(hgot, heap)

		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, heap)
		defer mem.tracking_allocator_destroy(&track)
		ta := mem.tracking_allocator(&track)
		tgot: []Csv_Row
		terr := dsv.unmarshal(src, &tgot, spec, {borrow_strings = false}, {runner = &pool.runner}, ta)
		testing.expectf(t, terr == nil && len(tgot) == len(want), "%v tracking err=%v", spec, terr)
		for row in tgot {
			delete(row.name, ta)
			delete(row.note, ta)
		}
		delete(tgot, ta)
		testing.expectf(t, len(track.allocation_map) == 0 && len(track.bad_free_array) == 0, "%v tracking leaks=%d bad=%d", spec, len(track.allocation_map), len(track.bad_free_array))
	}

	// Faulty CSV typed unmarshal falls back cleanly to serial with zero leaks.
	bad_csv := make_large_dsv(14000, .Csv, true, false)
	defer delete(bad_csv)
	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	va_s, va_p: virtual.Arena
	_ = virtual.arena_init_growing(&va_s)
	_ = virtual.arena_init_growing(&va_p)
	defer virtual.arena_destroy(&va_s)
	defer virtual.arena_destroy(&va_p)
	srows, prows: []Csv_Row
	serr := dsv.unmarshal(bad_csv, &srows, .Csv, allocator = virtual.arena_allocator(&va_s))
	perr := dsv.unmarshal(bad_csv, &prows, .Csv, {}, {runner = &pool.runner}, virtual.arena_allocator(&va_p))
	testing.expectf(t, perr == serr && perr != nil, "dsv bad parallel typed: perr=%v serr=%v", perr, serr)
}

// Regression tests for Phase 1B adversarial review findings in DSV:
// - H4: `dsv.records_scan` under `no_header` when record 0 has a fault (`Lone_Cr` / `Invalid_Utf8`) and a different
//   column count than rows 1..N must match serial bit-for-bit without corrupting `r.width`.
// - C2: parallel `dsv.records_scan` with a shared non-thread-safe `opts.scratch` arena is data-race-free.
@(test)
parallel_dsv_review_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	pool: host.Pool
	_ = host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)

	// H4: `no_header` CSV & TSV where record 0 faults (2 cells) and rows 1..400 are valid (3 cells).
	for spec in ([]dsv.Spec{.Csv, .Tsv}) {
		sep := "\t" if spec == .Tsv else ","
		for fault_row in ([]string{
			fmt.tprintf("bad\rcell%ssecond\n", sep), // Lone_Cr, 2 columns
			fmt.tprintf("bad\xffcell%ssecond\n", sep), // Invalid_Utf8, 2 columns
		}) {
			b := strings.builder_make()
			defer strings.builder_destroy(&b)
			strings.write_string(&b, fault_row)
			for i in 1 ..= 400 {
				fmt.sbprintf(&b, "%d%sname-%05d-padding-payload%sok\n", i, sep, i, sep)
			}
			src := transmute([]u8)strings.to_string(b)

			demand, derr := tape.demand_of({[]tape.Step{tape.Index(0)}, []tape.Step{tape.Index(2)}})
			testing.expect(t, derr == nil)
			defer tape.destroy_demand(&demand)

			opts_s := dsv.Options{format = tape.Dsv_Options{no_header = true}}
			opts_p := dsv.Options{format = tape.Dsv_Options{no_header = true}, runner = &pool.runner}
			rs := dsv.records_open(src, .Lines, spec, opts_s)
			rp := dsv.records_open(src, .Lines, spec, opts_p)
			defer tape.destroy_records(&rs)
			defer tape.destroy_records(&rp)

			out_s := make([]tape.Record, 512)
			docs_s := make([]tape.Document, 512)
			out_p := make([]tape.Record, 512)
			docs_p := make([]tape.Document, 512)
			defer delete(out_s)
			defer delete(docs_s)
			defer delete(out_p)
			defer delete(docs_p)

			ns := dsv.records_scan(&rs, &demand, out_s, docs_s)
			np := dsv.records_scan(&rp, &demand, out_p, docs_p)
			testing.expectf(t, ns == np && rs.err == rp.err && rs.width == rp.width && rs.width == 3,
				"H4 %v: ns=%d np=%d width s=%d p=%d err s=%v p=%v", spec, ns, np, rs.width, rp.width, rs.err, rp.err)
			for i in 0 ..< min(ns, np) {
				if out_s[i] != out_p[i] {
					testing.expectf(t, false, "H4 %v rec[%d]: got=%v want=%v", spec, i, out_p[i], out_s[i])
					break
				}
			}
		}
	}

	// C2: Shared non-thread-safe `mem.Arena` as `opts.scratch` under parallel `dsv.records_scan` (TSan-verified).
	{
		src := make_large_dsv(2000, .Csv, false, false)
		defer delete(src)
		scratch_buf := make([]u8, 2 << 20)
		defer delete(scratch_buf)
		arena: mem.Arena
		mem.arena_init(&arena, scratch_buf)
		demand, _ := tape.demand_of({[]tape.Step{tape.Name("name")}, []tape.Step{tape.Name("score")}})
		defer tape.destroy_demand(&demand)

		rp := dsv.records_open(src, .Lines, .Csv, {runner = &pool.runner, scratch = mem.arena_allocator(&arena)})
		defer tape.destroy_records(&rp)
		out := make([]tape.Record, 512)
		docs := make([]tape.Document, 512)
		defer delete(out)
		defer delete(docs)
		total := 0
		for {
			n := dsv.records_scan(&rp, &demand, out, docs)
			total += n
			if n < len(out) {
				break
			}
		}
		testing.expectf(t, total == 2000 && rp.err == nil, "C2 dsv scan: total=%d err=%v", total, rp.err)
	}
}
