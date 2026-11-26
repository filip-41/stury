package json_tests

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"

@(test)
json_edit_preserves_untargeted_bytes_and_comments :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("{\n  // lead a\n  \"a\": 1, // trail a\n  \"b\":   2,\n  \"c\": [ 10,  20 ],\n}\n")
	doc, err := json.build(src, .Jsonc, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: json.Overlay
	testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
	defer json.edit_destroy(&ov)

	// Edit only `"a"` and append `"d"`: `"b"` spacing (`"b":   2`), `"c"` spacing (`[ 10,  20 ]`), comments, trailing comma stay byte-exact!
	_, e1 := edit.set_path(&ov, {tape.Name("a")}, edit.val_int(42))
	testing.expect(t, e1 == nil)
	_, e2 := edit.set_path(&ov, {tape.Name("d")}, edit.val_string("hi"))
	testing.expect(t, e2 == nil)

	res, cerr := json.commit(&ov, .Jsonc, {}, alloc)
	testing.expect(t, cerr == nil)
	defer edit.destroy_commit_result(&res)

	got := string(res.bytes)
	testing.expect(t, strings.contains(got, "// lead a"))
	testing.expect(t, strings.contains(got, "\"a\": 42, // trail a"))
	testing.expect(t, strings.contains(got, "\"b\":   2,"))
	testing.expect(t, strings.contains(got, "\"c\": [ 10,  20 ],"))
	testing.expect(t, strings.contains(got, "\"d\": \"hi\""))
}

@(test)
json_edit_comment_facts_and_drop_on_strict_json :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("{\n  \"a\": 1,\n  \"b\": 2\n}\n")
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: json.Overlay
	testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
	defer json.edit_destroy(&ov)

	// Facts belong to the document/overlay, even on a plain JSON base!
	a_node, p := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "a")
	testing.expect_value(t, p, tape.Presence.Found)
	ha, herr := edit.handle_for_base(&ov, a_node)
	testing.expect(t, herr == nil)
	testing.expect(t, edit.set_fact(&ov, ha, .Comment, {"added comment"}) == nil)
	testing.expect(t, edit.set_fact(&ov, ha, .Comment_Inline, {"inline note"}) == nil)

	// Committing to `.Jsonc` emits BOTH comments cleanly!
	res_c, err_c := json.commit_as(&ov, .Jsonc, {}, alloc)
	testing.expect(t, err_c == nil)
	defer edit.destroy_commit_result(&res_c)
	testing.expect(t, strings.contains(string(res_c.bytes), "// added comment"))
	testing.expect(t, strings.contains(string(res_c.bytes), "// inline note"))
	testing.expect_value(t, res_c.dropped, tape.Facts{})

	// Committing the same overlay to strict `.Json` drops comments cleanly and reports `dropped`!
	res_j, err_j := json.commit_as(&ov, .Json, {}, alloc)
	testing.expect(t, err_j == nil)
	defer edit.destroy_commit_result(&res_j)
	testing.expect(t, !strings.contains(string(res_j.bytes), "//"))
	testing.expect(t, .Comment in res_j.dropped)
	testing.expect(t, .Comment_Inline in res_j.dropped)
}

@(test)
json_edit_group2_flow_comments_reorder_and_json5_style :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// Group 2: multi-item flow line with comments attached to the preceding item reorders cleanly!
	{
		src := transmute([]u8)string(`[1, /* first */ 2, /* second */ 3]`)
		doc, err := json.build(src, .Jsonc, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)

		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.reorder(&ov, root_h, {2, 0, 1}) == nil)

		res, cerr := json.commit_as(&ov, .Jsonc, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, strings.contains(got, "/* first */"))
		testing.expect(t, strings.contains(got, "/* second */"))
		// Verify semantic order is [3, 1, 2]!
		check_doc, berr := json.build(res.bytes, .Jsonc, {}, alloc)
		testing.expect(t, berr == nil)
		defer tape.destroy_document(&check_doc)
		n0, _ := tape.element(tape.Reader{doc = &check_doc}, tape.ROOT, 0)
		n1, _ := tape.element(tape.Reader{doc = &check_doc}, tape.ROOT, 1)
		n2, _ := tape.element(tape.Reader{doc = &check_doc}, tape.ROOT, 2)
		testing.expect_value(t, string(tape.span_bytes(&check_doc, check_doc.nodes[n0].lo, check_doc.nodes[n0].n)), "3")
		testing.expect_value(t, string(tape.span_bytes(&check_doc, check_doc.nodes[n1].lo, check_doc.nodes[n1].n)), "1")
		testing.expect_value(t, string(tape.span_bytes(&check_doc, check_doc.nodes[n2].lo, check_doc.nodes[n2].n)), "2")
	}

	// JSON5 style inheritance (unquoted keys + single quotes) and Group 1 refusal (NaN in strict JSON).
	{
		src := transmute([]u8)string(`{a: 'hello', b: 2}`)
		doc, err := json.build(src, .Json5, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("c")}, edit.val_int(3))

		res, cerr := json.commit_as(&ov, .Json5, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{a: 'hello', b: 2, c: 3}`)
	}

	// Group 1 refusal: NaN in strict JSON stays refused even under `reflow = true`!
	{
		src := transmute([]u8)string(`{"x": 1}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		nan_bits := u64(0x7FF8_0000_0000_0000)
		_, _ = edit.set_path(&ov, {tape.Name("x")}, edit.val_float(transmute(f64)nan_bits))

		_, cerr := json.commit_as(&ov, .Json, {reflow = true}, alloc)
		ref, is_ref := cerr.(edit.Refusal)
		testing.expect(t, is_ref)
		testing.expect_value(t, ref.kind, edit.Refusal_Kind.Unspellable_Value)
		testing.expect_value(t, ref.group, edit.Refusal_Group.Format_Impossible)
	}
}

