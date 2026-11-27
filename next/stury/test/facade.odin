package stury_tests

import "base:runtime"
import "core:bytes"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:engine"
import "stury:html"
import "stury:json"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:stury"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

@(test)
lookup_and_detect_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	for tc in ([?]struct { name: string, id: engine.Format_Id }{
		{"json", .Json}, {"TOML", .Toml_1_0}, {"xml", .Xml}, {"csv", .Csv}, {"cbor", .Cbor},
		{"yaml", .Yaml}, {"yaml:merge", .Yaml_Merge}, {"html", .Html}, {"html:fragment", .Html_Fragment},
		{"msgpack", .Msgpack}, {"msgpack:compact", .Msgpack_Compact},
	}) {
		e, ok := stury.format_by_name(tc.name)
		testing.expectf(t, ok && e.id == tc.id, "format_by_name(%q)", tc.name)
	}
	_, bad_name := stury.format_by_name("nonexistent")
	testing.expect(t, !bad_name)

	for tc in ([?]struct { path: string, id: engine.Format_Id, fr: engine.Framing, check_fr: bool }{
		{"/tmp/data.json.gz", .Json, .Single, true}, {"logs.ndjson.zst", .Json, .Lines, true},
		{"config.toml", .Toml_1_0, .Single, false}, {"feed.xml", .Xml, .Single, false},
		{"table.csv", .Csv, .Single, false}, {"blob.cbor", .Cbor, .Single, false},
		{"service.yaml", .Yaml, .Single, false}, {"page.htm", .Html, .Single, false},
		{"blob.mpk", .Msgpack, .Single, false},
	}) {
		ep, fr, pok := stury.format_of_path(tc.path)
		testing.expectf(t, pok && ep.id == tc.id && (!tc.check_fr || fr == tc.fr), "format_of_path(%q)", tc.path)
	}
	_, _, bad_path := stury.format_of_path("README")
	testing.expect(t, !bad_path)

	cbor_bytes := [?]u8{0xA1, 0x61, 'a', 0x01}
	for tc in ([?]struct { src: []u8, id: engine.Format_Id }{
		{transmute([]u8)string(`{"a":1}`), .Json},
		{transmute([]u8)string("[user]\nname = \"ada\"\n"), .Toml_1_0},
		{transmute([]u8)string(`<root><a>1</a></root>`), .Xml},
		{transmute([]u8)string("id,name\n1,ada\n"), .Csv},
		{cbor_bytes[:], .Cbor},
	}) {
		ed, _, dok := stury.detect_format(tc.src)
		testing.expectf(t, dok && ed.id == tc.id, "detect_format %v", tc.id)
	}
}

