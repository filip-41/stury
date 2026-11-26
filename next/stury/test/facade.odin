package stury_tests

import "base:runtime"
import "core:bytes"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
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

	e, ok := stury.format_by_name("json")
	testing.expect(t, ok && e.id == .Json)
	e, ok = stury.format_by_name("TOML")
	testing.expect(t, ok && e.id == .Toml_1_0)
	e, ok = stury.format_by_name("xml")
	testing.expect(t, ok && e.id == .Xml)
	e, ok = stury.format_by_name("csv")
	testing.expect(t, ok && e.id == .Csv)
	e, ok = stury.format_by_name("cbor")
	testing.expect(t, ok && e.id == .Cbor)
	_, ok = stury.format_by_name("nonexistent")
	testing.expect(t, !ok)

	ep, fr, pok := stury.format_of_path("/tmp/data.json.gz")
	testing.expect(t, pok && ep.id == .Json && fr == .Single)
	ep, fr, pok = stury.format_of_path("logs.ndjson.zst")
	testing.expect(t, pok && ep.id == .Json && fr == .Lines)
	ep, _, pok = stury.format_of_path("config.toml")
	testing.expect(t, pok && ep.id == .Toml_1_0)
	ep, _, pok = stury.format_of_path("feed.xml")
	testing.expect(t, pok && ep.id == .Xml)
	ep, _, pok = stury.format_of_path("table.csv")
	testing.expect(t, pok && ep.id == .Csv)
	ep, _, pok = stury.format_of_path("blob.cbor")
	testing.expect(t, pok && ep.id == .Cbor)
	_, _, pok = stury.format_of_path("README")
	testing.expect(t, !pok)

	cbor_bytes := [?]u8{0xA1, 0x61, 'a', 0x01}
	ed, _, dok := stury.detect_format(transmute([]u8)string(`{"a":1}`))
	testing.expect(t, dok && ed.id == .Json)
	ed, _, dok = stury.detect_format(transmute([]u8)string("[user]\nname = \"ada\"\n"))
	testing.expect(t, dok && ed.id == .Toml_1_0)
	ed, _, dok = stury.detect_format(transmute([]u8)string(`<root><a>1</a></root>`))
	testing.expect(t, dok && ed.id == .Xml)
	ed, _, dok = stury.detect_format(transmute([]u8)string("id,name\n1,ada\n"))
	testing.expect(t, dok && ed.id == .Csv)
	ed, _, dok = stury.detect_format(cbor_bytes[:])
	testing.expect(t, dok && ed.id == .Cbor)
}

@(test)
universal_validate_build_find_scan_write_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","id":7}}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nid = 7\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name></user></root>`)
	csv_src := transmute([]u8)string("name,id\nada,7\n")
	cbor_src := [?]u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x62, 'i', 'd', 0x07}

	specs := [?]stury.Spec{
		json.Spec.Json,
		toml.Spec.Toml_1_0,
		xml.Spec.Xml,
		dsv.Spec.Csv,
		cbor.Spec.Cbor,
	}
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
		_, wterr := stury.write_to(bytes.buffer_to_stream(&buf), &docs[i], json.Spec.Json)
		testing.expect_value(t, wterr, stury.Write_Error(nil))
		testing.expect(t, bytes.buffer_length(&buf) > 0)
		bytes.buffer_destroy(&buf)
	}

	// `format_to` streaming conversion.
	fbuf: bytes.Buffer
	bytes.buffer_init_allocator(&fbuf, 0, 64)
	defer bytes.buffer_destroy(&fbuf)
	_, ferr := stury.format_to(bytes.buffer_to_stream(&fbuf), toml_src, toml.Spec.Toml_1_0, json.Spec.Json)
	testing.expect_value(t, ferr, stury.Format_Error(nil))
	testing.expect_value(t, bytes.buffer_to_string(&fbuf), `{"user":{"name":"ada","id":7}}`)

	// `find` and `scan` via universal facade.
	path := [?]stury.Step{stury.Name("user"), stury.Name("name")}
	ans, find_err := stury.find(cbor_src[:], path[:], cbor.Spec.Cbor)
	testing.expect_value(t, find_err, stury.Error(nil))
	testing.expect_value(t, ans.outcome, stury.Presence.Found)
	testing.expect_value(t, ans.kind, stury.Kind.String)

	paths := [?][]stury.Step{path[:]}
	dem, derr := stury.demand_of(paths[:])
	testing.expect_value(t, derr, nil)
	defer stury.destroy(&dem)

	sdoc, serr := stury.scan(json_src, &dem, json.Spec.Json)
	testing.expect_value(t, serr, stury.Error(nil))
	defer stury.destroy(&sdoc)
	node, pres, has := tape.answer(stury.Reader{doc = &sdoc}, 0, 0)
	testing.expect(t, has && pres == .Found)
	testing.expect_value(t, string(tape.span_bytes(&sdoc, sdoc.nodes[node].lo, sdoc.nodes[node].n)), "ada")
}

