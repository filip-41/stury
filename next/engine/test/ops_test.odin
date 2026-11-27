package engine_tests

import "core:bytes"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:engine"
import "stury:html"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:lib/ops/write"
import "stury:lib/query"
import "stury:lib/schema/check"
import "stury:lib/schema/schema"
import "stury:msgpack"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

@(test)
ops_validate_build_find_scan_records_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","id":7},"extra":[1,2,3]}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nid = 7\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name></user></root>`)
	csv_src := transmute([]u8)string("name,id\nada,7\n")
	cbor_src := []u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x62, 'i', 'd', 0x07}
	yaml_src := transmute([]u8)string("user:\n  name: ada\n  id: 7\n")
	html_src := transmute([]u8)string(`<!DOCTYPE html><html><body><p id="p1">ada</p></body></html>`)
	mp_src := []u8{0x81, 0xA4, 'u', 's', 'e', 'r', 0x82, 0xA4, 'n', 'a', 'm', 'e', 0xA3, 'a', 'd', 'a', 0xA2, 'i', 'd', 0x07}

	Format_Case :: struct {
		name: string,
		spec: engine.Spec,
		src:  []u8,
		path: []tape.Step,
	}
	user_name := [?]tape.Step{tape.Name("user"), tape.Name("name")}
	xml_path := [?]tape.Step{tape.Name("root"), tape.Name("user"), tape.Name("name")}
	csv_path := [?]tape.Step{tape.Index(0), tape.Name("name")}
	html_path := [?]tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("p")}

	cases := [?]Format_Case {
		{"json", json.Spec.Json, json_src, user_name[:]},
		{"toml", toml.Spec.Toml_1_0, toml_src, user_name[:]},
		{"xml", xml.Spec.Xml, xml_src, xml_path[:]},
		{"csv", dsv.Spec.Csv, csv_src, csv_path[:]},
		{"cbor", cbor.Spec.Cbor, cbor_src, user_name[:]},
		{"yaml", yaml.Spec.Yaml_1_2, yaml_src, user_name[:]},
		{"html", html.Spec.Html, html_src, html_path[:]},
		{"msgpack", msgpack.Spec.Msgpack, mp_src, user_name[:]},
	}

	for c in cases {
		testing.expectf(t, engine.validate(c.src, c.spec) == nil, "%s validate failed", c.name)
		doc, berr := engine.build(c.src, c.spec)
		testing.expectf(t, berr == nil && len(doc.nodes) > 0, "%s build failed: %v", c.name, berr)
		defer tape.destroy(&doc)

		own_bytes, _, werr := engine.write(&doc, c.spec)
		testing.expectf(t, werr == nil && len(own_bytes) > 0, "%s write failed: %v", c.name, werr)
		delete(own_bytes)

		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 64)
		_, wterr := engine.write_to(bytes.buffer_to_stream(&buf), &doc, json.Spec.Json)
		testing.expectf(t, wterr == nil && bytes.buffer_length(&buf) > 0, "%s write_to json failed: %v", c.name, wterr)
		bytes.buffer_destroy(&buf)

		ans, ferr := engine.find(c.src, c.path, c.spec)
		testing.expectf(t, ferr == nil && ans.outcome == .Found, "%s find failed: %v %v", c.name, ferr, ans.outcome)

		cpaths := [?][]tape.Step{c.path}
		cdem, cderr := tape.demand_of(cpaths[:])
		testing.expect_value(t, cderr, nil)
		defer tape.destroy_demand(&cdem)
		csdoc, cserr := engine.scan(c.src, &cdem, c.spec)
		testing.expectf(t, cserr == nil, "%s scan failed: %v", c.name, cserr)
		tape.destroy(&csdoc)
	}

	// Verify exact find kind and scan answer contents.
	path := user_name
	ans, ferr := engine.find(cbor_src, path[:], cbor.Spec.Cbor)
	testing.expect_value(t, ferr, tape.Error(nil))
	testing.expect_value(t, ans.outcome, tape.Presence.Found)
	testing.expect_value(t, ans.kind, tape.Kind.String)

	paths := [?][]tape.Step{path[:]}
	tdem, tderr := tape.demand_of(paths[:])
	testing.expect_value(t, tderr, nil)
	defer tape.destroy_demand(&tdem)

	sdoc, serr := engine.scan(json_src, &tdem, json.Spec.Json)
	testing.expect_value(t, serr, tape.Error(nil))
	defer tape.destroy(&sdoc)
	r := tape.Reader{doc = &sdoc}
	node, pres, has := tape.answer(r, 0, 0)
	testing.expect(t, has && pres == .Found)
	testing.expect_value(t, string(tape.span_bytes(&sdoc, sdoc.nodes[node].lo, sdoc.nodes[node].n)), "ada")

	// CSV records_open via engine.
	recs, rerr := engine.records_open(csv_src, dsv.Spec.Csv, .Lines)
	testing.expect_value(t, rerr, tape.Error(nil))
	testing.expect(t, recs != nil)
	defer tape.destroy_records(recs)
	rec_arr: [4]tape.Record
	doc_arr: [4]tape.Document
	n := tape.records_scan(recs, &tdem, rec_arr[:], doc_arr[:])
	testing.expect_value(t, n, 1)
	testing.expect_value(t, rec_arr[0].err, tape.Error(nil))

	// Nil spec error reporting across universal ops including `records_open`.
	testing.expect(t, engine.validate(json_src, nil) != nil)
	_, nil_doc_err := engine.build(json_src, nil)
	testing.expect(t, nil_doc_err != nil)
	nil_recs, nil_rec_err := engine.records_open(csv_src, nil)
	testing.expect(t, nil_recs == nil)
	bad_spec_opt, is_bo := nil_rec_err.(tape.Bad_Option)
	testing.expect(t, is_bo && bad_spec_opt.option == "spec")
}

