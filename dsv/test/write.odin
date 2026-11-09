package dsv_tests

import "base:runtime"
import "core:io"
import "core:strings"
import "core:testing"
import core "../../core"
import typed "../../core/typed"
import write "../../core/write"
import records "../../core/records"
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

One :: struct {
	s: string,
}

Num :: struct {
	n: int,
}

Opt :: struct {
	s: Maybe(string),
}

Float :: struct {
	f: f64,
}

Write_Case :: struct {
	value:  any,
	spec:   dsv.Spec,
	layout: dsv.Options,
	want:   string,
	kind:   core.Typed_Error_Kind, // a refusal, which returns no text
}

expect_writes :: proc(t: ^testing.T, cases: []Write_Case, loc := #caller_location) {
	for c in cases {
		got, err := dsv.marshal(c.value, c.spec, c.layout, write = {}, allocator = context.temp_allocator)
		testing.expectf(t, walktest.typed_kind(err) == c.kind && string(got) == c.want, "%v %v %v: %v %q, want %v %q", c.value, c.spec, c.layout, err, got, c.kind, c.want, loc = loc)
	}
}

// Struct rows write a header then records, and map and list rows write the union of their keys or their cells. A header
// is refused where a row has none.
@(test)
rows_write_a_header_then_records :: proc(t: ^testing.T) {
	rows := []Write_Row{
		{id = 1, name = "a", ok = true, score = 1.5, small = 7, may = "m", color = .Blue, note = "n"},
		{id = -2, name = "", ok = false, score = 1e21, small = 0, color = .Red},
	}
	one := make(map[string]int, allocator = context.temp_allocator)
	one["a"] = 1
	maps := make([]map[string]int, 2, context.temp_allocator)
	maps[0] = make(map[string]int, context.temp_allocator)
	maps[1] = make(map[string]int, context.temp_allocator)
	maps[0]["b"], maps[0]["a"], maps[1]["c"] = 1, 2, 3
	empty := make([]map[string]string, 1, context.temp_allocator)
	empty[0] = make(map[string]string, context.temp_allocator)
	empty[0]["k"] = ""
	expect_writes(t, {
		{rows, .Csv, {}, "id,name,ok,score,small,may,color,note\n1,a,true,1.5,7,m,Blue,n\n-2,\"\",false,1e+21,0,,Red,\n", .None},
		{rows, .Csv, {no_header = true, crlf = true}, "1,a,true,1.5,7,m,Blue,n\r\n-2,\"\",false,1e+21,0,,Red,\r\n", .None},
		{[]map[string]int{one}, .Csv, {no_header = true}, "", .Unsupported},
		{[]map[string]int{one}, .Csv, {}, "a\n1\n", .None},
		{[][]int{{1, 2}, {3}}, .Csv, {}, "", .Wrong_Length},
		{[][]int{{1}, {2, 3}}, .Csv, {tolerate = {.Ragged}}, "1\n2,3\n", .None},
		{maps, .Csv, {}, "a,b,c\n2,1,\n,,3\n", .None},
		{empty, .Tsv, {}, "", .Unwritable},
		{[][]int{{}}, .Csv, {}, "", .Unwritable},
		{[]int{1, 2}, .Csv, {}, "1,2\n", .None},
		{[][][]int{}, .Csv, {}, "", .Unsupported},
		{[]struct {a: []int}{}, .Csv, {}, "", .Unsupported},
	})
	got, err := dsv.marshal([]struct {b, a: int}{{1, 2}}, .Csv, {}, write = {sort_keys = true}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, string(got), "a,b\n2,1\n")
}

