package dsv_tests

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// Delimited text writers: marshal, token/record writer, header/batch streaming, and writer laws.

@(private = "file")
Row :: struct {
	id:   int,
	name: string `csv:"who"`,
}

@(test)
rows_marshal_under_one_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	rows := []Row{{1, "a,b"}, {2, "c"}}
	text, err := dsv.marshal(&rows)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "id,who\n1,\"a,b\"\n2,c\n", "%v\n%s", err, text)
	tsv, terr := dsv.marshal(&rows, .Tsv)
	defer delete(tsv)
	testing.expectf(t, terr == nil && string(tsv) == "id\twho\n1\ta,b\n2\tc\n", "%v\n%s", terr, tsv)
}

@(test)
marshal_lines_error_aborts_without_leak_or_flush :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Bad :: struct {
		x: f64,
	}
	bad := Bad{x = math.nan_f64()}
	text, err := dsv.marshal(&bad, .Csv, {framing = .Lines})
	testing.expect(t, err != nil)
	testing.expect(t, text == nil)

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	serr := dsv.marshal_to(strings.to_writer(&sb), &bad, .Csv, {framing = .Lines})
	testing.expect(t, serr != nil)
	testing.expect_value(t, strings.builder_len(sb), 0)
}

@(test)
tokens_write_the_table_of_a_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Csv, {grow_header = true}) == nil)
	for step in ([?]struct {
		kind: write.Token_Kind,
		text: string,
	}{{.Array, ""}, {.Object, ""}, {.Key, "a"}, {.Number, "1"}, {.Key, "b"}, {.String, "x,y"}, {.Close, ""}, {.Object, ""}, {.Key, "b"}, {.Null, ""}, {.Key, "c"}, {.True, ""}, {.Close, ""}, {.Close, ""}}) {
		testing.expect(t, dsv.token(&w, step.kind, step.text) == nil)
	}
	text, err := dsv.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "a,b,c\n1,\"x,y\",\n,,true\n", "%v\n%s", err, text)
}

@(test)
records_write_rows_under_one_header :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Tsv, {framing = .Lines, grow_header = true}) == nil)
	for src in ([?]string{`{"a":1,"b":"x"}`, `{"a":2,"b":"y\tz"}`, `{"b":"w","c":3}`}) {
		doc, err := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expect(t, err == nil && dsv.put(&w, &doc) == nil)
	}
	text, err := dsv.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "a\tb\tc\n1\tx\t\n2\ty\\tz\t\n\tw\t3\n", "%v\n%s", err, text)
}

@(test)
a_malformed_sequence_is_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w) == nil)
	testing.expect(t, dsv.token(&w, .Close) != nil)
	testing.expect(t, dsv.token(&w, .Array) == nil)
	_, err := dsv.writer_end(&w)
	refused, ok := err.(write.Refused)
	testing.expect(t, ok && refused.why == .Malformed)
}

@(test)
rows_are_written_under_the_first_rows_keys :: proc(t: ^testing.T) {
	testkit.deadline(t)
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Csv, {framing = .Lines}) == nil)
	for src in ([?]string{`{"a":1,"b":"x"}`, `{"b":"y"}`, `{"b":"w","a":3}`, `{"a":1,"c":2}`}) {
		doc, err := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expect(t, err == nil && dsv.put(&w, &doc) == nil)
	}
	// A key the header lacks has no column, which the end of the writer refuses.
	text, err := dsv.writer_end(&w)
	defer delete(text)
	refused, ok := err.(dsv.Refused)
	testing.expectf(t, ok && refused.why == .Row_Keys && refused.node == 13, "%v %q", err, text)
}

@(test)
a_header_given_heads_the_rows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for header, k in ([?][]string{{"b", "a"}, {"a", "b"}}) {
		w: dsv.Writer
		testing.expect(t, dsv.writer_start(&w, .Csv, {header = header}) == nil)
		for step in ([?]struct {
			kind: dsv.Token_Kind,
			text: string,
		}{{.Array, ""}, {.Object, ""}, {.Key, "a"}, {.Number, "1"}, {.Key, "b"}, {.String, "x"}, {.Close, ""}, {.Object, ""}, {.Key, "a"}, {.Number, "2"}, {.Close, ""}, {.Close, ""}}) {
			testing.expect(t, dsv.token(&w, step.kind, step.text) == nil)
		}
		text, err := dsv.writer_end(&w)
		defer delete(text)
		want := [?]string{"b,a\nx,1\n,2\n", "a,b\n1,x\n2,\n"}
		testing.expectf(t, err == nil && string(text) == want[k], "%d: %v %q", k, err, text)
	}
	// A header with no row is the header's line.
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Csv, {header = {"a", "b"}}) == nil)
	testing.expect(t, dsv.token(&w, .Array) == nil && dsv.token(&w, .Close) == nil)
	text, err := dsv.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "a,b\n", "%v %q", err, text)
	testing.expect(t, dsv.writer_start(&w, .Csv, {header = {"a", "a"}}) == dsv.Bad_Option{"header"})
	testing.expect(t, dsv.writer_start(&w, .Csv, {grow_header = true, header = {"a"}}) == dsv.Bad_Option{"header"})
}

