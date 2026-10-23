package csv_tests

import "core:testing"
import csv "../"

@(test)
test_duplicate_header_names :: proc(t: ^testing.T) {
	// The default refuses the repeat, at its header cell.
	rows: []Strict
	err := read(t, "id,name,id\n1,a,2\n", &rows)
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Duplicate_Key)
	testing.expect_value(t, err.?.offset, 8)
	testing.expect_value(t, path_text(err.?), ".id")
	testing.expect(t, rows == nil, "a header refusal leaves the destination")
	err = read(t, "id,\"id\"\n1,2\n", &rows, {duplicates = .Refuse})
	testing.expect_value(t, err.?.offset, 3)

	testing.expect_value(t, read(t, "id,name,id\n1,a,2\n", &rows, {duplicates = .First}), nil)
	testing.expect_value(t, rows[0], Strict{1, "a"})
	testing.expect_value(t, read(t, "id,name,id\n1,a,2\n", &rows, {duplicates = .Last}), nil)
	testing.expect_value(t, rows[0], Strict{2, "a"})

	// The column a policy leaves out is read as unknown: its cells are checked as CSV and not read.
	testing.expect_value(t, read(t, "id,id\n1,not a number\n", &rows, {duplicates = .First}), nil)
	testing.expect_value(t, rows[0].id, 1)
	err = read(t, "id,id\n1,not a number\n", &rows, {duplicates = .Last})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, err.?.offset, 8)
	testing.expect_value(t, path_text(err.?), "[0].id")
	err = read(t, "id,id\n1\n", &rows, {duplicates = .First})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Syntax)

	// Three of a name; a repeat is not an unknown field; a required field is still found.
	testing.expect_value(t, read(t, "id,id,id\n1,2,3\n", &rows, {duplicates = .First}), nil)
	testing.expect_value(t, rows[0].id, 1)
	testing.expect_value(t, read(t, "id,id,id\n1,2,3\n", &rows, {duplicates = .Last}), nil)
	testing.expect_value(t, rows[0].id, 3)
	testing.expect_value(t, read(t, "name,id,name\nx,5,y\n", &rows, {duplicates = .Last, unknown_fields = .Refuse}), nil)
	testing.expect_value(t, rows[0], Strict{5, "y"})
	err = read(t, "id,id\n,3\n", &rows, {duplicates = .First})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Missing_Field)
	testing.expect_value(t, read(t, "id,id\n,3\n", &rows, {duplicates = .Last}), nil)

	// `.All` reads every column into the field, each judged as its type, where `.Last` reads the earlier ones as
	// unknown.
	testing.expect_value(t, read(t, "id,id,id\n1,2,3\n", &rows, {duplicates = .All}), nil)
	testing.expect_value(t, rows[0].id, 3)
	testing.expect_value(t, read(t, "id,id\nnot a number,1\n", &rows, {duplicates = .Last}), nil)
	err = read(t, "id,id\nnot a number,1\n", &rows, {duplicates = .All})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Wrong_Kind)
	testing.expect_value(t, err.?.offset, 6)

	// Under .Lazy the left-out column's bytes are not judged, as an unknown column's are not.
	testing.expect_value(t, read(t, "id,id\n1,\xff\n", &rows, {duplicates = .First, strictness = .Lazy}), nil)
	err = read(t, "id,id\n1,\xff\n", &rows, {duplicates = .Last, strictness = .Lazy})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Syntax)
}

Required_Id :: struct {
	id:   int `csv:"id,required"`,
	name: string,
}

// A required field several columns read is present when any of its cells is.
@(test)
test_required_with_all_duplicates :: proc(t: ^testing.T) {
	rows: []Required_Id
	testing.expect_value(t, read(t, "id,id,name\n,5,x\n", &rows, {duplicates = .All}), nil)
	testing.expect_value(t, rows[0], Required_Id{5, "x"})
	testing.expect_value(t, read(t, "id,id,name\n5,,x\n", &rows, {duplicates = .All}), nil)
	testing.expect_value(t, rows[0], Required_Id{5, "x"})
	testing.expect_value(t, read(t, "id,name,id,id\n,x,,7\n", &rows, {duplicates = .All}), nil)
	testing.expect_value(t, rows[0], Required_Id{7, "x"})
	err := read(t, "id,id,name\n,,x\n", &rows, {duplicates = .All})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Missing_Field)
	testing.expect_value(t, err.?.offset, 11)
	testing.expect_value(t, path_text(err.?), "[0].id")
	err = read(t, "id,id,name\n,5,x\n,,y\n", &rows, {duplicates = .All})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Missing_Field)
	testing.expect_value(t, path_text(err.?), "[1].id")
	// A ragged record's missing cells are absent.
	testing.expect_value(t, read(t, "id,id,name\n,5\n", &rows, {dialect = {ragged = true}, duplicates = .All}), nil)
	testing.expect_value(t, rows[0], Required_Id{5, ""})
	err = read(t, "name\nx\n", &rows, {duplicates = .All})
	testing.expect_value(t, err.?.kind, csv.Unmarshal_Error_Kind.Missing_Field)
}
