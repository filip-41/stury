package core_test

import "core:fmt"
import "core:strings"
import "core:io"
import "core:testing"
import core ".."
import typed "../typed"
import records "../records"
import dsv "../../dsv"
import json "../../json"
import model "../model"
import walktest "../../walktest"

@(private = "file")
Row :: struct {
	id:   int,
	name: string `model:"len>=2"`,
	age:  u8 `model:">=18"`,
	note: Maybe(string) `model:"optional"`,
}

// The codes and paths of a sink, one per line.
spelled :: proc(s: ^typed.Sink) -> string {
	b: strings.Builder
	for e in s.entries {
		fmt.sbprintf(&b, "%v", e.kind)
		if m, custom := e.operand.(string); custom && e.kind == .Custom {
			fmt.sbprintf(&b, "(%s)", m)
		}
		for st in e.path {
			switch x in st {
			case core.Name:
				fmt.sbprintf(&b, "/%s", string(x))
			case core.Index:
				fmt.sbprintf(&b, "/%d", int(x))
			case core.All, core.Slice, core.Descend, core.Index_Or_Name:
				fmt.sbprint(&b, "/*")
			}
		}
		fmt.sbprint(&b, ";")
	}
	return strings.to_string(b)
}

@(private = "file")
loaded :: proc(t: ^testing.T, checks: typed.Format_Checks, text: string, extra: Maybe(model.Extra) = nil) -> (out: string, rows: []Row, err: core.Error) {
	reg: model.Registry
	if x, ok := extra.?; ok {
		_ = model.register_extra(&reg, Row, x)
	}
	m, e := model.compile(&reg, []Row, checks)
	walktest.expect_nil(t, e)
	sink: typed.Sink
	err = model.load(&m, transmute([]u8)text, &rows, &sink)
	return spelled(&sink), rows, err
}

@(test)
csv_model_agrees_with_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	csv, _, _ := loaded(t, dsv.checks(.Csv), "id,name,age\n1,ada,30\n2,b,10\nx,cy,20\n")
	js, _, _ := loaded(t, json.checks(.Json), `[{"id":1,"name":"ada","age":30},{"id":2,"name":"b","age":10},{"id":"x","name":"cy","age":20}]`)
	testing.expect_value(t, csv, js)
	testing.expect_value(t, csv, "Too_Short/1/name;Below_Minimum/1/age;Wrong_Kind/2/id;")
}

// An empty cell is null and a quoted `""` the empty string, as JSON spells them.
@(test)
csv_model_empty_cell_is_null :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	text := "id,name,age,note\n1,ada,30,\n2,bo,40,\"\"\n3,,50,x\n"
	csv, rows, _ := loaded(t, dsv.checks(.Csv), text)
	testing.expect_value(t, csv, "Wrong_Kind/2/name;")
	testing.expect_value(t, len(rows), 3)
	testing.expect(t, rows[0].note == nil && rows[1].note.? == "")
	js, _, _ := loaded(t, json.checks(.Json), `[{"id":1,"name":"ada","age":30,"note":null},{"id":2,"name":"bo","age":40,"note":""},{"id":3,"name":null,"age":50,"note":"x"}]`)
	testing.expect_value(t, csv, js)
}

@(test)
csv_model_header_judged_once :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	out, _, _ := loaded(t, dsv.checks(.Csv), "id,name\n1,ada\n2,bob\n")
	testing.expect_value(t, out, "Missing_Field/age;")
	out, _, _ = loaded(t, dsv.checks(.Csv), "id,name,age,zip\n1,ada,30,x\n2,bob,40,y\n", .Forbid)
	testing.expect_value(t, out, "Not_Allowed/zip;")
	out, _, _ = loaded(t, dsv.checks(.Csv), "id,name,age,zip\n1,ada,30,x\n2,b,40,y\n")
	testing.expect_value(t, out, "Too_Short/1/name;")
}

@(test)
tsv_model_agrees_with_csv :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	tsv, _, _ := loaded(t, dsv.checks(.Tsv), "id\tname\tage\n1\tada\t30\n2\tb\t10\n")
	testing.expect_value(t, tsv, "Too_Short/1/name;Below_Minimum/1/age;")
}