@(test)
doc_facts_comments_attributes_and_css :: proc(t: ^testing.T) {
	testkit.deadline(t)

	jsonc_src := transmute([]u8)string("// head comment\n{\"a\": 1 /* inline */}\n")
	toml_src := transmute([]u8)string("# toml header\na = 1 # tail\n")
	xml_src := transmute([]u8)string(`<lib><!-- shelf --><book id="b1" class="story featured" title="A &amp; B"><title>Ada</title></book><note/></lib>`)
	json_src := transmute([]u8)string(`{"a":1}`)

	jcdoc, jcerr := stury.build(jsonc_src, json.Spec.Jsonc)
	testing.expect_value(t, jcerr, stury.Error(nil))
	defer stury.destroy(&jcdoc)

	tdoc, terr := stury.build(toml_src, toml.Spec.Toml_1_0)
	testing.expect_value(t, terr, stury.Error(nil))
	defer stury.destroy(&tdoc)

	xdoc, xerr := stury.build(xml_src, xml.Spec.Xml)
	testing.expect_value(t, xerr, stury.Error(nil))
	defer stury.destroy(&xdoc)

	jdoc, jerr := stury.build(json_src, json.Spec.Json)
	testing.expect_value(t, jerr, stury.Error(nil))
	defer stury.destroy(&jdoc)

	// Facts belong to the document.
	testing.expect(t, stury.doc_facts(&jcdoc) & tape.COMMENTS != {})
	testing.expect(t, stury.doc_facts(&tdoc) & tape.COMMENTS != {})
	testing.expect(t, .Attribute in stury.doc_facts(&xdoc))
	testing.expect(t, stury.doc_facts(&xdoc) & tape.COMMENTS != {})
	testing.expect_value(t, stury.doc_facts(&jdoc), stury.Facts{})
	testing.expect_value(t, stury.doc_facts(nil), stury.Facts{})

	// `comments` works uniformly across all formats.
	jc_cs, c_err1 := stury.comments(&jcdoc)
	testing.expect_value(t, c_err1, nil)
	defer delete(jc_cs)
	testing.expect_value(t, len(jc_cs), 2)
	testing.expect_value(t, jc_cs[0].text, "head comment")
	testing.expect_value(t, jc_cs[1].text, "inline")

	t_cs, c_err2 := stury.comments(&tdoc)
	testing.expect_value(t, c_err2, nil)
	defer delete(t_cs)
	testing.expect_value(t, len(t_cs), 2)
	testing.expect_value(t, t_cs[0].text, "toml header")
	testing.expect_value(t, t_cs[1].text, "tail")

	x_cs, c_err3 := stury.comments(&xdoc)
	testing.expect_value(t, c_err3, nil)
	defer delete(x_cs)
	testing.expect_value(t, len(x_cs), 1)
	testing.expect_value(t, x_cs[0].text, "shelf")

	j_cs, c_err4 := stury.comments(&jdoc)
	testing.expect_value(t, c_err4, nil)
	testing.expect_value(t, len(j_cs), 0)

	// `css` selects on XML and cleanly returns ok=false on JSON/TOML or invalid selectors.
	hits, ok := stury.css(&xdoc, "book.story")
	testing.expect(t, ok)
	defer stury.destroy_css(&hits)
	testing.expect_value(t, len(hits.matches), 1)

	book_node := hits.matches[0].value
	attrs, aerr := stury.attributes(&xdoc, book_node)
	testing.expect_value(t, aerr, nil)
	defer stury.destroy_attributes(attrs)
	testing.expect_value(t, len(attrs), 3)
	testing.expect_value(t, attrs[0].name, "id")
	testing.expect_value(t, attrs[0].value, "b1")
	testing.expect_value(t, attrs[2].name, "title")
	testing.expect_value(t, attrs[2].value, "A & B")

	// Non-markup documents cleanly return empty attributes and `css` ok=false.
	no_attrs, naerr := stury.attributes(&jdoc, stury.ROOT)
	testing.expect_value(t, naerr, nil)
	testing.expect_value(t, len(no_attrs), 0)

	_, j_css_ok := stury.css(&jdoc, "book")
	testing.expect(t, !j_css_ok)
	_, t_css_ok := stury.css(&tdoc, "book")
	testing.expect(t, !t_css_ok)
	_, bad_css_ok := stury.css(&xdoc, "book[invalid=")
	testing.expect(t, !bad_css_ok)

	// Writing reports dropped facts accurately.
	out_json, dropped, werr := stury.write(&jcdoc, json.Spec.Json)
	testing.expect_value(t, werr, stury.Write_Error(nil))
	defer delete(out_json)
	testing.expect(t, dropped & tape.COMMENTS != {})
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
	testing.expect_value(t, len(dres.changes), 1)
	testing.expect_value(t, dres.changes[0].op, stury.Diff_Op.Changed)

	// `diff_documents` between identical JSON and CBOR yields zero changes.
	cbor_src := [?]u8{0xA2, 0x61, 'a', 0x01, 0x61, 'b', 0x63, 'o', 'l', 'd'}
	jdoc, jerr := stury.build(j_src, json.Spec.Json)
	testing.expect_value(t, jerr, stury.Error(nil))
	defer stury.destroy(&jdoc)
	cdoc, cerr := stury.build(cbor_src[:], cbor.Spec.Cbor)
	testing.expect_value(t, cerr, stury.Error(nil))
	defer stury.destroy(&cdoc)

	eq_res, eq_err := stury.diff_documents(&jdoc, &cdoc)
	testing.expect_value(t, eq_err, nil)
	defer stury.destroy_diff(&eq_res)
	testing.expect_value(t, len(eq_res.changes), 0)

	// `schema_compile` + `check_schema` across JSON, TOML, CBOR.
	schema_json := transmute([]u8)string(`{"type":"object","required":["a","b"],"properties":{"a":{"type":"integer","minimum":1},"b":{"type":"string"}}}`)
	sc, scerr := stury.schema_compile(schema_json)
	testing.expect_value(t, scerr.kind, .None)
	defer stury.schema_destroy(sc)

	r1 := stury.check_schema(j_src, json.Spec.Json, sc)
	defer stury.destroy_check_result(&r1)
	testing.expect(t, r1.valid)

	r2 := stury.check_schema(t_src, toml.Spec.Toml_1_0, sc)
	defer stury.destroy_check_result(&r2)
	testing.expect(t, r2.valid)

	r3 := stury.check_schema(cbor_src[:], cbor.Spec.Cbor, &sc.plan)
	defer stury.destroy_check_result(&r3)
	testing.expect(t, r3.valid)

	rdoc := stury.check_document(&jdoc, sc)
	defer stury.destroy_check_result(&rdoc)
	testing.expect(t, rdoc.valid)

	bad_json := transmute([]u8)string(`{"a":0,"b":"ok"}`)
	r4 := stury.check_schema(bad_json, json.Spec.Json, sc)
	defer stury.destroy_check_result(&r4)
	testing.expect(t, !r4.valid)

	// `edit_init` / `set_path` / `commit` preserving JSONC comments via `stury` facade alone.
	jc_src := transmute([]u8)string("{\n  // keep me\n  \"a\": 1,\n  \"b\": \"old\"\n}\n")
	jc_doc, jce := stury.build(jc_src, json.Spec.Jsonc)
	testing.expect_value(t, jce, stury.Error(nil))
	defer stury.destroy(&jc_doc)

	ov: stury.Overlay
	testing.expect_value(t, stury.edit_init(&ov, &jc_doc), stury.Edit_Error(nil))
	defer stury.edit_destroy(&ov)

	step_a := [?]stury.Step{stury.Name("a")}
	_, sp_err := stury.set_path(&ov, step_a[:], stury.val_int(42))
	testing.expect_value(t, sp_err, stury.Edit_Error(nil))

	cres, cm_err := stury.commit(&ov)
	testing.expect_value(t, cm_err, stury.Edit_Error(nil))
	defer stury.destroy_commit_result(&cres)
	testing.expect(t, strings.contains(string(cres.bytes), "// keep me"))
	testing.expect(t, strings.contains(string(cres.bytes), "42"))

	// `commit_document` incremental tape splicing on XML.
	x_doc, x_berr := stury.build(transmute([]u8)string(`<r><a>1</a><b>2</b></r>`), xml.Spec.Xml)
	testing.expect_value(t, x_berr, stury.Error(nil))
	defer stury.destroy(&x_doc)

	x_ov: stury.Overlay
	testing.expect_value(t, stury.edit_init(&x_ov, &x_doc), stury.Edit_Error(nil))
	defer stury.edit_destroy(&x_ov)
	step_b := [?]stury.Step{stury.Name("r"), stury.Name("b")}
	_, xsp_err := stury.set_path(&x_ov, step_b[:], stury.val_string("9"))
	testing.expect_value(t, xsp_err, stury.Edit_Error(nil))

	spliced_doc, sres, sc_err := stury.commit_document(&x_ov, xml.Spec.Xml)
	testing.expect_value(t, sc_err, stury.Edit_Error(nil))
	defer stury.destroy(&spliced_doc)
	defer stury.destroy_commit_result(&sres)
	testing.expect_value(t, string(sres.bytes), `<r><a>1</a><b>9</b></r>`)
	testing.expect(t, len(spliced_doc.nodes) > 0)
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

@(test)
query_jq_and_jsonpath_across_all_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)

	json_src := transmute([]u8)string(`{"user":{"name":"ada","score":99}}`)
	toml_src := transmute([]u8)string("[user]\nname = \"ada\"\nscore = 99\n")
	xml_src := transmute([]u8)string(`<root><user><name>ada</name></user></root>`)
	csv_src := transmute([]u8)string("name,score\nada,99\n")
	cbor_src := [?]u8{0xA1, 0x64, 'u', 's', 'e', 'r', 0xA2, 0x64, 'n', 'a', 'm', 'e', 0x63, 'a', 'd', 'a', 0x65, 's', 'c', 'o', 'r', 'e', 0x18, 99}

	// jq across JSON, TOML, CBOR.
	jq_prog, jq_errs := stury.jq_compile(".user.name")
	testing.expect_value(t, len(jq_errs), 0)
	defer stury.jq_destroy(jq_prog)

	for pair in ([?]struct { src: []u8, spec: stury.Spec }{
		{json_src, json.Spec.Json},
		{toml_src, toml.Spec.Toml_1_0},
		{cbor_src[:], cbor.Spec.Cbor},
	}) {
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jq_run(jq_prog, pair.src, pair.spec, collect_jq_out, &col)
		defer stury.jq_run_result_destroy(&res)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	// jq over XML with `css("name")` builtin.
	xml_prog, xerrs := stury.jq_compile(`css("name")`)
	testing.expect_value(t, len(xerrs), 0)
	defer stury.jq_destroy(xml_prog)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jq_run(xml_prog, xml_src, xml.Spec.Xml, collect_jq_out, &col)
		defer stury.jq_run_result_destroy(&res)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	// jq over CSV.
	csv_prog, cerrs := stury.jq_compile(".[0].name")
	testing.expect_value(t, len(cerrs), 0)
	defer stury.jq_destroy(csv_prog)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jq_run(csv_prog, csv_src, dsv.Spec.Csv, collect_jq_out, &col)
		defer stury.jq_run_result_destroy(&res)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	// JSONPath across JSON, TOML, CBOR with normalized paths.
	jp_prog, jperr := stury.jsonpath_compile("$.user.name")
	testing.expect_value(t, jperr.kind, .None)
	defer stury.jsonpath_destroy(jp_prog)

	for pair in ([?]struct { src: []u8, spec: stury.Spec }{
		{json_src, json.Spec.Json},
		{toml_src, toml.Spec.Toml_1_0},
		{cbor_src[:], cbor.Spec.Cbor},
	}) {
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_prog, pair.src, pair.spec, collect_jp_out, &col, {want_paths = true})
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
		testing.expect_value(t, len(col.paths), 1)
		testing.expect_value(t, col.paths[0], `$['user']['name']`)
	}

	// JSONPath over XML and CSV.
	jp_xml, jpxerr := stury.jsonpath_compile("$.root.user.name")
	testing.expect_value(t, jpxerr.kind, .None)
	defer stury.jsonpath_destroy(jp_xml)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_xml, xml_src, xml.Spec.Xml, collect_jp_out, &col)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	jp_csv, jpcerr := stury.jsonpath_compile("$[0].name")
	testing.expect_value(t, jpcerr.kind, .None)
	defer stury.jsonpath_destroy(jp_csv)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_csv, csv_src, dsv.Spec.Csv, collect_jp_out, &col)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	// RFC 9535 absent field emits zero values (not null).
	jp_miss, jpmerr := stury.jsonpath_compile("$.user.missing")
	testing.expect_value(t, jpmerr.kind, .None)
	defer stury.jsonpath_destroy(jp_miss)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_miss, json_src, json.Spec.Json, collect_jp_out, &col)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 0)
	}
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
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	c := (^Exact_Size_Checker)(allocator_data)
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
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
	case .Resize, .Resize_Non_Zeroed:
		if old_memory != nil {
			delete_key(&c.sizes, old_memory)
		}
		data, err := c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
		if err == nil && raw_data(data) != nil {
			c.sizes[raw_data(data)] = size
		}
		return data, err
	case .Free_All, .Query_Features, .Query_Info:
		return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
	}
	return nil, .Mode_Not_Implemented
}

