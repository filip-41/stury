package capi_test

import "base:runtime"
import "core:c"
import "core:strings"
import "core:testing"
import "stury:capi"
import "stury:engine"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import schema_pkg "stury:lib/schema/schema"
import "stury:stury"
import "stury:testkit"

@(private = "file")
c_slice :: #force_inline proc "contextless" (s: string) -> ([^]u8, c.size_t) {
	return raw_data(s), c.size_t(len(s))
}

@(test)
capi_arena_format_lookup_detect_and_caps :: proc(t: ^testing.T) {
	testkit.deadline(t)

	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	capi.stury_arena_reset(a)
	capi.stury_arena_free(a)

	// Format by name.
	p, n := c_slice("json")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Json))
	p, n = c_slice("TOML")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Toml_1_0))
	p, n = c_slice("xml")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Xml))
	p, n = c_slice("csv")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Csv))
	p, n = c_slice("cbor")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Cbor))
	p, n = c_slice("yaml")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Yaml))
	p, n = c_slice("yaml:merge")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Yaml_Merge))
	p, n = c_slice("html")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Html))
	p, n = c_slice("html:fragment")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Html_Fragment))
	p, n = c_slice("msgpack")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Msgpack))
	p, n = c_slice("msgpack:compact")
	testing.expect_value(t, capi.stury_format_by_name(p, n), u32(engine.Format_Id.Msgpack_Compact))
	p, n = c_slice("nope")
	testing.expect_value(t, capi.stury_format_by_name(p, n), capi.FORMAT_UNKNOWN)

	// Format of path.
	p, n = c_slice("dir/file.json.gz")
	testing.expect_value(t, capi.stury_format_of_path(p, n), u32(engine.Format_Id.Json))
	p, n = c_slice("data.cbor")
	testing.expect_value(t, capi.stury_format_of_path(p, n), u32(engine.Format_Id.Cbor))
	p, n = c_slice("config.yml")
	testing.expect_value(t, capi.stury_format_of_path(p, n), u32(engine.Format_Id.Yaml))
	p, n = c_slice("index.html")
	testing.expect_value(t, capi.stury_format_of_path(p, n), u32(engine.Format_Id.Html))
	p, n = c_slice("data.mpk")
	testing.expect_value(t, capi.stury_format_of_path(p, n), u32(engine.Format_Id.Msgpack))
	p, n = c_slice("noext")
	testing.expect_value(t, capi.stury_format_of_path(p, n), capi.FORMAT_UNKNOWN)

	// Format detection.
	p, n = c_slice(`{"hello":1}`)
	testing.expect_value(t, capi.stury_format_detect(p, n), u32(engine.Format_Id.Json))
	p, n = c_slice(`<r><a/></r>`)
	testing.expect_value(t, capi.stury_format_detect(p, n), u32(engine.Format_Id.Xml))
	cbor_bytes := [?]u8{0xA1, 0x61, 'k', 0x05}
	testing.expect_value(t, capi.stury_format_detect(&cbor_bytes[0], len(cbor_bytes)), u32(engine.Format_Id.Cbor))
	p, n = c_slice("---\nname: ada\n")
	testing.expect_value(t, capi.stury_format_detect(p, n), u32(engine.Format_Id.Yaml))
	p, n = c_slice("<!DOCTYPE html><html><body><p>ok</p></body></html>")
	testing.expect_value(t, capi.stury_format_detect(p, n), u32(engine.Format_Id.Html))
	mp_sample := [?]u8{0x81, 0xA1, 'k', 0x05}
	testing.expect_value(t, capi.stury_format_detect(&mp_sample[0], len(mp_sample)), u32(engine.Format_Id.Msgpack))

	// Capabilities & facts bitmasks.
	cbor_caps := capi.stury_format_caps(u32(engine.Format_Id.Cbor))
	testing.expect(t, cbor_caps & (u32(1) << u32(tape.Cap.Binary)) != 0)
	testing.expect(t, capi.stury_format_caps(u32(engine.Format_Id.Msgpack)) & (u32(1) << u32(tape.Cap.Binary)) != 0)
	xml_facts := capi.stury_format_facts(u32(engine.Format_Id.Xml))
	testing.expect(t, xml_facts & (u16(1) << u16(tape.Fact_Kind.Attribute)) != 0)
	testing.expect(t, capi.stury_format_facts(u32(engine.Format_Id.Html)) & (u16(1) << u16(tape.Fact_Kind.Attribute)) != 0)
	testing.expect(t, capi.stury_format_facts(u32(engine.Format_Id.Yaml)) & (u16(1) << u16(tape.Fact_Kind.Comment)) != 0)
	json_facts := capi.stury_format_facts(u32(engine.Format_Id.Json))
	testing.expect_value(t, json_facts, u16(0))
	testing.expect_value(t, capi.stury_format_caps(capi.FORMAT_UNKNOWN), u32(0))
	testing.expect_value(t, capi.stury_format_facts(capi.FORMAT_UNKNOWN), u16(0))
}

