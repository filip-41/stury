package write_tests

import "base:runtime"
import "core:bytes"
import "core:mem"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/write"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

// Plain-text aligned table (`--to table`) and GitHub-Flavored Markdown table (`--to markdown`) output writers.

@(test)
render_table_styles_and_alignment :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `[{"name":"alice","age":30,"active":true},{"name":"bob","age":7,"active":false}]`
	doc, berr := json.build(transmute([]u8)src)
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)

	// .Plain (default): underlined header, auto right-align numeric columns, left-align strings/booleans.
	plain, err := write.write_table(&doc)
	defer delete(plain)
	testing.expect_value(t, err, nil)
	want_plain := strings.concatenate({
		"name   age  active\n",
		"-----  ---  ------\n",
		"alice   30  true\n",
		"bob      7  false\n",
	}, context.temp_allocator)
	testing.expectf(t, string(plain) == want_plain, "plain:\n%s\nwant:\n%s", plain, want_plain)

	// .Compact: aligned columns with no horizontal rule.
	compact, cerr := write.write_table(&doc, {style = .Compact})
	defer delete(compact)
	testing.expect_value(t, cerr, nil)
	want_compact := strings.concatenate({
		"name   age  active\n",
		"alice   30  true\n",
		"bob      7  false\n",
	}, context.temp_allocator)
	testing.expectf(t, string(compact) == want_compact, "compact:\n%s\nwant:\n%s", compact, want_compact)

	// .Box: crisp Unicode box borders.
	boxed, xerr := write.write_table(&doc, {style = .Box})
	defer delete(boxed)
	testing.expect_value(t, xerr, nil)
	want_box := strings.concatenate({
		"┌───────┬─────┬────────┐\n",
		"│ name  │ age │ active │\n",
		"├───────┼─────┼────────┤\n",
		"│ alice │  30 │ true   │\n",
		"│ bob   │   7 │ false  │\n",
		"└───────┴─────┴────────┘\n",
	}, context.temp_allocator)
	testing.expectf(t, string(boxed) == want_box, "box:\n%s\nwant:\n%s", boxed, want_box)

	// .Ascii: pure ASCII box borders.
	asc, aerr := write.write_table(&doc, {style = .Ascii})
	defer delete(asc)
	testing.expect_value(t, aerr, nil)
	want_ascii := strings.concatenate({
		"+-------+-----+--------+\n",
		"| name  | age | active |\n",
		"+-------+-----+--------+\n",
		"| alice |  30 | true   |\n",
		"| bob   |   7 | false  |\n",
		"+-------+-----+--------+\n",
	}, context.temp_allocator)
	testing.expectf(t, string(asc) == want_ascii, "ascii:\n%s\nwant:\n%s", asc, want_ascii)

	// Left alignment override + custom gap + no_header.
	left_no_hdr, lerr := write.write_table(&doc, {style = .Plain, align = .Left, no_header = true, column_gap = 1})
	defer delete(left_no_hdr)
	testing.expect_value(t, lerr, nil)
	testing.expectf(t, string(left_no_hdr) == "alice 30 true\nbob   7  false\n", "left_no_hdr: %q", left_no_hdr)

	// Right alignment override.
	right_all, rerr := write.write_table(&doc, {style = .Compact, align = .Right})
	defer delete(right_all)
	testing.expect_value(t, rerr, nil)
	want_right := " name  age  active\nalice   30    true\n  bob    7   false\n"
	testing.expectf(t, string(right_all) == want_right, "right:\n%s\nwant:\n%s", right_all, want_right)

	// Numeric column with null: numbers right-align while null left-aligns under .Auto.
	null_src := `[{"k":"a","v":10000},{"k":"b","v":null},{"k":"c","v":7}]`
	null_doc, _ := json.build(transmute([]u8)null_src)
	defer json.destroy(&null_doc)
	null_tbl, nerr := write.write_table(&null_doc, {style = .Box})
	defer delete(null_tbl)
	testing.expect_value(t, nerr, nil)
	want_null_tbl := strings.concatenate({
		"┌───┬───────┐\n",
		"│ k │     v │\n",
		"├───┼───────┤\n",
		"│ a │ 10000 │\n",
		"│ b │ null  │\n",
		"│ c │     7 │\n",
		"└───┴───────┘\n",
	}, context.temp_allocator)
	testing.expectf(t, string(null_tbl) == want_null_tbl, "null_tbl:\n%s\nwant:\n%s", null_tbl, want_null_tbl)

	// Custom null_text (including empty string "").
	blank_null, bnerr := write.write_table(&null_doc, {style = .Compact, null_text = ""})
	defer delete(blank_null)
	testing.expect_value(t, bnerr, nil)
	want_blank := "k      v\na  10000\nb\nc      7\n"
	testing.expectf(t, string(blank_null) == want_blank, "blank_null: %q want %q", blank_null, want_blank)
}

@(test)
render_markdown_tables_and_escaping :: proc(t: ^testing.T) {
	testkit.deadline(t)
	src := `[{"col1":"val","col2":42},{"col1":"a|b\\c\nd\r\ne","col2":7}]`
	doc, berr := json.build(transmute([]u8)src)
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)

	// Compact GFM pipe table.
	compact, cerr := write.write_markdown(&doc, {compact = true})
	defer delete(compact)
	testing.expect_value(t, cerr, nil)
	want_compact := strings.concatenate({
		"| col1 | col2 |\n",
		"| --- | ---: |\n",
		"| val | 42 |\n",
		"| a\\|b\\\\c<br>d<br>e | 7 |\n",
	}, context.temp_allocator)
	testing.expectf(t, string(compact) == want_compact, "md compact:\n%s\nwant:\n%s", compact, want_compact)

	// Default padded GFM pipe table: aligned pipes and >=3 dashes in divider.
	padded, perr := write.write_markdown(&doc)
	defer delete(padded)
	testing.expect_value(t, perr, nil)
	want_padded := strings.concatenate({
		"| col1              | col2 |\n",
		"| ----------------- | ---: |\n",
		"| val               |   42 |\n",
		"| a\\|b\\\\c<br>d<br>e |    7 |\n",
	}, context.temp_allocator)
	testing.expectf(t, string(padded) == want_padded, "md padded:\n%s\nwant:\n%s", padded, want_padded)

	// Alignment overrides in Markdown.
	left_md, lerr := write.write_markdown(&doc, {compact = true, align = .Left})
	defer delete(left_md)
	testing.expect_value(t, lerr, nil)
	testing.expect(t, strings.contains(string(left_md), "| --- | --- |\n"))

	right_md, rerr := write.write_markdown(&doc, {compact = true, align = .Right})
	defer delete(right_md)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, strings.contains(string(right_md), "| ---: | ---: |\n"))
}

