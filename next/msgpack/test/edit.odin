package msgpack_tests

import "base:runtime"
import "core:bytes"
import "core:testing"
import "stury:cbor"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:msgpack"
import "stury:testkit"

// Byte-preserving MessagePack overlay editing tests: verbatim copy, `.Msgpack -> .Compact` upgrades
// (including int/bin map keys), `.Tag` ext/-1/datetime overrides, structural deltas, `.Base_Ref`, `.Bytes`,
// `.Raw`, reorder validation, incremental `commit_document`, depth limits, and OOM sweep.

@(test)
msgpack_edit_preserves_untouched_and_upgrades_compact :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. {"a": 1, "raw": [cc 0x02 (non-compact!), 3]} -> editing "a" preserves "raw" bytes verbatim under `.Msgpack`.
	src := []u8{0x82, 0xa1, 'a', 0x01, 0xa3, 'r', 'a', 'w', 0x92, 0xcc, 0x02, 0x03}
	doc, err := msgpack.build(src, .Msgpack, {}, alloc)
	testing.expect_value(t, err, nil)
	defer tape.destroy_document(&doc)

	ov: msgpack.Overlay
	testing.expect(t, msgpack.edit_init(&ov, &doc, alloc) == nil)
	defer msgpack.edit_destroy(&ov)
	_, e1 := edit.set_path(&ov, {tape.Name("a")}, edit.val_int(42))
	testing.expect(t, e1 == nil)

	spliced, res, cerr := msgpack.commit_document(&ov, .Msgpack, {}, alloc)
	testing.expect(t, cerr == nil)
	defer tape.destroy_document(&spliced)
	defer edit.destroy_commit_result(&res)

	want := []u8{0x82, 0xa1, 'a', 0x2a, 0xa3, 'r', 'a', 'w', 0x92, 0xcc, 0x02, 0x03}
	testing.expectf(t, bytes.equal(res.bytes, want), "got %x want %x", res.bytes, want)

	fresh, ferr := msgpack.build(res.bytes, .Msgpack, {}, alloc)
	testing.expect_value(t, ferr, nil)
	defer tape.destroy_document(&fresh)
	testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))

	// 2. `.Msgpack -> .Compact` upgrade also compacts non-compact integer & binary sibling keys inside an edited map!
	// {0xd0 0x01 (non-compact int 1): 0xcc 0x02, c4 01 'b': 0x01, "x": 0x00}
	ksrc := []u8{0x83, 0xd0, 0x01, 0xcc, 0x02, 0xc4, 0x01, 'b', 0x01, 0xa1, 'x', 0x00}
	kdoc, kerr := msgpack.build(ksrc, .Msgpack, {}, alloc)
	testing.expect_value(t, kerr, nil)
	defer tape.destroy_document(&kdoc)

	kov: msgpack.Overlay
	testing.expect(t, msgpack.edit_init(&kov, &kdoc, alloc) == nil)
	defer msgpack.edit_destroy(&kov)
	_, e2 := edit.set_path(&kov, {tape.Name("x")}, edit.val_int(9))
	testing.expect(t, e2 == nil)

	cspliced, cres, ccerr := msgpack.commit_document(&kov, .Compact, {}, alloc)
	testing.expectf(t, ccerr == nil, "ccerr = %v", ccerr)
	defer tape.destroy_document(&cspliced)
	defer edit.destroy_commit_result(&cres)

	testing.expect_value(t, msgpack.validate(cres.bytes, .Compact), nil)
	// Compact output: {0x01 (compacted int key!): 0x02, bin('b'): 0x01, "x": 0x09}
	kwant := []u8{0x83, 0x01, 0x02, 0xc4, 0x01, 'b', 0x01, 0xa1, 'x', 0x09}
	testing.expectf(t, bytes.equal(cres.bytes, kwant), "got %x want %x", cres.bytes, kwant)
}