@(test)
capi_build_write_convert_and_dropped_facts :: proc(t: ^testing.T) {
	testkit.deadline(t)

	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	defer capi.stury_arena_free(a)

	// Validate + build + inspect + write JSONC -> JSON (reports dropped comments).
	jc := "// header\n{\"a\":1}\n"
	jp, jn := c_slice(jc)
	verr := capi.stury_validate(a, jp, jn, u32(engine.Format_Id.Jsonc), nil)
	testing.expect_value(t, verr.code, capi.Err_Code.Ok)

	doc: ^tape.Document
	berr := capi.stury_build(a, jp, jn, u32(engine.Format_Id.Jsonc), nil, &doc)
	testing.expect_value(t, berr.code, capi.Err_Code.Ok)
	testing.expect(t, doc != nil)
	testing.expect(t, capi.stury_doc_node_count(doc) > 0)
	testing.expect(t, capi.stury_doc_facts(doc) & (u16(1) << u16(tape.Fact_Kind.Comment)) != 0)

	out_p: [^]u8
	out_n: c.size_t
	dropped: u16
	werr := capi.stury_write(a, doc, u32(engine.Format_Id.Json), &out_p, &out_n, &dropped)
	testing.expect_value(t, werr.code, capi.Err_Code.Ok)
	testing.expect_value(t, string(out_p[:out_n]), `{"a":1}`)
	testing.expect(t, dropped & (u16(1) << u16(tape.Fact_Kind.Comment)) != 0)
	capi.stury_doc_free(doc)

	// Reset arena and convert TOML (with comments) -> JSON (reports dropped comments) and JSON -> CBOR -> JSON.
	capi.stury_arena_reset(a)
	toml_txt := "# top\na = 10\nb = \"hi\"\n"
	tp, tn := c_slice(toml_txt)
	cerr := capi.stury_convert(a, tp, tn, u32(engine.Format_Id.Toml_1_0), u32(engine.Format_Id.Json), nil, &out_p, &out_n, &dropped)
	testing.expect_value(t, cerr.code, capi.Err_Code.Ok)
	testing.expect_value(t, string(out_p[:out_n]), `{"a":10,"b":"hi"}`)
	testing.expect(t, dropped & (u16(1) << u16(tape.Fact_Kind.Comment)) != 0)

	cbor_p: [^]u8
	cbor_n: c.size_t
	cerr2 := capi.stury_convert(a, out_p, out_n, u32(engine.Format_Id.Json), u32(engine.Format_Id.Cbor), nil, &cbor_p, &cbor_n, nil)
	testing.expect_value(t, cerr2.code, capi.Err_Code.Ok)
	testing.expect(t, cbor_n > 0)

	back_p: [^]u8
	back_n: c.size_t
	cerr3 := capi.stury_convert(a, cbor_p, cbor_n, u32(engine.Format_Id.Cbor), u32(engine.Format_Id.Json), nil, &back_p, &back_n, nil)
	testing.expect_value(t, cerr3.code, capi.Err_Code.Ok)
	testing.expect_value(t, string(back_p[:back_n]), `{"a":10,"b":"hi"}`)

	// Syntax error produces `.Syntax` + exact offset + non-null arena message.
	bad := `{"a": }`
	bp, bn := c_slice(bad)
	serr := capi.stury_validate(a, bp, bn, u32(engine.Format_Id.Json), nil)
	testing.expect_value(t, serr.code, capi.Err_Code.Syntax)
	testing.expect(t, serr.at != tape.NO_BYTE)
	testing.expect(t, serr.message != nil && len(serr.message) > 0)

	// YAML validate + convert -> JSON (dropped `.Comment`) -> MessagePack_Compact -> JSON, and HTML validate + convert -> JSON.
	yml := "# hdr\nname: ada\nage: 36\n"
	yp, yn := c_slice(yml)
	testing.expect_value(t, capi.stury_validate(a, yp, yn, u32(engine.Format_Id.Yaml), nil).code, capi.Err_Code.Ok)
	testing.expect_value(t, capi.stury_convert(a, yp, yn, u32(engine.Format_Id.Yaml), u32(engine.Format_Id.Json), nil, &out_p, &out_n, &dropped).code, capi.Err_Code.Ok)
	testing.expect_value(t, string(out_p[:out_n]), `{"name":"ada","age":36}`)
	testing.expect(t, dropped & (u16(1) << u16(tape.Fact_Kind.Comment)) != 0)

	mp_p: [^]u8
	mp_n: c.size_t
	testing.expect_value(t, capi.stury_convert(a, out_p, out_n, u32(engine.Format_Id.Json), u32(engine.Format_Id.Msgpack_Compact), nil, &mp_p, &mp_n, nil).code, capi.Err_Code.Ok)
	testing.expect(t, mp_n > 0)
	testing.expect_value(t, capi.stury_validate(a, mp_p, mp_n, u32(engine.Format_Id.Msgpack_Compact), nil).code, capi.Err_Code.Ok)
	testing.expect_value(t, capi.stury_convert(a, mp_p, mp_n, u32(engine.Format_Id.Msgpack), u32(engine.Format_Id.Json), nil, &back_p, &back_n, nil).code, capi.Err_Code.Ok)
	testing.expect_value(t, string(back_p[:back_n]), `{"name":"ada","age":36}`)

	html_src := `<!DOCTYPE html><html><body><p>ada</p></body></html>`
	hp, hn := c_slice(html_src)
	testing.expect_value(t, capi.stury_validate(a, hp, hn, u32(engine.Format_Id.Html), nil).code, capi.Err_Code.Ok)
	h_out_p: [^]u8
	h_out_n: c.size_t
	testing.expect_value(t, capi.stury_convert(a, hp, hn, u32(engine.Format_Id.Html), u32(engine.Format_Id.Json), nil, &h_out_p, &h_out_n, nil).code, capi.Err_Code.Ok)
	testing.expect(t, strings.contains(string(h_out_p[:h_out_n]), `"ada"`))
}