@(test)
render_shapes_heterogeneous_nested_and_empty :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Heterogeneous array of objects: union of keys in first-seen order, and sort_keys = true.
	het_src := `[{"z":1,"a":"x"},{"a":"y","m":true},{"z":3,"b":null}]`
	het_doc, _ := json.build(transmute([]u8)het_src)
	defer json.destroy(&het_doc)

	het_md, herr := write.write_markdown(&het_doc, {compact = true})
	defer delete(het_md)
	testing.expect_value(t, herr, nil)
	want_het := strings.concatenate({
		"| z | a | m | b |\n",
		"| ---: | --- | --- | --- |\n",
		"| 1 | x |  |  |\n",
		"|  | y | true |  |\n",
		"| 3 |  |  | null |\n",
	}, context.temp_allocator)
	testing.expectf(t, string(het_md) == want_het, "het:\n%s\nwant:\n%s", het_md, want_het)

	het_sorted, serr := write.write_markdown(&het_doc, {compact = true, sort_keys = true})
	defer delete(het_sorted)
	testing.expect_value(t, serr, nil)
	want_het_sorted := strings.concatenate({
		"| a | b | m | z |\n",
		"| --- | --- | --- | ---: |\n",
		"| x |  |  | 1 |\n",
		"| y |  | true |  |\n",
		"|  | null |  | 3 |\n",
	}, context.temp_allocator)
	testing.expectf(t, string(het_sorted) == want_het_sorted, "het_sorted:\n%s\nwant:\n%s", het_sorted, want_het_sorted)

	// Array of arrays (ragged widths -> columns 0, 1, 2).
	arr_src := `[[1,"x"],[2,"y",true]]`
	arr_doc, _ := json.build(transmute([]u8)arr_src)
	defer json.destroy(&arr_doc)
	arr_tbl, aerr := write.write_table(&arr_doc, {style = .Compact})
	defer delete(arr_tbl)
	testing.expect_value(t, aerr, nil)
	testing.expectf(t, string(arr_tbl) == "0  1  2\n1  x\n2  y  true\n", "arr_tbl: %q", arr_tbl)

	// Single object: .Key_Value (default) vs .Row.
	obj_src := `{"b":2,"a":"hi"}`
	obj_doc, _ := json.build(transmute([]u8)obj_src)
	defer json.destroy(&obj_doc)

	kv_tbl, kverr := write.write_table(&obj_doc, {style = .Compact, sort_keys = true})
	defer delete(kv_tbl)
	testing.expect_value(t, kverr, nil)
	testing.expectf(t, string(kv_tbl) == "key  value\na    hi\nb    2\n", "kv_tbl: %q", kv_tbl)

	row_md, rowerr := write.write_markdown(&obj_doc, {object_layout = .Row, compact = true, sort_keys = true})
	defer delete(row_md)
	testing.expect_value(t, rowerr, nil)
	testing.expectf(t, string(row_md) == "| a | b |\n| --- | ---: |\n| hi | 2 |\n", "row_md: %q", row_md)

	// Scalar root & array of scalars.
	sc_doc, _ := json.build(transmute([]u8)string("42"))
	defer json.destroy(&sc_doc)
	sc_md, scerr := write.write_markdown(&sc_doc, {compact = true})
	defer delete(sc_md)
	testing.expect_value(t, scerr, nil)
	testing.expectf(t, string(sc_md) == "| value |\n| ---: |\n| 42 |\n", "sc_md: %q", sc_md)

	sc_arr_doc, _ := json.build(transmute([]u8)string(`[10,20,30]`))
	defer json.destroy(&sc_arr_doc)
	sc_arr_tbl, saerr := write.write_table(&sc_arr_doc, {style = .Compact, value_header = "num"})
	defer delete(sc_arr_tbl)
	testing.expect_value(t, saerr, nil)
	testing.expectf(t, string(sc_arr_tbl) == "num\n 10\n 20\n 30\n", "sc_arr_tbl: %q", sc_arr_tbl)

	// Mixed array (objects + arrays + scalars): single column with compact inline JSON for containers.
	mix_doc, _ := json.build(transmute([]u8)string(`[{"a":1},[2,3],"ok"]`))
	defer json.destroy(&mix_doc)
	mix_md, merr := write.write_markdown(&mix_doc, {compact = true})
	defer delete(mix_md)
	testing.expect_value(t, merr, nil)
	testing.expectf(t, string(mix_md) == "| value |\n| --- |\n| {\"a\":1} |\n| [2,3] |\n| ok |\n", "mix_md: %q", mix_md)

	// Nested objects/arrays inside object cells (including pipes & quotes!).
	nest_src := `[{"id":1,"meta":{"z":true,"a":"p|q"},"tags":[1,2]}]`
	nest_doc, _ := json.build(transmute([]u8)nest_src)
	defer json.destroy(&nest_doc)
	nest_md, nerr := write.write_markdown(&nest_doc, {compact = true, sort_keys = true})
	defer delete(nest_md)
	testing.expect_value(t, nerr, nil)
	testing.expectf(
		t,
		string(nest_md) == "| id | meta | tags |\n| ---: | --- | --- |\n| 1 | {\"a\":\"p\\|q\",\"z\":true} | [1,2] |\n",
		"nest_md: %q",
		nest_md,
	)

	// Empty inputs produce 0 bytes without error.
	for empty_src in ([?]string{"[]", "{}", "[{},{}]", "[[],[]]"}) {
		ed, _ := json.build(transmute([]u8)empty_src)
		defer json.destroy(&ed)
		et, terr := write.write_table(&ed)
		defer delete(et)
		em, merr2 := write.write_markdown(&ed)
		defer delete(em)
		testing.expectf(t, terr == nil && len(et) == 0, "empty table %s: %q %v", empty_src, et, terr)
		testing.expectf(t, merr2 == nil && len(em) == 0, "empty md %s: %q %v", empty_src, em, merr2)
	}
}

