package write_tests

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:yaml"

// The delimited writer: a table built from a text of each spec under each option set writes as a text of that spec
// and options that reads back as the same table, a table writes in another spec where its cells allow, and JSON writes
// as a table and a table as JSON by one rule.

@(private = "file")
OPTION_SETS := [?]dsv.Dsv_Options{{}, {infer = true}, {comment = '#'}, {no_header = true}, {delimiter = ';', infer = true}, {comment = '#', no_header = true, infer = true}, {comment = '#', crlf = true}}

@(private = "file")
TEXTS := [?]string{
	"a,b\n1,2\n",
	"name,qty\nbolt,12\n# note\n\"a,b\",3\n",
	"a,b,a\n1,2,3\n4,5,6\n",
	"x\n\"\"\n\"y\"\"z\"\nw\n",
	"a,b\r\n\"line\nend\",\"cr\rhere\"\r\n",
	"\"#h\",b\n#c\n\"#v\",\n,\n",
	"k;v\n1;\"a;b\"\ntrue;-0.5e3\n",
	"a\tb\n1\\t\\n\tx\\\\y\n",
	"h1,h2,h3\ntrue,false,null\n012,1.0,\"3\"\n",
	"\xef\xbb\xbfa,b\n\"\xef\xbb\xbf\",1\n",
	"# lead\na\n1\n# foot\n",
}

@(private = "file")
tables_round_trip :: proc(t: ^testing.T, src: string, spec: dsv.Spec, d: dsv.Dsv_Options, tally: ^Tally) {
	opts := dsv.Options{format = d}
	doc, err := dsv.build(transmute([]u8)src, spec, opts)
	if err != nil {
		return
	}
	defer dsv.destroy(&doc)
	tally.texts += 1
	for to in dsv.Spec {
		tally.writes += 1
		what := fmt.tprintf("%q as %v %v to %v", src, spec, d, to)
		text, dropped, werr := dsv.write(&doc, to)
		if werr != nil {
			r, refused := werr.(write.Refused)
			testing.expectf(t, refused && r.why == .No_Spelling && to != spec, "%s: %v", what, werr)
			tally.refused += 1
			continue
		}
		defer delete(text)
		back_opts := opts
		if to != spec {
			back := d
			back.delimiter = 0
			back_opts.format = back
		}
		holds := dsv.as(to).facts if d.comment != 0 else {}
		testing.expectf(t, dropped == doc.present - holds, "%s: dropped %v", what, dropped)
		if verr := dsv.validate(text, to, back_opts); verr != nil {
			testing.expectf(t, false, "%s: %v in %q", what, verr, text)
			continue
		}
		back, berr := dsv.build(text, to, back_opts)
		defer dsv.destroy(&back)
		testing.expect_value(t, berr, nil)
		if !testkit.values_agree(t, &doc, dsv.ROOT, &back, dsv.ROOT, {facts = holds}, what) {
			log.infof("written %q", text)
			continue
		}
		again, _, _ := dsv.write(&back, to)
		defer delete(again)
		testing.expectf(t, string(again) == string(text), "%s: rewrite %q of %q", what, again, text)
	}
	free_all(context.temp_allocator)
}

@(test)
tables_write_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	tally: Tally
	for src in TEXTS {
		for d in OPTION_SETS {
			for spec in dsv.Spec {
				tables_round_trip(t, src, spec, d, &tally)
			}
		}
	}
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x7ab1e)
	for _ in 0 ..< testkit.rounds(200) {
		// Each round trip frees the temporary allocator, so the text is the heap's.
		src := random_table()
		defer delete(src)
		for d in OPTION_SETS {
			for spec in dsv.Spec {
				tables_round_trip(t, src, spec, d, &tally)
			}
		}
	}
	testing.expectf(t, tally.texts > 1000 && tally.refused > 0, "%v", tally)
	log.infof("%d texts, %d writes, %d refused", tally.texts, tally.writes, tally.refused)
}