@(test)
lines_framing_handles_array_rows_and_empty_streams :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Empty `.Lines` stream with no header yields empty text (not Malformed).
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Csv, {framing = .Lines}) == nil)
	empty, eerr := dsv.writer_end(&w)
	defer delete(empty)
	testing.expectf(t, eerr == nil && len(empty) == 0, "empty lines: %v %q", eerr, empty)

	// Empty `.Lines` stream with explicit header yields just the header line.
	testing.expect(t, dsv.writer_start(&w, .Csv, {framing = .Lines, header = {"x", "y"}}) == nil)
	hdr_only, herr := dsv.writer_end(&w)
	defer delete(hdr_only)
	testing.expectf(t, herr == nil && string(hdr_only) == "x,y\n", "header lines: %v %q", herr, hdr_only)

	// `.Lines` with array rows (`no_header = true`) must NOT strip the first array as `rows_root`.
	testing.expect(t, dsv.writer_start(&w, .Csv, {framing = .Lines, format = dsv.Dsv_Options{no_header = true}}) == nil)
	for row in ([?]string{`[1,"a,b"]`, `[2,"c"]`}) {
		doc, derr := json.build(transmute([]u8)row)
		defer json.destroy(&doc)
		testing.expect(t, derr == nil && dsv.put(&w, &doc) == nil)
	}
	rows_out, rerr := dsv.writer_end(&w)
	defer delete(rows_out)
	testing.expectf(t, rerr == nil && string(rows_out) == "1,\"a,b\"\n2,c\n", "array lines: %v %q", rerr, rows_out)

	// Unsupported options on `dsv.write` are refused with `Bad_Option`.
	doc, _ := dsv.build(transmute([]u8)string("a\n1\n"))
	defer dsv.destroy(&doc)
	for bad in ([?]dsv.Write_Options{{indent = 2}, {tab = true}, {ascii = true}, {framing = .Lines}, {header = {"a"}}}) {
		_, _, err := dsv.write(&doc, .Csv, bad)
		_, is_bad := err.(dsv.Bad_Option)
		testing.expectf(t, is_bad, "expected Bad_Option for %v, got %v", bad, err)
	}
}

@(test)
rows_in_many_batches_are_the_table_of_the_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	strings.write_string(&text, "[")
	for i in 0 ..< 100000 {
		if i > 0 {
			strings.write_string(&text, ",")
		}
		if i % 7 == 3 {
			fmt.sbprintf(&text, `{{"id":%d,"name":"n, %d"}}`, i, i)
		} else {
			fmt.sbprintf(&text, `{{"id":%d,"name":"n%d","tag":"t%d"}}`, i, i, i % 5)
		}
	}
	strings.write_string(&text, "]")
	doc, err := json.build(transmute([]u8)strings.to_string(text))
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	want, _, werr := dsv.write(&doc, .Csv)
	defer delete(want)
	testing.expect(t, werr == nil)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	allocator := mem.tracking_allocator(&track)
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Csv, {}, {}, allocator) == nil)
	testing.expect(t, dsv.put(&w, &doc) == nil)
	got, gerr := dsv.writer_end(&w)
	testing.expectf(t, gerr == nil && string(got) == string(want), "%v", gerr)
	delete(got, allocator)
	// A sink holds no more than a batch of the rows, whichever their count.
	sink := strings.builder_make()
	defer strings.builder_destroy(&sink)
	track.peak_memory_allocated = 0
	testing.expect(t, dsv.writer_start(&w, .Csv, {}, strings.to_writer(&sink), allocator) == nil)
	testing.expect(t, dsv.put(&w, &doc) == nil)
	_, gerr = dsv.writer_end(&w)
	testing.expectf(t, gerr == nil && strings.to_string(sink) == string(want), "%v", gerr)
	testing.expectf(t, int(track.peak_memory_allocated) < len(want) / 4, "peak %d of %d bytes", track.peak_memory_allocated, len(want))
}

@(private = "file")
FIXTURES :: #directory + "../../../bench/fixtures/"

@(private = "file")
SAMPLES := [?]string{
	"id,name\n1,x\n2,\"y,z\"\n",
	"a,b,c\n1,,3\n\"\",\"q\"\"r\",\"two\nlines\"\n",
	"\xEF\xBB\xBFid\n1\n",
	"a\n\n1\n",
	"x,y\n\"1\",2\n",
}