@(test)
render_utf8_width_control_chars_and_truncation :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Display width sanity checks.
	testing.expect_value(t, write.display_width("hello"), 5)
	testing.expect_value(t, write.display_width("café"), 4)
	testing.expect_value(t, write.display_width("cafe\u0301"), 4) // combining acute accent
	testing.expect_value(t, write.display_width("日本語"), 6) // 3 CJK wide chars
	testing.expect_value(t, write.display_width("hi日本!"), 7)
	testing.expect_value(t, write.display_width("🚀"), 2)

	// Box table with CJK wide chars, combining marks, and control chars (\n, \r, \t, \x00, \x1b).
	src := "[{\"label\":\"日本語\",\"note\":\"a\\nb\\tc\"},{\"label\":\"cafe\u0301\",\"note\":\"x\\u0000\\u001by\"}]"
	doc, berr := json.build(transmute([]u8)src)
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)

	boxed, err := write.write_table(&doc, {style = .Box})
	defer delete(boxed)
	testing.expect_value(t, err, nil)

	// Verify every line in the box table has the exact same terminal display width!
	lines := strings.split(strings.trim_suffix(string(boxed), "\n"), "\n", context.temp_allocator)
	testing.expect_value(t, len(lines), 6)
	expected_w := write.display_width(lines[0])
	for line, idx in lines {
		testing.expectf(t, write.display_width(line) == expected_w, "line %d width %d != %d: %q", idx, write.display_width(line), expected_w, line)
	}
	// Verify control chars were escaped and never broke rows.
	testing.expect(t, strings.contains(string(boxed), `a\nb\tc`))
	testing.expect(t, strings.contains(string(boxed), `x\x00\x1by`))

	// Truncation with max_col_width on CJK & ASCII.
	trunc_box, terr := write.write_table(&doc, {style = .Box, max_col_width = 4})
	defer delete(trunc_box)
	testing.expect_value(t, terr, nil)
	tlines := strings.split(strings.trim_suffix(string(trunc_box), "\n"), "\n", context.temp_allocator)
	tw := write.display_width(tlines[0])
	for line, idx in tlines {
		testing.expectf(t, write.display_width(line) == tw, "trunc line %d width %d != %d: %q", idx, write.display_width(line), tw, line)
	}
	testing.expect(t, strings.contains(string(trunc_box), "日…"))

	trunc_ascii, taerr := write.write_table(&doc, {style = .Ascii, max_col_width = 4})
	defer delete(trunc_ascii)
	testing.expect_value(t, taerr, nil)
	testing.expectf(t, strings.contains(string(trunc_ascii), "l..."), "trunc_ascii:\n%s", trunc_ascii)
}

