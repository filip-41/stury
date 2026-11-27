package query_test

import "base:runtime"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

@(test)
plan_aux_named_demands_and_explain :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// Zero-initialized single-source plan works identically with `aux == nil`.
	p := query.Plan{allocator = context.allocator}
	p.sources[.Main] = query.finalize_source_demand({{steps = {tape.Name("id")}, grain = .Whole}}, false, context.allocator)
	if sd, ok := query.aux_demand_for(&p, "users"); ok || sd != nil {
		testing.expect(t, false, "unexpected aux demand on single-source plan")
	}

	b := strings.builder_make(context.allocator)
	query.format_plan(&b, &p)
	single_explain := strings.to_string(b)
	testing.expect(t, strings.contains(single_explain, "source main: partial [.id]"))
	testing.expect(t, !strings.contains(single_explain, "aux "))
	strings.builder_destroy(&b)

	// Install named aux demands with cloned names (`strings.clone` on transient buffer).
	dyn_name := strings.clone("users", context.allocator)
	aux_dem := query.finalize_source_demand({{steps = {tape.All{}, tape.Name("name")}, grain = .Whole}}, false, context.allocator)
	cfg_dem := query.whole_demand(false, .Whole_Op)
	entries := []query.Named_Demand{
		{name = dyn_name, demand = aux_dem},
		{name = "cfg", demand = cfg_dem},
	}
	err := query.set_aux_demands(&p, entries)
	delete(dyn_name, context.allocator) // verify Plan cloned the aux names independently
	testing.expect_value(t, err, runtime.Allocator_Error(nil))

	u_dem, u_ok := query.aux_demand_for(&p, "users")
	testing.expect(t, u_ok && u_dem != nil)
	testing.expect_value(t, u_dem.mode, query.Demand_Mode.Partial)
	testing.expect_value(t, len(u_dem.paths), 1)
	testing.expect(t, query.steps_equal(u_dem.paths[0].steps, {tape.All{}, tape.Name("name")}))

	c_dem, c_ok := query.aux_demand_for(&p, "cfg")
	testing.expect(t, c_ok && c_dem != nil)
	testing.expect_value(t, c_dem.mode, query.Demand_Mode.Whole)

	_, miss_ok := query.aux_demand_for(&p, "missing")
	testing.expect(t, !miss_ok)

	b2 := strings.builder_make(context.allocator)
	query.format_plan(&b2, &p)
	multi_explain := strings.to_string(b2)
	testing.expect(t, strings.contains(multi_explain, "aux users: partial [[].name]"))
	testing.expect(t, strings.contains(multi_explain, "aux cfg: whole (whole-value operation)"))
	strings.builder_destroy(&b2)

	query.plan_destroy(&p)
	testing.expect(t, p.aux == nil)
}

@(test)
hash_join_inner_left_semi_and_one_to_many :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	orders := read_json(t, h, `[
		{"oid":1,"uid":10,"qty":2},
		{"oid":2,"uid":20,"qty":5},
		{"oid":3,"uid":99,"qty":1},
		{"oid":4,"qty":4}
	]`)
	defer query.release(h, orders)

	users := read_json(t, h, `[
		{"id":10,"role":"admin","seq":1},
		{"id":20,"role":"viewer","seq":2},
		{"id":10,"role":"owner","seq":3},
		{"id":30,"role":"guest","seq":4}
	]`)
	defer query.release(h, users)

	// Inner join: 1-to-many preserves duplicate right order for uid=10, drops unmatched/missing.
	inner, s1 := query.hash_join_fields(h, orders, users, "uid", "id", .Inner, .Pair)
	testing.expect_value(t, s1, query.Status.Ok)
	defer query.release(h, inner)
	testing.expect_value(
		t,
		as_json(h, inner),
		`[[{"oid":1,"uid":10,"qty":2},{"id":10,"role":"admin","seq":1}],[{"oid":1,"uid":10,"qty":2},{"id":10,"role":"owner","seq":3}],[{"oid":2,"uid":20,"qty":5},{"id":20,"role":"viewer","seq":2}]]`,
	)

	// Left outer join (`.Merge_Left`): preserves unmatched left rows intact, keeps overlapping keys from left.
	left, s2 := query.hash_join_fields(h, orders, users, "uid", "id", .Left, .Merge_Left)
	testing.expect_value(t, s2, query.Status.Ok)
	defer query.release(h, left)
	testing.expect_value(
		t,
		as_json(h, left),
		`[{"id":10,"role":"admin","seq":1,"oid":1,"uid":10,"qty":2},{"id":10,"role":"owner","seq":3,"oid":1,"uid":10,"qty":2},{"id":20,"role":"viewer","seq":2,"oid":2,"uid":20,"qty":5},{"oid":3,"uid":99,"qty":1},{"oid":4,"qty":4}]`,
	)

	// Semi-join: returns matching left rows once even when right has duplicates.
	semi, s3 := query.hash_join_fields(h, orders, users, "uid", "id", .Semi)
	testing.expect_value(t, s3, query.Status.Ok)
	defer query.release(h, semi)
	testing.expect_value(t, as_json(h, semi), `[{"oid":1,"uid":10,"qty":2},{"oid":2,"uid":20,"qty":5}]`)

	// Empty right collection -> empty inner/semi, all left rows kept on left outer join.
	empty := read_json(t, h, `[]`)
	defer query.release(h, empty)
	ei, s4 := query.hash_join_fields(h, orders, empty, "uid", "id", .Inner, .Pair)
	testing.expect_value(t, s4, query.Status.Ok)
	defer query.release(h, ei)
	testing.expect_value(t, as_json(h, ei), `[]`)

	el, s5 := query.hash_join_fields(h, orders, empty, "uid", "id", .Left, .Pair)
	testing.expect_value(t, s5, query.Status.Ok)
	defer query.release(h, el)
	testing.expect_value(t, query.length_of(h, el), 4)
}

