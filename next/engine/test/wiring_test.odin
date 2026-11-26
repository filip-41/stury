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
import ops_write "stury:lib/ops/write"
import "stury:lib/query"
import schema_check "stury:lib/schema/check"
import schema_pkg "stury:lib/schema/schema"
import "stury:msgpack"
import "stury:testkit"
import "stury:toml"
import "stury:xml"
import "stury:yaml"

@(test)
wiring_all_eight_formats_registry_and_unique_ids :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// All 19 Format_Id specs map bijectively and claim strictly distinct tape.Format_Ids.
	seen := make(map[tape.Format_Id]engine.Format_Id)
	defer delete(seen)
	for id in engine.Format_Id {
		e, ok := engine.entry_of(id)
		testing.expectf(t, ok, "entry_of(%v) failed", id)
		testing.expect(t, e.format != nil && e.reads != nil)
		testing.expect_value(t, e.format.id, e.tape_id)
		prev, dup := seen[e.tape_id]
		testing.expectf(t, !dup, "tape Format_Id %d collides between %v and %v", e.tape_id, prev, id)
		seen[e.tape_id] = id
	}
	testing.expect_value(t, len(seen), 19)

	// New names, aliases, and extensions resolve cleanly.
	Name_Case :: struct {
		name:    string,
		id:      engine.Format_Id,
		framing: engine.Framing,
	}
	name_cases := [?]Name_Case {
		{"yaml", .Yaml, .Single},
		{"yml", .Yaml, .Single},
		{"yaml:1.2", .Yaml, .Single},
		{"YAML:MERGE", .Yaml_Merge, .Single},
		{"yaml-merge", .Yaml_Merge, .Single},
		{"html", .Html, .Single},
		{"htm", .Html, .Single},
		{"html:fragment", .Html_Fragment, .Single},
		{"msgpack", .Msgpack, .Concatenated},
		{"mpk", .Msgpack, .Concatenated},
		{"msgpack:compact", .Msgpack_Compact, .Concatenated},
	}
	for c in name_cases {
		e, fr, ok := engine.format_and_framing_by_name(c.name)
		testing.expectf(t, ok, "format_and_framing_by_name(%q) failed", c.name)
		testing.expect_value(t, e.id, c.id)
		testing.expect_value(t, fr, c.framing)
	}

	Path_Case :: struct {
		path: string,
		id:   engine.Format_Id,
	}
	path_cases := [?]Path_Case {
		{"config.yaml", .Yaml},
		{"compose.yml.gz", .Yaml},
		{"index.html", .Html},
		{"page.htm.zst", .Html},
		{"payload.msgpack", .Msgpack},
		{"packet.mpk.bz2", .Msgpack},
	}
	for c in path_cases {
		e, _, ok := engine.format_of_path(c.path)
		testing.expectf(t, ok, "format_of_path(%q) failed", c.path)
		testing.expect_value(t, e.id, c.id)
	}

	// Content detection for explicit YAML markers, HTML5 documents, and MessagePack binary items.
	ey, fy, oky := engine.detect_format(transmute([]u8)string("---\nname: stury\n"))
	testing.expect(t, oky && ey.id == .Yaml && fy == .Single)

	ey2, fy2, oky2 := engine.detect_format(transmute([]u8)string("%YAML 1.2\n---\na: 1\n---\na: 2\n"))
	testing.expect(t, oky2 && ey2.id == .Yaml && fy2 == .Concatenated)

	eh, fh, okh := engine.detect_format(transmute([]u8)string("<!DOCTYPE html><html><body><p>hi</p></body></html>"))
	testing.expect(t, okh && eh.id == .Html && fh == .Single)

	// MessagePack fixmap `{"k": 5}` (`0x81 0xA1 'k' 0x05`) is invalid CBOR and detects as `.Msgpack`.
	mp_single := [?]u8{0x81, 0xA1, 'k', 0x05}
	em, fm, okm := engine.detect_format(mp_single[:])
	testing.expect(t, okm && em.id == .Msgpack && fm == .Single)

	mp_seq := [?]u8{0x81, 0xA1, 'k', 0x05, 0x81, 0xA1, 'k', 0x06}
	em2, fm2, okm2 := engine.detect_format(mp_seq[:])
	testing.expect(t, okm2 && em2.id == .Msgpack && fm2 == .Concatenated)
}

