package stury_tests

import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:stury"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

// `format` reads a text in one format and writes it in another, and keeps the comments and styles both hold.

@(test)
a_text_changes_format :: proc(t: ^testing.T) {
	testkit.deadline(t)
	cases := [?]struct {
		src:  string,
		from: stury.Spec,
		to:   stury.Spec,
		want: string,
	}{
		{`{"a":1,"b":{"c":[1,2]}}`, json.Spec.Json, toml.Spec.Toml_1_0, "a = 1\n\n[b]\nc = [1, 2]\n"},
		{"# top\na = 0xFF # tail\n", toml.Spec.Toml_1_0, json.Spec.Jsonc, "{// top\n\"a\":255// tail\n}"},
		{"id,name\n1,x\n2,\"y,z\"\n", dsv.Spec.Csv, json.Spec.Json, `[{"id":"1","name":"x"},{"id":"2","name":"y,z"}]`},
		{`{"r":{"a":1}}`, json.Spec.Json, xml.Spec.Xml, "<r><a>1</a></r>"},
		{"<r><a>1</a><!-- c --></r>", xml.Spec.Xml, toml.Spec.Toml_1_0, "[r]\na = \"1\" # c \n"},
	}
	for c, k in cases {
		text, _, err := stury.format(transmute([]u8)c.src, c.from, c.to)
		defer delete(text)
		testing.expectf(t, err == nil, "%d: %v", k, err)
		testing.expectf(t, string(text) == c.want, "%d: %q", k, text)
	}
}

@(test)
a_fault_in_the_text_is_the_error :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text, _, err := stury.format(transmute([]u8)string(`{"a":`), json.Spec.Json, toml.Spec.Toml_1_0)
	testing.expect(t, text == nil && err != nil)
}
