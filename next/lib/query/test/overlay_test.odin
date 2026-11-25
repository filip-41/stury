package query_test

import "base:runtime"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/query"
import "stury:testkit"

@(test)
overlay_value_size_and_reads :: proc(t: ^testing.T) {
	testkit.deadline(t)
	#assert(size_of(query.Value) == 16)

	th: Test_Heap
	heap_start(&th)
	defer heap_done(t, &th)
	h := &th.h

	src := transmute([]u8)string("{\n  // note on a\n  \"a\": 1,\n  \"b\": [10, 20, 30],\n  \"c\": {\"nested\": \"ok\"}\n}\n")
	doc, err := json.build(src, .Jsonc, {}, runtime.heap_allocator())
	testing.expect(t, err == nil)

	root, ov, st := query.overlay_from_doc(h, doc, doc_owned = true)
	testing.expect_value(t, st, query.Status.Ok)
	defer query.release(h, root)
	testing.expect_value(t, root.kind, query.Kind.Overlay)

	// Read unchanged fields through the same Value API.
	testing.expect_value(t, query.type_of(root), query.Type.Object)
	testing.expect_value(t, query.length_of(h, root), 3)

	a_val, as := query.member(h, root, "a")
	testing.expect_value(t, as, query.Status.Ok)
	defer query.release(h, a_val)
	ai, _ := query.as_i64(a_val)
	testing.expect_value(t, ai, i64(1))

	// Read comment fact through Overlay_Ref.
	c_val, cs := query.fact_read(h, a_val, .Comment)
	testing.expect_value(t, cs, query.Status.Ok)
	defer query.release(h, c_val)
	c0, c0s := query.element(h, c_val, 0)
	testing.expect_value(t, c0s, query.Status.Ok)
	defer query.release(h, c0)
	testing.expect_value(t, query.text_of(c0), "note on a")

	// Mutate through Overlay via query.set_path (`set_path` consumes `root`!) and read back through Overlay_Ref.
	p_arr, ps := query.make_array(h, 1)
	testing.expect_value(t, ps, query.Status.Ok)
	defer query.release(h, p_arr)
	k_a, kas := query.text_value(h, "a")
	testing.expect_value(t, kas, query.Status.Ok)
	testing.expect_value(t, query.append_owned(h, &p_arr, k_a), query.Status.Ok)

	new_root, ss := query.set_path(h, root, p_arr, query.int_value(999))
	root = query.ABSENT
	testing.expect_value(t, ss, query.Status.Ok)
	defer query.release(h, new_root)

	a2, a2s := query.member(h, new_root, "a")
	testing.expect_value(t, a2s, query.Status.Ok)
	defer query.release(h, a2)
	ai2, _ := query.as_i64(a2)
	testing.expect_value(t, ai2, i64(999))

	// Commit overlay and verify untouched bytes & comments are preserved!
	res, cerr := json.commit(ov, .Jsonc, {}, runtime.heap_allocator())
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "{\n  // note on a\n  \"a\": 999,\n  \"b\": [10, 20, 30],\n  \"c\": {\"nested\": \"ok\"}\n}\n")
}

@(test)
overlay_reconcile_preserves_provenance :: proc(t: ^testing.T) {
	testkit.deadline(t)
	th: Test_Heap
	heap_start(&th)
	defer heap_done(t, &th)
	h := &th.h

	src := transmute([]u8)string("{\n  \"keep\": { \"weird\" :  [ 1,  2 ] },\n  \"change\": 10\n}\n")
	doc, err := json.build(src, .Json, {}, runtime.heap_allocator())
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	doc_val, ds := query.document_value(h, doc, owned = false)
	testing.expect_value(t, ds, query.Status.Ok)
	defer query.release(h, doc_val)

	// Construct a new object reusing `keep` (provenance Node_Ref!) and replacing `change` with 20.
	keep_val, ks := query.member(h, doc_val, "keep")
	testing.expect_value(t, ks, query.Status.Ok)
	defer query.release(h, keep_val)

	rebuilt, bs := query.make_object(h, 2)
	testing.expect_value(t, bs, query.Status.Ok)
	defer query.release(h, rebuilt)
	k1, _ := query.text_value(h, "keep")
	k2, _ := query.text_value(h, "change")
	// `object_put` takes ownership of `k1`, `keep_val`, `k2`!
	testing.expect_value(t, query.object_put(h, &rebuilt, k1, keep_val), query.Status.Ok)
	keep_val = query.ABSENT
	testing.expect_value(t, query.object_put(h, &rebuilt, k2, query.int_value(20)), query.Status.Ok)

	// Reconcile into Overlay: `keep` must stay untouched (zero edits on its weird spacing)!
	ov: edit.Overlay
	testing.expect(t, edit.init(&ov, &doc, runtime.heap_allocator()) == nil)
	defer edit.destroy(&ov)

	testing.expect(t, query.reconcile_overlay(h, &ov, rebuilt) == nil)

	res, cerr := json.commit(&ov, .Json, {}, runtime.heap_allocator())
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, string(res.bytes), "{\n  \"keep\": { \"weird\" :  [ 1,  2 ] },\n  \"change\": 20\n}\n")
}