@(test)
hash_index_scalar_and_numeric_equality :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// Mix integer `1`, float `1.0`, string `"1"`, boolean `true`/`false`, `null`.
	rows := read_json(t, h, `[
		{"k":1.0,"tag":"num-a"},
		{"k":"1","tag":"str-one"},
		{"k":1,"tag":"num-b"},
		{"k":true,"tag":"bool-t"},
		{"k":false,"tag":"bool-f"},
		{"k":null,"tag":"null-k"}
	]`)
	defer query.release(h, rows)

	idx, bs := query.hash_index_build_field(h, rows, "k")
	testing.expect_value(t, bs, query.Status.Ok)
	defer query.hash_index_destroy(&idx)

	// Probing with Int(1) matches BOTH `1.0` and `1`, NOT `"1"`.
	m_int, ls1 := query.hash_index_lookup(&idx, query.int_value(1))
	testing.expect_value(t, ls1, query.Status.Ok)
	testing.expect_value(t, len(m_int), 2)
	testing.expect_value(t, as_json(h, m_int[0]), `{"k":1.0,"tag":"num-a"}`)
	testing.expect_value(t, as_json(h, m_int[1]), `{"k":1,"tag":"num-b"}`)

	// Probing with Double(1.0) also matches both.
	m_flt, ls2 := query.hash_index_lookup(&idx, query.double_value(1.0))
	testing.expect_value(t, ls2, query.Status.Ok)
	testing.expect_value(t, len(m_flt), 2)

	// Probing with String("1") matches ONLY `"str-one"`.
	m_str, ls3 := query.hash_index_lookup(&idx, query.text_borrowed("1"))
	testing.expect_value(t, ls3, query.Status.Ok)
	testing.expect_value(t, len(m_str), 1)
	testing.expect_value(t, as_json(h, m_str[0]), `{"k":"1","tag":"str-one"}`)

	// Boolean & null keys match strictly by type+value.
	m_true, ls4 := query.hash_index_lookup(&idx, query.TRUE)
	testing.expect_value(t, ls4, query.Status.Ok)
	testing.expect_value(t, len(m_true), 1)
	testing.expect_value(t, as_json(h, m_true[0]), `{"k":true,"tag":"bool-t"}`)

	m_null, ls5 := query.hash_index_lookup(&idx, query.NULL)
	testing.expect_value(t, ls5, query.Status.Ok)
	testing.expect_value(t, len(m_null), 1)
	testing.expect_value(t, as_json(h, m_null[0]), `{"k":null,"tag":"null-k"}`)

	// NaN key never inserts or matches.
	nan := query.double_value(transmute(f64)u64(0x7FF8000000000000))
	testing.expect(t, query.hash_index_add(&idx, nan, query.NULL) == .Ok)
	has_nan, ns := query.hash_index_has(&idx, nan)
	testing.expect_value(t, ns, query.Status.Ok)
	testing.expect(t, !has_nan)

	// `index_by_field` normalizes `1` and `1.0` both to key `"1"`.
	obj_single, is1 := query.index_by_field(h, rows, "k")
	testing.expect_value(t, is1, query.Status.Ok)
	defer query.release(h, obj_single)
	v1, ms1 := query.member(h, obj_single, "1")
	testing.expect_value(t, ms1, query.Status.Ok)
	defer query.release(h, v1)
	testing.expect_value(t, as_json(h, v1), `{"k":1,"tag":"num-b"}`)

	obj_grouped, is2 := query.index_by_field(h, rows, "k", group_dups = true)
	testing.expect_value(t, is2, query.Status.Ok)
	defer query.release(h, obj_grouped)
	vg, ms2 := query.member(h, obj_grouped, "1")
	testing.expect_value(t, ms2, query.Status.Ok)
	defer query.release(h, vg)
	testing.expect_value(t, query.length_of(h, vg), 3)
}

