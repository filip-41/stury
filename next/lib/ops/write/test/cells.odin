package write_tests

import "base:runtime"
import "core:bytes"
import "core:io"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The delimited writer's cells: each spec spells a cell its own way, a comment byte, a byte-order mark and a delimiter
// at a line's start are guarded, a table written in another spec or from another format keeps its cells, and a
// write fails into a sink or an allocator without a trace.

@(private = "file")
Cells_Source :: enum {
	Csv,
	Tsv,
	Json,
	Json5,
	Jsonc,
}

@(private = "file")
Cells_Case :: struct {
	src:   string,
	from:  Cells_Source,
	read:  tape.Dsv_Options, // of a CSV source
	to:    dsv.Spec,
	d:     Maybe(tape.Dsv_Options), // the options written under, the document's own when nil
	want:  string,
	why:   Maybe(write.Refusal), // a refusal, which gives no text
	drops: bool, // facts the text does not hold
}

@(private = "file")
build_cells_source :: proc(c: Cells_Case) -> (doc: tape.Document, err: tape.Error) {
	src := transmute([]u8)c.src
	switch c.from {
	case .Csv:
		return dsv.build(src, .Csv, {format = c.read})
	case .Tsv:
		return dsv.build(src, .Tsv, {format = c.read})
	case .Json:
		return json.build(src, .Json)
	case .Json5:
		return json.build(src, .Json5)
	case .Jsonc:
		return json.build(src, .Jsonc)
	}
	return
}

@(private = "file")
expect_cells :: proc(t: ^testing.T, cases: []Cells_Case, loc := #caller_location) {
	for c in cases {
		doc, err := build_cells_source(c)
		defer dsv.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err, loc = loc) {
			continue
		}
		opts: write.Options
		if d, given := c.d.?; given {
			opts.format = d
		}
		text, dropped, werr := dsv.write(&doc, c.to, opts)
		defer delete(text)
		if why, refuses := c.why.?; refuses {
			r, refused := werr.(write.Refused)
			testing.expectf(t, text == nil && refused && r.why == why, "%q as %v %v: %q %v, want a refusal %v", c.src, c.to, c.d, text, werr, why, loc = loc)
			continue
		}
		testing.expectf(t, werr == nil && string(text) == c.want && (dropped != {}) == c.drops, "%q as %v %v: %q %v dropped %v, want %q dropped %v", c.src, c.to, c.d, text, werr, dropped, c.want, c.drops, loc = loc)
	}
}