@(test)
capi_schema_compile_and_streaming_check :: proc(t: ^testing.T) {
	testkit.deadline(t)

	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	defer capi.stury_arena_free(a)

	schema_src := `{"type":"object","required":["name","age"],"properties":{"name":{"type":"string","minLength":1},"age":{"type":"integer","minimum":0}}}`
	sp, sn := c_slice(schema_src)
	sc: ^schema_pkg.Compiled
	cerr := capi.stury_schema_compile(a, sp, sn, &sc)
	testing.expect_value(t, cerr.code, capi.Err_Code.Ok)
	testing.expect(t, sc != nil)
	defer capi.stury_schema_free(sc)

	valid: bool
	jp, jn := c_slice(`{"name":"ada","age":36}`)
	e1 := capi.stury_schema_check(a, sc, jp, jn, u32(engine.Format_Id.Json), nil, &valid)
	testing.expect_value(t, e1.code, capi.Err_Code.Ok)
	testing.expect(t, valid)

	tp, tn := c_slice("name = \"ada\"\nage = 36\n")
	e2 := capi.stury_schema_check(a, sc, tp, tn, u32(engine.Format_Id.Toml_1_0), nil, &valid)
	testing.expect_value(t, e2.code, capi.Err_Code.Ok)
	testing.expect(t, valid)

	cbor_ok := [?]u8{0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x63, 'a', 'g', 'e', 0x18, 36}
	e3 := capi.stury_schema_check(a, sc, &cbor_ok[0], len(cbor_ok), u32(engine.Format_Id.Cbor), nil, &valid)
	testing.expect_value(t, e3.code, capi.Err_Code.Ok)
	testing.expect(t, valid)

	// Invalid against schema -> `.Schema_Invalid`.
	bad_p, bad_n := c_slice(`{"name":"ada","age":-5}`)
	e4 := capi.stury_schema_check(a, sc, bad_p, bad_n, u32(engine.Format_Id.Json), nil, &valid)
	testing.expect_value(t, e4.code, capi.Err_Code.Schema_Invalid)
	testing.expect(t, !valid)
	testing.expect(t, e4.message != nil)

	// Malformed schema fails cleanly without leaks.
	bad_sc: ^schema_pkg.Compiled
	bsp, bsn := c_slice(`{not valid json`)
	e5 := capi.stury_schema_compile(a, bsp, bsn, &bad_sc)
	testing.expect_value(t, e5.code, capi.Err_Code.Syntax)
	testing.expect(t, bad_sc == nil)
}

