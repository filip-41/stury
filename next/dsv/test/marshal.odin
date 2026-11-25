package dsv_tests

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
