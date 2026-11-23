package dsv_tests

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// The records of a text are its rows past the header, each read alone with the header's keys. A row that faults ends
// at its line end, and the records go on at the next.
@(test)
records_read_each_row :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("a,b\n1,2\n3\n\"x\ny\",4\r\n\n5,6")
	r := dsv.records_open(src)
	out: [8]dsv.Record
	n := dsv.records_validate(&r, out[:])
	testing.expect_value(t, n, 4)
	testing.expect_value(t, r.err, nil)
	spans := []string{"1,2", "3", "\"x\ny\",4", "5,6"}
	for i in 0 ..< min(n, 4) {
		testing.expectf(t, string(src[out[i].lo:out[i].hi]) == spans[i], "record %d: %q", i, src[out[i].lo:out[i].hi])
		testing.expectf(t, (out[i].err == nil) == (i != 1), "record %d: %v", i, out[i].err)
	}
	r = dsv.records_open(src)
	answers: [8]dsv.Span_Answer
	n = dsv.records_find(&r, []tape.Step{tape.Name("b")}, out[:], answers[:])
	testing.expect_value(t, n, 4)
	testing.expect(t, answers[0].outcome == .Found && string(src[answers[0].lo:answers[0].hi]) == "2")
	testing.expect(t, answers[2].outcome == .Found && string(src[answers[2].lo:answers[2].hi]) == "4")
	r = dsv.records_open(src)
	demand, _ := tape.demand_of([][]tape.Step{{}}, allocator = context.temp_allocator)
	docs: [8]dsv.Document
	n = dsv.records_scan(&r, &demand, out[:], docs[:])
	testing.expect_value(t, n, 4)
	testing.expectf(t, render(&docs[3]) == `{"a":"5","b":"6"}`, "%s", render(&docs[3]))
	for &d in docs[:n] {
		dsv.destroy(&d)
	}
}

// A step budget no record reaches changes no record's verdict, whichever way the text is generated.
@(test)
records_validate_agrees_with_a_counting_walk :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for _ in 0 ..< 300 {
		src, spec, opts := random_text()
		counted := opts
		counted.budget.steps = 1 << 40
		plain := dsv.records_open(src, .Lines, spec, opts)
		steps := dsv.records_open(src, .Lines, spec, counted)
		a, b: [16]dsv.Record
		n := dsv.records_validate(&plain, a[:])
		m := dsv.records_validate(&steps, b[:])
		if !testing.expectf(t, n == m && plain.err == steps.err, "%q: %d records %v, counted %d %v", src, n, plain.err, m, steps.err) {
			continue
		}
		for i in 0 ..< n {
			testing.expectf(t, a[i] == b[i], "%q: record %d is %v, counted %v", src, i, a[i], b[i])
		}
	}
}


// A user of the records reads a record's cell by its column's name with `records_find`, and every cell by place with a
// `records_scan` of the path `.[]`, whose k-th answer is the k-th cell. Neither takes a document per record from the
// caller or a loop over the record's members, and a quoted cell reads decoded.

@(private = "file")
ROWS :: "name,qty,note\nbolt,12,\"a,\"\"b\"\"\"\n\"nut\",3,\nwasher,7,x\n"

@(test)
a_records_user_reads_a_cell_by_column_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(ROWS)
	r := dsv.records_open(src)
	out: [8]dsv.Record
	answers: [8]dsv.Span_Answer
	n := dsv.records_find(&r, []dsv.Step{dsv.Name("note")}, out[:], answers[:])
	testing.expect_value(t, n, 3)
	want := [3]string{`a,"b"`, "", "x"}
	buf: [16]u8
	for i in 0 ..< n {
		text, _ := dsv.node_text(dsv.as(.Csv), src, dsv.answer_node(answers[i]), buf[:])
		testing.expectf(t, answers[i].outcome == .Found && text == want[i], "record %d: %v %q", i, answers[i].outcome, text)
	}
	r = dsv.records_open(src)
	n = dsv.records_find(&r, []dsv.Step{dsv.Name("price")}, out[:], answers[:])
	testing.expect_value(t, n, 3)
	testing.expect(t, answers[0].outcome == .Missing)
}