@(test)
universal_validate_build_find_scan_write_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","id":7}}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nid = 7\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name></user></root>`)
	csv_src := transmute([]u8)string("name,id\nada,7\n")
	cbor_src := [?]u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x62, 'i', 'd', 0x07}

	specs := [?]stury.Spec{json.Spec.Json, toml.Spec.Toml_1_0, xml.Spec.Xml, dsv.Spec.Csv, cbor.Spec.Cbor}
	inputs := [?][]u8{json_src, toml_src, xml_src, csv_src, cbor_src[:]}

	// One concrete `stury.Document` mixes freely across all 5 formats in a single array.
	docs: [5]stury.Document
	defer for &d in docs {
		stury.destroy(&d)
	}
	for s, i in specs {
		testing.expect_value(t, stury.validate(inputs[i], s), stury.Error(nil))
		d, err := stury.build(inputs[i], s)
		testing.expect_value(t, err, stury.Error(nil))
		testing.expect(t, len(d.nodes) > 0)
		docs[i] = d

		// Every document writes cleanly to JSON via both `write` and `write_to`.
		out, _, werr := stury.write(&docs[i], json.Spec.Json)
		testing.expect_value(t, werr, stury.Write_Error(nil))
		testing.expect(t, len(out) > 0)
		delete(out)

		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 64)
		_, wterr := stury.write(bytes.buffer_to_stream(&buf), &docs[i], json.Spec.Json)
		testing.expect_value(t, wterr, stury.Write_Error(nil))
		testing.expect(t, bytes.buffer_length(&buf) > 0)
		bytes.buffer_destroy(&buf)
	}

	// `format` streaming conversion.
	fbuf: bytes.Buffer
	bytes.buffer_init_allocator(&fbuf, 0, 64)
	defer bytes.buffer_destroy(&fbuf)
	_, ferr := stury.format(bytes.buffer_to_stream(&fbuf), toml_src, toml.Spec.Toml_1_0, json.Spec.Json)
	testing.expect_value(t, ferr, stury.Format_Error(nil))
	testing.expect_value(t, bytes.buffer_to_string(&fbuf), `{"user":{"name":"ada","id":7}}`)

	// `find` and `scan` via universal facade.
	path := [?]tape.Step{tape.Name("user"), tape.Name("name")}
	ans, find_err := stury.find(cbor_src[:], path[:], cbor.Spec.Cbor)
	testing.expect_value(t, find_err, stury.Error(nil))
	testing.expect_value(t, ans.outcome, tape.Presence.Found)
	testing.expect_value(t, ans.kind, tape.Kind.String)

	paths := [?][]tape.Step{path[:]}
	dem, derr := tape.demand_of(paths[:])
	testing.expect_value(t, derr, nil)
	defer stury.destroy(&dem)

	sdoc, serr := stury.scan(json_src, &dem, json.Spec.Json)
	testing.expect_value(t, serr, stury.Error(nil))
	defer stury.destroy(&sdoc)
	node, pres, has := tape.answer(tape.Reader{doc = &sdoc}, 0, 0)
	testing.expect(t, has && pres == .Found)
	testing.expect_value(t, string(tape.span_bytes(&sdoc, sdoc.nodes[node].lo, sdoc.nodes[node].n)), "ada")
}

@(private = "file")
expect_comments :: proc(t: ^testing.T, doc: ^stury.Document, want: []string, loc := #caller_location) {
	cs, err := stury.comments(doc)
	testing.expect_value(t, err, nil, loc = loc)
	defer delete(cs)
	testing.expect_value(t, len(cs), len(want), loc = loc)
	for w, i in want {
		if i < len(cs) {
			testing.expect_value(t, cs[i].text, w, loc = loc)
		}
	}
}