@(test)
capi_overlay_edit_and_commit :: proc(t: ^testing.T) {
	testkit.deadline(t)

	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	defer capi.stury_arena_free(a)

	src := "{\n  // keep comment\n  \"user\": {\"name\": \"old\", \"count\": 1},\n  \"items\": [10, 20, 30],\n  \"drop\": true,\n  \"a/b\": \"orig\"\n}\n"
	sp, sn := c_slice(src)
	doc: ^tape.Document
	berr := capi.stury_build(a, sp, sn, u32(engine.Format_Id.Jsonc), nil, &doc)
	testing.expect_value(t, berr.code, capi.Err_Code.Ok)
	defer capi.stury_doc_free(doc)

	ov: ^edit.Overlay
	oerr := capi.stury_overlay_new(a, doc, &ov)
	testing.expect_value(t, oerr.code, capi.Err_Code.Ok)
	defer capi.stury_overlay_free(ov)

	// set_string, set_int, set_raw (on array element), RFC 6901 escaped key (~1 -> '/'), del_path.
	p1, n1 := c_slice("/user/name")
	v1, vn1 := c_slice("ada")
	testing.expect_value(t, capi.stury_overlay_set_string(a, ov, p1, n1, v1, vn1).code, capi.Err_Code.Ok)

	p2, n2 := c_slice("/user/count")
	testing.expect_value(t, capi.stury_overlay_set_int(a, ov, p2, n2, 99).code, capi.Err_Code.Ok)

	p3, n3 := c_slice("/items/1")
	v3, vn3 := c_slice("[1,2]")
	testing.expect_value(t, capi.stury_overlay_set_raw(a, ov, p3, n3, v3, vn3).code, capi.Err_Code.Ok)

	p4, n4 := c_slice("/a~1b")
	v4, vn4 := c_slice("escaped")
	testing.expect_value(t, capi.stury_overlay_set_string(a, ov, p4, n4, v4, vn4).code, capi.Err_Code.Ok)

	p5, n5 := c_slice("/drop")
	testing.expect_value(t, capi.stury_overlay_del_path(a, ov, p5, n5).code, capi.Err_Code.Ok)

	out_p: [^]u8
	out_n: c.size_t
	dropped: u16
	cm_err := capi.stury_overlay_commit(a, ov, capi.FORMAT_UNKNOWN, false, &out_p, &out_n, &dropped)
	testing.expect_value(t, cm_err.code, capi.Err_Code.Ok)
	res_str := string(out_p[:out_n])
	testing.expect(t, strings.contains(res_str, "// keep comment"))
	testing.expect(t, strings.contains(res_str, `"ada"`))
	testing.expect(t, strings.contains(res_str, "99"))
	testing.expect(t, strings.contains(res_str, "[1,2]"))
	testing.expect(t, strings.contains(res_str, `"escaped"`))
	testing.expect(t, !strings.contains(res_str, `"drop"`))

	// Invalid JSON Pointer (missing leading '/') returns `.Invalid_Arg`.
	bad_p, bad_n := c_slice("user/name")
	testing.expect_value(t, capi.stury_overlay_set_int(a, ov, bad_p, bad_n, 1).code, capi.Err_Code.Invalid_Arg)
}

