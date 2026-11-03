package dsv_tests

import "base:runtime"
import "core:io"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import dsv ".."
import json "../../json"
import walktest "../../walktest"

// The typed write of a delimited text: the bytes of each spec, each cell rule and refusal, the layout options, and the
// read of what was written.

Write_Row :: struct {
	id:    i64,
	name:  string,
	ok:    bool,
	score: f64,
	small: u8,
	may:   Maybe(string),
	color: Cell_Color,
	note:  cstring,
}

expect_text :: proc(t: ^testing.T, value: any, spec: dsv.Spec, layout: dsv.Options, want: string, loc := #caller_location) {
	got, err := dsv.marshal(value, spec, layout, {}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None, loc)
	testing.expect_value(t, string(got), want, loc)
}

expect_refused :: proc(t: ^testing.T, value: any, spec: dsv.Spec, layout: dsv.Options, kind: core.Typed_Error_Kind, loc := #caller_location) -> core.Typed_Error {
	got, err := dsv.marshal(value, spec, layout, {}, context.temp_allocator)
	testing.expect_value(t, err.kind, kind, loc)
	testing.expect(t, got == nil, "a refusal returns no text", loc = loc)
	return err
}

@(test)
struct_rows_write_a_header_then_records :: proc(t: ^testing.T) {
	rows := []Write_Row{
		{id = 1, name = "a", ok = true, score = 1.5, small = 7, may = "m", color = .Blue, note = "n"},
		{id = -2, name = "", ok = false, score = 1e21, small = 0, color = .Red},
	}
	expect_text(t, rows, .Csv, {}, "id,name,ok,score,small,may,color,note\n1,a,true,1.5,7,m,Blue,n\n-2,\"\",false,1e+21,0,,Red,\n")
	expect_text(t, rows, .Csv, {no_header = true, crlf = true}, "1,a,true,1.5,7,m,Blue,n\r\n-2,\"\",false,1e+21,0,,Red,\r\n")
}

@(test)
sort_keys_orders_the_columns :: proc(t: ^testing.T) {
	Two :: struct {b, a: int}
	rows := []Two{{1, 2}}
	got, err := dsv.marshal(rows, .Csv, {}, {sort_keys = true}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), "a,b\n2,1\n")
}

@(test)
csv_quotes_what_needs_it :: proc(t: ^testing.T) {
	One :: struct {s: string}
	rows := []One{{"a,b"}, {"q\"q"}, {"l\nl"}, {"plain"}, {"\r"}, {" "}}
	expect_text(t, rows, .Csv, {no_header = true}, "\"a,b\"\n\"q\"\"q\"\n\"l\nl\"\nplain\n\"\r\"\n \n")
	long := strings.repeat("x,\"", 700, context.temp_allocator)
	got, err := dsv.marshal([]One{{long}}, .Csv, {no_header = true}, {}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, len(got), 2 + 700 * 4 + 1)
}

@(test)
tsv_escapes_and_plain_refuses :: proc(t: ^testing.T) {
	One :: struct {s: string}
	expect_text(t, []One{{"a\tb\nc\\d\x00"}}, .Tsv, {no_header = true}, "a\\tb\\nc\\\\d\\0\n")
	expect_text(t, []One{{"a\\b\x00"}}, .Plain, {no_header = true}, "a\\b\x00\n")
	expect_refused(t, []One{{"a,b"}}, .Plain, {}, .Unwritable)
	expect_refused(t, []One{{"a\nb"}}, .Plain, {}, .Unwritable)
	expect_refused(t, []One{{"a;b"}}, .Tsv, {delimiter = ';'}, .Unwritable)
	expect_text(t, []One{{"a\tb"}}, .Tsv, {no_header = true, delimiter = ';'}, "a\tb\n")
}

@(test)
empty_cells_follow_the_spec :: proc(t: ^testing.T) {
	Pair :: struct {a: string, b: string}
	Opt :: struct {s: Maybe(string)}
	expect_text(t, []Pair{{"", "x"}}, .Tsv, {no_header = true}, "\tx\n")
	expect_refused(t, []Opt{{""}}, .Tsv, {}, .Unwritable)
	expect_text(t, []Opt{{""}}, .Csv, {no_header = true}, "\"\"\n")
	err := expect_refused(t, []Opt{{}}, .Csv, {no_header = true}, .Unwritable)
	testing.expect_value(t, err.n_steps, u8(1))
}

