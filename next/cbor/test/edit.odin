package cbor_tests

import "base:runtime"
import "core:bytes"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:testkit"

@(test)
cbor_edit_preserves_untouched_subitems_verbatim :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	// {"a": 1, "raw": [2, 3]} where "raw" uses non-minimal 2-byte encoding for 2 (0x18 0x02) -> must stay verbatim!
	src := []u8{0xa2, 0x61, 'a', 0x01, 0x63, 'r', 'a', 'w', 0x82, 0x18, 0x02, 0x03}
	doc, err := cbor.build(src, .Cbor, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: cbor.Overlay
	testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
	defer cbor.edit_destroy(&ov)

	_, e1 := edit.set_path(&ov, {tape.Name("a")}, edit.val_int(42))
	testing.expect(t, e1 == nil)

	spliced, res, cerr := cbor.commit_document(&ov, .Cbor, {}, alloc)
	testing.expect(t, cerr == nil)
	defer tape.destroy_document(&spliced)
	defer edit.destroy_commit_result(&res)

	// Expected: 0xa2, "a", 42 (0x18 0x2a), "raw", untouched [0x82, 0x18, 0x02, 0x03]
	want := []u8{0xa2, 0x61, 'a', 0x18, 0x2a, 0x63, 'r', 'a', 'w', 0x82, 0x18, 0x02, 0x03}
	testing.expectf(t, bytes.equal(res.bytes, want), "got %x, want %x", res.bytes, want)

	fresh, ferr := cbor.build(res.bytes, .Cbor, {}, alloc)
	testing.expect(t, ferr == nil)
	defer tape.destroy_document(&fresh)
	testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
}

@(test)
cbor_edit_tag_and_deterministic_sort :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	// {"bb": 1, "a": h'02'}
	src := []u8{0xa2, 0x62, 'b', 'b', 0x01, 0x61, 'a', 0x41, 0x02}
	doc, err := cbor.build(src, .Cbor, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	// 1. Add tag 24 (embedded CBOR on byte string) on "a" and commit as Deterministic ("a" < "bb").
	ov: cbor.Overlay
	testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
	defer cbor.edit_destroy(&ov)

	root_h, _ := edit.ensure_root(&ov)
	_, a_base, a_ok := edit.lookup_member(&ov, root_h, "a")
	testing.expect(t, a_ok)
	a_h, ae := edit.handle_for_base(&ov, a_base)
	testing.expect(t, ae == nil)
	testing.expect(t, edit.set_fact(&ov, a_h, .Tag, {"24"}) == nil)

	spliced, res, cerr := cbor.commit_document(&ov, .Deterministic, {}, alloc)
	testing.expectf(t, cerr == nil, "cerr = %v", cerr)
	defer tape.destroy_document(&spliced)
	defer edit.destroy_commit_result(&res)

	// Deterministic: "a" first with tag 24 (0xd8 0x18) before h'02' (0x41 0x02), then "bb" -> 0x01.
	want := []u8{0xa2, 0x61, 'a', 0xd8, 0x18, 0x41, 0x02, 0x62, 'b', 'b', 0x01}
	testing.expectf(t, bytes.equal(res.bytes, want), "got %x, want %x", res.bytes, want)

	fresh, ferr := cbor.build(res.bytes, .Deterministic, {}, alloc)
	testing.expect(t, ferr == nil)
	defer tape.destroy_document(&fresh)
	testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
	testing.expect_value(t, len(spliced.facts), len(fresh.facts))
}

@(test)
cbor_edit_group1_invalid_tag_refusal :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()
	src := []u8{0x01}
	doc, err := cbor.build(src, .Cbor, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	ov: cbor.Overlay
	testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
	defer cbor.edit_destroy(&ov)
	root_h, _ := edit.ensure_root(&ov)
	testing.expect(t, edit.set_fact(&ov, root_h, .Tag, {"not_a_uint"}) == nil)

	res, cerr := cbor.commit(&ov, .Cbor, {reflow = true}, alloc)
	defer edit.destroy_commit_result(&res)
	ref, is_ref := cerr.(edit.Refusal)
	testing.expect(t, is_ref)
	testing.expect_value(t, ref.group, edit.Refusal_Group.Format_Impossible)
}