// Each spec writes a cell its own way: CSV quotes what needs it, TSV escapes, Plain refuses what it cannot spell, an empty
// cell follows the spec, and a comment byte, a byte-order mark or a delimiter at a line's start is guarded.
@(test)
cells_follow_the_spec :: proc(t: ^testing.T) {
	long := strings.repeat("x,\"", 700, context.temp_allocator)
	expect_writes(t, {
		{[]One{{"a,b"}, {"q\"q"}, {"l\nl"}, {"plain"}, {"\r"}, {" "}}, .Csv, {no_header = true}, "\"a,b\"\n\"q\"\"q\"\n\"l\nl\"\nplain\n\"\r\"\n \n", .None},
		{[]One{{"a\tb\nc\\d\x00"}}, .Tsv, {no_header = true}, "a\\tb\\nc\\\\d\\0\n", .None},
		{[]One{{"a\\b\x00"}}, .Plain, {no_header = true}, "a\\b\x00\n", .None},
		{[]One{{"a,b"}}, .Plain, {}, "", .Unwritable},
		{[]One{{"a\nb"}}, .Plain, {}, "", .Unwritable},
		{[]One{{"a;b"}}, .Tsv, {delimiter = ';'}, "", .Unwritable},
		{[]One{{"a\tb"}}, .Tsv, {no_header = true, delimiter = ';'}, "a\tb\n", .None},
		{[]struct {a, b: string}{{"", "x"}}, .Tsv, {no_header = true}, "\tx\n", .None},
		{[]Opt{{""}}, .Tsv, {}, "", .Unwritable},
		{[]Opt{{""}}, .Csv, {no_header = true}, "\"\"\n", .None},
		{[]One{{"#x"}}, .Csv, {no_header = true, comment = '#'}, "\"#x\"\n", .None},
		{[]One{{"a"}, {"#x"}}, .Csv, {no_header = true, comment = '#'}, "a\n\"#x\"\n", .None},
		{[]One{{"x#"}}, .Csv, {no_header = true, comment = '#'}, "x#\n", .None},
		{[]One{{"#x"}}, .Plain, {comment = '#'}, "", .Unwritable},
		{[]One{{"\tx"}}, .Tsv, {no_header = true, delimiter = ';', comment = '\t'}, "\\tx\n", .None},
		{[]One{{"\xEF\xBB\xBFx"}}, .Csv, {no_header = true}, "\"\xEF\xBB\xBFx\"\n", .None},
		{[]One{{"\xEF\xBB\xBFx"}}, .Tsv, {no_header = true}, "", .Unwritable},
		{[]One{{"a"}, {"\xEF\xBB\xBFx"}}, .Csv, {no_header = true}, "a\n\xEF\xBB\xBFx\n", .None},
		{[]Num{{1}}, .Csv, {no_header = true, delimiter = '1'}, "\"1\"\n", .None},
		{[]Num{{1}}, .Plain, {delimiter = '1'}, "", .Unwritable},
		{[]Num{{12}}, .Csv, {no_header = true, comment = '1'}, "\"12\"\n", .None},
		{[]One{}, .Csv, {delimiter = '"'}, "", .Bad_Option},
		{[]One{{"\xff"}}, .Csv, {}, "", .Invalid_Utf8},
		{[]Float{{max(f64) * 2}}, .Csv, {}, "", .Non_Finite},
	})
	got, err := dsv.marshal([]One{{long}}, .Csv, {no_header = true}, write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	testing.expect_value(t, len(got), 2 + 700 * 4 + 1)
}

// A refusal names the row and the field it stopped at.
@(test)
refusals_name_their_steps :: proc(t: ^testing.T) {
	_, err := dsv.marshal([]Opt{{}}, .Csv, {no_header = true}, write = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	testing.expect_value(t, walktest.typed_of(err).n_steps, u8(1))
	_, err = dsv.marshal([]Float{{1}, {max(f64) * 2}}, .Csv, {}, write = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Non_Finite)
	testing.expect_value(t, walktest.typed_of(err).n_steps, u8(2))
	testing.expect_value(t, walktest.typed_of(err).steps[0], core.Step(core.Index(1)))
	testing.expect_value(t, walktest.typed_of(err).steps[1], core.Step(core.Name("f")))
	// A list row of another width than the first, which a read without `.Ragged` refuses.
	_, err = dsv.marshal([][]string{{"a", "b"}, {"c", "d"}, {"e"}}, .Csv, {}, write = {}, allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Wrong_Length)
	testing.expect_value(t, walktest.typed_of(err).n_steps, u8(1))
	testing.expect_value(t, walktest.typed_of(err).steps[0], core.Step(core.Index(2)))
	plan, _ := dsv.plan_make([]string, .Csv, allocator = context.temp_allocator)
	_, err = records.marshal([][]string{{"a"}, {"b", "c"}}, &plan, dsv.as(.Csv), allocator = context.temp_allocator)
	walktest.expect_kind(t, err, core.Typed_Error_Kind.Wrong_Length)
	ragged, _ := dsv.plan_make([]string, .Csv, {tolerate = {.Ragged}}, allocator = context.temp_allocator)
	text, rerr := records.marshal([][]string{{"a"}, {"b", "c"}}, &ragged, dsv.as(.Csv, {tolerate = {.Ragged}}), allocator = context.temp_allocator)
	walktest.expect_nil(t, rerr)
	testing.expect_value(t, string(text), "a\nb,c\n")
}

Hooked :: distinct i32

@(test)
hook_stand_ins_are_cells :: proc(t: ^testing.T) {
	Row :: struct {h: Hooked, s: Maybe(Hooked)}
	hooks := []typed.Type_Hook{{type = Hooked, write = proc(v: rawptr, _: runtime.Allocator) -> (any, core.Typed_Error_Kind) {
		return (^i32)(v)^, .None
	}}}
	plan, err := dsv.plan_make([]Row, .Csv, {}, plan = {hooks = hooks}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	defer typed.plan_destroy(&plan)
	got, werr := write.marshal([]Row{{h = 5, s = Hooked(6)}}, &plan, {}, context.temp_allocator)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, string(got), "h,s\n5,6\n")
}

@(test)
stream_output_matches_buffer :: proc(t: ^testing.T) {
	Row :: struct {id: int, s: string}
	rows := make([]Row, 3000, context.temp_allocator)
	for &r, i in rows {
		r = {i, "a,b"}
	}
	want, _ := dsv.marshal(rows, .Csv, {}, write = {}, allocator = context.temp_allocator)
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	plan, _ := dsv.plan_make([]Row, .Csv, allocator = context.temp_allocator)
	err := write.marshal_stream(strings.to_stream(&b), rows, &plan)
	walktest.expect_nil(t, err)
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
	text, err := dsv.marshal(rows, spec, layout, write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err, loc)
	back: []Write_Row
	var_err: core.Error
	switch spec {
	case .Csv:
		var_err = dsv.unmarshal(text, .Csv, &back, read = {}, opts = layout, allocator = context.temp_allocator)
	case .Tsv:
		var_err = dsv.unmarshal(text, .Tsv, &back, read = {}, opts = layout, allocator = context.temp_allocator)
	case .Plain:
		var_err = dsv.unmarshal(text, .Plain, &back, read = {}, opts = layout, allocator = context.temp_allocator)
	}
	walktest.expect_nil(t, var_err, loc)
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

Source :: enum {
	Csv,
	Json,
	Json5,
	Jsonc,
}

Doc_Case :: struct {
	src:     string,
	from:    Source,
	read:    dsv.Options, // of a CSV source
	opts:    core.Write_Options,
	as:      Maybe(core.As), // the spec written, the source's own when nil
	want:    string,
	kind:    core.Typed_Error_Kind,
	dropped: int,
}

build_source :: proc(c: Doc_Case) -> (core.Document, core.Error) {
	src := transmute([]u8)c.src
	switch c.from {
	case .Csv:   return dsv.build(src, .Csv, c.read, .Last, context.temp_allocator)
	case .Json:  return json.build(src, .Json, {}, .Last, context.temp_allocator)
	case .Json5: return json.build(src, .Json5, {}, .Last, context.temp_allocator)
	case .Jsonc: return json.build(src, .Jsonc, {}, .Last, context.temp_allocator)
	}
	return {}, {kind = .Bad_Value}
}

// A document writes in its own spec or another's: a table takes the union of its records' keys in source order, or sorted,
// a repeated key keeps its last value and counts the earlier ones as dropped, a wide record's columns past the header's
// last are named by position, a JSON5 number is written as JSON writes it, and a nested or scalar value or a non-finite
// number is refused. A text keeps the line end its first row was read with, and a line end in a quoted cell or a comment
// line is no row's.
@(test)
documents_write :: proc(t: ^testing.T) {
	ragged := dsv.Options{tolerate = {.Ragged}}
	crlf_cases := []Doc_Case{
		{src = "a,b\r\n1,2\r\n", want = "a,b\r\n1,2\r\n"},
		{src = "a,b\n1,2\n", want = "a,b\n1,2\n"},
		{src = "a,b\r\n", want = "a,b\r\n"},
		{src = "\"a\r\nb\",c\n1,2\n", want = "\"a\r\nb\",c\n1,2\n"},
		{src = "a,b\n\"x\r\ny\",2\n", want = "a,b\n\"x\r\ny\",2\n"},
		{src = "1,2\r\n", read = {no_header = true}, want = "1,2\r\n"},
		{src = "\"x\r\ny\",2\n3,4\n", read = {no_header = true}, want = "\"x\r\ny\",2\n3,4\n"},
		{src = "a,b\n", read = {no_header = true}, want = "a,b\n"},
		{src = "a,b\n", want = "a,b\n"},
		{src = "#c\r\na,b\n1,2\n", read = {comment = '#'}, want = "#c\na,b\n1,2\n"},
		{src = "a\r\n1,2\r\n", read = ragged, want = "a,2\r\n1,2\r\n"},
	}
	cases := []Doc_Case{
		{src = "# c\nid;name\n1;\"a;b\"\n2;\n", read = {delimiter = ';', comment = '#'}, want = "# c\nid;name\n1;\"a;b\"\n2;\n"},
		{src = "# c\nid;name\n1;\"a;b\"\n2;\n", read = {delimiter = ';', comment = '#'}, as = dsv.as(.Tsv), want = "id\tname\n1\ta;b\n2\t\n", dropped = 1},
		{src = "a,b\n1,2,3\n4\n", read = ragged, want = "a,b,3\n1,2,3\n4,,\n"},
		{src = "a,b\n1,2,3\n4\n", read = ragged, as = json.as(.Json), want = `[{"a":"1","b":"2","3":"3"},{"a":"4"}]`},
		{src = "b,a,c,a\n1,2,3,4\n5,6\n", read = ragged, opts = {sort_keys = true}, want = "a,a,b,c\n2,4,1,3\n6,,5,\n"},
		{src = `[{"b":1,"a":2,"c":3},{"c":4,"a":5}]`, from = .Json, opts = {sort_keys = true}, as = dsv.as(.Csv), want = "a,b,c\n2,1,3\n5,,4\n"},
		{src = `[{"b":1,"a":2,"c":3},{"c":4,"a":5}]`, from = .Json, as = dsv.as(.Csv), want = "b,a,c\n1,2,3\n,5,4\n"},
		{src = `[{"a":1,"b":"x,y"},{"b":null,"c":true,"a":2.50}]`, from = .Json, as = dsv.as(.Csv), want = "a,b,c\n1,\"x,y\",\n2.50,,true\n"},
		{src = `[[1,"a"],[2,"b"]]`, from = .Json, as = dsv.as(.Tsv), want = "1\ta\n2\tb\n"},
		{src = `[{"a":[1]}]`, from = .Json, as = dsv.as(.Csv), kind = .Unsupported},
		{src = "[/* c */ {\"a\":[1]}]", from = .Jsonc, as = dsv.as(.Csv), kind = .Unsupported},
		{src = `[{a:-0x10,b:+1,c:.5,d:5.,e:0X1F,f:1.50}]`, from = .Json5, as = dsv.as(.Csv, {comment = '-'}), want = "a,b,c,d,e,f\n\"-16\",1,0.5,5,31,1.50\n"},
		{src = `[{a:-0x10,b:+1,c:.5,d:5.,e:0X1F,f:1.50}]`, from = .Json5, as = dsv.as(.Csv, {delimiter = '.'}), want = "a.b.c.d.e.f\n-16.1.\"0.5\".5.31.\"1.50\"\n"},
		{src = `[[Infinity]]`, from = .Json5, as = dsv.as(.Csv), kind = .Non_Finite},
		{src = `[1]`, from = .Json, as = dsv.as(.Csv), kind = .Unsupported},
		{src = `[{"a":1,"a":2,"a":3,"b":4},{"a":5}]`, from = .Json, as = dsv.as(.Csv), want = "a,b\n3,4\n5,\n", dropped = 2},
		{src = "a,b\n1,\"x,y\"\n", as = dsv.as(.Tsv), want = "a\tb\n1\tx,y\n"},
		{src = "# c\na\n1\n", read = {comment = '#'}, want = "# c\na\n1\n"},
	}
	// A document's comments are written where an edit writes them, with the output's comment byte, and dropped and
	// counted where the output has no place for them or no comment byte.
	commented := "#top\na,b\n#one\n1,2\n#two\n3,4\n#foot\n"
	comment_cases := []Doc_Case{
		{src = commented, read = {comment = '#'}, want = commented},
		{src = commented, read = {comment = '#'}, as = dsv.as(.Tsv, {comment = ';'}), want = ";top\na\tb\n;one\n1\t2\n;two\n3\t4\n;foot\n"},
		{src = commented, read = {comment = '#'}, as = dsv.as(.Csv), want = "a,b\n1,2\n3,4\n", dropped = 4},
		{src = commented, read = {comment = '#'}, as = dsv.as(.Csv, {comment = '#', no_header = true}), want = "#one\n1,2\n#two\n3,4\n#foot\n", dropped = 1},
		{src = "#top\na,b\n", read = {comment = '#'}, want = "a,b\n#top\n"},
		{src = "1\n#two\n2\n#foot\n", read = {comment = '#', no_header = true}, want = "1\n#two\n2\n#foot\n"},
		{src = "// top\n[ // one\n {\"a\": 1}, /* inline */\n {\"a\": 2 /* cell */}\n// foot\n]\n", from = .Jsonc, as = dsv.as(.Csv, {comment = '#'}), want = "# top\na\n# one\n1\n2\n# foot\n", dropped = 2},
		{src = "[/* one\ntwo */ {\"a\": 1}]", from = .Jsonc, as = dsv.as(.Csv, {comment = '#'}), want = "a\n1\n", dropped = 1},
	}
	// A string cell an inferring read would take for another kind is quoted, and a cell it infers keeps its text.
	inferred := "a,b,c,d\n1,\"2\",true,\"false\"\n,x,1e2,\"\"\n"
	infer_cases := []Doc_Case{
		{src = inferred, read = {infer = true}, want = inferred},
		{src = inferred, read = {infer = true}, as = dsv.as(.Csv), want = "a,b,c,d\n1,2,true,false\n,x,1e2,\"\"\n"},
		{src = inferred, as = dsv.as(.Csv, {infer = true}), want = "a,b,c,d\n\"1\",\"2\",\"true\",\"false\"\n,x,\"1e2\",\"\"\n"},
		{src = "a,b\n1,x\n", as = dsv.as(.Tsv, {infer = true}), kind = .Unwritable},
		{src = "[{\"a\": \"2\", \"b\": 2, \"c\": \"true\", \"d\": false}]", from = .Json, as = dsv.as(.Csv, {infer = true}), want = "a,b,c,d\n\"2\",2,\"true\",false\n"},
	}
	for list in ([4][]Doc_Case{crlf_cases, cases, comment_cases, infer_cases}) {
		for c in list {
			doc, err := build_source(c)
			if !testing.expectf(t, err == nil, "%q: %v", c.src, err) {
				return
			}
			text, dropped, werr := core.write(&doc, c.opts, c.as, allocator = context.temp_allocator)
			testing.expectf(t, walktest.typed_kind(werr) == c.kind && string(text) == c.want && dropped == c.dropped, "%q: %v %q with %d dropped, want %v %q with %d", c.src, werr, text, dropped, c.kind, c.want, c.dropped)
		}
	}
}

Marshal_Try :: struct {
	value: any,
	opts:  core.Write_Options,
}

marshal_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	m := (^Marshal_Try)(data)
	text, err := dsv.marshal(m.value, .Csv, {}, write = m.opts, allocator = allocator)
	return text, walktest.typed_kind(err)
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
		want, err := dsv.marshal(c.value, .Csv, {}, write = c.opts, allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		walktest.sweep_write(t, marshal_try, &c, string(want))
	}
}

document_try :: proc(data: rawptr, allocator: runtime.Allocator) -> ([]u8, core.Typed_Error_Kind) {
	text, _, err := core.write((^core.Document)(data), {}, dsv.as(.Csv), allocator = allocator)
	return text, walktest.typed_kind(err)
}

@(test)
document_under_failing_allocators :: proc(t: ^testing.T) {
	long := strings.repeat("k", 600, context.temp_allocator)
	headed, herr := dsv.build(transmute([]u8)string("a,b\n1,\"x y\"\n2,3\n"), .Csv)
	defer core.destroy(&headed)
	walktest.expect_nil(t, herr)
	src := strings.concatenate({`[{"`, long, `":1,"b":"`, long, `"},{"c":null}]`}, context.temp_allocator)
	foreign_doc, ferr := json.build(transmute([]u8)src, .Json)
	defer core.destroy(&foreign_doc)
	walktest.expect_nil(t, ferr)
	for doc in ([?]^core.Document{&headed, &foreign_doc}) {
		want, _, err := core.write(doc, {}, dsv.as(.Csv), allocator = context.temp_allocator)
		walktest.expect_nil(t, err)
		walktest.sweep_write(t, document_try, doc, string(want))
	}
}

// A write that succeeds leaves nothing on the temporary allocator, which a caller may never free.
@(test)
write_keeps_off_the_temporary_allocator :: proc(t: ^testing.T) {
	f := walktest.Failing_Alloc{inner = context.temp_allocator, fail_at = -1}
	context.temp_allocator = walktest.failing_allocator(&f)
	text, err := dsv.marshal([]Sweep_Row{{1, "a"}}, allocator = context.allocator)
	defer delete(text)
	walktest.expect_nil(t, err)
	doc, derr := json.build(transmute([]u8)string(`[{"a":1}]`), .Json)
	defer core.destroy(&doc)
	walktest.expect_nil(t, derr)
	again, _, werr := core.write(&doc, as = dsv.as(.Csv))
	defer delete(again)
	walktest.expect_nil(t, werr)
	testing.expect_value(t, f.n, 0)
}

// An empty column name alone in a header would be a blank line where a spec has no spelling for it, and the first record
// would read as the header.
@(test)
header_of_one_empty_name :: proc(t: ^testing.T) {
	row := make(map[string]string, context.temp_allocator)
	row[""] = "x"
	rows := []map[string]string{row}
	for spec in ([?]dsv.Spec{.Tsv, .Plain}) {
		_, err := dsv.marshal(rows, spec, {}, write = {}, allocator = context.temp_allocator)
		walktest.expect_kind(t, err, core.Typed_Error_Kind.Unwritable)
	}
	text, err := dsv.marshal(rows, .Csv, {}, write = {}, allocator = context.temp_allocator)
	walktest.expect_nil(t, err)
	doc, derr := dsv.build(text, .Csv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, derr)
	testing.expect_value(t, core.length(&doc, core.ROOT), 1)
}

// A write that fails counts nothing, whether the document refuses or the stream does.
@(test)
failed_write_counts_nothing :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("# c\na\n1\n"), .Csv, {comment = '#'})
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	counted, dropped, kerr := core.write(&doc, as = dsv.as(.Csv), allocator = context.temp_allocator)
	walktest.expect_nil(t, kerr)
	testing.expect_value(t, string(counted), "a\n1\n")
	testing.expect_value(t, dropped, 1)
	closed := io.Stream{procedure = refusing_stream}
	lost, serr := core.write_stream(closed, &doc, as = dsv.as(.Csv))
	walktest.expect_kind(t, serr, core.Typed_Error_Kind.Write_Failed)
	testing.expect_value(t, lost, 0)
}