@(test)
audit_regressions_facade :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Finding #4: `attributes` / `destroy_attributes` passes exact allocated size on delete when entities shrink text.
	xml_src := transmute([]u8)string(`<root><item title="A &amp; B &lt; C"/></root>`)
	xdoc, xerr := stury.build(xml_src, xml.Spec.Xml)
	testing.expect_value(t, xerr, stury.Error(nil))
	defer stury.destroy(&xdoc)

	hits, css_ok := stury.css(&xdoc, "item")
	testing.expect(t, css_ok && len(hits.matches) == 1)
	defer stury.destroy_css(&hits)

	checker := Exact_Size_Checker{
		backing = context.allocator,
		sizes   = make(map[rawptr]int),
	}
	defer delete(checker.sizes)
	checked_alloc := runtime.Allocator{procedure = exact_size_alloc_proc, data = &checker}

	attrs, aerr := stury.attributes(&xdoc, hits.matches[0].value, checked_alloc)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, len(attrs), 1)
	testing.expect_value(t, attrs[0].value, "A & B < C")
	stury.destroy_attributes(attrs, checked_alloc)
	testing.expect_value(t, checker.mismatch, 0)
	testing.expect_value(t, len(checker.sizes), 0)

	// Finding #2: `jsonpath_eval` routes through `engine`'s `Guard_Emit` (accurate `res.emitted` & early stop).
	jp_items, jpi_err := stury.jsonpath_compile("$.items[*]")
	testing.expect_value(t, jpi_err.kind, .None)
	defer stury.jsonpath_destroy(jp_items)

	items_json := transmute([]u8)string(`{"items":[10,20,30]}`)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_items, items_json, json.Spec.Json, collect_jp_out, &col, {want_paths = true})
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, res.emitted, u64(3))
		testing.expect_value(t, len(col.paths), 3)
		testing.expect_value(t, col.paths[2], "$['items'][2]")
	}
	{
		col := Query_Collector{limit = 2}
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_items, items_json, json.Spec.Json, collect_jp_out, &col, {want_paths = true})
		testing.expect_value(t, res.err, stury.Query_Error.Stopped)
		// `engine.Guard_Emit` counts emissions where the callback returned `true` (1st returns true, 2nd stops).
		testing.expect_value(t, res.emitted, u64(1))
		testing.expect_value(t, len(col.values), 2)
	}
	// Framed NDJSON early stop stops without replaying earlier records.
	ndjson := transmute([]u8)string("{\"items\":[1,2]}\n{\"items\":[3,4]}\n")
	{
		col := Query_Collector{limit = 2}
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_items, ndjson, json.Spec.Json, collect_jp_out, &col, {framing = .Lines})
		testing.expect_value(t, res.err, stury.Query_Error.Stopped)
		testing.expect_value(t, res.emitted, u64(1))
		testing.expect_value(t, len(col.values), 2)
		testing.expect_value(t, col.values[0], "1")
		testing.expect_value(t, col.values[1], "2")
	}

	// Finding #3 & #5: `jq_run` honors `read.budget.memory` on a `.Projection_Direct`-eligible query (`.a`)
	// and maps evaluator `budget.memory` exhaustion to `.Exceeded` (not `.No_Memory`).
	proj_prog, proj_errs := stury.jq_compile(".a")
	testing.expect_value(t, len(proj_errs), 0)
	defer stury.jq_destroy(proj_prog)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jq_run(proj_prog, transmute([]u8)string(`{"a":1}`), json.Spec.Json, collect_jq_out, &col, {
			read = {budget = {memory = 16}},
		})
		defer stury.jq_run_result_destroy(&res)
		testing.expect_value(t, res.err, stury.Query_Error.Exceeded)
	}
	// Finding #5 for jq evaluator heap growth (`[range(500)]` under tight `budget.memory`) -> `.Exceeded`.
	grow_prog, grow_errs := stury.jq_compile("[range(500)]")
	testing.expect_value(t, len(grow_errs), 0)
	defer stury.jq_destroy(grow_prog)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jq_run(grow_prog, transmute([]u8)string(`null`), json.Spec.Json, collect_jq_out, &col, {
			budget = {memory = 512},
		})
		defer stury.jq_run_result_destroy(&res)
		testing.expect_value(t, res.err, stury.Query_Error.Exceeded)
	}
	// Finding #5 for JSONPath evaluator memory budget -> `.Exceeded`.
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_items, items_json, json.Spec.Json, collect_jp_out, &col, {
			budget = {memory = 16},
		})
		testing.expect_value(t, res.err, stury.Query_Error.Exceeded)
	}
	// Finding #7: large `u32` depth budget clamps safely without sign overflow.
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jp_items, items_json, json.Spec.Json, collect_jp_out, &col, {
			budget = {depth = max(u32)},
		})
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, res.emitted, u64(3))
	}
}