@(test)
msgpack_edit_tags_timestamps_deltas_and_refusals :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. Tag edits: `.Tag` "42" on `.Bytes`, `"datetime"` on RFC 3339 `.String`, delete `.Tag` on ext, and `.Base_Ref`
	src := []u8{0x82, 0xa1, 'b', 0xc4, 0x02, 0xde, 0xad, 0xa1, 't', 0xd6, 0xff, 0x51, 0x4b, 0x67, 0xb0}
	doc, err := msgpack.build(src, .Compact, {}, alloc)
	testing.expect_value(t, err, nil)
	defer tape.destroy_document(&doc)

	ov: msgpack.Overlay
	testing.expect(t, msgpack.edit_init(&ov, &doc, alloc) == nil)
	defer msgpack.edit_destroy(&ov)

	root_h, _ := edit.ensure_root(&ov)
	_, b_base, b_ok := edit.lookup_member(&ov, root_h, "b")
	testing.expect(t, b_ok)
	b_h, _ := edit.handle_for_base(&ov, b_base)
	testing.expect(t, edit.set_fact(&ov, b_h, .Tag, {"42"}) == nil)

	_, t_base, _ := edit.lookup_member(&ov, root_h, "t")
	t_h, _ := edit.handle_for_base(&ov, t_base)
	testing.expect(t, edit.del_fact(&ov, t_h, .Tag) == nil)

	dt_h, dt_err := edit.insert_member(&ov, root_h, 0, "dt", edit.val_string("2013-03-21T20:04:00Z"))
	testing.expect(t, dt_err == nil && edit.set_fact(&ov, dt_h, .Tag, {"datetime"}) == nil)

	_, ref_err := edit.insert_member(&ov, root_h, 1, "cp", edit.val_base_ref(b_base))
	testing.expect(t, ref_err == nil)
	_, raw_err := edit.insert_member(&ov, root_h, 2, "raw", edit.val_raw("\x91\x2a"))
	testing.expect(t, raw_err == nil)

	spliced, res, cerr := msgpack.commit_document(&ov, .Compact, {}, alloc)
	testing.expectf(t, cerr == nil, "cerr = %v", cerr)
	defer tape.destroy_document(&spliced)
	defer edit.destroy_commit_result(&res)
	testing.expect_value(t, msgpack.validate(res.bytes, .Compact), nil)

	// Verify "dt" became ts32 0xd6 ff 514b67b0, "cp" stayed bin 0xdead, "raw" became [42], "b" became fixext2 0xd5 42 0xdead, "t" reverted to RFC3339 str!
	r := msgpack.Reader{&spliced, nil}
	b_n, _ := msgpack.member(r, msgpack.ROOT, "b")
	testing.expect_value(t, spliced.nodes[b_n].kind, msgpack.Kind.Bytes)
	testing.expect_value(t, len(spliced.facts), 2) // dt + b
	raw_n, raw_p := msgpack.member(r, msgpack.ROOT, "raw")
	testing.expect(t, raw_p == .Found && spliced.nodes[raw_n].kind == .Array)
	t_n, _ := msgpack.member(r, msgpack.ROOT, "t")
	ts_s, _ := text_of(&spliced, t_n)
	testing.expect_value(t, ts_s, "2013-03-21T20:04:00Z")
	testing.expect(t, spliced.nodes[t_n].spelling & (1 << 15) == 0)

	// 2. Group 1 refusals (invalid ext tag range, ext on int/container, Bad_Order)
	{
		ov2: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&ov2, &doc, alloc) == nil)
		defer msgpack.edit_destroy(&ov2)
		rh2, _ := edit.ensure_root(&ov2)
		testing.expect(t, edit.set_fact(&ov2, rh2, .Tag, {"1"}) == nil)
		_, rerr := msgpack.commit(&ov2, .Compact, {reflow = true}, alloc)
		ref, is_ref := rerr.(edit.Refusal)
		testing.expect(t, is_ref && ref.group == .Format_Impossible && ref.kind == .Fact_No_Place)
	}
	{
		arr_doc, _ := msgpack.build([]u8{0x92, 0x01, 0x02}, .Compact, {}, alloc)
		defer tape.destroy_document(&arr_doc)
		ov3: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&ov3, &arr_doc, alloc) == nil)
		defer msgpack.edit_destroy(&ov3)
		rh3, _ := edit.ensure_root(&ov3)
		testing.expect(t, edit.reorder(&ov3, rh3, {0, 0}) == nil)
		_, oerr := msgpack.commit(&ov3, .Compact, {}, alloc)
		ref, is_ref := oerr.(edit.Refusal)
		testing.expect(t, is_ref && ref.kind == .Bad_Order)
	}

	// 3. Explicit `budget.depth` exceeded in `commit_document`
	{
		ov4: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&ov4, &doc, alloc) == nil)
		defer msgpack.edit_destroy(&ov4)
		leaf, _ := edit.new_node(&ov4, edit.val_int(1))
		in1, _ := edit.new_node(&ov4, edit.val_array({leaf}))
		in2, _ := edit.new_node(&ov4, edit.val_array({in1}))
		_, _ = edit.set_path(&ov4, {tape.Name("b")}, edit.val_array({in2}))
		_, res4, derr := msgpack.commit_document(&ov4, .Compact, {budget = {depth = 3}}, alloc)
		edit.destroy_commit_result(&res4)
		ex, is_ex := derr.(tape.Exceeded)
		testing.expectf(t, is_ex && ex.kind == .Depth, "depth exceed got %v", derr)
	}

	// 4. OOM sweep on `edit` + `commit`
	Sweep :: struct {
		doc: ^tape.Document,
	}
	run_edit :: proc(data: rawptr, a: runtime.Allocator) {
		s := (^Sweep)(data)
		ov: msgpack.Overlay
		if msgpack.edit_init(&ov, s.doc, a) != nil {
			return
		}
		defer msgpack.edit_destroy(&ov)
		raw_bytes := [?]u8{0x01, 0x02}
		_, _ = edit.set_path(&ov, {tape.Name("t")}, edit.val_bytes(raw_bytes[:]))
		_, _ = edit.set_path(&ov, {tape.Name("b")}, edit.val_int(77))
		cr, err := msgpack.commit(&ov, .Compact, {}, a)
		if err == nil {
			edit.destroy_commit_result(&cr)
		}
	}
	sw := testkit.sweep_failures(run_edit, &Sweep{&doc})
	testing.expectf(t, sw.bad == 0 && sw.refused >= 1, "edit OOM sweep: %v", sw)
}