refusing_stream :: proc(data: rawptr, mode: io.Stream_Mode, p: []u8, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
	return 0, .Permission_Denied if mode == .Write else .Unknown
}

// `core.write_stream` gives the bytes of the text in memory, in the read spec and in another.
@(test)
document_streams :: proc(t: ^testing.T) {
	doc, err := dsv.build(transmute([]u8)string("a,b\n1,\"x,y\"\n"), .Csv)
	defer core.destroy(&doc)
	walktest.expect_nil(t, err)
	b := strings.builder_make(context.temp_allocator)
	_, serr := core.write_stream(strings.to_stream(&b), &doc)
	walktest.expect_nil(t, serr)
	testing.expect_value(t, strings.to_string(b), "a,b\n1,\"x,y\"\n")
	strings.builder_reset(&b)
	_, derr := core.write_stream(strings.to_stream(&b), &doc, as = dsv.as(.Tsv))
	walktest.expect_nil(t, derr)
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
				want, werr := dsv.marshal([][]string{{plain}}, spec, {}, write = {}, allocator = context.temp_allocator)
				got, gerr := dsv.marshal([][]string{{fenced}}, spec, {}, write = {}, allocator = context.temp_allocator)
				testing.expect_value(t, walktest.typed_kind(gerr), walktest.typed_kind(werr))
				testing.expect_value(t, string(got), string(want))
			}
			free_all(context.temp_allocator)
		}
	}
}