@(private = "file")
C_Emit_Collector :: struct {
	ctx:    runtime.Context,
	values: [dynamic]string,
	paths:  [dynamic]string,
	limit:  int,
}

@(private = "file")
c_jq_cb :: proc "c" (ctx: rawptr, b: [^]u8, n: c.size_t) -> bool {
	col := (^C_Emit_Collector)(ctx)
	context = col.ctx
	append(&col.values, strings.clone(string(b[:int(n)])))
	return col.limit <= 0 || len(col.values) < col.limit
}

@(private = "file")
c_jp_cb :: proc "c" (ctx: rawptr, b: [^]u8, n: c.size_t, np: [^]u8, np_n: c.size_t) -> bool {
	col := (^C_Emit_Collector)(ctx)
	context = col.ctx
	append(&col.values, strings.clone(string(b[:int(n)])))
	if np != nil && np_n > 0 {
		append(&col.paths, strings.clone(string(np[:int(np_n)])))
	}
	return col.limit <= 0 || len(col.values) < col.limit
}

@(private = "file")
free_c_collector :: proc(col: ^C_Emit_Collector) {
	for v in col.values {
		delete(v)
	}
	delete(col.values)
	for p in col.paths {
		delete(p)
	}
	delete(col.paths)
}

@(test)
capi_jq_and_jsonpath_eval :: proc(t: ^testing.T) {
	testkit.deadline(t)

	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	defer capi.stury_arena_free(a)

	// jq compile + eval over JSON and TOML + early stop.
	jq_src := ".items[]"
	qp, qn := c_slice(jq_src)
	jqp: ^stury.Jq_Program
	testing.expect_value(t, capi.stury_jq_compile(a, qp, qn, &jqp).code, capi.Err_Code.Ok)
	defer capi.stury_jq_free(jqp)

	in_json := `{"items":[10,20,30]}`
	ip, in_len := c_slice(in_json)
	col := C_Emit_Collector{ctx = context}
	defer free_c_collector(&col)
	e1 := capi.stury_jq_eval(a, jqp, ip, in_len, u32(engine.Format_Id.Json), nil, c_jq_cb, &col)
	testing.expect_value(t, e1.code, capi.Err_Code.Ok)
	testing.expect_value(t, len(col.values), 3)
	testing.expect_value(t, col.values[0], "10")
	testing.expect_value(t, col.values[2], "30")

	// Early stop from callback yields `.Stopped`.
	stop_col := C_Emit_Collector{ctx = context, limit = 1}
	defer free_c_collector(&stop_col)
	e2 := capi.stury_jq_eval(a, jqp, ip, in_len, u32(engine.Format_Id.Json), nil, c_jq_cb, &stop_col)
	testing.expect_value(t, e2.code, capi.Err_Code.Stopped)
	testing.expect_value(t, len(stop_col.values), 1)

	// jq compile error yields `.Syntax` with arena message.
	bad_jqp: ^stury.Jq_Program
	bqp, bqn := c_slice(".a +")
	be := capi.stury_jq_compile(a, bqp, bqn, &bad_jqp)
	testing.expect_value(t, be.code, capi.Err_Code.Syntax)
	testing.expect(t, bad_jqp == nil && be.message != nil)

	// JSONPath compile + eval with normalized paths over TOML.
	jp_src := "$.items[*]"
	jpp, jpn := c_slice(jp_src)
	prog: ^stury.Jsonpath_Program
	testing.expect_value(t, capi.stury_jsonpath_compile(a, jpp, jpn, &prog).code, capi.Err_Code.Ok)
	defer capi.stury_jsonpath_free(prog)

	in_toml := "items = [10, 20, 30]\n"
	tp, tn := c_slice(in_toml)
	jp_col := C_Emit_Collector{ctx = context}
	defer free_c_collector(&jp_col)
	je1 := capi.stury_jsonpath_eval(a, prog, tp, tn, u32(engine.Format_Id.Toml_1_0), nil, true, c_jp_cb, &jp_col)
	testing.expect_value(t, je1.code, capi.Err_Code.Ok)
	testing.expect_value(t, len(jp_col.values), 3)
	testing.expect_value(t, jp_col.values[1], "20")
	testing.expect_value(t, len(jp_col.paths), 3)
	testing.expect_value(t, jp_col.paths[1], "$['items'][1]")

	// JSONPath early stop yields `.Stopped`.
	jp_stop := C_Emit_Collector{ctx = context, limit = 2}
	defer free_c_collector(&jp_stop)
	je2 := capi.stury_jsonpath_eval(a, prog, tp, tn, u32(engine.Format_Id.Toml_1_0), nil, false, c_jp_cb, &jp_stop)
	testing.expect_value(t, je2.code, capi.Err_Code.Stopped)
	testing.expect_value(t, len(jp_stop.values), 2)
	testing.expect_value(t, len(jp_stop.paths), 0)

	// JSONPath compile error yields `.Syntax`.
	bad_jp: ^stury.Jsonpath_Program
	bjpp, bjpn := c_slice("not_starting_with_dollar")
	jbe := capi.stury_jsonpath_compile(a, bjpp, bjpn, &bad_jp)
	testing.expect_value(t, jbe.code, capi.Err_Code.Syntax)
	testing.expect(t, bad_jp == nil && jbe.message != nil)

	// jq query over YAML and MessagePack.
	np, nn := c_slice(".name")
	name_jqp: ^stury.Jq_Program
	testing.expect_value(t, capi.stury_jq_compile(a, np, nn, &name_jqp).code, capi.Err_Code.Ok)
	defer capi.stury_jq_free(name_jqp)

	yp, yn := c_slice("# hdr\nname: ada\nage: 36\n")
	col_y := C_Emit_Collector{ctx = context}
	defer free_c_collector(&col_y)
	testing.expect_value(t, capi.stury_jq_eval(a, name_jqp, yp, yn, u32(engine.Format_Id.Yaml), nil, c_jq_cb, &col_y).code, capi.Err_Code.Ok)
	testing.expect_value(t, len(col_y.values), 1)
	testing.expect_value(t, col_y.values[0], `"ada"`)

	mp_p: [^]u8
	mp_n: c.size_t
	testing.expect_value(t, capi.stury_convert(a, yp, yn, u32(engine.Format_Id.Yaml), u32(engine.Format_Id.Msgpack_Compact), nil, &mp_p, &mp_n, nil).code, capi.Err_Code.Ok)
	col_m := C_Emit_Collector{ctx = context}
	defer free_c_collector(&col_m)
	testing.expect_value(t, capi.stury_jq_eval(a, name_jqp, mp_p, mp_n, u32(engine.Format_Id.Msgpack), nil, c_jq_cb, &col_m).code, capi.Err_Code.Ok)
	testing.expect_value(t, len(col_m.values), 1)
	testing.expect_value(t, col_m.values[0], `"ada"`)
}

