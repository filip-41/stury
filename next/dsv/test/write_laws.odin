package dsv_tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// The writer's laws: a delimited text, a bench fixture or a sample, written in either spec reads back as the same
// table, and the rows written as they come into a sink that takes a few bytes at a time are the text a buffer holds.
// And the texts v1 writes of the same values are the texts written here.

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