@(test)
a_records_user_reads_a_cell_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(ROWS)
	demand, derr := dsv.demand_of({{dsv.All{}}})
	defer dsv.destroy(&demand)
	testing.expect_value(t, derr, nil)
	r := dsv.records_open(src)
	out: [8]dsv.Record
	docs: [8]dsv.Document
	n := dsv.records_scan(&r, &demand, out[:], docs[:])
	defer for &d in docs[:n] {
		dsv.destroy(&d)
	}
	testing.expect_value(t, n, 3)
	want := [3][3]string{{"bolt", "12", `a,"b"`}, {"nut", "3", ""}, {"washer", "7", "x"}}
	buf: [16]u8
	for i in 0 ..< n {
		for j in 0 ..< 3 {
			at, p, ok := dsv.answer({&docs[i], nil}, 0, j)
			text, _ := dsv.node_text(&docs[i], at, buf[:])
			testing.expectf(t, ok && p == .Found && text == want[i][j], "record %d cell %d: %v %q", i, j, p, text)
		}
		_, _, past := dsv.answer({&docs[i], nil}, 0, 3)
		testing.expect(t, !past)
	}
}

// Under `no_header` a record is an array, and a path of its place names the cell.
@(test)
a_records_user_reads_a_cell_of_a_row_without_a_header_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\nc,d\n")
	r := dsv.records_open(src, .Lines, .Csv, {format = dsv.Dsv_Options{no_header = true}})
	out: [4]dsv.Record
	answers: [4]dsv.Span_Answer
	n := dsv.records_find(&r, []dsv.Step{dsv.Index(1)}, out[:], answers[:])
	testing.expect_value(t, n, 2)
	buf: [4]u8
	want := [2]string{"b", "d"}
	for i in 0 ..< n {
		text, _ := dsv.node_text(dsv.as(.Csv), src, dsv.answer_node(answers[i]), buf[:])
		testing.expectf(t, text == want[i], "record %d: %q", i, text)
	}
}

@(private = "file")
Model_Row :: struct {
	at, hi: u64,
}

// Frames `src` byte by byte, honouring quotes, until the whole text's fault. Gives the rows past the header.
@(private = "file")
model_rows :: proc(src: string, spec: dsv.Spec, opts: dsv.Options) -> (rows: [dynamic]Model_Row, fault: tape.Error) {
	rows = make([dynamic]Model_Row, context.temp_allocator)
	fault = dsv.validate(transmute([]u8)src, spec, opts)
	delim: u8 = '\t' if spec == .Tsv else ','
	d, _ := opts.format.(dsv.Dsv_Options)
	header := !d.no_header
	i := 3 if strings.has_prefix(src, "\xef\xbb\xbf") else 0
	for i < len(src) {
		if src[i] == '\n' || strings.has_prefix(src[i:], "\r\n") || d.comment != 0 && src[i] == d.comment {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			i += 1
			continue
		}
		j := i
		first, quoted := true, false
		for j < len(src) {
			c := src[j]
			if quoted {
				if c == '"' && j + 1 < len(src) && src[j + 1] == '"' {
					j += 2
					continue
				}
				quoted = c != '"'
			} else if c == '\n' {
				break
			} else if spec == .Csv && c == '"' && first {
				quoted = true
			}
			first = c == delim
			j += 1
		}
		hi := j
		if hi > i && src[hi - 1] == '\r' {
			hi -= 1
		}
		if f, bad := fault.(tape.Fault); bad && u64(hi) >= f.at {
			return
		}
		if header {
			header = false
		} else {
			append(&rows, Model_Row{u64(i), u64(hi)})
		}
		i = j + 1
	}
	return
}

@(private = "file", rodata)
CELLS := []string{"a", "12", "", "\"q,x\"", "\"l\nm\"", "\"d\"\"q\"", "é", "b\\tc", "\"\"", " s ", "-3.5", "true"}

// A seeded table of `rows` rows of three cells with blank lines, comment lines, ragged rows, CR LF line ends and a byte
// order mark among them, in the quoting the spec reads.
@(private = "file")
seeded_rows :: proc(spec: dsv.Spec, rows: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	if rand.int_max(4) == 0 {
		strings.write_string(&b, "\xef\xbb\xbf")
	}
	delim: u8 = '\t' if spec == .Tsv else ','
	for r in 0 ..< rows {
		switch rand.int_max(16) {
		case 0:
			strings.write_string(&b, "\n")
		case 1:
			strings.write_string(&b, "#c\n")
		}
		n := 3 + (rand.int_max(3) - 1 if rand.int_max(12) == 0 else 0)
		for c in 0 ..< max(n, 1) {
			if c > 0 {
				strings.write_byte(&b, delim)
			}
			cell := rand.choice(CELLS)
			if spec != .Csv && strings.contains_any(cell, "\"\n") {
				cell = "w"
			}
			strings.write_string(&b, cell)
		}
		if r < rows - 1 || rand.int_max(2) == 0 {
			strings.write_string(&b, "\r\n" if rand.int_max(4) == 0 else "\n")
		}
	}
	return strings.to_string(b)
}

