package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:host"
import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:testkit"

// Builds of delimited texts on a runner's threads against the build on one thread.

// The thread counts every text is built on, and for a short text the counts that cut it at each of its LFs.
@(private = "file")
threads_of :: proc(n: int) -> []int {
	threads := make([dynamic]int, context.temp_allocator)
	append(&threads, 1, 2, 3, 17, 70)
	for k := 4; 4 * k <= n && k < 600; k += 1 + k / 8 {
		append(&threads, k)
	}
	return threads[:]
}

// A cell whose bytes a chunk that starts inside it reads wrong from any other place: quoted cells holding delimiters,
// LFs, CR LFs and `""`, escapes, characters of two to four bytes, numbers and empty cells.
@(private = "file")
seam_cell :: proc(b: ^strings.Builder, spec: dsv.Spec, header: bool, col: int) {
	if header {
		fmt.sbprintf(b, "k%d", col)
		return
	}
	switch spec {
	case .Csv:
		cells := [?]string{"\"a,\nb\"", "\"\"\"\"", "\"x\r\n\"\"\n\"", "\"\n\"", "\"\"", "\"#c,\"\"\n# d\"", "plain", "-12.5e3", "", "true", "\xc3\xa9\xe2\x82\xac", "\xf0\x9f\x98\x80x"}
		strings.write_string(b, cells[rand.int_max(len(cells))])
	case .Tsv:
		cells := [?]string{"a\\tb", "\\n\\r\\0\\\\", "\"q\"", "plain", "7", "", "\xc3\xa9\xe2\x82\xac"}
		strings.write_string(b, cells[rand.int_max(len(cells))])
	case .Plain:
		cells := [?]string{"\"q", "plain", "0", "", "false", "\xf0\x9f\x98\x80"}
		strings.write_string(b, cells[rand.int_max(len(cells))])
	}
}

// A text of `rows` records of `width` cells under a header, with comment lines holding quotes and delimiters, empty
// lines, CR LF line ends, ragged records when `ragged`, and a wide header of `width` cells.
@(private = "file")
seam_text :: proc(spec: dsv.Spec, rows, width: int, comments, ragged: bool) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	delim := u8('\t') if spec == .Tsv else ','
	if comments {
		strings.write_string(&b, "# a \"head, comment\n")
	}
	for row in 0 ..< rows + 1 {
		switch {
		case comments && rand.int_max(5) == 0:
			strings.write_string(&b, "# \"open, quote\n" if rand.int_max(2) == 0 else "#\r\n")
		case rand.int_max(9) == 0:
			strings.write_string(&b, "\n" if rand.int_max(2) == 0 else "\r\n")
		}
		cells := width if !ragged || row == 0 else 1 + rand.int_max(width + 2)
		for col in 0 ..< cells {
			if col > 0 {
				strings.write_byte(&b, delim)
			}
			seam_cell(&b, spec, row == 0, col)
		}
		strings.write_string(&b, "\r\n" if rand.int_max(3) == 0 else "\n")
	}
	if comments && rand.int_max(2) == 0 {
		strings.write_string(&b, "# the \"foot\n# and more")
	}
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
DSV_MUTATE_ALPHABET :: "\",\t\n\r\\#x\xff\xc3"

// The option sets the texts are built under: each tolerance, each `Dsv_Options` field, the budgets and the policies.
@(private = "file")
parallel_options :: proc(spec: dsv.Spec) -> []dsv.Options {
	all := dsv.Tolerances{.Ragged, .Bare_Quote, .Invalid_Utf8}
	return slice.clone(
		[]dsv.Options {
			{},
			{format = dsv.Dsv_Options{comment = '#'}},
			{format = dsv.Dsv_Options{no_header = true}},
			{format = dsv.Dsv_Options{infer = true}},
			{format = dsv.Dsv_Options{delimiter = ';' if spec == .Csv else ','}},
			{tolerate = {.Ragged}},
			{tolerate = {.Bare_Quote}},
			{tolerate = {.Invalid_Utf8}},
			{format = dsv.Dsv_Options{comment = '#', no_header = true, infer = true}, tolerate = all},
			{format = dsv.Dsv_Options{comment = '#'}, tolerate = all},
			{budget = {steps = 9}},
			{budget = {nodes = 60}, tolerate = {.Ragged}},
			{budget = {depth = 1}},
			{budget = {memory = 4096}},
			{dups = .Refuse},
			{dups = .First, tolerate = {.Ragged}},
		},
		context.temp_allocator,
	)
}