@(test)
doc_facts_comments_attributes_and_css :: proc(t: ^testing.T) {
	testkit.deadline(t)

	jcdoc, jcerr := stury.build(transmute([]u8)string("// head comment\n{\"a\": 1 /* inline */}\n"), json.Spec.Jsonc)
	tdoc, terr := stury.build(transmute([]u8)string("# toml header\na = 1 # tail\n"), toml.Spec.Toml_1_0)
	xdoc, xerr := stury.build(transmute([]u8)string(`<lib><!-- shelf --><book id="b1" class="story featured" title="A &amp; B"><title>Ada</title></book><note/></lib>`), xml.Spec.Xml)
	jdoc, jerr := stury.build(transmute([]u8)string(`{"a":1}`), json.Spec.Json)
	defer stury.destroy(&jcdoc)
	defer stury.destroy(&tdoc)
	defer stury.destroy(&xdoc)
	defer stury.destroy(&jdoc)
	testing.expect(t, jcerr == nil && terr == nil && xerr == nil && jerr == nil)

	// Facts belong to the document.
	testing.expect(t, stury.doc_facts(&jcdoc) & tape.COMMENTS != {})
	testing.expect(t, stury.doc_facts(&tdoc) & tape.COMMENTS != {})
	testing.expect(t, .Attribute in stury.doc_facts(&xdoc) && stury.doc_facts(&xdoc) & tape.COMMENTS != {})
	testing.expect_value(t, stury.doc_facts(&jdoc), tape.Facts{})
	testing.expect_value(t, stury.doc_facts(nil), tape.Facts{})

	// `comments` works uniformly across all formats.
	expect_comments(t, &jcdoc, {"head comment", "inline"})
	expect_comments(t, &tdoc, {"toml header", "tail"})
	expect_comments(t, &xdoc, {"shelf"})
	expect_comments(t, &jdoc, {})

	// `css` selects on XML and cleanly returns ok=false on JSON/TOML or invalid selectors.
	hits, ok := stury.css(&xdoc, "book.story")
	testing.expect(t, ok && len(hits.matches) == 1)
	defer stury.destroy(&hits)

	attrs, aerr := stury.attributes(&xdoc, hits.matches[0].value)
	testing.expect_value(t, aerr, nil)
	defer stury.destroy(attrs)
	testing.expect_value(t, len(attrs), 3)
	testing.expect(t, attrs[0].name == "id" && attrs[0].value == "b1" && attrs[2].name == "title" && attrs[2].value == "A & B")

	// Non-markup documents cleanly return empty attributes and `css` ok=false.
	no_attrs, naerr := stury.attributes(&jdoc, tape.ROOT)
	testing.expect(t, naerr == nil && len(no_attrs) == 0)
	_, j_css_ok := stury.css(&jdoc, "book")
	_, t_css_ok := stury.css(&tdoc, "book")
	_, bad_css_ok := stury.css(&xdoc, "book[invalid=")
	testing.expect(t, !j_css_ok && !t_css_ok && !bad_css_ok)

	// Writing reports dropped facts accurately.
	out_json, dropped, werr := stury.write(&jcdoc, json.Spec.Json)
	testing.expect_value(t, werr, stury.Write_Error(nil))
	defer delete(out_json)
	testing.expect(t, dropped & tape.COMMENTS != {})

	// YAML comments + Failsafe dialect, and HTML5 CSS selection + attributes.
	yaml_src := transmute([]u8)string("# note\nuser:\n  name: ada\n  age: 36\n")
	ydoc, yerr := stury.build(yaml_src, yaml.Spec.Yaml_1_2)
	testing.expect_value(t, yerr, stury.Error(nil))
	defer stury.destroy(&ydoc)
	expect_comments(t, &ydoc, {"note"})

	fs_doc, fs_err := stury.build(yaml_src, yaml.Spec.Yaml_1_2, {format = tape.Yaml_Options{dialect = .Failsafe}})
	testing.expect_value(t, fs_err, stury.Error(nil))
	defer stury.destroy(&fs_doc)
	fs_json, _, fsw_err := stury.write(&fs_doc, json.Spec.Json)
	testing.expect_value(t, fsw_err, stury.Write_Error(nil))
	defer delete(fs_json)
	testing.expect(t, strings.contains(string(fs_json), `"36"`))

	hdoc, herr := stury.build(transmute([]u8)string(`<!DOCTYPE html><html><body><div class="card" data-id="7"><p>ada</p></div></body></html>`), html.Spec.Html)
	testing.expect_value(t, herr, stury.Error(nil))
	defer stury.destroy(&hdoc)
	hhits, hok := stury.css(&hdoc, "div.card")
	testing.expect(t, hok && len(hhits.matches) == 1)
	defer stury.destroy(&hhits)
	hattrs, haerr := stury.attributes(&hdoc, hhits.matches[0].value)
	testing.expect_value(t, haerr, nil)
	defer stury.destroy(hattrs)
	testing.expect_value(t, len(hattrs), 2)
}

