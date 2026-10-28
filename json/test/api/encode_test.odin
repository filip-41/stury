package json_tests

// The writer's scalars through `marshal`: string escapes (§3.1), floats (§3.3: the ECMAScript layout on
// goldens, `-0` kept, non-finite refused).

import "base:runtime"
import json "../.."
import core "../../../core"
import "core:io"
import "core:math"
import "core:strings"
import "core:testing"

@(test)
test_encode_string_escapes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		s, want: string,
	}
	cases := []Case{
		{"", `""`},
		{"plain", `"plain"`},
		{"q\"b\\", `"q\"b\\"`},
		{"\b\f\n\r\t", `"\b\f\n\r\t"`},
		{"\x00\x01\x1f", `"\u0000\u0001\u001f"`},
		{"\x7f/é😀", "\"\x7f/é😀\""},
		{"0123456789abcde\"", `"0123456789abcde\""`},
		{"0123456789abcdef\n", `"0123456789abcdef\n"`},
	}
	for c in cases {
		testing.expect_value(t, marshal_text(t, c.s), c.want)
	}
}

@(test)
test_encode_f64_goldens :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	Case :: struct {
		f:    f64,
		want: string,
	}
	cases := []Case{
		{0, "0"},
		{1, "1"},
		{-1.5, "-1.5"},
		{100, "100"},
		{123e18, "123000000000000000000"},
		{1e21, "1e+21"},
		{1e20, "100000000000000000000"},
		{0.1, "0.1"},
		{0.30000000000000004, "0.30000000000000004"},
		{123.456, "123.456"},
		{1e-6, "0.000001"},
		{1e-7, "1e-7"},
		{1.5e-7, "1.5e-7"},
		{5e-324, "5e-324"},
		{2.2250738585072014e-308, "2.2250738585072014e-308"},
		{1.7976931348623157e308, "1.7976931348623157e+308"},
		{9007199254740992, "9007199254740992"},
		{-1e-300, "-1e-300"},
	}
	for c in cases {
		testing.expect_value(t, marshal_text(t, c.f), c.want)
	}
	testing.expect_value(t, marshal_text(t, math.copy_sign(f64(0), -1)), "-0")
}

@(test)
test_encode_f64_non_finite :: proc(t: ^testing.T) {
	for f in ([]f64{math.inf_f64(1), math.inf_f64(-1), math.nan_f64()}) {
		marshal_refused(t, f, json.Marshal_Error_Kind.Non_Finite)
	}
}

// `jq_spelling` writes a Document as `stury -c` prints it (the wants below are that binary's output for the
// same text), without it the source's written forms are kept.
@(test)
test_encode_jq_spelling :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := `[1E2,-0,1e1000,0.1,100000000000000000000,"\/","é","\u0001\u007f\n\t\"\\",{"a":1,"b":2,"a":3},{"k":{"z":[],"y":{}}}]`
	want := `[1E+2,-0,1E+1000,0.1,100000000000000000000,"/","é","\u0001\u007f\n\t\"\\",{"a":3,"b":2},{"k":{"z":[],"y":{}}}]`
	doc := build_ok(t, text)
	defer json.destroy(&doc)
	got, err := json.marshal(&doc, {jq_spelling = true}, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(got), want)
	plain, _ := json.marshal(&doc, {}, context.temp_allocator)
	testing.expect_value(t, string(plain), `[1E2,-0,1e1000,0.1,100000000000000000000,"\/","é","\u0001\u007f\n\t\"\\",{"a":1,"b":2,"a":3},{"k":{"z":[],"y":{}}}]`)
	pretty, _ := json.marshal(&doc, {jq_spelling = true, pretty = true, indent = 2, trailing_newline = true}, context.temp_allocator)
	testing.expect(t, strings.has_prefix(string(pretty), "[\n  1E+2,\n"), string(pretty))
	testing.expect(t, strings.has_suffix(string(pretty), "    }\n  }\n]\n"), string(pretty))
	ascii, _ := json.marshal(&doc, {jq_spelling = true, ascii_only = true}, context.temp_allocator)
	testing.expect(t, strings.contains(string(ascii), "\"\\u00e9\""), string(ascii))
	sb := strings.builder_make(context.temp_allocator)
	err = json.marshal_to_writer(strings.to_writer(&sb), &doc, {jq_spelling = true}, context.temp_allocator)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	testing.expect_value(t, strings.to_string(sb), want)
}