@(test)
render_across_all_source_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. JSON5 with NaN / Infinity / hex integer.
	j5_doc, j5_err := json.build(transmute([]u8)string("[{k: 'hex', v: 0xff}, {k: 'nan', v: NaN}, {k: 'inf', v: -Infinity}]"), .Json5)
	defer json.destroy(&j5_doc)
	testing.expect_value(t, j5_err, nil)
	j5_md, j5_werr := write.write_markdown(&j5_doc, {compact = true})
	defer delete(j5_md)
	testing.expect_value(t, j5_werr, nil)
	testing.expectf(t, string(j5_md) == "| k | v |\n| --- | ---: |\n| hex | 255 |\n| nan | NaN |\n| inf | -Infinity |\n", "json5: %q", j5_md)

	// 2. CSV (with infer = true, and duplicate header policy, and header-only, and no_header).
	csv_doc, csv_err := dsv.build(transmute([]u8)string("item,qty\nbolt,12\nnut,3\n"), .Csv, {format = dsv.Dsv_Options{infer = true}})
	defer dsv.destroy(&csv_doc)
	testing.expect_value(t, csv_err, nil)
	csv_tbl, csv_werr := write.write_table(&csv_doc, {style = .Compact})
	defer delete(csv_tbl)
	testing.expect_value(t, csv_werr, nil)
	testing.expectf(t, string(csv_tbl) == "item  qty\nbolt   12\nnut     3\n", "csv: %q", csv_tbl)

	// CSV duplicate column dropped under .Last policy + sort_keys.
	csv_dup, dup_err := dsv.build(transmute([]u8)string("b,a,b\n1,2,3\n"), .Csv, {dups = .Last})
	defer dsv.destroy(&csv_dup)
	testing.expect_value(t, dup_err, nil)
	dup_md, dup_werr := write.write_markdown(&csv_dup, {compact = true, sort_keys = true})
	defer delete(dup_md)
	testing.expect_value(t, dup_werr, nil)
	testing.expectf(t, string(dup_md) == "| a | b |\n| --- | --- |\n| 2 | 3 |\n", "csv_dup: %q", dup_md)

	// CSV header-only.
	csv_hdr, hdr_err := dsv.build(transmute([]u8)string("x,y\n"), .Csv)
	defer dsv.destroy(&csv_hdr)
	testing.expect_value(t, hdr_err, nil)
	hdr_md, hdr_werr := write.write_markdown(&csv_hdr, {compact = true})
	defer delete(hdr_md)
	testing.expect_value(t, hdr_werr, nil)
	testing.expectf(t, string(hdr_md) == "| x | y |\n| --- | --- |\n", "csv_hdr: %q", hdr_md)

	// TSV without header.
	tsv_doc, tsv_err := dsv.build(transmute([]u8)string("alpha\t10\nbeta\t20\n"), .Tsv, {format = dsv.Dsv_Options{no_header = true, infer = true}})
	defer dsv.destroy(&tsv_doc)
	testing.expect_value(t, tsv_err, nil)
	tsv_md, tsv_werr := write.write_markdown(&tsv_doc, {compact = true})
	defer delete(tsv_md)
	testing.expect_value(t, tsv_werr, nil)
	testing.expectf(t, string(tsv_md) == "| 0 | 1 |\n| --- | ---: |\n| alpha | 10 |\n| beta | 20 |\n", "tsv: %q", tsv_md)

	// 3. TOML (single table + subtree [[items]] array of tables via opts.node).
	toml_src := "title = \"demo\"\n[[items]]\nname = \"a\"\ncount = 1\n[[items]]\nname = \"b\"\ncount = 25\n"
	toml_doc, toml_err := toml.build(transmute([]u8)toml_src)
	defer toml.destroy(&toml_doc)
	testing.expect_value(t, toml_err, nil)
	items_node, items_p := toml.member({&toml_doc, nil}, toml.ROOT, "items")
	testing.expect_value(t, items_p, tape.Presence.Found)
	toml_md, toml_werr := write.write_markdown(&toml_doc, {node = items_node, compact = true})
	defer delete(toml_md)
	testing.expect_value(t, toml_werr, nil)
	testing.expectf(t, string(toml_md) == "| name | count |\n| --- | ---: |\n| a | 1 |\n| b | 25 |\n", "toml items: %q", toml_md)

	// 4. XML (object tree with repeated sibling tags rendered in .Key_Value mode).
	xml_src := "<root><item>one</item><item>two</item></root>"
	xml_doc, xml_err := xml.build(transmute([]u8)xml_src)
	defer xml.destroy(&xml_doc)
	testing.expect_value(t, xml_err, nil)
	root_el, root_p := xml.member({&xml_doc, nil}, xml.ROOT, "root")
	testing.expect_value(t, root_p, tape.Presence.Found)
	xml_tbl, xml_werr := write.write_table(&xml_doc, {node = root_el, style = .Compact})
	defer delete(xml_tbl)
	testing.expect_value(t, xml_werr, nil)
	testing.expectf(t, string(xml_tbl) == "key   value\nitem  one\nitem  two\n", "xml: %q", xml_tbl)

	// 5. YAML (sequence of mappings).
	yaml_src := "- name: alice\n  score: 100\n- name: bob\n  score: 85\n"
	yaml_doc, yaml_err := yaml.build(transmute([]u8)yaml_src)
	defer yaml.destroy(&yaml_doc)
	testing.expect_value(t, yaml_err, nil)
	yaml_tbl, yaml_werr := write.write_table(&yaml_doc, {style = .Compact})
	defer delete(yaml_tbl)
	testing.expect_value(t, yaml_werr, nil)
	testing.expectf(t, string(yaml_tbl) == "name   score\nalice    100\nbob       85\n", "yaml: %q", yaml_tbl)

	// 6. CBOR (binary document round-tripped from JSON, plus raw CBOR byte string & int map key).
	j_doc, _ := json.build(transmute([]u8)string(`[{"id":1,"tag":"ok"},{"id":2,"tag":"done"}]`))
	defer json.destroy(&j_doc)
	cbor_bytes, _, cwerr := cbor.write(&j_doc)
	defer delete(cbor_bytes)
	testing.expect_value(t, cwerr, nil)
	cbor_doc, cberr := cbor.build(cbor_bytes)
	defer cbor.destroy(&cbor_doc)
	testing.expect_value(t, cberr, nil)
	cbor_md, cmerr := write.write_markdown(&cbor_doc, {compact = true})
	defer delete(cbor_md)
	testing.expect_value(t, cmerr, nil)
	testing.expectf(t, string(cbor_md) == "| id | tag |\n| ---: | --- |\n| 1 | ok |\n| 2 | done |\n", "cbor: %q", cbor_md)

	// Raw CBOR map with integer key (1) -> byte string ("hi" = 0x68 0x69 -> base64 "aGk="): A1 01 42 68 69.
	raw_cbor := []u8{0xA1, 0x01, 0x42, 0x68, 0x69}
	raw_cbor_doc, rcerr := cbor.build(raw_cbor)
	defer cbor.destroy(&raw_cbor_doc)
	testing.expect_value(t, rcerr, nil)
	rc_tbl, rtwerr := write.write_table(&raw_cbor_doc, {style = .Compact})
	defer delete(rc_tbl)
	testing.expect_value(t, rtwerr, nil)
	testing.expectf(t, string(rc_tbl) == "key  value\n1    aGk=\n", "cbor raw bytes: %q", rc_tbl)
}

