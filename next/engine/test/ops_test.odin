package engine_tests

import "core:bytes"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:engine"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/diff"
import "stury:lib/ops/edit"
import "stury:lib/ops/write"
import "stury:lib/query"
import "stury:lib/schema/check"
import "stury:lib/schema/schema"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(test)
ops_validate_build_find_scan_records_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","id":7},"extra":[1,2,3]}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nid = 7\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name></user></root>`)
	csv_src := transmute([]u8)string("name,id\nada,7\n")
	cbor_src := []u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x62, 'i', 'd', 0x07}

	specs := [?]engine.Spec {
		json.Spec.Json,
		toml.Spec.Toml_1_0,
		xml.Spec.Xml,
		dsv.Spec.Csv,
		cbor.Spec.Cbor,
	}
	inputs := [?][]u8 {
		json_src,
		toml_src,
		xml_src,
		csv_src,
		cbor_src,
	}

	for s, i in specs {
		testing.expect_value(t, engine.validate(inputs[i], s), tape.Error(nil))
		doc, berr := engine.build(inputs[i], s)
		testing.expect_value(t, berr, tape.Error(nil))
		testing.expect(t, len(doc.nodes) > 0)
		tape.destroy(&doc)
	}

	// Find & Scan across formats supporting path queries.
	path := [?]tape.Step{tape.Name("user"), tape.Name("name")}
	ans, ferr := engine.find(cbor_src, path[:], cbor.Spec.Cbor)
	testing.expect_value(t, ferr, tape.Error(nil))
	testing.expect_value(t, ans.outcome, tape.Presence.Found)
	testing.expect_value(t, ans.kind, tape.Kind.String)

	// Build a narrow partial demand `.user.name`.
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

@(test)
ops_edit_reconcile_jq :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 3. Real jq provenance mutation -> `engine.reconcile_edit` preserves formatting/comments outside mutated field.
	jq_src := transmute([]u8)string("{\n  // keep spacing\n  \"a\": { \"x\" :  1 },\n  \"b\": 2\n}\n")
	jq_doc, jq_berr := engine.build(jq_src, json.Spec.Jsonc)
	testing.expect_value(t, jq_berr, tape.Error(nil))
	defer tape.destroy(&jq_doc)

	jq_ov: edit.Overlay
	testing.expect(t, edit.init(&jq_ov, &jq_doc) == nil)
	defer edit.destroy(&jq_ov)

	prog, perrs := jq.compile(`{a: .a, b: (.b + 10)}`)
	testing.expect_value(t, len(perrs), 0)
	defer jq.destroy_program(prog)

	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	inp, ist := query.overlay_value(&h, &jq_ov)
	testing.expect_value(t, ist, query.Status.Ok)

	Cap_Out :: struct {
		h:   ^query.Heap,
		val: query.Value,
		has: bool,
	}
	on_out :: proc(data: rawptr, v: query.Value, heap_ptr: ^query.Heap) -> bool {
		c := (^Cap_Out)(data)
		if !c.has {
			c.val = v
			c.has = true
		} else {
			query.release(heap_ptr, v)
		}
		return false
	}
	cap_out := Cap_Out{h = &h}
	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	end := jq.run_value(&run, inp, on_out, &cap_out)
	testing.expect_value(t, end, jq.Run_End.Stopped)
	testing.expect(t, cap_out.has)
	defer query.release(&h, cap_out.val)

	rres, rerr := engine.reconcile_edit(&h, &jq_ov, cap_out.val)
	testing.expect(t, rerr == nil)
	defer edit.destroy_commit_result(&rres)
	testing.expect_value(t, string(rres.bytes), "{\n  // keep spacing\n  \"a\": { \"x\" :  1 },\n  \"b\": 12\n}\n")

	// XML `reconcile_edit_document`: jq update reconciled onto overlay -> spliced document + bytes.
	xdoc, xberr := engine.build(transmute([]u8)string(`<r><a>1</a><b>2</b></r>`), xml.Spec.Xml)
	testing.expect_value(t, xberr, tape.Error(nil))
	defer tape.destroy(&xdoc)
	xov: edit.Overlay
	testing.expect(t, edit.init(&xov, &xdoc) == nil)
	defer edit.destroy(&xov)
	xprog, xperrs := jq.compile(`.r.b = "9"`)
	testing.expect_value(t, len(xperrs), 0)
	defer jq.destroy_program(xprog)
	xinp, xist := query.overlay_value(&h, &xov)
	testing.expect_value(t, xist, query.Status.Ok)
	xcap := Cap_Out{h = &h}
	xrun: jq.Run
	jq.run_init(&xrun, xprog, &h, nil)
	defer jq.run_destroy(&xrun)
	xend := jq.run_value(&xrun, xinp, on_out, &xcap)
	testing.expect_value(t, xend, jq.Run_End.Stopped)
	testing.expect(t, xcap.has)
	defer query.release(&h, xcap.val)
	xspliced, xres, xcerr := engine.reconcile_edit_document(&h, &xov, xcap.val)
	testing.expect(t, xcerr == nil)
	defer tape.destroy(&xspliced)
	defer edit.destroy_commit_result(&xres)
	testing.expect_value(t, string(xres.bytes), `<r><a>1</a><b>9</b></r>`)
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