@(test)
universal_diff_schema_and_edit :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Cross-format `diff` (JSON vs TOML).
	j_src := transmute([]u8)string(`{"a":1,"b":"old"}`)
	t_src := transmute([]u8)string("a = 1\nb = \"new\"\n")
	dres, derr := stury.diff(j_src, json.Spec.Json, t_src, toml.Spec.Toml_1_0)
	testing.expect_value(t, derr, stury.Diff_Error(nil))
	defer stury.destroy_diff(&dres)
	testing.expect(t, len(dres.changes) == 1 && dres.changes[0].op == .Changed)

	// `diff` between identical JSON and CBOR documents yields zero changes.
	cbor_src := [?]u8{0xA2, 0x61, 'a', 0x01, 0x61, 'b', 0x63, 'o', 'l', 'd'}
	jdoc, jerr := stury.build(j_src, json.Spec.Json)
	cdoc, cerr := stury.build(cbor_src[:], cbor.Spec.Cbor)
	defer stury.destroy(&jdoc)
	defer stury.destroy(&cdoc)
	testing.expect(t, jerr == nil && cerr == nil)

	eq_res, eq_err := stury.diff(&jdoc, &cdoc)
	testing.expect_value(t, eq_err, nil)
	defer stury.destroy_diff(&eq_res)
	testing.expect_value(t, len(eq_res.changes), 0)

	// `schema_compile` + `check_schema` across JSON, TOML, CBOR.
	sc, scerr := stury.schema_compile(transmute([]u8)string(`{"type":"object","required":["a","b"],"properties":{"a":{"type":"integer","minimum":1},"b":{"type":"string"}}}`))
	testing.expect_value(t, scerr.kind, .None)
	defer stury.schema_destroy(sc)

	r1 := stury.check_schema(j_src, json.Spec.Json, sc)
	r2 := stury.check_schema(t_src, toml.Spec.Toml_1_0, sc)
	r3 := stury.check_schema(cbor_src[:], cbor.Spec.Cbor, &sc.plan)
	rdoc := stury.check_document(&jdoc, sc)
	r4 := stury.check_schema(transmute([]u8)string(`{"a":0,"b":"ok"}`), json.Spec.Json, sc)
	defer {
		stury.destroy_check_result(&r1)
		stury.destroy_check_result(&r2)
		stury.destroy_check_result(&r3)
		stury.destroy_check_result(&rdoc)
		stury.destroy_check_result(&r4)
	}
	testing.expect(t, r1.valid && r2.valid && r3.valid && rdoc.valid && !r4.valid)

	// `edit_init` / `set_path` / `commit` preserving JSONC comments via `stury` facade alone.
	jc_doc, jce := stury.build(transmute([]u8)string("{\n  // keep me\n  \"a\": 1,\n  \"b\": \"old\"\n}\n"), json.Spec.Jsonc)
	testing.expect_value(t, jce, stury.Error(nil))
	defer stury.destroy(&jc_doc)

	ov: stury.Overlay
	testing.expect_value(t, stury.edit_init(&ov, &jc_doc), stury.Edit_Error(nil))
	defer stury.edit_destroy(&ov)
	step_a := [?]tape.Step{tape.Name("a")}
	_, sp_err := stury.set_path(&ov, step_a[:], stury.val_int(42))
	testing.expect_value(t, sp_err, stury.Edit_Error(nil))
	cres, cm_err := stury.commit(&ov)
	testing.expect_value(t, cm_err, stury.Edit_Error(nil))
	defer stury.destroy_commit_result(&cres)
	testing.expect(t, strings.contains(string(cres.bytes), "// keep me") && strings.contains(string(cres.bytes), "42"))

	// `commit_document` incremental tape splicing on XML.
	x_doc, x_berr := stury.build(transmute([]u8)string(`<r><a>1</a><b>2</b></r>`), xml.Spec.Xml)
	testing.expect_value(t, x_berr, stury.Error(nil))
	defer stury.destroy(&x_doc)
	x_ov: stury.Overlay
	testing.expect_value(t, stury.edit_init(&x_ov, &x_doc), stury.Edit_Error(nil))
	defer stury.edit_destroy(&x_ov)
	step_b := [?]tape.Step{tape.Name("r"), tape.Name("b")}
	_, xsp_err := stury.set_path(&x_ov, step_b[:], stury.val_string("9"))
	testing.expect_value(t, xsp_err, stury.Edit_Error(nil))
	spliced_doc, sres, sc_err := stury.commit_document(&x_ov, xml.Spec.Xml)
	testing.expect_value(t, sc_err, stury.Edit_Error(nil))
	defer stury.destroy(&spliced_doc)
	defer stury.destroy_commit_result(&sres)
	testing.expect(t, string(sres.bytes) == `<r><a>1</a><b>9</b></r>` && len(spliced_doc.nodes) > 0)

	// SQL DDL schema compile + streaming check across JSON and YAML.
	ddl_sc, ddl_err := stury.schema_compile_ddl(transmute([]u8)string("CREATE TABLE users (\n  name VARCHAR(50) NOT NULL,\n  age INT NOT NULL CHECK (age >= 0)\n);\n"))
	testing.expect_value(t, ddl_err.kind, .None)
	defer stury.destroy(ddl_sc)
	r_json := stury.check_schema(transmute([]u8)string(`{"name":"ada","age":36}`), json.Spec.Json, ddl_sc)
	r_yaml := stury.check_schema(transmute([]u8)string("name: ada\nage: 36\n"), yaml.Spec.Yaml_1_2, ddl_sc)
	r_bad := stury.check_schema(transmute([]u8)string("name: ada\nage: -1\n"), yaml.Spec.Yaml_1_2, ddl_sc)
	defer {
		stury.destroy_check_result(&r_json)
		stury.destroy_check_result(&r_yaml)
		stury.destroy_check_result(&r_bad)
	}
	testing.expect(t, r_json.valid && r_yaml.valid && !r_bad.valid)

	// Table and Markdown writers through `stury`.
	rows_doc, rb_err := stury.build(transmute([]u8)string(`[{"name":"ada","age":36},{"name":"bob","age":42}]`), json.Spec.Json)
	testing.expect_value(t, rb_err, stury.Error(nil))
	defer stury.destroy(&rows_doc)

	tbl, terr := stury.write_table(&rows_doc)
	md, mderr := stury.write_markdown(&rows_doc)
	defer delete(tbl)
	defer delete(md)
	testing.expect(t, terr == nil && strings.contains(string(tbl), "ada") && strings.contains(string(tbl), "42"))
	testing.expect(t, mderr == nil && strings.contains(string(md), "| name") && strings.contains(string(md), "---:"))
}

