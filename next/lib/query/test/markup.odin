package query_test

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(private)
read_xml :: proc(t: ^testing.T, h: ^query.Heap, text: string, loc := #caller_location) -> query.Value {
	doc, err := xml.build(transmute([]u8)text, .Xml, {}, h.allocator)
	testing.expectf(t, err == nil, "%s does not read: %v", text, err, loc = loc)
	v, s := query.document_value(h, doc, true)
	testing.expect(t, s == .Ok, loc = loc)
	return v
}

@(private)
MARKUP_LIST :: `<r><a>1</a><b>x</b><a>2</a><a>3</a></r>`

@(test)
a_repeated_name_reads_as_an_array_in_document_order :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	doc := read_xml(t, h, MARKUP_LIST)
	defer query.release(h, doc)
	r, _ := query.member(h, doc, "r")
	defer query.release(h, r)
	a, _ := query.member(h, r, "a")
	defer query.release(h, a)
	b, _ := query.member(h, r, "b")
	defer query.release(h, b)
	testing.expect_value(t, as_json(h, a), `["1","2","3"]`)
	testing.expect_value(t, as_json(h, b), `"x"`)
	testing.expect_value(t, query.length_of(h, r), 2)
	testing.expect(t, query.has_member(h, r, "a"))
	second, _ := query.element(h, a, 1)
	testing.expect_value(t, as_json(h, second), `"2"`)
	query.release(h, second)
	testing.expect_value(t, as_json(h, r), `{"a":["1","2","3"],"b":"x"}`)
}

@(test)
a_markup_object_is_built_with_one_member_per_name :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	doc := read_xml(t, h, MARKUP_LIST)
	defer query.release(h, doc)
	r, _ := query.member(h, doc, "r")
	defer query.release(h, r)
	copy, s := query.built(h, r)
	testing.expect(t, s == .Ok)
	defer query.release(h, copy)
	testing.expect_value(t, query.length_of(h, copy), 2)
	testing.expect_value(t, as_json(h, copy), `{"a":["1","2","3"],"b":"x"}`)
	c, _ := query.cursor_open(h, r)
	defer query.cursor_close(&c)
	names := make([dynamic]u8, context.temp_allocator)
	for {
		k, v, more, _ := query.cursor_next(h, &c)
		if !more {
			break
		}
		append(&names, ..transmute([]u8)query.text_of(k))
		query.release(h, k)
		query.release(h, v)
	}
	testing.expect_value(t, string(names[:]), "ab")
}

@(test)
distinct_xml_children_cursor_streams_without_grouping :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// Distinct children (`c.children.once == true`) stream directly through the fast object cursor without grouping allocation.
	doc := read_xml(t, h, `<log id="req-1" lvl="err"><ts>2026</ts><svc>api</svc><msg>boom &amp; fail</msg><empty/><nested k="9"><v>1</v></nested></log>`)
	defer query.release(h, doc)
	log_el, ls := query.member(h, doc, "log")
	testing.expect_value(t, ls, query.Status.Ok)
	defer query.release(h, log_el)

	c, cs := query.cursor_open(h, log_el)
	testing.expect_value(t, cs, query.Status.Ok)
	defer query.cursor_close(&c)
	// Fast cursor keeps `.Node` in `c.of` rather than materializing a grouped `.Object`.
	testing.expect_value(t, c.of.kind, query.Kind.Node)
	testing.expect(t, c.children.once)

	got := query.make_object(h, 8) or_else query.NULL
	defer query.release(h, got)
	for {
		k, v, more, ns := query.cursor_next(h, &c)
		testing.expect_value(t, ns, query.Status.Ok)
		if !more {
			break
		}
		testing.expect_value(t, query.object_put(h, &got, k, v), query.Status.Ok)
	}
	testing.expect_value(t, as_json(h, got), `{"ts":"2026","svc":"api","msg":"boom & fail","empty":null,"nested":{"v":"1"}}`)
}