@(test)
csv_model_single_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	sink: typed.Sink
	row: Row
	err := model.load(&m, transmute([]u8)string("id,name,age\n1,ada,30\n"), &row, &sink)
	walktest.expect_nil(t, err)
	testing.expect_value(t, row.name, "ada")
	testing.expect_value(t, len(sink.entries), 0)
	sink2: typed.Sink
	_ = model.load(&m, transmute([]u8)string("id,name,age\n1,ada,30\n2,bob,40\n"), &row, &sink2)
	testing.expect(t, len(sink2.entries) > 0 || true)
	testing.expect_value(t, spelled(&sink2) != "", true)
}

@(test)
model_loads_a_built_value_as_its_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, json.checks(.Json))
	walktest.expect_nil(t, e)
	doc, err := core.build(transmute([]u8)string(`{"id":1,"name":"a","age":10}`), json.as(.Json))
	walktest.expect_nil(t, err)
	sink: typed.Sink
	row: Row
	_ = model.load_value(&m, core.built_value(core.Node_Ref{&doc, core.ROOT}), &row, &sink)
	testing.expect_value(t, spelled(&sink), "Too_Short/name;Below_Minimum/age;")
	testing.expect_value(t, row.id, 1)
}

@(test)
csv_model_without_a_header_binds_by_position :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	by_position := dsv.checks(.Csv, {no_header = true})
	out, rows, _ := loaded(t, by_position, "1,ada,30\n2,b,10\nx,cy,20\n")
	testing.expect_value(t, out, "Too_Short/1/name;Below_Minimum/1/age;Wrong_Kind/2/id;")
	testing.expect_value(t, rows[0].name, "ada")
	out, _, _ = loaded(t, by_position, "1,ada\n")
	testing.expect_value(t, out, "Missing_Field/0/age;")
}

@(test)
csv_model_of_rows_that_are_no_structs_reads_plainly :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, [][]string, dsv.checks(.Csv, {no_header = true}))
	walktest.expect_nil(t, e)
	sink: typed.Sink
	rows: [][]string
	err := model.load(&m, transmute([]u8)string("a,b\nc,d\n"), &rows, &sink)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(sink.entries), 0)
	testing.expect_value(t, rows[1][1], "d")
	numbers_model, ne := model.compile(&reg, [][]int, dsv.checks(.Csv, {no_header = true}))
	walktest.expect_nil(t, ne)
	numbers: [][]int
	sink2: typed.Sink
	_ = model.load(&numbers_model, transmute([]u8)string("1,2\n3,x\n"), &numbers, &sink2)
	testing.expect_value(t, spelled(&sink2), "Wrong_Kind/1/1;")
	sink3: typed.Sink
	whole: [][]int
	_ = model.load(&numbers_model, transmute([]u8)string("1,2\n3,4\n"), &whole, &sink3)
	testing.expect_value(t, len(sink3.entries), 0)
	testing.expect_value(t, whole[1][0], 3)
}


// The offsets of a sink's entries, one per entry.
offsets :: proc(s: ^typed.Sink) -> string {
	b: strings.Builder
	for e in s.entries {
		fmt.sbprintf(&b, "%d-%d,", e.start, e.end)
	}
	return strings.to_string(b)
}

// Reads `text` record by record through `model.read` and returns the sink, and how many records there were.
reading :: proc(t: ^testing.T, m: ^model.Model($T), reader: records.Reader, sink: ^typed.Sink) -> (n: int) {
	it := reader
	defer records.close(&it)
	for {
		row: T
		_, more := model.read(&it, m, &row, sink)
		if !more {
			return
		}
		n += 1
	}
}

@(test)
model_reads_records_as_a_whole_text_loads :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	text := "id,name,age,note\n1,ada,30,\n2,b,10,x\nx,cy,20,\n"
	spec := dsv.Spec.Csv
	sink: typed.Sink
	testing.expect_value(t, reading(t, &m, dsv.records_open(transmute([]u8)text, spec), &sink), 3)
	testing.expect_value(t, spelled(&sink), "Too_Short/name;Below_Minimum/age;Wrong_Kind/id;")
	whole: typed.Sink
	whole_model, _ := model.compile(&reg, []Row, dsv.checks(.Csv))
	listed: []Row
	_ = model.load(&whole_model, transmute([]u8)text, &listed, &whole)
	testing.expect_value(t, offsets(&sink), offsets(&whole))
	streamed: typed.Sink
	reader := strings.Reader{}
	strings.reader_init(&reader, text)
	testing.expect_value(t, reading(t, &m, dsv.records_open_stream(strings.reader_to_stream(&reader), spec), &streamed), 3)
	testing.expect_value(t, spelled(&streamed), spelled(&sink))
	testing.expect_value(t, offsets(&streamed), offsets(&sink))
}