@(private = "file")
LAYOUTS := []dsv.Options {
	{},
	{format = dsv.Dsv_Options{no_header = true}},
	{format = dsv.Dsv_Options{comment = '#'}},
	{format = dsv.Dsv_Options{no_header = true, comment = '#'}},
	{tolerate = {.Invalid_Utf8, .Ragged, .Bare_Quote}},
}

// The records of a text frame as a plain framer that honours quotes does, up to the byte the whole text's verdict
// refuses. Every byte of seeded texts in turn becomes one that breaks or ends a row.
@(test)
records_frame_the_rows_a_model_frames :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x5c)
	defer free_all(context.temp_allocator)
	breakers := "\",\t\n\r\\x#\xff\xc3"
	for round in 0 ..< testkit.rounds(30) {
		spec := dsv.Spec(round % 3)
		src := seeded_rows(spec, 1 + rand.int_max(6))
		buf := make([]u8, len(src), context.temp_allocator)
		for i in -1 ..< len(src) {
			for c in transmute([]u8)breakers {
				copy(buf, src)
				if i >= 0 {
					buf[i] = c
				}
				for opts in LAYOUTS {
					if !records_match_model(t, string(buf), spec, opts) {
						return
					}
				}
				if i < 0 {
					break
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(private = "file")
records_match_model :: proc(t: ^testing.T, src: string, spec: dsv.Spec, opts: dsv.Options) -> bool {
	want, fault := model_rows(src, spec, opts)
	r := dsv.records_open(transmute([]u8)src, .Lines, spec, opts)
	out := make([dynamic]dsv.Record, context.temp_allocator)
	batch: [3]dsv.Record
	for {
		m := dsv.records_validate(&r, batch[:])
		append(&out, ..batch[:m])
		if m < len(batch) {
			break
		}
	}
	n := len(out)
	for i in 0 ..< min(n, len(want)) {
		if !testing.expectf(t, out[i].lo == want[i].at && out[i].hi == want[i].hi && out[i].err == nil, "%v %v %q: row %d is %v, want %v", spec, opts, src, i, out[i], want[i]) {
			return false
		}
	}
	if fault == nil {
		return testing.expectf(t, n == len(want) && r.err == nil, "%v %v %q: %d rows %v, want %d", spec, opts, src, n, r.err, len(want))
	}
	return testing.expectf(t, n >= len(want), "%v %v %q: %d rows, want the %d before the fault %v", spec, opts, src, n, len(want), fault)
}

// Under `infer` an unquoted number, `true` or `false` of a record's cell is that kind, a quoted one is a string, and an
// empty one is null.
@(test)
record_cells_take_the_inferred_kinds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b,c,d,e\n1,\"2\",true,\"false\",\n")
	r := dsv.records_open(src, .Lines, .Csv, {format = dsv.Dsv_Options{infer = true}})
	out: [2]dsv.Record
	docs: [2]dsv.Document
	demand, _ := dsv.demand_of({{tape.All{}}})
	defer dsv.destroy(&demand)
	n := dsv.records_scan(&r, &demand, out[:], docs[:])
	defer for &d in docs[:n] {
		dsv.destroy(&d)
	}
	testing.expect_value(t, n, 1)
	kinds := [5]tape.Kind{.Number, .String, .True, .String, .Null}
	texts := [5]string{"1", "2", "true", "false", ""}
	for want, i in kinds {
		node, p, _ := dsv.answer({&docs[0], nil}, 0, i)
		text, _ := text_of(&docs[0], node)
		testing.expectf(t, p == .Found && docs[0].nodes[node].kind == want && text == texts[i], "cell %d: %v %v %q", i, p, docs[0].nodes[node].kind, text)
	}
}

// Under `.Ragged` a record wider than the header names its cells past the header's last by position, and a header cell
// of that name takes the same path, which reads the record's last cell of it.
@(test)
records_name_the_cells_past_the_header_by_place :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("3,b\n1,2\n4,5,6,7\n")
	opts := dsv.Options {
		tolerate = {.Ragged},
	}
	out: [4]dsv.Record
	answers: [4]dsv.Span_Answer
	for c in ([]struct {
			name: string,
			want: [2]string,
		}{{"4", {"", "7"}}, {"3", {"1", "6"}}, {"b", {"2", "5"}}}) {
		r := dsv.records_open(src, .Lines, .Csv, opts)
		n := dsv.records_find(&r, []tape.Step{tape.Name(c.name)}, out[:], answers[:])
		testing.expect_value(t, n, 2)
		for i in 0 ..< min(n, 2) {
			text := string(src[answers[i].lo:answers[i].hi]) if answers[i].outcome == .Found else ""
			testing.expectf(t, text == c.want[i], "name %q record %d: %q", c.name, i, text)
		}
	}
}

// A text of more records than a batch holds, and one record of 50000 cells, read in batches of three, frame as a
// quote-honouring framer does.
@(test)
records_across_batches_frame_as_a_model_does :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x3b)
	defer free_all(context.temp_allocator)
	for round in 0 ..< testkit.rounds(6) {
		spec := dsv.Spec(round % 3)
		src := seeded_rows(spec, 700)
		for opts in LAYOUTS {
			if !records_match_model(t, src, spec, opts) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
	wide := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< 3 {
		for c in 0 ..< 50_000 {
			strings.write_string(&wide, "," if c > 0 else "")
			strings.write_string(&wide, "\"x\"" if c % 7 == 0 else "1")
		}
		strings.write_byte(&wide, '\n')
	}
	records_match_model(t, strings.to_string(wide), .Csv, {format = dsv.Dsv_Options{no_header = true}})
}

// A quoted header name, a byte order mark, CR LF line ends, a blank line and a quoted line end in a cell: each record is
// its line, a column is found by its decoded name, and a cell reads decoded.
@(test)
records_read_a_quoted_header_name_and_a_blank_line :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("\xef\xbb\xbfid,\"pri\"\"ce\",note\r\n1,\"2,5\",\"a\"\"b\"\n\n2,7,\"x\ny\"\n")
	r := dsv.records_open(src)
	out: [4]dsv.Record
	testing.expect_value(t, dsv.records_validate(&r, out[:]), 2)
	testing.expect_value(t, r.err, nil)
	testing.expect_value(t, string(src[out[0].lo:out[0].hi]), "1,\"2,5\",\"a\"\"b\"")
	testing.expect_value(t, string(src[out[1].lo:out[1].hi]), "2,7,\"x\ny\"")
	answers: [4]dsv.Span_Answer
	r = dsv.records_open(src)
	n := dsv.records_find(&r, []tape.Step{tape.Name("pri\"ce")}, out[:], answers[:])
	testing.expect_value(t, n, 2)
	buf: [16]u8
	for want, i in ([]string{"2,5", "7"}) {
		text, _ := dsv.node_text(dsv.as(.Csv), src, dsv.answer_node(answers[i]), buf[:])
		testing.expectf(t, answers[i].outcome == .Found && text == want, "record %d: %v %q", i, answers[i].outcome, text)
	}
	r = dsv.records_open(src)
	n = dsv.records_find(&r, []tape.Step{tape.Name("nope")}, out[:], answers[:])
	testing.expect(t, n == 2 && answers[0].outcome == .Missing)
}

