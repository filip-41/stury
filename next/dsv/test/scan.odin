package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// A scan that stops at the first cell of its key in a record wider than the header keeps that cell.
@(test)
scans_stop_inside_a_wide_record :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			text: string,
			at:   u64,
		}{{"a,b\n1,2,3\n", 4}, {"a,b\tc\nx,y,z,w\n0", 6}}) {
		demand, _ := tape.demand_of([][]tape.Step{{tape.Index(0), tape.Name("a")}}, allocator = context.temp_allocator)
		doc, err := dsv.scan(transmute([]u8)c.text, &demand, .Csv, {stop_early = true}, {dups = .First})
		defer dsv.destroy(&doc)
		node, p, ok := tape.answer({doc = &doc}, 0, 0)
		kept := ok && p == .Found && int(node) < len(doc.nodes)
		testing.expectf(t, err == nil && kept && doc.nodes[node].lo == c.at, "%q: %v %v %v %v", c.text, err, ok, p, node)
	}
}

// A scan passes the cells of the columns no path takes with no token once it skipped their keys in a record, and counts
// them in each record, across a header past the 63 columns a column has a bit of, and records narrower or wider than
// it.
@(test)
scans_pass_the_columns_no_path_takes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	b := strings.builder_make(context.temp_allocator)
	for c in 0 ..< 70 {
		fmt.sbprintf(&b, "%sc%d", "," if c > 0 else "", c)
	}
	for r in 0 ..< 4 {
		cells := 70 if r < 2 else 40 if r == 2 else 75
		strings.write_byte(&b, '\n')
		for c in 0 ..< cells {
			fmt.sbprintf(&b, "%s%d", "," if c > 0 else "", 100 * r + c)
		}
	}
	text := transmute([]u8)strings.to_string(b)
	testkit.readers_agree(t, dsv.reads(.Csv), dsv.as(.Csv), text, {tolerate = {.Ragged}}, "wide", &a)
	testing.expect(t, a.texts == 1 && a.scans > 0)
	free_all(context.temp_allocator)
}

// The columns a scan takes read as a build reads them, at each place in a wide header where a run of cells starts or ends
// and across the 63rd, from which every column shares one bit, in records that go on past the header.
@(test)
scans_take_the_columns_of_wide_records_as_builds_do :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for width in ([]int{12, 13, 40, 63, 64, 65, 130}) {
		b := strings.builder_make(context.temp_allocator)
		for c in 0 ..< width {
			fmt.sbprintf(&b, "%sc%d", "," if c > 0 else "", c)
		}
		for r in 0 ..< 5 {
			strings.write_byte(&b, '\n')
			for c in 0 ..< width + r % 2 {
				switch (r + c) % 5 {
				case 0:
					fmt.sbprintf(&b, "%s\"q,%d\"\"\"", "," if c > 0 else "", c)
				case 1:
					strings.write_string(&b, "," if c > 0 else "")
				case:
					fmt.sbprintf(&b, "%s%d", "," if c > 0 else "", 100 * r + c)
				}
			}
		}
		src := transmute([]u8)strings.to_string(b)
		opts := dsv.Options {
			tolerate = {.Ragged},
		}
		full, berr := dsv.build(src, .Csv, opts)
		defer dsv.destroy(&full)
		testing.expect_value(t, berr, nil)
		for picks in ([][]int{{0}, {width - 1}, {5, 6}, {width / 2}, {62, 64}, {63}, {1, width - 2}, {3, 11, 12}}) {
			paths := make([dynamic][]tape.Step, context.temp_allocator)
			for c in picks {
				if c < width {
					path := make([]tape.Step, 2, context.temp_allocator)
					path[0], path[1] = tape.All{}, tape.Name(fmt.tprintf("c%d", c))
					append(&paths, path)
				}
			}
			demand, derr := dsv.demand_of(paths[:])
			defer dsv.destroy(&demand)
			testing.expect_value(t, derr, nil)
			doc, err := dsv.scan(src, &demand, .Csv, {}, opts)
			defer dsv.destroy(&doc)
			testing.expect_value(t, err, nil)
			for path, i in paths {
				answers := make([dynamic]testkit.Ref_Answer, context.temp_allocator)
				testkit.reference_answers(&full, path, .Default, &answers)
				for want, k in answers {
					node, p, ok := dsv.answer({&doc, nil}, i, k)
					want_text, got_text := answer_text(&full, want.node, want.outcome), answer_text(&doc, node, p)
					testing.expectf(t, ok && want_text == got_text, "width %d %v answer %d: %q, build %q", width, picks, k, got_text, want_text)
				}
			}
		}
	}
}

