package dsv_tests

import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:testkit"

// A row of a table with a header is an object keyed by it, so `.[i][j]` is an index on an object and answers
// `Wrong_Kind`. Under `no_header` a row is an array, and the index answers the cell.

@(private = "file")
ROWS :: "a,b\n1,2\n3,4\n"

// What `.[1][0]` of ROWS answers, and the cell's text when it is found.
@(private = "file")
Answer :: struct {
	presence: dsv.Presence,
	text:     string,
}

// Reads ROWS whole for `size` 0, else in windows of `size` new bytes, each from the last read's `keep`.
@(private = "file")
find_cell :: proc(t: ^testing.T, opts: dsv.Options, size: int) -> Answer {
	src := transmute([]u8)string(ROWS)
	path := []dsv.Step{dsv.Index(1), dsv.Index(0)}
	if size == 0 {
		a, err := dsv.find(src, path, .Csv, {}, opts)
		testing.expect_value(t, err, nil)
		return {a.outcome, string(src[a.lo:a.hi]) if a.outcome == .Found else ""}
	}
	pieces := dsv.Pieces {
		allocator = context.allocator,
	}
	defer dsv.destroy(&pieces)
	read := opts
	read.pieces = &pieces
	for to := size; ; to += size {
		to = min(to, len(src))
		pieces.from, pieces.last = pieces.keep, to == len(src)
		a, err := dsv.find(src[pieces.keep:to], path, .Csv, {}, read)
		testing.expect_value(t, err, nil)
		if !pieces.more {
			return {a.outcome, strings.clone(string(pieces.text), context.temp_allocator) if a.outcome == .Found else ""}
		}
	}
}

@(private = "file")
scan_cell :: proc(t: ^testing.T, opts: dsv.Options, size: int) -> Answer {
	src := transmute([]u8)string(ROWS)
	d, derr := dsv.demand_of({{dsv.Index(1), dsv.Index(0)}})
	defer dsv.destroy(&d)
	testing.expect_value(t, derr, nil)
	pieces := dsv.Pieces {
		allocator = context.allocator,
	}
	defer dsv.destroy(&pieces)
	read := opts
	if size > 0 {
		read.pieces = &pieces
	}
	for to := size if size > 0 else len(src); ; to += size {
		to = min(to, len(src))
		pieces.from, pieces.last = pieces.keep, to == len(src)
		s, err := dsv.scan(src[pieces.keep:to], &d, .Csv, {}, read)
		defer dsv.destroy(&s)
		testing.expect_value(t, err, nil)
		if size == 0 || !pieces.more {
			at, presence, _ := dsv.answer({&s, nil}, 0, 0)
			buf: [8]u8
			text, _ := dsv.node_text(&s, at, buf[:])
			return {presence, strings.clone(text, context.temp_allocator) if presence == .Found else ""}
		}
	}
}

@(test)
an_index_into_a_row_with_a_header_is_wrong_kind :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for size in ([]int{0, 1, 3, 5}) {
		found, scanned := find_cell(t, {}, size), scan_cell(t, {}, size)
		testing.expectf(t, found == {.Wrong_Kind, ""} && scanned == {.Wrong_Kind, ""}, "window %d: find %v, scan %v", size, found, scanned)
	}
}

@(test)
an_index_into_a_row_without_a_header_is_the_cell :: proc(t: ^testing.T) {
	testkit.deadline(t)
	no_header := dsv.Options {
		format = dsv.Dsv_Options{no_header = true},
	}
	for size in ([]int{0, 1, 3, 5}) {
		found, scanned := find_cell(t, no_header, size), scan_cell(t, no_header, size)
		testing.expectf(t, found == {.Found, "1"} && scanned == {.Found, "1"}, "window %d: find %v, scan %v", size, found, scanned)
	}
}