// A framing other than lines is none of a delimited text's, which every records read refuses before the first record.
@(test)
records_refuse_a_framing_a_delimited_text_does_not_have :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a\n1\n")
	for framing in tape.Framing {
		if framing == .Lines {
			continue
		}
		r := dsv.records_open(src, framing)
		out: [2]dsv.Record
		n := dsv.records_validate(&r, out[:])
		_, refused := r.err.(tape.Bad_Option)
		testing.expectf(t, n == 0 && refused, "%v: %d records, %v", framing, n, r.err)
	}
}

// Reads the records of `src` as the text of each alone does, whole and in windows of several sizes, with the paths of a
// record a text may have.
@(private = "file")
records_alone_in_windows :: proc(t: ^testing.T, src: []u8, spec: dsv.Spec, opts: dsv.Options, name: string) -> bool {
	d, _ := opts.format.(dsv.Dsv_Options)
	paths := [][]tape.Step{{tape.Name("a")}, {tape.Name("k0")}, {tape.Name("3")}, {tape.Name("zz")}, {tape.All{}}, {tape.Index(1)}, {tape.Index(-1)}, {tape.Slice{lo = 1}}}
	for cuts in ([][]int{nil, {len(src) / 2}, {1, 2, 3}, testkit.cuts_by(len(src), 3), testkit.cuts_by(len(src), 17), testkit.cuts_by(len(src), 64)}) {
		run := testkit.Piece_Run{src, dsv.reads(spec), dsv.as(spec), opts, cuts}
		head := testkit.Alone_Head.First_Record if d.no_header else .Text_Before_First
		testkit.records_alone_agree(t, run, {head = head, rows = true}, paths, name) or_return
	}
	return true
}