// The thread law over `src`, with the tables compared too (via `testkit.same_documents`). Under a memory budget the
// law is the one-thread document or a refusal of the budget.
@(private = "file")
agree :: proc(t: ^testing.T, spec: dsv.Spec, src: []u8, opts: dsv.Options, runner: ^tape.Runner, name: string) -> (ok, built: bool) {
	if opts.budget.memory != 0 {
		return testkit.threads_fit(t, dsv.reads(spec), dsv.as(spec), src, opts, runner, name), false
	}
	return testkit.threads_agree(t, dsv.reads(spec), dsv.as(spec), src, opts, runner, name)
}

// Over texts whose chunks start inside quoted cells with LFs and `""`, past CR LFs, before characters of several bytes,
// in comment lines, in ragged records and in a header wider than a chunk, valid and spoiled, built under every option
// set on every thread count: the build in parts is the build on one thread, node for node, table for table, and
// refuses a text with the same error.
@(test)
parts_build_what_one_thread_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xd5f1)
	builds, valid := 0, 0
	for round in 0 ..< testkit.rounds(12) {
		spec := dsv.Spec(round % 3)
		for opts in parallel_options(spec) {
			o, _ := opts.format.(dsv.Dsv_Options)
			width := 1 + rand.int_max(5) if round % 4 != 3 else 150 + rand.int_max(60)
			// Ragged records that no tolerance takes fault at the first record of another width.
			src := seam_text(spec, 4 + rand.int_max(30), width, o.comment != 0, .Ragged in opts.tolerate || rand.int_max(4) == 0)
			texts := [?][]u8{src, testkit.mutate(src, DSV_MUTATE_ALPHABET)}
			for text, i in texts {
				for threads in threads_of(len(text)) {
					r := testkit.serial_runner(threads)
					builds += 1
					ok, built := agree(t, spec, text, opts, &r, fmt.tprintf("round %d text %d", round, i))
					valid += int(built)
					if !ok {
						log.infof("%q", string(text))
						return
					}
				}
			}
		}
		free_all(context.temp_allocator)
	}
	testing.expectf(t, builds > 1000 && valid > builds / 4, "%d builds, %d of a valid text", builds, valid)
}

// A long valid text is joined from its parts with no build on one thread: the runner sees the chunks read and the
// parts walked, and the facts placed of a text with comments.
@(test)
parts_join_with_no_build_on_one_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x10b5)
	for spec in dsv.Spec {
		for comments in ([]bool{false, true}) {
			// A text shorter than `PARALLEL_FROM` is built on one thread, so this text is made long enough to join.
			rows := 400
			src := seam_text(spec, rows, 4, comments, false)
			for len(src) < build.PARALLEL_FROM {
				rows *= 2
				src = seam_text(spec, rows, 4, comments, false)
			}
			opts := dsv.Options{format = dsv.Dsv_Options{comment = '#' if comments else 0}}
			for threads in ([]int{3, 17, 70}) {
				starts := 0
				r := testkit.counting_runner(threads, &starts)
				if ok, built := agree(t, spec, src, opts, &r, "joined"); !ok || !testing.expect(t, built) {
					return
				}
				testing.expectf(t, starts == (3 if comments else 2), "%v comments %v on %d threads: %d tasks", spec, comments, threads, starts)
			}
		}
	}
	free_all(context.temp_allocator)
}

// A text of many records, each holding a quoted cell of several lines, whose chunks mostly start inside a quoted cell,
// builds as on one thread on every thread count.
@(test)
parts_of_multiline_cells_build_as_one_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "id,text,n\n")
	for i in 0 ..< 5000 {
		fmt.sbprintf(&b, "%d,\"line one\nline, two\r\n\"\"three\"\"\n\",%d\n", i, i % 7)
	}
	src := transmute([]u8)strings.to_string(b)
	for threads in ([]int{1, 2, 3, 7, 17, 70, 255, 1000}) {
		r := testkit.serial_runner(threads)
		if ok, built := agree(t, .Csv, src, {}, &r, "multiline"); !ok || !testing.expect(t, built) {
			return
		}
	}
	free_all(context.temp_allocator)
}