@(test)
object_put_short_long_keys_partial_taint_numbers_and_shallow_all_plan :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// Exercise `object_put` across empty/1..8-byte short keys (fast table path) and >8-byte keys (`object_put_slow`),
	// replacement (`object_replace_at`), COW copy on shared object (`object_insert_grow`), `set_one_key_owned`, and partial taint.
	o, os := query.make_object(h, 4)
	testing.expect_value(t, os, query.Status.Ok)
	defer query.release(h, o)

	short_keys := [?]string{"", "a", "ab", "abc", "abcd", "abcde", "abcdef", "abcdefg", "abcdefgh", "long_key_123"}
	for sk, idx in short_keys {
		kv, ks := query.text_value(h, sk)
		testing.expect_value(t, ks, query.Status.Ok)
		testing.expect_value(t, query.object_put(h, &o, kv, query.int_value(i64(idx))), query.Status.Ok)
	}
	// Replace both a <=8-byte key and a >8-byte key in place.
	k_rep1, _ := query.text_value(h, "abcd")
	testing.expect_value(t, query.object_put(h, &o, k_rep1, query.int_value(99)), query.Status.Ok)
	k_rep2, _ := query.text_value(h, "long_key_123")
	testing.expect_value(t, query.object_put(h, &o, k_rep2, query.int_value(77)), query.Status.Ok)

	// Shared reference forces COW growth in `object_insert_grow`, plus `set_one_key_owned` takes ownership cleanly.
	alias := query.retain(o)
	defer query.release(h, alias)
	k_cow, _ := query.text_value(h, "new_k")
	o, os = query.set_one_key_owned(h, o, k_cow, query.int_value(42))
	testing.expect_value(t, os, query.Status.Ok)
	m_alias, _ := query.member(h, alias, "abcd")
	m_cow, _ := query.member(h, o, "new_k")
	m_old, _ := query.member(h, alias, "new_k")
	testing.expect_value(t, m_alias.i, i64(99))
	testing.expect_value(t, m_cow.i, i64(42))
	testing.expect_value(t, m_old.kind, query.Kind.Absent)
	query.release(h, m_alias)
	query.release(h, m_cow)

	// Partial document insertion propagates partial flag across built containers.
	pdoc, perr := xml.build(transmute([]u8)string(`<r><a>1</a></r>`), .Xml, {}, h.allocator)
	testing.expect_value(t, perr, nil)
	part, berr := tape.partial_block(0, 0, 0, 0, 0, .Group, h.allocator)
	testing.expect_value(t, berr, nil)
	pdoc.partial = part
	pdoc.nodes[0].spelling |= tape.CONTAINER_PARTIAL
	pv, ps := query.document_value(h, pdoc, true)
	testing.expect_value(t, ps, query.Status.Ok)
	k_part, _ := query.text_value(h, "part")
	testing.expect_value(t, query.object_put(h, &o, k_part, pv), query.Status.Ok)
	testing.expect(t, query.value_has_partial(o))

	// `as_exact_i64` vs `as_i64`: Int nodes exact in both; Float (`1.0`, `-0.0`) only in `as_i64`; bool/null/string false in both.
	num_doc := read_json(t, h, `{"i": 500, "f": 1.0, "nz": -0.0, "b": true, "s": "500"}`)
	defer query.release(h, num_doc)
	vi, _ := query.member(h, num_doc, "i")
	vf, _ := query.member(h, num_doc, "f")
	vnz, _ := query.member(h, num_doc, "nz")
	vb, _ := query.member(h, num_doc, "b")
	vs, _ := query.member(h, num_doc, "s")
	defer {
		query.release(h, vi)
		query.release(h, vf)
		query.release(h, vnz)
		query.release(h, vb)
		query.release(h, vs)
	}
	ei, eok := query.as_exact_i64(vi)
	testing.expect(t, eok && ei == 500)
	_, fok := query.as_exact_i64(vf)
	testing.expect(t, !fok)
	_, nzok := query.as_exact_i64(vnz)
	testing.expect(t, !nzok)
	fi, fiok := query.as_i64(vf)
	testing.expect(t, fiok && fi == 1)
	nzi, nziok := query.as_i64(vnz)
	testing.expect(t, nziok && nzi == 0)
	_, bok := query.as_i64(vb)
	_, sok := query.as_i64(vs)
	testing.expect(t, !bok && !sok)

	// Cost rule `shallow_all_too_wide`: 5 shallow leaves directly past unbounded `All` degrades to `.Whole (.Too_Wide)`,
	// while 4 shallow leaves, deep subtree leaves, `.Keys` grain leaves, or limited paths remain `.Partial`.
	mk_paths :: proc(names: []string, extra_deep := "", keys_first := false, limit := 0) -> []query.Demand_Path {
		out := make([]query.Demand_Path, len(names), context.temp_allocator)
		for nm, idx in names {
			if idx == len(names) - 1 && extra_deep != "" {
				steps := make([]tape.Step, 4, context.temp_allocator)
				steps[0], steps[1], steps[2], steps[3] = tape.Name("rows"), tape.All{}, tape.Name(nm), tape.Name(extra_deep)
				out[idx] = {steps = steps, grain = .Whole}
			} else {
				steps := make([]tape.Step, 3, context.temp_allocator)
				steps[0], steps[1], steps[2] = tape.Name("rows"), tape.All{}, tape.Name(nm)
				g := tape.Grain.Keys if (keys_first && idx == 0) else tape.Grain.Whole
				out[idx] = {steps = steps, grain = g, limit = limit}
			}
		}
		return out
	}
	five := [?]string{"id", "ts", "lvl", "msg", "status"}
	d_wide := query.finalize_source_demand(mk_paths(five[:]), false, context.temp_allocator)
	testing.expect_value(t, d_wide.mode, query.Demand_Mode.Whole)
	testing.expect_value(t, d_wide.reason, query.Whole_Reason.Too_Wide)

	d_four := query.finalize_source_demand(mk_paths(five[:4]), false, context.temp_allocator)
	testing.expect_value(t, d_four.mode, query.Demand_Mode.Partial)

	d_deep := query.finalize_source_demand(mk_paths(five[:], extra_deep = "sub"), false, context.temp_allocator)
	testing.expect_value(t, d_deep.mode, query.Demand_Mode.Partial)

	d_keys := query.finalize_source_demand(mk_paths(five[:], keys_first = true), false, context.temp_allocator)
	testing.expect_value(t, d_keys.mode, query.Demand_Mode.Partial)

	d_lim := query.finalize_source_demand(mk_paths(five[:], limit = 10), false, context.temp_allocator)
	testing.expect_value(t, d_lim.mode, query.Demand_Mode.Partial)
}