@(test)
render_docs_batch_streaming_sinks_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Multi-document batch (simulating NDJSON records).
	d1, _ := json.build(transmute([]u8)string(`{"id":1,"name":"alice"}`))
	defer json.destroy(&d1)
	d2, _ := json.build(transmute([]u8)string(`{"id":2,"name":"bob","role":"admin"}`))
	defer json.destroy(&d2)
	docs := [?]tape.Document{d1, d2}

	batch_tbl, bterr := write.write_table_docs(docs[:], {style = .Compact})
	defer delete(batch_tbl)
	testing.expect_value(t, bterr, nil)
	testing.expectf(t, string(batch_tbl) == "id  name   role\n 1  alice\n 2  bob    admin\n", "batch_tbl: %q", batch_tbl)

	batch_md, bmerr := write.write_markdown_docs(docs[:], {compact = true})
	defer delete(batch_md)
	testing.expect_value(t, bmerr, nil)
	testing.expectf(t, string(batch_md) == "| id | name | role |\n| ---: | --- | --- |\n| 1 | alice |  |\n| 2 | bob | admin |\n", "batch_md: %q", batch_md)

	// Empty docs slice -> empty output.
	empty_docs, ederr := write.write_table_docs(nil)
	defer delete(empty_docs)
	testing.expectf(t, ederr == nil && len(empty_docs) == 0, "empty_docs: %q %v", empty_docs, ederr)

	// Sink streaming (`write_table_to`, `write_markdown_to`, `write_table_docs_to`, `write_markdown_docs_to`).
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	testing.expect_value(t, write.write_table_docs_to(bytes.buffer_to_stream(&buf), docs[:], {style = .Compact}), nil)
	testing.expectf(t, bytes.buffer_to_string(&buf) == string(batch_tbl), "sink tbl mismatch")

	bytes.buffer_reset(&buf)
	testing.expect_value(t, write.write_markdown_docs_to(bytes.buffer_to_stream(&buf), docs[:], {compact = true}), nil)
	testing.expectf(t, bytes.buffer_to_string(&buf) == string(batch_md), "sink md mismatch")

	// Streaming token writers (framed = true for multi-record stream).
	tw: write.Table_Render_Writer
	testing.expect_value(t, write.table_render_writer_start(&tw, {style = .Compact}, {}, true), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .Object), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .Key, "k"), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .String, "v1"), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .Close), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .Object), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .Key, "k"), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .String, "v2"), nil)
	testing.expect_value(t, write.table_render_writer_token(&tw, .Close), nil)
	tw_out, tw_err := write.table_render_writer_end(&tw)
	defer delete(tw_out)
	testing.expect_value(t, tw_err, nil)
	testing.expectf(t, string(tw_out) == "k\nv1\nv2\n", "tw_out: %q", tw_out)

	mw: write.Markdown_Writer
	bytes.buffer_reset(&buf)
	testing.expect_value(t, write.markdown_writer_start(&mw, {compact = true}, bytes.buffer_to_stream(&buf), true), nil)
	testing.expect_value(t, write.markdown_writer_token(&mw, .Object), nil)
	testing.expect_value(t, write.markdown_writer_token(&mw, .Key, "n"), nil)
	testing.expect_value(t, write.markdown_writer_token(&mw, .Number, "10"), nil)
	testing.expect_value(t, write.markdown_writer_token(&mw, .Close), nil)
	mw_out, mw_err := write.markdown_writer_end(&mw)
	testing.expectf(t, mw_err == nil && mw_out == nil, "mw sink: %v", mw_err)
	testing.expectf(t, bytes.buffer_to_string(&buf) == "| n |\n| ---: |\n| 10 |\n", "mw sink out: %q", bytes.buffer_to_string(&buf))

	// Error checks: nil sink, negative max_col_width, invalid node, partial scan doc, malformed token stream.
	testing.expect_value(t, write.write_table_to({}, &d1), write.Error(tape.Bad_Option{"sink"}))
	testing.expect_value(t, write.write_markdown_to({}, &d1), write.Error(tape.Bad_Option{"sink"}))
	_, neg_err := write.write_table(&d1, {max_col_width = -1})
	testing.expect_value(t, neg_err, write.Error(tape.Bad_Option{"max_col_width"}))
	_, bad_node := write.write_markdown(&d1, {node = 999})
	testing.expect_value(t, bad_node, write.Error(tape.Bad_Option{"node"}))

	demand, _ := tape.demand_of([][]tape.Step{{tape.Index(0)}})
	defer tape.destroy(&demand)
	part, perr := json.scan(transmute([]u8)string(`[{"a":1},{"a":2}]`), &demand)
	defer json.destroy(&part)
	testing.expect_value(t, perr, nil)
	_, p_terr := write.write_table(&part)
	_, p_merr := write.write_markdown(&part)
	r1, ok1 := p_terr.(write.Refused)
	r2, ok2 := p_merr.(write.Refused)
	testing.expectf(t, ok1 && r1.why == .Partial, "partial table: %v", p_terr)
	testing.expectf(t, ok2 && r2.why == .Partial, "partial md: %v", p_merr)

	bad_mw: write.Markdown_Writer
	testing.expect_value(t, write.markdown_writer_start(&bad_mw), nil)
	testing.expect_value(t, write.markdown_writer_token(&bad_mw, .Object), nil)
	_, mal_err := write.markdown_writer_end(&bad_mw)
	r3, ok3 := mal_err.(write.Refused)
	testing.expectf(t, ok3 && r3.why == .Malformed, "malformed writer: %v", mal_err)
}

@(private = "file")
Render_Sweep_Run :: struct {
	doc:      ^tape.Document,
	markdown: bool,
	sink:     bool,
	sort:     bool,
	box:      bool,
}

@(private = "file")
render_sweep_one :: proc(data: rawptr, a: runtime.Allocator) {
	r := (^Render_Sweep_Run)(data)
	if r.markdown {
		opts := write.Markdown_Options{sort_keys = r.sort}
		if r.sink {
			taken: bytes.Buffer
			bytes.buffer_init_allocator(&taken, 0, 0, context.allocator)
			defer bytes.buffer_destroy(&taken)
			err := write.write_markdown_to(bytes.buffer_to_stream(&taken), r.doc, opts, a)
			if err != nil {
				_ = err.(runtime.Allocator_Error)
			}
			return
		}
		text, err := write.write_markdown(r.doc, opts, a)
		if err == nil {
			delete(text, a)
		} else {
			_ = err.(runtime.Allocator_Error)
		}
		return
	}
	opts := write.Table_Render_Options{
		style     = .Box if r.box else .Plain,
		sort_keys = r.sort,
	}
	if r.sink {
		taken: bytes.Buffer
		bytes.buffer_init_allocator(&taken, 0, 0, context.allocator)
		defer bytes.buffer_destroy(&taken)
		err := write.write_table_to(bytes.buffer_to_stream(&taken), r.doc, opts, a)
		if err != nil {
			_ = err.(runtime.Allocator_Error)
		}
		return
	}
	text, err := write.write_table(r.doc, opts, a)
	if err == nil {
		delete(text, a)
	} else {
		_ = err.(runtime.Allocator_Error)
	}
}

