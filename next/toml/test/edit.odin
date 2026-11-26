package toml_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"
import "stury:toml"

@(test)
toml_edit_preserves_sections_comments_and_inline_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("# top comment\nname = 'lit' # keep me\ninline = { x = 1, y = 2 }\n\n[server]\nhost = \"localhost\"\nport = 8080\n")
	doc, err := toml.build(src, .Toml_1_0, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: toml.Overlay
	testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
	defer toml.edit_destroy(&ov)

	_, e1 := edit.set_path(&ov, {tape.Name("server"), tape.Name("port")}, edit.val_int(9090))
	testing.expect(t, e1 == nil)
	_, e2 := edit.set_path(&ov, {tape.Name("inline"), tape.Name("z")}, edit.val_int(3))
	testing.expect(t, e2 == nil)

	res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)

	got := string(res.bytes)
	testing.expect(t, strings.contains(got, "# top comment"))
	testing.expect(t, strings.contains(got, "name = 'lit' # keep me"))
	testing.expect(t, strings.contains(got, "port = 9090"))
	testing.expect(t, strings.contains(got, "z = 3"))
}

@(test)
toml_edit_group2_section_before_top_level_line_and_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Group 2: reordering root so `[sec]` is requested before top-level key `a` keeps `a` above `[sec]`!
	{
		src := transmute([]u8)string("a = 1\n\n[sec]\nx = 2\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)
		// Request section (idx 1) before top-level key `a` (idx 0).
		testing.expect(t, edit.reorder(&ov, root_h, {1, 0}) == nil)

		res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		// Must parse back with `a` still in root table and `sec.x == 2`!
		check_doc, berr := toml.build(res.bytes, .Toml_1_0, {}, alloc)
		testing.expect(t, berr == nil)
		defer tape.destroy_document(&check_doc)
		_, pa := tape.member(tape.Reader{doc = &check_doc}, tape.ROOT, "a")
		testing.expect_value(t, pa, tape.Presence.Found)
		sec_n, ps := tape.member(tape.Reader{doc = &check_doc}, tape.ROOT, "sec")
		testing.expect_value(t, ps, tape.Presence.Found)
		_, px := tape.member(tape.Reader{doc = &check_doc}, sec_n, "x")
		testing.expect_value(t, px, tape.Presence.Found)
	}

	// Group 1 refusals: null in TOML, control byte in comment, invalid datetime tag (refused even with reflow=true!).
	{
		src := transmute([]u8)string("a = \"not-a-date\"\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		// Null refusal.
		ov1: toml.Overlay
		testing.expect(t, toml.edit_init(&ov1, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov1)
		_, _ = edit.set_path(&ov1, {tape.Name("a")}, edit.val_null())
		_, e_null := toml.commit(&ov1, .Toml_1_0, {reflow = true}, alloc)
		r1, ok1 := e_null.(edit.Refusal)
		testing.expect(t, ok1 && r1.group == .Format_Impossible && r1.kind == .Unspellable_Value)

		// Control byte in comment refusal.
		ov2: toml.Overlay
		testing.expect(t, toml.edit_init(&ov2, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov2)
		an, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "a")
		ha, _ := edit.handle_for_base(&ov2, an)
		_ = edit.set_fact(&ov2, ha, .Comment, {"bad\x01ctrl"})
		_, e_ctrl := toml.commit(&ov2, .Toml_1_0, {reflow = true}, alloc)
		r2, ok2 := e_ctrl.(edit.Refusal)
		testing.expect(t, ok2 && r2.group == .Format_Impossible && r2.kind == .Fact_No_Place)

		// Invalid datetime tag refusal.
		ov3: toml.Overlay
		testing.expect(t, toml.edit_init(&ov3, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov3)
		ha3, _ := edit.handle_for_base(&ov3, an)
		_ = edit.set_fact(&ov3, ha3, .Tag, {"date-local"})
		_, e_dt := toml.commit(&ov3, .Toml_1_0, {reflow = true}, alloc)
		r3, ok3 := e_dt.(edit.Refusal)
		testing.expect(t, ok3 && r3.group == .Format_Impossible && r3.kind == .Fact_No_Place)
	}
}

@(test)
toml_edit_reflow_multiline_quotes_sections_renames_and_aot :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. Full reflow (`reflow = true` replacing a header table via `toml.write`!) + multiline `"` end escaping + `.@tag = "date"`.
	{
		src := transmute([]u8)string("d = \"2026-01-02\"\ns = \"old\"\n\n[tbl]\nx = 1\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)

		dn, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "d")
		dh, _ := edit.handle_for_base(&ov, dn)
		testing.expect(t, edit.set_fact(&ov, dh, .Tag, {"date"}) == nil)

		sh, _ := edit.set_path(&ov, {tape.Name("s")}, edit.val_string("ends with quote\""))
		testing.expect(t, edit.set_fact(&ov, sh, .Style, {"multiline"}) == nil)

		res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, strings.contains(got, "d = 2026-01-02\n"))
		testing.expect(t, strings.contains(got, "ends with quote\\\"\"\"\""))

		// Verify reflow replacing `[tbl]` with scalar succeeds cleanly!
		_, _ = edit.set_path(&ov, {tape.Name("tbl")}, edit.val_int(99))
		res2, cerr2 := toml.commit(&ov, .Toml_1_0, {reflow = true}, alloc)
		testing.expect(t, cerr2 == nil)
		defer edit.destroy_commit_result(&res2)
		testing.expect(t, strings.contains(string(res2.bytes), "tbl = 99"))
	}

	// 2. Normalized section header matching (`[ a . b ]` and `['c']`), `rename_member`, and multiline inline `#` comment (no double comma!).
	{
		src := transmute([]u8)string("arr = [\n  1, # first\n  2\n]\ninline = { a = 1, b = 2 }\n\n[ a . b ]\nk = 1\n\n['c']\nv = 2\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)

		arr_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "arr")
		arr_h, _ := edit.handle_for_base(&ov, arr_n)
		_, _ = edit.insert_element(&ov, arr_h, -1, edit.val_int(3))

		inl_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "inline")
		inl_h, _ := edit.handle_for_base(&ov, inl_n)
		testing.expect(t, edit.rename_member(&ov, inl_h, "a", "alpha") == nil)

		a_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "a")
		ab_n, _ := tape.member(tape.Reader{doc = &doc}, a_n, "b")
		ab_h, _ := edit.handle_for_base(&ov, ab_n)
		_, _ = edit.insert_member(&ov, ab_h, -1, "k2", edit.val_int(2))

		c_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "c")
		c_h, _ := edit.handle_for_base(&ov, c_n)
		testing.expect(t, edit.rename_member(&ov, c_h, "v", "val") == nil)

		res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, !strings.contains(got, ",,"))
		testing.expect(t, strings.contains(got, "alpha = 1"))
		testing.expect(t, strings.contains(got, "k2 = 2"))
		testing.expect(t, strings.contains(got, "val = 2"))
	}

	// 3. `[[arr]]` AOT deletion also removes its `[arr.sub]` subtable, and insertion respects `ins.at`!
	{
		src := transmute([]u8)string("[[items]]\nname = \"first\"\n\n[items.sub]\nx = 1\n\n[[items]]\nname = \"second\"\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)

		it_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "items")
		it_h, _ := edit.handle_for_base(&ov, it_n)
		testing.expect(t, edit.del_element(&ov, it_h, 0) == nil)

		nv, _ := edit.new_node(&ov, edit.val_string("zero"))
		es := [1]edit.Object_Entry{{key = "name", value = nv}}
		_, _ = edit.insert_element(&ov, it_h, 0, edit.val_object(es[:]))

		res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, !strings.contains(got, "[items.sub]"))
		testing.expect(t, strings.index(got, `name = "zero"`) < strings.index(got, `name = "second"`))
	}
}

