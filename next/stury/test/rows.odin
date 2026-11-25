package stury_tests

import "core:testing"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:stury"
import "stury:testkit"

// `stury.format` converts across formats cleanly via build-then-write, refuses nil `from`/`to` specs, and preserves
// delimited options (header mode, delimiter inheritance, ragged rows, duplicate policies).

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