@(test)
facade_yaml_html_msgpack_ddl_and_table_writers :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Lookup and path detection for YAML, HTML, MessagePack.
	e, ok := stury.format_by_name("yaml")
	testing.expect(t, ok && e.id == .Yaml)
	e, ok = stury.format_by_name("yaml:merge")
	testing.expect(t, ok && e.id == .Yaml_Merge)
	e, ok = stury.format_by_name("html")
	testing.expect(t, ok && e.id == .Html)
	e, ok = stury.format_by_name("html:fragment")
	testing.expect(t, ok && e.id == .Html_Fragment)
	e, ok = stury.format_by_name("msgpack")
	testing.expect(t, ok && e.id == .Msgpack)
	e, ok = stury.format_by_name("msgpack:compact")
	testing.expect(t, ok && e.id == .Msgpack_Compact)

	ep, _, pok := stury.format_of_path("service.yaml")
	testing.expect(t, pok && ep.id == .Yaml)
	ep, _, pok = stury.format_of_path("page.htm")
	testing.expect(t, pok && ep.id == .Html)
	ep, _, pok = stury.format_of_path("blob.mpk")
	testing.expect(t, pok && ep.id == .Msgpack)

	// YAML dialects (`Core` vs `Failsafe`), HTML CSS selector, and MessagePack query/check.
	yaml_src := transmute([]u8)string("# note\nuser:\n  name: ada\n  age: 36\n")
	ydoc, yerr := stury.build(yaml_src, yaml.Spec.Yaml_1_2)
	testing.expect_value(t, yerr, stury.Error(nil))
	defer stury.destroy(&ydoc)
	ycs, yc_err := stury.comments(&ydoc)
	testing.expect_value(t, yc_err, nil)
	defer delete(ycs)
	testing.expect_value(t, len(ycs), 1)
	testing.expect_value(t, ycs[0].text, "note")

	// YAML Failsafe dialect keeps `36` as a string.
	fs_doc, fs_err := stury.build(yaml_src, yaml.Spec.Yaml_1_2, {format = stury.Yaml_Options{dialect = .Failsafe}})
	testing.expect_value(t, fs_err, stury.Error(nil))
	defer stury.destroy(&fs_doc)
	fs_json, _, fsw_err := stury.write(&fs_doc, json.Spec.Json)
	testing.expect_value(t, fsw_err, stury.Write_Error(nil))
	defer delete(fs_json)
	testing.expect(t, strings.contains(string(fs_json), `"36"`))

	// HTML5 document + CSS selection + attributes.
	html_src := transmute([]u8)string(`<!DOCTYPE html><html><body><div class="card" data-id="7"><p>ada</p></div></body></html>`)
	hdoc, herr := stury.build(html_src, html.Spec.Html)
	testing.expect_value(t, herr, stury.Error(nil))
	defer stury.destroy(&hdoc)
	hhits, hok := stury.css(&hdoc, "div.card")
	testing.expect(t, hok && len(hhits.matches) == 1)
	defer stury.destroy_css(&hhits)
	hattrs, haerr := stury.attributes(&hdoc, hhits.matches[0].value)
	testing.expect_value(t, haerr, nil)
	defer stury.destroy_attributes(hattrs)
	testing.expect_value(t, len(hattrs), 2)

	// jq and JSONPath over YAML, HTML, and MessagePack.
	mp_bytes, _, mp_ferr := stury.format(yaml_src, yaml.Spec.Yaml_1_2, msgpack.Spec.Compact)
	testing.expect_value(t, mp_ferr, stury.Format_Error(nil))
	defer delete(mp_bytes)

	jqp, jq_errs := stury.jq_compile(".user.name")
	testing.expect_value(t, len(jq_errs), 0)
	defer stury.jq_destroy(jqp)
	for pair in ([?]struct { src: []u8, spec: stury.Spec }{
		{yaml_src, yaml.Spec.Yaml_1_2},
		{mp_bytes, msgpack.Spec.Compact},
	}) {
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jq_run(jqp, pair.src, pair.spec, collect_jq_out, &col)
		defer stury.jq_run_result_destroy(&res)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	jpp, jperr := stury.jsonpath_compile("$.html.body.div.p")
	testing.expect_value(t, jperr.kind, .None)
	defer stury.jsonpath_destroy(jpp)
	{
		col: Query_Collector
		defer destroy_collector(&col)
		res := stury.jsonpath_eval(jpp, html_src, html.Spec.Html, collect_jp_out, &col)
		testing.expect_value(t, res.err, stury.Query_Error.None)
		testing.expect_value(t, len(col.values), 1)
		testing.expect_value(t, col.values[0], `"ada"`)
	}

	// SQL DDL schema compile + streaming check across JSON, YAML, and MessagePack.
	ddl_sql := transmute([]u8)string("CREATE TABLE users (\n  name VARCHAR(50) NOT NULL,\n  age INT NOT NULL CHECK (age >= 0)\n);\n")
	ddl_sc, ddl_err := stury.schema_compile_ddl(ddl_sql)
	testing.expect_value(t, ddl_err.kind, stury.Ddl_Error_Kind.None)
	defer stury.ddl_destroy(ddl_sc)

	r_json := stury.check_schema(transmute([]u8)string(`{"name":"ada","age":36}`), json.Spec.Json, ddl_sc)
	defer stury.destroy_check_result(&r_json)
	testing.expect(t, r_json.valid)

	r_yaml := stury.check_schema(transmute([]u8)string("name: ada\nage: 36\n"), yaml.Spec.Yaml_1_2, ddl_sc)
	defer stury.destroy_check_result(&r_yaml)
	testing.expect(t, r_yaml.valid)

	r_bad := stury.check_schema(transmute([]u8)string("name: ada\nage: -1\n"), yaml.Spec.Yaml_1_2, ddl_sc)
	defer stury.destroy_check_result(&r_bad)
	testing.expect(t, !r_bad.valid)

	// Table and Markdown writers through `stury`.
	rows_doc, rb_err := stury.build(transmute([]u8)string(`[{"name":"ada","age":36},{"name":"bob","age":42}]`), json.Spec.Json)
	testing.expect_value(t, rb_err, stury.Error(nil))
	defer stury.destroy(&rows_doc)

	tbl, terr := stury.write_table(&rows_doc)
	testing.expect_value(t, terr, stury.Write_Error(nil))
	defer delete(tbl)
	testing.expect(t, strings.contains(string(tbl), "ada") && strings.contains(string(tbl), "42"))

	md, mderr := stury.write_markdown(&rows_doc)
	testing.expect_value(t, mderr, stury.Write_Error(nil))
	defer delete(md)
	testing.expect(t, strings.contains(string(md), "| name") && strings.contains(string(md), "---:"))
}
