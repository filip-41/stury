package write_tests

import "core:bytes"
import "core:io"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// A JSON text written from its document: tokens past the sizes a buffer is reserved in, tokens at the end of the
// source or of a page, strings the read decoded, and the errors a sink returns.

// The layouts each text is written in.
@(private = "file")
DOCUMENT_LAYOUTS := [?]json.Write_Options{{}, {indent = 2}, {tab = true}, {indent = 7}}

// The text of a write of `doc` into a sink, which the caller frees.
@(private)
sink_text :: proc(doc: ^json.Document, to: json.Spec, opts: json.Write_Options) -> ([]u8, json.Write_Error) {
	sink: bytes.Buffer
	defer bytes.buffer_destroy(&sink)
	_, err := json.write_to(bytes.buffer_to_stream(&sink), doc, to, opts)
	return bytes.clone(bytes.buffer_to_bytes(&sink)), err
}

// Reads `src` as JSON, JSONC and JSON5 and writes each document as JSON in each layout, into a buffer and a sink. The
// three reads take three routes to the text, the dense one over the source's bytes, the rows of the tokens, and the
// walk, and the text is one. It is valid JSON that reads back as the same values and writes as the same text.
@(private = "file")
routes_agree :: proc(t: ^testing.T, src: []u8, loc := #caller_location) -> bool {
	strict, serr := json.build(src, .Json)
	defer json.destroy(&strict)
	rows, rerr := json.build(src, .Jsonc)
	defer json.destroy(&rows)
	walked, werr := json.build(src, .Json5)
	defer json.destroy(&walked)
	if !testing.expectf(t, serr == nil && rerr == nil && werr == nil, "%.80q: %v %v %v", src, serr, rerr, werr, loc = loc) {
		return false
	}
	for opts in DOCUMENT_LAYOUTS {
		want, _, err := json.write(&walked, .Json, opts)
		defer delete(want)
		if !testing.expectf(t, err == nil, "%.80q under %v: %v", src, opts, err, loc = loc) {
			return false
		}
		if verr := json.validate(want); verr != nil {
			testing.expectf(t, false, "%.80q under %v wrote %.200q: %v", src, opts, want, verr, loc = loc)
			return false
		}
		for doc, k in ([?]^json.Document{&strict, &rows}) {
			got, _, gerr := json.write(doc, .Json, opts)
			defer delete(got)
			if !testing.expectf(t, gerr == nil && string(got) == string(want), "%.80q under %v by route %d: %v, %d bytes against %d", src, opts, k, gerr, len(got), len(want), loc = loc) {
				return false
			}
			sunk, sinkerr := sink_text(doc, .Json, opts)
			defer delete(sunk)
			if !testing.expectf(t, sinkerr == nil && string(sunk) == string(want), "%.80q under %v to a sink by route %d: %v", src, opts, k, sinkerr, loc = loc) {
				return false
			}
		}
		back, berr := json.build(want, .Json)
		defer json.destroy(&back)
		if !testing.expectf(t, berr == nil, "%.80q under %v: %v", src, opts, berr, loc = loc) {
			return false
		}
		if !testkit.values_agree(t, &strict, json.ROOT, &back, json.ROOT, {}, "written text", loc) {
			return false
		}
		again, _, aerr := json.write(&back, .Json, opts)
		defer delete(again)
		if !testing.expectf(t, aerr == nil && string(again) == string(want), "%.80q under %v: a write of the written text changes it", src, opts, loc = loc) {
			return false
		}
	}
	return true
}

// A long key and a long string past one reservation are copied whole.
@(test)
document_long_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	key := strings.repeat("k", 10000, context.temp_allocator)
	value := strings.repeat("v", 70000, context.temp_allocator)
	text := strings.concatenate({`{"`, key, `":["`, value, `",1]}`}, context.temp_allocator)
	routes_agree(t, transmute([]u8)text)
	escaped := strings.concatenate({`["`, strings.repeat(`aé\n`, 20000, context.temp_allocator), `"]`}, context.temp_allocator)
	routes_agree(t, transmute([]u8)escaped)
}

