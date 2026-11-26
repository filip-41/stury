package jq_tests

import "base:runtime"
import "core:bytes"
import "core:testing"
import "stury:cbor"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/query"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(test)
jq_fact_writes_jsonc :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("{\n  // old note\n  \"a\": 1,\n  \"b\": 2\n}\n")
	doc, err := json.build(src, .Jsonc, {}, alloc)
	testing.expect(t, err == nil)

	prog, perrs := jq.compile(`.a = 42 | .a.@comment = "new note" | .b.@comment_inline = "side"`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)

	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, len(outs.vals), 1)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	out_ov, _, ok := query.overlay_handle(outs.vals[0])
	testing.expect(t, ok)
	res, cerr := json.commit(out_ov, .Jsonc, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "{\n  // new note\n  \"a\": 42,\n  \"b\": 2 // side\n}\n")
}

@(test)
jq_fact_writes_xml_attributes_and_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string(`<r><a old="drop" keep='yes'>hi</a></r>`)
	doc, err := xml.build(src, .Xml, {}, alloc)
	testing.expect(t, err == nil)

	prog, perrs := jq.compile(`.r.a.&id = "x" | del(.r.a.&old)`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)

	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, len(outs.vals), 1)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	out_ov, _, ok := query.overlay_handle(outs.vals[0])
	testing.expect(t, ok)
	res, cerr := xml.commit(out_ov, {}, alloc)
	testing.expectf(t, cerr == nil, "cerr = %v", cerr)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), `<r><a keep='yes' id="x">hi</a></r>`)
}

@(test)
jq_fact_writes_toml_style_and_comment :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("name = \"hello\"\ncount = 1\n")
	doc, err := toml.build(src, .Toml_1_0, {}, alloc)
	testing.expect(t, err == nil)

	prog, perrs := jq.compile(`.name.@style = "literal" | .name.@comment = "top" | .count = 7`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)

	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, len(outs.vals), 1)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	out_ov, _, ok := query.overlay_handle(outs.vals[0])
	testing.expect(t, ok)
	res, cerr := toml.commit(out_ov, .Toml_1_0, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "# top\nname = 'hello'\ncount = 7\n")
}

@(test)
jq_fact_writes_cbor_tag :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	// {"a": h'05'} — tag 24 (embedded CBOR) applies to a byte string.
	src := []u8{0xa1, 0x61, 'a', 0x41, 0x05}
	doc, err := cbor.build(src, .Cbor, {}, alloc)
	testing.expect(t, err == nil)

	prog, perrs := jq.compile(`.a.@tag = 24`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)

	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, len(outs.vals), 1)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	out_ov, _, ok := query.overlay_handle(outs.vals[0])
	testing.expect(t, ok)
	res, cerr := cbor.commit(out_ov, .Cbor, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	want := []u8{0xa1, 0x61, 'a', 0xd8, 0x18, 0x41, 0x05}
	testing.expectf(t, bytes.equal(res.bytes, want), "got %x, want %x", res.bytes, want)
}

@(test)
jq_reconcile_arbitrary_filter_lossless :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("{\n  \"a\": { \"x\" :  1 },\n  \"b\": 2\n}\n")
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer json.destroy(&doc)

	ov: edit.Overlay
	testing.expect(t, edit.init(&ov, &doc, alloc) == nil)
	defer edit.destroy(&ov)

	prog, perrs := jq.compile(`{a: .a, b: (.b + 10)}`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)

	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	inp, st := query.overlay_value(&h, &ov)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, len(outs.vals), 1)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	// Reconcile arbitrary rebuilt object back into Overlay: `.a` keeps its exact `{ "x" :  1 }` spacing!
	testing.expect(t, query.reconcile_overlay(&h, &ov, outs.vals[0]) == nil)

	res, cerr := json.commit(&ov, .Json, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "{\n  \"a\": { \"x\" :  1 },\n  \"b\": 12\n}\n")
}