@(private = "file")
random_table :: proc() -> string {
	b := strings.builder_make()
	width := 1 + rand.int_max(4)
	for _ in 0 ..< 1 + rand.int_max(5) {
		if rand.int_max(6) == 0 {
			strings.write_string(&b, "# comment\n")
		}
		for j in 0 ..< width {
			if j > 0 {
				strings.write_byte(&b, ',')
			}
			cell := rand.choice([]string{"", "x", "12", "-3.5", "true", "a b", "\"q,\"", "\"l\nf\"", "\"\"\"\"", "\"\"", "é", "t\\t", "#h", ";"})
			strings.write_string(&b, cell)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// JSON as a table: an array of objects, the first one's keys the header, or of arrays with `no_header`, each cell a
// scalar, and a table as JSON: an array of objects keyed by the header.
@(test)
tables_convert_by_one_rule :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		src:  string,
		spec: dsv.Spec,
		d:    dsv.Dsv_Options,
		want: string,
	}
	cases := [?]Case{
		{`[{"a":1,"b":"x,y"},{"a":null,"b":"z"},{"a":true,"b":"q\"r"}]`, .Csv, {}, "a,b\n1,\"x,y\"\n,z\ntrue,\"q\"\"r\"\n"},
		{`[{"a":1,"b":2},{"b":3,"a":4}]`, .Csv, {infer = true}, "a,b\n1,2\n4,3\n"},
		{`[{"a":"1","b":""},{"a":2,"b":"true"}]`, .Csv, {infer = true}, "a,b\n\"1\",\"\"\n2,\"true\"\n"},
		{`[{"a":"t\tb","b":"l\nf"}]`, .Tsv, {}, "a\tb\nt\\tb\tl\\nf\n"},
		{`[[1,"x"],[2,"y"]]`, .Csv, {no_header = true}, "1,x\n2,y\n"},
		{`[{"#a":1}]`, .Csv, {comment = '#'}, "\"#a\"\n1\n"},
		{`[]`, .Csv, {}, ""},
	}
	// The values that are no array of records: an object a record, a scalar a cell, an array of scalars a column, and
	// objects with different keys under the union of their keys, a key a record lacks an empty cell.
	Shape :: struct {
		src:     string,
		want:    string,
		dropped: tape.Facts,
	}
	shapes := [?]Shape{
		{`{"a":1,"b":"x"}`, "a,b\n1,x\n", {}},
		{`"x,y"`, "\"x,y\"\n", {}},
		{`[1,"a",true]`, "1\na\ntrue\n", {}},
		{`[{"a":1},{"b":2}]`, "a,b\n1,\n,2\n", {.Absent}},
		{`[{"a":1},{"a":3,"b":2},{"c":4,"a":5}]`, "a,b,c\n1,,\n3,2,\n5,,4\n", {.Absent}},
	}
	for c in shapes {
		doc, _ := json.build(transmute([]u8)c.src)
		defer json.destroy(&doc)
		text, dropped, err := dsv.write(&doc)
		defer delete(text)
		testing.expectf(t, err == nil && string(text) == c.want && dropped == c.dropped, "%s: %q %v %v, want %q", c.src, text, dropped, err, c.want)
	}
	for c in cases {
		doc, _ := json.build(transmute([]u8)c.src)
		defer json.destroy(&doc)
		text, _, err := dsv.write(&doc, c.spec, {format = c.d})
		defer delete(text)
		testing.expectf(t, err == nil && string(text) == c.want, "%s: %q %v, want %q", c.src, text, err, c.want)
		if err != nil {
			continue
		}
		back, berr := dsv.build(text, c.spec, {format = c.d})
		defer dsv.destroy(&back)
		testing.expect_value(t, berr, nil)
		// A row whose keys stand in another order than the header's reads back in the header's.
		if !strings.contains(c.src, `{"b":3,"a":4}`) {
			testkit.values_agree(t, &doc, json.ROOT, &back, dsv.ROOT, {scalars_as_text = !c.d.infer}, c.src)
		}
	}
	Refusal :: struct {
		src:  string,
		spec: dsv.Spec,
		d:    dsv.Dsv_Options,
		want: write.Error,
	}
	refusals := [?]Refusal{
		{`[1,null]`, .Csv, {}, write.Refused{2, .No_Spelling}},
		{`[1,[2]]`, .Csv, {}, write.Refused{2, .Not_A_Table}},
		{`[{"a":1},2]`, .Csv, {}, write.Refused{4, .Not_A_Table}},
		{`[{"a":[1]}]`, .Csv, {}, write.Refused{3, .Not_A_Table}},
		{`[{"a":null}]`, .Csv, {}, write.Refused{1, .No_Spelling}},
		{`[{"a":""}]`, .Tsv, {}, write.Refused{3, .No_Spelling}},
		{`[{"a":"x,y"}]`, .Plain, {}, write.Refused{3, .No_Spelling}},
		{`[{"a":"x;y"}]`, .Tsv, {delimiter = ';'}, write.Refused{3, .No_Spelling}},
		{`[[1],[1,2]]`, .Csv, {no_header = true}, write.Refused{3, .Row_Keys}},
		{`[[1]]`, .Csv, {}, tape.Bad_Option{"no_header"}},
		{`[{"a":1}]`, .Csv, {delimiter = '"'}, tape.Bad_Option{"delimiter"}},
	}
	for c in refusals {
		doc, _ := json.build(transmute([]u8)c.src)
		defer json.destroy(&doc)
		text, _, err := dsv.write(&doc, c.spec, {format = c.d})
		testing.expectf(t, text == nil && err == c.want, "%s as %v: %v, want %v", c.src, c.spec, err, c.want)
	}
	csv := "id,name\n1,\"a \"\"b\"\"\"\n2,\n# c\n"
	table, _ := dsv.build(transmute([]u8)string(csv), .Csv, {format = dsv.Dsv_Options{infer = true, comment = '#'}})
	defer dsv.destroy(&table)
	text, dropped, err := json.write(&table, .Jsonc)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "[{\"id\":1,\"name\":\"a \\\"b\\\"\"},{\"id\":2,\"name\":null}\n// c\n]" && dropped == {}, "%q %v %v", text, dropped, err)
	plain, plain_dropped, _ := json.write(&table, .Json, {indent = 1})
	defer delete(plain)
	testing.expectf(t, string(plain) == "[\n {\n  \"id\": 1,\n  \"name\": \"a \\\"b\\\"\"\n },\n {\n  \"id\": 2,\n  \"name\": null\n }\n]" && plain_dropped == {.Comment_Foot}, "%q %v", plain, plain_dropped)
}

