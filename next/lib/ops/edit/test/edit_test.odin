package edit_tests

import "base:runtime"
import "core:mem"
import "core:testing"
import "stury:cbor"
import "stury:dsv"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/query"
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

@(test)
review_fixes_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. TOML out-of-range integer literals via `.Raw` MUST be rejected, while valid min(i64) and floats succeed.
	{
		src := transmute([]u8)string("v = 1\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)
		vn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "v")

		for bad in ([]string{"-9223372036854775809", "18446744073709551616", "99999999999999999999"}) {
			ov: toml.Overlay
			testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
			vh, _ := edit.handle_for_base(&ov, vn)
			testing.expect(t, edit.set(&ov, vh, edit.val_raw(bad)) == nil)
			res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
			edit.destroy_commit_result(&res)
			toml.edit_destroy(&ov)
			testing.expectf(t, cerr != nil, "TOML out-of-range integer %q must be rejected", bad)
		}
		for good in ([]string{"-9223372036854775808", "3.14", "1e5"}) {
			ov: toml.Overlay
			testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
			vh, _ := edit.handle_for_base(&ov, vn)
			testing.expect(t, edit.set(&ov, vh, edit.val_raw(good)) == nil)
			res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
			testing.expectf(t, cerr == nil, "valid TOML scalar %q failed: %v", good, cerr)
			edit.destroy_commit_result(&res)
			toml.edit_destroy(&ov)
		}
	}

	// 2. Duplicate-key reflow detection on `handle_for_base` + `set` (direct, nested, and escaped keys).
	{
		cases := [?]struct {
			src:     string,
			target:  tape.Node_Index,
			want_ok: string,
		}{
			{`{"a": 1, "a": 2}`, 4, `{"a":99}`},
			{`{"a": {"x": 1}, "a": {"x": 2}}`, 8, `{"a":{"x":99}}`},
			{`{"a": 1, "\u0061": 2}`, 4, `{"a":99}`},
		}
		for c in cases {
			doc, err := json.build(transmute([]u8)c.src, .Json, {}, alloc)
			testing.expect(t, err == nil)
			defer tape.destroy_document(&doc)

			ov: json.Overlay
			testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
			defer json.edit_destroy(&ov)

			h, herr := edit.handle_for_base(&ov, c.target)
			testing.expect(t, herr == nil)
			testing.expect(t, edit.set(&ov, h, edit.val_int(99)) == nil)

			res0, cerr0 := json.commit(&ov, .Json, {reflow = false}, alloc)
			edit.destroy_commit_result(&res0)
			ref, is_ref := cerr0.(edit.Refusal)
			testing.expectf(t, is_ref && ref.kind == .Layout_Reflow_Needed, "%s: expected Layout_Reflow_Needed, got %v", c.src, cerr0)

			res1, cerr1 := json.commit(&ov, .Json, {reflow = true}, alloc)
			testing.expectf(t, cerr1 == nil, "%s reflow failed: %v", c.src, cerr1)
			testing.expect_value(t, string(res1.bytes), c.want_ok)
			testing.expect(t, len(res1.rewritten) > 0)
			edit.destroy_commit_result(&res1)
		}

		// Also verify `jq` `.a = 99` on `{"a": 1, "a": 2}` refuses without reflow and deduplicates with reflow.
		{
			doc, derr := json.build(transmute([]u8)string(`{"a": 1, "a": 2}`), .Json, {}, alloc)
			testing.expect(t, derr == nil)
			prog, perrs := jq.compile(`.a = 99`)
			defer jq.destroy_program(prog)
			testing.expect_value(t, len(perrs), 0)

			qh: query.Heap
			query.heap_init(&qh, alloc)
			defer query.heap_destroy(&qh)

			inp, qov, qst := query.overlay_from_doc(&qh, doc, doc_owned = true)
			testing.expect_value(t, qst, query.Status.Ok)

			run: jq.Run
			jq.run_init(&run, prog, &qh, nil)
			defer jq.run_destroy(&run)
			Collect :: struct {
				h:   ^query.Heap,
				val: query.Value,
				n:   int,
			}
			col := Collect{h = &qh}
			sink :: proc(data: rawptr, v: query.Value, _: ^query.Heap) -> bool {
				c := (^Collect)(data)
				if c.n == 0 {
					c.val = query.retain(v)
				}
				c.n += 1
				return true
			}
			end := jq.run_value(&run, inp, sink, &col)
			testing.expect_value(t, end, jq.Run_End.Done)
			testing.expect_value(t, col.n, 1)
			defer query.release(&qh, col.val)
			testing.expect(t, query.reconcile_overlay(&qh, qov, col.val) == nil)

			r0, ce0 := json.commit(qov, .Json, {reflow = false}, alloc)
			edit.destroy_commit_result(&r0)
			ref, is_ref := ce0.(edit.Refusal)
			testing.expectf(t, is_ref && ref.kind == .Layout_Reflow_Needed, "jq .a=99 expected Layout_Reflow_Needed, got %v", ce0)

			r1, ce1 := json.commit(qov, .Json, {reflow = true}, alloc)
			testing.expectf(t, ce1 == nil, "jq .a=99 reflow failed: %v", ce1)
			testing.expect_value(t, string(r1.bytes), `{"a":99}`)
			testing.expect(t, len(r1.rewritten) > 0)
			edit.destroy_commit_result(&r1)
		}
	}

	// 3. `Budget.depth` enforced on `.Raw` nested containers in both JSON and TOML.
	{
		d := tape.DEFAULT_DEPTH - 1
		// JSON: depth DEFAULT_DEPTH - 1 array `[...[1]...]` + `val_raw("[[[1]]]")` exceeds DEFAULT_DEPTH!
		jsrc := make([]u8, 2 * d + 1, alloc)
		defer delete(jsrc, alloc)
		for i in 0 ..< d {
			jsrc[i] = '['
			jsrc[len(jsrc) - 1 - i] = ']'
		}
		jsrc[d] = '1'
		jdoc, jerr := json.build(jsrc, .Json, {}, alloc)
		testing.expect(t, jerr == nil)
		defer tape.destroy_document(&jdoc)
		jov: json.Overlay
		testing.expect(t, json.edit_init(&jov, &jdoc, alloc) == nil)
		defer json.edit_destroy(&jov)
		leaf_h, _ := edit.handle_for_base(&jov, tape.Node_Index(d))
		testing.expect(t, edit.set(&jov, leaf_h, edit.val_raw("[[[1]]]")) == nil)
		jres, jcerr := json.commit(&jov, .Json, {}, alloc)
		edit.destroy_commit_result(&jres)
		jex, is_jex := jcerr.(tape.Exceeded)
		testing.expectf(t, is_jex && jex.kind == .Depth, "JSON depth exceed expected, got %v", jcerr)

		// TOML: depth DEFAULT_DEPTH - 1 array `v=[...[1]...]` + `val_raw("{a={b={c=1}}}")` exceeds DEFAULT_DEPTH!
		// (`v=` adds root table depth 1, so `d - 1` brackets leaves 1 level of headroom.)
		td := d - 1
		tsrc := make([]u8, 2 + 2 * td + 1, alloc)
		defer delete(tsrc, alloc)
		tsrc[0], tsrc[1] = 'v', '='
		for i in 0 ..< td {
			tsrc[2 + i] = '['
			tsrc[len(tsrc) - 1 - i] = ']'
		}
		tsrc[2 + td] = '1'
		tdoc, terr := toml.build(tsrc, .Toml_1_0, {}, alloc)
		testing.expect(t, terr == nil)
		defer tape.destroy_document(&tdoc)
		tov: toml.Overlay
		testing.expect(t, toml.edit_init(&tov, &tdoc, alloc) == nil)
		defer toml.edit_destroy(&tov)
		// Nodes: 0=root, 1=key("v"), 2..2+td-1=arrays, 2+td=leaf `1`.
		tleaf_h, _ := edit.handle_for_base(&tov, tape.Node_Index(2 + td))
		testing.expect(t, edit.set(&tov, tleaf_h, edit.val_raw("{a={b={c=1}}}")) == nil)
		tres, tcerr := toml.commit(&tov, .Toml_1_0, {}, alloc)
		edit.destroy_commit_result(&tres)
		tex, is_tex := tcerr.(tape.Exceeded)
		testing.expectf(t, is_tex && tex.kind == .Depth, "TOML depth exceed expected, got %v", tcerr)
	}

	// 4. Bounded 16 KiB caller allocator succeeds on 1-scalar edit commits for all 4 text composers.
	{
		backing: [16 * 1024]u8
		ba: mem.Arena
		// JSON
		{
			doc, _ := json.build(transmute([]u8)string(`{"a": 1}`), .Json, {}, alloc)
			defer tape.destroy_document(&doc)
			ov: json.Overlay
			_ = json.edit_init(&ov, &doc, alloc)
			defer json.edit_destroy(&ov)
			h, _ := edit.handle_for_base(&ov, 2)
			_ = edit.set(&ov, h, edit.val_raw("2"))
			mem.arena_init(&ba, backing[:])
			res, cerr := json.commit(&ov, .Json, {}, mem.arena_allocator(&ba))
			testing.expectf(t, cerr == nil && string(res.bytes) == `{"a": 2}`, "JSON 16KiB commit failed: %v", cerr)
		}
		// TOML
		{
			doc, _ := toml.build(transmute([]u8)string("a = 1\n"), .Toml_1_0, {}, alloc)
			defer tape.destroy_document(&doc)
			ov: toml.Overlay
			_ = toml.edit_init(&ov, &doc, alloc)
			defer toml.edit_destroy(&ov)
			h, _ := edit.handle_for_base(&ov, 2)
			_ = edit.set(&ov, h, edit.val_raw("2"))
			mem.arena_init(&ba, backing[:])
			res, cerr := toml.commit(&ov, .Toml_1_0, {}, mem.arena_allocator(&ba))
			testing.expectf(t, cerr == nil && string(res.bytes) == "a = 2\n", "TOML 16KiB commit failed: %v", cerr)
		}
		// XML
		{
			doc, _ := xml.build(transmute([]u8)string(`<r><a>1</a></r>`), .Xml, {}, alloc)
			defer tape.destroy_document(&doc)
			ov: xml.Overlay
			_ = xml.edit_init(&ov, &doc, alloc)
			defer xml.edit_destroy(&ov)
			rn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "r")
			an, _ := tape.member(tape.Reader{doc = &doc}, rn, "a")
			h, _ := edit.handle_for_base(&ov, an)
			_ = edit.set(&ov, h, edit.val_raw("2"))
			mem.arena_init(&ba, backing[:])
			res, cerr := xml.commit(&ov, {}, mem.arena_allocator(&ba))
			testing.expectf(t, cerr == nil && string(res.bytes) == `<r><a>2</a></r>`, "XML 16KiB commit failed: %v", cerr)
		}
		// DSV
		{
			doc, _ := dsv.build(transmute([]u8)string("a,b\n1,2\n"), .Csv, {}, alloc)
			defer tape.destroy_document(&doc)
			ov: dsv.Overlay
			_ = dsv.edit_init(&ov, &doc, alloc)
			defer dsv.edit_destroy(&ov)
			row0, _ := tape.element(tape.Reader{doc = &doc}, tape.ROOT, 0)
			cell, _ := tape.member(tape.Reader{doc = &doc}, row0, "b")
			h, _ := edit.handle_for_base(&ov, cell)
			_ = edit.set(&ov, h, edit.val_raw("9"))
			mem.arena_init(&ba, backing[:])
			res, cerr := dsv.commit(&ov, .Csv, {}, mem.arena_allocator(&ba))
			testing.expectf(t, cerr == nil && string(res.bytes) == "a,b\n1,9\n", "DSV 16KiB commit failed: %v", cerr)
		}
	}

	// 5. Non-`.Raw` leaf fast-path edit (`val_int`, `val_string`) keeps `ov.parents == nil` (no `ensure_parents`).
	{
		doc, err := json.build(transmute([]u8)string(`{"a": 1, "b": "old"}`), .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)
		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		ha, _ := edit.handle_for_base(&ov, 2)
		hb, _ := edit.handle_for_base(&ov, 4)
		testing.expect(t, edit.set(&ov, ha, edit.val_int(42)) == nil)
		testing.expect(t, edit.set(&ov, hb, edit.val_string("new")) == nil)
		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"a": 42, "b": "new"}`)
		testing.expect(t, ov.parents == nil)
	}

	// 6. Setting a `.Key` handle via `handle_for_base` + `set` does NOT corrupt JSON output.
	{
		doc, err := json.build(transmute([]u8)string(`{"a": 1}`), .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)
		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		// Node 1 is `.Key` ("a").
		kh, _ := edit.handle_for_base(&ov, 1)
		testing.expect(t, edit.set(&ov, kh, edit.val_int(999)) == nil)
		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"a": 1}`)
	}

	// 7. Bug #10: `Options.budget.depth` enforced during `commit_document` / `splice_document` / `walk_fragment`
	//    for JSON, TOML, XML, and CBOR (`DEFAULT_DEPTH` and explicit small `budget.depth`).
	{
		// JSON: explicit depth=3 fails when inserting nested container of depth 3 under depth 1 (`1 + 3 > 3`).
		jdoc, _ := json.build(transmute([]u8)string(`{"a": 1}`), .Json, {}, alloc)
		defer tape.destroy_document(&jdoc)
		jov: json.Overlay
		_ = json.edit_init(&jov, &jdoc, alloc)
		defer json.edit_destroy(&jov)
		_, _ = edit.set_path(&jov, {tape.Name("a")}, edit.val_raw(`[[[1]]]`))
		_, jres, jerr := json.commit_document(&jov, .Json, {budget = {depth = 3}}, alloc)
		edit.destroy_commit_result(&jres)
		jex, is_jex := jerr.(tape.Exceeded)
		testing.expectf(t, is_jex && jex.kind == .Depth, "JSON splice_document depth exceed expected, got %v", jerr)

		// TOML: explicit depth=3 fails under `commit_document`.
		tdoc, _ := toml.build(transmute([]u8)string("a = 1\n"), .Toml_1_0, {}, alloc)
		defer tape.destroy_document(&tdoc)
		tov: toml.Overlay
		_ = toml.edit_init(&tov, &tdoc, alloc)
		defer toml.edit_destroy(&tov)
		_, _ = edit.set_path(&tov, {tape.Name("a")}, edit.val_raw(`{x={y={z=1}}}`))
		_, tres, terr := toml.commit_document(&tov, .Toml_1_0, {budget = {depth = 3}}, alloc)
		edit.destroy_commit_result(&tres)
		tex, is_tex := terr.(tape.Exceeded)
		testing.expectf(t, is_tex && tex.kind == .Depth, "TOML splice_document depth exceed expected, got %v", terr)

		// XML: explicit depth=4 fails under `commit_document`.
		xdoc, _ := xml.build(transmute([]u8)string(`<r><a>1</a></r>`), .Xml, {}, alloc)
		defer tape.destroy_document(&xdoc)
		xov: xml.Overlay
		_ = xml.edit_init(&xov, &xdoc, alloc)
		defer xml.edit_destroy(&xov)
		_, _ = edit.set_path(&xov, {tape.Name("r"), tape.Name("a")}, edit.val_raw(`<b><c><d>1</d></c></b>`))
		_, xres, xerr := xml.commit_document(&xov, {budget = {depth = 4}}, alloc)
		edit.destroy_commit_result(&xres)
		xex, is_xex := xerr.(tape.Exceeded)
		testing.expectf(t, is_xex && xex.kind == .Depth, "XML splice_document depth exceed expected, got %v", xerr)
	}
}