// A token within a block copy of the source's end is written whole at every length, as a value and as a key.
@(test)
document_tokens_near_the_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for n in 0 ..< 70 {
		x := strings.repeat("x", n, context.temp_allocator)
		digits := strings.repeat("7", n + 1, context.temp_allocator)
		for parts in ([?][3]string{{`[1,{"k":"`, x, `"}]`}, {`{"`, x, `":[]}`}, {`{"a":{"k":`, digits, `}}`}}) {
			parts := parts
			text := strings.concatenate(parts[:], context.temp_allocator)
			if !routes_agree(t, transmute([]u8)text) {
				return
			}
		}
		free_all(context.temp_allocator)
	}
}

// A text of more than twice a sink's buffer is written through each refill.
@(test)
document_refills :: proc(t: ^testing.T) {
	testkit.deadline(t)
	members := strings.repeat(`{"id":1,"tags":[[[[[[[["a","b"]]]]]]]],"on":true},`, 3000, context.temp_allocator)
	text := strings.concatenate({"[", members, "null]"}, context.temp_allocator)
	routes_agree(t, transmute([]u8)text)
}

// A text that ends at an unmapped page is written whole by each route, into a buffer and a sink: no read passes its
// last byte.
@(test)
document_writes_stop_at_the_end_of_a_page :: proc(t: ^testing.T) {
	testkit.deadline(t)
	fence: testkit.Fence
	defer testkit.fence_release(&fence)
	texts: [dynamic]string
	defer delete(texts)
	for text in ([]string{`null`, `-0.0`, `"a"`, `[]`, `{}`, `[[],{},[[]],{"a":{}}]`, `{"a":1,"b":[true,false,null],"c":{"d":"e","f":[1.5e300,-0,0.1]}}`, `  [ 1 , 2 ,
	3 ]  `, `{"esc":"a\né\"\\\/😀","A":"k","":""}`, `["é","日本語","😀",""]`}) {
		append(&texts, text)
	}
	// The sizes around the one a small text is copied up to.
	for n in 1000 ..< 1030 {
		append(&texts, strings.concatenate({`["`, strings.repeat("a", n, context.temp_allocator), `"]`}, context.temp_allocator))
	}
	for n in 0 ..< 200 {
		append(&texts, strings.concatenate({`["`, strings.repeat("a", n, context.temp_allocator), `"]`}, context.temp_allocator))
		append(&texts, strings.concatenate({"[", strings.repeat("1,", n, context.temp_allocator), "1]"}, context.temp_allocator))
		append(&texts, strings.concatenate({"[", strings.repeat(" ", n, context.temp_allocator), "1", strings.repeat(" ", n, context.temp_allocator), "]"}, context.temp_allocator))
	}
	for text in texts {
		plain, perr := json.build(transmute([]u8)text)
		if !testing.expectf(t, perr == nil, "%q: %v", text, perr) {
			return
		}
		for spec in ([?]json.Spec{.Json, .Jsonc, .Json5}) {
			fenced, ferr := json.build(testkit.fence_copy(&fence, transmute([]u8)text), spec)
			if !testing.expectf(t, ferr == nil, "%q as %v: %v", text, spec, ferr) {
				return
			}
			for opts in DOCUMENT_LAYOUTS {
				want, _, werr := json.write(&plain, .Json, opts)
				got, _, gerr := json.write(&fenced, .Json, opts)
				sunk, serr := sink_text(&fenced, .Json, opts)
				testing.expectf(t, werr == nil && gerr == nil && serr == nil && string(got) == string(want) && string(sunk) == string(want), "%q as %v under %v: %q %v, a sink %v", text, spec, opts, got, gerr, serr)
				delete(want)
				delete(got)
				delete(sunk)
			}
			json.destroy(&fenced)
		}
		json.destroy(&plain)
	}
}

