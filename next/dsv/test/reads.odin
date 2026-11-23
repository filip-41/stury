package dsv_tests

import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

// Writes the value at `at` of `doc` through the readers, as JSON: a table's rows as objects whose keys are the header's.
render_value :: proc(b: ^strings.Builder, doc: ^dsv.Document, at: dsv.Node_Index) {
	r := dsv.Reader{doc = doc}
	n := doc.nodes[at]
	buf: [256]u8
	#partial switch n.kind {
	case .Null:
		strings.write_string(b, "null")
	case .True:
		strings.write_string(b, "true")
	case .False:
		strings.write_string(b, "false")
	case .Number:
		strings.write_string(b, string(dsv.span_bytes(doc, n.lo, n.n)))
	case .String:
		text, _ := dsv.node_text(doc, at, buf[:])
		fmt.sbprintf(b, "%q", text)
	case .Array, .Object:
		c, _, _ := dsv.children(r, at, context.temp_allocator)
		strings.write_byte(b, '[' if n.kind == .Array else '{')
		for first := true; ; first = false {
			key, value, p := dsv.next_child(r, &c)
			if p == .Missing {
				break
			}
			if !first {
				strings.write_byte(b, ',')
			}
			if key != dsv.NO_NODE {
				text, _ := dsv.node_text(doc, key, buf[:])
				fmt.sbprintf(b, "%q:", text)
			}
			render_value(b, doc, value)
		}
		strings.write_byte(b, ']' if n.kind == .Array else '}')
	}
}

render :: proc(doc: ^dsv.Document) -> string {
	b := strings.builder_make(context.temp_allocator)
	if len(doc.nodes) > 0 {
		render_value(&b, doc, dsv.ROOT)
	}
	return strings.to_string(b)
}

Built :: struct {
	text: string,
	spec: dsv.Spec,
	opts: dsv.Dsv_Options,
	tol:  tape.Tolerances,
	want: string,
}

// Texts and the documents their builds read as.
@(rodata)
BUILT := []Built {
	{"a,b\n1,2\n3,4\n", .Csv, {}, {}, `[{"a":"1","b":"2"},{"a":"3","b":"4"}]`},
	{"a,b\r\n1,2", .Csv, {}, {}, `[{"a":"1","b":"2"}]`},
	{"a,b\n", .Csv, {}, {}, `[]`},
	{"", .Csv, {}, {}, `[]`},
	{"\xef\xbb\xbfa\n1\n", .Csv, {}, {}, `[{"a":"1"}]`},
	{"a,b\n,\"\"\n", .Csv, {}, {}, `[{"a":null,"b":""}]`},
	{"\"x\"\"y\",\"p,q\"\n\"a\nb\",c\n", .Csv, {}, {}, `[{"x\"y":"a\nb","p,q":"c"}]`},
	{"1,2\n3,4\n", .Csv, {no_header = true}, {}, `[["1","2"],["3","4"]]`},
	{"a,b,c\n1,2.5e3,true\n-0,x,false\n", .Csv, {infer = true}, {}, `[{"a":1,"b":2.5e3,"c":true},{"a":-0,"b":"x","c":false}]`},
	{"a,b\n01,\"1\"\n", .Csv, {infer = true}, {}, `[{"a":"01","b":"1"}]`},
	{"a\tb\nx\\ty\t\\\\\n", .Tsv, {}, {}, `[{"a":"x\ty","b":"\\"}]`},
	{"a;b\n1;2\n", .Plain, {delimiter = ';'}, {}, `[{"a":"1","b":"2"}]`},
	{"a,b\n1,2,3\n4\n", .Csv, {}, {.Ragged}, `[{"a":"1","b":"2","3":"3"},{"a":"4"}]`},
	{"a,a\n1,2\n", .Csv, {}, {}, `[{"a":"2"}]`},
	{"# c\na,b\n#d\n1,2\n# e\n", .Csv, {comment = '#'}, {}, `[{"a":"1","b":"2"}]`},
	{"a,b\n\xff,2\n", .Csv, {}, {.Invalid_Utf8}, `[{"a":"�","b":"2"}]`},
	{"a\"\tb\xff,c\n1\"\"2,\"q\"\"\xff\"\n", .Csv, {}, {.Bare_Quote, .Invalid_Utf8}, `[{"a\"\tb�":"1\"\"2","c":"q\"�"}]`},
}