@(test)
hash_join_budget_and_oom_sweep :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Tight `Budget.memory` fails cleanly with `.Memory` and zero leaked blocks.
	{
		x: Test_Heap
		heap_start(&x)
		defer heap_done(t, &x)
		h := &x.h

		left := read_json(t, h, `[{"id":1,"v":"aaaa"},{"id":2,"v":"bbbb"},{"id":3,"v":"cccc"}]`)
		defer query.release(h, left)
		right := read_json(t, h, `[{"id":1,"n":10},{"id":2,"n":20},{"id":3,"n":30}]`)
		defer query.release(h, right)

		h.limit = h.used + 128
		joined, status := query.hash_join_fields(h, left, right, "id", "id", .Inner, .Pair)
		testing.expect_value(t, status, query.Status.Error)
		testing.expect_value(t, h.err.kind, query.Error_Kind.Memory)
		query.release(h, joined)
		query.clear_error(h)
	}

	// 2. Exhaustive OOM injection sweep across index build, join, `index_by`, and `set_aux_demands`.
	run_oom_ops :: proc(_: rawptr, alloc: runtime.Allocator) {
		h: query.Heap
		query.heap_init(&h, alloc)
		defer query.heap_destroy(&h)

		doc_l, erl := json_build_for_test(`[{"uid":1,"x":"a"},{"uid":2,"x":"b"},{"uid":1,"x":"c"}]`, alloc)
		if erl != nil {
			return
		}
		vl, sl := query.document_value(&h, doc_l, true)
		if sl != .Ok {
			tape.destroy(&doc_l)
			return
		}
		defer query.release(&h, vl)

		doc_r, err := json_build_for_test(`[{"id":1,"name":"ada"},{"id":1,"name":"ada2"},{"id":2,"name":"bob"}]`, alloc)
		if err != nil {
			return
		}
		vr, sr := query.document_value(&h, doc_r, true)
		if sr != .Ok {
			tape.destroy(&doc_r)
			return
		}
		defer query.release(&h, vr)

		idx, bs := query.hash_index_build_field(&h, vr, "id")
		if bs == .Ok {
			_, _ = query.hash_index_lookup(&idx, query.int_value(1))
			_ = query.hash_index_add(&idx, query.double_value(1.0), query.NULL)
			_, _ = query.hash_index_lookup(&idx, query.int_value(1))
		}
		query.hash_index_destroy(&idx)

		if joined, js := query.hash_join_fields(&h, vl, vr, "uid", "id", .Left, .Merge_Left); js == .Ok {
			query.release(&h, joined)
		}

		if grouped, gs := query.index_by_field(&h, vr, "id", group_dups = true); gs == .Ok {
			query.release(&h, grouped)
		}

		p := query.Plan{allocator = alloc}
		defer query.destroy_plan(&p)
		d := query.finalize_source_demand({{steps = {tape.All{}, tape.Name("name")}, grain = .Whole}}, false, alloc)
		if set_err := query.set_aux_demands(&p, {{name = "users", demand = d}}); set_err != nil {
			query.destroy_source_demand(&d)
		}
	}

	sweep := testkit.sweep_failures(run_oom_ops, nil)
	testing.expect(t, sweep.runs > 5)
	testing.expect_value(t, sweep.bad, 0)
}

@(private = "file")
json_build_for_test :: proc(s: string, alloc: runtime.Allocator) -> (tape.Document, tape.Error) {
	return json.build(transmute([]u8)s, .Json, {}, alloc)
}