@(test)
ops_write_and_format_dropped_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// TOML with comment -> JSON drops .Comment, whereas -> JSONC retains .Comment!
	toml_src := transmute([]u8)string("# keep comment\na = 1\n")
	j_text, j_drop, j_err := engine.format(toml_src, toml.Spec.Toml_1_0, json.Spec.Json)
	testing.expect_value(t, j_err, nil)
	defer delete(j_text)
	testing.expect(t, .Comment in j_drop)
	testing.expect_value(t, string(j_text), `{"a":1}`)

	jc_text, jc_drop, jc_err := engine.format(toml_src, toml.Spec.Toml_1_0, json.Spec.Jsonc, opts = {indent = 2})
	testing.expect_value(t, jc_err, nil)
	defer delete(jc_text)
	testing.expect(t, .Comment not_in jc_drop)
	testing.expect(t, strings.contains(string(jc_text), "keep comment"))

	// XML attribute -> TOML reports dropped `.Attribute`.
	xml_src := transmute([]u8)string(`<cfg env="prod"><port>8080</port></cfg>`)
	tx, tdrop, terr := engine.format(xml_src, xml.Spec.Xml, toml.Spec.Toml_1_0)
	testing.expect_value(t, terr, nil)
	defer delete(tx)
	testing.expect(t, .Attribute in tdrop)
	testing.expect_value(t, engine.validate(tx, toml.Spec.Toml_1_0), tape.Error(nil))

	// Tagged CBOR (RFC 8949 Tag 0 date-time) -> JSON reports dropped `.Tag`.
	cbor_tagged := []u8{0xC0, 0x74, '2', '0', '2', '6', '-', '0', '1', '-', '0', '1', 'T', '0', '0', ':', '0', '0', ':', '0', '0', 'Z'}
	cj, cj_drop, cj_err := engine.format(cbor_tagged, cbor.Spec.Cbor, json.Spec.Json)
	testing.expect_value(t, cj_err, nil)
	defer delete(cj)
	testing.expect(t, .Tag in cj_drop)
	testing.expect_value(t, string(cj), `"2026-01-01T00:00:00Z"`)

	// Streaming `format_to` into io.Writer matches `format`.
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	stream_drop, stream_err := engine.format_to(strings.to_writer(&sb), toml_src, toml.Spec.Toml_1_0, json.Spec.Json)
	testing.expect_value(t, stream_err, nil)
	testing.expect_value(t, stream_drop, j_drop)
	testing.expect_value(t, strings.to_string(sb), string(j_text))

	// Write document directly to CSV & CBOR.
	rows_json := transmute([]u8)string(`[{"id":1,"name":"ada"},{"id":2,"name":"lin"}]`)
	row_doc, rberr := engine.build(rows_json, json.Spec.Json)
	testing.expect_value(t, rberr, tape.Error(nil))
	defer tape.destroy(&row_doc)

	csv_bytes, _, csv_werr := engine.write(&row_doc, dsv.Spec.Csv)
	testing.expect_value(t, csv_werr, write.Error(nil))
	defer delete(csv_bytes)
	testing.expect_value(t, string(csv_bytes), "id,name\n1,ada\n2,lin\n")

	cbor_bytes, _, cbor_werr := engine.write(&row_doc, cbor.Spec.Cbor)
	testing.expect_value(t, cbor_werr, write.Error(nil))
	defer delete(cbor_bytes)
	testing.expect_value(t, engine.validate(cbor_bytes, cbor.Spec.Cbor), tape.Error(nil))

	// Table and Markdown writers.
	tbl, tbl_err := engine.write_table(&row_doc)
	testing.expect_value(t, tbl_err, write.Error(nil))
	defer delete(tbl)
	testing.expect(t, strings.contains(string(tbl), "name") && strings.contains(string(tbl), "ada"))

	md, mderr := engine.write_markdown(&row_doc)
	testing.expect_value(t, mderr, write.Error(nil))
	defer delete(md)
	testing.expect(t, strings.contains(string(md), "| name") && strings.contains(string(md), "---:"))

	// Cross-format conversions: YAML_MERGE -> JSON, JSON <-> YAML, JSON <-> MessagePack <-> CBOR, HTML <-> JSON.
	yaml_merge_src := transmute([]u8)string("base: &b\n  x: 1\n  y: 2\nchild:\n  <<: *b\n  y: 9\n")
	ym_json, _, ym_err := engine.format(yaml_merge_src, yaml.Spec.Yaml_Merge, json.Spec.Json)
	testing.expect_value(t, ym_err, engine.Format_Error(nil))
	defer delete(ym_json)
	testing.expect(t, strings.contains(string(ym_json), `"x":1`) && strings.contains(string(ym_json), `"y":9`))

	j_src := transmute([]u8)string(`{"a":1,"b":"hi"}`)
	j_yaml, _, jy_err := engine.format(j_src, json.Spec.Json, yaml.Spec.Yaml_1_2, opts = {indent = 2})
	testing.expect_value(t, jy_err, engine.Format_Error(nil))
	defer delete(j_yaml)
	y_back, _, yb_err := engine.format(j_yaml, yaml.Spec.Yaml_1_2, json.Spec.Json)
	testing.expect_value(t, yb_err, engine.Format_Error(nil))
	defer delete(y_back)
	testing.expect_value(t, string(y_back), string(j_src))

	j_mp, _, jmp_err := engine.format(j_src, json.Spec.Json, msgpack.Spec.Compact)
	testing.expect_value(t, jmp_err, engine.Format_Error(nil))
	defer delete(j_mp)
	mp_cbor, _, mc_err := engine.format(j_mp, msgpack.Spec.Compact, cbor.Spec.Deterministic)
	testing.expect_value(t, mc_err, engine.Format_Error(nil))
	defer delete(mp_cbor)
	cbor_mp, _, cm_err := engine.format(mp_cbor, cbor.Spec.Deterministic, msgpack.Spec.Msgpack)
	testing.expect_value(t, cm_err, engine.Format_Error(nil))
	defer delete(cbor_mp)
	mp_json, _, mj_err := engine.format(cbor_mp, msgpack.Spec.Msgpack, json.Spec.Json)
	testing.expect_value(t, mj_err, engine.Format_Error(nil))
	defer delete(mp_json)
	testing.expect_value(t, string(mp_json), string(j_src))

	html_src := transmute([]u8)string(`<!DOCTYPE html><html><body><p>hello</p></body></html>`)
	h_json, _, hj_err := engine.format(html_src, html.Spec.Html, json.Spec.Json)
	testing.expect_value(t, hj_err, engine.Format_Error(nil))
	defer delete(h_json)
	testing.expect(t, strings.contains(string(h_json), `"hello"`))
	j_html, _, jh_err := engine.format(h_json, json.Spec.Json, html.Spec.Html)
	testing.expect_value(t, jh_err, engine.Format_Error(nil))
	defer delete(j_html)
	testing.expect(t, strings.contains(string(j_html), "<p>hello</p>"))
}