@(test)
capi_null_pointer_overflow_and_budget_safety :: proc(t: ^testing.T) {
	testkit.deadline(t)

	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	defer capi.stury_arena_free(a)

	// All free/reset functions are safe on NULL.
	capi.stury_arena_reset(nil)
	capi.stury_arena_free(nil)
	capi.stury_doc_free(nil)
	capi.stury_schema_free(nil)
	capi.stury_overlay_free(nil)
	capi.stury_jq_free(nil)
	capi.stury_jsonpath_free(nil)

	// Format & doc accessors on NULL / overflow length.
	huge := ~c.size_t(0)
	testing.expect_value(t, capi.stury_format_by_name(nil, 4), capi.FORMAT_UNKNOWN)
	testing.expect_value(t, capi.stury_format_by_name(nil, huge), capi.FORMAT_UNKNOWN)
	testing.expect_value(t, capi.stury_format_of_path(nil, 4), capi.FORMAT_UNKNOWN)
	testing.expect_value(t, capi.stury_format_detect(nil, 4), capi.FORMAT_UNKNOWN)
	testing.expect_value(t, capi.stury_doc_facts(nil), u16(0))
	testing.expect_value(t, capi.stury_doc_node_count(nil), c.size_t(0))

	// NULL pointers & overflow lengths return `.Invalid_Arg`; `stury_build(nil, ...)` allows NULL error arena.
	doc: ^tape.Document
	out_p: [^]u8
	out_n: c.size_t
	jp, jn := c_slice(`{"a":1}`)
	testing.expect_value(t, capi.stury_build(nil, jp, jn, u32(engine.Format_Id.Json), nil, &doc).code, capi.Err_Code.Ok)
	testing.expect(t, doc != nil)
	capi.stury_doc_free(doc)
	doc = nil
	testing.expect_value(t, capi.stury_build(a, jp, jn, u32(engine.Format_Id.Json), nil, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_build(a, nil, 5, u32(engine.Format_Id.Json), nil, &doc).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_build(a, jp, huge, u32(engine.Format_Id.Json), nil, &doc).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_build(a, jp, jn, capi.FORMAT_UNKNOWN, nil, &doc).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_write(nil, nil, u32(engine.Format_Id.Json), &out_p, &out_n, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_write(a, nil, u32(engine.Format_Id.Json), &out_p, &out_n, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_convert(nil, jp, jn, u32(engine.Format_Id.Json), u32(engine.Format_Id.Toml_1_0), nil, &out_p, &out_n, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_schema_compile(a, jp, jn, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_schema_check(a, nil, jp, jn, u32(engine.Format_Id.Json), nil, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_overlay_new(a, nil, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_overlay_set_int(a, nil, nil, 0, 1).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_overlay_del_path(a, nil, nil, 0).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_overlay_commit(nil, nil, capi.FORMAT_UNKNOWN, false, &out_p, &out_n, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_overlay_commit(a, nil, capi.FORMAT_UNKNOWN, false, &out_p, &out_n, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_jq_compile(a, jp, jn, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_jq_eval(a, nil, jp, jn, u32(engine.Format_Id.Json), nil, nil, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_jsonpath_compile(a, jp, jn, nil).code, capi.Err_Code.Invalid_Arg)
	testing.expect_value(t, capi.stury_jsonpath_eval(a, nil, jp, jn, u32(engine.Format_Id.Json), nil, false, nil, nil).code, capi.Err_Code.Invalid_Arg)

	// Budget enforcement: depth, nodes, and steps return `.Budget`.
	nested := `[[[[1]]]]`
	np, nn := c_slice(nested)
	depth_b := capi.Budget{depth = 2}
	testing.expect_value(t, capi.stury_validate(a, np, nn, u32(engine.Format_Id.Json), &depth_b).code, capi.Err_Code.Budget)

	nodes_b := capi.Budget{nodes = 2}
	testing.expect_value(t, capi.stury_build(a, np, nn, u32(engine.Format_Id.Json), &nodes_b, &doc).code, capi.Err_Code.Budget)
	testing.expect(t, doc == nil)

	// Step budget in jq evaluator.
	loop_p, loop_n := c_slice("range(10000)")
	jqp: ^stury.Jq_Program
	testing.expect_value(t, capi.stury_jq_compile(a, loop_p, loop_n, &jqp).code, capi.Err_Code.Ok)
	defer capi.stury_jq_free(jqp)
	steps_b := capi.Budget{steps = 5}
	nul_p, nul_n := c_slice("null")
	testing.expect_value(t, capi.stury_jq_eval(a, jqp, nul_p, nul_n, u32(engine.Format_Id.Json), &steps_b, nil, nil).code, capi.Err_Code.Budget)

	// Finding #5: Evaluator memory budget returns `.Budget` (not `.No_Memory`) in both jq and JSONPath.
	grow_p, grow_n := c_slice("[range(500)]")
	grow_prog: ^stury.Jq_Program
	testing.expect_value(t, capi.stury_jq_compile(a, grow_p, grow_n, &grow_prog).code, capi.Err_Code.Ok)
	defer capi.stury_jq_free(grow_prog)
	mem_b := capi.Budget{memory = 512}
	testing.expect_value(t, capi.stury_jq_eval(a, grow_prog, nul_p, nul_n, u32(engine.Format_Id.Json), &mem_b, nil, nil).code, capi.Err_Code.Budget)

	jp_all_p, jp_all_n := c_slice("$.a")
	jp_prog: ^stury.Jsonpath_Program
	testing.expect_value(t, capi.stury_jsonpath_compile(a, jp_all_p, jp_all_n, &jp_prog).code, capi.Err_Code.Ok)
	defer capi.stury_jsonpath_free(jp_prog)
	tiny_mem := capi.Budget{memory = 16}
	testing.expect_value(t, capi.stury_jsonpath_eval(a, jp_prog, jp, jn, u32(engine.Format_Id.Json), &tiny_mem, false, nil, nil).code, capi.Err_Code.Budget)

	// Finding #6: `stury_schema_check` budget exhaustion returns `.Budget`.
	sc_p, sc_n := c_slice(`{"type":"array"}`)
	sc: ^schema_pkg.Compiled
	testing.expect_value(t, capi.stury_schema_compile(a, sc_p, sc_n, &sc).code, capi.Err_Code.Ok)
	defer capi.stury_schema_free(sc)
	arr_p, arr_n := c_slice(`[[[1]]]`)
	sc_steps := capi.Budget{steps = 1}
	sc_valid := true
	sc_err := capi.stury_schema_check(a, sc, arr_p, arr_n, u32(engine.Format_Id.Json), &sc_steps, &sc_valid)
	testing.expect_value(t, sc_err.code, capi.Err_Code.Budget)
	testing.expect(t, !sc_valid)

	// Finding #11: jq `halt` maps to `.Halted` (distinct from callback `.Stopped`).
	halt_p, halt_n := c_slice("halt")
	halt_prog: ^stury.Jq_Program
	testing.expect_value(t, capi.stury_jq_compile(a, halt_p, halt_n, &halt_prog).code, capi.Err_Code.Ok)
	defer capi.stury_jq_free(halt_prog)
	testing.expect_value(t, capi.stury_jq_eval(a, halt_prog, nul_p, nul_n, u32(engine.Format_Id.Json), nil, nil, nil).code, capi.Err_Code.Halted)
}

@(test)
capi_doc_survives_arena_reset_across_overlay_commits :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Finding #1 regression: `stury_doc_t` is independently owned (freed by `stury_doc_free`),
	// so `stury_arena_reset(a)` between build, overlay creation, and multiple commits never dangles `ov.base` or UAFs.
	a := capi.stury_arena_new()
	testing.expect(t, a != nil)
	defer capi.stury_arena_free(a)

	src := "{\n  // header\n  \"k\": 1\n}\n"
	sp, sn := c_slice(src)
	doc: ^tape.Document
	testing.expect_value(t, capi.stury_build(a, sp, sn, u32(engine.Format_Id.Jsonc), nil, &doc).code, capi.Err_Code.Ok)
	testing.expect(t, doc != nil)

	// Resetting arena immediately after build leaves `doc` 100% intact.
	capi.stury_arena_reset(a)
	testing.expect(t, capi.stury_doc_node_count(doc) > 0)

	ov: ^edit.Overlay
	testing.expect_value(t, capi.stury_overlay_new(a, doc, &ov).code, capi.Err_Code.Ok)
	pk, pk_n := c_slice("/k")
	testing.expect_value(t, capi.stury_overlay_set_int(a, ov, pk, pk_n, 2).code, capi.Err_Code.Ok)

	capi.stury_arena_reset(a)
	out1: [^]u8
	len1: c.size_t
	testing.expect_value(t, capi.stury_overlay_commit(a, ov, capi.FORMAT_UNKNOWN, false, &out1, &len1, nil).code, capi.Err_Code.Ok)
	testing.expect(t, strings.contains(string(out1[:len1]), "// header"))
	testing.expect(t, strings.contains(string(out1[:len1]), "2"))

	// Mutate again, reset arena again, commit again, then free overlay & doc cleanly.
	testing.expect_value(t, capi.stury_overlay_set_int(a, ov, pk, pk_n, 3).code, capi.Err_Code.Ok)
	capi.stury_arena_reset(a)
	out2: [^]u8
	len2: c.size_t
	testing.expect_value(t, capi.stury_overlay_commit(a, ov, capi.FORMAT_UNKNOWN, false, &out2, &len2, nil).code, capi.Err_Code.Ok)
	testing.expect(t, strings.contains(string(out2[:len2]), "3"))

	capi.stury_overlay_free(ov)
	capi.stury_arena_reset(a)
	capi.stury_doc_free(doc)
}