@(test)
samples_and_fixtures_write_and_read_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	texts := make([dynamic]string, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for s, i in SAMPLES {
		append(&texts, s)
		append(&names, fmt.tprintf("sample %d", i))
	}
	for name in ([?]string{"table.csv", "wide.csv", "table.tsv"}) {
		src, err := os.read_entire_file_from_path(strings.concatenate({FIXTURES, name}, context.temp_allocator), context.temp_allocator)
		if err == nil {
			append(&texts, string(src))
			append(&names, name)
		}
	}
	for text, i in texts {
		for from in ([?]dsv.Spec{.Csv, .Tsv}) {
			doc, err := dsv.build(transmute([]u8)text, from, allocator = context.temp_allocator)
			if err != nil {
				continue
			}
			for to in ([?]dsv.Spec{.Csv, .Tsv}) {
				out, _, werr := dsv.write(&doc, to, allocator = context.temp_allocator)
				if werr != nil {
					continue
				}
				back, berr := dsv.build(out, to, allocator = context.temp_allocator)
				if !testing.expectf(t, berr == nil, "%s from %v to %v: %v", names[i], from, to, berr) {
					continue
				}
				testkit.values_agree(t, &doc, tape.ROOT, &back, tape.ROOT, {}, names[i])
			}
		}
	}
}

// The texts v1 writes of `[{"a":1,"b":"x,y"},{"a":2.5,"b":"q\"r"},{"a":true,"b":null}]` as `--to csv` and `--to tsv`, and
// of `[["a","b,c"],[1,null],[2.5,"q\"z"]]`, which has no keys to name a header.
@(test)
the_texts_are_v1s :: proc(t: ^testing.T) {
	testkit.deadline(t)
	objects, _ := json.build(transmute([]u8)string(`[{"a":1,"b":"x,y"},{"a":2.5,"b":"q\"r"},{"a":true,"b":null}]`))
	defer json.destroy(&objects)
	cells, _ := json.build(transmute([]u8)string(`[["a","b,c"],[1,null],[2.5,"q\"z"]]`))
	defer json.destroy(&cells)
	csv, _, _ := dsv.write(&objects, .Csv)
	defer delete(csv)
	testing.expectf(t, string(csv) == "a,b\n1,\"x,y\"\n2.5,\"q\"\"r\"\ntrue,\n", "%q", csv)
	tsv, _, _ := dsv.write(&objects, .Tsv)
	defer delete(tsv)
	testing.expectf(t, string(tsv) == "a\tb\n1\tx,y\n2.5\tq\"r\ntrue\t\n", "%q", tsv)
	rows, _, err := dsv.write(&cells, .Csv, {format = tape.Dsv_Options{no_header = true}})
	defer delete(rows)
	testing.expectf(t, err == nil && string(rows) == "a,\"b,c\"\n1,\n2.5,\"q\"\"z\"\n", "%v %q", err, rows)
	// The rows written as they come are the same text.
	w: dsv.Writer
	testing.expect(t, dsv.writer_start(&w, .Csv, {framing = .Lines}) == nil)
	for src in ([?]string{`{"a":1,"b":"x,y"}`, `{"a":2.5,"b":"q\"r"}`, `{"a":true,"b":null}`}) {
		doc, _ := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expect(t, dsv.put(&w, &doc) == nil)
	}
	streamed, serr := dsv.writer_end(&w)
	defer delete(streamed)
	testing.expectf(t, serr == nil && string(streamed) == string(csv), "%v %q", serr, streamed)
}

// Rows written into a sink that takes a few bytes at a time, across the batches the writer ends, are the text a buffer
// holds, whatever the size of a piece.
@(test)
rows_written_in_pieces_are_the_same_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.builder_make()
	defer strings.builder_destroy(&text)
	for i in 0 ..< 3000 {
		fmt.sbprintf(&text, "%d,\"n, %d\",\n", i, i)
	}
	src := strings.concatenate({"id,name,note\n", strings.to_string(text)})
	defer delete(src)
	doc, err := dsv.build(transmute([]u8)src)
	defer dsv.destroy(&doc)
	testing.expect(t, err == nil)
	want, _, _ := dsv.write(&doc, .Tsv)
	defer delete(want)
	for limit in ([?]int{1, 5, 4097}) {
		c: testkit.Chunked
		defer testkit.chunked_destroy(&c)
		w: dsv.Writer
		testing.expect(t, dsv.writer_start(&w, .Tsv, {}, testkit.chunked_sink(&c, limit)) == nil)
		testing.expect(t, dsv.put(&w, &doc) == nil)
		_, werr := dsv.writer_end(&w)
		testing.expectf(t, werr == nil && string(c.taken[:]) == string(want), "pieces of %d: %v", limit, werr)
	}
}