@(test)
model_reads_records_opened_with_a_constant_spec :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	text := "id,name,age,note\n1,ada,30,\n2,b,10,x\n"
	sink: typed.Sink
	testing.expect_value(t, reading(t, &m, dsv.records_open(transmute([]u8)text, .Csv), &sink), 2)
	testing.expect_value(t, spelled(&sink), "Too_Short/name;Below_Minimum/age;")
}

@(test)
model_reports_the_header_of_a_table_with_no_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	text := "id,name\n"
	spec := dsv.Spec.Csv
	whole: typed.Sink
	whole_model, _ := model.compile(&reg, []Row, dsv.checks(.Csv))
	listed: []Row
	_ = model.load(&whole_model, transmute([]u8)text, &listed, &whole)
	testing.expect_value(t, spelled(&whole), "Missing_Field/age;")
	sink: typed.Sink
	testing.expect_value(t, reading(t, &m, dsv.records_open(transmute([]u8)text, spec), &sink), 1)
	testing.expect_value(t, spelled(&sink), "Missing_Field/age;")
}

@(test)
model_stops_at_a_header_that_lacks_a_required_column :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	text := "id,name\n1,ada\n2,bo\n3,cy\n"
	sink: typed.Sink
	testing.expect_value(t, reading(t, &m, dsv.records_open(transmute([]u8)text, .Csv), &sink), 1)
	testing.expect_value(t, spelled(&sink), "Missing_Field/age;")
}

@(test)
model_reads_ndjson_records_whole_or_streamed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Row, json.checks(.Json))
	walktest.expect_nil(t, e)
	text := `{"id":1,"name":"ada","age":30}` + "\n" + `{"id":2,"name":"b","age":10}` + "\n" + `{"id":"x","name":"cy","age":20}` + "\n"
	spec := json.Spec.Json
	whole: typed.Sink
	testing.expect_value(t, reading(t, &m, json.records_open(transmute([]u8)text, spec), &whole), 3)
	testing.expect_value(t, spelled(&whole), "Too_Short/name;Below_Minimum/age;Wrong_Kind/id;")
	streamed: typed.Sink
	reader := strings.Reader{}
	strings.reader_init(&reader, text)
	testing.expect_value(t, reading(t, &m, json.records_open_stream(strings.reader_to_stream(&reader), spec), &streamed), 3)
	testing.expect_value(t, spelled(&streamed), spelled(&whole))
	testing.expect_value(t, offsets(&streamed), offsets(&whole))
}

@(private = "file")
Law :: struct {
	f: f64 `model:"<=0.1"`,
	g: f32,
	i: i8,
	u: u8,
	n: int `model:">=0"`,
	e: string `model:"format=email"`,
	d: string `model:"format=date-time"`,
	o: string `model:"optional,len>=1"`,
	q: string `model:"len<=1"`,
}

// A cell of a row of `Law`: its column, its text as CSV spells it, and as JSON spells it.
@(private = "file")
Cell :: struct {
	column, csv, json: string,
}

@(private = "file")
LAW_BASE := [?]Cell{{"f", "0.1", "0.1"}, {"g", "1.5", "1.5"}, {"i", "7", "7"}, {"u", "7", "7"}, {"n", "3", "3"}, {"e", "a@b.c", `"a@b.c"`}, {"d", "2020-01-01T00:00:00Z", `"2020-01-01T00:00:00Z"`}, {"q", "x", `"x"`}}

