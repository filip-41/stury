package write_tests

import "core:testing"
import "stury:json"
import "stury:testkit"

// The numbers JSON5 spells that RFC 8259 does not, written into JSON by their value.

@(private = "file")
Number_Case :: struct {
	json5: string,
	json:  string,
}

@(private = "file")
NUMBER_CASES := []Number_Case {
	{"+1", "1"},
	{"+1.5e3", "1.5e3"},
	{"-1.5", "-1.5"},
	{".5", "0.5"},
	{"-.5", "-0.5"},
	{"+.5e2", "0.5e2"},
	{"5.", "5.0"},
	{"5.e3", "5.0e3"},
	{"0x0", "0"},
	{"0x1d9", "473"},
	{"-0xFF", "-255"},
	{"+0x7f", "127"},
	{"0xfffffffffffffff", "1152921504606846975"},
	{"0x1000000000000000", "1152921504606846976"},
	{"0xffffffffffffffffffff", "1208925819614629174706175"},
	{"-0x1000000000000000000", "-4722366482869645213696"},
}

@(test)
json5_numbers_into_json :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in NUMBER_CASES {
		doc, err := json.build(transmute([]u8)c.json5, .Json5)
		if !testing.expectf(t, err == nil, "%q: %v", c.json5, err) {
			continue
		}
		defer json.destroy(&doc)
		text, _, werr := json.write(&doc, .Json)
		testing.expectf(t, werr == nil && string(text) == c.json, "%q: %q, %v, want %q", c.json5, text, werr, c.json)
		delete(text)
	}
}