// Each record of a text answers as the text of the header and that record alone does, and under `no_header` as the text
// of the first record and that record, whose width the others take: its verdict with the fault at the record's place, each path found with and without `stop_early`, and the
// scan of them, whole and in windows, over the texts the tests read and generated ones.
@(test)
records_answer_as_their_own_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x6a)
	defer free_all(context.temp_allocator)
	for c in BUILT {
		if !records_alone_in_windows(t, transmute([]u8)c.text, c.spec, {format = c.opts, tolerate = c.tol}, c.text) {
			return
		}
	}
	for c in CSV_CASES {
		if !records_alone_in_windows(t, transmute([]u8)c.text, .Csv, {}, c.text) {
			return
		}
	}
	for text in ([]string{"a,b\n1,2\n3\n\"x\ny\",4\r\n\n5,6", "\xef\xbb\xbfid,\"pri\"\"ce\",note\r\n1,\"2,5\",\"a\"\"b\"\n\n2,7,\"x\ny\"\n", "a,b\n#c\n1,2\n#d\n3,4\n"}) {
		for opts in LAYOUTS {
			if !records_alone_in_windows(t, transmute([]u8)text, .Csv, opts, text) {
				return
			}
		}
	}
	for _ in 0 ..< testkit.rounds(40) {
		text, spec, opts := random_text()
		if !records_alone_in_windows(t, text, spec, opts, "generated") {
			return
		}
		free_all(context.temp_allocator)
	}
	for round in 0 ..< testkit.rounds(12) {
		spec := dsv.Spec(round % 3)
		text := seeded_rows(spec, 12)
		for opts in LAYOUTS {
			if !records_alone_in_windows(t, transmute([]u8)text, spec, opts, "seeded") {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

// A record narrower than the header, with a record after it, is refused by a find or a scan that stops at its answer, as the text of the header
// and that record alone is, whose cell ends at the text's end.
@(test)
records_stopped_at_an_answer_judge_the_width_of_a_record :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\n1,2\n3\n4,5\n")
	_, alone := dsv.find(transmute([]u8)string("a,b\n3"), []tape.Step{tape.Index(0), tape.Name("a")}, .Csv, {stop_early = true})
	fault, faulted := alone.(tape.Fault)
	testing.expectf(t, faulted && fault.kind == .Bad_Width, "find of the header and the record: %v", alone)
	r := dsv.records_open(src)
	out: [4]dsv.Record
	answers: [4]dsv.Span_Answer
	n := dsv.records_find(&r, []tape.Step{tape.Name("a")}, out[:], answers[:], {stop_early = true})
	testing.expect_value(t, n, 3)
	_, find_fault := out[1].err.(tape.Fault)
	testing.expectf(t, find_fault, "find of the record: %v", out[1].err)
	demand, _ := dsv.demand_of({{tape.Name("a")}})
	defer dsv.destroy(&demand)
	r = dsv.records_open(src)
	docs: [4]dsv.Document
	n = dsv.records_scan(&r, &demand, out[:], docs[:], {stop_early = true})
	defer for &d in docs[:n] {
		dsv.destroy(&d)
	}
	_, scan_fault := out[1].err.(tape.Fault)
	testing.expectf(t, n == 3 && scan_fault, "scan of the record: %v", out[1].err)
}

// With no header the first record's width is the others', also when a find or a scan stopped at its answer in that
// record, so a narrower record after it faults as the text of the first record and that record does.
@(test)
records_with_no_header_judge_the_width_of_a_first_record_read_to_its_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	opts := dsv.Options {
		format = dsv.Dsv_Options{no_header = true},
	}
	src := transmute([]u8)string("1,2\n3\n4,5\n")
	_, alone := dsv.find(transmute([]u8)string("1,2\n3"), []tape.Step{tape.Index(1), tape.Index(1)}, .Csv, {stop_early = true}, opts)
	fault, faulted := alone.(tape.Fault)
	testing.expectf(t, faulted && fault.kind == .Bad_Width, "find of the first record and the record: %v", alone)
	out: [4]dsv.Record
	answers: [4]dsv.Span_Answer
	r := dsv.records_open(src, .Lines, .Csv, opts)
	n := dsv.records_find(&r, []tape.Step{tape.Index(1)}, out[:], answers[:], {stop_early = true})
	testing.expect_value(t, n, 3)
	_, find_fault := out[1].err.(tape.Fault)
	testing.expectf(t, find_fault && out[0].err == nil && out[2].err == nil, "find of the records: %v %v %v", out[0].err, out[1].err, out[2].err)
	demand, _ := dsv.demand_of({{tape.Index(1)}})
	defer dsv.destroy(&demand)
	r = dsv.records_open(src, .Lines, .Csv, opts)
	docs: [4]dsv.Document
	n = dsv.records_scan(&r, &demand, out[:], docs[:], {stop_early = true})
	defer for &d in docs[:n] {
		dsv.destroy(&d)
	}
	_, scan_fault := out[1].err.(tape.Fault)
	testing.expectf(t, n == 3 && scan_fault, "scan of the records: %v", out[1].err)
}

// A text with a header of `columns` cells and one record, which is past the cells the records hold in their own state
// when `columns` is past 128.
@(private = "file")
wide_header_text :: proc(columns: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< columns {
		fmt.sbprintf(&b, "%sk%d", "," if i > 0 else "", i)
	}
	strings.write_string(&b, "\n1,2\n")
	return transmute([]u8)strings.to_string(b)
}

@(private = "file")
Wide_Run :: struct {
	src:   []u8,
	stuck: int, // the runs whose records ended with an error and still asked for a window
}

// The records of a wide header in pieces, read as far as they go or four batches of two, under the allocator `a`.
@(private = "file")
read_wide_records_in_pieces :: proc(data: rawptr, a: runtime.Allocator) {
	run := (^Wide_Run)(data)
	src := run.src
	p := tape.Pieces {
		allocator = a,
		last      = true,
	}
	defer tape.destroy(&p)
	rr, err := dsv.reads(.Csv).records(dsv.as(.Csv), src, .Lines, {pieces = &p}, a)
	if err != nil {
		return
	}
	defer tape.destroy_records(rr)
	out: [2]tape.Record
	answers: [2]tape.Span_Answer
	for _ in 0 ..< 4 {
		n := tape.records_find(rr, []tape.Step{tape.Index(0)}, out[:], answers[:], {}, a)
		if n < len(out) {
			break
		}
	}
	if rr.err != nil && p.more {
		run.stuck += 1
	}
}

// Records of a text in pieces whose allocation is refused at any point end with the error, give no record after it, and
// leave the pieces with nothing more to read, instead of reading a state that was never made.
@(test)
records_in_pieces_end_when_an_allocation_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	run := Wide_Run {
		src = wide_header_text(150),
	}
	s := testkit.sweep_failures(read_wide_records_in_pieces, &run)
	testing.expectf(t, s.refused > 0 && s.bad == 0 && run.stuck == 0, "%v, %d stuck", s, run.stuck)
}