// A table writes what its read kept and nothing else: a partial table is refused, a repeated header name keeps the cells
// its `Duplicates` policy kept, comments go on comment lines one a body line, or with no comment byte are dropped and
// counted, and `no_header` writes records with no header line.
@(test)
tables_write_what_the_read_kept :: proc(t: ^testing.T) {
	testkit.deadline(t)
	demand, _ := tape.demand_of([][]tape.Step{{tape.Index(1)}})
	defer tape.destroy(&demand)
	part, perr := dsv.scan(transmute([]u8)string("a,b\n1,2\n3,4\n5,6\n"), &demand)
	defer dsv.destroy(&part)
	testing.expect_value(t, perr, nil)
	_, _, err := dsv.write(&part)
	r, refused := err.(write.Refused)
	testing.expectf(t, refused && r.why == .Partial, "partial: %v", err)
	for policy in ([]tape.Duplicates{.First, .Last}) {
		doc, _ := dsv.build(transmute([]u8)string("a,a,b\n1,2,3\n"), .Csv, {dups = policy})
		defer dsv.destroy(&doc)
		text, _, werr := dsv.write(&doc)
		defer delete(text)
		want := "a,b\n1,3\n" if policy == .First else "a,b\n2,3\n"
		testing.expectf(t, werr == nil && string(text) == want, "%v: %q %v", policy, text, werr)
	}
	Case :: struct {
		src:     string,
		d:       dsv.Dsv_Options,
		want:    string,
		dropped: tape.Facts,
	}
	cases := [?]Case{
		{"// head\n[{\"a\":1},{\"a\":2}\n// foot\n]", {}, "a\n1\n2\n", {.Comment, .Comment_Foot}},
		{"/* l1\nl2\r\nl3 */[{\"a\":1}]", {comment = '#'}, "# l1\n#l2\n#l3 \na\n1\n", {}},
		{"[{\"a\":1,\"b\":2},{\"a\":3,\"b\":4}]", {no_header = true}, "1,2\n3,4\n", {}},
		{"/* l1\nl2 */[{\"a\":1},{\"a\":\"x\\ny\"}]", {comment = '#', crlf = true}, "# l1\r\n#l2 \r\na\r\n1\r\n\"x\ny\"\r\n", {}},
	}
	for c in cases {
		doc, _ := json.build(transmute([]u8)c.src, .Jsonc)
		defer json.destroy(&doc)
		text, dropped, werr := dsv.write(&doc, .Csv, {format = c.d})
		defer delete(text)
		testing.expectf(t, werr == nil && string(text) == c.want && dropped == c.dropped, "%q: %q %v %v", c.src, text, dropped, werr)
	}
	// JSON5 numbers are cells of the same values as JSON writes them, past 64 bits and binary64 too.
	numbers := "[{\"a\": 0x10000000000000000, \"b\": +123456789012345678901234, \"c\": .123456789012345678901, \"d\": 5., \"e\": -0xff, \"f\": +.5e3}]"
	doc5, _ := json.build(transmute([]u8)numbers, .Json5)
	defer json.destroy(&doc5)
	cells, _, cerr := dsv.write(&doc5)
	defer delete(cells)
	as_json, _, jerr := json.write(&doc5, .Json)
	defer delete(as_json)
	testing.expectf(t, cerr == nil && string(cells) == "a,b,c,d,e,f\n18446744073709551616,123456789012345678901234,0.123456789012345678901,5.0,-255,0.5e3\n", "JSON5 numbers: %q %v", cells, cerr)
	testing.expectf(t, jerr == nil && string(as_json) == "[{\"a\":18446744073709551616,\"b\":123456789012345678901234,\"c\":0.123456789012345678901,\"d\":5.0,\"e\":-255,\"f\":0.5e3}]", "JSON5 numbers as JSON: %q %v", as_json, jerr)
	// Under `sort_keys` the columns go in the order of their names, a delimited table's and an array of objects'.
	for src in ([]string{"b,a,c\n1,2,3\n4,5,6\n", "[{\"b\":1,\"a\":2,\"c\":3},{\"c\":6,\"a\":5,\"b\":4}]"}) {
		sorted: tape.Document
		if src[0] == '[' {
			sorted, _ = json.build(transmute([]u8)src)
		} else {
			sorted, _ = dsv.build(transmute([]u8)src)
		}
		defer dsv.destroy(&sorted)
		text, _, serr := dsv.write(&sorted, .Csv, {sort_keys = true})
		defer delete(text)
		testing.expectf(t, serr == nil && string(text) == "a,b,c\n2,1,3\n5,4,6\n", "%q sorted: %q %v", src, text, serr)
	}
	header, _ := dsv.build(transmute([]u8)string("a,b\n"))
	defer dsv.destroy(&header)
	text, _, herr := dsv.write(&header, .Csv, {format = dsv.Dsv_Options{no_header = true}})
	defer delete(text)
	back, _ := dsv.build(text, .Csv, {format = dsv.Dsv_Options{no_header = true}})
	defer dsv.destroy(&back)
	testing.expectf(t, herr == nil && back.nodes[0].n == 1, "a header alone under no_header: %q %v", text, herr)
}