@(test)
canonical_key_inf_sorted_objects_and_large_group :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	// 1. `+Inf`, `-Inf`, `null`, and NaN stay cleanly distinguished / skipped in `canonical_index_key`.
	pos_inf := query.double_value(transmute(f64)u64(0x7FF0000000000000))
	neg_inf := query.double_value(transmute(f64)u64(0xFFF0000000000000))
	nan := query.double_value(transmute(f64)u64(0x7FF8000000000000))

	k_pinf, s1 := query.canonical_index_key(h, pos_inf)
	testing.expect_value(t, s1, query.Status.Ok)
	testing.expect_value(t, query.text_of(k_pinf), "Infinity")
	query.release(h, k_pinf)

	k_ninf, s2 := query.canonical_index_key(h, neg_inf)
	testing.expect_value(t, s2, query.Status.Ok)
	testing.expect_value(t, query.text_of(k_ninf), "-Infinity")
	query.release(h, k_ninf)

	k_null, s3 := query.canonical_index_key(h, query.NULL)
	testing.expect_value(t, s3, query.Status.Ok)
	testing.expect_value(t, query.text_of(k_null), "null")
	query.release(h, k_null)

	k_nan, s4 := query.canonical_index_key(h, nan)
	testing.expect_value(t, s4, query.Status.Ok)
	testing.expect_value(t, k_nan.kind, query.Kind.Absent)

	// Overflow wide number from JSON (`1e400`) becomes `+Inf` -> `"Infinity"` rather than `"null"`.
	wide_doc := read_json(t, h, `[{"k":null,"v":"null-row"},{"k":1e400,"v":"pos-inf"},{"k":-1e400,"v":"neg-inf"}]`)
	defer query.release(h, wide_doc)
	idx_inf, s5 := query.index_by_field(h, wide_doc, "k")
	testing.expect_value(t, s5, query.Status.Ok)
	defer query.release(h, idx_inf)
	m_null, _ := query.member(h, idx_inf, "null")
	defer query.release(h, m_null)
	m_pi, _ := query.member(h, idx_inf, "Infinity")
	defer query.release(h, m_pi)
	m_ni, _ := query.member(h, idx_inf, "-Infinity")
	defer query.release(h, m_ni)
	testing.expect_value(t, as_json(h, m_null), `{"k":null,"v":"null-row"}`)
	testing.expect_value(t, as_json(h, m_pi), `{"k":1e400,"v":"pos-inf"}`)
	testing.expect_value(t, as_json(h, m_ni), `{"k":-1e400,"v":"neg-inf"}`)

	// 2. Compound object keys normalize member order via `sort_keys = true`.
	o1 := read_json(t, h, `{"b":2,"a":{"y":9,"x":8}}`)
	o2 := read_json(t, h, `{"a":{"x":8,"y":9},"b":2}`)
	defer query.release(h, o1)
	defer query.release(h, o2)
	co1, sc1 := query.canonical_index_key(h, o1)
	co2, sc2 := query.canonical_index_key(h, o2)
	testing.expect(t, sc1 == .Ok && sc2 == .Ok)
	defer query.release(h, co1)
	defer query.release(h, co2)
	testing.expect_value(t, query.text_of(co1), `{"a":{"x":8,"y":9},"b":2}`)
	testing.expect_value(t, query.text_of(co1), query.text_of(co2))

	// 3. Large duplicate-key grouping in `index_by_field(..., group_dups = true)` keeps O(N) & zero leaks.
	many, ms := query.make_array(h, 200)
	testing.expect_value(t, ms, query.Status.Ok)
	defer query.release(h, many)
	for i in 0 ..< 200 {
		row, rerr := query.make_object(h, 2)
		testing.expect_value(t, rerr, query.Status.Ok)
		testing.expect_value(t, query.object_put(h, &row, query.text_borrowed("k"), query.int_value(i64(i % 2))), query.Status.Ok)
		testing.expect_value(t, query.object_put(h, &row, query.text_borrowed("seq"), query.int_value(i64(i))), query.Status.Ok)
		testing.expect_value(t, query.append_owned(h, &many, row), query.Status.Ok)
	}
	grouped, gs := query.index_by_field(h, many, "k", group_dups = true)
	testing.expect_value(t, gs, query.Status.Ok)
	defer query.release(h, grouped)
	g0, _ := query.member(h, grouped, "0")
	g1, _ := query.member(h, grouped, "1")
	defer query.release(h, g0)
	defer query.release(h, g1)
	testing.expect_value(t, query.length_of(h, g0), 100)
	testing.expect_value(t, query.length_of(h, g1), 100)
}