@(test)
comment_and_bom_guards :: proc(t: ^testing.T) {
	One :: struct {s: string}
	expect_text(t, []One{{"#x"}}, .Csv, {no_header = true, comment = '#'}, "\"#x\"\n")
	expect_text(t, []One{{"a"}, {"#x"}}, .Csv, {no_header = true, comment = '#'}, "a\n\"#x\"\n")
	expect_text(t, []One{{"x#"}}, .Csv, {no_header = true, comment = '#'}, "x#\n")
	expect_refused(t, []One{{"#x"}}, .Plain, {comment = '#'}, .Unwritable)
	expect_text(t, []One{{"\tx"}}, .Tsv, {no_header = true, delimiter = ';', comment = '\t'}, "\\tx\n")
	expect_text(t, []One{{"\xEF\xBB\xBFx"}}, .Csv, {no_header = true}, "\"\xEF\xBB\xBFx\"\n")
	expect_refused(t, []One{{"\xEF\xBB\xBFx"}}, .Tsv, {no_header = true}, .Unwritable)
	expect_text(t, []One{{"a"}, {"\xEF\xBB\xBFx"}}, .Csv, {no_header = true}, "a\n\xEF\xBB\xBFx\n")
	Num :: struct {n: int}
	expect_text(t, []Num{{1}}, .Csv, {no_header = true, delimiter = '1'}, "\"1\"\n")
	expect_refused(t, []Num{{1}}, .Plain, {delimiter = '1'}, .Unwritable)
	expect_text(t, []Num{{12}}, .Csv, {no_header = true, comment = '1'}, "\"12\"\n")
}

@(test)
bad_layouts_and_values_are_refused :: proc(t: ^testing.T) {
	One :: struct {s: string}
	expect_refused(t, []One{}, .Csv, {delimiter = '"'}, .Bad_Option)
	expect_refused(t, []One{{"\xff"}}, .Csv, {}, .Bad_Utf8)
	Float :: struct {f: f64}
	expect_refused(t, []Float{{max(f64) * 2}}, .Csv, {}, .Non_Finite)
	expect_refused(t, [][][]int{}, .Csv, {}, .Unsupported)
	// A list of cells is one row.
	expect_text(t, []int{1, 2}, .Csv, {}, "1,2\n")
	Nested :: struct {a: []int}
	expect_refused(t, []Nested{}, .Csv, {}, .Unsupported)
	err := expect_refused(t, []Float{{1}, {max(f64) * 2}}, .Csv, {}, .Non_Finite)
	testing.expect_value(t, err.n_steps, u8(2))
	testing.expect_value(t, err.steps[0], core.Step(core.Index(1)))
	testing.expect_value(t, err.steps[1], core.Step(core.Name("f")))
}

@(test)
list_and_map_rows_write :: proc(t: ^testing.T) {
	expect_text(t, [][]int{{1, 2}, {3}}, .Csv, {}, "1,2\n3\n")
	rows := make([]map[string]int, 2, context.temp_allocator)
	rows[0] = make(map[string]int, context.temp_allocator)
	rows[1] = make(map[string]int, context.temp_allocator)
	rows[0]["b"], rows[0]["a"], rows[1]["c"] = 1, 2, 3
	expect_text(t, rows, .Csv, {}, "a,b,c\n2,1,\n,,3\n")
	empty := make([]map[string]string, 1, context.temp_allocator)
	empty[0] = make(map[string]string, context.temp_allocator)
	empty[0]["k"] = ""
	expect_refused(t, empty, .Tsv, {}, .Unwritable)
	expect_refused(t, [][]int{{}}, .Csv, {}, .Unwritable)
}

Hooked :: distinct i32

@(test)
hook_stand_ins_are_cells :: proc(t: ^testing.T) {
	Row :: struct {h: Hooked, s: Maybe(Hooked)}
	hooks := []typed.Type_Hook{{type = Hooked, write = proc(v: rawptr, _: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
		return (^i32)(v)^, .None
	}}}
	plan, err := dsv.plan_make([]Row, .Csv, {}, {hooks = hooks}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	defer typed.plan_destroy(&plan)
	rows := []Row{{h = 5, s = Hooked(6)}}
	got, werr := write.marshal(rows, &plan, {}, context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), "h,s\n5,6\n")
}