@(test)
builds_read_as_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for c in BUILT {
		doc, err := dsv.build(transmute([]u8)c.text, c.spec, {format = c.opts, tolerate = c.tol})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.text, err) {
			continue
		}
		got := render(&doc)
		testing.expectf(t, got == c.want, "%q: %s, want %s", c.text, got, c.want)
	}
}

// The header is stored once past the root's records, which the root counts alone, and each record holds no key.
@(test)
builds_store_the_header_once :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a,b\n1,2\n3,4\n")
	doc, err := dsv.build(src)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(doc.nodes), 10)
	testing.expect_value(t, doc.nodes[0].n, 7)
	testing.expect_value(t, int(doc.nodes[0].spelling & tape.MAX_CHILDREN), 2)
	header := doc.nodes[7]
	testing.expect(t, header.kind == .Array && header.role == .Key && header.n == 3)
	n, _, _ := dsv.length({doc = &doc}, dsv.ROOT, context.allocator)
	testing.expect_value(t, n, 2)
	row, _ := dsv.element({doc = &doc}, dsv.ROOT, 1)
	v, p := dsv.member({doc = &doc}, row, "b")
	testing.expect(t, p == .Found && string(src[doc.nodes[v].lo:][:1]) == "4")
}

// A header wider than a 16-bit column number still names its cells by key slots, so the build stays linear.
@(test)
builds_name_cells_of_a_very_wide_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	COLUMNS :: 70_000
	head := strings.builder_make()
	row := strings.builder_make()
	defer strings.builder_destroy(&head)
	defer strings.builder_destroy(&row)
	for c in 0 ..< COLUMNS {
		sep := "," if c > 0 else ""
		fmt.sbprintf(&head, "%sc%d", sep, c)
		fmt.sbprintf(&row, "%sv%d", sep, c)
	}
	text := fmt.aprintf("%s\n%s\n", strings.to_string(head), strings.to_string(row))
	defer delete(text)
	doc, err := dsv.build(transmute([]u8)text)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	r := dsv.Reader{doc = &doc}
	rec, _ := dsv.element(r, dsv.ROOT, 0)
	for c in ([]int{0, 65_533, 65_534, 65_535, 65_536, COLUMNS - 1}) {
		v, p := dsv.member(r, rec, fmt.tprintf("c%d", c))
		buf: [16]u8
		got, _ := dsv.node_text(&doc, v, buf[:])
		testing.expectf(t, p == .Found && got == fmt.tprintf("v%d", c), "column %d: %v %q", c, p, got)
	}
	_, p := dsv.member(r, rec, "c70000")
	testing.expect_value(t, p, tape.Presence.Missing)
}

// A build's nodes are the root value's subtree and then the header, in no container. A reader gives rows and cells from
// the subtree and keys from the header, and never the header's own node.
@(test)
builds_keep_the_header_past_the_root_subtree :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	for c in ([]struct {
		text: string,
		tol:  tape.Tolerances,
	} {
		{"a,b\n1,2\n3,4\n", {}},
		{"a,b\n", {}},
		{"a,b\n1,2,3\n4\n", {.Ragged}},
		{"a,a,b,c,d,e,f,g,h,i\n1,2,3,4,5,6,7,8,9,10\n", {}},
	}) {
		src := transmute([]u8)c.text
		doc, err := dsv.build(src, .Csv, {tolerate = c.tol})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.text, err) {
			continue
		}
		root := dsv.Node_Index(doc.nodes[0].n)
		testing.expectf(t, root < dsv.Node_Index(len(doc.nodes)), "%q: no header past the root", c.text)
		header := doc.nodes[root]
		testing.expectf(t, header.kind == .Array && header.role == .Key && int(root) + int(header.n) == len(doc.nodes), "%q: header %v past a root of %d nodes", c.text, header, root)
		r := dsv.Reader{doc = &doc}
		rows, _, _ := dsv.children(r, dsv.ROOT, context.temp_allocator)
		for {
			_, row, p := dsv.next_child(r, &rows)
			if p == .Missing {
				break
			}
			testing.expectf(t, row < root, "%q: row %d is past the root's subtree", c.text, row)
			cells, _, _ := dsv.children(r, row, context.temp_allocator)
			for {
				key, cell, q := dsv.next_child(r, &cells)
				if q == .Missing {
					break
				}
				testing.expectf(t, cell < root && key > root && key < root + dsv.Node_Index(header.n), "%q: cell %d key %d, header at %d", c.text, cell, key, root)
			}
		}
	}
	doc, err := dsv.build(transmute([]u8)string("1,2\n"), .Csv, {format = dsv.Dsv_Options{no_header = true}})
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, int(doc.nodes[0].n), len(doc.nodes))
}