// Long texts on pools of 1, 2, 3, 4 and 8 threads: the same documents, built by threads at once.
@(test)
parts_build_on_pools :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x9002)
	Text :: struct {
		src:  []u8,
		spec: dsv.Spec,
		opts: dsv.Options,
	}
	texts := make([dynamic]Text, context.temp_allocator)
	for spec in dsv.Spec {
		append(&texts, Text{seam_text(spec, 2000, 6, false, false), spec, {}})
		append(&texts, Text{seam_text(spec, 2000, 5, true, true), spec, {format = dsv.Dsv_Options{comment = '#', infer = true}, tolerate = {.Ragged, .Invalid_Utf8, .Bare_Quote}}})
	}
	for workers in ([]int{1, 2, 3, 4, 8}) {
		pool: host.Pool
		host.pool_init(&pool, workers)
		defer host.pool_destroy(&pool)
		for text, i in texts {
			for _ in 0 ..< 3 {
				if ok, _ := agree(t, text.spec, text.src, text.opts, &pool.runner, fmt.tprintf("text %d", i)); !ok {
					return
				}
			}
		}
	}
	free_all(context.temp_allocator)
}

// The allocator of a build on a pool is called on the calling thread alone, and a memory budget gives the document of the
// build on one thread or a refusal.
@(test)
parts_allocate_on_the_calling_thread :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xa11d)
	pool: host.Pool
	host.pool_init(&pool, 4)
	defer host.pool_destroy(&pool)
	c: testkit.Caller_Only
	only := testkit.caller_only(&c, context.allocator)
	for spec in dsv.Spec {
		src := seam_text(spec, 300, 3, true, false)
		opts := dsv.Options{format = dsv.Dsv_Options{comment = '#'}, runner = &pool.runner}
		doc, err := dsv.build(src, spec, opts, only)
		testing.expectf(t, err == nil && len(doc.nodes) > 300, "%v %v %d", spec, err, len(doc.nodes))
		dsv.destroy(&doc)
		for memory in ([]u64{1, 4096, u64(len(src)), u64(len(src)) * 4, u64(len(src)) * 64}) {
			if ok, _ := agree(t, spec, src, {budget = {memory = memory}}, &pool.runner, "memory"); !ok {
				return
			}
		}
	}
	testing.expect_value(t, c.strays, 0)
	free_all(context.temp_allocator)
}

// A build in parts frees every block it took, whether it joins its parts, falls back to one thread or faults.
@(test)
parts_free_what_they_take :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xf4ee)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	for spec in dsv.Spec {
		src := seam_text(spec, 200, 3, true, false)
		bad := testkit.mutate(src, DSV_MUTATE_ALPHABET)
		r := testkit.serial_runner(9)
		for text in ([][]u8{src, bad}) {
			for opts in parallel_options(spec) {
				wide := opts
				wide.runner = &r
				doc, _ := dsv.build(text, spec, wide, mem.tracking_allocator(&track))
				dsv.destroy(&doc)
			}
		}
	}
	testing.expectf(t, len(track.allocation_map) == 0, "%d blocks left", len(track.allocation_map))
	free_all(context.temp_allocator)
}

// A memory budget the build on one thread fits gives, at every thread count, the document of that build or the refusal of
// the budget, never another document.
@(test)
memory_budget_gives_the_one_thread_document_or_a_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xb0da)
	defer free_all(context.temp_allocator)
	one, many := testkit.serial_runner(3), testkit.serial_runner(17)
	runners := [2]^tape.Runner{&one, &many}
	for spec in dsv.Spec {
		for opts in ([]dsv.Options{{}, {format = dsv.Dsv_Options{comment = '#'}}, {tolerate = {.Ragged}}, {format = dsv.Dsv_Options{no_header = true}}}) {
			d, _ := opts.format.(dsv.Dsv_Options)
			src := seam_text(spec, 300, 3, d.comment != 0, .Ragged in opts.tolerate)
			if !testkit.threads_fit_budget_sweep(t, dsv.reads(spec), dsv.as(spec), src, opts, runners[:], false, "budget") {
				return
			}
		}
	}
}

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