@(test)
overlay_big_int_escaped_strings_patch_cow_and_lifetime :: proc(t: ^testing.T) {
	testkit.deadline(t)
	th: Test_Heap
	heap_start(&th)
	defer heap_done(t, &th)
	h := &th.h

	// 1. Escaped base string read via `.Overlay` MUST decode (`"hi\n\"there\""`), never raw escaped bytes!
	//    Plus `.Big` (>64-bit integer) written into `.Overlay` must NOT UAF and must round-trip cleanly!
	{
		src := transmute([]u8)string("{\"s\": \"hi\\n\\\"there\\\"\", \"n\": 1}\n")
		doc, err := json.build(src, .Json, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)

		root, ov, st := query.overlay_from_doc(h, doc, doc_owned = true)
		testing.expect_value(t, st, query.Status.Ok)

		sv, ss := query.member(h, root, "s")
		testing.expect_value(t, ss, query.Status.Ok)
		testing.expect_value(t, query.text_of(sv), "hi\n\"there\"")
		query.release(h, sv)

		// Write a >64-bit integer `.Big` into `.n` via `set_one`!
		big_src := transmute([]u8)string("123456789012345678901234567890")
		big_doc, berr := json.build(big_src, .Json, {}, runtime.heap_allocator())
		testing.expect(t, berr == nil)
		big_node, bns := query.document_value(h, big_doc, owned = true)
		testing.expect_value(t, bns, query.Status.Ok)
		big_v, bs := query.number_of(h, big_node)
		testing.expect_value(t, bs, query.Status.Ok)
		query.release(h, big_node)
		kn, _ := query.text_value(h, "n")
		defer query.release(h, kn)
		root, st = query.set_one(h, root, kn, query.retain(big_v))
		testing.expect_value(t, st, query.Status.Ok)

		// Read back `.n` from `.Overlay` and verify exact `write_json` + `compare`!
		nv, ns := query.member(h, root, "n")
		testing.expect_value(t, ns, query.Status.Ok)
		buf := make([dynamic]u8, runtime.heap_allocator())
		defer delete(buf)
		testing.expect_value(t, query.write_json(h, &buf, nv), query.Status.Ok)
		testing.expect_value(t, string(buf[:]), "123456789012345678901234567890")
		cmp, cs := query.compare(h, nv, big_v)
		testing.expect_value(t, cs, query.Status.Ok)
		testing.expect_value(t, cmp, 0)
		query.release(h, big_v)
		query.release(h, nv)

		// Commit and verify exact big integer in output JSON!
		res, cerr := json.commit(ov, .Json, {}, runtime.heap_allocator())
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "{\"s\": \"hi\\n\\\"there\\\"\", \"n\": 123456789012345678901234567890}\n")

		// Releasing `root` MUST clear `h.write_fact` / `h.write_fact_data`!
		query.release(h, root)
		testing.expect(t, h.write_fact == nil && h.write_fact_data == nil)
	}

	// 2. `.Overlay` COW aliasing: holding an extra ref prevents in-place mutation of the original overlay!
	{
		src := transmute([]u8)string(`{"a": 1}`)
		doc, err := json.build(src, .Json, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)

		root, ov, st := query.overlay_from_doc(h, doc, doc_owned = true)
		testing.expect_value(t, st, query.Status.Ok)
		alias := query.retain(root)
		defer query.release(h, alias)

		ka, _ := query.text_value(h, "a")
		defer query.release(h, ka)
		mutated, ms := query.set_one(h, root, ka, query.int_value(99))
		testing.expect_value(t, ms, query.Status.Ok)
		defer query.release(h, mutated)

		// `mutated` has `a = 99`, while `alias` AND `ov` remain untouched (`a = 1`, `!ov.dirty`)!
		mv, _ := query.member(h, mutated, "a")
		av, _ := query.member(h, alias, "a")
		defer query.release(h, mv)
		defer query.release(h, av)
		testing.expect_value(t, query.as_f64(mv), f64(99))
		testing.expect_value(t, query.as_f64(av), f64(1))
		testing.expect(t, !ov.dirty)
	}

	// 3. `apply_patch` on `.Overlay` materializes safely without casting `.Overlay` to `^Object_Block`!
	{
		src := transmute([]u8)string(`{"a": 1, "b": [10, 20]}`)
		doc, err := json.build(src, .Json, {}, runtime.heap_allocator())
		testing.expect(t, err == nil)

		root, _, st := query.overlay_from_doc(h, doc, doc_owned = true)
		testing.expect_value(t, st, query.Status.Ok)
		defer query.release(h, root)

		p_src := transmute([]u8)string(`[{"op":"replace","path":"/a","value":7},{"op":"add","path":"/b/1","value":15}]`)
		p_doc, perr := json.build(p_src, .Json, {}, runtime.heap_allocator())
		testing.expect(t, perr == nil)
		patch_v, ps := query.document_value(h, p_doc, owned = true)
		testing.expect_value(t, ps, query.Status.Ok)
		defer query.release(h, patch_v)

		patched, as := query.apply_patch(h, root, patch_v)
		testing.expect_value(t, as, query.Status.Ok)
		defer query.release(h, patched)

		buf := make([dynamic]u8, runtime.heap_allocator())
		defer delete(buf)
		testing.expect_value(t, query.write_json(h, &buf, patched), query.Status.Ok)
		testing.expect_value(t, string(buf[:]), `{"a":7,"b":[10,15,20]}`)
	}
}
