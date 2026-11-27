package stury_tests

import "core:testing"
import "stury:dsv"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:msgpack"
import "stury:stury"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

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
		{"a: 1\nb:\n  - 2\n  - 3\n", yaml.Spec.Yaml_1_2, json.Spec.Json, `{"a":1,"b":[2,3]}`},
		{"<!DOCTYPE html><html><body><p>ok</p></body></html>", html.Spec.Html, json.Spec.Json, `{"html":{"head":null,"body":{"p":"ok"}}}`},
	}
	for c, k in cases {
		text, _, err := stury.format(transmute([]u8)c.src, c.from, c.to)
		defer delete(text)
		testing.expectf(t, err == nil, "%d: %v", k, err)
		testing.expectf(t, string(text) == c.want, "%d: %q", k, text)
	}

	// JSON -> MessagePack -> YAML -> JSON roundtrip.
	mp, _, mperr := stury.format(transmute([]u8)string(`{"k":42}`), json.Spec.Json, msgpack.Spec.Compact)
	testing.expect_value(t, mperr, stury.Format_Error(nil))
	defer delete(mp)
	yml, _, yerr := stury.format(mp, msgpack.Spec.Compact, yaml.Spec.Yaml_1_2, opts = {indent = 2})
	testing.expect_value(t, yerr, stury.Format_Error(nil))
	defer delete(yml)
	back, _, berr := stury.format(yml, yaml.Spec.Yaml_1_2, json.Spec.Json)
	testing.expect_value(t, berr, stury.Format_Error(nil))
	defer delete(back)
	testing.expect_value(t, string(back), `{"k":42}`)
}

@(test)
a_fault_in_the_text_is_the_error :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text, _, err := stury.format(transmute([]u8)string(`{"a":`), json.Spec.Json, toml.Spec.Toml_1_0)
	testing.expect(t, text == nil && err != nil)
}

@(test)
nil_specs_are_refused :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := transmute([]u8)string(`{"a":1}`)
	text, _, err := stury.format(src, json.Spec.Json, nil)
	testing.expectf(t, text == nil && err == stury.Format_Error(write.Error(tape.Bad_Option{"to"})), "nil to: %v", err)
	text2, _, err2 := stury.format(src, nil, json.Spec.Json)
	testing.expectf(t, text2 == nil && err2 == stury.Format_Error(tape.Error(tape.Bad_Option{"from"})), "nil from: %v", err2)
}

@(test)
delimited_options_and_edge_shapes_convert_cleanly :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// `no_header` round-trips through CSV -> JSON -> CSV.
	csv_no_hdr := transmute([]u8)string("1,x\n2,y\n")
	as_json, _, jerr := stury.format(csv_no_hdr, dsv.Spec.Csv, json.Spec.Json, {format = dsv.Dsv_Options{no_header = true}})
	defer delete(as_json)
	testing.expectf(t, jerr == nil && string(as_json) == `[["1","x"],["2","y"]]`, "no_header to json: %v %q", jerr, as_json)
	back_csv, _, cerr := stury.format(as_json, json.Spec.Json, dsv.Spec.Csv, {}, {format = dsv.Dsv_Options{no_header = true}})
	defer delete(back_csv)
	testing.expectf(t, cerr == nil && string(back_csv) == "1,x\n2,y\n", "no_header back: %v %q", cerr, back_csv)

	// Semicolon delimiter inherited when writing CSV, reset to tab when writing TSV.
	semi := transmute([]u8)string("a;b\n1;\"x;y\"\n")
	semi_csv, _, scerr := stury.format(semi, dsv.Spec.Csv, dsv.Spec.Csv, {format = dsv.Dsv_Options{delimiter = ';'}})
	defer delete(semi_csv)
	testing.expectf(t, scerr == nil && string(semi_csv) == "a;b\n1;\"x;y\"\n", "delimiter inherit: %v %q", scerr, semi_csv)
	semi_tsv, _, sterr := stury.format(semi, dsv.Spec.Csv, dsv.Spec.Tsv, {format = dsv.Dsv_Options{delimiter = ';'}})
	defer delete(semi_tsv)
	testing.expectf(t, sterr == nil && string(semi_tsv) == "a\tb\n1\tx;y\n", "delimiter reset for tsv: %v %q", sterr, semi_tsv)

	// Ragged CSV rows are refused strictly and convert cleanly under `.Ragged` tolerance.
	ragged := transmute([]u8)string("id,name\n1,x\n2\n")
	_, _, rstrict := stury.format(ragged, dsv.Spec.Csv, json.Spec.Json)
	testing.expect(t, rstrict != nil)
	rag_json, _, rerr := stury.format(ragged, dsv.Spec.Csv, json.Spec.Json, {tolerate = {.Ragged}})
	defer delete(rag_json)
	testing.expectf(t, rerr == nil && string(rag_json) == `[{"id":"1","name":"x"},{"id":"2"}]`, "ragged: %v %q", rerr, rag_json)

	// Repeated header names under `dups = .All`.
	dups := transmute([]u8)string("id,id\n1,2\n")
	dup_json, _, derr := stury.format(dups, dsv.Spec.Csv, json.Spec.Json, {dups = .All})
	defer delete(dup_json)
	testing.expectf(t, derr == nil && string(dup_json) == `[{"id":"1","id":"2"}]`, "dups .All: %v %q", derr, dup_json)
	dup_csv, _, dcerr := stury.format(dups, dsv.Spec.Csv, dsv.Spec.Csv, {dups = .All})
	defer delete(dup_csv)
	testing.expectf(t, dcerr == nil && string(dup_csv) == "id,id\n1,2\n", "dups .All csv: %v %q", dcerr, dup_csv)
}