@(test)
wiring_all_eight_formats_ops_roundtrip :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","id":7}}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nid = 7\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name><id>7</id></user></root>`)
	csv_src := transmute([]u8)string("name,id\nada,7\n")
	cbor_src := [?]u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x62, 'i', 'd', 0x07}
	yaml_src := transmute([]u8)string("user:\n  name: ada\n  id: 7\n")
	html_src := transmute([]u8)string(`<!DOCTYPE html><html><body><p id="p1">ada</p></body></html>`)
	mp_src := [?]u8{0x81, 0xA4, 'u', 's', 'e', 'r', 0x82, 0xA4, 'n', 'a', 'm', 'e', 0xA3, 'a', 'd', 'a', 0xA2, 'i', 'd', 0x07}

	Case :: struct {
		name: string,
		spec: engine.Spec,
		src:  []u8,
		path: []tape.Step,
	}
	user_name := [?]tape.Step{tape.Name("user"), tape.Name("name")}
	xml_path := [?]tape.Step{tape.Name("root"), tape.Name("user"), tape.Name("name")}
	csv_path := [?]tape.Step{tape.Index(0), tape.Name("name")}
	html_path := [?]tape.Step{tape.Name("html"), tape.Name("body"), tape.Name("p")}

	cases := [?]Case {
		{"json", json.Spec.Json, json_src, user_name[:]},
		{"toml", toml.Spec.Toml_1_0, toml_src, user_name[:]},
		{"xml", xml.Spec.Xml, xml_src, xml_path[:]},
		{"csv", dsv.Spec.Csv, csv_src, csv_path[:]},
		{"cbor", cbor.Spec.Cbor, cbor_src[:], user_name[:]},
		{"yaml", yaml.Spec.Yaml_1_2, yaml_src, user_name[:]},
		{"html", html.Spec.Html, html_src, html_path[:]},
		{"msgpack", msgpack.Spec.Msgpack, mp_src[:], user_name[:]},
	}

	for c in cases {
		// 1. validate
		testing.expectf(t, engine.validate(c.src, c.spec) == nil, "%s validate failed", c.name)

		// 2. build + write + write_to (roundtrip back to own spec and to JSON)
		doc, berr := engine.build(c.src, c.spec)
		testing.expectf(t, berr == nil, "%s build failed: %v", c.name, berr)
		defer tape.destroy(&doc)

		own_bytes, _, werr := engine.write(&doc, c.spec)
		testing.expectf(t, werr == nil && len(own_bytes) > 0, "%s write failed: %v", c.name, werr)
		delete(own_bytes)

		buf: bytes.Buffer
		bytes.buffer_init_allocator(&buf, 0, 64)
		_, wterr := engine.write_to(bytes.buffer_to_stream(&buf), &doc, json.Spec.Json)
		testing.expectf(t, wterr == nil && bytes.buffer_length(&buf) > 0, "%s write_to json failed: %v", c.name, wterr)
		bytes.buffer_destroy(&buf)

		// 3. find
		ans, ferr := engine.find(c.src, c.path, c.spec)
		testing.expectf(t, ferr == nil && ans.outcome == .Found, "%s find failed: %v %v", c.name, ferr, ans.outcome)

		// 4. scan
		paths := [?][]tape.Step{c.path}
		dem, derr := tape.demand_of(paths[:])
		testing.expect_value(t, derr, nil)
		defer tape.destroy_demand(&dem)
		sdoc, serr := engine.scan(c.src, &dem, c.spec)
		testing.expectf(t, serr == nil, "%s scan failed: %v", c.name, serr)
		tape.destroy(&sdoc)
	}
}

