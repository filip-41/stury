package json_tests

// `split_record`: the value a record starts with, when bytes that belong to no record follow it.

import json "../.."
import "core:testing"

@(test)
test_split_record_names_a_value_and_the_fault_after_it :: proc(t: ^testing.T) {
	Case :: struct {
		rec:   string,
		value: string, // "" when the record is one text
		at:    u64,    // the fault's offset, when split
	}
	cases := [?]Case{
		{`[1]]`, `[1]`, 3},
		{`"a"x`, `"a"`, 3},
		{`{"a":1}x`, `{"a":1}`, 7},
		// A bare scalar has no closing byte: what follows it is part of one faulty token, as jq reads it.
		{`1]`, ``, 0},
		{`true,`, ``, 0},
		{`nullx`, ``, 0},
		// No complete text before the fault: one faulty text, not a value.
		{`[1,`, ``, 0},
		{`{"a":`, ``, 0},
		{`nul`, ``, 0},
		// One text: the caller validates it whole.
		{`[1]`, ``, 0},
		{`{"a":1}`, ``, 0},
	}
	for c in cases {
		value, fault, split := json.split_record(raw(c.rec))
		if c.value == "" {
			testing.expect(t, !split, c.rec)
			continue
		}
		testing.expect(t, split, c.rec)
		testing.expect_value(t, string(value), c.value)
		e, bad := fault.?
		testing.expect(t, bad, c.rec)
		testing.expect_value(t, e.offset, c.at)
	}
}