@(test)
table_bug_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// P16 Bug 1 (HIGH SEGFAULT): empty column-0 header with `comment != 0` and >= 2 columns.
	jdoc, jerr := json.build(transmute([]u8)string(`[{"":1,"b":2}]`))
	defer json.destroy(&jdoc)
	testing.expect_value(t, jerr, nil)
	jcsv, _, jwerr := dsv.write(&jdoc, .Csv, {format = dsv.Dsv_Options{comment = '#'}})
	defer delete(jcsv)
	testing.expectf(t, jwerr == nil && string(jcsv) == ",b\n1,2\n", "empty col-0 header json: %q %v", jcsv, jwerr)

	w: dsv.Writer
	testing.expect_value(t, dsv.writer_start(&w, .Csv, {header = {"", "b"}, format = dsv.Dsv_Options{comment = '#'}}), nil)
	testing.expect_value(t, dsv.token(&w, .Object), nil)
	testing.expect_value(t, dsv.token(&w, .Key, ""), nil)
	testing.expect_value(t, dsv.token(&w, .Number, "1"), nil)
	testing.expect_value(t, dsv.token(&w, .Key, "b"), nil)
	testing.expect_value(t, dsv.token(&w, .Number, "2"), nil)
	testing.expect_value(t, dsv.token(&w, .Close), nil)
	wcsv, wwerr := dsv.writer_end(&w)
	defer delete(wcsv)
	testing.expectf(t, wwerr == nil && string(wcsv) == ",b\n1,2\n", "empty col-0 header writer: %q %v", wcsv, wwerr)

	// P16 Bug 2 (HIGH OOB panic): `dsv.write(&csv_doc, .Csv, {node = row0})` on odd- and even-width Tabular_Ext rows.
	for c in ([?]struct{ src, want: string }{
		{"a,b,c\n1,2,3\n4,5,6\n", "a,b,c\n1,2,3\n"},
		{"a,b\n1,2\n3,4\n", "a,b\n1,2\n"},
	}) {
		cdoc, cerr := dsv.build(transmute([]u8)c.src, .Csv)
		defer dsv.destroy(&cdoc)
		testing.expect_value(t, cerr, nil)
		row0, p := dsv.element({&cdoc, nil}, dsv.ROOT, 0)
		testing.expect_value(t, p, tape.Presence.Found)
		out, _, werr := dsv.write(&cdoc, .Csv, {node = row0})
		defer delete(out)
		testing.expectf(t, werr == nil && string(out) == c.want, "single tabular row %q -> %q (%v)", c.src, out, werr)
	}

	// P16 Bug 3 (HIGH blank-line data loss): duplicate header collapsed to 1 column whose kept cell is `.Null`.
	for c in ([?]struct{ src: string, dups: tape.Duplicates }{
		{"a,a\n1,\n", .Last},
		{"a,a\n,1\n", .First},
	}) {
		cdoc, cerr := dsv.build(transmute([]u8)c.src, .Csv, {dups = c.dups})
		defer dsv.destroy(&cdoc)
		testing.expect_value(t, cerr, nil)
		out, _, werr := dsv.write(&cdoc, .Csv)
		delete(out)
		r, refused := werr.(write.Refused)
		testing.expectf(t, refused && r.why == .No_Spelling, "dup single null %q %v: %q %v", c.src, c.dups, out, werr)
	}

	// P16 Bug 4: `same_key` does not conflate `.Null` key with empty `.String` key.
	ydoc, yerr := yaml.build(transmute([]u8)string("- null: 1\n  \"\": 2\n"))
	defer yaml.destroy(&ydoc)
	testing.expect_value(t, yerr, nil)
	ycsv, _, ywerr := dsv.write(&ydoc, .Csv)
	defer delete(ycsv)
	testing.expectf(t, ywerr == nil && string(ycsv) == "null,\n1,2\n", "yaml null vs empty key: %q %v", ycsv, ywerr)

	// P16 Bug 6: `table_writer_start` rejects non-zero `opts.node`, `indent`, `ascii`, out-of-range `framing`.
	bad_w: dsv.Writer
	for tc in ([?]struct { opts: dsv.Write_Options, opt: string }{
		{{node = 1}, "node"}, {{indent = 2}, "indent"}, {{ascii = true}, "ascii"}, {{framing = write.Record_Framing(9)}, "framing"},
	}) {
		testing.expect_value(t, dsv.writer_start(&bad_w, .Csv, tc.opts), dsv.Write_Error(tape.Bad_Option{tc.opt}))
	}

	// P16 Bug 7: short ragged delimited rows under `sort_keys` and `dups = .Last`.
	for tc in ([?]struct { src, want: string, dups: tape.Duplicates, sort: bool }{
		{"b,a\n1\n", "a,b\n,1\n", .Default, true},
		{"a,b,a\n1,2\n", "b,a\n2,1\n", .Last, false},
	}) {
		rag, rerr := dsv.build(transmute([]u8)tc.src, .Csv, {dups = tc.dups, tolerate = {.Ragged}})
		defer dsv.destroy(&rag)
		testing.expect_value(t, rerr, nil)
		out, _, werr := dsv.write(&rag, .Csv, {sort_keys = tc.sort})
		defer delete(out)
		testing.expectf(t, werr == nil && string(out) == tc.want, "short ragged %q: %q %v", tc.src, out, werr)
	}

	// P16 Bug 5: `Table_Writer` OOM sweep across explicit header, streaming header, and `grow_header`.
	for mode in 0 ..< 3 {
		m := mode
		s := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
			mode := (^int)(data)^
			opts: dsv.Write_Options
			switch mode {
			case 0:
				opts = {header = {"a", "b"}}
			case 1:
				opts = {}
			case 2:
				opts = {grow_header = true}
			}
			tw: dsv.Writer
			if err := dsv.writer_start(&tw, .Csv, opts, {}, a); err != nil {
				_ = err.(runtime.Allocator_Error)
				return
			}
			for step in ([?]struct{ kind: write.Token_Kind, text: string }{
				{.Array, ""}, {.Object, ""}, {.Key, "a"}, {.String, "1"}, {.Key, "b"}, {.String, "2"}, {.Close, ""}, {.Close, ""},
			}) {
				if err := dsv.token(&tw, step.kind, step.text); err != nil {
					_ = err.(runtime.Allocator_Error)
					dsv.writer_drop(&tw)
					return
				}
			}
			out, eerr := dsv.writer_end(&tw)
			if eerr == nil {
				delete(out, a)
			} else {
				_ = eerr.(runtime.Allocator_Error)
			}
		}, &m)
		testing.expectf(t, s.bad == 0 && s.refused >= 1, "Table_Writer mode %d oom sweep: %v", mode, s)
	}
}