// `jq_spelling` writes a JSONC Document as `stury --from jsonc` prints it, comments included (the wants are that
// binary's `-c .` and `.` output): a repeated key keeps its last value's comments at its first place.
@(test)
test_encode_jq_spelling_jsonc :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	text := "// head\n{\n  // lead a\n  \"a\": /* in a */ 1E2, // trail a\n  \"b\": [1, /* two */ 2, // after 2\n  ],\n  \"c\": // in c\n    /* in c2 */ [],\n  \"e\": {\n    // empty\n  },\n  // lead a again\n  \"a\": \"\\/\" /* last a */\n  // foot\n} /* end */ // end2\n"
	doc, err := json.build(raw(text), {dialect = .Jsonc})
	testing.expect_value(t, err, nil)
	defer json.destroy(&doc)
	compact, cerr := json.marshal(&doc, {jq_spelling = true, trailing_newline = true}, context.temp_allocator)
	testing.expect_value(t, marshal_kind(cerr), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(compact), "// head\n{// lead a again\n\"a\":\"/\",/* last a */\"b\":[1,/* two */2// after 2\n],\"c\":// in c\n/* in c2 */[],\"e\":{// empty\n}// foot\n}/* end */// end2\n")
	pretty, perr := json.marshal(&doc, {jq_spelling = true, pretty = true, indent = 2, trailing_newline = true}, context.temp_allocator)
	testing.expect_value(t, marshal_kind(perr), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(pretty), "// head\n{\n  // lead a again\n  \"a\": \"/\", /* last a */\n  \"b\": [\n    1, /* two */\n    2 // after 2\n  ],\n  \"c\": // in c\n  /* in c2 */ [],\n  \"e\": {\n    // empty\n  }\n  // foot\n} /* end */ // end2\n")
}

// An allocator that refuses at any point of a `jq_spelling` marshal gives `.Out_Of_Memory` and no output,
// never a short one.
@(test)
test_encode_jq_spelling_refused_allocator :: proc(t: ^testing.T) {
	doc := build_ok(t, `{"a":[1E2,{"b":0.1e1,"b":2}],"c":"x\/y","d":{"e":[]}}`)
	defer json.destroy(&doc)
	opts := json.Document_Opts{jq_spelling = true, pretty = true, indent = 2, trailing_newline = true}
	want, werr := json.marshal(&doc, opts)
	defer delete(want)
	testing.expect_value(t, marshal_kind(werr), json.Marshal_Error_Kind.None)
	sweep := Budget_Sweep{limit = 1000}
	for b, k in next_budget(&sweep) {
		out, err := json.marshal(&doc, opts, budget_allocator(b))
		if !b.refused {
			testing.expect_value(t, string(out), string(want))
			delete(out)
			continue
		}
		testing.expectf(t, marshal_kind(err) == .Out_Of_Memory && out == nil, "refused at allocation %d: %v, %q", k, err, string(out))
		delete(out)
	}
	expect_swept(t, &sweep)
}

// A writer that accepts `left` bytes, then refuses.
Refusing_Writer :: struct {
	left: int,
}

refusing_writer_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	w := (^Refusing_Writer)(data)
	#partial switch mode {
	case .Write:
		if len(p) > w.left {
			n, w.left = i64(w.left), 0
			return n, .Unexpected_EOF
		}
		w.left -= len(p)
		return i64(len(p)), nil
	case .Query:
		return io.query_utility({.Write, .Query})
	}
	return 0, .Empty
}

// A writer that refuses, at once or after a prefix, is `.Write_Failed` from `marshal_to_writer` (a value
// compact and pretty, a JSONC document, and an output past the sink's flush size) and the error from
// `render_error_to_writer`.
@(test)
test_writer_that_refuses_is_write_failed :: proc(t: ^testing.T) {
	jsonc, jerr := json.build(raw("{\"a\": [1, 2] /* c */}"), {dialect = .Jsonc})
	defer json.destroy(&jsonc)
	testing.expect_value(t, jerr, nil)
	big := make([]int, 100000)
	defer delete(big)
	small := []int{1, 2, 3}
	for left in ([]int{0, 3}) {
		for opts in ([]json.Marshal_Opts{{}, {pretty = true, indent = 2}}) {
			w := Refusing_Writer{left}
			testing.expect_value(t, marshal_kind(json.marshal_to_writer(io.Writer{refusing_writer_proc, &w}, small, opts)), json.Marshal_Error_Kind.Write_Failed)
		}
		w := Refusing_Writer{left}
		testing.expect_value(t, marshal_kind(json.marshal_to_writer(io.Writer{refusing_writer_proc, &w}, &jsonc)), json.Marshal_Error_Kind.Write_Failed)
		w = Refusing_Writer{left}
		err := core.render_error_to_writer(io.Writer{refusing_writer_proc, &w}, raw("[1,"), json.Error{kind = .Truncated, offset = 3})
		testing.expectf(t, err != nil, "render_error_to_writer with %d bytes accepted", left)
	}
	w := Refusing_Writer{1000}
	testing.expect_value(t, marshal_kind(json.marshal_to_writer(io.Writer{refusing_writer_proc, &w}, big)), json.Marshal_Error_Kind.Write_Failed)
}

@(test)
test_jq_spelling_uses_only_passed_allocator :: proc(t: ^testing.T) {
	doc := build_ok(t, `[12.34e1, 1.234e-10, -0.005e2, 100e-2]`)
	defer json.destroy(&doc)
	alloc := context.allocator
	saved_alloc := context.allocator
	saved_temp := context.temp_allocator
	context.allocator = runtime.panic_allocator()
	context.temp_allocator = runtime.panic_allocator()
	out, err := json.marshal(&doc, {jq_spelling = true}, alloc)
	context.allocator = saved_alloc
	context.temp_allocator = saved_temp
	defer delete(out, alloc)
	testing.expect_value(t, marshal_kind(err), json.Marshal_Error_Kind.None)
	testing.expect_value(t, string(out), `[123.4,1.234E-10,-0.5,1.00]`)
}