@(test)
ops_check_schema_and_document :: proc(t: ^testing.T) {
	testkit.deadline(t)

	obj_schema := `{
		"type": "object",
		"properties": {
			"name": {"type": "string", "minLength": 1},
			"count": {"type": "integer", "minimum": 1}
		},
		"required": ["name", "count"]
	}`
	sc, sc_err := schema.compile_json(transmute([]u8)obj_schema)
	testing.expect_value(t, sc_err.kind, schema.Error_Kind.None)
	defer schema.destroy(sc)

	valid_json := transmute([]u8)string(`{"name":"ada","count":3}`)
	bad_json := transmute([]u8)string(`{"name":"","count":0}`)
	valid_toml := transmute([]u8)string("name = \"ada\"\ncount = 3\n")
	valid_cbor := []u8{0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x65, 'c', 'o', 'u', 'n', 't', 0x03}

	rj := engine.check_schema(valid_json, json.Spec.Json, &sc.plan)
	defer check.result_destroy(&rj)
	testing.expect(t, rj.valid)

	rt := engine.check_schema(valid_toml, toml.Spec.Toml_1_0, &sc.plan)
	defer check.result_destroy(&rt)
	testing.expect(t, rt.valid)

	rc := engine.check_schema(valid_cbor, cbor.Spec.Cbor, &sc.plan)
	defer check.result_destroy(&rc)
	testing.expect(t, rc.valid)

	sink: check.Sink
	check.sink_init(&sink)
	defer check.sink_destroy(&sink)
	rbad := engine.check_schema(bad_json, json.Spec.Json, &sc.plan, {}, &sink)
	defer check.result_destroy(&rbad)
	testing.expect(t, !rbad.valid)
	testing.expect(t, len(sink.entries) > 0)

	// XML & CSV (`dsv_opts = {infer = true}`) schema checks + `check_document`.
	csv_schema := `{"type": "array", "items": {"type": "object", "properties": {"id": {"type": "integer"}}, "required": ["id"]}}`
	csv_sc, csv_sc_err := schema.compile_json(transmute([]u8)csv_schema)
	testing.expect_value(t, csv_sc_err.kind, schema.Error_Kind.None)
	defer schema.destroy(csv_sc)

	rdsv_ok := engine.check_schema(transmute([]u8)string("id\n10\n20\n"), dsv.Spec.Csv, &csv_sc.plan, dsv_opts = {infer = true})
	defer check.result_destroy(&rdsv_ok)
	testing.expect(t, rdsv_ok.valid)

	rdsv_bad := engine.check_schema(transmute([]u8)string("id\nnope\n"), dsv.Spec.Csv, &csv_sc.plan, dsv_opts = {infer = true})
	defer check.result_destroy(&rdsv_bad)
	testing.expect(t, !rdsv_bad.valid)

	xml_schema := `{"type": "object", "required": ["root"]}`
	xml_sc, xml_sc_err := schema.compile_json(transmute([]u8)xml_schema)
	testing.expect_value(t, xml_sc_err.kind, schema.Error_Kind.None)
	defer schema.destroy(xml_sc)
	rxml := engine.check_schema(transmute([]u8)string(`<root><item>x</item></root>`), xml.Spec.Xml, &xml_sc.plan)
	defer check.result_destroy(&rxml)
	testing.expect(t, rxml.valid)

	doc, berr := engine.build(valid_json, json.Spec.Json)
	testing.expect_value(t, berr, tape.Error(nil))
	defer tape.destroy(&doc)
	rdoc := engine.check_document(&doc, &sc.plan)
	defer check.result_destroy(&rdoc)
	testing.expect(t, rdoc.valid)

	// Streaming `check_schema` on YAML (Core + `.Failsafe` dialect), MessagePack, and HTML.
	valid_yaml := transmute([]u8)string("name: ada\ncount: 3\n")
	ry := engine.check_schema(valid_yaml, yaml.Spec.Yaml_1_2, &sc.plan)
	defer check.result_destroy(&ry)
	testing.expect(t, ry.valid)

	ry_fs := engine.check_schema(valid_yaml, yaml.Spec.Yaml_1_2, &sc.plan, yaml_opts = {dialect = .Failsafe})
	defer check.result_destroy(&ry_fs)
	testing.expect(t, !ry_fs.valid)

	valid_mp, _, mp_ferr := engine.format(valid_json, json.Spec.Json, msgpack.Spec.Compact)
	testing.expect_value(t, mp_ferr, engine.Format_Error(nil))
	defer delete(valid_mp)
	rmp := engine.check_schema(valid_mp, msgpack.Spec.Msgpack, &sc.plan)
	defer check.result_destroy(&rmp)
	testing.expect(t, rmp.valid)

	html_sc, hscerr := schema.compile_json(transmute([]u8)string(`{"type":"object","required":["html"]}`))
	testing.expect_value(t, hscerr.kind, schema.Error_Kind.None)
	defer schema.destroy(html_sc)
	rhtml := engine.check_schema(transmute([]u8)string(`<!DOCTYPE html><html><body><p>hello</p></body></html>`), html.Spec.Html, &html_sc.plan)
	defer check.result_destroy(&rhtml)
	testing.expect(t, rhtml.valid)
}