// An escape that reads as U+FFFD, a tolerated lone surrogate half, is written as the character, and a pair as its
// character, on every route, and the text reads strictly.
@(test)
document_lone_surrogates_write_as_they_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	long := strings.repeat("a", 300, context.temp_allocator)
	FFFD :: "\xEF\xBF\xBD"
	cases := [?][2]string {
		{`"\ud800"`, `"` + FFFD + `"`},
		{`["\udc00",1]`, `["` + FFFD + `",1]`},
		{`["\ud83dx"]`, `["` + FFFD + `x"]`},
		{`{"\ud800":"😀"}`, `{"` + FFFD + `":"😀"}`},
		{`[1,1,1,1,1,1,1,1,1,1,1,1,1,"\ud800",1,1,1,1,1,1,1,1,1,1,1,1,1]`, `[1,1,1,1,1,1,1,1,1,1,1,1,1,"` + FFFD + `",1,1,1,1,1,1,1,1,1,1,1,1,1]`},
		{strings.concatenate({`["`, long, `\ud800"]`}, context.temp_allocator), strings.concatenate({`["`, long, FFFD, `"]`}, context.temp_allocator)},
	}
	for c in cases {
		for spec in ([?]json.Spec{.Json, .Jsonc, .Json5}) {
			doc, err := json.build(transmute([]u8)c[0], spec, {tolerate = {.Lone_Surrogate}})
			if !testing.expectf(t, err == nil, "%q as %v: %v", c[0], spec, err) {
				continue
			}
			defer json.destroy(&doc)
			text, _, werr := json.write(&doc)
			defer delete(text)
			testing.expect_value(t, werr, nil)
			testing.expectf(t, string(text) == c[1], "%q as %v: %q, want %q", c[0], spec, text, c[1])
			testing.expect_value(t, json.validate(text), nil)
		}
	}
}

// Strings a tolerance read are spelled again past a chunk of rows, in keys too.
@(test)
document_tolerated_strings_through_the_rows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	FFFD :: "\xEF\xBF\xBD"
	src := strings.concatenate({"[", strings.repeat("\"a\xff\",{\"k\xff\":\"b\"},1,", 3000, context.temp_allocator), "0]"}, context.temp_allocator)
	want := strings.concatenate({"[", strings.repeat(`"a` + FFFD + `",{"k` + FFFD + `":"b"},1,`, 3000, context.temp_allocator), "0]"}, context.temp_allocator)
	for spec in ([?]json.Spec{.Json, .Jsonc, .Json5}) {
		doc, err := json.build(transmute([]u8)src, spec, {tolerate = {.Invalid_Utf8}})
		defer json.destroy(&doc)
		testing.expect_value(t, err, nil)
		text, _, werr := json.write(&doc)
		defer delete(text)
		testing.expect_value(t, werr, nil)
		testing.expectf(t, string(text) == want, "as %v: %d bytes, want %d", spec, len(text), len(want))
		pretty, _, perr := json.write(&doc, .Json, {indent = 2})
		defer delete(pretty)
		again, aerr := json.build(pretty)
		defer json.destroy(&again)
		testing.expect_value(t, perr, nil)
		testing.expect_value(t, aerr, nil)
		compact, _, cerr := json.write(&again)
		defer delete(compact)
		testing.expect_value(t, cerr, nil)
		testing.expect(t, string(compact) == want)
	}
}

// Strings read with escapes are written with the escapes they were read with, and a comment's text is left as it was.
@(test)
document_keeps_string_escapes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `{"a":["é\/x","😀","é","\n\"\\","\u00e9\u0041",1E2]}`
	doc, _ := json.build(transmute([]u8)string(src))
	defer json.destroy(&doc)
	compact, _, err := json.write(&doc)
	defer delete(compact)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(compact), src)
	pretty, _, perr := json.write(&doc, .Json, {indent = 1})
	defer delete(pretty)
	testing.expect_value(t, perr, nil)
	testing.expect_value(t, string(pretty), "{\n \"a\": [\n  \"é\\/x\",\n  \"😀\",\n  \"é\",\n  \"\\n\\\"\\\\\",\n  \"\\u00e9\\u0041\",\n  1E2\n ]\n}")
	jsonc, _ := json.build(transmute([]u8)string(`[/* \/ */ "\/"]`), .Jsonc)
	defer json.destroy(&jsonc)
	text, _, jerr := json.write(&jsonc, .Jsonc)
	defer delete(text)
	testing.expect_value(t, jerr, nil)
	testing.expect_value(t, string(text), `[/* \/ */"\/"]`)
}

// A JSONC line comment holding U+2028 or U+2029, which end a JSON5 line comment, is written as JSON5 as a block comment
// with the text as it was, so the text past them stays in the comment, and as JSONC as it was.
@(test)
document_line_separators_as_json5 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "[1 // a , 2 b\n]"
	doc, err := json.build(transmute([]u8)src, .Jsonc)
	defer json.destroy(&doc)
	if !testing.expect_value(t, err, nil) {
		return
	}
	text, _, werr := json.write(&doc, .Json5)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, string(text), "[1/* a\u2028, 2\u2029b*/]")
	again, rerr := json.build(text, .Json5)
	defer json.destroy(&again)
	testing.expect_value(t, rerr, nil)
	testing.expect_value(t, len(again.nodes), len(doc.nodes))
	testing.expect_value(t, len(again.facts), 1)
	kept, _, kerr := json.write(&doc, .Jsonc)
	defer delete(kept)
	testing.expect_value(t, kerr, nil)
	testing.expect_value(t, string(kept), "[1// a , 2 b\n]")
}