@(test)
msgpack_edit_base_ref_structural_shrunk_header_and_foreign_docs :: proc(t: ^testing.T) {
	testkit.deadline(t)
	alloc := runtime.heap_allocator()

	// 1. Structural edits (`insert_member`, `del_member`, `reorder`, `insert_element`) on `.Base_Ref` containers
	//    both newly created (`n.base == NO_NODE`) and replacing an existing node (`n.base != NO_NODE`).
	{
		src := []u8{
			0x83,
			0xa3, 'a', 'r', 'r', 0x93, 0x0a, 0x14, 0x1e,
			0xa3, 'o', 'b', 'j', 0x82, 0xa1, 'k', 0x01, 0xa1, 'm', 0x02,
			0xa1, 's', 0x2a,
		}
		doc, err := msgpack.build(src, .Compact, {}, alloc)
		testing.expect_value(t, err, nil)
		defer tape.destroy_document(&doc)

		ov: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&ov, &doc, alloc) == nil)
		defer msgpack.edit_destroy(&ov)

		root_h, _ := edit.ensure_root(&ov)
		_, arr_base, _ := edit.lookup_member(&ov, root_h, "arr")
		_, obj_base, _ := edit.lookup_member(&ov, root_h, "obj")

		cp_arr, aerr := edit.insert_member(&ov, root_h, -1, "cp_arr", edit.val_base_ref(arr_base))
		testing.expect_value(t, aerr, nil)
		testing.expect(t, edit.del_element(&ov, cp_arr, 1) == nil)
		_, ierr := edit.insert_element(&ov, cp_arr, -1, edit.val_int(99))
		testing.expect_value(t, ierr, nil)
		testing.expect(t, edit.reorder(&ov, cp_arr, {3, 2, 0}) == nil)

		_, s_base, _ := edit.lookup_member(&ov, root_h, "s")
		s_h, _ := edit.handle_for_base(&ov, s_base)
		testing.expect(t, edit.set(&ov, s_h, edit.val_base_ref(obj_base)) == nil)
		testing.expect(t, edit.del_member(&ov, s_h, "k") == nil)
		_, merr := edit.insert_member(&ov, s_h, -1, "added", edit.val_int(7))
		testing.expect_value(t, merr, nil)

		spliced, res, cerr := msgpack.commit_document(&ov, .Compact, {}, alloc)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)
		if !testing.expectf(t, cerr == nil, "base_ref commit cerr=%v", cerr) {
			return
		}
		testing.expect_value(t, msgpack.validate(res.bytes, .Compact), nil)

		fresh, ferr := msgpack.build(res.bytes, .Compact, {}, alloc)
		defer tape.destroy_document(&fresh)
		testing.expect_value(t, ferr, nil)
		testing.expect_value(t, len(spliced.nodes), len(fresh.nodes))
		testkit.values_agree(t, &fresh, tape.ROOT, &spliced, tape.ROOT, {number_values = true}, "base_ref structural")

		// Check `cp_arr` == [99, 30, 10] and `s` == {"m": 2, "added": 7}.
		cp_n, _ := msgpack.member({&spliced, nil}, msgpack.ROOT, "cp_arr")
		c0, _ := msgpack.element({&spliced, nil}, cp_n, 0)
		c2, _ := msgpack.element({&spliced, nil}, cp_n, 2)
		n0, _ := msgpack.node_number(&spliced, c0)
		n2, _ := msgpack.node_number(&spliced, c2)
		testing.expect(t, n0.bits == 99 && n2.bits == 10)

		s_n, _ := msgpack.member({&spliced, nil}, msgpack.ROOT, "s")
		add_n, add_p := msgpack.member({&spliced, nil}, s_n, "added")
		k_n, k_p := msgpack.member({&spliced, nil}, s_n, "k")
		testing.expect(t, add_p == .Found && k_p == .Missing && k_n == msgpack.NO_NODE)
		an, _ := msgpack.node_number(&spliced, add_n)
		testing.expect_value(t, an.bits, u64(7))
	}

	// 2. Non-compact container header shrinking (`0xdc 0x00 0x02` -> `0x92`) on `.Ancestor` state in `commit_document`,
	//    plus `opts.budget` propagation into `commit` and `commit_document`.
	{
		ksrc := []u8{0xdc, 0x00, 0x02, 0x01, 0x02}
		kdoc, kerr := msgpack.build(ksrc, .Msgpack, {}, alloc)
		testing.expect_value(t, kerr, nil)
		defer tape.destroy_document(&kdoc)

		kov: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&kov, &kdoc, alloc) == nil)
		defer msgpack.edit_destroy(&kov)
		_, _ = edit.set_path(&kov, {tape.Index(1)}, edit.val_int(3))

		spliced, res, cerr := msgpack.commit_document(&kov, .Msgpack, {}, alloc)
		testing.expect_value(t, cerr, nil)
		defer tape.destroy_document(&spliced)
		defer edit.destroy_commit_result(&res)

		want := []u8{0x92, 0x01, 0x03}
		testing.expectf(t, bytes.equal(res.bytes, want), "shrunk header got %x want %x", res.bytes, want)
		e0, _ := msgpack.element({&spliced, nil}, msgpack.ROOT, 0)
		e1, _ := msgpack.element({&spliced, nil}, msgpack.ROOT, 1)
		testing.expect_value(t, spliced.nodes[e0].lo, u64(1))
		testing.expect_value(t, spliced.nodes[e1].lo, u64(2))
		v0, _ := msgpack.node_number(&spliced, e0)
		v1, _ := msgpack.node_number(&spliced, e1)
		testing.expect(t, v0.bits == 1 && v1.bits == 3)

		// `opts.budget` enforced by `commit` (`validate` checks `.Depth`) and `commit_document` (`full_build_cb` checks `.Nodes`).
		_, doc_res, bud_doc_err := msgpack.commit_document(&kov, .Msgpack, {budget = {nodes = 2}}, alloc)
		edit.destroy_commit_result(&doc_res)
		ex_n, is_ex_n := bud_doc_err.(tape.Exceeded)
		testing.expectf(t, is_ex_n && ex_n.kind == .Nodes, "budget.nodes commit_document got %v", bud_doc_err)

		ov_d: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&ov_d, &kdoc, alloc) == nil)
		defer msgpack.edit_destroy(&ov_d)
		inner, _ := edit.new_node(&ov_d, edit.val_int(9))
		_, _ = edit.set_path(&ov_d, {tape.Index(0)}, edit.val_array({inner}))
		cres_d, bud_commit_err := msgpack.commit(&ov_d, .Msgpack, {budget = {depth = 1}}, alloc)
		edit.destroy_commit_result(&cres_d)
		ex_d, is_ex_d := bud_commit_err.(tape.Exceeded)
		testing.expectf(t, is_ex_d && ex_d.kind == .Depth, "budget.depth commit got %v", bud_commit_err)
	}

	// 3. Committing edits over foreign JSON & CBOR base documents (sibling non-string keys & dropped facts preserved accurately).
	{
		jdoc, jerr := json.build(transmute([]u8)string(`{"b":[1,2],"a":10}`), .Json, {}, alloc)
		testing.expect_value(t, jerr, nil)
		defer tape.destroy_document(&jdoc)

		jov: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&jov, &jdoc, alloc) == nil)
		defer msgpack.edit_destroy(&jov)
		_, _ = edit.set_path(&jov, {tape.Name("b"), tape.Index(1)}, edit.val_int(99))

		jspliced, jres, jcerr := msgpack.commit_document(&jov, .Compact, {}, alloc)
		testing.expectf(t, jcerr == nil, "json->msgpack edit: %v", jcerr)
		defer tape.destroy_document(&jspliced)
		defer edit.destroy_commit_result(&jres)
		testing.expect_value(t, msgpack.validate(jres.bytes, .Compact), nil)

		// CBOR map `{1: 100, "tag": d8 18 41 09 (unknown CBOR tag 24 -> dropped), "c": 3}` -> edit `"c" = 7`.
		csrc := []u8{0xa3, 0x01, 0x18, 100, 0x63, 't', 'a', 'g', 0xd8, 0x18, 0x41, 0x09, 0x61, 'c', 0x03}
		cdoc, cerr := cbor.build(csrc, .Cbor, {}, alloc)
		testing.expect_value(t, cerr, nil)
		defer tape.destroy_document(&cdoc)

		cov: msgpack.Overlay
		testing.expect(t, msgpack.edit_init(&cov, &cdoc, alloc) == nil)
		defer msgpack.edit_destroy(&cov)
		_, _ = edit.set_path(&cov, {tape.Name("c")}, edit.val_int(7))

		cspliced, cres, ccerr := msgpack.commit_document(&cov, .Compact, {}, alloc)
		testing.expectf(t, ccerr == nil, "cbor->msgpack edit: %v", ccerr)
		defer tape.destroy_document(&cspliced)
		defer edit.destroy_commit_result(&cres)
		testing.expect_value(t, msgpack.validate(cres.bytes, .Compact), nil)
		testing.expect(t, .Tag in cres.dropped)
		n1, p1 := msgpack.member({&cspliced, nil}, msgpack.ROOT, "1")
		testing.expect(t, p1 == .Found)
		nv1, _ := msgpack.node_number(&cspliced, n1)
		testing.expect_value(t, nv1.bits, u64(100))
	}
}
