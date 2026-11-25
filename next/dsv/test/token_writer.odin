package dsv_tests

import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/ops/write"
import "stury:testkit"

// The token writer and record writer of a delimited text: the rows written as tokens or one record at a time are the
// table `write` writes of the same values.

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