// Records of a whole text take the allocator they are given, also for the header's keys past what their own state holds.
@(test)
records_allocate_from_the_allocator_they_are_given :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := wide_header_text(200)
	ambient := testkit.Failing {
		backing = context.allocator,
		fail_at = -1,
	}
	given := testkit.Failing {
		backing = context.allocator,
		fail_at = -1,
	}
	{
		context.allocator = testkit.failing_allocator(&ambient)
		rr, err := dsv.reads(.Csv).records(dsv.as(.Csv), src, .Lines, {}, testkit.failing_allocator(&given))
		defer tape.destroy_records(rr)
		testing.expect_value(t, err, nil)
		out: [2]tape.Record
		testing.expect_value(t, tape.records_validate(rr, out[:], testkit.failing_allocator(&given)), 1)
	}
	testing.expect_value(t, ambient.count, 0)
	testing.expect(t, given.count > 1)
}

// The comment lines a read of records skips are judged as a whole read judges them: an ill-formed sequence in one ends
// the records at the fault the text's verdict gives, after the records before it.
@(test)
records_judge_the_comment_lines_they_skip :: proc(t: ^testing.T) {
	testkit.deadline(t)
	opts := dsv.Options {
		format = dsv.Dsv_Options{comment = '#'},
	}
	for c in ([]struct {
			src:     string,
			records: int,
		}{
			{"a,b\r\n#z,\xff\r\n", 0},
			{"a,b\n#\xff\n1,2\n", 0},
			{"a,b\n1,2\n#\xe2\x82\xff\n3,4\n", 1},
			{"a,b\n1,2\n# x\xe2\x82", 1},
			{"a,b\n1,2\n\n# \xc3(\n3,4\n", 1},
		}) {
		want := dsv.validate(transmute([]u8)c.src, .Csv, opts)
		fault, faulted := want.(tape.Fault)
		testing.expectf(t, faulted && fault.detail != 0, "%q: validate gave %v", c.src, want)
		r := dsv.records_open(transmute([]u8)c.src, .Lines, .Csv, opts)
		out: [4]dsv.Record
		n := dsv.records_validate(&r, out[:])
		testing.expectf(t, n == c.records && r.err == want, "%q: %d records, %v, want %d and %v", c.src, n, r.err, c.records, want)
	}
}

