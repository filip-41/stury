package query_test

import "core:bytes"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:lib/ops/edit"
import "stury:lib/query"
import "stury:msgpack"
import "stury:testkit"
import "stury:yaml"

@(test)
bytes_values_cbor_msgpack_and_yaml :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// 1. Owned and borrowed `.Bytes` values, distinct from `.String` with identical bytes.
	raw_abc := [?]u8{'a', 'b', 'c'}
	raw_bin := [?]u8{0xDE, 0xAD, 0xBE, 0xEF}
	bv, bs := query.bytes_value(h, raw_abc[:])
	testing.expect_value(t, bs, query.Status.Ok)
	defer query.release(h, bv)
	bb := query.bytes_borrowed(raw_abc[:])
	sv, ss := query.text_value(h, "abc")
	testing.expect_value(t, ss, query.Status.Ok)
	defer query.release(h, sv)

	testing.expect_value(t, query.type_of(bv), query.Type.Bytes)
	testing.expect_value(t, query.type_of(bb), query.Type.Bytes)
	testing.expect(t, query.is_bytes(bv) && !query.is_text(bv))
	testing.expect(t, query.is_bytes(bb) && !query.is_text(bb))
	testing.expect(t, !query.is_bytes(sv) && query.is_text(sv))
	testing.expect(t, bytes.equal(query.bytes_of(bv), raw_abc[:]))

	eq_bb, _ := query.equal(h, bv, bb)
	eq_bs, _ := query.equal(h, bv, sv)
	testing.expect(t, eq_bb)
	testing.expect(t, !eq_bs)

	hbv, _ := query.hash(h, bv)
	hbb, _ := query.hash(h, bb)
	testing.expect_value(t, hbv, hbb)

	// 2. JSON serialization encodes `.Bytes` as RFC 4648 base64 strings.
	bin_v, _ := query.bytes_value(h, raw_bin[:])
	defer query.release(h, bin_v)
	testing.expect_value(t, as_json(h, bv), `"YWJj"`)
	testing.expect_value(t, as_json(h, bin_v), `"3q2+7w=="`)
	empty_b := query.bytes_borrowed(nil)
	testing.expect_value(t, as_json(h, empty_b), `""`)

	// 3. CBOR definite & indefinite byte strings, MessagePack bin, and YAML `!!binary` preserve `.Bytes`.
	// CBOR map: {"def": h'deadbeef', "indef": (_ h'de', h'adbeef'), "str": "abc"}
	cbor_src := [?]u8{
		0xA3,
		0x63, 'd', 'e', 'f', 0x44, 0xDE, 0xAD, 0xBE, 0xEF,
		0x65, 'i', 'n', 'd', 'e', 'f', 0x5F, 0x41, 0xDE, 0x43, 0xAD, 0xBE, 0xEF, 0xFF,
		0x63, 's', 't', 'r', 0x63, 'a', 'b', 'c',
	}
	cdoc, cerr := cbor.build(cbor_src[:], allocator = h.allocator)
	testing.expect_value(t, cerr, tape.Error(nil))
	cv, cs := query.document_value(h, cdoc, true)
	testing.expect_value(t, cs, query.Status.Ok)
	defer query.release(h, cv)

	c_def, _ := query.member(h, cv, "def")
	defer query.release(h, c_def)
	c_indef, _ := query.member(h, cv, "indef")
	defer query.release(h, c_indef)
	c_str, _ := query.member(h, cv, "str")
	defer query.release(h, c_str)

	// Definite CBOR byte string is zero-copy `.Node` with `type_of == .Bytes`.
	testing.expect_value(t, c_def.kind, query.Kind.Node)
	testing.expect_value(t, query.type_of(c_def), query.Type.Bytes)
	testing.expect(t, bytes.equal(query.bytes_of(c_def), raw_bin[:]))
	// Indefinite CBOR byte string decodes into `Kind.Bytes`.
	testing.expect_value(t, c_indef.kind, query.Kind.Bytes)
	testing.expect_value(t, query.type_of(c_indef), query.Type.Bytes)
	testing.expect(t, bytes.equal(query.bytes_of(c_indef), raw_bin[:]))
	testing.expect_value(t, query.type_of(c_str), query.Type.String)

	// MessagePack map: {"bin": bin(deadbeef)}
	mp_src := [?]u8{0x81, 0xA3, 'b', 'i', 'n', 0xC4, 0x04, 0xDE, 0xAD, 0xBE, 0xEF}
	mdoc, merr := msgpack.build(mp_src[:], allocator = h.allocator)
	testing.expect_value(t, merr, tape.Error(nil))
	mv, ms := query.document_value(h, mdoc, true)
	testing.expect_value(t, ms, query.Status.Ok)
	defer query.release(h, mv)
	m_bin, _ := query.member(h, mv, "bin")
	defer query.release(h, m_bin)
	testing.expect_value(t, m_bin.kind, query.Kind.Node)
	testing.expect_value(t, query.type_of(m_bin), query.Type.Bytes)
	testing.expect(t, bytes.equal(query.bytes_of(m_bin), raw_bin[:]))

	// YAML `!!binary` decodes into `.Bytes`.
	ydoc, yerr := yaml.build(transmute([]u8)string("bin: !!binary 3q2+7w==\n"), allocator = h.allocator)
	testing.expect_value(t, yerr, tape.Error(nil))
	yv, ys := query.document_value(h, ydoc, true)
	testing.expect_value(t, ys, query.Status.Ok)
	defer query.release(h, yv)
	y_bin, _ := query.member(h, yv, "bin")
	defer query.release(h, y_bin)
	testing.expect_value(t, query.type_of(y_bin), query.Type.Bytes)
	testing.expect(t, bytes.equal(query.bytes_of(y_bin), raw_bin[:]))

	// Cross-format equality & hash consistency (CBOR def == CBOR indef == MsgPack == YAML == owned).
	for other in ([?]query.Value{c_def, c_indef, m_bin, y_bin}) {
		eq, _ := query.equal(h, bin_v, other)
		testing.expect(t, eq)
		h1, _ := query.hash(h, bin_v)
		h2, _ := query.hash(h, other)
		testing.expect_value(t, h1, h2)
	}

	// 4. Collation order: `.String < .Bytes < .Array`, unsigned bytewise comparison.
	b_lo := query.bytes_borrowed([]u8{0x01, 0x7F})
	b_hi := query.bytes_borrowed([]u8{0x01, 0xFF})
	b_short := query.bytes_borrowed([]u8{0x01})
	cmp_s_b, _ := query.compare(h, sv, b_short)
	cmp_sh_lo, _ := query.compare(h, b_short, b_lo)
	cmp_lo_hi, _ := query.compare(h, b_lo, b_hi)
	testing.expect(t, cmp_s_b < 0 && cmp_sh_lo < 0 && cmp_lo_hi < 0)

	arr, _ := query.make_array(h, 4)
	defer query.release(h, arr)
	_ = query.append_owned(h, &arr, query.retain(b_hi))
	_ = query.append_owned(h, &arr, query.retain(sv))
	_ = query.append_owned(h, &arr, query.retain(b_lo))
	_ = query.append_owned(h, &arr, query.retain(b_short))
	sorted, sort_st := query.sort_by(h, arr)
	testing.expect_value(t, sort_st, query.Status.Ok)
	defer query.release(h, sorted)
	sitems := query.items_of(sorted)
	testing.expect_value(t, query.type_of(sitems[0]), query.Type.String)
	testing.expect(t, bytes.equal(query.bytes_of(sitems[1]), []u8{0x01}))
	testing.expect(t, bytes.equal(query.bytes_of(sitems[2]), []u8{0x01, 0x7F}))
	testing.expect(t, bytes.equal(query.bytes_of(sitems[3]), []u8{0x01, 0xFF}))

	// 5. `built_deep` preserves `.Bytes` values.
	deep, dst := query.built_deep(h, cv)
	testing.expect_value(t, dst, query.Status.Ok)
	defer query.release(h, deep)
	d_def, _ := query.member(h, deep, "def")
	defer query.release(h, d_def)
	testing.expect_value(t, d_def.kind, query.Kind.Bytes)
	testing.expect(t, bytes.equal(query.bytes_of(d_def), raw_bin[:]))
}