@(test)
jq_overlay_cow_aliasing_backtracking_css_u64_tag_and_group1 :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. COW aliasing `[., (.a = 2)]` and backtracking `(try (.a = 2 | error("x")) catch empty) // .`:
	//    neither may corrupt the original overlay!
	{
		src := transmute([]u8)string(`{"a": 1}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: edit.Overlay
		testing.expect(t, edit.init(&ov, &doc, alloc) == nil)
		defer edit.destroy(&ov)

		prog, perrs := jq.compile(`[., (.a = 2)]`)
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(perrs), 0)

		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)

		inp, st := query.overlay_value(&h, &ov)
		testing.expect_value(t, st, query.Status.Ok)

		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		defer jq.run_destroy(&run)
		outs := Outputs{h = &h}
		defer delete(outs.vals)

		end := jq.run_value(&run, inp, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, len(outs.vals), 1)
		defer for v in outs.vals {
			query.release(&h, v)
		}

		buf := make([dynamic]u8, alloc)
		defer delete(buf)
		testing.expect_value(t, query.write_json(&h, &buf, outs.vals[0]), query.Status.Ok)
		testing.expect_value(t, string(buf[:]), `[{"a":1},{"a":2}]`)
		testing.expect(t, !ov.dirty)
	}

	// 2. Large `u64` CBOR tag (`> max(i64)`) via `.a.@tag = 18446744073709551615`!
	{
		src := []u8{0xa1, 0x61, 'a', 0x05}
		doc, err := cbor.build(src, .Cbor, {}, alloc)
		testing.expect(t, err == nil)

		prog, perrs := jq.compile(`.a.@tag = 18446744073709551615`)
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(perrs), 0)

		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)

		inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = true)
		testing.expect_value(t, st, query.Status.Ok)

		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		defer jq.run_destroy(&run)
		outs := Outputs{h = &h}
		defer delete(outs.vals)

		end := jq.run_value(&run, inp, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, len(outs.vals), 1)
		defer for v in outs.vals {
			query.release(&h, v)
		}

		out_ov, _, ok := query.overlay_handle(outs.vals[0])
		testing.expect(t, ok)
		res, cerr := cbor.commit(out_ov, .Cbor, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		want := []u8{0xa1, 0x61, 'a', 0xdb, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x05}
		testing.expectf(t, bytes.equal(res.bytes, want), "got %x, want %x", res.bytes, want)
	}

	// 3. `css` on XML `.Overlay` and XML `.Group` after `.Container_Delta`!
	{
		src := transmute([]u8)string(`<r><a class="hit">1</a><a class="hit">2</a><b>keep</b></r>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: edit.Overlay
		testing.expect(t, edit.init(&ov, &doc, alloc) == nil)
		defer edit.destroy(&ov)

		prog, perrs := jq.compile(`[css(".hit")]`)
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(perrs), 0)

		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)

		inp, st := query.overlay_value(&h, &ov)
		testing.expect_value(t, st, query.Status.Ok)

		hooks := jq.Hooks{markup = xml_markup}
		run: jq.Run
		jq.run_init(&run, prog, &h, nil, &hooks)
		defer jq.run_destroy(&run)
		outs := Outputs{h = &h}
		defer delete(outs.vals)

		end := jq.run_value(&run, inp, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, len(outs.vals), 1)
		defer for v in outs.vals {
			query.release(&h, v)
		}
		buf := make([dynamic]u8, alloc)
		defer delete(buf)
		testing.expect_value(t, query.write_json(&h, &buf, outs.vals[0]), query.Status.Ok)
		testing.expect_value(t, string(buf[:]), `["1","2"]`)

		// Verify XML `.Group` on `.Container_Delta` (delete `<b>` -> `.r.a` still groups both `<a>` elements!)
		rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "r")
		rh, _ := edit.handle_for_base(&ov, rn)
		testing.expect(t, edit.del_member(&ov, rh, "b") == nil)
		root_v, rs := query.overlay_value(&h, &ov)
		testing.expect_value(t, rs, query.Status.Ok)
		defer query.release(&h, root_v)
		r_v, r_st := query.member(&h, root_v, "r")
		testing.expect_value(t, r_st, query.Status.Ok)
		defer query.release(&h, r_v)
		a_v, a_st := query.member(&h, r_v, "a")
		testing.expect_value(t, a_st, query.Status.Ok)
		defer query.release(&h, a_v)
		testing.expect_value(t, query.type_of(a_v), query.Type.Array)
		testing.expect_value(t, query.length_of(&h, a_v), 2)
	}
	{
		// Group 1 refusal inside `jq` is catchable by `try ... catch`!
		src := transmute([]u8)string(`<r><a>1</a></r>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)

		prog, perrs := jq.compile(`try (.r.a.@comment = "bad -- comment") catch "caught"`)
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(perrs), 0)

		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)

		inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = true)
		testing.expect_value(t, st, query.Status.Ok)

		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		defer jq.run_destroy(&run)
		outs := Outputs{h = &h}
		defer delete(outs.vals)

		end := jq.run_value(&run, inp, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, len(outs.vals), 1)
		defer for v in outs.vals {
			query.release(&h, v)
		}
		testing.expect_value(t, query.text_of(outs.vals[0]), "caught")
	}
}

// Helper for concise single-doc jq-on-overlay evaluation returning formatted JSON output.
@(private = "file")
eval_jq_overlay_json :: proc(
	t: ^testing.T,
	src: []u8,
	doc: tape.Document,
	doc_owned: bool,
	expr: string,
	hooks: ^jq.Hooks = nil,
) -> string {
	_ = src
	alloc := runtime.heap_allocator()
	prog, perrs := jq.compile(expr)
	defer jq.destroy_program(prog)
	testing.expectf(t, len(perrs) == 0, "compile %q errors: %d", expr, len(perrs))

	h: query.Heap
	query.heap_init(&h, alloc)
	defer query.heap_destroy(&h)

	inp, _, st := query.overlay_from_doc(&h, doc, doc_owned = doc_owned)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil, hooks)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	defer for v in outs.vals {
		query.release(&h, v)
	}
	if len(outs.vals) == 0 {
		return ""
	}
	buf := make([dynamic]u8, alloc)
	testing.expect_value(t, query.write_json(&h, &buf, outs.vals[0]), query.Status.Ok)
	return string(buf[:])
}

@(test)
jq_overlay_same_ov_cow_facts_decode_css_and_reconcile_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Bug #1: Same-overlay assignments (`.b = .a`, `.a = 42 | .b = .a`, `.[1] = .[0]`, `setpath(["b"]; .a)`, `.a = .`, `.a = .a.b`, self `.a = .a`)
	{
		cases := [?][3]string {
			{`{"a":{"x":1},"b":0}`, `.b = .a`, `{"a":{"x":1},"b":{"x":1}}`},
			{`{"a":1,"b":0}`, `.a = 42 | .b = .a`, `{"a":42,"b":42}`},
			{`[10,20]`, `.[1] = .[0]`, `[10,10]`},
			{`{"a":{"x":1},"b":0}`, `setpath(["b"]; .a)`, `{"a":{"x":1},"b":{"x":1}}`},
			{`{"a":{"x":1}}`, `.a = .a.x`, `{"a":1}`},
			{`{"a":1,"b":2}`, `.a = .`, `{"a":{"a":1,"b":2},"b":2}`},
			{`{"a":42}`, `.a = .a`, `{"a":42}`},
		}
		for c in cases {
			doc, err := json.build(transmute([]u8)c[0], .Json, {}, alloc)
			testing.expect(t, err == nil)
			got := eval_jq_overlay_json(t, nil, doc, true, c[1])
			defer delete(got, alloc)
			testing.expectf(t, got == c[2], "%s on %s: got %s, want %s", c[1], c[0], got, c[2])
		}
	}

	// Bug #2: Fact writes COW isolation + scalar created fact write `.b = 99 | .b.@comment = "note"`
	{
		cases := [?][3]string {
			{`{"a":1}`, `[., (.a.@comment = "x")] | map(.a.@comment)`, `[null,["x"]]`},
			{`{"a":1}`, `[., (.x = 1)][1] | (.a |= (.@comment = "x")) | [.x, .a, .a.@comment]`, `[1,1,["x"]]`},
			{`{"a":"hi\nthere"}`, `[., (.x = 1)][1] | (.a |= (.@comment = "x")) | [.x, .a, .a.@comment]`, `[1,"hi\nthere",["x"]]`},
			{`{"a":1}`, `[., (.x = 1)][0] | (.a |= (.@comment = "x")) | [.x, .a, .a.@comment]`, `[null,1,["x"]]`},
			{`{"a":1}`, `(try (.x = 1 | error("boom")) catch empty) // . | (.a |= (.@comment = "x")) | [.a, .a.@comment]`, `[1,["x"]]`},
			{`{"a":1,"b":2}`, `.a |= (.@comment = "cx") | .b |= (.@comment = "cy") | [.a.@comment, .b.@comment]`, `[["cx"],["cy"]]`},
			{`{"a":1}`, `. as $orig | (.a.@comment = "x") | $orig.a.@comment`, `null`},
			{`{"a":1}`, `[., (.@comment = "x")] | map(.@comment)`, `[null,["x"]]`},
			{`{"a":1}`, `. as $orig | (.a | .@comment = "x") | $orig.a.@comment`, `null`},
			{`{"a":1}`, `(try (.a.@comment = "x" | error("boom")) catch empty) // . | .a.@comment`, `null`},
			{`{"a":1}`, `. as $orig | (try (.a.@comment = "x" | error("boom")) catch "err") | $orig.a.@comment`, `null`},
			{`{"a":1}`, `{w: .} | .w.a.@comment = "x" | .w.a.@comment`, `["x"]`},
			{`{"a":1}`, `.b = 99 | .b.@comment = "note" | [.b, .b.@comment]`, `[99,["note"]]`},
			{`{"a":{"x":1}}`, `(.b = .a | .b.x.@comment = "z") | [.a.x.@comment, .b.x.@comment]`, `[null,["z"]]`},
		}
		for c in cases {
			doc, err := json.build(transmute([]u8)c[0], .Jsonc, {}, alloc)
			testing.expect(t, err == nil)
			got := eval_jq_overlay_json(t, nil, doc, true, c[1])
			defer delete(got, alloc)
			testing.expectf(t, got == c[2], "%s: got %s, want %s", c[1], got, c[2])
		}

		// Commit JSONC `.b = 99 | .b.@comment = "note"` to verify comment lands in serialized JSONC output!
		jdoc, _ := json.build(transmute([]u8)string("{\n  \"a\": 1\n}\n"), .Jsonc, {}, alloc)
		prog, _ := jq.compile(`.b = 99 | .b.@comment = "note"`)
		defer jq.destroy_program(prog)
		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)
		inp, _, _ := query.overlay_from_doc(&h, jdoc, doc_owned = true)
		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		defer jq.run_destroy(&run)
		outs := Outputs{h = &h}
		defer delete(outs.vals)
		_ = jq.run_value(&run, inp, collect, &outs)
		defer for v in outs.vals {
			query.release(&h, v)
		}
		testing.expect_value(t, len(outs.vals), 1)
		out_ov, _, ok := query.overlay_handle(outs.vals[0])
		testing.expect(t, ok)
		res, cerr := json.commit(out_ov, .Jsonc, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "{\n  \"a\": 1,\n  // note\n  \"b\": 99\n}\n")

		// Bug #1 + #2 commit checks: `.a = .` on JSON and `.b = 99 | .b.@comment = "note"` on TOML, plus COW `[., del(.a)]`!
		jdoc2, _ := json.build(transmute([]u8)string(`{"a":1,"b":2}`), .Json, {}, alloc)
		p2, _ := jq.compile(`.a = .`)
		defer jq.destroy_program(p2)
		h2: query.Heap
		query.heap_init(&h2, alloc)
		defer query.heap_destroy(&h2)
		inp2, _, _ := query.overlay_from_doc(&h2, jdoc2, doc_owned = true)
		run2: jq.Run
		jq.run_init(&run2, p2, &h2, nil)
		defer jq.run_destroy(&run2)
		outs2 := Outputs{h = &h2}
		defer delete(outs2.vals)
		_ = jq.run_value(&run2, inp2, collect, &outs2)
		defer for v in outs2.vals {
			query.release(&h2, v)
		}
		testing.expect_value(t, len(outs2.vals), 1)
		ov2, _, ok2 := query.overlay_handle(outs2.vals[0])
		testing.expect(t, ok2)
		res2, cerr2 := json.commit(ov2, .Json, {}, alloc)
		testing.expect(t, cerr2 == nil)
		defer edit.destroy_commit_result(&res2)
		testing.expect_value(t, string(res2.bytes), `{"a":{"a":1,"b":2},"b":2}`)

		cow_del_doc, _ := json.build(transmute([]u8)string(`{"a":1,"b":2}`), .Json, {}, alloc)
		cow_del := eval_jq_overlay_json(t, nil, cow_del_doc, true, `[., del(.a)]`)
		defer delete(cow_del, alloc)
		testing.expect_value(t, cow_del, `[{"a":1,"b":2},{"b":2}]`)

		tdoc, _ := toml.build(transmute([]u8)string("a = 1\n"), .Toml_1_0, {}, alloc)
		tp, _ := jq.compile(`.b = 99 | .b.@comment = "note"`)
		defer jq.destroy_program(tp)
		th: query.Heap
		query.heap_init(&th, alloc)
		defer query.heap_destroy(&th)
		tinp, _, _ := query.overlay_from_doc(&th, tdoc, doc_owned = true)
		trun: jq.Run
		jq.run_init(&trun, tp, &th, nil)
		defer jq.run_destroy(&trun)
		touts := Outputs{h = &th}
		defer delete(touts.vals)
		_ = jq.run_value(&trun, tinp, collect, &touts)
		defer for v in touts.vals {
			query.release(&th, v)
		}
		testing.expect_value(t, len(touts.vals), 1)
		tov, _, tok := query.overlay_handle(touts.vals[0])
		testing.expect(t, tok)
		tres, tcerr := toml.commit(tov, .Toml_1_0, {}, alloc)
		testing.expect(t, tcerr == nil)
		defer edit.destroy_commit_result(&tres)
		testing.expect_value(t, string(tres.bytes), "a = 1\n# note\nb = 99\n")
	}

	// Bug #5: `text_of` on `.Overlay` wrapping `SPELLING_DECODE` base scalar!
	{
		jdoc, _ := json.build(transmute([]u8)string(`{"s": "a\nb"}`), .Jsonc, {}, alloc)
		got := eval_jq_overlay_json(t, nil, jdoc, true, `.s |= (.@comment = "note" | . + "!")`)
		defer delete(got, alloc)
		testing.expect_value(t, got, `{"s":"a\nb!"}`)

		xdoc, _ := xml.build(transmute([]u8)string(`<r><a>hi &amp; bye</a></r>`), .Xml, {}, alloc)
		xgot := eval_jq_overlay_json(t, nil, xdoc, true, `.r.a |= (.@comment = "c" | . + "!")`)
		defer delete(xgot, alloc)
		testing.expect_value(t, xgot, `{"r":{"a":"hi & bye!"}}`)
	}

	// Bug #6 + Bug #9: `css()` over edited XML `.Overlay`, grouped XML `.Base_Ref` copy, and `reconcile_overlay` repeated XML!
	{
		hooks := jq.Hooks{markup = xml_markup}
		src := `<r><a>1</a><a>2</a><b>keep</b></r>`
		cases := [?][2]string {
			{`.r.a[0].&class = "hit" | [css(".hit")]`, `["1"]`},
			{`del(.r.a[0]) | [css("a")]`, `["2"]`},
			{`.r.c = "new" | .r.c.&class = "hit" | [css(".hit")]`, `["new"]`},
			{`.r.a[0].&class = "hit" | css(".hit") |= . + "!" | .r.a`, `["1!","2"]`},
			{`(.copy = .r | .copy.a)`, `["1","2"]`},
		}
		for c in cases {
			xdoc, err := xml.build(transmute([]u8)src, .Xml, {}, alloc)
			testing.expect(t, err == nil)
			got := eval_jq_overlay_json(t, nil, xdoc, true, c[0], &hooks)
			defer delete(got, alloc)
			testing.expectf(t, got == c[1], "%s: got %s, want %s", c[0], got, c[1])
		}

		// Bug #9 `reconcile_overlay`: repeated XML elements updating only element 1 preserves element 0 verbatim!
		rsrc := transmute([]u8)string(`<r><a k='verbatim'>1</a><a>2</a></r>`)
		rdoc, rerr := xml.build(rsrc, .Xml, {}, alloc)
		testing.expect(t, rerr == nil)
		defer tape.destroy_document(&rdoc)
		rov: edit.Overlay
		testing.expect(t, edit.init(&rov, &rdoc, alloc) == nil)
		defer edit.destroy(&rov)

		rprog, _ := jq.compile(`.r.a = [.r.a[0], "22"]`)
		defer jq.destroy_program(rprog)
		rh: query.Heap
		query.heap_init(&rh, alloc)
		defer query.heap_destroy(&rh)
		rinp, _ := query.overlay_value(&rh, &rov)
		rrun: jq.Run
		jq.run_init(&rrun, rprog, &rh, nil)
		defer jq.run_destroy(&rrun)
		routs := Outputs{h = &rh}
		defer delete(routs.vals)
		_ = jq.run_value(&rrun, rinp, collect, &routs)
		defer for v in routs.vals {
			query.release(&rh, v)
		}
		testing.expect(t, query.reconcile_overlay(&rh, &rov, routs.vals[0]) == nil)
		rres, rcerr := xml.commit(&rov, {}, alloc)
		testing.expect(t, rcerr == nil)
		defer edit.destroy_commit_result(&rres)
		testing.expect_value(t, string(rres.bytes), `<r><a k='verbatim'>1</a><a>22</a></r>`)

		// Repeated XML array-replaced element length changes across multiple `reconcile_overlay` passes (`2 -> 3 -> 2 -> "solo" -> ["one", "two"] -> del`).
		run_reconcile := proc(t: ^testing.T, h: ^query.Heap, rov: ^edit.Overlay, src_prog: string, want_xml: string) {
			p, perr := jq.compile(src_prog)
			testing.expect(t, perr == nil)
			defer jq.destroy_program(p)
			inp, _ := query.overlay_value(h, rov)
			run: jq.Run
			jq.run_init(&run, p, h, nil)
			defer jq.run_destroy(&run)
			outs := Outputs{h = h}
			defer delete(outs.vals)
			_ = jq.run_value(&run, inp, collect, &outs)
			defer for v in outs.vals {
				query.release(h, v)
			}
			testing.expect_value(t, len(outs.vals), 1)
			testing.expect(t, query.reconcile_overlay(h, rov, outs.vals[0]) == nil)
			res, cerr := xml.commit(rov, {}, runtime.heap_allocator())
			testing.expectf(t, cerr == nil, "%s cerr=%v", src_prog, cerr)
			defer edit.destroy_commit_result(&res)
			testing.expect_value(t, string(res.bytes), want_xml)
		}
		run_reconcile(t, &rh, &rov, `.r.a = [.r.a[0], "22", "33"]`, `<r><a k='verbatim'>1</a><a>22</a><a>33</a></r>`)
		run_reconcile(t, &rh, &rov, `.r.a = [.r.a[0], "two"]`, `<r><a k='verbatim'>1</a><a>two</a></r>`)

		// Empty array `.r.a = []` commits with `.Empty_Markup_Array`, and subsequent length change (`0 -> 2` on `array_h`) recovers cleanly!
		p_empty, _ := jq.compile(`.r.a = []`)
		defer jq.destroy_program(p_empty)
		inp_e, _ := query.overlay_value(&rh, &rov)
		run_e: jq.Run
		jq.run_init(&run_e, p_empty, &rh, nil)
		defer jq.run_destroy(&run_e)
		outs_e := Outputs{h = &rh}
		defer delete(outs_e.vals)
		_ = jq.run_value(&run_e, inp_e, collect, &outs_e)
		defer for v in outs_e.vals {
			query.release(&rh, v)
		}
		testing.expect(t, query.reconcile_overlay(&rh, &rov, outs_e.vals[0]) == nil)
		_, e_cerr := xml.commit(&rov, {}, alloc)
		er_ref, ok_e := e_cerr.(edit.Refusal)
		testing.expect(t, ok_e && er_ref.kind == .Empty_Markup_Array)

		run_reconcile(t, &rh, &rov, `.r.a = ["recovered", "two"]`, `<r><a k='verbatim'>recovered</a><a>two</a></r>`)
		run_reconcile(t, &rh, &rov, `.r.a = "solo"`, `<r><a>solo</a></r>`)
		run_reconcile(t, &rh, &rov, `.r.a = ["one", "two"]`, `<r><a>one</a><a>two</a></r>`)
		run_reconcile(t, &rh, &rov, `del(.r.a)`, `<r></r>`)
	}
}
