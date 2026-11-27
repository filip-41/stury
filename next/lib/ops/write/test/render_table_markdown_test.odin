package write_tests

import "base:runtime"
import "core:bytes"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
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

@(private = "file")
expect_tbl :: proc(t: ^testing.T, doc: ^tape.Document, want: string, opts := write.Table_Render_Options{}, loc := #caller_location) {
	got, err := write.write_table(doc, opts)
	defer delete(got)
	testing.expectf(t, err == nil && string(got) == want, "table: %v\ngot:\n%q\nwant:\n%q", err, got, want, loc = loc)
}

@(private = "file")
expect_md :: proc(t: ^testing.T, doc: ^tape.Document, want: string, opts := write.Markdown_Options{}, loc := #caller_location) {
	got, err := write.write_markdown(doc, opts)
	defer delete(got)
	testing.expectf(t, err == nil && string(got) == want, "markdown: %v\ngot:\n%q\nwant:\n%q", err, got, want, loc = loc)
}

@(private = "file")
expect_json_tbl :: proc(t: ^testing.T, src, want: string, opts := write.Table_Render_Options{}, spec := json.Spec.Json, loc := #caller_location) {
	doc, err := json.build(transmute([]u8)src, spec)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil, loc = loc)
	expect_tbl(t, &doc, want, opts, loc)
}

@(private = "file")
expect_json_md :: proc(t: ^testing.T, src, want: string, opts := write.Markdown_Options{}, spec := json.Spec.Json, loc := #caller_location) {
	doc, err := json.build(transmute([]u8)src, spec)
	defer json.destroy(&doc)
	testing.expect_value(t, err, nil, loc = loc)
	expect_md(t, &doc, want, opts, loc)
}

@(test)
render_table_styles_and_alignment :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, berr := json.build(transmute([]u8)string(`[{"name":"alice","age":30,"active":true},{"name":"bob","age":7,"active":false}]`))
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)

	expect_tbl(t, &doc, "name   age  active\n-----  ---  ------\nalice   30  true\nbob      7  false\n")
	expect_tbl(t, &doc, "name   age  active\nalice   30  true\nbob      7  false\n", {style = .Compact})
	expect_tbl(t, &doc, "┌───────┬─────┬────────┐\n│ name  │ age │ active │\n├───────┼─────┼────────┤\n│ alice │  30 │ true   │\n│ bob   │   7 │ false  │\n└───────┴─────┴────────┘\n", {style = .Box})
	expect_tbl(t, &doc, "+-------+-----+--------+\n| name  | age | active |\n+-------+-----+--------+\n| alice |  30 | true   |\n| bob   |   7 | false  |\n+-------+-----+--------+\n", {style = .Ascii})
	expect_tbl(t, &doc, "alice 30 true\nbob   7  false\n", {style = .Plain, align = .Left, no_header = true, column_gap = 1})
	expect_tbl(t, &doc, " name  age  active\nalice   30    true\n  bob    7   false\n", {style = .Compact, align = .Right})

	// Numeric column with null: numbers right-align while null left-aligns under .Auto, plus custom null_text.
	null_doc, _ := json.build(transmute([]u8)string(`[{"k":"a","v":10000},{"k":"b","v":null},{"k":"c","v":7}]`))
	defer json.destroy(&null_doc)
	expect_tbl(t, &null_doc, "┌───┬───────┐\n│ k │     v │\n├───┼───────┤\n│ a │ 10000 │\n│ b │ null  │\n│ c │     7 │\n└───┴───────┘\n", {style = .Box})
	expect_tbl(t, &null_doc, "k      v\na  10000\nb\nc      7\n", {style = .Compact, null_text = ""})
}

@(test)
render_markdown_tables_and_escaping :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, berr := json.build(transmute([]u8)string(`[{"col1":"val","col2":42},{"col1":"a|b\\c\nd\r\ne","col2":7}]`))
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)

	expect_md(t, &doc, "| col1 | col2 |\n| --- | ---: |\n| val | 42 |\n| a\\|b\\\\c<br>d<br>e | 7 |\n", {compact = true})
	expect_md(t, &doc, "| col1              | col2 |\n| ----------------- | ---: |\n| val               |   42 |\n| a\\|b\\\\c<br>d<br>e |    7 |\n")

	for tc in ([?]struct { align: write.Column_Align, sep: string }{{.Left, "| --- | --- |\n"}, {.Right, "| ---: | ---: |\n"}}) {
		md, err := write.write_markdown(&doc, {compact = true, align = tc.align})
		defer delete(md)
		testing.expect(t, err == nil && strings.contains(string(md), tc.sep))
	}
}