@(test)
wiring_cross_format_conversions_edit_check_and_writers :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Cross-format conversions: YAML <-> JSON, YAML_MERGE -> JSON, HTML <-> JSON, MSGPACK <-> JSON/CBOR.
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

	// MessagePack <-> JSON <-> CBOR.
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

	// HTML <-> JSON.
	html_src := transmute([]u8)string(`<!DOCTYPE html><html><body><p>hello</p></body></html>`)
	h_json, _, hj_err := engine.format(html_src, html.Spec.Html, json.Spec.Json)
	testing.expect_value(t, hj_err, engine.Format_Error(nil))
	defer delete(h_json)
	testing.expect(t, strings.contains(string(h_json), `"hello"`))
	j_html, _, jh_err := engine.format(h_json, json.Spec.Json, html.Spec.Html)
	testing.expect_value(t, jh_err, engine.Format_Error(nil))
	defer delete(j_html)
	testing.expect(t, strings.contains(string(j_html), "<p>hello</p>"))

	// 2. Streaming `check_schema` on YAML (including dialect option), HTML, and MessagePack.
	sc, scerr := schema_pkg.compile_json(transmute([]u8)string(`{"type":"object","required":["a","b"],"properties":{"a":{"type":"integer"},"b":{"type":"string"}}}`))
	testing.expect_value(t, scerr.kind, .None)
	defer schema_pkg.destroy(sc)

	cy := engine.check_schema(j_yaml, yaml.Spec.Yaml_1_2, &sc.plan)
	defer schema_check.result_destroy(&cy)
	testing.expect(t, cy.valid)

	// Under YAML Failsafe dialect, `a: 1` resolves as string so `"type":"integer"` fails.
	cy_fs := engine.check_schema(j_yaml, yaml.Spec.Yaml_1_2, &sc.plan, yaml_opts = {dialect = .Failsafe})
	defer schema_check.result_destroy(&cy_fs)
	testing.expect(t, !cy_fs.valid)

	cm := engine.check_schema(j_mp, msgpack.Spec.Msgpack, &sc.plan)
	defer schema_check.result_destroy(&cm)
	testing.expect(t, cm.valid)

	html_sc, hscerr := schema_pkg.compile_json(transmute([]u8)string(`{"type":"object","required":["html"]}`))
	testing.expect_value(t, hscerr.kind, .None)
	defer schema_pkg.destroy(html_sc)
	ch := engine.check_schema(html_src, html.Spec.Html, &html_sc.plan)
	defer schema_check.result_destroy(&ch)
	testing.expect(t, ch.valid)

	// 3. Edit `edit_commit` + `edit_commit_document` on YAML, HTML, and MessagePack.
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
		testing.expect_value(t, ferr, ops_write.Error(nil))
		defer delete(as_json)
		testing.expect_value(t, string(as_json), `{"a":99,"b":"hi"}`)
	}

	// 4. Cross-format diff (YAML vs MessagePack) + table & markdown writers.
	dres, derr := engine.diff_bytes(j_yaml, yaml.Spec.Yaml_1_2, j_mp, msgpack.Spec.Msgpack)
	testing.expect_value(t, derr, engine.Diff_Error(nil))
	defer diff.destroy_result(&dres)
	testing.expect_value(t, len(dres.changes), 0)

	arr_doc, ab_err := engine.build(transmute([]u8)string(`[{"name":"ada","score":10},{"name":"bob","score":20}]`), json.Spec.Json)
	testing.expect_value(t, ab_err, tape.Error(nil))
	defer tape.destroy(&arr_doc)

	tbl, terr := engine.write_table(&arr_doc)
	testing.expect_value(t, terr, ops_write.Error(nil))
	defer delete(tbl)
	testing.expect(t, strings.contains(string(tbl), "name") && strings.contains(string(tbl), "ada"))

	md, mderr := engine.write_markdown(&arr_doc)
	testing.expect_value(t, mderr, ops_write.Error(nil))
	defer delete(md)
	testing.expect(t, strings.contains(string(md), "| name") && strings.contains(string(md), "---:"))
}

