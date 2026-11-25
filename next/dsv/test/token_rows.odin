package dsv_tests

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"

// The rows of a delimited text written as they come, under the header of the first row or the caller's.

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
	refused, ok := err.(write.Refused)
	testing.expectf(t, ok && refused.why == .Row_Keys && refused.node == 13, "%v %q", err, text)
}

@(test)
a_header_given_heads_the_rows :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for header, k in ([?][]string{{"b", "a"}, {"a", "b"}}) {
		w: dsv.Writer
		testing.expect(t, dsv.writer_start(&w, .Csv, {}, {}, context.allocator, header) == nil)
		for step in ([?]struct {
			kind: write.Token_Kind,
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
	testing.expect(t, dsv.writer_start(&w, .Csv, {}, {}, context.allocator, {"a", "b"}) == nil)
	testing.expect(t, dsv.token(&w, .Array) == nil && dsv.token(&w, .Close) == nil)
	text, err := dsv.writer_end(&w)
	defer delete(text)
	testing.expectf(t, err == nil && string(text) == "a,b\n", "%v %q", err, text)
	testing.expect(t, dsv.writer_start(&w, .Csv, {}, {}, context.allocator, {"a", "a"}) == tape.Bad_Option{"header"})
	testing.expect(t, dsv.writer_start(&w, .Csv, {grow_header = true}, {}, context.allocator, {"a"}) == tape.Bad_Option{"header"})
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