@(test)
ops_diff_cross_format_and_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_a := transmute([]u8)string(`{"service":"api","ports":[80,443],"tags":["v1"]}`)
	toml_b := transmute([]u8)string("service = \"api\"\nports = [80, 8443]\ntags = [\"v1\", \"v2\"]\n")

	dres, derr := engine.diff_bytes(json_a, json.Spec.Json, toml_b, toml.Spec.Toml_1_0)
	testing.expect_value(t, derr, nil)
	defer diff.destroy_result(&dres)
	testing.expect_value(t, len(dres.changes), 2)

	// Fact diff across JSONC comments (`diff.Options{facts = true}`).
	jc1 := transmute([]u8)string("// old note\n{\"a\": 1}")
	jc2 := transmute([]u8)string("// new note\n{\"a\": 1}")
	doc1, e1 := engine.build(jc1, json.Spec.Jsonc)
	doc2, e2 := engine.build(jc2, json.Spec.Jsonc)
	testing.expect_value(t, e1, tape.Error(nil))
	testing.expect_value(t, e2, tape.Error(nil))
	defer tape.destroy(&doc1)
	defer tape.destroy(&doc2)

	fdres, fderr := engine.diff_documents(&doc1, &doc2, {facts = true})
	testing.expect_value(t, fderr, diff.Error(nil))
	defer diff.destroy_result(&fdres)
	testing.expect(t, len(fdres.changes) >= 1)
	testing.expect_value(t, fdres.changes[0].op, diff.Op.Fact)

	// Cross-format diff: YAML vs MessagePack yields zero changes for identical content.
	y_src := transmute([]u8)string("a: 1\nb: hi\n")
	mp_src, _, mp_err := engine.format(transmute([]u8)string(`{"a":1,"b":"hi"}`), json.Spec.Json, msgpack.Spec.Compact)
	testing.expect_value(t, mp_err, engine.Format_Error(nil))
	defer delete(mp_src)
	ym_dres, ym_derr := engine.diff_bytes(y_src, yaml.Spec.Yaml_1_2, mp_src, msgpack.Spec.Msgpack)
	testing.expect_value(t, ym_derr, engine.Diff_Error(nil))
	defer diff.destroy_result(&ym_dres)
	testing.expect_value(t, len(ym_dres.changes), 0)
}