Read_Case :: struct {
	src:       string,
	no_header: bool,
	path:      []tape.Step,
	want:      []string, // the text of each answer found, "M" for a missing one and "T" for any other
}

// The text of an answer: the decoded cell for a found one, else "M" for missing and "T" for the other outcomes.
answer_text :: proc(doc: ^dsv.Document, node: dsv.Node_Index, p: dsv.Presence) -> string {
	switch p {
	case .Found:
		text, _ := text_of(doc, node)
		return strings.clone(text, context.temp_allocator)
	case .Missing:
		return "M"
	case .Wrong_Kind, .Not_Loaded:
		return "T"
	}
	return "T"
}

// A path reaches the cells of a table the same through a scan, a scan that stops at its answer and a build read as the
// steps say. A cell is read by name in a record with a header, by place in one without, and an index into a headed
// record is the wrong kind.
@(test)
scans_answer_paths_as_a_build_does :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	headed := "id,name\n1,ann\n2,bob\n"
	bare := "1,2\n3,4\n"
	for c in ([]Read_Case {
			{headed, false, {tape.Index(0), tape.Name("name")}, {"ann"}},
			{headed, false, {tape.Index(1), tape.Name("id")}, {"2"}},
			{headed, false, {tape.Index(1), tape.Index(1)}, {"T"}},
			{headed, false, {tape.All{}, tape.Name("name")}, {"ann", "bob"}},
			{headed, false, {tape.All{}, tape.Index(0)}, {"T", "T"}},
			{headed, false, {tape.Index(2)}, {"M"}},
			{headed, false, {tape.Index(0), tape.Name("age")}, {"M"}},
			{headed, false, {tape.Index(0), tape.Index(5)}, {"T"}},
			{headed, false, {tape.Index(0), tape.Name("name"), tape.Name("x")}, {"T"}},
			{headed, false, {tape.Name("name")}, {"T"}},
			{"a,b\n\"1,2\",3\n", false, {tape.Index(0), tape.Name("a")}, {"1,2"}},
			{"\"a b\",c\n1,2\n", false, {tape.Index(0), tape.Name("a b")}, {"1"}},
			{"a,b\n1,2\n3\n", false, {tape.Index(1), tape.Name("b")}, {"M"}},
			{bare, true, {tape.Index(1), tape.Index(0)}, {"3"}},
			{bare, true, {tape.Index(-1), tape.Index(-1)}, {"4"}},
			{bare, true, {tape.All{}, tape.Index(1)}, {"2", "4"}},
			{bare, true, {tape.Index(0), tape.Index(2)}, {"M"}},
			{bare, true, {tape.Index(0), tape.Name("a")}, {"T"}},
		}) {
		src := transmute([]u8)c.src
		opts := dsv.Options {
			format   = dsv.Dsv_Options{no_header = c.no_header},
			tolerate = {.Ragged},
		}
		demand, derr := dsv.demand_of({c.path})
		defer dsv.destroy(&demand)
		testing.expect_value(t, derr, nil)
		for stop in ([]bool{false, true}) {
			doc, err := dsv.scan(src, &demand, .Csv, {stop_early = stop}, opts)
			defer dsv.destroy(&doc)
			got := make([dynamic]string, context.temp_allocator)
			for k := 0; err == nil; k += 1 {
				node, p, ok := dsv.answer({&doc, nil}, 0, k)
				if !ok {
					break
				}
				append(&got, answer_text(&doc, node, p))
			}
			testing.expectf(t, err == nil && slice.equal(got[:], c.want), "scan %q %v stop %v: %v %v, want %v", c.src, c.path, stop, got[:], err, c.want)
		}
		full, berr := dsv.build(src, .Csv, opts)
		defer dsv.destroy(&full)
		testing.expect_value(t, berr, nil)
		answers := make([dynamic]testkit.Ref_Answer, context.temp_allocator)
		testkit.reference_answers(&full, c.path, .Default, &answers)
		got := make([dynamic]string, context.temp_allocator)
		for a in answers {
			append(&got, answer_text(&full, a.node, a.outcome))
		}
		testing.expectf(t, slice.equal(got[:], c.want), "build %q %v: %v, want %v", c.src, c.path, got[:], c.want)
	}
}

