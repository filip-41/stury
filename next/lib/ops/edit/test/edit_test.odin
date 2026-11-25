package edit_tests

import "base:runtime"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"
import "stury:toml"
import "stury:xml"

@(private = "file")
docs_semantically_equal :: proc(t: ^testing.T, a, b: ^tape.Document, label: string) {
	testing.expectf(t, len(a.nodes) == len(b.nodes), "%s: node count mismatch: spliced=%d fresh=%d", label, len(a.nodes), len(b.nodes))
	if len(a.nodes) != len(b.nodes) {
		return
	}
	for i in 0 ..< len(a.nodes) {
		na, nb := a.nodes[i], b.nodes[i]
		testing.expectf(t, na.kind == nb.kind && na.role == nb.role && na.lo == nb.lo && na.n == nb.n && na.spelling == nb.spelling,
			"%s: node[%d] mismatch: spliced=%v fresh=%v", label, i, na, nb)
	}
	testing.expectf(t, len(a.facts) == len(b.facts), "%s: fact count mismatch: spliced=%d fresh=%d", label, len(a.facts), len(b.facts))
	for i in 0 ..< min(len(a.facts), len(b.facts)) {
		fa, fb := a.facts[i], b.facts[i]
		testing.expectf(t, fa == fb, "%s: fact[%d] mismatch: spliced=%v fresh=%v", label, i, fa, fb)
	}
	testing.expectf(t, a.root_close == b.root_close, "%s: root_close mismatch: spliced=%d fresh=%d", label, a.root_close, b.root_close)
}

@(test)
overlay_handle_stability_and_no_ancestor_copy :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string(`{"a": {"b": {"c": 1, "d": 2}}, "big": {"k1": 1, "k2": 2, "k3": 3, "k4": 4}}`)
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: edit.Overlay
	testing.expect(t, edit.init(&ov, &doc, alloc) == nil)
	defer edit.destroy(&ov)

	// Deep edit a.b.c = 10 -> verify stable handle across successive edits and zero ancestor member list copying!
	h1, e1 := edit.set_path(&ov, {tape.Name("a"), tape.Name("b"), tape.Name("c")}, edit.val_int(10))
	testing.expect(t, e1 == nil)
	testing.expect(t, h1 != edit.NO_HANDLE)

	// Ancestors (`root`, `a`, `b`) must stay `.Ancestor` with ZERO copied member lists!
	rn, rok := edit.get_node(&ov, ov.root)
	testing.expect(t, rok)
	testing.expect_value(t, rn.state, edit.Node_State.Ancestor)
	testing.expect_value(t, len(rn.members), 0)
	testing.expect(t, rn.delta == nil)

	// Successive edit on the same node keeps the EXACT same generational Handle!
	h2, e2 := edit.set_path(&ov, {tape.Name("a"), tape.Name("b"), tape.Name("c")}, edit.val_int(20))
	testing.expect(t, e2 == nil)
	testing.expect_value(t, h1, h2)

	// Fact override updates `Overlay.present` cache.
	testing.expect(t, .Comment not_in ov.present)
	testing.expect(t, edit.set_fact(&ov, h1, .Comment, {"deep note"}) == nil)
	testing.expect(t, .Comment in ov.present)

	// Verify reading back the value and fact through Overlay API.
	n1, ok1 := edit.get_node(&ov, h1)
	testing.expect(t, ok1)
	testing.expect_value(t, n1.val.i, i64(20))
	fo, fok := edit.find_fact_override(&ov, h1, .Comment)
	testing.expect(t, fok && len(fo.values) == 1 && fo.values[0] == "deep note")
}

@(test)
overlay_refuses_partial_document :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string(`{"a": 1, "b": 2}`)
	dem, derr := tape.demand_of({{tape.Name("a")}}, {.Whole}, nil, false, alloc)
	testing.expect(t, derr == nil)
	defer tape.destroy_demand(&dem)
	pdoc, perr := json.scan(src, &dem, .Json, {}, {}, alloc)
	testing.expect(t, perr == nil)
	defer tape.destroy_document(&pdoc)

	ov: edit.Overlay
	ierr := edit.init(&ov, &pdoc, alloc)
	ref, is_ref := ierr.(edit.Refusal)
	testing.expect(t, is_ref)
	testing.expect_value(t, ref.kind, edit.Refusal_Kind.Partial_Document)
	testing.expect_value(t, ref.group, edit.Refusal_Group.Format_Impossible)
}