// Each spec writes a cell its own way: CSV quotes what needs it, TSV escapes, Plain refuses what it cannot spell, an
// empty cell follows the spec, and a comment byte, a byte-order mark or a delimiter at a line's start is guarded.
@(test)
cells_follow_the_spec :: proc(t: ^testing.T) {
	testkit.deadline(t)
	none := tape.Dsv_Options{no_header = true}
	expect_cells(t, {
		{src = `[["a,b"],["q\"q"],["l\nl"],["plain"],["\r"],[" "]]`, from = .Json, to = .Csv, d = none, want = "\"a,b\"\n\"q\"\"q\"\n\"l\nl\"\nplain\n\"\r\"\n \n"},
		{src = `[["a\tb\nc\\d\u0000"]]`, from = .Json, to = .Tsv, d = none, want = "a\\tb\\nc\\\\d\\0\n"},
		{src = `[["a\\b\u0000"]]`, from = .Json, to = .Plain, d = none, want = "a\\b\x00\n"},
		{src = `[{"s":"a,b"}]`, from = .Json, to = .Plain, why = .No_Spelling},
		{src = `[{"s":"a\nb"}]`, from = .Json, to = .Plain, why = .No_Spelling},
		{src = `[{"s":"a;b"}]`, from = .Json, to = .Tsv, d = tape.Dsv_Options{delimiter = ';'}, why = .No_Spelling},
		{src = `[[null, "x"]]`, from = .Json, to = .Tsv, d = none, want = "\tx\n"},
		{src = `[["", "x"]]`, from = .Json, to = .Tsv, d = none, why = .No_Spelling},
		{src = `[["", "x"]]`, from = .Json, to = .Plain, d = none, why = .No_Spelling},
		{src = `[["", "x"]]`, from = .Json, to = .Csv, d = none, want = "\"\",x\n"},
		{src = `[{"s":""}]`, from = .Json, to = .Tsv, why = .No_Spelling},
		{src = `[[""]]`, from = .Json, to = .Csv, d = none, want = "\"\"\n"},
		{src = `[["#x"]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, comment = '#'}, want = "\"#x\"\n"},
		{src = `[["a"],["#x"]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, comment = '#'}, want = "a\n\"#x\"\n"},
		{src = `[["x#"]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, comment = '#'}, want = "x#\n"},
		{src = `[["#x"]]`, from = .Json, to = .Plain, d = tape.Dsv_Options{no_header = true, comment = '#'}, why = .No_Spelling},
		{src = `[["\tx"]]`, from = .Json, to = .Tsv, d = tape.Dsv_Options{no_header = true, delimiter = ';', comment = '\t'}, want = "\\tx\n"},
		{src = `[["\ufeffx"]]`, from = .Json, to = .Csv, d = none, want = "\"\xEF\xBB\xBFx\"\n"},
		{src = `[["\ufeffx"]]`, from = .Json, to = .Tsv, d = none, why = .No_Spelling},
		{src = `[["a"],["\ufeffx"]]`, from = .Json, to = .Csv, d = none, want = "a\n\xEF\xBB\xBFx\n"},
		{src = `[["1"]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, delimiter = '1'}, want = "\"1\"\n"},
		{src = `[[1]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, delimiter = '1'}, why = .No_Spelling},
		{src = `[{"n":1}]`, from = .Json, to = .Plain, d = tape.Dsv_Options{delimiter = '1'}, why = .No_Spelling},
		{src = `[["12"]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, comment = '1'}, want = "\"12\"\n"},
		{src = `[[12]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, comment = '1'}, why = .No_Spelling},
		{src = `[[Infinity]]`, from = .Json5, to = .Csv, d = none, why = .No_Spelling},
		{src = `[["a","b"],["c"]]`, from = .Json, to = .Csv, d = none, why = .Row_Keys},
	})
	long := strings.repeat(`x,\"`, 700, context.temp_allocator)
	doc, err := json.build(transmute([]u8)strings.concatenate({`[["`, long, `"]]`}, context.temp_allocator))
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	text, _, werr := dsv.write(&doc, .Csv, {format = none})
	defer delete(text)
	testing.expect_value(t, werr, nil)
	testing.expect_value(t, len(text), 2 + 700 * 4 + 1)
}

// A document written in its own spec or another's: a table keeps its cells, a JSON5 number is written as JSON writes
// it, a comment goes where the target holds one with its comment byte and is dropped, and reported, where it holds
// none, and the end of each line is `crlf`'s.
@(test)
cells_of_documents_in_each_spec :: proc(t: ^testing.T) {
	testkit.deadline(t)
	commented := "#top\na,b\n#one\n1,2\n#two\n3,4\n#foot\n"
	expect_cells(t, {
		{src = "# c\nid;name\n1;\"a;b\"\n2;\n", read = {delimiter = ';', comment = '#'}, to = .Csv, want = "# c\nid;name\n1;\"a;b\"\n2;\n"},
		{src = "a,b\n1,\"x,y\"\n", to = .Tsv, want = "a\tb\n1\tx,y\n"},
		{src = "# c\na\n1\n", read = {comment = '#'}, to = .Csv, want = "# c\na\n1\n"},
		{src = `[{"a":-0x10,"b":0}]`, from = .Json5, to = .Csv, want = "a,b\n-16,0\n"},
		{src = `[{a:-0x10,b:+1,c:.5,d:5.,e:0X1F,f:1.50}]`, from = .Json5, to = .Csv, want = "a,b,c,d,e,f\n-16,1,0.5,5.0,31,1.50\n"},
		{src = `[{a:-0x10,b:+1}]`, from = .Json5, to = .Csv, d = tape.Dsv_Options{comment = '-'}, why = .No_Spelling},
		{src = `[{a:+1,b:.5}]`, from = .Json5, to = .Csv, d = tape.Dsv_Options{delimiter = '.'}, why = .No_Spelling},
		{src = `[[1,"a"],[2,"b"]]`, from = .Json, to = .Tsv, d = tape.Dsv_Options{no_header = true}, want = "1\ta\n2\tb\n"},
		{src = commented, read = {comment = '#'}, to = .Csv, want = commented},
		{src = commented, read = {comment = '#'}, to = .Tsv, d = tape.Dsv_Options{comment = ';'}, want = ";top\na\tb\n;one\n1\t2\n;two\n3\t4\n;foot\n"},
		{src = commented, read = {comment = '#'}, to = .Csv, d = tape.Dsv_Options{}, want = "a,b\n1,2\n3,4\n", drops = true},
		{src = "// top\n[ // one\n {\"a\": 1}, /* inline */\n {\"a\": 2 /* cell */}\n// foot\n]\n", from = .Jsonc, to = .Csv, d = tape.Dsv_Options{comment = '#'}, want = "# top\na\n# one\n1\n2\n# foot\n", drops = true},
		{src = "1\n#two\n2\n#foot\n", read = {comment = '#', no_header = true}, to = .Csv, want = "1\n#two\n2\n#foot\n"},
	})
}

// A CSV written with `crlf` ends each line with CR LF and leaves a line end inside a quoted cell as it was.
@(test)
cells_end_each_line_by_crlf :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_cells(t, {
		{src = "a,b\n1,2\n", to = .Csv, d = tape.Dsv_Options{crlf = true}, want = "a,b\r\n1,2\r\n"},
		{src = "a,b\r\n1,2\r\n", to = .Csv, d = tape.Dsv_Options{crlf = true}, want = "a,b\r\n1,2\r\n"},
		{src = "\"a\r\nb\",c\n1,2\n", to = .Csv, d = tape.Dsv_Options{crlf = true}, want = "\"a\r\nb\",c\r\n1,2\r\n"},
		{src = "a,b\n\"x\ny\",2\n", to = .Csv, d = tape.Dsv_Options{crlf = true}, want = "a,b\r\n\"x\ny\",2\r\n"},
		{src = "#c\na,b\n1,2\n", read = {comment = '#'}, to = .Csv, d = tape.Dsv_Options{comment = '#', crlf = true}, want = "#c\r\na,b\r\n1,2\r\n"},
		{src = `[[1,2],[3,4]]`, from = .Json, to = .Csv, d = tape.Dsv_Options{no_header = true, crlf = true}, want = "1,2\r\n3,4\r\n"},
		{src = "a\tb\n1\t2\n", from = .Tsv, to = .Tsv, d = tape.Dsv_Options{crlf = true}, want = "a\tb\r\n1\t2\r\n"},
	})
}

// A cell an inferring read would take for another kind is quoted, and a cell it infers keeps its text.
@(test)
cells_follow_infer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	inferred := "a,b,c,d\n1,\"2\",true,\"false\"\n,x,1e2,\"\"\n"
	expect_cells(t, {
		{src = inferred, read = {infer = true}, to = .Csv, want = inferred},
		{src = inferred, read = {infer = true}, to = .Csv, d = tape.Dsv_Options{}, want = "a,b,c,d\n1,2,true,false\n,x,1e2,\"\"\n"},
		{src = inferred, to = .Csv, d = tape.Dsv_Options{infer = true}, want = "a,b,c,d\n\"1\",\"2\",\"true\",\"false\"\n,x,\"1e2\",\"\"\n"},
		{src = "a,b\n1,x\n", to = .Tsv, d = tape.Dsv_Options{infer = true}, why = .No_Spelling},
		{src = `[{"a": "2", "b": 2, "c": "true", "d": false}]`, from = .Json, to = .Csv, d = tape.Dsv_Options{infer = true}, want = "a,b,c,d\n\"2\",2,\"true\",false\n"},
	})
}

// An empty column name alone in a header would be a blank line where a spec has no spelling for it, and the first
// record would read as the header.
@(test)
cells_header_of_one_empty_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string(`[{"":"x"}]`))
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil)
	for spec in ([?]dsv.Spec{.Tsv, .Plain}) {
		text, _, werr := dsv.write(&doc, spec)
		r, refused := werr.(write.Refused)
		testing.expectf(t, text == nil && refused && r.why == .No_Spelling, "%v: %q %v", spec, text, werr)
	}
	text, _, werr := dsv.write(&doc, .Csv)
	defer delete(text)
	testing.expect_value(t, werr, nil)
	back, berr := dsv.build(text, .Csv)
	defer dsv.destroy(&back)
	testing.expect_value(t, berr, nil)
	records, _, _ := dsv.length(dsv.Reader{&back, nil}, dsv.ROOT, context.allocator)
	testing.expect_value(t, records, 1)
}