// A text with a comment, read under a raised depth, is written back at its full depth.
@(test)
document_deep_comment :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := strings.concatenate({strings.repeat("[", 5000, context.temp_allocator), "/* c */0", strings.repeat("]", 5000, context.temp_allocator)}, context.temp_allocator)
	doc, err := json.build(transmute([]u8)src, .Jsonc, {budget = {depth = 5000}})
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	text, _, werr := json.write(&doc, .Jsonc)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect(t, string(text) == src)
}

// Empty containers among scalars inside `levels` arrays, as many as fill the output more than once.
@(private = "file")
empty_rows_text :: proc(levels, n: int) -> []u8 {
	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< levels {
		strings.write_byte(&b, '[')
	}
	for i in 0 ..< n {
		strings.write_string(&b, "[]," if i % 2 == 1 else "1,")
	}
	strings.write_string(&b, `"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"`)
	for _ in 0 ..< levels {
		strings.write_byte(&b, ']')
	}
	return b.buf[:]
}

// An empty container the rare path opened closes before anything else is written, whatever room the output has after
// it. The walk of a JSON5 read is the model. A text past a sink's buffer or the hint of a wide indent reaches the rare
// path at an arbitrary row.
@(test)
document_empty_container_from_the_rare_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Sized :: struct {
		levels, n: int,
		opts:      json.Write_Options,
		sink:      bool,
	}
	cases := [?]Sized {
		{1, 40_000, {}, true},
		{1, 40_000, {indent = 2}, true},
		{20, 5_000, {indent = 16}, false},
		{40, 5_000, {indent = 16}, false},
	}
	for c in cases {
		text := empty_rows_text(c.levels, c.n)
		strict, serr := json.build(text, .Json, {}, context.temp_allocator)
		walked, werr := json.build(text, .Json5, {}, context.temp_allocator)
		testing.expectf(t, serr == nil && werr == nil, "%v: %v %v", c, serr, werr)
		want, _, err := json.write(&walked, .Json, c.opts)
		defer delete(want)
		testing.expect_value(t, err, nil)
		got: []u8
		if c.sink {
			got, err = sink_text(&strict, .Json, c.opts)
		} else {
			got, _, err = json.write(&strict, .Json, c.opts)
		}
		defer delete(got)
		testing.expectf(t, string(got) == string(want), "%v: %d bytes against %d", c, len(got), len(want))
		testing.expect_value(t, err, nil)
		free_all(context.temp_allocator)
	}
}

// A sink that fails is the error of the write, through the layout loop and the rows alike.
@(test)
document_write_to_a_failing_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	closed := io.Stream {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			return 0, .Permission_Denied if mode == .Write else .Unknown
		},
	}
	Case :: struct {
		src:  string,
		from: json.Spec,
	}
	for c in ([?]Case{{`[1,2]`, .Json}, {`[1,2]`, .Jsonc}, {"[1, /* c */ 2]", .Jsonc}, {"[1, /* c */ 2]", .Json5}}) {
		doc, err := json.build(transmute([]u8)c.src, c.from)
		defer json.destroy(&doc)
		testing.expect_value(t, err, nil)
		for to in json.Spec {
			_, werr := json.write_to(closed, &doc, to)
			testing.expectf(t, werr == json.Write_Error(io.Error.Permission_Denied), "%q as %v to %v: %v", c.src, c.from, to, werr)
		}
	}
}

// A CSV read with `infer` writes each cell as the null, boolean or number it reads as, and every other cell as a
// string, so the text is JSON whatever the cells hold.
@(test)
document_infers_cells :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a,b,c,d,e,f,g,h\n1,-2.50e3,true,false,,x,\"7\",0\n01,+1,.5,1.,0x1,NaN,-, 1\n"
	doc, err := dsv.build(transmute([]u8)src, .Csv, {format = dsv.Dsv_Options{infer = true}})
	defer dsv.destroy(&doc)
	if !testing.expect_value(t, err, nil) {
		return
	}
	text, _, werr := json.write(&doc)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, string(text), `[{"a":1,"b":-2.50e3,"c":true,"d":false,"e":null,"f":"x","g":"7","h":0},` +
		`{"a":"01","b":"+1","c":".5","d":"1.","e":"0x1","f":"NaN","g":"-","h":" 1"}]`)
	testing.expect_value(t, json.validate(text), nil)
}