@(test)
render_shapes_heterogeneous_nested_and_empty :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Heterogeneous array of objects: union of keys in first-seen order, and sort_keys = true.
	het_doc, _ := json.build(transmute([]u8)string(`[{"z":1,"a":"x"},{"a":"y","m":true},{"z":3,"b":null}]`))
	defer json.destroy(&het_doc)
	expect_md(t, &het_doc, "| z | a | m | b |\n| ---: | --- | --- | --- |\n| 1 | x |  |  |\n|  | y | true |  |\n| 3 |  |  | null |\n", {compact = true})
	expect_md(t, &het_doc, "| a | b | m | z |\n| --- | --- | --- | ---: |\n| x |  |  | 1 |\n| y |  | true |  |\n|  | null |  | 3 |\n", {compact = true, sort_keys = true})

	// Array of arrays, single object (.Key_Value vs .Row), scalar root, array of scalars, mixed array, nested cells.
	expect_json_tbl(t, `[[1,"x"],[2,"y",true]]`, "0  1  2\n1  x\n2  y  true\n", {style = .Compact})
	expect_json_tbl(t, `{"b":2,"a":"hi"}`, "key  value\na    hi\nb    2\n", {style = .Compact, sort_keys = true})
	expect_json_md(t, `{"b":2,"a":"hi"}`, "| a | b |\n| --- | ---: |\n| hi | 2 |\n", {object_layout = .Row, compact = true, sort_keys = true})
	expect_json_md(t, `42`, "| value |\n| ---: |\n| 42 |\n", {compact = true})
	expect_json_tbl(t, `[10,20,30]`, "num\n 10\n 20\n 30\n", {style = .Compact, value_header = "num"})
	expect_json_md(t, `[{"a":1},[2,3],"ok"]`, "| value |\n| --- |\n| {\"a\":1} |\n| [2,3] |\n| ok |\n", {compact = true})
	expect_json_md(t, `[{"id":1,"meta":{"z":true,"a":"p|q"},"tags":[1,2]}]`, "| id | meta | tags |\n| ---: | --- | --- |\n| 1 | {\"a\":\"p\\|q\",\"z\":true} | [1,2] |\n", {compact = true, sort_keys = true})

	// Empty inputs produce 0 bytes without error.
	for empty_src in ([?]string{"[]", "{}", "[{},{}]", "[[],[]]"}) {
		expect_json_tbl(t, empty_src, "")
		expect_json_md(t, empty_src, "")
	}
}

@(private = "file")
test_display_width :: proc "contextless" (s: string) -> int {
	total := 0
	for i := 0; i < len(s); {
		r, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 {
			sz = 1
		}
		switch {
		case r < 0x20 || (r >= 0x7F && r < 0xA0) || (r >= 0x0300 && r <= 0x036F):
		case (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x1F300 && r <= 0x1FAFF):
			total += 2
		case:
			total += 1
		}
		i += sz
	}
	return total
}

@(private = "file")
expect_uniform_width :: proc(t: ^testing.T, out: []u8, want_lines := 0, loc := #caller_location) {
	lines := strings.split(strings.trim_suffix(string(out), "\n"), "\n", context.temp_allocator)
	if want_lines > 0 {
		testing.expect_value(t, len(lines), want_lines, loc = loc)
	}
	expected_w := test_display_width(lines[0])
	for line, idx in lines {
		testing.expectf(t, test_display_width(line) == expected_w, "line %d width %d != %d: %q", idx, test_display_width(line), expected_w, line, loc = loc)
	}
}