@(private = "file")
Query_Collector :: struct {
	values: [dynamic]string,
	paths:  [dynamic]string,
	limit:  int,
}

@(private = "file")
collect_jq_out :: proc(ctx: rawptr, b: []u8) -> bool {
	c := (^Query_Collector)(ctx)
	append(&c.values, strings.clone(string(b)))
	return c.limit <= 0 || len(c.values) < c.limit
}

@(private = "file")
collect_jp_out :: proc(ctx: rawptr, b: []u8, norm_path: string) -> bool {
	c := (^Query_Collector)(ctx)
	append(&c.values, strings.clone(string(b)))
	if len(norm_path) > 0 {
		append(&c.paths, strings.clone(norm_path))
	}
	return c.limit <= 0 || len(c.values) < c.limit
}

@(private = "file")
destroy_collector :: proc(c: ^Query_Collector) {
	for v in c.values {
		delete(v)
	}
	delete(c.values)
	for p in c.paths {
		delete(p)
	}
	delete(c.paths)
}

@(private = "file")
expect_jq :: proc(t: ^testing.T, expr: string, src: []u8, spec: stury.Spec, want: []string, opts := stury.Jq_Run_Options{}, want_err := stury.Query_Error.None, loc := #caller_location) {
	prog, errs := stury.jq_compile(expr)
	testing.expect_value(t, len(errs), 0, loc = loc)
	defer stury.jq_destroy(prog)
	col: Query_Collector
	defer destroy_collector(&col)
	res := stury.jq_run(prog, src, spec, collect_jq_out, &col, opts)
	defer stury.jq_run_result_destroy(&res)
	testing.expect_value(t, res.err, want_err, loc = loc)
	if want_err == .None {
		testing.expect_value(t, len(col.values), len(want), loc = loc)
		for w, i in want {
			if i < len(col.values) {
				testing.expect_value(t, col.values[i], w, loc = loc)
			}
		}
	}
}