@(test)
wiring_neon_regressions_detect_and_reconcile_yaml_dialect :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Finding 2: JSON5 / CSV containing `\v` (`0x0b`) or `\f` (`0x0c`) MUST NOT be misclassified as `.Msgpack`.
	ej5, frj5, okj5 := engine.detect_format(transmute([]u8)string("{\x0ca: 1}"))
	testing.expect(t, okj5 && ej5.id == .Json5 && frj5 == .Single)

	ej5v, _, okj5v := engine.detect_format(transmute([]u8)string("{\x0ba: 1}"))
	testing.expect(t, okj5v && ej5v.id == .Json5)

	ecsv, frcsv, okcsv := engine.detect_format(transmute([]u8)string("a,b\n1\x0c,2\n"))
	testing.expect(t, okcsv && ecsv.id == .Csv && frcsv == .Lines)

	// Pure ASCII containing another control byte (e.g. BEL `0x07`) MUST NOT be misclassified as concatenated MessagePack fixints.
	_, _, ok_ctrl := engine.detect_format(transmute([]u8)string("hello\x07world"))
	testing.expect(t, !ok_ctrl)

	// TOML bare key `--- = 1` MUST NOT be misclassified as YAML marker.
	et, _, okt := engine.detect_format(transmute([]u8)string("--- = 1\n"))
	testing.expect(t, okt && et.id == .Toml_1_0)

	// Genuine MessagePack single containers and binary streams still detect as `.Msgpack`.
	mp_arr := [?]u8{0x92, 0x01, 0x02}
	ema, frma, okma := engine.detect_format(mp_arr[:])
	testing.expect(t, okma && ema.id == .Msgpack && frma == .Single)

	mp_bin := [?]u8{0xC4, 0x02, 0xDE, 0xAD}
	emb, frmb, okmb := engine.detect_format(mp_bin[:])
	testing.expect(t, okmb && emb.id == .Msgpack && frmb == .Single)

	mp_stream := [?]u8{0x92, 0x01, 0x02, 0x92, 0x03, 0x04}
	ems, frms, okms := engine.detect_format(mp_stream[:])
	testing.expect(t, okms && ems.id == .Msgpack && frms == .Concatenated)

	// Finding 4: `reconcile_edit` and `reconcile_edit_document` forward `Yaml_Options` (`.Failsafe`).
	yaml_src := transmute([]u8)string("a: 1\n")
	fs_opts := tape.Yaml_Options{dialect = .Failsafe}
	ydoc, yerr := engine.build(yaml_src, yaml.Spec.Yaml_1_2, {format = fs_opts})
	testing.expect_value(t, yerr, tape.Error(nil))
	defer tape.destroy(&ydoc)

	ov: edit.Overlay
	testing.expect_value(t, edit.init(&ov, &ydoc), edit.Error(nil))
	defer edit.destroy(&ov)

	prog, perrs := jq.compile(`.b = "01"`)
	testing.expect_value(t, len(perrs), 0)
	defer jq.destroy_program(prog)

	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)
	inp, ost := query.overlay_value(&h, &ov)
	testing.expect_value(t, ost, query.Status.Ok)

	Cap :: struct {
		val: query.Value,
		has: bool,
	}
	on_out :: proc(d: rawptr, v: query.Value, hp: ^query.Heap) -> bool {
		c := (^Cap)(d)
		if !c.has {
			c.val = v
			c.has = true
		} else {
			query.release(hp, v)
		}
		return false
	}
	cap_out: Cap
	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	end := jq.run_value(&run, inp, on_out, &cap_out)
	testing.expect_value(t, end, jq.Run_End.Stopped)
	testing.expect(t, cap_out.has)
	defer query.release(&h, cap_out.val)

	sdoc, cres, cerr := engine.reconcile_edit_document(&h, &ov, cap_out.val, yaml.Spec.Yaml_1_2, {}, context.allocator, fs_opts)
	testing.expect_value(t, cerr, edit.Error(nil))
	defer tape.destroy(&sdoc)
	defer edit.destroy_commit_result(&cres)

	// Re-reading under `.Failsafe` must produce string values `"1"` and `"01"`.
	out_json, _, werr := engine.write(&sdoc, json.Spec.Json)
	testing.expect_value(t, werr, ops_write.Error(nil))
	defer delete(out_json)
	testing.expect_value(t, string(out_json), `{"a":"1","b":"01"}`)
}