// A header that repeats a key gives a row's first or last cell of it by the build's policy, and `.Refuse` faults at
// the repeat's first byte.
@(test)
builds_take_repeated_keys_by_policy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	src := transmute([]u8)string("a,b,\"a\"\n1,2,3\n")
	for c in ([]struct {
			dups: tape.Duplicates,
			want: string,
		}{{.Default, `[{"a":"3","b":"2"}]`}, {.Last, `[{"a":"3","b":"2"}]`}, {.First, `[{"a":"1","b":"2"}]`}}) {
		doc, err := dsv.build(src, .Csv, {dups = c.dups})
		testing.expectf(t, err == nil && render(&doc) == c.want, "%v: %s %v", c.dups, render(&doc), err)
		dsv.destroy(&doc)
	}
	_, err := dsv.build(src, .Csv, {dups = .Refuse})
	f, faulted := err.(tape.Fault)
	testing.expectf(t, faulted && f.kind == .Duplicate_Key && f.at == 4, "refuse: %v", err)
	// A header wide enough for key slots finds its keys by hash.
	wide := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 40 {
		fmt.sbprintf(&wide, "%sk%d", "," if i > 0 else "", i)
	}
	strings.write_string(&wide, ",k7\n")
	for i in 0 ..< 41 {
		fmt.sbprintf(&wide, "%s%d", "," if i > 0 else "", i)
	}
	strings.write_byte(&wide, '\n')
	doc, werr := dsv.build(transmute([]u8)strings.to_string(wide))
	defer dsv.destroy(&doc)
	row, _ := dsv.element({doc = &doc}, dsv.ROOT, 0)
	expected := [3]string{"0", "39", "40"}
	for name, want in ([]string{"k0", "k39", "k7"}) {
		v, p := dsv.member({doc = &doc}, row, name)
		testing.expectf(t, werr == nil && p == .Found, "%s: %v %v", name, p, werr)
		if p == .Found {
			text := string(dsv.span_bytes(&doc, doc.nodes[v].lo, doc.nodes[v].n))
			expect := expected[want]
			testing.expectf(t, text == expect, "%s: %s, want %s", name, text, expect)
		}
	}
	_, p := dsv.member({doc = &doc}, row, "k40")
	testing.expect_value(t, p, dsv.Presence.Missing)
}

// Comment lines are facts of the record after them, and the root's foot past the last. Those before the header are
// the root's.
@(test)
builds_keep_comment_lines_as_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Read :: struct {
		src:       string,
		comment:   u8,
		no_header: bool,
		node:      tape.Node_Index,
		kind:      tape.Fact_Kind,
		body:      string,
	}
	for c in ([]Read {
			{"a,b\n#head\n1,2\n", '#', false, 1, .Comment, "head"},
			{"a,b\n1,2\n#foot\n", '#', false, dsv.ROOT, .Comment_Foot, "foot"},
			{"#top\na,b\n1,2\n", '#', false, dsv.ROOT, .Comment, "top"},
			{"a,b\n1,2\n#end", '#', false, dsv.ROOT, .Comment_Foot, "end"},
			{"//hello\na,b\n1,2\n", '/', false, dsv.ROOT, .Comment, "/hello"},
			{"\xEF\xBB\xBF#c\na,b\n1,2\n", '#', false, dsv.ROOT, .Comment, "c"},
			{"#c\r\n1,2\n", '#', true, 1, .Comment, "c"},
			{"#only\n\n", '#', false, dsv.ROOT, .Comment_Foot, "only"},
			{"#top\na,b\n", '#', false, dsv.ROOT, .Comment_Foot, "top"},
		}) {
		src := transmute([]u8)c.src
		doc, err := dsv.build(src, .Csv, {format = dsv.Dsv_Options{comment = c.comment, no_header = c.no_header}})
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil && len(doc.facts) == 1, "%q: %v %v", c.src, err, doc.facts) {
			continue
		}
		f := doc.facts[0]
		testing.expectf(t, f.node == c.node && f.kind == c.kind && string(src[f.lo + 1:f.lo + u64(f.n)]) == c.body, "%q: %v", c.src, f)
	}
}