// A scan keeps the cells its path reaches and the records around them: a record before the one reached is not loaded,
// a name no path asked for is not loaded in a record that was, and a name read from a record with no header is the
// wrong kind.
@(test)
scans_keep_what_their_path_reaches :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("1,2\n3,4\n")
	opts := dsv.Options {
		format = dsv.Dsv_Options{no_header = true},
	}
	cell, _ := dsv.demand_of({{tape.Index(1), tape.Index(1)}})
	defer dsv.destroy(&cell)
	doc, err := dsv.scan(src, &cell, .Csv, {}, opts)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	node, p, _ := dsv.answer({&doc, nil}, 0, 0)
	text, _ := text_of(&doc, node)
	testing.expect(t, p == .Found && text == "4")
	r := dsv.Reader{doc = &doc}
	n, _, _ := dsv.length(r, dsv.ROOT, context.allocator)
	testing.expect_value(t, n, 2)
	_, last := dsv.element(r, dsv.ROOT, 1)
	testing.expect_value(t, last, tape.Presence.Found)
	_, before := dsv.element(r, dsv.ROOT, 0)
	testing.expect_value(t, before, tape.Presence.Not_Loaded)

	named, _ := dsv.demand_of({{tape.Index(0), tape.Name("a")}})
	defer dsv.destroy(&named)
	bare, berr := dsv.scan(src, &named, .Csv, {}, opts)
	defer dsv.destroy(&bare)
	testing.expect_value(t, berr, nil)
	_, outcome, _ := dsv.answer({&bare, nil}, 0, 0)
	testing.expect_value(t, outcome, tape.Presence.Wrong_Kind)

	headed, herr := dsv.scan(transmute([]u8)string("a,b\n1,2\n"), &named)
	defer dsv.destroy(&headed)
	testing.expect_value(t, herr, nil)
	hr := dsv.Reader{doc = &headed}
	row, _ := dsv.element(hr, dsv.ROOT, 0)
	a, ap := dsv.member(hr, row, "a")
	a_text, _ := text_of(&headed, a)
	testing.expect(t, ap == .Found && a_text == "1")
	_, bp := dsv.member(hr, row, "b")
	testing.expect_value(t, bp, tape.Presence.Not_Loaded)
}

// Under `.Ragged` a path names a wide record's cell past the header's last by its 1-based position, and a header cell
// of that name repeats it. A path takes the last of a repeated name, and the answers of several paths come in the
// text's order.
@(test)
scans_name_the_cells_past_the_header_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("3,b\n1,2\n4,5,6,7\n")
	ragged := dsv.Options {
		tolerate = {.Ragged},
	}
	paths := [][]tape.Step{{tape.Index(1), tape.Name("4")}, {tape.Index(0), tape.Name("3")}, {tape.Index(1), tape.Name("3")}}
	want := []string{"7", "1", "6"}
	for path, i in paths {
		demand, _ := dsv.demand_of({path})
		defer dsv.destroy(&demand)
		doc, err := dsv.scan(src, &demand, .Csv, {}, ragged)
		defer dsv.destroy(&doc)
		node, _, _ := dsv.answer({&doc, nil}, 0, 0)
		text, _ := text_of(&doc, node)
		testing.expectf(t, err == nil && text == want[i], "path %d: %v %q", i, err, text)
	}
	many, _ := dsv.demand_of({paths[0], paths[1], paths[2]})
	defer dsv.destroy(&many)
	doc, err := dsv.scan(src, &many, .Csv, {}, ragged)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	for i in 0 ..< 3 {
		node, _, _ := dsv.answer({&doc, nil}, i, 0)
		text, _ := text_of(&doc, node)
		testing.expectf(t, text == want[i], "path %d of many: %q", i, text)
	}
	demand, _ := dsv.demand_of({paths[0]})
	defer dsv.destroy(&demand)
	_, strict := dsv.scan(src, &demand)
	fault, faulted := strict.(tape.Fault)
	testing.expect(t, faulted && fault.kind == .Bad_Width)
}