// A record that ends in a sequence its line end cuts is ill-formed when the text goes on past it, as the text's verdict
// says, and cut only at the text's end.
@(test)
records_end_in_an_ill_formed_sequence_unless_the_text_ends :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			src:     string,
			kind:    tape.Fault_Kind,
			at:      u64,
		}{
			{"a\nx\xc3\ny\n", .Bad_Char, 3},
			{"a\r\nx\xe2\x82\r\ny\r\n", .Bad_Char, 4},
			{"a\nx\xf0\x9f\x98\n", .Bad_Char, 3},
			{"a\nx\xc3", .Truncated, 4},
			{"a\nx\xe2\x82", .Truncated, 5},
		}) {
		src := transmute([]u8)c.src
		want, _ := dsv.validate(src).(tape.Fault)
		testing.expectf(t, want.kind == c.kind && want.at == c.at, "%q: validate gave %v", c.src, want)
		r := dsv.records_open(src)
		out: [4]dsv.Record
		n := dsv.records_validate(&r, out[:])
		got, _ := out[0].err.(tape.Fault)
		testing.expectf(t, n >= 1 && got.kind == want.kind && got.at == want.at && got.detail == want.detail, "%q: %v, validate %v", c.src, out[0].err, want)
	}
}

// A quote the text never closes ends its record at the line it opened on, and the records go on at the next line, in a
// whole text and in windows, while a whole read faults at the quote.
@(test)
records_resume_at_the_line_after_an_unclosed_quote :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			src:   string,
			spans: []string,
			bad:   int,
		}{
			{"a,b\n1,2\n3,\"x\n4,5\n5,6", {"1,2", "3,\"x", "4,5", "5,6"}, 1},
			{"a,b\r\n3,\"x\r\n4,5\r\n", {"3,\"x", "4,5"}, 0},
			{"a,b\n\"p\nq\",\"x\n4,5\n", {"\"p\nq\",\"x", "4,5"}, 0},
			{"a,b\n3,\"x", {"3,\"x"}, 0},
		}) {
		src := transmute([]u8)c.src
		whole := dsv.validate(src)
		fault, _ := whole.(tape.Fault)
		testing.expectf(t, fault.kind == .Truncated, "%q: validate gave %v", c.src, whole)
		r := dsv.records_open(src)
		out: [6]dsv.Record
		n := dsv.records_validate(&r, out[:])
		testing.expectf(t, n == len(c.spans) && r.err == nil, "%q: %d records, %v", c.src, n, r.err)
		for i in 0 ..< min(n, len(c.spans)) {
			testing.expectf(t, string(src[out[i].lo:out[i].hi]) == c.spans[i] && (out[i].err != nil) == (i == c.bad), "%q: record %d is %q, %v", c.src, i, src[out[i].lo:out[i].hi], out[i].err)
		}
		bad, _ := out[c.bad].err.(tape.Fault)
		testing.expectf(t, bad.kind == .Truncated && bad.at == fault.at, "%q: record %d faults %v, validate %v", c.src, c.bad, out[c.bad].err, whole)
	}
}

// A TSV backslash before a line feed escapes nothing, so the row ends there in the records as in every whole read.
@(test)
records_end_a_tsv_row_at_a_line_feed_after_a_backslash :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a\tb\n1\\\n3\t4\n5\t6\n")
	whole, err := dsv.build(src, .Tsv)
	defer dsv.destroy(&whole)
	fault, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && fault.at == 5, "build: %v", err)
	r := dsv.records_open(src, .Lines, .Tsv)
	out: [4]dsv.Record
	n := dsv.records_validate(&r, out[:])
	testing.expect_value(t, n, 3)
	spans := []string{"1\\", "3\t4", "5\t6"}
	for i in 0 ..< min(n, 3) {
		testing.expectf(t, string(src[out[i].lo:out[i].hi]) == spans[i] && (out[i].err != nil) == (i == 0), "record %d is %q, %v", i, src[out[i].lo:out[i].hi], out[i].err)
	}
}

