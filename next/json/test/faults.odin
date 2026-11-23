package json_tests

import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/records"
import "stury:testkit"

@(private = "file")
Detailed :: struct {
	spec: json.Spec,
	src:  string,
	at:   u64,
	code: string,
}

@(private = "file")
DETAILED := []Detailed {
	{.Json, `[1,]`, 3, "trailing_comma"},
	{.Json, `{"a":1,}`, 7, "trailing_comma"},
	{.Json, `{"a" 1}`, 5, "colon"},
	{.Json, `[1] x`, 4, "trailing"},
	{.Json, `]`, 0, "unmatched_bracket"},
	{.Json, `{"a":1]`, 6, "unmatched_bracket"},
	{.Json, `[}`, 1, "unmatched_brace"},
	{.Json, `{"a":}`, 5, "expected_value"},
	{.Json, `[1 2]`, 3, "array_separator"},
	{.Json, `{"a":1 "b":2}`, 7, "member_separator"},
	{.Json, `[,1]`, 1, "lone_comma"},
	{.Json, `['a']`, 1, "single_quote"},
	{.Json, `[.5]`, 1, "leading_dot"},
	{.Json, `[+1]`, 1, "leading_plus"},
	{.Json, `[01]`, 2, "leading_zero"},
	{.Json, `[-Infinity]`, 2, "non_finite"},
	{.Json, `[NaN]`, 1, "non_finite"},
	{.Json, `[nul]`, 4, "literal"},
	{.Json, `{1:2}`, 1, "key_not_string"},
	{.Json, "[\"a\x01\"]", 3, "control_char"},
	{.Json, "[\"\xff\"]", 2, "invalid_utf8"},
	{.Json, "{\"a\":1,\"b\":[1,2,3],\"c\":\"x\x02\"}", 25, "control_char"},
	{.Jsonc, `{"a" /x}`, 5, "colon"},
	{.Jsonc, `[1] /x`, 4, "trailing"},
	{.Jsonc, `{/x}`, 1, "key_not_string"},
	{.Jsonc, `[/x]`, 1, "expected_value"},
	{.Jsonc, "1 /* \xff */", 5, "invalid_utf8"},
	{.Jsonc, "[1, /* \xff */ 2]", 7, "invalid_utf8"},
	{.Json5, `{-:1}`, 1, "identifier"},
}

// Every read refuses a text with the same fault, whose detail names the rule the text broke.
@(test)
faults_name_the_rule_on_every_read :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in DETAILED {
		src := transmute([]u8)c.src
		path := []tape.Step{tape.Name("zz")}
		demand, _ := tape.demand_of([][]tape.Step{path}, allocator = context.temp_allocator)
		doc, berr := json.build(src, c.spec)
		tape.destroy(&doc)
		sdoc, serr := json.scan(src, &demand, c.spec)
		tape.destroy(&sdoc)
		_, ferr := json.find(src, path, c.spec)
		for err, read in ([]tape.Error{json.validate(src, c.spec), berr, serr, ferr}) {
			f, faulted := err.(tape.Fault)
			testing.expectf(t, faulted && f.at == c.at && tape.fault_rule(f).code == c.code, "%v %q read %d: %v, want %s at %d", c.spec, c.src, read, err, c.code, c.at)
		}
	}
	text := transmute([]u8)string("[1,]\n[01]\n[\"\x01\"]\n")
	r := json.records_open(text)
	out: [4]records.Record
	n := json.records_validate(&r, out[:])
	for want, i in ([]string{"trailing_comma", "leading_zero", "control_char"}) {
		f, faulted := out[i].err.(tape.Fault)
		testing.expectf(t, n == 3 && faulted && tape.fault_rule(f).code == want, "record %d of %d: %v, want %s", i, n, out[i].err, want)
	}
}

// A message names the line and column of the byte an error names, and its rule's message.
@(test)
error_messages_place_the_fault :: proc(t: ^testing.T) {
	testkit.deadline(t)
	buf: [128]u8
	src := transmute([]u8)string("[1,\n  2,\n]")
	testing.expect_value(t, tape.error_message(buf[:], json.validate(src), src), "3:1: Trailing comma before the closing bracket")
	src = transmute([]u8)string("[\"\x01\"]")
	testing.expect_value(t, tape.error_message(buf[:], json.validate(src), src), "1:3: Unescaped control character U+0001")
	testing.expect_value(t, tape.error_message(buf[:], tape.Exceeded{at = tape.NO_BYTE, kind = .Memory}, src), "Exceeds the memory limit")
	testing.expect_value(t, tape.error_message(buf[:], tape.Exceeded{at = 2, kind = .Depth}, src), "1:3: Exceeds the depth limit")
	testing.expect_value(t, tape.error_message(buf[:], tape.Bad_Option{"dups"}, src), "Option not taken: dups")
	testing.expect_value(t, tape.error_message(buf[:4], json.validate(src), src), "1:3:")
}