@(test)
bytes_overlay_preserves_native_type :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// CBOR map {"a": h'0102', "b": "hi"}
	cbor_src := [?]u8{0xA2, 0x61, 'a', 0x42, 0x01, 0x02, 0x61, 'b', 0x62, 'h', 'i'}
	doc, err := cbor.build(cbor_src[:], allocator = h.allocator)
	testing.expect_value(t, err, tape.Error(nil))
	defer tape.destroy(&doc)

	ov: edit.Overlay
	testing.expect_value(t, edit.init(&ov, &doc, h.allocator), edit.Error(nil))
	defer edit.destroy(&ov)

	ov_v, ov_st := query.overlay_value(h, &ov)
	testing.expect_value(t, ov_st, query.Status.Ok)
	defer query.release(h, ov_v)

	// Reading untouched CBOR `.Bytes` through overlay preserves `.Bytes`.
	a_val, _ := query.member(h, ov_v, "a")
	defer query.release(h, a_val)
	testing.expect_value(t, query.type_of(a_val), query.Type.Bytes)
	testing.expect(t, bytes.equal(query.bytes_of(a_val), []u8{0x01, 0x02}))

	// Setting a new `.Bytes` value via `edit.set_member` reads back from `Overlay_Ref` as `.Bytes`.
	root_h, _ := edit.ensure_root(&ov)
	new_raw := [?]u8{0xCA, 0xFE, 0xBA, 0xBE}
	_, sm_err := edit.set_member(&ov, root_h, "a", edit.val_bytes(new_raw[:]))
	testing.expect_value(t, sm_err, edit.Error(nil))

	a_after, _ := query.member(h, ov_v, "a")
	defer query.release(h, a_after)
	testing.expect_value(t, a_after.kind, query.Kind.Overlay)
	testing.expect_value(t, query.type_of(a_after), query.Type.Bytes)
	testing.expect(t, query.is_bytes(a_after) && !query.is_text(a_after))
	testing.expect(t, bytes.equal(query.bytes_of(a_after), new_raw[:]))

	// Reconciling a built object with a `.Bytes` field into overlay writes `edit.val_bytes` and commits native CBOR major 2!
	built_obj, _ := query.make_object(h, 2)
	defer query.release(h, built_obj)
	bv, _ := query.bytes_value(h, []u8{0xAA, 0xBB})
	_ = query.object_put(h, &built_obj, query.text_borrowed("a"), bv)
	_ = query.object_put(h, &built_obj, query.text_borrowed("b"), query.text_borrowed("hi"))

	testing.expect_value(t, query.reconcile_overlay(h, &ov, built_obj), edit.Error(nil))
	cres, cerr := cbor.commit(&ov, .Cbor, allocator = h.allocator)
	testing.expect_value(t, cerr, edit.Error(nil))
	defer edit.destroy_commit_result(&cres)

	re_doc, re_err := cbor.build(cres.bytes, allocator = h.allocator)
	testing.expect_value(t, re_err, tape.Error(nil))
	defer tape.destroy(&re_doc)
	an, ap := tape.member(tape.Reader{doc = &re_doc}, tape.ROOT, "a")
	testing.expect_value(t, ap, tape.Presence.Found)
	testing.expect_value(t, re_doc.nodes[an].kind, tape.Kind.Bytes)
	testing.expect(t, bytes.equal(tape.span_bytes(&re_doc, re_doc.nodes[an].lo, re_doc.nodes[an].n), []u8{0xAA, 0xBB}))
}