// Every read of a text judges a repeated header name under `.Refuse` and faults at the repeat, as a build does, with
// `.All` an option of a build alone. A ragged text read with `.Ragged` answers every record.
@(test)
reads_of_a_path_take_one_member_of_a_repeated_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,a\n1,2\n")
	path := []tape.Step{tape.All{}, tape.Name("a")}
	refuse := dsv.Options {
		dups = .Refuse,
	}
	repeat := proc(t: ^testing.T, what: string, err: tape.Error) {
		fault, faulted := err.(tape.Fault)
		testing.expectf(t, faulted && fault.kind == .Duplicate_Key && fault.at == 2, "%s: %v", what, err)
	}
	repeat(t, "validate", dsv.validate(src, .Csv, refuse))
	_, ferr := dsv.find(src, path, .Csv, {}, refuse)
	repeat(t, "find", ferr)
	_, sferr := dsv.find(src, path, .Csv, {stop_early = true}, refuse)
	repeat(t, "find stopping early", sferr)
	demand, _ := dsv.demand_of({path})
	defer dsv.destroy(&demand)
	doc, serr := dsv.scan(src, &demand, .Csv, {}, refuse)
	defer dsv.destroy(&doc)
	repeat(t, "scan", serr)
	_, berr := dsv.build(src, .Csv, refuse)
	repeat(t, "build", berr)
	r := dsv.records_open(src, .Lines, .Csv, refuse)
	repeat(t, "records", r.err)
	out: [2]dsv.Record
	testing.expect_value(t, dsv.records_validate(&r, out[:]), 0)
	all := dsv.Options {
		dups = .All,
	}
	_, aerr := dsv.find(src, path, .Csv, {}, all)
	testing.expect_value(t, aerr, tape.Error(tape.Bad_Option{"dups"}))

	ragged := transmute([]u8)string("a,b\n1,2,3\n4\n5,6\n")
	cells, _ := dsv.demand_of({{tape.All{}, tape.Name("a")}})
	defer dsv.destroy(&cells)
	read, rerr := dsv.scan(ragged, &cells, .Csv, {}, {tolerate = {.Ragged}})
	defer dsv.destroy(&read)
	testing.expect_value(t, rerr, nil)
	got := make([dynamic]string, context.temp_allocator)
	for k := 0; ; k += 1 {
		node, p, ok := dsv.answer({&read, nil}, 0, k)
		if !ok {
			break
		}
		append(&got, answer_text(&read, node, p))
	}
	testing.expect(t, slice.equal(got[:], []string{"1", "4", "5"}))
	free_all(context.temp_allocator)
}

// A scan with a path through one column and another through a different column of another record keeps the cells of
// both.
@(test)
scans_take_every_column_the_paths_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("x,yy,q\nc0_0,c0_1,c0_2\nc1_0,c1_1,c1_2\nc2_0,c2_1,c2_2\n")
	demand, _ := dsv.demand_of({{tape.All{}, tape.Name("yy")}, {tape.Index(1), tape.Name("x")}})
	defer dsv.destroy(&demand)
	for stop in ([]bool{false, true}) {
		doc, err := dsv.scan(src, &demand, .Csv, {stop_early = stop})
		defer dsv.destroy(&doc)
		testing.expect_value(t, err, nil)
		node, p, _ := dsv.answer({&doc, nil}, 1, 0)
		text := ""
		if p == .Found {
			text, _ = text_of(&doc, node)
		}
		testing.expectf(t, p == .Found && text == "c1_0", "stop %v: .[1].x is %v %q", stop, p, text)
	}
}