@(test)
render_utf8_width_control_chars_and_truncation :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, berr := json.build(transmute([]u8)string("[{\"label\":\"日本語\",\"note\":\"a\\nb\\tc\"},{\"label\":\"cafe\u0301\",\"note\":\"x\\u0000\\u001by\"}]"))
	defer json.destroy(&doc)
	testing.expect_value(t, berr, nil)

	boxed, err := write.write_table(&doc, {style = .Box})
	defer delete(boxed)
	testing.expect_value(t, err, nil)
	expect_uniform_width(t, boxed, 6)
	testing.expect(t, strings.contains(string(boxed), `a\nb\tc`) && strings.contains(string(boxed), `x\x00\x1by`))

	trunc_box, terr := write.write_table(&doc, {style = .Box, max_col_width = 4})
	defer delete(trunc_box)
	testing.expect_value(t, terr, nil)
	expect_uniform_width(t, trunc_box)
	testing.expect(t, strings.contains(string(trunc_box), "日…"))

	trunc_ascii, taerr := write.write_table(&doc, {style = .Ascii, max_col_width = 4})
	defer delete(trunc_ascii)
	testing.expect(t, taerr == nil && strings.contains(string(trunc_ascii), "l..."))
}

@(test)
render_across_all_source_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. JSON5 with NaN / Infinity / hex integer.
	expect_json_md(t, "[{k: 'hex', v: 0xff}, {k: 'nan', v: NaN}, {k: 'inf', v: -Infinity}]", "| k | v |\n| --- | ---: |\n| hex | 255 |\n| nan | NaN |\n| inf | -Infinity |\n", {compact = true}, .Json5)

	// 2. CSV (infer, duplicate header .Last + sort_keys, header-only) and TSV (no_header).
	csv_doc, csv_err := dsv.build(transmute([]u8)string("item,qty\nbolt,12\nnut,3\n"), .Csv, {format = dsv.Dsv_Options{infer = true}})
	csv_dup, dup_err := dsv.build(transmute([]u8)string("b,a,b\n1,2,3\n"), .Csv, {dups = .Last})
	csv_hdr, hdr_err := dsv.build(transmute([]u8)string("x,y\n"), .Csv)
	tsv_doc, tsv_err := dsv.build(transmute([]u8)string("alpha\t10\nbeta\t20\n"), .Tsv, {format = dsv.Dsv_Options{no_header = true, infer = true}})
	defer {
		dsv.destroy(&csv_doc)
		dsv.destroy(&csv_dup)
		dsv.destroy(&csv_hdr)
		dsv.destroy(&tsv_doc)
	}
	testing.expect(t, csv_err == nil && dup_err == nil && hdr_err == nil && tsv_err == nil)
	expect_tbl(t, &csv_doc, "item  qty\nbolt   12\nnut     3\n", {style = .Compact})
	expect_md(t, &csv_dup, "| a | b |\n| --- | --- |\n| 2 | 3 |\n", {compact = true, sort_keys = true})
	expect_md(t, &csv_hdr, "| x | y |\n| --- | --- |\n", {compact = true})
	expect_md(t, &tsv_doc, "| 0 | 1 |\n| --- | ---: |\n| alpha | 10 |\n| beta | 20 |\n", {compact = true})

	// 3. TOML subtree [[items]], 4. XML repeated tags, 5. YAML sequence of mappings.
	toml_doc, toml_err := toml.build(transmute([]u8)string("title = \"demo\"\n[[items]]\nname = \"a\"\ncount = 1\n[[items]]\nname = \"b\"\ncount = 25\n"))
	xml_doc, xml_err := xml.build(transmute([]u8)string("<root><item>one</item><item>two</item></root>"))
	yaml_doc, yaml_err := yaml.build(transmute([]u8)string("- name: alice\n  score: 100\n- name: bob\n  score: 85\n"))
	defer {
		toml.destroy(&toml_doc)
		xml.destroy(&xml_doc)
		yaml.destroy(&yaml_doc)
	}
	testing.expect(t, toml_err == nil && xml_err == nil && yaml_err == nil)
	items_node, items_p := toml.member({&toml_doc, nil}, toml.ROOT, "items")
	root_el, root_p := xml.member({&xml_doc, nil}, xml.ROOT, "root")
	testing.expect(t, items_p == .Found && root_p == .Found)
	expect_md(t, &toml_doc, "| name | count |\n| --- | ---: |\n| a | 1 |\n| b | 25 |\n", {node = items_node, compact = true})
	expect_tbl(t, &xml_doc, "key   value\nitem  one\nitem  two\n", {node = root_el, style = .Compact})
	expect_tbl(t, &yaml_doc, "name   score\nalice    100\nbob       85\n", {style = .Compact})

	// 6. CBOR round-trip from JSON, plus raw CBOR map with int key -> byte string ("hi" -> "aGk=").
	j_doc, _ := json.build(transmute([]u8)string(`[{"id":1,"tag":"ok"},{"id":2,"tag":"done"}]`))
	defer json.destroy(&j_doc)
	cbor_bytes, _, cwerr := cbor.write(&j_doc)
	defer delete(cbor_bytes)
	cbor_doc, cberr := cbor.build(cbor_bytes)
	raw_cbor_doc, rcerr := cbor.build([]u8{0xA1, 0x01, 0x42, 0x68, 0x69})
	defer {
		cbor.destroy(&cbor_doc)
		cbor.destroy(&raw_cbor_doc)
	}
	testing.expect(t, cwerr == nil && cberr == nil && rcerr == nil)
	expect_md(t, &cbor_doc, "| id | tag |\n| ---: | --- |\n| 1 | ok |\n| 2 | done |\n", {compact = true})
	expect_tbl(t, &raw_cbor_doc, "key  value\n1    aGk=\n", {style = .Compact})
}