// Options a spec cannot read, and options of another family, are refused before the text is read.
@(test)
reads_refuse_bad_options :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string("a\n")
	for c in ([]struct {
			spec: dsv.Spec,
			opts: dsv.Dsv_Options,
			want: string,
		}{{.Csv, {delimiter = '"'}, "delimiter"}, {.Csv, {delimiter = '\n'}, "delimiter"}, {.Tsv, {delimiter = 'n'}, "delimiter"}, {.Csv, {comment = ','}, "comment"}, {.Tsv, {comment = '\\'}, "comment"}}) {
		want := tape.Error(tape.Bad_Option{c.want})
		opts := dsv.Options{format = c.opts}
		testing.expectf(t, dsv.validate(src, c.spec, opts) == want, "%v", c)
		_, err := dsv.build(src, c.spec, opts)
		testing.expectf(t, err == want, "%v build: %v", c, err)
		r := dsv.records_open(src, .Lines, c.spec, opts)
		testing.expectf(t, r.err == want, "%v records: %v", c, r.err)
	}
	p := tape.Pieces{allocator = context.allocator}
	testing.expect_value(t, dsv.validate(src, .Csv, {pieces = &p}), tape.Error(tape.Bad_Option{"pieces"}))
	runner: tape.Runner
	testing.expect_value(t, dsv.validate(src, .Csv, {runner = &runner}), tape.Error(tape.Bad_Option{"runner"}))
	_, err := dsv.build(src, .Csv, {runner = &runner})
	testing.expect_value(t, err, tape.Error(tape.Bad_Option{"runner"}))
}

// A depth budget of one level holds the text but no record.
@(test)
reads_keep_the_depth_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	want := tape.Error(tape.Exceeded{at = 2, kind = .Depth})
	src := transmute([]u8)string("a\n1\n")
	opts := dsv.Options{budget = {depth = 1}}
	testing.expect_value(t, dsv.validate(src, .Csv, opts), want)
	_, err := dsv.build(src, .Csv, opts)
	testing.expect_value(t, err, want)
	testing.expect_value(t, dsv.validate(transmute([]u8)string("a\n"), .Csv, opts), nil)
}

Found :: struct {
	text: string,
	path: []tape.Step,
	opts: dsv.Dsv_Options,
	want: tape.Presence,
	span: string,
}

@(test)
finds_answer_cells_and_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]Found {
		{"a,b\n1,2\n3,4\n", {tape.Index(1), tape.Name("b")}, {}, .Found, "4"},
		{"a,b\n1,2\n3,4\n", {tape.Index(-2), tape.Name("a")}, {}, .Found, "1"},
		{"a,b\n1,2\n3,4\n", {tape.Index(0), tape.Name("c")}, {}, .Missing, ""},
		{"a,b\n1,\"x\"\"y\"\n", {tape.Index(0), tape.Name("b")}, {}, .Found, `"x""y"`},
		{"1,2\n3,4\n", {tape.Index(1), tape.Index(0)}, {no_header = true}, .Found, "3"},
		{"a,b\n1,2\n3,4\n", {tape.Index(1)}, {}, .Found, "3,4\n"},
		{"a\n1\n", {tape.Name("a")}, {}, .Wrong_Kind, ""},
	}) {
		src := transmute([]u8)c.text
		for stop in ([]bool{false, true}) {
			a, err := dsv.find(src, c.path, .Csv, {stop_early = stop}, {format = c.opts})
			span := c.text[a.lo:a.hi] if a.outcome == .Found else ""
			testing.expectf(t, err == nil && a.outcome == c.want && span == c.span, "%q %v stop %v: %v %q %v", c.text, c.path, stop, a.outcome, span, err)
		}
	}
}