// A write that fails into a sink or is refused gives no text, and the error is the sink's or the refusal's.
@(test)
cells_failed_write_gives_its_error :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := dsv.build(transmute([]u8)string("# c\na\n1\n"), .Csv, {format = tape.Dsv_Options{comment = '#'}})
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	text, dropped, kerr := dsv.write(&doc, .Csv, {format = tape.Dsv_Options{}})
	defer delete(text)
	testing.expect_value(t, kerr, nil)
	testing.expect_value(t, string(text), "a\n1\n")
	testing.expect_value(t, dropped, tape.Facts{.Comment})
	closed := io.Stream {
		procedure = proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (i64, io.Error) {
			return 0, .Permission_Denied if mode == .Write else .Unknown
		},
	}
	_, serr := dsv.write_to(closed, &doc, .Csv, {format = tape.Dsv_Options{}})
	testing.expect_value(t, serr, dsv.Write_Error(io.Error.Permission_Denied))
	refusing, _ := json.build(transmute([]u8)string("// c\n[{\"a\":1},{\"a\":[1]}]"), .Jsonc)
	defer json.destroy(&refusing)
	none, _, rerr := dsv.write(&refusing, .Csv, {format = tape.Dsv_Options{comment = '#'}})
	r, refused := rerr.(write.Refused)
	testing.expectf(t, none == nil && refused && r.why == .Not_A_Table, "%q %v", none, rerr)
}