@(test)
render_docs_batch_streaming_sinks_and_errors :: proc(t: ^testing.T) {
	testkit.deadline(t)

	d1, _ := json.build(transmute([]u8)string(`{"id":1,"name":"alice"}`))
	d2, _ := json.build(transmute([]u8)string(`{"id":2,"name":"bob","role":"admin"}`))
	defer json.destroy(&d1)
	defer json.destroy(&d2)
	docs := [?]tape.Document{d1, d2}

	batch_tbl, bterr := write.write_table_docs(docs[:], {style = .Compact})
	batch_md, bmerr := write.write_markdown_docs(docs[:], {compact = true})
	empty_docs, ederr := write.write_table_docs(nil)
	defer {
		delete(batch_tbl)
		delete(batch_md)
		delete(empty_docs)
	}
	testing.expect(t, bterr == nil && string(batch_tbl) == "id  name   role\n 1  alice\n 2  bob    admin\n")
	testing.expect(t, bmerr == nil && string(batch_md) == "| id | name | role |\n| ---: | --- | --- |\n| 1 | alice |  |\n| 2 | bob | admin |\n")
	testing.expect(t, ederr == nil && len(empty_docs) == 0)

	// Sink streaming (`write_table_to`, `write_markdown_to`) and `Token_Tape` framed collection.
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	testing.expect_value(t, write.write_table_to(bytes.buffer_to_stream(&buf), &d1, {style = .Compact}), nil)
	testing.expect_value(t, bytes.buffer_to_string(&buf), "key   value\nid    1\nname  alice\n")
	bytes.buffer_reset(&buf)
	testing.expect_value(t, write.write_markdown_to(bytes.buffer_to_stream(&buf), &d1, {compact = true}), nil)
	testing.expect_value(t, bytes.buffer_to_string(&buf), "| key | value |\n| --- | --- |\n| id | 1 |\n| name | alice |\n")

	tt: write.Token_Tape
	testing.expect_value(t, write.token_tape_start(&tt, true, 0, context.allocator), nil)
	defer write.token_tape_drop(&tt)
	for step in ([?]struct { kind: write.Token_Kind, text: string }{
		{.Object, ""}, {.Key, "k"}, {.String, "v1"}, {.Close, ""},
		{.Object, ""}, {.Key, "k"}, {.String, "v2"}, {.Close, ""},
	}) {
		testing.expect_value(t, write.token_tape_take(&tt, step.kind, step.text), nil)
	}
	tt_doc, tt_derr := write.token_tape_document(&tt)
	testing.expect_value(t, tt_derr, nil)
	expect_tbl(t, &tt_doc, "k\nv1\nv2\n", {style = .Compact})
	bytes.buffer_reset(&buf)
	testing.expect_value(t, write.write_markdown_to(bytes.buffer_to_stream(&buf), &tt_doc, {compact = true}), nil)
	testing.expect_value(t, bytes.buffer_to_string(&buf), "| k |\n| --- |\n| v1 |\n| v2 |\n")

	// Error checks: nil sink, negative max_col_width, invalid node, partial scan doc.
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
	testing.expect(t, ok1 && r1.why == .Partial && ok2 && r2.why == .Partial)
}