// Loads one row of `Law` with `change` in place of its column, as a CSV text and as a JSON array, and returns what each
// collected.
@(private = "file")
law_row :: proc(t: ^testing.T, m: ^model.Model([]Law), json_m: ^model.Model([]Law), change: Cell, drop := false) -> (csv, js: string) {
	head, row, obj: strings.Builder
	strings.write_string(&obj, "[{")
	for base, k in LAW_BASE {
		cell := change if change.column == base.column else base
		if k > 0 {
			strings.write_byte(&head, ',')
			strings.write_byte(&row, ',')
			strings.write_byte(&obj, ',')
		}
		strings.write_string(&head, base.column)
		strings.write_string(&row, cell.csv)
		fmt.sbprintf(&obj, `"%s":%s`, base.column, cell.json)
	}
	strings.write_string(&obj, "}]")
	text := fmt.tprintf("%s\n%s\n", strings.to_string(head), strings.to_string(row))
	sink: typed.Sink
	rows: []Law
	_ = model.load(m, transmute([]u8)text, &rows, &sink)
	csv = spelled(&sink)
	sink2: typed.Sink
	rows2: []Law
	_ = model.load(json_m, transmute([]u8)strings.to_string(obj), &rows2, &sink2)
	return csv, spelled(&sink2)
}

@(test)
csv_and_json_collect_the_same_codes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	csv_m, e1 := model.compile(&reg, []Law, dsv.checks(.Csv))
	json_m, e2 := model.compile(&reg, []Law, json.checks(.Json))
	walktest.expect_nil(t, e1)
	walktest.expect_nil(t, e2)
	cases := [?]Cell{
		{"f", "0.10000000000000000001", "0.10000000000000000001"},
		{"f", "0.1000000000000001", "0.1000000000000001"},
		{"f", "1e-1", "1e-1"},
		{"f", "x", `"x"`},
		{"g", "1e39", "1e39"},
		{"g", "-1e39", "-1e39"},
		{"g", "0.1", "0.1"},
		{"i", "127", "127"},
		{"i", "128", "128"},
		{"i", "-129", "-129"},
		{"i", "1.5", "1.5"},
		{"i", "1e2", "1e2"},
		{"i", "1.0", "1.0"},
		{"u", "2e1", "2e1"},
		{"n", "1e30", "1e30"},
		{"e", `""`, `""`},
		{"u", "-1", "-1"},
		{"u", "256", "256"},
		{"n", "-1", "-1"},
		{"n", "9223372036854775808", "9223372036854775808"},
		{"n", "x", `"x"`},
		{"e", "a b@c", `"a b@c"`},
		{"e", "a..b@c", `"a..b@c"`},
		{"e", "a@b", `"a@b"`},
		{"d", "2020-01-01 00:00:00Z", `"2020-01-01 00:00:00Z"`},
		{"d", "2016-12-31T23:59:60Z", `"2016-12-31T23:59:60Z"`},
		{"d", "2020-02-30T00:00:00Z", `"2020-02-30T00:00:00Z"`},
		{"d", "2020-01-01T00:00:00+24:00", `"2020-01-01T00:00:00+24:00"`},
		{"q", `""""`, `"\""`},
		{"q", `"xx"""`, `"xx\""`},
	}
	for c in cases {
		csv, js := law_row(t, &csv_m, &json_m, c)
		testing.expectf(t, csv == js, "%s=%q: csv %q, json %q", c.column, c.csv, csv, js)
	}
}

// A string that holds a quote, which a CSV text doubles, is dumped and loaded back as it was.
@(test)
csv_model_round_trips_a_quote :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, e := model.compile(nil, []Patch_Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	rows := []Patch_Row{{id = 1, name = `say "hi"`}}
	text, err := model.dump(&m, &rows)
	walktest.expect_nil(t, err)
	back: []Patch_Row
	walktest.expect_nil(t, model.load(&m, text, &back))
	testing.expect(t, len(back) == 1 && back[0].name == `say "hi"` && model.was_set(&m, Patch_Row, back[0].set, "name"))
}

@(test)
csv_empty_cell_is_judged_as_json_null :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	csv_m, _ := model.compile(&reg, []Law, dsv.checks(.Csv))
	json_m, _ := model.compile(&reg, []Law, json.checks(.Json))
	csv, js := law_row(t, &csv_m, &json_m, {"n", "", "null"})
	testing.expect_value(t, csv, "Wrong_Kind/0/n;")
	testing.expect_value(t, csv, js)
	csv, js = law_row(t, &csv_m, &json_m, {"o", "", "null"})
	testing.expect_value(t, csv, "")
	testing.expect_value(t, csv, js)
}

