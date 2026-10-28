package json_tests

// `judge_record`: a record's fault as its framing tells it.

import json "../.."
import "core:testing"

@(test)
test_judge_record_splits_a_seq_value_from_the_bytes_after_it :: proc(t: ^testing.T) {
	Case :: struct {
		rec:   string,
		value: int, // the value's length, 0 when the record is one text
	}
	cases := [?]Case{
		{`[1]]`, 3},
		{`"a"x`, 3},
		{`{"a":1}x`, 7},
		// A bare scalar has no closing byte: what follows it is part of one faulty token, as jq reads it.
		{`true,`, 0},
		{`nullx`, 0},
		// No complete text before the fault: one faulty text, not a value.
		{`[1,`, 0},
		{`{"a":`, 0},
		{`nul`, 0},
	}
	for c in cases {
		src := raw(c.rec)
		read := json.validate(src)
		testing.expect(t, read != nil, c.rec)
		end, err := json.judge_record(src, {bytes = src}, read, {framing = .JSON_Seq})
		testing.expect_value(t, end, c.value)
		testing.expect(t, err != nil, c.rec)
		// Only `.JSON_Seq` splits.
		end, _ = json.judge_record(src, {bytes = src}, read)
		testing.expect_value(t, end, 0)
	}
}

@(test)
test_judge_record_refuses_what_the_framing_refuses :: proc(t: ^testing.T) {
	// A number alone in a `.JSON_Seq` record may be cut short, whatever the read said.
	src := raw("\x1e12")
	rec := json.Record{bytes = src[1:], at = 1}
	_, err := json.judge_record(src, rec, nil, {framing = .JSON_Seq})
	e, bad := err.?
	testing.expect(t, bad && e.kind == .Truncated && json.Fault(e.detail) == .Cut_Number && e.offset == 2)
	testing.expect_value(t, json.fault_name(e.kind, e.detail), "Potentially truncated top-level numeric value")
	_, err = json.judge_record(src, rec, nil, {framing = .NDJSON})
	testing.expect(t, err == nil)
	// A byte order mark past the input's start leads no record.
	src = raw("1\n\xef\xbb\xbf2")
	_, err = json.judge_record(src, {bytes = src[2:], at = 2}, nil, {framing = .NDJSON})
	e, bad = err.?
	testing.expect(t, bad && e.kind == .Bad_Char && e.offset == 0)
}

@(test)
test_judge_record_names_the_byte_that_cut_a_literal :: proc(t: ^testing.T) {
	// `tru` ends where its line does: the newline broke the literal, as a read of the whole input says.
	src := raw("tru\n1")
	rec := json.Record{bytes = src[:3]}
	_, err := json.judge_record(src, rec, json.validate(rec.bytes), {framing = .NDJSON})
	e, bad := err.?
	testing.expect(t, bad && e.kind == .Bad_Char && json.Fault(e.detail) == .Literal && e.offset == 3)
	// At the input's end nothing cut it.
	_, err = json.judge_record(src[:3], rec, json.validate(rec.bytes), {framing = .NDJSON})
	e, bad = err.?
	testing.expect(t, bad && e.kind == .Truncated)
}