@(private = "file")
Render_Sweep_Run :: struct {
	doc:                       ^tape.Document,
	markdown, sink, sort, box: bool,
}

@(private = "file")
render_sweep_one :: proc(data: rawptr, a: runtime.Allocator) {
	r := (^Render_Sweep_Run)(data)
	md_opts := write.Markdown_Options{sort_keys = r.sort}
	tbl_opts := write.Table_Render_Options{style = .Box if r.box else .Plain, sort_keys = r.sort}
	err: write.Error
	if r.sink {
		taken: bytes.Buffer
		bytes.buffer_init_allocator(&taken, 0, 0, context.allocator)
		defer bytes.buffer_destroy(&taken)
		s := bytes.buffer_to_stream(&taken)
		err = write.write_markdown_to(s, r.doc, md_opts, a) if r.markdown else write.write_table_to(s, r.doc, tbl_opts, a)
	} else {
		text: []u8
		if r.markdown {
			text, err = write.write_markdown(r.doc, md_opts, a)
		} else {
			text, err = write.write_table(r.doc, tbl_opts, a)
		}
		if err == nil {
			delete(text, a)
		}
	}
	if err != nil {
		_ = err.(runtime.Allocator_Error)
	}
}

@(test)
render_table_markdown_oom_sweep_and_zero_temp :: proc(t: ^testing.T) {
	testkit.deadline(t)

	jdoc, jerr := json.build(transmute([]u8)string(`[{"z":1,"name":"日本語|a\\b\nc","meta":{"k":true,"arr":[1,2]}},{"name":"alice","extra":null,"z":200}]`))
	cdoc, cerr := dsv.build(transmute([]u8)string("b,a\n1,\"x|y\"\n20,z\n"), .Csv, {format = dsv.Dsv_Options{infer = true}})
	obj_doc, oerr := json.build(transmute([]u8)string(`{"b":[1,2],"a":"hello\nworld"}`))
	defer {
		json.destroy(&jdoc)
		dsv.destroy(&cdoc)
		json.destroy(&obj_doc)
	}
	testing.expect(t, jerr == nil && cerr == nil && oerr == nil)

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

	// Verify zero allocations on `context.temp_allocator`.
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
		for cmp in ([?]bool{false, true}) {
			m_out, merr := write.write_markdown(d, {compact = cmp, sort_keys = !cmp})
			delete(m_out)
			testing.expect_value(t, merr, nil)
		}
	}
	batch := [?]tape.Document{jdoc, obj_doc}
	bt, bterr := write.write_table_docs(batch[:], {style = .Box})
	bm, bmerr := write.write_markdown_docs(batch[:])
	delete(bt)
	delete(bm)
	testing.expect(t, bterr == nil && bmerr == nil && f.count == 0)
}

@(private = "file")
Token_Tape_Render_Sweep :: struct {
	markdown, framed: bool,
}

@(private = "file")
token_tape_render_sweep_one :: proc(data: rawptr, a: runtime.Allocator) {
	r := (^Token_Tape_Render_Sweep)(data)
	tt: write.Token_Tape
	if err := write.token_tape_start(&tt, r.framed, 0, a); err != nil {
		return
	}
	defer write.token_tape_drop(&tt)
	for step in ([?]struct { kind: write.Token_Kind, text: string }{{.Object, ""}, {.Key, "k"}, {.Number, "1"}, {.Close, ""}}) {
		if terr := write.token_tape_take(&tt, step.kind, step.text); terr != nil {
			_ = terr.(runtime.Allocator_Error)
			return
		}
	}
	doc, derr := write.token_tape_document(&tt)
	if derr != nil {
		return
	}
	text: []u8
	eerr: write.Error
	if r.markdown {
		text, eerr = write.write_markdown(&doc, {compact = true}, a)
	} else {
		text, eerr = write.write_table(&doc, {style = .Compact}, a)
	}
	if eerr == nil {
		delete(text, a)
	} else {
		_ = eerr.(runtime.Allocator_Error)
	}
}