@(test)
render_table_markdown_oom_sweep_and_zero_temp :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Exhaustive OOM sweep across JSON (heterogeneous + nested + UTF-8) and CSV (tabular) documents.
	json_src := `[{"z":1,"name":"日本語|a\\b\nc","meta":{"k":true,"arr":[1,2]}},{"name":"alice","extra":null,"z":200}]`
	jdoc, jerr := json.build(transmute([]u8)json_src)
	defer json.destroy(&jdoc)
	testing.expect_value(t, jerr, nil)

	csv_src := "b,a\n1,\"x|y\"\n20,z\n"
	cdoc, cerr := dsv.build(transmute([]u8)csv_src, .Csv, {format = dsv.Dsv_Options{infer = true}})
	defer dsv.destroy(&cdoc)
	testing.expect_value(t, cerr, nil)

	obj_doc, oerr := json.build(transmute([]u8)string(`{"b":[1,2],"a":"hello\nworld"}`))
	defer json.destroy(&obj_doc)
	testing.expect_value(t, oerr, nil)

	docs := [?]^tape.Document{&jdoc, &cdoc, &obj_doc}
	for d in docs {
		for md in ([?]bool{false, true}) {
			for sink in ([?]bool{false, true}) {
				for sort in ([?]bool{false, true}) {
					run := Render_Sweep_Run{doc = d, markdown = md, sink = sink, sort = sort, box = !md && sort}
					s := testkit.sweep_failures(render_sweep_one, &run)
					testing.expectf(t, s.bad == 0 && s.refused >= 1, "oom sweep md=%v sink=%v sort=%v: %v", md, sink, sort, s)
				}
			}
		}
	}

	// 2. Verify zero allocations on `context.temp_allocator`.
	f := testkit.Failing{backing = context.temp_allocator, fail_at = -1}
	prev_temp := context.temp_allocator
	context.temp_allocator = testkit.failing_allocator(&f)
	defer context.temp_allocator = prev_temp

	for d in docs {
		for style in write.Table_Style {
			t_out, terr := write.write_table(d, {style = style, sort_keys = true, max_col_width = 12})
			delete(t_out)
			testing.expect_value(t, terr, nil)
		}
		m_out, merr := write.write_markdown(d, {sort_keys = true})
		delete(m_out)
		testing.expect_value(t, merr, nil)
		m_cmp, mcerr := write.write_markdown(d, {compact = true})
		delete(m_cmp)
		testing.expect_value(t, mcerr, nil)
	}
	batch := [?]tape.Document{jdoc, obj_doc}
	bt, bterr := write.write_table_docs(batch[:], {style = .Box})
	delete(bt)
	testing.expect_value(t, bterr, nil)
	bm, bmerr := write.write_markdown_docs(batch[:])
	delete(bm)
	testing.expect_value(t, bmerr, nil)

	testing.expect_value(t, f.count, 0)
}

@(private = "file")
Writer_Start_Sweep :: struct {
	markdown: bool,
	framed:   bool,
}

@(private = "file")
writer_start_sweep_one :: proc(data: rawptr, a: runtime.Allocator) {
	r := (^Writer_Start_Sweep)(data)
	if r.markdown {
		mw: write.Markdown_Writer
		err := write.markdown_writer_start(&mw, {compact = true}, {}, r.framed, a)
		if err != nil {
			_ = err.(runtime.Allocator_Error)
			return
		}
		if terr := write.markdown_writer_token(&mw, .Object); terr != nil {
			_ = terr.(runtime.Allocator_Error)
			write.markdown_writer_drop(&mw)
			return
		}
		if terr := write.markdown_writer_token(&mw, .Key, "k"); terr != nil {
			_ = terr.(runtime.Allocator_Error)
			write.markdown_writer_drop(&mw)
			return
		}
		if terr := write.markdown_writer_token(&mw, .Number, "1"); terr != nil {
			_ = terr.(runtime.Allocator_Error)
			write.markdown_writer_drop(&mw)
			return
		}
		if terr := write.markdown_writer_token(&mw, .Close); terr != nil {
			_ = terr.(runtime.Allocator_Error)
			write.markdown_writer_drop(&mw)
			return
		}
		text, eerr := write.markdown_writer_end(&mw)
		if eerr == nil {
			delete(text, a)
		} else {
			_ = eerr.(runtime.Allocator_Error)
		}
		return
	}
	tw: write.Table_Render_Writer
	err := write.table_render_writer_start(&tw, {style = .Compact}, {}, r.framed, a)
	if err != nil {
		_ = err.(runtime.Allocator_Error)
		return
	}
	if terr := write.table_render_writer_token(&tw, .Object); terr != nil {
		_ = terr.(runtime.Allocator_Error)
		write.table_render_writer_drop(&tw)
		return
	}
	if terr := write.table_render_writer_token(&tw, .Key, "k"); terr != nil {
		_ = terr.(runtime.Allocator_Error)
		write.table_render_writer_drop(&tw)
		return
	}
	if terr := write.table_render_writer_token(&tw, .Number, "1"); terr != nil {
		_ = terr.(runtime.Allocator_Error)
		write.table_render_writer_drop(&tw)
		return
	}
	if terr := write.table_render_writer_token(&tw, .Close); terr != nil {
		_ = terr.(runtime.Allocator_Error)
		write.table_render_writer_drop(&tw)
		return
	}
	text, eerr := write.table_render_writer_end(&tw)
	if eerr == nil {
		delete(text, a)
	} else {
		_ = eerr.(runtime.Allocator_Error)
	}
}