@(test)
toml_edit_aot_subtables_implicit_and_dotted_tables :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. AOT `[items.sub]` isolation: editing, inserting, renaming, deleting on `items[1].sub` leaves `items[0].sub` untouched;
	//    inserting scalar/subtable into `items[0]` stays inside `items[0]` (never at EOF inside `[other]`).
	{
		src := transmute([]u8)string("[[items]]\nname = \"zero\"\n[items.sub]\nx = 1\n\n[[items]]\nname = \"one\"\n[items.sub]\nx = 2\ny = 3\n\n[other]\nz = 9\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)

		it_n, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "items")
		it1, _ := tape.element(tape.Reader{doc = &doc}, it_n, 1)
		sub1, _ := tape.member(tape.Reader{doc = &doc}, it1, "sub")
		sub1_h, _ := edit.handle_for_base(&ov, sub1)
		testing.expect(t, edit.del_member(&ov, sub1_h, "y") == nil)
		testing.expect(t, edit.rename_member(&ov, sub1_h, "x", "x_new") == nil)
		_, _ = edit.insert_member(&ov, sub1_h, -1, "added", edit.val_int(77))

		it0, _ := tape.element(tape.Reader{doc = &doc}, it_n, 0)
		it0_h, _ := edit.handle_for_base(&ov, it0)
		_, _ = edit.insert_member(&ov, it0_h, -1, "tag", edit.val_string("zero-tag"))

		spliced, res, cerr := toml.commit_document(&ov, .Toml_1_0, {}, alloc)
		testing.expectf(t, cerr == nil, "AOT subtable commit failed: %v", cerr)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		chk, berr := toml.build(res.bytes, .Toml_1_0, {}, alloc)
		testing.expectf(t, berr == nil, "AOT output invalid TOML:\n%s", string(res.bytes))
		defer tape.destroy_document(&chk)

		r := tape.Reader{doc = &chk}
		c_items, _ := tape.member(r, tape.ROOT, "items")
		c0, _ := tape.element(r, c_items, 0)
		c0_tag, p_tag := tape.member(r, c0, "tag")
		testing.expect_value(t, p_tag, tape.Presence.Found)
		_ = c0_tag
		c0_sub, _ := tape.member(r, c0, "sub")
		c0_x, p0x := tape.member(r, c0_sub, "x")
		testing.expect_value(t, p0x, tape.Presence.Found)
		_ = c0_x

		c1, _ := tape.element(r, c_items, 1)
		c1_sub, _ := tape.member(r, c1, "sub")
		_, p1x := tape.member(r, c1_sub, "x_new")
		_, p1y := tape.member(r, c1_sub, "y")
		_, p1a := tape.member(r, c1_sub, "added")
		testing.expect_value(t, p1x, tape.Presence.Found)
		testing.expect(t, p1y != .Found)
		testing.expect_value(t, p1a, tape.Presence.Found)

		c_other, _ := tape.member(r, tape.ROOT, "other")
		_, p_ot := tape.member(r, c_other, "tag")
		testing.expect(t, p_ot != .Found)
	}

	// 2. Implicit super-table (`[a.b]` present, `[a]` absent) with trailing `[other]`:
	//    batching scalar inserts into `a` emits ONE `[a]` header before `[other]` (never inside `[other]`).
	{
		src := transmute([]u8)string("[a.b]\nx = 1\n\n[other]\ny = 2\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("a"), tape.Name("k1")}, edit.val_int(10))
		_, _ = edit.set_path(&ov, {tape.Name("a"), tape.Name("k2")}, edit.val_int(20))

		res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
		testing.expectf(t, cerr == nil, "implicit super-table commit failed: %v", cerr)
		defer edit.destroy_commit_result(&res)

		chk, berr := toml.build(res.bytes, .Toml_1_0, {}, alloc)
		testing.expectf(t, berr == nil, "implicit output invalid TOML:\n%s", string(res.bytes))
		defer tape.destroy_document(&chk)

		r := tape.Reader{doc = &chk}
		ca, _ := tape.member(r, tape.ROOT, "a")
		_, pk1 := tape.member(r, ca, "k1")
		_, pk2 := tape.member(r, ca, "k2")
		testing.expect_value(t, pk1, tape.Presence.Found)
		testing.expect_value(t, pk2, tape.Presence.Found)
		co, _ := tape.member(r, tape.ROOT, "other")
		_, pok1 := tape.member(r, co, "k1")
		testing.expect(t, pok1 != .Found)
	}

	// 3. Dotted-key table (`a.b = 1` at root AND `[sec]\na.b = 1`) + split dotted table delete/rename.
	{
		src := transmute([]u8)string("a.b = 1\nz = 0\na.c = 2\n\n[sec]\nd.x = 5\n\n[other]\ny = 9\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)
		// Rename/insert on split root dotted table `a` AND insert on `[sec]` dotted table `d`.
		an, _ := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "a")
		ah, _ := edit.handle_for_base(&ov, an)
		_, _ = edit.insert_member(&ov, ah, -1, "k", edit.val_int(3))
		testing.expect(t, edit.del_member(&ov, ah, "c") == nil)
		_, _ = edit.set_path(&ov, {tape.Name("sec"), tape.Name("d"), tape.Name("w")}, edit.val_int(6))

		spliced, res, cerr := toml.commit_document(&ov, .Toml_1_0, {}, alloc)
		testing.expectf(t, cerr == nil, "dotted table commit failed: %v", cerr)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		chk, berr := toml.build(res.bytes, .Toml_1_0, {}, alloc)
		testing.expectf(t, berr == nil, "dotted output invalid TOML:\n%s", string(res.bytes))
		defer tape.destroy_document(&chk)

		r := tape.Reader{doc = &chk}
		ca, _ := tape.member(r, tape.ROOT, "a")
		_, pk := tape.member(r, ca, "k")
		_, pc := tape.member(r, ca, "c")
		_, pz := tape.member(r, tape.ROOT, "z")
		testing.expect_value(t, pk, tape.Presence.Found)
		testing.expect(t, pc != .Found)
		testing.expect_value(t, pz, tape.Presence.Found)

		csec, _ := tape.member(r, tape.ROOT, "sec")
		cd, _ := tape.member(r, csec, "d")
		_, pw := tape.member(r, cd, "w")
		testing.expect_value(t, pw, tape.Presence.Found)

		coth, _ := tape.member(r, tape.ROOT, "other")
		_, pok := tape.member(r, coth, "k")
		_, pow := tape.member(r, coth, "w")
		testing.expect(t, pok != .Found && pow != .Found)
	}

	// 4. Incremental `commit_document` leaf edit on TOML + full-reflow cleanup with prior splices (zero leaks).
	{
		src := transmute([]u8)string("a = 1\n[tbl]\nx = 2\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov1: toml.Overlay
		testing.expect(t, toml.edit_init(&ov1, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov1)
		_, _ = edit.set_path(&ov1, {tape.Name("a")}, edit.val_int(42))
		spliced, res, cerr := toml.commit_document(&ov1, .Toml_1_0, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), "a = 42\n[tbl]\nx = 2\n")

		// Full reflow cleanup after emitting `a = 42` splice and replacing header table `[tbl]`.
		_, _ = edit.set_path(&ov1, {tape.Name("tbl")}, edit.val_int(99))
		res2, cerr2 := toml.commit(&ov1, .Toml_1_0, {reflow = true}, alloc)
		testing.expect(t, cerr2 == nil)
		defer edit.destroy_commit_result(&res2)
		testing.expect(t, strings.contains(string(res2.bytes), "tbl = 99"))
	}

	// 5. TOML reorder on implicit super-table (`!found_sec`) with inserted scalar MUST emit `[a]` header!
	{
		src := transmute([]u8)string("[other]\nz = 9\n\n[a.b]\nx = 1\n")
		doc, err := toml.build(src, .Toml_1_0, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: toml.Overlay
		testing.expect(t, toml.edit_init(&ov, &doc, alloc) == nil)
		defer toml.edit_destroy(&ov)
		an, ap := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "a")
		testing.expect_value(t, ap, tape.Presence.Found)
		ha, herr := edit.handle_for_base(&ov, an)
		testing.expect(t, herr == nil)
		_, _ = edit.set_member(&ov, ha, "k", edit.val_int(2))
		testing.expect(t, edit.reorder(&ov, ha, {1, 0}) == nil)

		res, cerr := toml.commit(&ov, .Toml_1_0, {}, alloc)
		testing.expectf(t, cerr == nil, "implicit super-table reorder failed: %v", cerr)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect_value(t, got, "[other]\nz = 9\n\n[a]\nk = 2\n[a.b]\nx = 1\n")

		parsed, perr := toml.build(res.bytes, .Toml_1_0, {}, alloc)
		testing.expect(t, perr == nil)
		defer tape.destroy_document(&parsed)
		r := tape.Reader{doc = &parsed}
		ca, pa := tape.member(r, tape.ROOT, "a")
		testing.expect_value(t, pa, tape.Presence.Found)
		vk, pk := tape.member(r, ca, "k")
		testing.expect_value(t, pk, tape.Presence.Found)
		testing.expect_value(t, string(tape.span_bytes(&parsed, parsed.nodes[vk].lo, parsed.nodes[vk].n)), "2")
		coth, _ := tape.member(r, tape.ROOT, "other")
		_, pok := tape.member(r, coth, "k")
		testing.expect(t, pok != .Found)

		// Mixed dotted key (`a.y = 1`) + implicit subtable (`[a.b]`) with inserted scalar + reorder requires reflow=true.
		msrc := transmute([]u8)string("a.y = 1\n[a.b]\nx = 1\n")
		mdoc, merr := toml.build(msrc, .Toml_1_0, {}, alloc)
		testing.expect(t, merr == nil)
		defer tape.destroy_document(&mdoc)
		mov: toml.Overlay
		testing.expect(t, toml.edit_init(&mov, &mdoc, alloc) == nil)
		defer toml.edit_destroy(&mov)
		man, map_p := tape.member(tape.Reader{doc = &mdoc}, tape.ROOT, "a")
		testing.expect_value(t, map_p, tape.Presence.Found)
		mha, mherr := edit.handle_for_base(&mov, man)
		testing.expect(t, mherr == nil)
		_, _ = edit.set_member(&mov, mha, "k", edit.val_int(2))
		testing.expect(t, edit.reorder(&mov, mha, {2, 1, 0}) == nil)
		mres, mrcerr := toml.commit(&mov, .Toml_1_0, {reflow = true}, alloc)
		testing.expect(t, mrcerr == nil)
		defer edit.destroy_commit_result(&mres)
		mparsed, mperr := toml.build(mres.bytes, .Toml_1_0, {}, alloc)
		testing.expect(t, mperr == nil)
		tape.destroy_document(&mparsed)
	}
}