@(test)
walk_fragment_splice_parity_all_five_formats :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. JSON: scalar replacement + container replacement spliced vs fresh build.
	{
		src := transmute([]u8)string("{\n  \"a\": 1,\n  \"b\": \"old\",\n  \"c\": [10, 20, 30]\n}\n")
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		_, e1 := edit.set_path(&ov, {tape.Name("b")}, edit.val_string("updated_longer_string"))
		testing.expect(t, e1 == nil)
		_, e2 := edit.set_path(&ov, {tape.Name("c"), tape.Index(1)}, edit.val_int(9999))
		testing.expect(t, e2 == nil)

		spliced, res, cerr := json.commit_document(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := json.build(res.bytes, .Json, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		docs_semantically_equal(t, &spliced, &fresh, "json splice")
	}

	// 2. TOML: inline scalar edit spliced vs fresh build.
	{
		src := transmute([]u8)string("title = \"hello\"\ncount = 1\n[sec]\nflag = false\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)
		_, e1 := edit.set_path(&ov, {tape.Name("count")}, edit.val_int(12345))
		testing.expect(t, e1 == nil)

		spliced, res, cerr := toml.commit_document(&ov, .Toml_1_0, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := toml.build(res.bytes, .Toml_1_0, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		docs_semantically_equal(t, &spliced, &fresh, "toml splice")
	}

	// 3. XML: element text edit spliced vs fresh build.
	{
		src := transmute([]u8)string(`<root><a>one</a><b>two</b></root>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)
		_, e1 := edit.set_path(&ov, {tape.Name("root"), tape.Name("a")}, edit.val_string("ONE_UPDATED"))
		testing.expect(t, e1 == nil)

		spliced, res, cerr := xml.commit_document(&ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := xml.build(res.bytes, .Xml, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		docs_semantically_equal(t, &spliced, &fresh, "xml splice")
	}

	// 4. DSV (CSV): cell edit spliced vs fresh build.
	{
		src := transmute([]u8)string("name,score\nalice,10\nbob,20\n")
		doc, err := dsv.build(src, .Csv, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: dsv.Overlay
		testing.expect(t, dsv.edit_init(&ov, &doc, alloc) == nil)
		defer dsv.edit_destroy(&ov)
		_, e1 := edit.set_path(&ov, {tape.Index(0), tape.Name("score")}, edit.val_string("999"))
		testing.expect(t, e1 == nil)

		spliced, res, cerr := dsv.commit_document(&ov, .Csv, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := dsv.build(res.bytes, .Csv, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		docs_semantically_equal(t, &spliced, &fresh, "dsv splice")
	}

	// 5. CBOR: map value replacement spliced vs fresh build.
	{
		// {"a": 1, "b": 2}
		src := []u8{0xa2, 0x61, 'a', 0x01, 0x61, 'b', 0x02}
		doc, err := cbor.build(src, .Cbor, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: cbor.Overlay
		testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
		defer cbor.edit_destroy(&ov)
		_, e1 := edit.set_path(&ov, {tape.Name("a")}, edit.val_int(1000))
		testing.expect(t, e1 == nil)

		spliced, res, cerr := cbor.commit_document(&ov, .Cbor, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := cbor.build(res.bytes, .Cbor, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		docs_semantically_equal(t, &spliced, &fresh, "cbor splice")
	}
}

@(test)
refusal_groups_and_reflow_rewritten_ranges :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Group 1 refusal (invalid XML comment containing `--`) MUST remain refused even with `reflow = true`.
	{
		src := transmute([]u8)string(`<r><a/></r>`)
		doc, err := xml.build(src, .Xml, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: xml.Overlay
		testing.expect(t, xml.edit_init(&ov, &doc, alloc) == nil)
		defer xml.edit_destroy(&ov)

		root_h, _ := edit.ensure_root(&ov)
		_, r_base, r_ok := edit.lookup_member(&ov, root_h, "r")
		testing.expect(t, r_ok)
		r_h, _ := edit.handle_for_base(&ov, r_base)
		_, a_base, a_ok := edit.lookup_member(&ov, r_h, "a")
		testing.expect(t, a_ok)
		a_h, _ := edit.handle_for_base(&ov, a_base)
		testing.expect(t, edit.set_fact(&ov, a_h, .Comment, {"bad -- comment"}) == nil)

		res, cerr := xml.commit(&ov, {reflow = true}, alloc)
		defer edit.destroy_commit_result(&res)
		ref, is_ref := cerr.(edit.Refusal)
		testing.expect(t, is_ref)
		testing.expect_value(t, ref.group, edit.Refusal_Group.Format_Impossible)
	}

	// Group 2 layout refusal (duplicate key in JSON object when editing) refused by default,
	// accepted under `reflow = true` with `rewritten` reporting only the smallest enclosing range!
	{
		src := transmute([]u8)string("{\n  \"keep\": { \"raw\" :  true },\n  \"dup\": {\"x\": 1, \"x\": 2}\n}\n")
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		_, e1 := edit.set_path(&ov, {tape.Name("dup"), tape.Name("x")}, edit.val_int(9))
		testing.expect(t, e1 == nil)

		// Without reflow -> Group 2 Layout_Conflict refusal.
		res0, cerr0 := json.commit(&ov, .Json, {reflow = false}, alloc)
		defer edit.destroy_commit_result(&res0)
		ref, is_ref := cerr0.(edit.Refusal)
		testing.expect(t, is_ref)
		testing.expect_value(t, ref.group, edit.Refusal_Group.Layout_Conflict)

		// With reflow -> succeeds, keeps `"keep": { "raw" :  true }` byte-exact, and reports `rewritten`!
		res1, cerr1 := json.commit(&ov, .Json, {reflow = true}, alloc)
		testing.expect(t, cerr1 == nil)
		defer edit.destroy_commit_result(&res1)
		testing.expect(t, len(res1.rewritten) > 0)
		testing.expect_value(t, string(res1.bytes), "{\n  \"keep\": { \"raw\" :  true },\n  \"dup\": {\"x\":9}\n}\n")
	}
}

@(test)
overlay_chained_container_deltas_and_splice_fixes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. del -> set on a base key must restore base member rather than duplicating in `inserted_members`,
	//    and `container_len` must match `effective_members`.
	{
		src := transmute([]u8)string(`{"a": 1, "b": 2, "c": 3}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)

		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.del_member(&ov, root_h, "b") == nil)
		testing.expect_value(t, edit.container_len(&ov, root_h), 2)
		_, serr := edit.set_member(&ov, root_h, "b", edit.val_int(22))
		testing.expect(t, serr == nil)
		testing.expect_value(t, edit.container_len(&ov, root_h), 3)

		rn, _ := edit.get_node(&ov, root_h)
		testing.expect(t, rn.delta == nil || len(rn.delta.inserted_members) == 0)

		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"a": 1, "b": 22, "c": 3}`)
	}

	// 2. Chained renames (`a -> b; b -> c`), swaps (`a -> b; b -> a`), and del after rename.
	{
		src := transmute([]u8)string(`{"a": 1, "b": 2}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)

		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.rename_member(&ov, root_h, "a", "x") == nil)
		testing.expect(t, edit.rename_member(&ov, root_h, "x", "z") == nil)
		testing.expect(t, edit.del_member(&ov, root_h, "z") == nil)
		testing.expect_value(t, edit.container_len(&ov, root_h), 1)

		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"b": 2}`)
	}

	// 3. Swap renames (`a -> b`, `b -> a` via temp) + `.Base_Ref` -> `.Container_Delta` without aliasing `ov.by_base`.
	{
		src := transmute([]u8)string(`{"a": {"k": 1}, "b": 2}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)

		root_h, _ := edit.ensure_root(&ov)
		_, a_base, a_ok := edit.lookup_member(&ov, root_h, "a")
		testing.expect(t, a_ok)
		// Insert a `.Base_Ref` copy of `a` under `"copy"`, then mutate `"copy"` via Container_Delta!
		copy_h, cerr0 := edit.insert_member(&ov, root_h, -1, "copy", edit.val_base_ref(a_base))
		testing.expect(t, cerr0 == nil)
		testing.expect(t, edit.del_member(&ov, copy_h, "k") == nil)
		// Original `"a"` must still have `"k"`!
		a_h, _ := edit.handle_for_base(&ov, a_base)
		_, _, k_still := edit.lookup_member(&ov, a_h, "k")
		testing.expect(t, k_still)
		testing.expect_value(t, edit.container_len(&ov, copy_h), 0)
	}

	// 4. Stale `ov.by_base` descendants pruned when base container is replaced, and `order` updated on insert/del.
	{
		src := transmute([]u8)string(`{"box": {"inner": 1}, "arr": [10, 20, 30]}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)

		_, _ = edit.set_path(&ov, {tape.Name("box"), tape.Name("inner")}, edit.val_int(99))
		box_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "box")
		inner_n, _ := tape.member(tape.Reader{doc = &doc}, box_n, "inner")
		_, had_inner := ov.by_base[inner_n]
		testing.expect(t, had_inner)
		// Replace whole `box` with scalar 5 -> `inner_n` must be pruned from `ov.by_base`!
		_, _ = edit.set_path(&ov, {tape.Name("box")}, edit.val_int(5))
		_, still_inner := ov.by_base[inner_n]
		testing.expect(t, !still_inner)

		// Reorder `arr` then delete index 1 and insert 99 -> `order` stays valid and commits cleanly!
		arr_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "arr")
		arr_h, _ := edit.handle_for_base(&ov, arr_n)
		testing.expect(t, edit.reorder(&ov, arr_h, {2, 1, 0}) == nil)
		testing.expect(t, edit.del_element(&ov, arr_h, 1) == nil)
		_, _ = edit.insert_element(&ov, arr_h, -1, edit.val_int(99))

		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"box": 5, "arr": [30, 10, 99]}`)
	}

	// 5. `splice_document` fixes: deleted CBOR `.Tag` (no ghost tag!), JSONC `.Comment_Inline` shifted, XML `.Object` `Node.lo` parity!
	{
		// CBOR deleted `.Tag` must NOT leave a ghost tag in spliced `doc.facts`!
		c_src := []u8{0xa1, 0x61, 'a', 0xd8, 0x18, 0x41, 0x05}
		c_doc, c_err := cbor.build(c_src, .Cbor, {}, alloc)
		testing.expect(t, c_err == nil)
		defer tape.destroy_document(&c_doc)

		c_ov: cbor.Overlay
		testing.expect(t, cbor.edit_init(&c_ov, &c_doc, alloc) == nil)
		defer cbor.edit_destroy(&c_ov)
		an, _ := tape.member(tape.Reader{doc = &c_doc}, tape.ROOT, "a")
		ah, _ := edit.handle_for_base(&c_ov, an)
		testing.expect(t, edit.del_fact(&c_ov, ah, .Tag) == nil)

		spliced, res, cerr := cbor.commit_document(&c_ov, .Cbor, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, len(spliced.facts), 0)
		testing.expect(t, .Tag not_in spliced.present)
	}
	{
		// JSONC `.Comment_Inline` after a length-changing value edit shifts to exact offset!
		j_src := transmute([]u8)string("{\n  \"a\": 1, // tail a\n  \"b\": 2\n}\n")
		j_doc, j_err := json.build(j_src, .Jsonc, {}, alloc)
		testing.expect(t, j_err == nil)
		defer tape.destroy_document(&j_doc)

		j_ov: json.Overlay
		testing.expect(t, json.edit_init(&j_ov, &j_doc, alloc) == nil)
		defer json.edit_destroy(&j_ov)
		_, _ = edit.set_path(&j_ov, {tape.Name("a")}, edit.val_int(1234567))

		spliced, res, cerr := json.commit_document(&j_ov, .Jsonc, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := json.build(res.bytes, .Jsonc, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.facts), len(fresh.facts))
		for i in 0 ..< len(fresh.facts) {
			testing.expect_value(t, spliced.facts[i].lo, fresh.facts[i].lo)
			testing.expect_value(t, spliced.facts[i].n, fresh.facts[i].n)
			testing.expect_value(t, spliced.facts[i].kind, fresh.facts[i].kind)
		}
	}
	{
		// XML `walk_fragment` replacing an element's `.Object` content preserves exact `Node.lo` parity!
		x_src := transmute([]u8)string(`<root><a id="1"><x>old</x></a><b>keep</b></root>`)
		x_doc, x_err := xml.build(x_src, .Xml, {}, alloc)
		testing.expect(t, x_err == nil)
		defer tape.destroy_document(&x_doc)

		x_ov: xml.Overlay
		testing.expect(t, xml.edit_init(&x_ov, &x_doc, alloc) == nil)
		defer xml.edit_destroy(&x_ov)
		yk, _ := edit.new_node(&x_ov, edit.val_string("new"))
		entries := [1]edit.Object_Entry{{key = "y", value = yk}}
		_, _ = edit.set_path(&x_ov, {tape.Name("root"), tape.Name("a")}, edit.val_object(entries[:]))

		spliced, res, cerr := xml.commit_document(&x_ov, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := xml.build(res.bytes, .Xml, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
		for i in 0 ..< len(fresh.nodes) {
			testing.expect_value(t, spliced.nodes[i].kind, fresh.nodes[i].kind)
			testing.expect_value(t, spliced.nodes[i].lo, fresh.nodes[i].lo)
			testing.expect_value(t, spliced.nodes[i].n, fresh.nodes[i].n)
		}
	}
}