@(test)
ops_edit_commit_jsonc_and_xml_doc :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. JSONC byte-preserving `edit_commit` + clean `edit_commit_document` no-op clone path.
	src := transmute([]u8)string("{\n  // keep header\n  \"a\": 1,\n  \"b\": 2\n}\n")
	doc, err := engine.build(src, json.Spec.Jsonc)
	testing.expect_value(t, err, tape.Error(nil))
	defer tape.destroy(&doc)

	noop_ov: edit.Overlay
	testing.expect(t, edit.init(&noop_ov, &doc) == nil)
	defer edit.destroy(&noop_ov)
	noop_doc, noop_res, noop_err := engine.edit_commit_document(&noop_ov, json.Spec.Jsonc)
	testing.expect(t, noop_err == nil)
	defer tape.destroy(&noop_doc)
	defer edit.destroy_commit_result(&noop_res)
	testing.expect_value(t, string(noop_res.bytes), string(src))
	testing.expect_value(t, len(noop_doc.nodes), len(doc.nodes))

	ov: edit.Overlay
	testing.expect(t, edit.init(&ov, &doc) == nil)
	defer edit.destroy(&ov)
	root, rh_err := edit.ensure_root(&ov)
	testing.expect(t, rh_err == nil)
	_, sm_err := edit.set_member(&ov, root, "b", edit.val_int(99))
	testing.expect(t, sm_err == nil)

	cres, cerr := engine.edit_commit(&ov, json.Spec.Jsonc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&cres)
	testing.expect_value(t, string(cres.bytes), "{\n  // keep header\n  \"a\": 1,\n  \"b\": 99\n}\n")

	// 2. XML `edit_commit_document` + `reconcile_edit_document` incremental tape splicing!
	// (Note: xml.walk_fragment returns `(ft, nil)` cleanly; other formats returning `shift_fragment_tape` directly are noted upstream.)
	x_doc, xberr := engine.build(transmute([]u8)string(`<r><a>1</a><b>2</b></r>`), xml.Spec.Xml)
	testing.expect_value(t, xberr, tape.Error(nil))
	defer tape.destroy(&x_doc)

	x_ov: edit.Overlay
	testing.expect(t, edit.init(&x_ov, &x_doc) == nil)
	defer edit.destroy(&x_ov)
	x_rn, x_pres := tape.member(tape.Reader{doc = &x_doc}, tape.ROOT, "r")
	testing.expect_value(t, x_pres, tape.Presence.Found)
	x_rh, _ := edit.handle_for_base(&x_ov, x_rn)
	_, _ = edit.set_member(&x_ov, x_rh, "b", edit.val_string("9"))

	x_spliced, x_cres, x_cerr := engine.edit_commit_document(&x_ov, xml.Spec.Xml)
	testing.expect(t, x_cerr == nil)
	defer tape.destroy(&x_spliced)
	defer edit.destroy_commit_result(&x_cres)
	testing.expect_value(t, string(x_cres.bytes), `<r><a>1</a><b>9</b></r>`)

	xr := tape.Reader{doc = &x_spliced}
	sr, srp := tape.member(xr, tape.ROOT, "r")
	testing.expect_value(t, srp, tape.Presence.Found)
	bn, bpres := tape.member(xr, sr, "b")
	testing.expect_value(t, bpres, tape.Presence.Found)
	testing.expect_value(t, string(tape.span_bytes(&x_spliced, x_spliced.nodes[bn].lo, x_spliced.nodes[bn].n)), "9")
}

@(test)
ops_edit_commit_reflow :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 2. Group 2 reflow refusal + `reflow = true` through `engine.edit_commit`.
	dup_src := transmute([]u8)string(`{"a":1,"a":2}`)
	dup_doc, derr := engine.build(dup_src, json.Spec.Json)
	testing.expect_value(t, derr, tape.Error(nil))
	defer tape.destroy(&dup_doc)

	dup_ov: edit.Overlay
	testing.expect(t, edit.init(&dup_ov, &dup_doc) == nil)
	defer edit.destroy(&dup_ov)
	droot, _ := edit.ensure_root(&dup_ov)
	_, _ = edit.set_member(&dup_ov, droot, "a", edit.val_int(5))
	_, no_reflow_err := engine.edit_commit(&dup_ov, json.Spec.Json, {reflow = false})
	ref, is_ref := no_reflow_err.(edit.Refusal)
	testing.expect(t, is_ref && ref.kind == .Layout_Reflow_Needed)

	with_reflow, reflow_err := engine.edit_commit(&dup_ov, json.Spec.Json, {reflow = true})
	testing.expect(t, reflow_err == nil)
	defer edit.destroy_commit_result(&with_reflow)
	testing.expect_value(t, string(with_reflow.bytes), `{"a":5}`)
}

@(private = "file")
Cap_Out :: struct {
	val: query.Value,
	has: bool,
}

@(private = "file")
cap_first_out :: proc(data: rawptr, v: query.Value, h: ^query.Heap) -> bool {
	c := (^Cap_Out)(data)
	if !c.has {
		c.val = v
		c.has = true
	} else {
		query.release(h, v)
	}
	return false
}

@(private = "file")
eval_first_overlay :: proc(t: ^testing.T, h: ^query.Heap, ov: ^edit.Overlay, expr: string, loc := #caller_location) -> query.Value {
	prog, perrs := jq.compile(expr)
	testing.expect_value(t, len(perrs), 0, loc = loc)
	defer jq.destroy_program(prog)
	inp, ist := query.overlay_value(h, ov)
	testing.expect_value(t, ist, query.Status.Ok, loc = loc)
	cap_out: Cap_Out
	run: jq.Run
	jq.run_init(&run, prog, h, nil)
	defer jq.run_destroy(&run)
	end := jq.run_value(&run, inp, cap_first_out, &cap_out)
	testing.expect_value(t, end, jq.Run_End.Stopped, loc = loc)
	testing.expect(t, cap_out.has, loc = loc)
	return cap_out.val
}