// A write into a sink gives the bytes of the text in memory, in the read spec and in another.
@(test)
cells_stream_to_a_sink :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := dsv.build(transmute([]u8)string("a,b\n1,\"x,y\"\n"), .Csv)
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	for c in ([?][2]string{{"", "a,b\n1,\"x,y\"\n"}, {"tsv", "a\tb\n1\tx,y\n"}}) {
		spec := dsv.Spec.Tsv if c[0] == "tsv" else .Csv
		sink: bytes.Buffer
		defer bytes.buffer_destroy(&sink)
		_, serr := dsv.write_to(bytes.buffer_to_stream(&sink), &doc, spec)
		testing.expect_value(t, serr, nil)
		testing.expect_value(t, string(bytes.buffer_to_bytes(&sink)), c[1])
	}
	_, zerr := dsv.write_to({}, &doc)
	testing.expect_value(t, zerr, dsv.Write_Error(tape.Bad_Option{"sink"}))
}

// A table of more rows than a sink's buffer holds is written through each refill, and is the text a buffer write gives.
@(test)
cells_written_through_each_refill :: proc(t: ^testing.T) {
	testkit.deadline(t)
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "id,name\n")
	for i in 0 ..< 20000 {
		strings.write_int(&b, i)
		strings.write_string(&b, ",\"a,b \"\"q\"\"\"\n" if i % 3 == 0 else ",plain\n")
	}
	doc, err := dsv.build(transmute([]u8)strings.to_string(b))
	defer dsv.destroy(&doc)
	testing.expect_value(t, err, nil)
	for spec in dsv.Spec {
		want, _, werr := dsv.write(&doc, spec)
		defer delete(want)
		sink: bytes.Buffer
		defer bytes.buffer_destroy(&sink)
		_, serr := dsv.write_to(bytes.buffer_to_stream(&sink), &doc, spec)
		if spec == .Plain {
			testing.expectf(t, serr != nil && werr != nil, "plain: %v %v", serr, werr)
			continue
		}
		testing.expect_value(t, werr, nil)
		testing.expect_value(t, serr, nil)
		testing.expectf(t, string(bytes.buffer_to_bytes(&sink)) == string(want), "%v: %d bytes against %d", spec, bytes.buffer_length(&sink), len(want))
	}
}