@(test)
cbor_edit_f16_subnormal_nested_sorted_upgrade_and_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. Binary16 subnormal `5.960464477539063e-8` encodes as 3-byte `f9 00 01` in `.Preferred`!
	{
		src := []u8{0xa1, 0x61, 'f', 0x00}
		doc, err := cbor.build(src, .Preferred, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: cbor.Overlay
		testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
		defer cbor.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("f")}, edit.val_float(5.960464477539063e-8))

		res, cerr := cbor.commit(&ov, .Preferred, {}, alloc)
		testing.expectf(t, cerr == nil, "cerr = %v", cerr)
		defer edit.destroy_commit_result(&res)
		want := []u8{0xa1, 0x61, 'f', 0xf9, 0x00, 0x01}
		testing.expectf(t, bytes.equal(res.bytes, want), "got %x, want %x", res.bytes, want)
	}

	// 2. Nested array inside a `.Deterministic` sorted map + cross-spec `.Cbor` -> `.Deterministic` upgrade!
	{
		// {"bb": [1, 2], "a": 0x18 0x01 (non-minimal 1)}
		src := []u8{0xa2, 0x62, 'b', 'b', 0x82, 0x01, 0x02, 0x61, 'a', 0x18, 0x01}
		doc, err := cbor.build(src, .Cbor, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: cbor.Overlay
		testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
		defer cbor.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("bb"), tape.Index(1)}, edit.val_int(9))

		spliced, res, cerr := cbor.commit_document(&ov, .Deterministic, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		// Deterministic: "a": 0x01 (preferred!), "bb": [1, 9]
		want := []u8{0xa2, 0x61, 'a', 0x01, 0x62, 'b', 'b', 0x82, 0x01, 0x09}
		testing.expectf(t, bytes.equal(res.bytes, want), "got %x, want %x", res.bytes, want)

		fresh, ferr := cbor.build(res.bytes, .Deterministic, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
	}

	// 3. `validate_order` refuses invalid permutation on CBOR container!
	{
		src := []u8{0x82, 0x01, 0x02}
		doc, err := cbor.build(src, .Cbor, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: cbor.Overlay
		testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
		defer cbor.edit_destroy(&ov)
		root_h, _ := edit.ensure_root(&ov)
		testing.expect(t, edit.reorder(&ov, root_h, {0, 0}) == nil)

		_, cerr := cbor.commit(&ov, .Cbor, {}, alloc)
		ref, is_ref := cerr.(edit.Refusal)
		testing.expect(t, is_ref && ref.kind == .Bad_Order)
	}

	// 4. Multi-edit incremental `commit_document` (zero leak, exact parity) + `walk_fragment` explicit depth limit!
	{
		src := []u8{0xa2, 0x61, 'a', 0x01, 0x61, 'b', 0x02}
		doc, err := cbor.build(src, .Cbor, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		ov: cbor.Overlay
		testing.expect(t, cbor.edit_init(&ov, &doc, alloc) == nil)
		defer cbor.edit_destroy(&ov)
		_, _ = edit.set_path(&ov, {tape.Name("a")}, edit.val_int(99))
		_, _ = edit.set_path(&ov, {tape.Name("b")}, edit.val_string("ok"))

		spliced, res, cerr := cbor.commit_document(&ov, .Cbor, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		fresh, ferr := cbor.build(res.bytes, .Cbor, {}, alloc)
		testing.expect(t, ferr == nil)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))

		// Explicit `budget.depth` exceeded in CBOR `commit_document`: root depth 1 + nested raw array depth 3 = 4 > 3.
		ov2: cbor.Overlay
		testing.expect(t, cbor.edit_init(&ov2, &doc, alloc) == nil)
		defer cbor.edit_destroy(&ov2)
		a2, _ := edit.new_node(&ov2, edit.val_int(1))
		inner1, _ := edit.new_node(&ov2, edit.val_array({a2}))
		inner2, _ := edit.new_node(&ov2, edit.val_array({inner1}))
		_, _ = edit.set_path(&ov2, {tape.Name("a")}, edit.val_array({inner2}))
		_, res2, derr := cbor.commit_document(&ov2, .Cbor, {budget = {depth = 3}}, alloc)
		edit.destroy_commit_result(&res2)
		ex, is_ex := derr.(tape.Exceeded)
		testing.expectf(t, is_ex && ex.kind == .Depth, "CBOR commit_document depth exceed expected, got %v", derr)
	}
}