@(test)
stream_output_matches_buffer :: proc(t: ^testing.T) {
	Row :: struct {id: int, s: string}
	rows := make([]Row, 3000, context.temp_allocator)
	for &r, i in rows {
		r = {i, "a,b"}
	}
	want, _ := dsv.marshal(rows, .Csv, {}, {}, context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	plan, _ := dsv.plan_make([]Row, .Csv, allocator = context.temp_allocator)
	err := write.marshal_stream(strings.to_stream(&b), rows, &plan)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, strings.to_string(b), string(want))
}

// What was written reads back as the same rows, in every spec and with awkward text.
@(test)
written_text_reads_back :: proc(t: ^testing.T) {
	texts := []string{"plain", "a,b", "q\"q", "multi\nline", "tab\there", "back\\slash", " lead", "trail ", "#hash", "é日本", "x;y", "z"}
	rows := make([]Write_Row, len(texts), context.temp_allocator)
	for &r, i in rows {
		r = {id = i64(i) - 5, name = texts[i], ok = i % 2 == 0, score = f64(i) / 3, small = u8(i), may = texts[(i + 1) % len(texts)], color = .Green, note = "n"}
	}
	round_trip(t, rows, .Csv, {})
	round_trip(t, rows, .Csv, {delimiter = ';', comment = '#', crlf = true})
	round_trip(t, rows, .Tsv, {})
	round_trip(t, rows, .Tsv, {comment = '#'})
}

round_trip :: proc(t: ^testing.T, rows: []Write_Row, spec: dsv.Spec, layout: dsv.Options, loc := #caller_location) {
	text, err := dsv.marshal(rows, spec, layout, {}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None, loc)
	back: []Write_Row
	var_err: core.Typed_Error
	switch spec {
	case .Csv:
		var_err = dsv.unmarshal(text, .Csv, &back, {}, layout, context.temp_allocator)
	case .Tsv:
		var_err = dsv.unmarshal(text, .Tsv, &back, {}, layout, context.temp_allocator)
	case .Plain:
		var_err = dsv.unmarshal(text, .Plain, &back, {}, layout, context.temp_allocator)
	}
	testing.expect_value(t, var_err.kind, core.Typed_Error_Kind.None, loc)
	testing.expect_value(t, len(back), len(rows), loc)
	for r, i in rows {
		if i < len(back) {
			testing.expect_value(t, back[i].id, r.id, loc)
			testing.expect_value(t, back[i].name, r.name, loc)
			testing.expect_value(t, back[i].may, r.may, loc)
			testing.expect_value(t, back[i].score, r.score, loc)
		}
	}
}

@(test)
dsv_document_writes_in_its_spec :: proc(t: ^testing.T) {
	src := "# c\nid;name\n1;\"a;b\"\n2;\n"
	doc, err := dsv.build(transmute([]u8)src, .Csv, {delimiter = ';', comment = '#'}, false, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	got, _, werr := core.write(&doc, {}, allocator = context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), "id;name\n1;\"a;b\"\n2;\n")
	tsv, _, terr := core.write(&doc, {}, dsv.as(.Tsv), context.temp_allocator)
	testing.expect_value(t, terr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(tsv), "id\tname\n1\ta;b\n2\t\n")
}

@(test)
json_records_write_as_a_table :: proc(t: ^testing.T) {
	src := `[{"a":1,"b":"x,y"},{"b":null,"c":true,"a":2.50}]`
	doc, err := json.build(transmute([]u8)src, .Json, {}, false, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	got, _, werr := core.write(&doc, {}, dsv.as(.Csv), context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), "a,b,c\n1,\"x,y\",\n2.50,,true\n")
	rows := `[[1,"a"],[2,"b"]]`
	doc2, _ := json.build(transmute([]u8)rows, .Json, {}, false, context.temp_allocator)
	got, _, werr = core.write(&doc2, {}, dsv.as(.Tsv), context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(got), "1\ta\n2\tb\n")
	nested := `[{"a":[1]}]`
	doc3, _ := json.build(transmute([]u8)nested, .Json, {}, false, context.temp_allocator)
	_, _, werr = core.write(&doc3, {}, dsv.as(.Csv), context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.Unsupported)
	scalar := `[1]`
	doc4, _ := json.build(transmute([]u8)scalar, .Json, {}, false, context.temp_allocator)
	_, _, werr = core.write(&doc4, {}, dsv.as(.Csv), context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.Unsupported)
}