// A CBOR document into JSON and CSV: a byte string is the base64 of its payload as a value, as it is as a key, and a
// number is its value in decimal, exact, whatever its size: a bignum, a decimal fraction, a negative integer down to
// -2^64, none a float spelling.
@(private = "file")
Binary_Case :: struct {
	cbor: []u8,
	json: string,
	csv:  string,
}

@(private = "file")
BINARY_CASES := []Binary_Case {
	{{0x41, 0x01}, `"AQ=="`, "AQ==\n"},
	{{0x40}, `""`, "\"\"\n"},
	{{0x82, 0x41, 0x01, 0x42, 0xff, 0x00}, `["AQ==","/wA="]`, "AQ==\n/wA=\n"},
	{{0x5f, 0x41, 0x01, 0x42, 0x02, 0x03, 0xff}, `"AQID"`, "AQID\n"},
	{{0xa1, 0x41, 0x01, 0x41, 0x02}, `{"AQ==":"Ag=="}`, "AQ==\nAg==\n"},
	{{0xc2, 0x49, 1, 0, 0, 0, 0, 0, 0, 0, 0}, "18446744073709551616", "18446744073709551616\n"},
	{{0xc3, 0x49, 1, 0, 0, 0, 0, 0, 0, 0, 0}, "-18446744073709551617", "-18446744073709551617\n"},
	{{0xc4, 0x82, 0x20, 0x03}, "3e-1", "3e-1\n"},
	{{0x3b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "-18446744073709551616", "-18446744073709551616\n"},
	{{0x3b, 0x80, 0, 0, 0, 0, 0, 0, 0}, "-9223372036854775809", "-9223372036854775809\n"},
	{{0x3b, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "-9223372036854775808", "-9223372036854775808\n"},
	{{0x3b, 0x80, 0, 0, 0, 0, 0, 0, 0x01}, "-9223372036854775810", "-9223372036854775810\n"},
	{{0x31}, "-18", "-18\n"},
	{{0x38, 0x33}, "-52", "-52\n"},
	{{0x82, 0x38, 0x33, 0x18, 0x31}, "[-52,49]", "-52\n49\n"},
	{{0x1b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}, "18446744073709551615", "18446744073709551615\n"},
	{{0xf9, 0x3c, 0x00}, "1.0", "1.0\n"},
}

@(test)
binary_documents_into_json_and_csv :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in BINARY_CASES {
		doc, err := cbor.build(c.cbor)
		if !testing.expectf(t, err == nil, "%x: %v", c.cbor, err) {
			continue
		}
		defer cbor.destroy(&doc)
		for spec in ([]json.Spec{.Json, .Jsonc, .Json5}) {
			text, _, werr := json.write(&doc, spec)
			testing.expectf(t, werr == nil && string(text) == c.json, "%x as %v: %q, %v, want %q", c.cbor, spec, text, werr, c.json)
			delete(text)
		}
		text, _, werr := dsv.write(&doc, .Csv)
		testing.expectf(t, werr == nil && string(text) == c.csv, "%x as CSV: %q, %v, want %q", c.cbor, text, werr, c.csv)
		delete(text)
	}
}

// Nothing an array of arrays writes as CSV has keys, so a header would read back as its first record.
@(test)
binary_array_of_arrays_into_csv_needs_no_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := cbor.build({0x82, 0x82, 0x01, 0x02, 0x82, 0x03, 0x04})
	testing.expect(t, err == nil)
	defer cbor.destroy(&doc)
	_, _, werr := dsv.write(&doc, .Csv)
	bad, is_bad := werr.(tape.Bad_Option)
	testing.expect(t, is_bad && bad.option == "no_header")
	text, _, werr2 := dsv.write(&doc, .Csv, {format = tape.Dsv_Options{no_header = true}})
	testing.expectf(t, werr2 == nil && string(text) == "1,2\n3,4\n", "%q, %v", text, werr2)
	delete(text)
}