@(private = "file")
expect_jp :: proc(t: ^testing.T, expr: string, src: []u8, spec: stury.Spec, want: []string, want_paths: []string = nil, opts := stury.Jsonpath_Eval_Options{}, limit := 0, want_err := stury.Query_Error.None, want_emitted := u64(0), check_emitted := false, loc := #caller_location) {
	prog, cerr := stury.jsonpath_compile(expr)
	testing.expect_value(t, cerr.kind, .None, loc = loc)
	defer stury.jsonpath_destroy(prog)
	col := Query_Collector{limit = limit}
	defer destroy_collector(&col)
	res := stury.jsonpath_eval(prog, src, spec, collect_jp_out, &col, opts)
	testing.expect_value(t, res.err, want_err, loc = loc)
	if check_emitted {
		testing.expect_value(t, res.emitted, want_emitted, loc = loc)
	}
	if want != nil {
		testing.expect_value(t, len(col.values), len(want), loc = loc)
		for w, i in want {
			if i < len(col.values) {
				testing.expect_value(t, col.values[i], w, loc = loc)
			}
		}
	}
	if want_paths != nil {
		testing.expect_value(t, len(col.paths), len(want_paths), loc = loc)
		for wp, i in want_paths {
			if i < len(col.paths) {
				testing.expect_value(t, col.paths[i], wp, loc = loc)
			}
		}
	}
}

@(test)
query_jq_and_jsonpath_across_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","score":99}}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nscore = 99\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name></user></root>`)
	csv_src := transmute([]u8)string("name,score\nada,99\n")
	cbor_src := [?]u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x65, 's', 'c', 'o', 'r', 'e', 0x18, 99}
	yaml_src := transmute([]u8)string("user:\n  name: ada\n  score: 99\n")
	html_src := transmute([]u8)string(`<!DOCTYPE html><html><body><div class="card"><p>ada</p></div></body></html>`)
	mp_bytes, _, mp_ferr := stury.format(yaml_src, yaml.Spec.Yaml_1_2, msgpack.Spec.Compact)
	testing.expect_value(t, mp_ferr, stury.Format_Error(nil))
	defer delete(mp_bytes)

	// jq across JSON, TOML, CBOR, YAML, MessagePack, XML, CSV.
	for pair in ([?]struct { src: []u8, spec: stury.Spec }{
		{json_src, json.Spec.Json}, {toml_src, toml.Spec.Toml_1_0}, {cbor_src[:], cbor.Spec.Cbor},
		{yaml_src, yaml.Spec.Yaml_1_2}, {mp_bytes, msgpack.Spec.Compact},
	}) {
		expect_jq(t, ".user.name", pair.src, pair.spec, {`"ada"`})
	}
	expect_jq(t, `css("name")`, xml_src, xml.Spec.Xml, {`"ada"`})
	expect_jq(t, ".[0].name", csv_src, dsv.Spec.Csv, {`"ada"`})

	// JSONPath across JSON, TOML, CBOR with normalized paths, plus XML, CSV, HTML, and RFC 9535 absent field.
	for pair in ([?]struct { src: []u8, spec: stury.Spec }{
		{json_src, json.Spec.Json}, {toml_src, toml.Spec.Toml_1_0}, {cbor_src[:], cbor.Spec.Cbor},
	}) {
		expect_jp(t, "$.user.name", pair.src, pair.spec, {`"ada"`}, {`$['user']['name']`}, {want_paths = true})
	}
	expect_jp(t, "$.root.user.name", xml_src, xml.Spec.Xml, {`"ada"`})
	expect_jp(t, "$[0].name", csv_src, dsv.Spec.Csv, {`"ada"`})
	expect_jp(t, "$.html.body.div.p", html_src, html.Spec.Html, {`"ada"`})
	expect_jp(t, "$.user.missing", json_src, json.Spec.Json, {})
}

@(private = "file")
Exact_Size_Checker :: struct {
	backing:  runtime.Allocator,
	sizes:    map[rawptr]int,
	mismatch: int,
}