@(test)
ops_edit_reconcile_jq :: proc(t: ^testing.T) {
	testkit.deadline(t)

	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)

	// 1. Real jq provenance mutation -> `engine.reconcile_edit` preserves formatting/comments outside mutated field.
	{
		jq_src := transmute([]u8)string("{\n  // keep spacing\n  \"a\": { \"x\" :  1 },\n  \"b\": 2\n}\n")
		jq_doc, jq_berr := engine.build(jq_src, json.Spec.Jsonc)
		testing.expect_value(t, jq_berr, tape.Error(nil))
		defer tape.destroy(&jq_doc)

		jq_ov: edit.Overlay
		testing.expect(t, edit.init(&jq_ov, &jq_doc) == nil)
		defer edit.destroy(&jq_ov)

		val := eval_first_overlay(t, &h, &jq_ov, `{a: .a, b: (.b + 10)}`)
		defer query.release(&h, val)

		rres, rerr := engine.reconcile_edit(&h, &jq_ov, val)
		testing.expect(t, rerr == nil)
		defer edit.destroy_commit_result(&rres)
		testing.expect_value(t, string(rres.bytes), "{\n  // keep spacing\n  \"a\": { \"x\" :  1 },\n  \"b\": 12\n}\n")
	}

	// 2. XML `reconcile_edit_document`: jq update reconciled onto overlay -> spliced document + bytes.
	{
		xdoc, xberr := engine.build(transmute([]u8)string(`<r><a>1</a><b>2</b></r>`), xml.Spec.Xml)
		testing.expect_value(t, xberr, tape.Error(nil))
		defer tape.destroy(&xdoc)
		xov: edit.Overlay
		testing.expect(t, edit.init(&xov, &xdoc) == nil)
		defer edit.destroy(&xov)

		xval := eval_first_overlay(t, &h, &xov, `.r.b = "9"`)
		defer query.release(&h, xval)

		xspliced, xres, xcerr := engine.reconcile_edit_document(&h, &xov, xval)
		testing.expect(t, xcerr == nil)
		defer tape.destroy(&xspliced)
		defer edit.destroy_commit_result(&xres)
		testing.expect_value(t, string(xres.bytes), `<r><a>1</a><b>9</b></r>`)
	}

	// 3. `reconcile_edit_document` forwards `Yaml_Options` (`.Failsafe`).
	{
		yaml_src := transmute([]u8)string("a: 1\n")
		fs_opts := tape.Yaml_Options{dialect = .Failsafe}
		ydoc, yerr := engine.build(yaml_src, yaml.Spec.Yaml_1_2, {format = fs_opts})
		testing.expect_value(t, yerr, tape.Error(nil))
		defer tape.destroy(&ydoc)

		yov: edit.Overlay
		testing.expect_value(t, edit.init(&yov, &ydoc), edit.Error(nil))
		defer edit.destroy(&yov)

		yval := eval_first_overlay(t, &h, &yov, `.b = "01"`)
		defer query.release(&h, yval)

		sdoc, cres, cerr := engine.reconcile_edit_document(&h, &yov, yval, yaml.Spec.Yaml_1_2, {}, context.allocator, fs_opts)
		testing.expect_value(t, cerr, edit.Error(nil))
		defer tape.destroy(&sdoc)
		defer edit.destroy_commit_result(&cres)

		out_json, _, werr := engine.write(&sdoc, json.Spec.Json)
		testing.expect_value(t, werr, write.Error(nil))
		defer delete(out_json)
		testing.expect_value(t, string(out_json), `{"a":"1","b":"01"}`)
	}
}

