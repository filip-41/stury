package json_tests

import "core:testing"
import core "../../core"
import json ".."

// A check from the names of `json` alone: load the schema, bind it to a spec, judge a text and its records.
@(test)
schema_check_from_json_names :: proc(t: ^testing.T) {
	text := `{"type": "object", "properties": {"a": {"type": "integer"}}, "required": ["a"]}`
	s, err := json.load_schema(transmute([]u8)text)
	testing.expect(t, err == nil)
	defer json.destroy(s)
	b, berr := json.bind_schema(s, .Json)
	testing.expect(t, berr == nil)
	defer json.destroy(&b)
	sink: json.Sink
	defer json.destroy(&sink)
	testing.expect(t, json.check_schema(&b, transmute([]u8)string(`{"a": 1}`), &sink) == nil)
	testing.expect(t, json.check_schema(&b, transmute([]u8)string(`{"a": "x"}`), &sink) != nil)
	testing.expect_value(t, len(sink.entries), 1)
	count, rerr := json.check_schema_records(&b, transmute([]u8)string("{\"a\": 1}\n{\"b\": 2}\n"), .Lines)
	testing.expect_value(t, count, 2)
	_, failed := rerr.(core.Typed_Error)
	testing.expect(t, failed)
	_, bad := json.load_schema(transmute([]u8)string(`{"type": 5}`))
	testing.expect(t, bad != nil)
}

// `load_schema` reads a schema with no `$schema` in the draft its options name, and its checks judge a repeated key as
// they say.
@(test)
schema_options_from_json_names :: proc(t: ^testing.T) {
	tuple := transmute([]u8)string(`{"items": [{"type": "integer"}]}`)
	s, err := json.load_schema(tuple, {draft = .D07})
	testing.expectf(t, err == nil, "%v", err)
	defer json.destroy(s)
	b, berr := json.bind_schema(s, .Json)
	testing.expect(t, berr == nil)
	defer json.destroy(&b)
	testing.expect(t, json.check_schema(&b, transmute([]u8)string(`[1, "x"]`)) == nil)
	testing.expect(t, json.check_schema(&b, transmute([]u8)string(`["x"]`)) != nil)
	once := transmute([]u8)string(`{"maxProperties": 1}`)
	repeated := transmute([]u8)string(`{"a": 1, "a": 2}`)
	for dups in ([2]json.Duplicates{.Last, .Refuse}) {
		r, rerr := json.load_schema(once, {dups = dups})
		testing.expect(t, rerr == nil)
		defer json.destroy(r)
		rb, rberr := json.bind_schema(r, .Json)
		testing.expect(t, rberr == nil)
		defer json.destroy(&rb)
		testing.expect_value(t, json.check_schema(&rb, repeated) == nil, dups == .Last)
	}
}