@(private = "file")
exact_size_alloc_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, runtime.Allocator_Error) {
	c := (^Exact_Size_Checker)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if (mode == .Resize || mode == .Resize_Non_Zeroed) && old_memory != nil {
			delete_key(&c.sizes, old_memory)
		}
		data, err := c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
		if err == nil && raw_data(data) != nil {
			c.sizes[raw_data(data)] = size
		}
		return data, err
	case .Free:
		if old_memory != nil {
			if rec, ok := c.sizes[old_memory]; ok {
				if old_size != 0 && old_size != rec {
					c.mismatch += 1
				}
				delete_key(&c.sizes, old_memory)
			}
		}
		return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
	case .Free_All, .Query_Features, .Query_Info:
		return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
	}
	return nil, .Mode_Not_Implemented
}

@(test)
audit_regressions_facade :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Finding #4: `attributes` / `destroy_attributes` passes exact allocated size on delete when entities shrink text.
	xdoc, xerr := stury.build(transmute([]u8)string(`<root><item title="A &amp; B &lt; C"/></root>`), xml.Spec.Xml)
	testing.expect_value(t, xerr, stury.Error(nil))
	defer stury.destroy(&xdoc)
	hits, css_ok := stury.css(&xdoc, "item")
	testing.expect(t, css_ok && len(hits.matches) == 1)
	defer stury.destroy(&hits)

	checker := Exact_Size_Checker{backing = context.allocator, sizes = make(map[rawptr]int)}
	defer delete(checker.sizes)
	checked_alloc := runtime.Allocator{procedure = exact_size_alloc_proc, data = &checker}
	attrs, aerr := stury.attributes(&xdoc, hits.matches[0].value, checked_alloc)
	testing.expect(t, aerr == nil && len(attrs) == 1 && attrs[0].value == "A & B < C")
	stury.destroy(attrs, checked_alloc)
	testing.expect(t, checker.mismatch == 0 && len(checker.sizes) == 0)

	// Finding #2: `jsonpath_eval` routes through `engine`'s `Guard_Emit` (accurate `res.emitted` & early stop).
	items_json := transmute([]u8)string(`{"items":[10,20,30]}`)
	expect_jp(t, "$.items[*]", items_json, json.Spec.Json, {"10", "20", "30"}, {"$['items'][0]", "$['items'][1]", "$['items'][2]"}, {want_paths = true}, 0, .None, 3, true)
	// `engine.Guard_Emit` counts emissions where the callback returned `true` (1st returns true, 2nd stops).
	expect_jp(t, "$.items[*]", items_json, json.Spec.Json, {"10", "20"}, nil, {want_paths = true}, 2, .Stopped, 1, true)
	// Framed NDJSON early stop stops without replaying earlier records.
	ndjson := transmute([]u8)string("{\"items\":[1,2]}\n{\"items\":[3,4]}\n")
	expect_jp(t, "$.items[*]", ndjson, json.Spec.Json, {"1", "2"}, nil, {framing = .Lines}, 2, .Stopped, 1, true)

	// Finding #3 & #5: `jq_run` honors `read.budget.memory` on `.Projection_Direct` and maps evaluator budget to `.Exceeded`.
	expect_jq(t, ".a", transmute([]u8)string(`{"a":1}`), json.Spec.Json, nil, {read = {budget = {memory = 16}}}, .Exceeded)
	expect_jq(t, "[range(500)]", transmute([]u8)string(`null`), json.Spec.Json, nil, {budget = {memory = 512}}, .Exceeded)
	expect_jp(t, "$.items[*]", items_json, json.Spec.Json, nil, nil, {budget = {memory = 16}}, 0, .Exceeded)
	// Finding #7: large `u32` depth budget clamps safely without sign overflow.
	expect_jp(t, "$.items[*]", items_json, json.Spec.Json, nil, nil, {budget = {depth = max(u32)}}, 0, .None, 3, true)
}