@(test)
ops_edit_commit_toml_xml_cbor :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 4. TOML + XML + CBOR `edit_commit` dispatch via engine.
	t_doc, _ := engine.build(transmute([]u8)string("a = 1\nb = 2\n"), toml.Spec.Toml_1_0)
	defer tape.destroy(&t_doc)
	t_ov: edit.Overlay
	_ = edit.init(&t_ov, &t_doc)
	defer edit.destroy(&t_ov)
	t_root, _ := edit.ensure_root(&t_ov)
	_, _ = edit.set_member(&t_ov, t_root, "b", edit.val_int(42))
	tc, tc_err := engine.edit_commit(&t_ov)
	testing.expect(t, tc_err == nil)
	defer edit.destroy_commit_result(&tc)
	testing.expect_value(t, string(tc.bytes), "a = 1\nb = 42\n")

	x_doc, _ := engine.build(transmute([]u8)string(`<r><a>1</a></r>`), xml.Spec.Xml)
	defer tape.destroy(&x_doc)
	x_ov: edit.Overlay
	_ = edit.init(&x_ov, &x_doc)
	defer edit.destroy(&x_ov)
	x_rn, x_rpres := tape.member(tape.Reader{doc = &x_doc}, tape.ROOT, "r")
	testing.expect_value(t, x_rpres, tape.Presence.Found)
	x_rh, _ := edit.handle_for_base(&x_ov, x_rn)
	_, _ = edit.set_member(&x_ov, x_rh, "a", edit.val_string("2"))
	xc, xc_err := engine.edit_commit(&x_ov)
	testing.expect(t, xc_err == nil)
	defer edit.destroy_commit_result(&xc)
	testing.expect_value(t, string(xc.bytes), `<r><a>2</a></r>`)

	c_doc, _ := engine.build([]u8{0xA1, 0x61, 'a', 0x01}, cbor.Spec.Cbor)
	defer tape.destroy(&c_doc)
	c_ov: edit.Overlay
	_ = edit.init(&c_ov, &c_doc)
	defer edit.destroy(&c_ov)
	c_root, _ := edit.ensure_root(&c_ov)
	_, _ = edit.set_member(&c_ov, c_root, "a", edit.val_int(9))
	cc, cc_err := engine.edit_commit(&c_ov)
	testing.expect(t, cc_err == nil)
	defer edit.destroy_commit_result(&cc)
	testing.expect(t, bytes.equal(cc.bytes, []u8{0xA1, 0x61, 'a', 0x09}))

	// 5. YAML, HTML, and MessagePack `edit_commit_document` dispatch via engine.
	{
		ydoc, yerr := engine.build(transmute([]u8)string("# keep\na: 1\nb: old\n"), yaml.Spec.Yaml_1_2)
		testing.expect_value(t, yerr, tape.Error(nil))
		defer tape.destroy(&ydoc)
		ov: edit.Overlay
		testing.expect_value(t, engine.edit_init(&ov, &ydoc), edit.Error(nil))
		defer edit.destroy(&ov)
		st := [?]tape.Step{tape.Name("b")}
		_, serr := edit.set_path(&ov, st[:], edit.val_string("new"))
		testing.expect_value(t, serr, edit.Error(nil))
		sdoc, cres, cerr := engine.edit_commit_document(&ov)
		testing.expect_value(t, cerr, edit.Error(nil))
		defer tape.destroy(&sdoc)
		defer edit.destroy_commit_result(&cres)
		testing.expect(t, strings.contains(string(cres.bytes), "# keep") && strings.contains(string(cres.bytes), "new"))
	}
	{
		hdoc, herr := engine.build(transmute([]u8)string(`<html><body><p>old</p></body></html>`), html.Spec.Html)
		testing.expect_value(t, herr, tape.Error(nil))
		defer tape.destroy(&hdoc)
		ov: edit.Overlay
		testing.expect_value(t, engine.edit_init(&ov, &hdoc), edit.Error(nil))
		defer edit.destroy(&ov)
		st := [?]tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("p")}
		_, serr := edit.set_path(&ov, st[:], edit.val_string("updated"))
		testing.expect_value(t, serr, edit.Error(nil))
		sdoc, cres, cerr := engine.edit_commit_document(&ov, html.Spec.Html)
		testing.expect_value(t, cerr, edit.Error(nil))
		defer tape.destroy(&sdoc)
		defer edit.destroy_commit_result(&cres)
		testing.expect(t, strings.contains(string(cres.bytes), "<p>updated</p>"))
	}
	{
		j_mp, _, jmp_err := engine.format(transmute([]u8)string(`{"a":1,"b":"hi"}`), json.Spec.Json, msgpack.Spec.Compact)
		testing.expect_value(t, jmp_err, engine.Format_Error(nil))
		defer delete(j_mp)
		mdoc, merr := engine.build(j_mp, msgpack.Spec.Msgpack)
		testing.expect_value(t, merr, tape.Error(nil))
		defer tape.destroy(&mdoc)
		ov: edit.Overlay
		testing.expect_value(t, engine.edit_init(&ov, &mdoc), edit.Error(nil))
		defer edit.destroy(&ov)
		st := [?]tape.Step{tape.Name("a")}
		_, serr := edit.set_path(&ov, st[:], edit.val_int(99))
		testing.expect_value(t, serr, edit.Error(nil))
		sdoc, cres, cerr := engine.edit_commit_document(&ov, msgpack.Spec.Compact)
		testing.expect_value(t, cerr, edit.Error(nil))
		defer tape.destroy(&sdoc)
		defer edit.destroy_commit_result(&cres)
		as_json, _, ferr := engine.write(&sdoc, json.Spec.Json)
		testing.expect_value(t, ferr, write.Error(nil))
		defer delete(as_json)
		testing.expect_value(t, string(as_json), `{"a":99,"b":"hi"}`)
	}
}

@(test)
ops_edit_commit_target_validation :: proc(t: ^testing.T) {
	testkit.deadline(t)

	doc, berr := engine.build(transmute([]u8)string(`{"a":1}`), json.Spec.Json)
	testing.expect_value(t, berr, tape.Error(nil))
	defer tape.destroy(&doc)

	ov: edit.Overlay
	testing.expect(t, edit.init(&ov, &doc) == nil)
	defer edit.destroy(&ov)
	root, _ := edit.ensure_root(&ov)
	_, _ = edit.set_member(&ov, root, "a", edit.val_int(2))

	// Conflicting `target` vs `opts.target` rejects with `Bad_Option{"target"}`.
	_, conflict_err := engine.edit_commit(&ov, json.Spec.Json, {target = xml.as(.Xml)})
	c_bo, c_is_bo := conflict_err.(tape.Bad_Option)
	testing.expect(t, c_is_bo && c_bo.option == "target")

	// Unknown `opts.target` when `target == nil` rejects with `Bad_Option{"target"}` instead of silent fallback.
	unknown_fmt: tape.Format
	unknown_fmt.id = tape.Format_Id(9999)
	_, unk_err := engine.edit_commit(&ov, nil, {target = &unknown_fmt})
	u_bo, u_is_bo := unk_err.(tape.Bad_Option)
	testing.expect(t, u_is_bo && u_bo.option == "target")
}