@(private = "file")
Keyed :: struct {
	by: map[i8]int,
}

// A key the map's key type does not hold fails the object's member names, as its schema's `propertyNames` does.
@(test)
json_map_keys_out_of_range_refuse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	m, e := model.compile(&reg, Keyed, json.checks(.Json))
	walktest.expect_nil(t, e)
	sink: typed.Sink
	v: Keyed
	_ = model.load(&m, transmute([]u8)string(`{"by":{"1":1,"300":2,"x":3}}`), &v, &sink)
	testing.expect_value(t, spelled(&sink), "No_Match/by;No_Match/by;")
}

@(test)
csv_model_reads_map_rows_and_plain_elements :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	maps, e := model.compile(&reg, []map[string]int, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	rows: []map[string]int
	sink: typed.Sink
	_ = model.load(&maps, transmute([]u8)string("a,b\n1,2\n3,x\n"), &rows, &sink)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, rows[0]["b"], 2)
	testing.expect_value(t, spelled(&sink), "Wrong_Kind/1/b;")
	flags, fe := model.compile(&reg, [][]bool, dsv.checks(.Csv, {no_header = true}))
	walktest.expect_nil(t, fe)
	bools: [][]bool
	sink2: typed.Sink
	_ = model.load(&flags, transmute([]u8)string("true,x\n"), &bools, &sink2)
	testing.expect_value(t, spelled(&sink2), "Wrong_Kind/0/1;")
	testing.expect_value(t, bools[0][0], true)
	whole, we := model.compile(&reg, [][]int, dsv.checks(.Csv, {no_header = true}))
	walktest.expect_nil(t, we)
	ints: [][]int
	sink3: typed.Sink
	_ = model.load(&whole, transmute([]u8)string("1.0,2e1\n"), &ints, &sink3)
	testing.expect_value(t, spelled(&sink3), "")
	testing.expect_value(t, ints[0][1], 20)
	maybe, me := model.compile(&reg, []struct{ mb: Maybe(int) }, dsv.checks(.Csv))
	walktest.expect_nil(t, me)
	mrows: []struct{ mb: Maybe(int) }
	sink4: typed.Sink
	_ = model.load(&maybe, transmute([]u8)string("mb\n1.0\n"), &mrows, &sink4)
	testing.expect_value(t, spelled(&sink4), "")
	testing.expect_value(t, mrows[0].mb, 1)
}

// A reader that hands out `step` bytes a call, so a stream's window is short.
@(private = "file")
Drip :: struct {
	text: string,
	at:   int,
	step: int,
}

@(private = "file")
drip_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	d := (^Drip)(data)
	if mode != .Read {
		return 0, .Empty
	}
	if d.at >= len(d.text) {
		return 0, .EOF
	}
	k := copy(p[:min(len(p), d.step)], d.text[d.at:])
	d.at += k
	return i64(k), nil
}

@(test)
csv_model_judges_the_header_once_whole_or_streamed :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	spec := dsv.Spec.Csv
	reg: model.Registry
	m, e := model.compile(&reg, Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	texts := [?]string{"id,name,age,name\n1,ada,30,bo\n", "id,name\n1,ada\n2,bob\n", "id,name,age,zip\n1,ada,30,x\n2,b,40,y\n", "id,name\n", "id,name,age,name\n"}
	for text in texts {
		whole: typed.Sink
		reading(t, &m, dsv.records_open(transmute([]u8)text, spec), &whole)
		if text == texts[0] {
			testing.expect_value(t, spelled(&whole), "Duplicate_Key/name;")
		}
		for step in ([?]int{1, 3, 7}) {
			d := Drip{text, 0, step}
			streamed: typed.Sink
			reading(t, &m, dsv.records_open_stream(io.Stream{drip_proc, &d}, spec), &streamed)
			testing.expectf(t, spelled(&streamed) == spelled(&whole), "step %d, %q: %q, want %q", step, text, spelled(&streamed), spelled(&whole))
		}
	}
}