@(test)
universal_marshal_and_unmarshal_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	User :: struct {
		name:   string `stury:"name"`,
		age:    int    `stury:"age"`,
		active: bool   `stury:"active"`,
	}
	want := User{name = "ada", age = 36, active = true}

	// Round-trip `marshal` (buffer + `io.Writer` sink) and `unmarshal` across JSON, CBOR, TOML, YAML, and MessagePack.
	for spec in ([?]stury.Spec{
		json.Spec.Json,
		cbor.Spec.Cbor,
		toml.Spec.Toml_1_0,
		yaml.Spec.Yaml_1_2,
		msgpack.Spec.Compact,
	}) {
		encoded, merr := stury.marshal(&want, spec)
		testing.expectf(t, merr == nil, "marshal %v err: %v", spec, merr)
		defer delete(encoded)
		testing.expect(t, len(encoded) > 0)

		got: User
		uerr := stury.unmarshal(encoded, &got, spec)
		testing.expectf(t, uerr == nil, "unmarshal %v err: %v", spec, uerr)
		defer delete(got.name)
		testing.expect_value(t, got, want)

		// Streaming `marshal` into `io.Writer` produces identical bytes.
		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 64)
		defer bytes.buffer_destroy(&buf)
		serr := stury.marshal(bytes.buffer_to_stream(&buf), &want, spec)
		testing.expectf(t, serr == nil, "marshal_to %v err: %v", spec, serr)
		testing.expect_value(t, string(bytes.buffer_to_bytes(&buf)), string(encoded))
	}

	// DSV (CSV & TSV) typed round-trip over slice of structs.
	rows_in := [?]User{
		{name = "ada", age = 36, active = true},
		{name = "bob", age = 42, active = false},
	}
	rows_slice := rows_in[:]
	for dspec in ([?]stury.Spec{dsv.Spec.Csv, dsv.Spec.Tsv}) {
		encoded, merr := stury.marshal(&rows_slice, dspec)
		testing.expectf(t, merr == nil, "marshal %v err: %v", dspec, merr)
		defer delete(encoded)

		rows_out: []User
		uerr := stury.unmarshal(encoded, &rows_out, dspec)
		testing.expectf(t, uerr == nil, "unmarshal %v err: %v", dspec, uerr)
		defer {
			for r in rows_out {
				delete(r.name)
			}
			delete(rows_out)
		}
		testing.expect_value(t, len(rows_out), len(rows_in))
		for r, i in rows_out {
			testing.expect_value(t, r, rows_in[i])
		}
	}

	// XML typed round-trip (marshal + unmarshal) on single-root struct; nil specs return `Bad_Option`.
	Xml_Doc :: struct {
		user: User `xml:"user"`,
	}
	xdoc_val := Xml_Doc{user = want}
	xbytes, xmerr := stury.marshal(&xdoc_val, xml.Spec.Xml)
	testing.expect_value(t, xmerr, stury.Write_Error(nil))
	defer delete(xbytes)
	testing.expect(t, strings.contains(string(xbytes), "<user>") && strings.contains(string(xbytes), "<name>ada</name>"))

	xdoc_out: Xml_Doc
	xml_uerr := stury.unmarshal(xbytes, &xdoc_out, xml.Spec.Xml)
	testing.expect_value(t, xml_uerr, stury.Error(nil))
	defer delete(xdoc_out.user.name)
	testing.expect_value(t, xdoc_out, xdoc_val)

	// Streaming XML marshal into `io.Writer` produces identical bytes.
	xbuf: bytes.Buffer
	bytes.buffer_init_allocator(&xbuf, 0, 64)
	defer bytes.buffer_destroy(&xbuf)
	testing.expect_value(t, stury.marshal(bytes.buffer_to_stream(&xbuf), &xdoc_val, xml.Spec.Xml), stury.Write_Error(nil))
	testing.expect_value(t, string(bytes.buffer_to_bytes(&xbuf)), string(xbytes))

	dummy: User
	nil_uerr := stury.unmarshal(xbytes, &dummy, nil)
	testing.expect_value(t, nil_uerr, stury.Error(tape.Bad_Option{"spec"}))
	_, nil_merr := stury.marshal(&want, nil)
	testing.expect_value(t, nil_merr, stury.Write_Error(tape.Bad_Option{"to"}))
}
