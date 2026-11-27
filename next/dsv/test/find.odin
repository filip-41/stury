package dsv_tests

import "core:strings"
import "core:testing"
import "stury:dsv"
import "stury:lib/core/tape"
import "stury:testkit"

Found :: struct {
	text: string,
	path: []tape.Step,
	opts: dsv.Dsv_Options,
	want: tape.Presence,
	span: string,
}

@(test)
finds_answer_cells_and_records :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]Found {
		{"a,b\n1,2\n3,4\n", {tape.Index(1), tape.Name("b")}, {}, .Found, "4"},
		{"a,b\n1,2\n3,4\n", {tape.Index(-2), tape.Name("a")}, {}, .Found, "1"},
		{"a,b\n1,2\n3,4\n", {tape.Index(0), tape.Name("c")}, {}, .Missing, ""},
		{"a,b\n1,\"x\"\"y\"\n", {tape.Index(0), tape.Name("b")}, {}, .Found, `"x""y"`},
		{"1,2\n3,4\n", {tape.Index(1), tape.Index(0)}, {no_header = true}, .Found, "3"},
		{"a,b\n1,2\n3,4\n", {tape.Index(1)}, {}, .Found, "3,4\n"},
		{"a\n1\n", {tape.Name("a")}, {}, .Wrong_Kind, ""},
	}) {
		src := transmute([]u8)c.text
		for stop in ([]bool{false, true}) {
			a, err := dsv.find(src, c.path, .Csv, {stop_early = stop}, {format = c.opts})
			span := c.text[a.lo:a.hi] if a.outcome == .Found else ""
			testing.expectf(t, err == nil && a.outcome == c.want && span == c.span, "%q %v stop %v: %v %q %v", c.text, c.path, stop, a.outcome, span, err)
		}
	}
}

// A find that passes over the records after its answer judges them against the width of the records before.
@(test)
finds_judge_the_rest_by_the_width_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in ([]struct {
			text: string,
			opts: dsv.Dsv_Options,
			at:   u64,
		}{{"1,2\n3\n", {no_header = true}, 5}, {"a,b\n1,2\n3\n", {}, 9}, {"1,2\n3,4,5\n", {no_header = true}, 7}}) {
		_, err := dsv.find(transmute([]u8)c.text, {tape.Index(0)}, .Csv, {}, {format = c.opts})
		fault, ok := err.(tape.Fault)
		testing.expectf(t, ok && fault.kind == .Bad_Width && fault.at == c.at, "%q: %v", c.text, err)
	}
}

// A record's span ends where its text does: at its line end in a text that tolerates a bare quote, and a find that stops
// at its answer leaves the rest of the record, here an unfinished quoted cell, unread.
@(test)
finds_end_a_record_where_its_text_ends :: proc(t: ^testing.T) {
	testkit.deadline(t)
	bare := transmute([]u8)string("a,b\n1,x\"y\n2,3\n")
	a, err := dsv.find(bare, []tape.Step{tape.Index(0)}, .Csv, {}, {tolerate = {.Bare_Quote}})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(bare[a.lo:a.hi]), "1,x\"y\n")

	open := transmute([]u8)string("a,b\n1,\"x")
	path := []tape.Step{tape.Index(0), tape.Name("a")}
	a, err = dsv.find(open, path, .Csv, {stop_early = true}, {dups = .First})
	testing.expect_value(t, err, nil)
	testing.expect_value(t, a.outcome, tape.Presence.Found)
	testing.expect_value(t, string(open[a.lo:a.hi]), "1")
	_, whole := dsv.find(open, path, .Csv, {}, {dups = .First})
	fault, faulted := whole.(tape.Fault)
	testing.expectf(t, faulted && fault.kind == .Truncated && fault.at == 6, "whole: %v", whole)
}

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