@(test)
render_audit_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. OOM sweep for framed=true and framed=false streaming token writers (verifies token_tape_drop on start OOM).
	for md in ([?]bool{false, true}) {
		for framed in ([?]bool{false, true}) {
			run := Writer_Start_Sweep{markdown = md, framed = framed}
			s := testkit.sweep_failures(writer_start_sweep_one, &run)
			testing.expectf(t, s.bad == 0 && s.refused >= 1, "writer_start sweep md=%v framed=%v: %v", md, framed, s)
		}
	}

	// 2. mem.nil_allocator() and zero runtime.Allocator{} return .Out_Of_Memory without panicking.
	sample_doc, serr := json.build(transmute([]u8)string(`[{"a":1,"b":"x"}]`))
	defer json.destroy(&sample_doc)
	testing.expect_value(t, serr, nil)
	docs := [?]tape.Document{sample_doc}
	sink_buf: bytes.Buffer
	defer bytes.buffer_destroy(&sink_buf)
	sink := bytes.buffer_to_stream(&sink_buf)

	for bad_alloc in ([?]runtime.Allocator{mem.nil_allocator(), {}}) {
		_, e1 := write.write_table(&sample_doc, {}, bad_alloc)
		testing.expect_value(t, e1, write.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect_value(t, write.write_table_to(sink, &sample_doc, {}, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))
		_, e2 := write.write_table_docs(docs[:], {}, bad_alloc)
		testing.expect_value(t, e2, write.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect_value(t, write.write_table_docs_to(sink, docs[:], {}, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))

		_, e3 := write.write_markdown(&sample_doc, {}, bad_alloc)
		testing.expect_value(t, e3, write.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect_value(t, write.write_markdown_to(sink, &sample_doc, {}, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))
		_, e4 := write.write_markdown_docs(docs[:], {}, bad_alloc)
		testing.expect_value(t, e4, write.Error(runtime.Allocator_Error.Out_Of_Memory))
		testing.expect_value(t, write.write_markdown_docs_to(sink, docs[:], {}, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))

		// Valid write.Out with nil/mem.nil_allocator() passed to write_*_out.
		out: write.Out
		testing.expect_value(t, write.out_start(&out, context.allocator, {}, write.ROOM_MAX), nil)
		testing.expect_value(t, write.write_table_out(&out, &sample_doc, {}, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))
		write.out_drop(&out)

		testing.expect_value(t, write.out_start(&out, context.allocator, {}, write.ROOM_MAX), nil)
		testing.expect_value(t, write.write_markdown_out(&out, &sample_doc, {}, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))
		write.out_drop(&out)

		tw: write.Table_Render_Writer
		testing.expect_value(t, write.table_render_writer_start(&tw, {}, {}, true, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))
		mw: write.Markdown_Writer
		testing.expect_value(t, write.markdown_writer_start(&mw, {}, {}, true, bad_alloc), write.Error(runtime.Allocator_Error.Out_Of_Memory))
	}

	// 3. opts.node pointing directly to a DSV row .Object (no key nodes, keys live in Tabular_Ext.keys).
	csv_doc, cerr := dsv.build(transmute([]u8)string("name,qty\nbolt,12\nnut,3\n"), .Csv, {format = dsv.Dsv_Options{infer = true}})
	defer dsv.destroy(&csv_doc)
	testing.expect_value(t, cerr, nil)
	row0, row0_p := dsv.element({&csv_doc, nil}, dsv.ROOT, 0)
	testing.expect_value(t, row0_p, tape.Presence.Found)

	row_kv, rkv_err := write.write_table(&csv_doc, {node = row0, style = .Compact})
	defer delete(row_kv)
	testing.expect_value(t, rkv_err, nil)
	testing.expectf(t, string(row_kv) == "key   value\nname  bolt\nqty   12\n", "dsv row kv: %q", row_kv)

	row_md, rmd_err := write.write_markdown(&csv_doc, {node = row0, object_layout = .Row, compact = true})
	defer delete(row_md)
	testing.expect_value(t, rmd_err, nil)
	testing.expectf(t, string(row_md) == "| name | qty |\n| --- | ---: |\n| bolt | 12 |\n", "dsv row md: %q", row_md)

	// Multi-doc batch with opts.node pointing to a DSV row .Object.
	csv_docs := [?]tape.Document{csv_doc}
	batch_dsv_row, bderr := write.write_markdown_docs(csv_docs[:], {node = row0, compact = true})
	defer delete(batch_dsv_row)
	testing.expect_value(t, bderr, nil)
	testing.expectf(t, string(batch_dsv_row) == "| name | qty |\n| --- | ---: |\n| bolt | 12 |\n", "dsv row batch: %q", batch_dsv_row)

	// 4. CBOR .Bytes keys (single base64, NOT double-base64) + YAML !!binary & .Number keys (1e0, .inf, -.inf, .nan).
	// CBOR: [{ h'6869': 42 }] -> 81 A1 42 68 69 18 2A (h'6869' = "hi" -> base64 "aGk=").
	cbor_bkey := []u8{0x81, 0xA1, 0x42, 0x68, 0x69, 0x18, 0x2A}
	cbor_bkey_doc, cbk_err := cbor.build(cbor_bkey)
	defer cbor.destroy(&cbor_bkey_doc)
	testing.expect_value(t, cbk_err, nil)
	cbk_md, cbk_werr := write.write_markdown(&cbor_bkey_doc, {compact = true})
	defer delete(cbk_md)
	testing.expect_value(t, cbk_werr, nil)
	testing.expectf(t, string(cbk_md) == "| aGk= |\n| ---: |\n| 42 |\n", "cbor bytes key: %q", cbk_md)

	// Nested CBOR map with .Bytes key inside a cell: [{ "m": { h'6869': 7 } }] -> 81 A1 61 6D A1 42 68 69 07.
	cbor_nested_bkey := []u8{0x81, 0xA1, 0x61, 0x6D, 0xA1, 0x42, 0x68, 0x69, 0x07}
	cbor_nb_doc, cnb_err := cbor.build(cbor_nested_bkey)
	defer cbor.destroy(&cbor_nb_doc)
	testing.expect_value(t, cnb_err, nil)
	cnb_md, cnb_werr := write.write_markdown(&cbor_nb_doc, {compact = true})
	defer delete(cnb_md)
	testing.expect_value(t, cnb_werr, nil)
	testing.expectf(t, string(cnb_md) == "| m |\n| --- |\n| {\"aGk=\":7} |\n", "cbor nested bytes key: %q", cnb_md)

	// YAML array of mappings with !!binary key and .Number keys (1e0, .inf, -.inf, .nan).
	yaml_keys_src := "- !!binary aGk=: 1\n  1e0: 2\n  .inf: 3\n  -.inf: 4\n  .nan: 5\n"
	yaml_keys_doc, yk_err := yaml.build(transmute([]u8)yaml_keys_src)
	defer yaml.destroy(&yaml_keys_doc)
	testing.expect_value(t, yk_err, nil)
	yk_md, yk_werr := write.write_markdown(&yaml_keys_doc, {compact = true})
	defer delete(yk_md)
	testing.expect_value(t, yk_werr, nil)
	// Every cell value (1, 2, 3, 4, 5) MUST be found via tape.member (not dropped to absent) and aGk= NOT double-encoded.
	testing.expectf(t, strings.contains(string(yk_md), "| aGk= |"), "yaml binary key not double-base64: %q", yk_md)
	testing.expectf(t, strings.contains(string(yk_md), "| 1 | 2 | 3 | 4 | 5 |\n"), "yaml number keys matched values: %q", yk_md)

	// 5. Synthetic tape.Document with container keys ([1, 2]) + duplicate container key (.Last policy) + OOM sweep on find_container_key_member.
	ck_src := "12firstlast"
	ck_nodes := [?]tape.Node{
		{kind = .Array, role = .Value, n = 10, spelling = 1},
		{kind = .Object, role = .Value, n = 9, spelling = 2},
		{kind = .Array, role = .Key, n = 3, spelling = 2},
		{kind = .Number, role = .Value, lo = 0, n = 1},
		{kind = .Number, role = .Value, lo = 1, n = 1},
		{kind = .String, role = .Value, lo = 2, n = 5},
		{kind = .Array, role = .Key, n = 3, spelling = 2},
		{kind = .Number, role = .Value, lo = 0, n = 1},
		{kind = .Number, role = .Value, lo = 1, n = 1},
		{kind = .String, role = .Value, lo = 7, n = 4},
	}
	ck_doc := tape.Document{src = transmute([]u8)ck_src, nodes = ck_nodes[:], format = json.as(.Json)}
	ck_md, ck_werr := write.write_markdown(&ck_doc, {compact = true})
	defer delete(ck_md)
	testing.expect_value(t, ck_werr, nil)
	testing.expectf(t, string(ck_md) == "| [1,2] |\n| --- |\n| last |\n", "container key dup .Last: %q", ck_md)

	ck_run := Render_Sweep_Run{doc = &ck_doc, markdown = true, sink = false, sort = false}
	ck_sweep := testkit.sweep_failures(render_sweep_one, &ck_run)
	testing.expectf(t, ck_sweep.bad == 0 && ck_sweep.refused >= 1, "container key oom sweep: %v", ck_sweep)

	// 6. opts.node = tape.NO_NODE returns Bad_Option{"node"} (safe on 32-bit wasm32 without signed wrap to -1).
	_, no_node_tbl := write.write_table(&sample_doc, {node = tape.NO_NODE})
	testing.expect_value(t, no_node_tbl, write.Error(tape.Bad_Option{"node"}))
	_, no_node_md := write.write_markdown(&sample_doc, {node = tape.NO_NODE})
	testing.expect_value(t, no_node_md, write.Error(tape.Bad_Option{"node"}))
	_, no_node_docs := write.write_table_docs(docs[:], {node = tape.NO_NODE})
	testing.expect_value(t, no_node_docs, write.Error(tape.Bad_Option{"node"}))

	// Bonus: .Plain underline alignment when col 0 has empty header and empty cell.
	empty_col_doc, ec_err := json.build(transmute([]u8)string(`[{"":"","b":1}]`))
	defer json.destroy(&empty_col_doc)
	testing.expect_value(t, ec_err, nil)
	ec_tbl, ec_werr := write.write_table(&empty_col_doc, {style = .Plain})
	defer delete(ec_tbl)
	testing.expect_value(t, ec_werr, nil)
	want_ec := "   b\n-  -\n   1\n"
	testing.expectf(t, string(ec_tbl) == want_ec, "empty col plain:\n%q\nwant:\n%q", ec_tbl, want_ec)

	// Bonus: max_col_width = 1 and 2 with .Ascii ellipsis ("." and "..").
	wide_doc, _ := json.build(transmute([]u8)string(`[{"header":"abcdef"}]`))
	defer json.destroy(&wide_doc)
	a1, a1_err := write.write_table(&wide_doc, {style = .Ascii, max_col_width = 1})
	defer delete(a1)
	testing.expect_value(t, a1_err, nil)
	testing.expectf(t, strings.contains(string(a1), "| . |\n"), "ascii max_col_width=1: %q", a1)
	a2, a2_err := write.write_table(&wide_doc, {style = .Ascii, max_col_width = 2})
	defer delete(a2)
	testing.expect_value(t, a2_err, nil)
	testing.expectf(t, strings.contains(string(a2), "| .. |\n"), "ascii max_col_width=2: %q", a2)

	// Bonus: XML repeated sibling tags under .Key_Value preserve every element in document order.
	xml_rep_doc, xr_err := xml.build(transmute([]u8)string("<list><x>1</x><x>2</x><y>3</y><x>4</x></list>"))
	defer xml.destroy(&xml_rep_doc)
	testing.expect_value(t, xr_err, nil)
	list_el, list_p := xml.member({&xml_rep_doc, nil}, xml.ROOT, "list")
	testing.expect_value(t, list_p, tape.Presence.Found)
	xr_md, xr_werr := write.write_markdown(&xml_rep_doc, {node = list_el, compact = true})
	defer delete(xr_md)
	testing.expect_value(t, xr_werr, nil)
	testing.expectf(t, string(xr_md) == "| key | value |\n| --- | --- |\n| x | 1 |\n| x | 2 |\n| y | 3 |\n| x | 4 |\n", "xml repeated: %q", xr_md)
}