// A scan of random tables answers each path with the cells the table holds, whole and stopped at its answers: a
// record in a headed table by name, in a headless one by place, and a record that does not exist as no found answer.
@(test)
scans_answer_the_tables_they_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x9a7)
	NAMES := [?]string{"x", "yy", `"q r"`, `"e""f"`}
	DECODED := [?]string{"x", "yy", "q r", `e"f`}
	for _ in 0 ..< testkit.rounds(400) {
		defer free_all(context.temp_allocator)
		headed := rand.int_max(2) == 0
		width := rand.int_max(4) + 1
		rows := rand.int_max(4) + 1
		b := strings.builder_make(context.temp_allocator)
		if headed {
			for c in 0 ..< width {
				fmt.sbprint(&b, "," if c > 0 else "", NAMES[c], sep = "")
			}
			strings.write_byte(&b, '\n')
		}
		cells := make([][]string, rows, context.temp_allocator)
		for &row, i in cells {
			row = make([]string, width, context.temp_allocator)
			for &cell, c in row {
				cell = fmt.tprintf("c%d_%d", i, c)
				fmt.sbprint(&b, "," if c > 0 else "", cell, sep = "")
			}
			strings.write_byte(&b, '\n')
		}
		src := transmute([]u8)strings.to_string(b)
		paths := make([][]tape.Step, rand.int_max(3) + 1, context.temp_allocator)
		wants := make([][dynamic]string, len(paths), context.temp_allocator)
		for &path, p in paths {
			steps := make([]tape.Step, 2, context.temp_allocator)
			lead := tape.Step(tape.All{})
			chosen := make([dynamic]int, context.temp_allocator)
			if rand.int_max(3) > 0 {
				at := rand.int_max(rows + 2) - 1
				if rand.int_max(2) == 0 {
					at = -1 - rand.int_max(rows + 1)
				}
				lead = tape.Index(at)
				place := at if at >= 0 else rows + at
				if place >= 0 && place < rows {
					append(&chosen, place)
				}
			} else {
				for i in 0 ..< rows {
					append(&chosen, i)
				}
			}
			// The cell each chosen record answers: its text, or "M" when the record has no such cell.
			step: tape.Step
			column := rand.int_max(width + 1)
			index := rand.int_max(2 * width + 2) - width - 1
			if headed {
				step = tape.Name(DECODED[column] if column < width else "zz")
			} else {
				step = tape.Index(index)
			}
			steps[0], steps[1] = lead, step
			path = steps
			wants[p] = make([dynamic]string, context.temp_allocator)
			for i in chosen {
				place := column if headed else (index if index >= 0 else width + index)
				if place >= 0 && place < width {
					append(&wants[p], cells[i][place])
				} else {
					append(&wants[p], "M")
				}
			}
			if len(chosen) == 0 {
				append(&wants[p], "-")
			}
		}
		demand, derr := dsv.demand_of(paths)
		defer dsv.destroy(&demand)
		testing.expectf(t, derr == nil, "%q %v: %v", src, paths, derr)
		opts := dsv.Options {
			format = dsv.Dsv_Options{no_header = !headed},
		}
		for stop in ([]bool{false, true}) {
			doc, err := dsv.scan(src, &demand, .Csv, {stop_early = stop}, opts)
			defer dsv.destroy(&doc)
			testing.expectf(t, err == nil, "%q: %v", src, err)
			for want, p in wants {
				got := make([dynamic]string, context.temp_allocator)
				for k := 0; ; k += 1 {
					node, outcome, ok := dsv.answer({&doc, nil}, p, k)
					if !ok {
						break
					}
					append(&got, answer_text(&doc, node, outcome))
				}
				if want[0] == "-" {
					testing.expectf(t, len(got) == 1 && (got[0] == "M" || got[0] == "T"), "%q %v stop %v: %v for a record that is not there", src, paths[p], stop, got[:])
				} else {
					testing.expectf(t, slice.equal(got[:], want[:]), "%q %v of %v stop %v: %v, want %v", src, p, paths, stop, got[:], want[:])
				}
			}
		}
	}
}

// A text of 3000 records in each spec answers two paths through different records by a scan as a find does.
@(test)
scans_of_two_paths_read_each_spec_as_finds_do :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	paths := [][]tape.Step{{tape.Index(0), tape.Name("a")}, {tape.Index(1), tape.Name("b")}}
	demand, _ := dsv.demand_of(paths)
	defer dsv.destroy(&demand)
	for spec in dsv.Spec {
		sep := "\t" if spec == .Tsv else ","
		row := strings.concatenate({"1", sep, "2\n"}, context.temp_allocator)
		src := strings.concatenate({"a", sep, "b\n", strings.repeat(row, 3000, context.temp_allocator)}, context.temp_allocator)
		doc, err := dsv.scan(transmute([]u8)src, &demand, spec)
		defer dsv.destroy(&doc)
		testing.expect_value(t, err, nil)
		for path, i in paths {
			node, p, _ := dsv.answer({&doc, nil}, i, 0)
			text, _ := text_of(&doc, node)
			found, ferr := dsv.find(transmute([]u8)src, path, spec)
			testing.expectf(t, p == .Found && ferr == nil && found.outcome == .Found && text == src[found.lo:found.hi], "%v path %d: %q %v", spec, i, text, p)
		}
	}
}