@(test)
json_edit_dup_keys_multi_insert_comments_and_target_override :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. Structural delta on object containing duplicate keys triggers reflow cleanly (no panic!).
	{
		src := transmute([]u8)string(`{"a": 1, "a": 2, "b": 3}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.del_member(&ov, root_h, "b") == nil)

		res, cerr := json.commit(&ov, .Json, {reflow = true}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"a":2}`)
	}

	// 2. Multi-insert on empty-after-delete, `/* block */` comment before `,` preserved without dangling comma!
	{
		src := transmute([]u8)string(`[1 /* keep */, 2]`)
		doc, err := json.build(src, .Jsonc, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.del_element(&ov, root_h, 0) == nil)

		res, cerr := json.commit(&ov, .Jsonc, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect(t, strings.contains(string(res.bytes), "/* keep */"))
		testing.expect(t, !strings.contains(string(res.bytes), ","))
	}
	{
		src := transmute([]u8)string(`[1]`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.del_element(&ov, root_h, 0) == nil)
		_, _ = edit.insert_element(&ov, root_h, -1, edit.val_int(10))
		_, _ = edit.insert_element(&ov, root_h, -1, edit.val_int(20))

		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `[10, 20]`)
	}

	// 3. `.Bytes` base64 spelling + `.Raw` validation refuses malformed `.Raw` even on local single-node replace!
	{
		src := transmute([]u8)string(`{"b": 1, "r": 2}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		raw_bytes := [3]u8{'f', 'o', 'o'}
		_, _ = edit.set_path(&ov, {tape.Name("b")}, edit.val_bytes(raw_bytes[:]))

		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect_value(t, string(res.bytes), `{"b": "Zm9v", "r": 2}`)

		// Malformed `.Raw` must be caught by full-document validation!
		_, _ = edit.set_path(&ov, {tape.Name("r")}, edit.val_raw("1, 2"))
		_, bad_err := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, bad_err != nil)
	}

	// 4. Explicit `.Json` target overrides `.Jsonc` base format and strips comments!
	{
		src := transmute([]u8)string("{\n  // drop me\n  \"a\": 1\n}\n")
		doc, err := json.build(src, .Jsonc, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("a")}, edit.val_int(2))

		res, cerr := json.commit(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer edit.destroy_commit_result(&res)
		testing.expect(t, !strings.contains(string(res.bytes), "drop me"))
		testing.expect(t, .Comment in res.dropped)
	}
}

@(test)
json_edit_foot_comment_replace_dup_reflow_and_splice_doc :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. JSONC container replace (`val_object` and `val_raw`) + `.Comment_Foot` emits valid non-overlapping JSONC.
	{
		src := transmute([]u8)string("{\n  \"a\": {\n    \"old\": 1\n    // old foot\n  }\n}\n")
		doc, err := json.build(src, .Jsonc, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		vy, _ := edit.new_node(&ov, edit.val_int(2))
		ents := [1]edit.Object_Entry{{key = "y", value = vy}}
		ha, _ := edit.set_path(&ov, {tape.Name("a")}, edit.val_object(ents[:]))
		testing.expect(t, edit.set_fact(&ov, ha, .Comment_Foot, {"new foot"}, padded = true) == nil)

		spliced, res, cerr := json.commit_document(&ov, .Jsonc, {}, alloc)
		testing.expectf(t, cerr == nil, "val_object + Comment_Foot failed: %v", cerr)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, strings.contains(got, "\"y\": 2"))
		testing.expect(t, strings.contains(got, "// new foot"))
		testing.expect(t, !strings.contains(got, "// old foot"))

		// Also with `.Raw` replacement + `.Comment_Foot`.
		ov2: json.Overlay
		testing.expect(t, json.edit_init(&ov2, &doc, alloc) == nil)
		defer json.edit_destroy(&ov2)
		ha2, _ := edit.set_path(&ov2, {tape.Name("a")}, edit.val_raw("{\n    \"z\": 3\n  }"))
		testing.expect(t, edit.set_fact(&ov2, ha2, .Comment_Foot, {"raw foot"}, padded = true) == nil)
		res2, cerr2 := json.commit(&ov2, .Jsonc, {}, alloc)
		testing.expectf(t, cerr2 == nil, "val_raw + Comment_Foot failed: %v", cerr2)
		defer edit.destroy_commit_result(&res2)
		testing.expect(t, strings.contains(string(res2.bytes), "// raw foot"))
		chk, ck_err := json.build(res2.bytes, .Jsonc, {}, alloc)
		testing.expect(t, ck_err == nil)
		tape.destroy_document(&chk)
	}

	// 2. JSONC duplicate-key reflow + `.Comment_Foot` does NOT produce overlapping splices.
	{
		src := transmute([]u8)string("{\n  \"x\": 1,\n  \"x\": 2\n  // old foot\n}\n")
		doc, err := json.build(src, .Jsonc, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("x")}, edit.val_int(99))
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.set_fact(&ov, root_h, .Comment_Foot, {"new foot"}, padded = true) == nil)

		res, cerr := json.commit(&ov, .Jsonc, {reflow = true}, alloc)
		testing.expectf(t, cerr == nil, "dup-key + Comment_Foot reflow failed: %v", cerr)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect(t, strings.contains(got, "\"x\": 99"))
		testing.expect(t, strings.contains(got, "// new foot"))
		testing.expect(t, len(res.rewritten) > 0)
		chk, ck_err := json.build(res.bytes, .Jsonc, {}, alloc)
		testing.expect(t, ck_err == nil)
		tape.destroy_document(&chk)
	}

	// 3. Multi-splice incremental `commit_document` (zero leak, non-fallback incremental splice parity).
	{
		src := transmute([]u8)string(`{"a": 1, "b": "hi", "c": [1, 2]}`)
		doc, err := json.build(src, .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("a")}, edit.val_int(100))
		_, _ = edit.set_path(&ov, {tape.Name("b")}, edit.val_string("world"))

		spliced, res, cerr := json.commit_document(&ov, .Json, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		fresh, ferr := json.build(res.bytes, .Json, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
		testing.expect_value(t, string(res.bytes), `{"a": 100, "b": "world", "c": [1, 2]}`)
	}

	// 4. JSONC reorder fallback to `emit_bracket_reflow` MUST NOT duplicate head/inline `.Comment` splices.
	{
		src := transmute([]u8)string("{\n  // old head\n  \"a\": {} // old inline\n}\n")
		doc, err := json.build(src, .Jsonc, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: json.Overlay
		testing.expect(t, json.edit_init(&ov, &doc, alloc) == nil)
		defer json.edit_destroy(&ov)
		an, ap := tape.member(tape.Reader{doc = &doc}, tape.ROOT, "a")
		testing.expect_value(t, ap, tape.Presence.Found)
		ha, herr := edit.handle_for_base(&ov, an)
		testing.expect(t, herr == nil)
		testing.expect(t, edit.set_fact(&ov, ha, .Comment, {"new head"}, padded = true) == nil)
		testing.expect(t, edit.set_fact(&ov, ha, .Comment_Inline, {"new inline"}, padded = true) == nil)
		testing.expect(t, edit.set_fact(&ov, ha, .Comment_Foot, {"foot note"}, padded = true) == nil)
		_, _ = edit.set_member(&ov, ha, "x", edit.val_int(1))
		_, _ = edit.set_member(&ov, ha, "y", edit.val_int(2))
		testing.expect(t, edit.reorder(&ov, ha, {1, 0}) == nil)

		res, cerr := json.commit(&ov, .Jsonc, {reflow = true}, alloc)
		testing.expectf(t, cerr == nil, "reorder reflow with comments failed: %v", cerr)
		defer edit.destroy_commit_result(&res)
		got := string(res.bytes)
		testing.expect_value(t, strings.count(got, "// new head"), 1)
		testing.expect_value(t, strings.count(got, "// new inline"), 1)
		testing.expect_value(t, strings.count(got, "// foot note"), 1)
		testing.expect(t, strings.contains(got, "\"y\":2"))
		testing.expect(t, strings.contains(got, "\"x\":1"))
		chk, ck_err := json.build(res.bytes, .Jsonc, {}, alloc)
		testing.expect(t, ck_err == nil)
		defer tape.destroy_document(&chk)
		ca, pa := tape.member(tape.Reader{doc = &chk}, tape.ROOT, "a")
		testing.expect_value(t, pa, tape.Presence.Found)
		c, cp, cerr2 := tape.children(tape.Reader{doc = &chk}, ca, alloc)
		testing.expect(t, cerr2 == nil && cp == .Found)
		defer tape.destroy_children(&c)
		k0, v0, p0 := tape.next_child(tape.Reader{doc = &chk}, &c)
		k1, v1, p1 := tape.next_child(tape.Reader{doc = &chk}, &c)
		testing.expect(t, p0 == .Found && p1 == .Found)
		testing.expect_value(t, string(tape.span_bytes(&chk, chk.nodes[k0].lo, chk.nodes[k0].n)), "y")
		testing.expect_value(t, string(tape.span_bytes(&chk, chk.nodes[v0].lo, chk.nodes[v0].n)), "2")
		testing.expect_value(t, string(tape.span_bytes(&chk, chk.nodes[k1].lo, chk.nodes[k1].n)), "x")
		testing.expect_value(t, string(tape.span_bytes(&chk, chk.nodes[v1].lo, chk.nodes[v1].n)), "1")
	}
}