// A record's end is found 64 bytes at a time, so a quoted line feed, a doubled quote and the line end of a CR LF are
// put at every offset of a block edge, and each record keeps the bytes the whole text gives it.
@(test)
records_frame_across_block_edges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for spec in dsv.Spec {
		for pad in 0 ..< 140 {
			body := strings.builder_make(context.temp_allocator)
			strings.write_string(&body, "a,b\n")
			for _ in 0 ..< pad {
				strings.write_byte(&body, 'x')
			}
			if spec == .Csv {
				strings.write_string(&body, ",\"q\"\"\n,\"\"z\n\"\r\nlast,1\n")
			} else {
				strings.write_string(&body, ",1\r\nlast,1\n")
			}
			src := transmute([]u8)strings.to_string(body)
			whole, err := dsv.build(src, spec, {tolerate = {.Ragged}})
			defer dsv.destroy(&whole)
			r := dsv.records_open(src, .Lines, spec, {tolerate = {.Ragged}})
			out: [4]dsv.Record
			n := dsv.records_validate(&r, out[:])
			testing.expectf(t, err == nil && n == 2 && out[0].err == nil && out[1].err == nil, "%v pad %d: %v, %d records", spec, pad, err, n)
			if n == 2 {
				testing.expectf(t, string(src[out[1].lo:out[1].hi]) == "last,1", "%v pad %d: last record %q", spec, pad, src[out[1].lo:out[1].hi])
			}
		}
	}
}

// The records of a text in pieces are read a window at a time, a record the window's end cuts read in the next, each
// keyed by the header, which the windows past it need not hold.
@(test)
records_in_pieces_read_a_window_at_a_time :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("a,b\n1,\"two\nlines\"\n3,4\n")
	p := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&p)
	r := dsv.records_open(src[:5], .Lines, .Csv, {pieces = &p})
	got := make([dynamic]string, context.temp_allocator)
	windows := 1
	for {
		out: [4]tape.Record
		answers: [4]tape.Span_Answer
		n := dsv.records_find(&r, {tape.Name("b")}, out[:], answers[:])
		for a in answers[:n] {
			append(&got, string(src[a.lo:a.hi]))
		}
		if !p.more {
			break
		}
		windows += 1
		p.from = p.keep
		end := min(p.at + 5, u64(len(src)))
		p.last = end == u64(len(src))
		testing.expect_value(t, tape.records_window(&r, src[p.from:end]), nil)
	}
	testing.expectf(t, r.err == nil && slice.equal(got[:], []string{"\"two\nlines\"", "4"}), "%v %q", r.err, got[:])
	testing.expectf(t, windows > 2, "%v windows", windows)
}

// A header that faults ends the records of a text in pieces when a window holds its line: at open when the first window
// does, as it ends a whole text's, else at the batch whose window first does.
@(test)
records_in_pieces_give_a_header_fault_where_the_header_ends :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("# note\na\xFF,b\n1,2\n")
	opts := tape.Options{format = dsv.Dsv_Options{comment = '#'}}
	whole := dsv.records_open(src, .Lines, .Csv, opts)
	testing.expect(t, whole.err != nil)
	for cut in ([]int{11, 12, 15}) {
		p := dsv.Pieces{allocator = context.allocator}
		defer dsv.destroy(&p)
		o := opts
		o.pieces = &p
		r := dsv.records_open(src[:cut], .Lines, .Csv, o)
		holds := cut >= 12
		testing.expectf(t, r.err == (whole.err if holds else nil), "cut %v: open %v, whole %v", cut, r.err, whole.err)
	}
	p := dsv.Pieces{allocator = context.allocator}
	defer dsv.destroy(&p)
	o := opts
	o.pieces = &p
	r := dsv.records_open(src[:10], .Lines, .Csv, o)
	testing.expect_value(t, r.err, nil)
	out: [2]tape.Record
	n := dsv.records_validate(&r, out[:])
	testing.expect(t, n == 0 && r.err == nil && p.more)
	p.from, p.last = p.keep, true
	testing.expect_value(t, tape.records_window(&r, src[p.from:]), nil)
	n = dsv.records_validate(&r, out[:])
	testing.expectf(t, n == 0 && r.err == whole.err, "%v %v, whole %v", n, r.err, whole.err)
}