// A repeated header name refuses a read as it refuses a build, at the later cell, whichever bytes make the names equal: a
// TSV cell written `\0` and a raw NUL, an empty cell, and quotes that are bytes of a TSV cell.
@(test)
reads_refuse_the_repeats_a_build_refuses :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	demand, _ := dsv.demand_of({{tape.All{}, tape.Name("a")}})
	defer dsv.destroy(&demand)
	refuse := dsv.Options {
		dups = .Refuse,
	}
	for c in ([]struct {
			src:  string,
			spec: dsv.Spec,
		}{{"a,a\n1,2\n", .Csv}, {"\"q\"\t\"q\"\n1\t2\n", .Tsv}, {",\n1,2\n", .Csv}, {"\\0\t\x00\n1\t2\n", .Tsv}, {"\\0\t\\0\n", .Tsv}, {"a,a\n1,2\n3,\"x\n", .Csv}}) {
		src := transmute([]u8)c.src
		built, want := dsv.build(src, c.spec, refuse)
		dsv.destroy(&built)
		fault, faulted := want.(tape.Fault)
		testing.expectf(t, faulted && fault.kind == .Duplicate_Key, "%q: build %v", c.src, want)
		testing.expectf(t, dsv.validate(src, c.spec, refuse) == want, "%q: validate", c.src)
		_, ferr := dsv.find(src, []tape.Step{tape.Index(0)}, c.spec, {}, refuse)
		testing.expectf(t, ferr == want, "%q: find %v", c.src, ferr)
		doc, serr := dsv.scan(src, &demand, c.spec, {}, refuse)
		dsv.destroy(&doc)
		testing.expectf(t, serr == want, "%q: scan %v", c.src, serr)
		r := dsv.records_open(src, .Lines, c.spec, refuse)
		testing.expectf(t, r.err == want, "%q: records %v", c.src, r.err)
	}
}

// A scan of records that all have the header's width reads as with `.Ragged`: without it each record after the first
// replays the first, and with it each is read through its tokens. Over the texts the tests read and generated ones
// with faults, under every option, both `stop_early` and the budgets of nodes and steps. A memory budget is left out,
// as a replay holds less.
@(test)
scans_replay_records_as_they_read_them :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	compared := 0
	for c in BUILT {
		compared += replays_agree(t, c.spec, transmute([]u8)c.text, {format = c.opts, tolerate = c.tol})
	}
	for c in CSV_CASES {
		compared += replays_agree(t, .Csv, transmute([]u8)c.text, {})
	}
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5ca9)
	for _ in 0 ..< testkit.rounds(200) {
		text, spec, opts := random_text(even = true)
		compared += replays_agree(t, spec, text, opts)
	}
	testing.expectf(t, compared >= 8000, "%d scans compared", compared)
}

// Compares the scans of `src` with and without `.Ragged` for demands whose steps from the root are `All`, and returns
// how many gave a document.
replays_agree :: proc(t: ^testing.T, spec: dsv.Spec, src: []u8, opts: dsv.Options) -> (compared: int) {
	paths := [][][]tape.Step {
		{{tape.All{}, tape.Name("k0")}},
		{{tape.All{}, tape.Name("k1")}, {tape.All{}, tape.Name("k2")}},
		{{tape.All{}, tape.Name("b")}, {tape.All{}, tape.Name("a")}, {tape.All{}, tape.Name("zz")}},
		{{tape.All{}, tape.All{}}},
		{{tape.All{}, tape.Name("k0"), tape.Name("x")}},
		{{tape.All{}, tape.Name("k1")}, {tape.All{}, tape.Index(0)}},
	}
	budgets := []tape.Budget{{}, {nodes = 6}, {nodes = 30}, {steps = 4}}
	for set in paths {
		demand, _ := dsv.demand_of(set, allocator = context.temp_allocator)
		for dups in ([]tape.Duplicates{.Last, .First, .Group}) {
			for budget in budgets {
				for stop in ([]bool{false, true}) {
					even := opts
					even.dups, even.budget, even.tolerate = dups, budget, opts.tolerate - {.Ragged}
					doc, err := dsv.scan(src, &demand, spec, {stop_early = stop}, even)
					defer dsv.destroy(&doc)
					if fault, ok := err.(tape.Fault); ok && fault.kind == .Bad_Width {
						continue
					}
					ragged := even
					ragged.tolerate += {.Ragged}
					read, rerr := dsv.scan(src, &demand, spec, {stop_early = stop}, ragged)
					defer dsv.destroy(&read)
					same := testkit.same_refusal(err, rerr) && (err != nil || testkit.same_documents(doc, read))
					if !testing.expectf(t, same, "%q %v %v %v %v stop %v: %v %v", src, spec, set, dups, budget, stop, err, rerr) {
						return
					}
					compared += int(err == nil)
				}
			}
		}
	}
	return
}
