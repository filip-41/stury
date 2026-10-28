package csv_tests

import "core:testing"
import csv "../"

// Objects under the first object's keys; a key the header lacks is refused, and a refused record leaves the
// table and the text as they were.
@(test)
test_table_objects :: proc(t: ^testing.T) {
	tab := csv.table_make({sort_keys = true})
	defer csv.destroy(&tab)
	out: [dynamic]u8
	defer delete(out)
	testing.expect_value(t, csv.table_object(&tab, &out, {"b", "a"}, {"1", "x,y"}), nil)
	testing.expect_value(t, csv.table_object(&tab, &out, {"a"}, {nil}), nil)
	testing.expect_value(t, string(out[:]), "a,b\n\"x,y\",1\n,\n")
	testing.expect_value(t, csv.table_object(&tab, &out, {"a", "c"}, {"1", "2"}), csv.Table_Error{kind = .Unknown_Key, key = 1})
	testing.expect_value(t, csv.table_row(&tab, &out, {"1"}), csv.Table_Error{kind = .Mixed_Shapes})

	first := csv.table_make()
	defer csv.destroy(&first)
	clear(&out)
	err := csv.table_object(&first, &out, {"a"}, {nil})
	testing.expect_value(t, err, csv.Table_Error{kind = .Unwritable, record = .Unwritable})
	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, first.shape, csv.Table_Shape.Unset)
	testing.expect_value(t, csv.table_object(&first, &out, {"b"}, {"2"}), nil)
	testing.expect_value(t, string(out[:]), "b\n2\n")
}

// A growing table holds its records and writes them under the header of every key at the end, one part a call.
@(test)
test_table_grows :: proc(t: ^testing.T) {
	tab := csv.table_make({sort_keys = true}, grow = true)
	defer csv.destroy(&tab)
	out: [dynamic]u8
	defer delete(out)
	testing.expect_value(t, csv.table_object(&tab, &out, {"b", "a"}, {"1", "2"}), nil)
	testing.expect_value(t, csv.table_object(&tab, &out, {"c", "a"}, {"3", "4"}), nil)
	testing.expect_value(t, len(out), 0)
	parts := 0
	for {
		more, err := csv.table_finish(&tab, &out)
		testing.expect_value(t, err, nil)
		if !more {
			break
		}
		parts += 1
	}
	testing.expect_value(t, parts, 3)
	testing.expect_value(t, string(out[:]), "a,b,c\n2,1,\n4,,3\n")
	// Finished, it writes as a table that does not grow.
	testing.expect_value(t, csv.table_object(&tab, &out, {"c"}, {"5"}), nil)
	testing.expect_value(t, string(out[len(out) - 3:]), ",5\n")
}

// Rows of cells are written as they are, and a table of rows takes no object.
@(test)
test_table_rows :: proc(t: ^testing.T) {
	tab := csv.table_make({dialect = csv.TSV})
	defer csv.destroy(&tab)
	out: [dynamic]u8
	defer delete(out)
	testing.expect_value(t, csv.table_row(&tab, &out, {"1", "a\tb"}), nil)
	testing.expect_value(t, string(out[:]), "1\ta\\tb\n")
	testing.expect_value(t, csv.table_object(&tab, &out, {"a"}, {"1"}), csv.Table_Error{kind = .Mixed_Shapes})
}
