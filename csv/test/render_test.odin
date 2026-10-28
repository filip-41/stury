package csv_tests

import "core:io"
import "core:strings"
import "core:testing"
import csv "../"
import core "../../core"

@(test)
test_error_position :: proc(t: ^testing.T) {
	src := "a,b\r\n1,2\r\n3\r\n"
	err := csv.validate(transmute([]byte)src).?
	testing.expect_value(t, err, csv_fault(10, .Field_Count))
	line, col := csv.error_position(transmute([]byte)src, err)
	testing.expect_value(t, line, 3)
	testing.expect_value(t, col, 1)
	// An error that points at no byte has no position.
	line, col = csv.error_position(transmute([]byte)src, csv.Error{kind = .Bad_Option})
	testing.expect_value(t, line, 0)
	testing.expect_value(t, col, 0)
	line, col = csv.error_position(transmute([]byte)src, csv.Error{offset = 999, kind = .Truncated})
	testing.expect_value(t, line, 0)
	testing.expect_value(t, col, 0)
}

@(test)
test_render_error :: proc(t: ^testing.T) {
	src := "id,name\n1,a\n2\n"
	bytes := transmute([]byte)src
	err := csv.validate(bytes).?
	text := csv.render_error(bytes, err, context.temp_allocator)
	testing.expect_value(t, text, "3:1: Record has the wrong number of fields")
	testing.expect_value(t, csv.render_error(bytes, csv.Error{kind = .Bad_Option}, context.temp_allocator), "offset 0: Unsupported option")
	testing.expect_value(t, csv.render_error(bytes, csv.Error{offset = 99, kind = .Truncated}, context.temp_allocator), "offset 99: Unfinished input")

	rows: []Row
	cases := []struct {
		src:  string,
		want: string,
	} {
		{"id\nabc\n", "2:1: Value of the wrong kind at [0].id"},
		{"id\n1\n\"2\n", "4:1: Unfinished input at [1]"},
		{"id,ok\n1,true\n2\n", "3:1: Record has the wrong number of fields at [1]"},
	}
	for c in cases {
		uerr := read(t, c.src, &rows)
		e, refused := uerr.?
		if !testing.expectf(t, refused, "%q: accepted", c.src) {
			continue
		}
		testing.expect_value(t, csv.render_error(transmute([]byte)c.src, e, context.temp_allocator), c.want)
	}
	rerr := read(t, "id,id\n1,2\n", &rows, {duplicates = .Refuse})
	testing.expect_value(t, csv.render_error(transmute([]byte)string("id,id\n1,2\n"), rerr.?, context.temp_allocator), "1:4: Duplicate key at .id")
	nested: []Nested
	nerr := read(t, "id,list\n1,2\n", &nested)
	testing.expect_value(t, csv.render_error(bytes, nerr.?, context.temp_allocator), "Unsupported type at [].list")
	nerr = read(t, "", &rows, {dialect = {delimiter = '"'}})
	testing.expect_value(t, csv.render_error(bytes, nerr.?, context.temp_allocator), "Unsupported option")

	// A name that is not an identifier is quoted. A path longer than the steps kept is marked.
	quoted := csv.Unmarshal_Error {
		kind      = .Wrong_Kind,
		offset    = 3,
		n_steps   = 2,
		truncated = true,
	}
	quoted.steps[0], quoted.steps[1] = csv.Index(4), csv.Name("full name")
	testing.expect_value(t, csv.render_error(bytes, quoted, context.temp_allocator), "1:4: Value of the wrong kind at …[4].\"full name\"")

	// The writer form writes the same text and returns the writer's failure.
	b := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, core.render_error_to_writer(strings.to_writer(&b), bytes, err, csv.fault_name), nil)
	testing.expect_value(t, strings.to_string(b), text)
	failing := io.Writer {
		procedure = fail_writer,
	}
	testing.expect_value(t, core.render_error_to_writer(failing, bytes, quoted), io.Error.Unexpected_EOF)
}

@(test)
test_render_path_error :: proc(t: ^testing.T) {
	src := transmute([]byte)string("a,b\n1,2\n")
	ragged := transmute([]byte)string("a,b\n1\n")
	one := transmute([]byte)string("a\nx\n")
	text :: proc(t: ^testing.T, src: []byte, err: Maybe(csv.Path_Error), want: string, loc := #caller_location) {
		e, refused := err.?
		if !testing.expectf(t, refused, "accepted, want %q", want, loc = loc) {
			return
		}
		testing.expect_value(t, csv.render_error(src, e, context.temp_allocator), want, loc = loc)
		b := strings.builder_make(context.temp_allocator)
		testing.expect_value(t, core.render_error_to_writer(strings.to_writer(&b), src, e, csv.fault_name), nil, loc = loc)
		testing.expect_value(t, strings.to_string(b), want, loc = loc)
	}
	defer free_all(context.temp_allocator)

	// Located in the source, then the scan's fault.
	_, err := csv.set(ragged, ".[0].a", 1)
	text(t, ragged, err, "2:1: Record has the wrong number of fields")
	// Offsets into the path text and into the edited text, not the source.
	_, err = csv.set(src, ".[", 1)
	text(t, src, err, "offset 1: Invalid path")
	_, err = csv.splice(src, []csv.Edit{{lo = 4, hi = 5, bytes = transmute([]byte)string("1,9")}})
	text(t, src, err, "offset 4: Invalid result text: Record has the wrong number of fields")
	// No position.
	_, err = csv.set(src, ".[0]", 1)
	text(t, src, err, "Unsupported path")
	_, err = csv.set(src, ".[1].a", 1)
	text(t, src, err, "Path matched nothing")
	_, err = csv.insert(src, ".", -1, []Maybe(string){"1", "2"})
	text(t, src, err, "Entry has no valid place")
	_, err = csv.splice(src, []csv.Edit{{lo = 5, hi = 4}})
	text(t, src, err, "Edits out of range, unsorted or overlapping")
	_, err = csv.splice(src, nil, {dialect = csv.Dialect{delimiter = '"'}})
	text(t, src, err, "Unsupported option")
	// The cell count or the field index of a row that does not fit.
	_, err = csv.insert(src, ".", 0, []Maybe(string){"1"})
	text(t, src, err, "Entry does not fit its destination (1)")
	// What marshal refused, and the record it was for where there is one.
	_, err = csv.set(src, ".[0].a", []int{1})
	text(t, src, err, "Value cannot be written: Unsupported type")
	_, err = csv.set(one, ".[0].a", "", {dialect = csv.Dialect{quoting = .None}})
	text(t, one, err, "2:1: Value cannot be written: Dialect cannot write it unchanged")
	semi := transmute([]byte)string("a;b\n1;2\n")
	_, err = csv.set(semi, ".[0].b", "p;q", {dialect = csv.Dialect{quoting = .None, delimiter = ';'}})
	text(t, semi, err, "Value cannot be written: Dialect cannot write it unchanged")
}

