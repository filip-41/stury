package jq_tests

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(private = "file")
eval_doc :: proc(t: ^testing.T, expr: string, doc: tape.Document, write_fn: query.Fact_Writer = nil, write_data: rawptr = nil, loc := #caller_location) -> (out: string, end: jq.Run_End, err_msg: string, tainted: bool) {
	d := doc
	r := eval_jq(t, expr, {doc = &d, write_fact = write_fn, write_fact_data = write_data}, loc = loc)
	return r.out, r.end, r.err_msg, r.tainted
}

@(test)
facts_read_across_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// 1. JSONC comments: head, alias comment_head, inline, foot.
	{
		src := transmute([]u8)string("// head\n{\n  // lead a\n  \"a\": /* in */ 1, // trail a\n  \"b\": [\n    1\n    // foot b\n  ]\n} // end\n")
		doc, err := json.build(src, .Jsonc, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		out, end, _, _ := eval_doc(t, `[.@comment, .@comment_head, .a.@comment, .a.@comment_inline, .b.@comment_foot, .@comment_inline]`, doc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `[["head"],["head"],["lead a","in"],["trail a"],["foot b"],["end"]]`)
	}

	// 2. TOML comments, styles, and date-time tags.
	{
		src := transmute([]u8)string("# top\nname = 'lit'\nhex = 0xff\nd = 2024-01-02\n[sec]\nt = 2024-01-02T03:04:05Z\n")
		doc, err := toml.build(src, .Toml_1_0, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		out, end, _, _ := eval_doc(t, `[.name.@comment, .name.@style, .hex.@style, .d.@tag, .sec.@style, .sec.t.@tag]`, doc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `[["top"],"literal","hex","date-local","header","datetime"]`)
	}

	// 3. CBOR numeric tag (tag 1 + uint 42).
	{
		src := []u8{0xc1, 0x18, 0x2a}
		doc, err := cbor.build(src, .Cbor, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		out, end, _, _ := eval_doc(t, `[., .@tag]`, doc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `[42,1]`)
	}

	// 4. XML attributes, element name, namespace, content, comments, PI, doctype.
	{
		src := transmute([]u8)string(`<!DOCTYPE r><?xml-stylesheet type="text/css"?><!-- root --><r xmlns:x="urn:x"><x:a href="https://example.com" xml:lang="en">hi <b>there</b></x:a></r>`)
		doc, err := xml.build(src, .Xml, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		out, end, _, _ := eval_doc(t, `[.r."x:a".&href, .r."x:a".&"xml:lang", .r."x:a".@attrs, .r."x:a".@name, .r."x:a".@namespace, .r."x:a".@content, .r.@comment, .@pi, .@doctype]`, doc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `["https://example.com","en",{"href":"https://example.com","xml:lang":"en"},"x:a","urn:x","hi there",["root"],["xml-stylesheet type=\"text/css\""],"<!DOCTYPE r>"]`)
	}

	// 5. CSV comment lines with `--comment '#'`.
	{
		src := transmute([]u8)string("# header comment\na,b\n# row1 comment\n1,2\n")
		opts := dsv.Options{format = tape.Dsv_Options{comment = '#'}}
		doc, err := dsv.build(src, .Csv, opts, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		out, end, _, _ := eval_doc(t, `[.@comment, .[0].@comment]`, doc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `[["header comment"],["row1 comment"]]`)
	}

	// 6. Facts on `.Null`, `.False`, `.True`, decoded strings (entities/escapes), `.Bytes`, scalar roots, and XML `.Instruction_Foot`.
	{
		// Empty XML element (`.Null`) and entity-decoded text (`SPELLING_DECODE`) preserve facts.
		xml_src := transmute([]u8)string(`<r><a k="1"/><b attr="x&amp;y">hi &amp; bye</b><?p foot?></r><?z end?>`)
		xdoc, xerr := xml.build(xml_src, .Xml, {}, runtime.heap_allocator())
		testing.expect(t, xerr == nil)
		defer tape.destroy_document(&xdoc)

		out, end, _, _ := eval_doc(t, `[.r.a.&k, .r.a.@name, .r.b.&attr, .r.b.@name, .r.b.@content, .r.@pi, .@pi]`, xdoc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `["1","a","x&y","b","hi & bye",["p foot"],["z end"]]`)

		// JSONC null, boolean, and escape-decoded string preserve comments, and `!Partial.facts` taints on them.
		jc_src := transmute([]u8)string("{\n  // n\n  \"a\": null,\n  // b\n  \"b\": true,\n  // s\n  \"s\": \"x\\ny\"\n}\n")
		jdoc, jerr := json.build(jc_src, .Jsonc, {}, runtime.heap_allocator())
		testing.expect(t, jerr == nil)
		defer tape.destroy_document(&jdoc)

		jout, jend, _, _ := eval_doc(t, `[.a.@comment, .b.@comment, .s.@comment]`, jdoc)
		testing.expect_value(t, jend, jq.Run_End.Done)
		testing.expect_value(t, jout, `[["n"],["b"],["s"]]`)

		d_nf, derr := tape.demand_of({{tape.Name("b")}, {tape.Name("s")}}, {.Whole, .Whole}, nil, false, runtime.heap_allocator())
		testing.expect(t, derr == nil)
		defer tape.destroy_demand(&d_nf)
		pdoc, perr := json.scan(jc_src, &d_nf, .Jsonc, {}, {}, runtime.heap_allocator())
		testing.expect(t, perr == nil)
		defer tape.destroy_document(&pdoc)

		_, te1, _, tt1 := eval_doc(t, `try .b.@comment catch "no"`, pdoc)
		testing.expect_value(t, te1, jq.Run_End.Tainted)
		testing.expect(t, tt1)
		_, te2, _, tt2 := eval_doc(t, `try .s.@comment catch "no"`, pdoc)
		testing.expect_value(t, te2, jq.Run_End.Tainted)
		testing.expect(t, tt2)

		// CBOR tag on boolean (`true`) and byte string (`.Bytes`).
		cbor_bool := []u8{0xd8, 0x63, 0xf5} // tag 99 + true
		cb1, ce1 := cbor.build(cbor_bool, .Cbor, {}, runtime.heap_allocator())
		testing.expect(t, ce1 == nil)
		defer tape.destroy_document(&cb1)
		co1, cend1, _, _ := eval_doc(t, `[., .@tag]`, cb1)
		testing.expect_value(t, cend1, jq.Run_End.Done)
		testing.expect_value(t, co1, `[true,99]`)

		cbor_bytes := []u8{0xd8, 0x18, 0x41, 0x41} // tag 24 + bstr "A"
		cb2, ce2 := cbor.build(cbor_bytes, .Cbor, {}, runtime.heap_allocator())
		testing.expect(t, ce2 == nil)
		defer tape.destroy_document(&cb2)
		co2, cend2, _, _ := eval_doc(t, `[., type, .@tag]`, cb2)
		testing.expect_value(t, cend2, jq.Run_End.Done)
		testing.expect_value(t, co2, `["QQ==","bytes",24]`)

		// Empty `.@()` / `.&[]` and slice `.@(1:2)` / `.&[1:2]` must be compile errors.
		for bad in ([?]string{`.@()`, `.&[]`, `.@(1:2)`, `.&[1:2]`}) {
			bp, berrs := jq.compile(bad)
			jq.destroy_program(bp)
			testing.expectf(t, len(berrs) > 0, "expected compile error for %q", bad)
		}
	}
}

@(test)
facts_computed_paths_demands_and_write_seam :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Computed `.@(expr)` and `.&[expr]`, `path()`, and error cases.
	{
		src := transmute([]u8)string("// hi\n{\"a\": 1}\n")
		doc, err := json.build(src, .Jsonc, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		out, end, _, _ := eval_doc(t, `[path(.a.@comment), path(.a.@("com" + "ment")), path(.a.@("comment_head")), path(.a.&k), path(.a.&["xml:lang"]), .@("com" + "ment")]`, doc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `[["a",{"fact":"comment"}],["a",{"fact":"comment"}],["a",{"fact":"comment"}],["a",{"fact":"attribute","name":"k"}],["a",{"fact":"attribute","name":"xml:lang"}],["hi"]]`)

		_, end_bad, msg_bad, _ := eval_doc(t, `path(.a.@comment[0])`, doc)
		testing.expect_value(t, end_bad, jq.Run_End.Failed)
		testing.expect_value(t, msg_bad, "A comment step must be the last step of a path")

		_, end_unk, msg_unk, _ := eval_doc(t, `.a.@("nope")`, doc)
		testing.expect_value(t, end_unk, jq.Run_End.Failed)
		testing.expect(t, strings.has_prefix(msg_unk, "unknown fact .@nope, the facts are "))

		_, end_num, msg_num, _ := eval_doc(t, `.a.@(123)`, doc)
		testing.expect_value(t, end_num, jq.Run_End.Failed)
		testing.expect(t, strings.has_prefix(msg_num, "a fact name is a string, not number"))

		_, end_attr, msg_attr, _ := eval_doc(t, `.a.&[123]`, doc)
		testing.expect_value(t, end_attr, jq.Run_End.Failed)
		testing.expect(t, strings.has_prefix(msg_attr, "an attribute name is a string, not number"))

		// Static unknown fact is a compile error.
		prog, perrs := jq.compile(`.a.@nope`)
		defer jq.destroy_program(prog)
		testing.expect(t, len(perrs) == 1)
		testing.expect(t, strings.has_prefix(perrs[0].msg, "unknown fact .@nope, the facts are "))
	}

	// Demand.facts = true under scan vs facts = false tainting.
	{
		prog, errs := jq.compile(`.a.@comment`)
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(errs), 0)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)
		testing.expect(t, plan.sources[.Main].facts)
		testing.expect(t, plan.sources[.Main].demand.facts)

		src := transmute([]u8)string("{\n  // note\n  \"a\": 1,\n  \"b\": 2\n}\n")
		pdoc, perr := json.scan(src, &plan.sources[.Main].demand, .Jsonc, {}, {}, runtime.heap_allocator())
		testing.expect(t, perr == nil)
		defer tape.destroy_document(&pdoc)

		out, end, _, tainted := eval_doc(t, `.a.@comment`, pdoc)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect(t, !tainted)
		testing.expect_value(t, out, `["note"]`)

		// Same path scanned WITHOUT facts must taint uncatchably!
		d_nofacts, derr := tape.demand_of({{tape.Name("a")}}, {.Whole}, nil, false, runtime.heap_allocator())
		testing.expect(t, derr == nil)
		defer tape.destroy_demand(&d_nofacts)
		ndoc, nerr := json.scan(src, &d_nofacts, .Jsonc, {}, {}, runtime.heap_allocator())
		testing.expect(t, nerr == nil)
		defer tape.destroy_document(&ndoc)

		_, tend, _, ttainted := eval_doc(t, `try .a.@comment catch "nope"`, ndoc)
		testing.expect_value(t, tend, jq.Run_End.Tainted)
		testing.expect(t, ttainted)
	}

	// Fact-write validation seam + custom Overlay writer hook.
	{
		Write_Record :: struct {
			calls:   int,
			kind:    tape.Fact_Kind,
			attr:    string,
			is_attr: bool,
			val:     string,
		}
		hook_writer :: proc(data: rawptr, h: ^query.Heap, v: query.Value, kind: tape.Fact_Kind, attr: string, is_attr: bool, nv: query.Value) -> (query.Value, query.Status) {
			rec := (^Write_Record)(data)
			rec.calls += 1
			rec.kind = kind
			rec.attr = strings.clone(attr)
			rec.is_attr = is_attr
			rec.val = query.text_of(nv) if query.is_text(nv) else "null"
			query.release(h, nv)
			return v, .Ok
		}

		src := transmute([]u8)string(`{"a": 1}`)
		doc, err := json.build(src, .Json, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		// Validation rejections before hook is even reached.
		_, e1, m1, _ := eval_doc(t, `.a.@name = "x"`, doc)
		testing.expect_value(t, e1, jq.Run_End.Failed)
		testing.expect(t, strings.contains(m1, "cannot be written"))

		_, e2, m2, _ := eval_doc(t, `.a.@comment = 123`, doc)
		testing.expect_value(t, e2, jq.Run_End.Failed)
		testing.expect_value(t, m2, "a comment is a string, an array of strings, or null")

		_, e3, m3, _ := eval_doc(t, `.a.&k = 123`, doc)
		testing.expect_value(t, e3, jq.Run_End.Failed)
		testing.expect_value(t, m3, "an attribute is a string or null")

		_, e4, m4, _ := eval_doc(t, `.a.@anchor = 123`, doc)
		testing.expect_value(t, e4, jq.Run_End.Failed)
		testing.expect(t, strings.contains(m4, "a tag, an anchor, an alias or a style"))

		// Valid write and delete dispatch cleanly through the Overlay hook seam.
		rec: Write_Record
		out_w, ew, _, _ := eval_doc(t, `.a.@comment = "hi"`, doc, hook_writer, &rec)
		testing.expect_value(t, ew, jq.Run_End.Done)
		testing.expect_value(t, out_w, `{"a":1}`)
		testing.expect_value(t, rec.calls, 1)
		testing.expect_value(t, rec.kind, tape.Fact_Kind.Comment)
		testing.expect_value(t, rec.val, "hi")

		out_d, ed, _, _ := eval_doc(t, `del(.a.&href)`, doc, hook_writer, &rec)
		testing.expect_value(t, ed, jq.Run_End.Done)
		testing.expect_value(t, out_d, `{"a":1}`)
		testing.expect_value(t, rec.calls, 2)
		testing.expect_value(t, rec.kind, tape.Fact_Kind.Attribute)
		testing.expect(t, rec.is_attr)
		testing.expect_value(t, rec.attr, "href")
		testing.expect_value(t, rec.val, "null")
	}
}