@(test)
ops_bytes_roundtrip_cbor_msgpack_and_text :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// CBOR map {"payload": h'deadbeef', "label": "ok"} -> MessagePack -> CBOR preserves native `.Bytes`.
	cbor_src := [?]u8{0xA2, 0x67, 'p', 'a', 'y', 'l', 'o', 'a', 'd', 0x44, 0xDE, 0xAD, 0xBE, 0xEF, 0x65, 'l', 'a', 'b', 'e', 'l', 0x62, 'o', 'k'}
	raw_want := [?]u8{0xDE, 0xAD, 0xBE, 0xEF}

	mp_bytes, _, f1 := engine.format(cbor_src[:], cbor.Spec.Cbor, msgpack.Spec.Compact)
	testing.expect_value(t, f1, engine.Format_Error(nil))
	defer delete(mp_bytes)

	mp_doc, mberr := engine.build(mp_bytes, msgpack.Spec.Msgpack)
	testing.expect_value(t, mberr, tape.Error(nil))
	defer tape.destroy(&mp_doc)
	mp_p, mp_pres := tape.member(tape.Reader{doc = &mp_doc}, tape.ROOT, "payload")
	testing.expect_value(t, mp_pres, tape.Presence.Found)
	testing.expect_value(t, mp_doc.nodes[mp_p].kind, tape.Kind.Bytes)
	testing.expect(t, bytes.equal(tape.span_bytes(&mp_doc, mp_doc.nodes[mp_p].lo, mp_doc.nodes[mp_p].n), raw_want[:]))

	// Through `query.Value` -> `engine.write_value`: binary targets emit native `.Bytes`, text targets emit RFC 4648 base64!
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	qv, qst := query.document_value(&h, mp_doc, owned = false)
	testing.expect_value(t, qst, query.Status.Ok)
	defer query.release(&h, qv)

	// Write `query.Value` back to CBOR and verify native `.Bytes`.
	cbor_out, cwerr := engine.write_value(&h, qv, cbor.Spec.Cbor)
	testing.expect_value(t, cwerr, write.Error(nil))
	defer delete(cbor_out)
	cdoc, cberr := engine.build(cbor_out, cbor.Spec.Cbor)
	testing.expect_value(t, cberr, tape.Error(nil))
	defer tape.destroy(&cdoc)
	cp, cpres := tape.member(tape.Reader{doc = &cdoc}, tape.ROOT, "payload")
	testing.expect_value(t, cpres, tape.Presence.Found)
	testing.expect_value(t, cdoc.nodes[cp].kind, tape.Kind.Bytes)
	testing.expect(t, bytes.equal(tape.span_bytes(&cdoc, cdoc.nodes[cp].lo, cdoc.nodes[cp].n), raw_want[:]))

	// Write `query.Value` back to MessagePack and verify native `.Bytes`.
	mp_out, mwerr := engine.write_value(&h, qv, msgpack.Spec.Compact)
	testing.expect_value(t, mwerr, write.Error(nil))
	defer delete(mp_out)
	mdoc2, mberr2 := engine.build(mp_out, msgpack.Spec.Msgpack)
	testing.expect_value(t, mberr2, tape.Error(nil))
	defer tape.destroy(&mdoc2)
	mp2, mpres2 := tape.member(tape.Reader{doc = &mdoc2}, tape.ROOT, "payload")
	testing.expect_value(t, mpres2, tape.Presence.Found)
	testing.expect_value(t, mdoc2.nodes[mp2].kind, tape.Kind.Bytes)
	testing.expect(t, bytes.equal(tape.span_bytes(&mdoc2, mdoc2.nodes[mp2].lo, mdoc2.nodes[mp2].n), raw_want[:]))

	// Text targets emit RFC 4648 base64 (`"3q2+7w=="`).
	for text_spec in ([?]engine.Spec{json.Spec.Json, yaml.Spec.Yaml_1_2, toml.Spec.Toml_1_0}) {
		tout, twerr := engine.write_value(&h, qv, text_spec)
		testing.expectf(t, twerr == nil, "write_value %v err: %v", text_spec, twerr)
		defer delete(tout)
		testing.expectf(t, strings.contains(string(tout), "3q2+7w=="), "%v got %q", text_spec, string(tout))
	}

	// XML unmarshal via `engine.unmarshal`.
	Item :: struct {
		name:  string `xml:"name"`,
		count: int    `xml:"count"`,
	}
	Doc :: struct {
		item: Item `xml:"item"`,
	}
	got: Doc
	uerr := engine.unmarshal(transmute([]u8)string(`<item><name>widget</name><count>5</count></item>`), &got, xml.Spec.Xml)
	testing.expect_value(t, uerr, tape.Error(nil))
	defer delete(got.item.name)
	testing.expect_value(t, got.item.name, "widget")
	testing.expect_value(t, got.item.count, 5)
}
