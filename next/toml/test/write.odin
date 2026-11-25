package toml_tests

import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:toml"

// The TOML writer: a document is written as a text that reads back as the same values, a table's own keys before its
// subtables.

@(private = "file")
JSON_TEXTS := [?]string{
	`{"a":1,"b":"x\ny\"\\","c":[1,2.5,"s",[true,false]],"d":{"e":{"f":1},"g":[{"h":1},{"h":2}]},"i":{}}`,
	`{"d":{"x":1},"a":2,"k":[{"p":[{"q":1}]},{"p":[]}],"m":[{"a":1},2]}`,
	`{"odd key":1,"é":2,"":3,"a.b":{"c.d":4},"-":{"_":[]}}`,
	`{"big":9223372036854775807,"neg":-0,"f":1e5,"g":-2.5E-3}`,
	`{}`,
}

@(test)
json_objects_write_as_toml_that_reads_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src, k in JSON_TEXTS {
		doc, err := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		testing.expectf(t, err == nil, "%s: %v", src, err)
		for spec in toml.Spec {
			text, _, werr := toml.write(&doc, spec)
			defer delete(text)
			testing.expectf(t, werr == nil, "%d: %v", k, werr)
			testing.expectf(t, toml.validate(text, spec) == nil, "%d: %v\n%s", k, toml.validate(text, spec), text)
			back, berr := toml.build(text, spec)
			defer toml.destroy(&back)
			testing.expectf(t, berr == nil, "%d: %v", k, berr)
			again, _, aerr := toml.write(&back, spec)
			defer delete(again)
			testing.expectf(t, aerr == nil && string(again) == string(text), "%d: a write of the text differs:\n%s\n%s", k, text, again)
			// Back through JSON, the values are the document's.
			as_json, _, jerr := json.write(&back, .Json, {sort_keys = true})
			defer delete(as_json)
			want, _, _ := json.write(&doc, .Json, {sort_keys = true})
			defer delete(want)
			testing.expectf(t, jerr == nil && string(as_json) == string(want), "%d: %s\nwant %s", k, as_json, want)
		}
	}
}

@(test)
known_texts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, _ := json.build(transmute([]u8)string(`{"d":{"x":1,"y":{"z":"s"}},"a":2,"k":[{"p":1},{"p":2}],"l":[1,[2]]}`))
	defer json.destroy(&doc)
	text, _, err := toml.write(&doc)
	defer delete(text)
	want := "a = 2\nl = [1, [2]]\n\n[d]\nx = 1\n\n[d.y]\nz = \"s\"\n\n[[k]]\np = 1\n\n[[k]]\np = 2\n"
	testing.expectf(t, err == nil && string(text) == want, "%v\n%s", err, text)
}

@(test)
toml_dates_are_kept :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := "a = 1979-05-27T07:32:00Z\nb = 07:32:00\nc = \"1979-05-27\"\n"
	doc, err := toml.build(transmute([]u8)src)
	defer toml.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := toml.write(&doc)
	defer delete(text)
	testing.expectf(t, werr == nil && string(text) == src, "%v\n%s", werr, text)
}

@(test)
values_with_no_toml_spelling_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for src in ([?]string{`{"a":123456789012345678901234567890}`, `{"a":18446744073709551615}`, `{"a":null}`, `[1]`, `{"a":{"b":[null]}}`, `"s"`}) {
		doc, _ := json.build(transmute([]u8)src)
		defer json.destroy(&doc)
		_, _, err := toml.write(&doc)
		refused, ok := err.(write.Refused)
		testing.expectf(t, ok && refused.why == .No_Spelling, "%s: %v", src, err)
	}
	doc, _ := json.build(transmute([]u8)string(`{"a":1}`))
	defer json.destroy(&doc)
	_, _, err := toml.write(&doc, .Toml_1_0, {ascii = true})
	testing.expect(t, err != nil)
	_ = tape.ROOT
	_ = testkit.deadline
}