@(test)
render_audit_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. OOM sweep for framed=true and framed=false Token_Tape -> render pipelines.
	for md in ([?]bool{false, true}) {
		for framed in ([?]bool{false, true}) {
			run := Token_Tape_Render_Sweep{markdown = md, framed = framed}
			s := testkit.sweep_failures(token_tape_render_sweep_one, &run)
			testing.expectf(t, s.bad == 0 && s.refused >= 1, "token_tape render sweep md=%v framed=%v: %v", md, framed, s)
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
	oom := write.Error(runtime.Allocator_Error.Out_Of_Memory)
	for bad_alloc in ([?]runtime.Allocator{mem.nil_allocator(), {}}) {
		_, e1 := write.write_table(&sample_doc, {}, bad_alloc)
		_, e2 := write.write_table_docs(docs[:], {}, bad_alloc)
		_, e3 := write.write_markdown(&sample_doc, {}, bad_alloc)
		_, e4 := write.write_markdown_docs(docs[:], {}, bad_alloc)
		tt: write.Token_Tape
		testing.expect(t, e1 == oom && e2 == oom && e3 == oom && e4 == oom)
		testing.expect_value(t, write.write_table_to(sink, &sample_doc, {}, bad_alloc), oom)
		testing.expect_value(t, write.write_markdown_to(sink, &sample_doc, {}, bad_alloc), oom)
		testing.expect_value(t, write.token_tape_start(&tt, true, 0, bad_alloc), runtime.Allocator_Error.Out_Of_Memory)
	}

	// 3. opts.node pointing directly to a DSV row .Object (no key nodes, keys live in Tabular_Ext.keys).
	csv_doc, cerr := dsv.build(transmute([]u8)string("name,qty\nbolt,12\nnut,3\n"), .Csv, {format = dsv.Dsv_Options{infer = true}})
	defer dsv.destroy(&csv_doc)
	row0, row0_p := dsv.element({&csv_doc, nil}, dsv.ROOT, 0)
	testing.expect(t, cerr == nil && row0_p == .Found)
	expect_tbl(t, &csv_doc, "key   value\nname  bolt\nqty   12\n", {node = row0, style = .Compact})
	expect_md(t, &csv_doc, "| name | qty |\n| --- | ---: |\n| bolt | 12 |\n", {node = row0, object_layout = .Row, compact = true})
	csv_docs := [?]tape.Document{csv_doc}
	batch_dsv_row, bderr := write.write_markdown_docs(csv_docs[:], {node = row0, compact = true})
	defer delete(batch_dsv_row)
	testing.expect(t, bderr == nil && string(batch_dsv_row) == "| name | qty |\n| --- | ---: |\n| bolt | 12 |\n")

	// 4. CBOR .Bytes keys (single base64, NOT double-base64) + YAML !!binary & .Number keys.
	cbor_bkey_doc, cbk_err := cbor.build([]u8{0x81, 0xA1, 0x42, 0x68, 0x69, 0x18, 0x2A})
	cbor_nb_doc, cnb_err := cbor.build([]u8{0x81, 0xA1, 0x61, 0x6D, 0xA1, 0x42, 0x68, 0x69, 0x07})
	yaml_keys_doc, yk_err := yaml.build(transmute([]u8)string("- !!binary aGk=: 1\n  1e0: 2\n  .inf: 3\n  -.inf: 4\n  .nan: 5\n"))
	defer {
		cbor.destroy(&cbor_bkey_doc)
		cbor.destroy(&cbor_nb_doc)
		yaml.destroy(&yaml_keys_doc)
	}
	testing.expect(t, cbk_err == nil && cnb_err == nil && yk_err == nil)
	expect_md(t, &cbor_bkey_doc, "| aGk= |\n| ---: |\n| 42 |\n", {compact = true})
	expect_md(t, &cbor_nb_doc, "| m |\n| --- |\n| {\"aGk=\":7} |\n", {compact = true})
	yk_md, yk_werr := write.write_markdown(&yaml_keys_doc, {compact = true})
	defer delete(yk_md)
	testing.expect(t, yk_werr == nil && strings.contains(string(yk_md), "| aGk= |") && strings.contains(string(yk_md), "| 1 | 2 | 3 | 4 | 5 |\n"))

	// 5. Synthetic tape.Document with container keys ([1, 2]) + duplicate container key (.Last policy) + OOM sweep.
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
	ck_doc := tape.Document{src = transmute([]u8)string("12firstlast"), nodes = ck_nodes[:], format = json.as(.Json)}
	expect_md(t, &ck_doc, "| [1,2] |\n| --- |\n| last |\n", {compact = true})
	ck_run := Render_Sweep_Run{doc = &ck_doc, markdown = true}
	ck_sweep := testkit.sweep_failures(render_sweep_one, &ck_run)
	testing.expectf(t, ck_sweep.bad == 0 && ck_sweep.refused >= 1, "container key oom sweep: %v", ck_sweep)

	// 6. opts.node = tape.NO_NODE returns Bad_Option{"node"} (safe on 32-bit wasm32 without signed wrap to -1).
	bad_node_err := write.Error(tape.Bad_Option{"node"})
	_, no_node_tbl := write.write_table(&sample_doc, {node = tape.NO_NODE})
	_, no_node_md := write.write_markdown(&sample_doc, {node = tape.NO_NODE})
	_, no_node_docs := write.write_table_docs(docs[:], {node = tape.NO_NODE})
	testing.expect(t, no_node_tbl == bad_node_err && no_node_md == bad_node_err && no_node_docs == bad_node_err)

	// Bonus: .Plain underline alignment on empty col 0, .Ascii max_col_width 1/2, XML repeated tags, ragged DSV .Last, orphan combining mark.
	expect_json_tbl(t, `[{"":"","b":1}]`, "   b\n-  -\n   1\n", {style = .Plain})
	wide_doc, _ := json.build(transmute([]u8)string(`[{"header":"abcdef"}]`))
	defer json.destroy(&wide_doc)
	for tc in ([?]struct { w: int, want: string }{{1, "| . |\n"}, {2, "| .. |\n"}}) {
		a_out, a_err := write.write_table(&wide_doc, {style = .Ascii, max_col_width = tc.w})
		defer delete(a_out)
		testing.expect(t, a_err == nil && strings.contains(string(a_out), tc.want))
	}

	xml_rep_doc, xr_err := xml.build(transmute([]u8)string("<list><x>1</x><x>2</x><y>3</y><x>4</x></list>"))
	defer xml.destroy(&xml_rep_doc)
	list_el, list_p := xml.member({&xml_rep_doc, nil}, xml.ROOT, "list")
	testing.expect(t, xr_err == nil && list_p == .Found)
	expect_md(t, &xml_rep_doc, "| key | value |\n| --- | --- |\n| x | 1 |\n| x | 2 |\n| y | 3 |\n| x | 4 |\n", {node = list_el, compact = true})

	rag_doc, rag_err := dsv.build(transmute([]u8)string("a,b,a\n1,2\n"), .Csv, {dups = .Last, tolerate = {.Ragged}})
	defer dsv.destroy(&rag_doc)
	testing.expect_value(t, rag_err, nil)
	expect_md(t, &rag_doc, "| b | a |\n| --- | --- |\n| 2 | 1 |\n", {compact = true})

	zw_doc, zw_err := json.build(transmute([]u8)string("[{\"a\":\"\u0301日本語\",\"b\":\"x\u0301日本語\"}]"))
	defer json.destroy(&zw_doc)
	testing.expect_value(t, zw_err, nil)
	zw_tbl, zw_werr := write.write_table(&zw_doc, {style = .Box, max_col_width = 2})
	defer delete(zw_tbl)
	testing.expect(t, zw_werr == nil && !strings.contains(string(zw_tbl), " \u0301…") && strings.contains(string(zw_tbl), "x\u0301…"))
}
