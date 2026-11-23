package dsv_tests

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
