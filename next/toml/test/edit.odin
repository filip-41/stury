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
