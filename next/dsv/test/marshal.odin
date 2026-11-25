package dsv_tests

import "core:math"
import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:testkit"

// Typed writes: a list of structs written as a delimited text has a header once and a row for each.

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