@(private)
Marshal_Try :: struct {
	value: any,
	opts:  core.Write_Options,
}

@(private)
marshal_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	m := (^Marshal_Try)(data)
	text, err := dsv.marshal(m.value, .Csv, {}, m.opts, allocator)
	return text, err.kind
}

Sweep_Row :: struct {
	id:   int,
	name: string,
}

@(test)
marshal_under_failing_allocators :: proc(t: ^testing.T) {
	rows := []Sweep_Row{{1, "a"}, {2, "b,c"}}
	first := make(map[string]string, context.temp_allocator)
	first["x"], first["y"] = "1", "2"
	second := make(map[string]string, context.temp_allocator)
	second["z"] = "3"
	keyed := []map[string]string{first, second}
	for c in ([?]Marshal_Try{{rows, {}}, {rows, {sort_keys = true}}, {keyed, {}}}) {
		c := c
		want, err := dsv.marshal(c.value, .Csv, {}, c.opts, context.temp_allocator)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		walktest.sweep_write(t, marshal_try, &c, string(want))
	}
}

@(private)
document_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	text, _, err := core.write((^core.Document)(data), {}, dsv.as(.Csv), allocator)
	return text, err.kind
}

@(test)
document_under_failing_allocators :: proc(t: ^testing.T) {
	long := strings.repeat("k", 600, context.temp_allocator)
	headed, herr := dsv.build(transmute([]u8)string("a,b\n1,\"x y\"\n2,3\n"), .Csv)
	defer core.destroy(&headed)
	testing.expect_value(t, herr.kind, core.Document_Error_Kind.None)
	src := strings.concatenate({`[{"`, long, `":1,"b":"`, long, `"},{"c":null}]`}, context.temp_allocator)
	foreign_doc, ferr := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&foreign_doc)
	testing.expect_value(t, ferr.kind, core.Document_Error_Kind.None)
	for doc in ([?]^core.Document{&headed, &foreign_doc}) {
		want, _, err := core.write(doc, {}, dsv.as(.Csv), context.temp_allocator)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
		walktest.sweep_write(t, document_try, doc, string(want))
	}
}

// A write that succeeds leaves nothing on the temporary allocator, which a caller may never free.
@(test)
write_keeps_off_the_temporary_allocator :: proc(t: ^testing.T) {
	rows := []Sweep_Row{{1, "a"}}
	f := walktest.Failing_Alloc{inner = context.temp_allocator, fail_at = -1}
	context.temp_allocator = walktest.failing_allocator(&f)
	text, err := dsv.marshal(rows, allocator = context.allocator)
	defer delete(text)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	doc, derr := json.build(transmute([]u8)string(`[{"a":1}]`), .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, derr.kind, core.Document_Error_Kind.None)
	again, _, werr := core.write(&doc, as = dsv.as(.Csv))
	defer delete(again)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, f.n, 0)
}

// A headed text with no record keeps its header through `core.write`, and an empty table of no header stays empty.
@(test)
write_document_header_alone :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("a,b\n"), .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	text, _, werr := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "a,b\n")
	bare, berr := dsv.build(transmute([]u8)string("a,b\n"), .Csv, {no_header = true})
	defer core.destroy(&bare)
	testing.expect_value(t, berr.kind, core.Document_Error_Kind.None)
	again, _, aerr := core.write(&bare)
	defer delete(again)
	testing.expect_value(t, aerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(again), "a,b\n")
}

// An empty column name alone in a header would be a blank line where a spec has no spelling for it, and the first record
// would read as the header.
@(test)
header_of_one_empty_name :: proc(t: ^testing.T) {
	row := make(map[string]string, context.temp_allocator)
	row[""] = "x"
	rows := []map[string]string{row}
	for spec in ([?]dsv.Spec{.Tsv, .Plain}) {
		_, err := dsv.marshal(rows, spec, {}, {}, context.temp_allocator)
		testing.expect_value(t, err.kind, core.Typed_Error_Kind.Unwritable)
	}
	text, err := dsv.marshal(rows, .Csv, {}, {}, context.temp_allocator)
	testing.expect_value(t, err.kind, core.Typed_Error_Kind.None)
	doc, derr := dsv.build(text, .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, derr.kind, core.Document_Error_Kind.None)
	testing.expect_value(t, core.length(&doc, core.ROOT), 1)
}