@(test)
csv_model_forbids_a_cell_past_the_last_column_of_a_headerless_row :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	by_position := dsv.checks(.Csv, {no_header = true})
	out, _, _ := loaded(t, by_position, "1,ada,30,n,EXTRA\n", extra = model.Extra.Forbid)
	testing.expect_value(t, out, "Wrong_Length/0/note;")
	out, _, _ = loaded(t, by_position, "1,ada,30,n,EXTRA\n")
	testing.expect_value(t, out, "")
}

@(private = "file")
Patch_Row :: struct {
	id:   int,
	name: string `model:"len>=2"`,
	set:  model.Fields_Set,
}

// A patch of a record keeps a member whose column the header lacks and reads an empty cell as null, and a table, whose
// rows hold no set, takes no patch.
@(test)
csv_model_patch_of_a_record_misses_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, e := model.compile(nil, Patch_Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	row := Patch_Row{id = 4}
	walktest.expect_nil(t, model.patch(&m, &row, transmute([]u8)string("name\nada\n")))
	testing.expect(t, row.name == "ada" && row.id == 4 && !model.was_set(&m, Patch_Row, row.set, "id"))
	refused, is_typed := model.patch(&m, &row, transmute([]u8)string("id,name\n,bo\n")).(core.Typed_Error)
	testing.expect(t, is_typed && refused.kind == .Wrong_Kind)
	testing.expect(t, row.name == "ada" && row.id == 4)
	table, _ := model.compile(nil, []Patch_Row, dsv.checks(.Csv))
	rows: []Patch_Row
	testing.expect(t, model.patch(&table, &rows, transmute([]u8)string("name\nada\n")) != nil)
}

@(private = "file")
Law_Row :: struct {
	id:   int,
	kind: Maybe(string),
	role: string `model:"optional"`,
	n:    int `model:"optional"`,
	note: Maybe(string) `model:"optional"`,
	set:  model.Fields_Set,
}

// Every dump of a valid value loads back, under every option and in every format: an option leaves out only a member a
// load does not require, and a CSV or TSV row, whose empty cell reads back as null, keeps every other member's value.
@(test)
model_dump_under_every_option_loads_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	reg: model.Registry
	model.register(&reg, Law_Row, "role", "member")
	model.register(&reg, Law_Row, "n", 7)
	formats := [?]typed.Format_Checks{json.checks(.Json), dsv.checks(.Csv), dsv.checks(.Tsv)}
	names := [?]string{"JSON", "CSV", "TSV"}
	for checks, f in formats {
		m, e := model.compile(&reg, []Law_Row, checks)
		walktest.expect_nil(t, e)
		source := []Law_Row{{id = 9, kind = "k", role = "boss", n = 3}}
		source_text, _ := model.dump(&m, &source)
		loaded_rows: []Law_Row
		walktest.expect_nil(t, model.load(&m, source_text, &loaded_rows))
		values := [?][]Law_Row{{{id = 1, role = "member", n = 7}, {id = 2, kind = "k", role = "boss", n = 3, note = "x"}}, loaded_rows}
		for &rows in values {
			plain, _ := model.dump(&m, &rows)
			for bits in 0 ..< 8 {
				opts := model.Dump_Opts{exclude_unset = bits & 1 != 0, exclude_none = bits & 2 != 0, exclude_defaults = bits & 4 != 0}
				text, err := model.dump(&m, &rows, opts)
				walktest.expect_nil(t, err)
				back: []Law_Row
				if !testing.expectf(t, model.load(&m, text, &back) == nil, "%v under %v does not load back: %s", names[f], opts, text) {
					continue
				}
				if !opts.exclude_unset {
					again, _ := model.dump(&m, &back)
					testing.expectf(t, string(again) == string(plain), "%v under %v loads back as %s", names[f], opts, again)
				}
			}
		}
	}
}

Strict_Row :: struct {
	id:   int,
	note: Maybe(string) `model:"not_null"`,
}

// A member that refuses null compiles for a row, and its empty cell is the null it refuses.
@(test)
csv_model_refuses_an_empty_cell_where_null_is_refused :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	m, e := model.compile(nil, []Strict_Row, dsv.checks(.Csv))
	walktest.expect_nil(t, e)
	sink: typed.Sink
	rows: []Strict_Row
	_ = model.load(&m, transmute([]u8)string("id,note\n1,x\n2,\n"), &rows, &sink)
	testing.expect_value(t, spelled(&sink), "Wrong_Kind/1/note;")
}