// A find that passes over the records after its answer judges them against the width of the records before.
@(test)
finds_judge_the_rest_by_the_width_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			text: string,
			opts: dsv.Dsv_Options,
			at:   u64,
		}{{"1,2\n3\n", {no_header = true}, 5}, {"a,b\n1,2\n3\n", {}, 9}, {"1,2\n3,4,5\n", {no_header = true}, 7}}) {
		_, err := dsv.find(transmute([]u8)c.text, {tape.Index(0)}, .Csv, {}, {format = c.opts})
		fault, ok := err.(tape.Fault)
		testing.expectf(t, ok && fault.kind == .Bad_Width && fault.at == c.at, "%q: %v", c.text, err)
	}
}

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

// The readers law over the texts the tests read and generated ones: a scan's partial document answers as the build
// does, and a text the build refuses is refused by every read.
@(test)
scans_agree_with_builds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	a: testkit.Agreement
	defer delete(a.shapes)
	for c in BUILT {
		testkit.readers_agree(t, dsv.reads(c.spec), dsv.as(c.spec), transmute([]u8)c.text, {format = c.opts, tolerate = c.tol}, c.text, &a)
	}
	for c in CSV_CASES {
		testkit.readers_agree(t, dsv.reads(.Csv), dsv.as(.Csv), transmute([]u8)c.text, {}, c.text, &a)
	}
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0xd5f)
	for _ in 0 ..< testkit.rounds(40) {
		text, spec, opts := random_text()
		testkit.readers_agree(t, dsv.reads(spec), dsv.as(spec), text, opts, "generated", &a)
	}
	testkit.expect_agreement(t, &a, {texts = 40, refused = 10, scans = 2000, on_path = 2000, shapes = 10})
}

// A random delimited text of a few records, with quoted cells, escapes, empty cells, comment lines, ragged records and
// CR LF line ends, and the options it reads with.
random_text :: proc() -> ([]u8, dsv.Spec, dsv.Options) {
	spec := dsv.Spec(rand.int_max(3))
	o: dsv.Options
	d := dsv.Dsv_Options{no_header = rand.int_max(4) == 0, infer = rand.int_max(2) == 0, comment = '#' if rand.int_max(3) == 0 else 0}
	if rand.int_max(3) == 0 {
		o.tolerate = {.Ragged}
	}
	o.format = d
	b := strings.builder_make(context.temp_allocator)
	delim := u8('\t') if spec == .Tsv else ','
	width := 1 + rand.int_max(4)
	cells := []string{"", "x", "12", "-3.5", "true", "a b", "\xc3\xa9"}
	for row in 0 ..< 1 + rand.int_max(6) {
		if d.comment != 0 && rand.int_max(4) == 0 {
			strings.write_string(&b, "# note\n")
		}
		w := width if .Ragged not_in o.tolerate else 1 + rand.int_max(5)
		for col in 0 ..< w {
			if col > 0 {
				strings.write_byte(&b, delim)
			}
			switch {
			case spec == .Csv && rand.int_max(4) == 0:
				strings.write_string(&b, "\"q,\"\"\n\"")
			case spec == .Tsv && rand.int_max(4) == 0:
				strings.write_string(&b, "t\\tu")
			case row == 0 && !d.no_header:
				fmt.sbprintf(&b, "k%d", col % 3)
			case:
				strings.write_string(&b, rand.choice(cells))
			}
		}
		strings.write_string(&b, "\r\n" if rand.int_max(3) == 0 else "\n")
	}
	if rand.int_max(5) == 0 {
		strings.write_string(&b, "x\"y")
	}
	return transmute([]u8)strings.to_string(b), spec, o
}

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

// The records of a text judge each record alike whether the walk counts steps or not, which are two instances of the
// walk, one with no tokens for a validate.
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