// A cell that ends at an unmapped page is written as it is when it is copied elsewhere: no read passes its last byte.
@(test)
cells_at_the_end_of_a_page :: proc(t: ^testing.T) {
	testkit.deadline(t)
	fence: Fence
	defer fence_release(&fence)
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
			quoted: [dynamic]u8
			append(&quoted, "h\n\"")
			for c in body {
				append(&quoted, c)
				if c == '"' {
					append(&quoted, '"')
				}
			}
			append(&quoted, '"')
			plain_source := strings.concatenate({"h\n", string(body)}, context.temp_allocator)
			for source, k in ([2]string{string(quoted[:]), plain_source}) {
				heap, herr := dsv.build(transmute([]u8)source)
				fenced, ferr := dsv.build(fence_copy(&fence, transmute([]u8)source))
				if herr != nil || ferr != nil {
					testing.expectf(t, (herr == nil) == (ferr == nil), "%q: %v %v", source, herr, ferr)
					dsv.destroy(&heap)
					dsv.destroy(&fenced)
					continue
				}
				for spec in dsv.Spec {
					want, _, werr := dsv.write(&heap, spec)
					got, _, gerr := dsv.write(&fenced, spec)
					testing.expectf(t, werr == gerr && string(got) == string(want), "source %d of %q as %v: %q %v, want %q %v", k, body, spec, got, gerr, want, werr)
					delete(want)
					delete(got)
				}
				dsv.destroy(&heap)
				dsv.destroy(&fenced)
			}
			delete(quoted)
			free_all(context.temp_allocator)
		}
	}
}

@(private = "file")
Cells_Run :: struct {
	doc:  ^tape.Document,
	spec: dsv.Spec,
	sink: bool,
}

// Every allocation of a delimited write may be refused, into a buffer and into a sink, and none is kept.
@(test)
cells_under_failing_allocators :: proc(t: ^testing.T) {
	testkit.deadline(t)
	long := strings.repeat("k", 600, context.temp_allocator)
	headed, herr := dsv.build(transmute([]u8)string("a,b\n1,\"x y\"\n2,3\n"))
	defer dsv.destroy(&headed)
	testing.expect_value(t, herr, nil)
	commented, cerr := dsv.build(transmute([]u8)string("# t\na,b\n# r\n1,\"x\ny\"\n"), .Csv, {format = tape.Dsv_Options{comment = '#'}})
	defer dsv.destroy(&commented)
	testing.expect_value(t, cerr, nil)
	src := strings.concatenate({`[{"`, long, `":1,"b":"`, long, `"},{"`, long, `":2,"b":null}]`}, context.temp_allocator)
	alien, aerr := json.build(transmute([]u8)src)
	defer json.destroy(&alien)
	testing.expect_value(t, aerr, nil)
	docs := [?]^tape.Document{&headed, &commented, &alien}
	for doc in docs {
		for spec in ([?]dsv.Spec{.Csv, .Tsv}) {
			for sink in ([]bool{false, true}) {
				run := Cells_Run{doc, spec, sink}
				s := testkit.sweep_failures(proc(data: rawptr, a: runtime.Allocator) {
						r := (^Cells_Run)(data)
						if r.sink {
							taken: bytes.Buffer
							defer bytes.buffer_destroy(&taken)
							_, err := dsv.write_to(bytes.buffer_to_stream(&taken), r.doc, r.spec, {}, a)
							if err != nil {
								_ = err.(runtime.Allocator_Error)
							}
							return
						}
						text, _, err := dsv.write(r.doc, r.spec, {}, a)
						if err == nil {
							delete(text, a)
						} else {
							_ = err.(runtime.Allocator_Error)
						}
					}, &run)
				testing.expectf(t, s.bad == 0 && s.refused >= 1, "%v a sink %v: %v", spec, sink, s)
			}
		}
	}
}