// A repeated key keeps its last value, and each earlier one counts as dropped.
@(test)
repeated_key_counts_as_dropped :: proc(t: ^testing.T) {
	doc, err := json.build(transmute([]u8)string(`[{"a":1,"a":2,"a":3,"b":4},{"a":5}]`), .Json)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	text, dropped, werr := core.write(&doc, as = dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "a,b\n3,4\n5,\n")
	testing.expect_value(t, dropped, 2)
}

// A write of a document keeps the line end its text was read with.
@(test)
write_document_keeps_crlf :: proc(t: ^testing.T) {
	for src in ([?]string{"a,b\r\n1,2\r\n", "a,b\n1,2\n", "a,b\r\n"}) {
		doc, err := dsv.build(transmute([]u8)src, .Csv)
		defer core.destroy(&doc)
		testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
		text, _, werr := core.write(&doc)
		defer delete(text)
		testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
		testing.expect_value(t, string(text), src)
	}
	doc, err := dsv.build(transmute([]u8)string("1,2\r\n"), .Csv, {no_header = true})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	text, _, werr := core.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(text), "1,2\r\n")
}

// A write that fails counts nothing, whether the document refuses or the stream does.
@(test)
failed_write_counts_nothing :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("# c\na\n1\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	nested, nerr := json.build(transmute([]u8)string("[/* c */ {\"a\":[1]}]"), .Jsonc)
	defer core.destroy(&nested)
	testing.expect_value(t, nerr.kind, core.Document_Error_Kind.None)
	_, dropped, werr := core.write(&nested, as = dsv.as(.Csv), allocator = context.temp_allocator)
	testing.expect_value(t, werr.kind, core.Typed_Error_Kind.Unsupported)
	testing.expect_value(t, dropped, 0)
	counted, kept, kerr := core.write(&doc, allocator = context.temp_allocator)
	testing.expect_value(t, kerr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, string(counted), "a\n1\n")
	testing.expect_value(t, kept, 1)
	closed := io.Stream{procedure = refusing_stream}
	lost, serr := core.write_stream(closed, &doc)
	testing.expect_value(t, serr.kind, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, lost, 0)
}

@(private)
refusing_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	return 0, .Permission_Denied if mode == .Write else .Unknown
}

// `core.write_stream` gives the bytes of the text in memory, in the read spec and in another.
@(test)
document_streams :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("a,b\n1,\"x,y\"\n"), .Csv)
	defer core.destroy(&doc)
	testing.expect_value(t, err.kind, core.Document_Error_Kind.None)
	b := strings.builder_make(context.temp_allocator)
	_, serr := core.write_stream(strings.to_stream(&b), &doc)
	testing.expect_value(t, serr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, strings.to_string(b), "a,b\n1,\"x,y\"\n")
	strings.builder_reset(&b)
	_, derr := core.write_stream(strings.to_stream(&b), &doc, as = dsv.as(.Tsv))
	testing.expect_value(t, derr.kind, core.Typed_Error_Kind.None)
	testing.expect_value(t, strings.to_string(b), "a\tb\n1\tx,y\n")
}

// A cell that ends at an unmapped page is written as it is when it is copied elsewhere: no read passes its last byte.
@(test)
cells_at_the_end_of_a_page :: proc(t: ^testing.T) {
	fence := walktest.fence_init()
	defer walktest.unfence(&fence)
	for stop in ([?]u8{'a', ',', '"', '\t', '\\', 0xC3, '\n'}) {
		for n in 0 ..< 70 {
			body := make([]u8, n, context.temp_allocator)
			for &b, i in body {
				b = 'a'
				if stop != 'a' && i % 17 == 16 {
					b = stop
				}
			}
			if stop == 0xC3 && n > 0 {
				body[n - 1] = 0xA9
				if n > 1 {
					body[n - 2] = 0xC3
				}
			}
			fenced := string(walktest.fence_copy(&fence, body))
			plain := strings.clone(string(body), context.temp_allocator)
			for spec in ([?]dsv.Spec{.Csv, .Tsv, .Plain}) {
				want, werr := dsv.marshal([][]string{{plain}}, spec, {}, {}, context.temp_allocator)
				got, gerr := dsv.marshal([][]string{{fenced}}, spec, {}, {}, context.temp_allocator)
				testing.expect_value(t, gerr.kind, werr.kind)
				testing.expect_value(t, string(got), string(want))
			}
			free_all(context.temp_allocator)
		}
	}
}
