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

	inp, ov, st := query.overlay_from_doc(&h, doc, doc_owned = true)
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

	res, cerr := json.commit(ov, .Jsonc, {}, alloc)
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

	inp, ov, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	res, cerr := xml.commit(ov, {}, alloc)
	testing.expect(t, cerr == nil)
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

	inp, ov, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	res, cerr := toml.commit(ov, .Toml_1_0, {}, alloc)
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

	inp, ov, st := query.overlay_from_doc(&h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)

	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	defer jq.run_destroy(&run)
	outs := Outputs{h = &h}
	defer delete(outs.vals)

	end := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Done)
	defer for v in outs.vals {
		query.release(&h, v)
	}

	res, cerr := cbor.commit(ov, .Cbor, {}, alloc)
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

		inp, ov, st := query.overlay_from_doc(&h, doc, doc_owned = true)
		testing.expect_value(t, st, query.Status.Ok)

		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		defer jq.run_destroy(&run)
		outs := Outputs{h = &h}
		defer delete(outs.vals)

		end := jq.run_value(&run, inp, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		defer for v in outs.vals {
			query.release(&h, v)
		}

		res, cerr := cbor.commit(ov, .Cbor, {}, alloc)
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
