package jq_tests

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

@(test)
analyze_with_vars_prunes_per_source_demand :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// 1. Dynamic join lookup `$users[.user_id].name`: `.Main` needs only `.user_id`, `$users` needs only `[].name`.
	{
		prog, errs := jq.compile(`{uid: .user_id, uname: $users[.user_id].name}`, {variables = {"users"}})
		testing.expectf(t, len(errs) == 0, "compile errors: %v", errs)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"users"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		main := &plan.sources[.Main]
		testing.expect_value(t, main.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(main, {tape.Name("user_id")}))

		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok && ud != nil)
		testing.expect_value(t, ud.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(ud, {tape.All{}, tape.Name("name")}))
	}

	// 2. Binding `$row` before lookup: `$users[$row.uid].name` + `[].email` from array iteration.
	{
		prog, errs := jq.compile(`. as $row | {name: $users[$row.uid].name, tags: $users[] | select(.active) | .email}`, {variables = {"users"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"users", "unused"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(&plan.sources[.Main], {tape.Name("uid")}))

		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok)
		testing.expect_value(t, ud.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(ud, {tape.All{}, tape.Name("name")}))
		testing.expect(t, has_path(ud, {tape.All{}, tape.Name("active")}, .Exists))
		testing.expect(t, has_path(ud, {tape.All{}, tape.Name("email")}))

		un_d, un_ok := query.aux_demand_for(&plan, "unused")
		testing.expect(t, un_ok)
		testing.expect_value(t, un_d.mode, query.Demand_Mode.None)
	}

	// 3. Nested object lookup `$users.by_id[.id]`: keeps `.by_id` subtree only, pruning sibling root keys!
	{
		prog, errs := jq.compile(`$users.by_id[.id]`, {variables = {"users"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"users"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		testing.expect(t, has_path(&plan.sources[.Main], {tape.Name("id")}))
		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok)
		testing.expect_value(t, ud.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(ud, {tape.Name("by_id")}))
	}

	// 4. Whole/dynamic usage of `$users` does NOT degrade `.Main`!
	{
		prog, errs := jq.compile(`{id: .id, u: $users}`, {variables = {"users"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_plan_with_vars(prog, {"users"})
		testing.expect(t, ok)
		defer jq.destroy_plan(&plan)

		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(&plan.sources[.Main], {tape.Name("id")}))

		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok)
		testing.expect_value(t, ud.mode, query.Demand_Mode.Whole)

		explained := jq.explain_plan(&plan)
		testing.expect(t, strings.contains(explained, "source main: partial [.id]"))
		testing.expect(t, strings.contains(explained, "aux users: whole"))
	}

	// 5. `$users | keys` leaves `.Main` at `.None` and `$users` at `.Keys` grain.
	{
		prog, errs := jq.compile(`$users | keys`, {variables = {"users"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"users"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.None)
		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok)
		testing.expect_value(t, ud.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(ud, nil, .Keys))
	}

	// 6. Zero-arg function called from multiple callsites collects ALL aux demands.
	{
		prog, errs := jq.compile(`def u: $users[.id]; (u.a, u.b)`, {variables = {"users"}})
		testing.expect(t, len(errs) == 0)
		defer jq.destroy_program(prog)

		plan, ok := jq.analyze_with_vars(prog, {"users"})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)

		ud, _ := query.aux_demand_for(&plan, "users")
		testing.expect_value(t, ud.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(ud, {tape.All{}, tape.Name("a")}))
		testing.expect(t, has_path(ud, {tape.All{}, tape.Name("b")}))
	}

	// 7. Nil program safely returns `false`.
	_, bad_ok := jq.analyze_with_vars(nil, {"users"})
	testing.expect(t, !bad_ok)
}

@(private = "file")
run_join_expr :: proc(t: ^testing.T, src, input_json: string, vars: []string = nil, global_jsons: []string = nil, loc := #caller_location) -> string {
	r := eval_jq(t, src, {
		input_json  = input_json,
		variables   = vars,
		globals     = global_jsons,
		prepend_env = true,
		with_joins  = true,
	}, loc = loc)
	testing.expect_value(t, r.end, jq.Run_End.Done, loc = loc)
	return r.out
}

@(test)
jq_join_builtins_and_native_hash_join :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	orders_json := `[{"oid":1,"uid":1},{"oid":2,"uid":"1"},{"oid":3,"uid":99}]`
	users_json := `[{"id":1.0,"name":"ada"},{"id":1,"name":"ada-dup"},{"id":"1","name":"str-one"}]`

	// `index_by` + `lookup`: numeric equivalence (`1 == 1.0`), string `"1"` kept distinct.
	out1 := run_join_expr(
		t,
		`($users | index_by(.id)) as $idx | [.[] | {oid, user: (lookup($idx; .uid).name // null)}]`,
		orders_json,
		{"users"},
		{users_json},
	)
	testing.expect_value(t, out1, `[{"oid":1,"user":"ada-dup"},{"oid":2,"user":"str-one"},{"oid":3,"user":null}]`)

	// `hash_join` preserves 1-to-many duplicate matches in right order.
	out2 := run_join_expr(
		t,
		`hash_join($users; .uid; .id) | map({oid: .[0].oid, role: .[1].name})`,
		orders_json,
		{"users"},
		{users_json},
	)
	testing.expect_value(t, out2, `[{"oid":1,"role":"ada"},{"oid":1,"role":"ada-dup"},{"oid":2,"role":"str-one"}]`)

	// `left_join` keeps unmatched rows with `null`, and `semi_join`/`anti_join` filter properly.
	out3 := run_join_expr(t, `left_join($users; .uid; .id) | length`, orders_json, {"users"}, {users_json})
	testing.expect_value(t, out3, `4`)

	out4 := run_join_expr(t, `semi_join($users; .uid; .id) | map(.oid)`, orders_json, {"users"}, {users_json})
	testing.expect_value(t, out4, `[1,2]`)

	out5 := run_join_expr(t, `anti_join($users; .uid; .id) | map(.oid)`, orders_json, {"users"}, {users_json})
	testing.expect_value(t, out5, `[3]`)

	// Native `join_index_build` + `join_hash_eval` + `join_lookup_object` on `query.Heap`.
	{
		lk_prog, _ := jq.compile(`.uid`)
		rk_prog, _ := jq.compile(`.id`)
		defer jq.destroy_program(lk_prog)
		defer jq.destroy_program(rk_prog)

		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer query.heap_destroy(&h)

		lval, _ := read_value(&h, orders_json)
		rval, _ := read_value(&h, users_json)
		defer query.release(&h, lval)
		defer query.release(&h, rval)

		idx, bs := jq.join_index_build(&h, rval, rk_prog)
		testing.expect_value(t, bs, query.Status.Ok)
		defer query.hash_index_destroy(&idx)

		res, js := jq.join_hash_eval(&h, lval, &idx, lk_prog, .Inner, .Merge_Right)
		testing.expect_value(t, js, query.Status.Ok)
		defer query.release(&h, res)
		testing.expect_value(t, query.length_of(&h, res), 3)

		lookup_obj, os := jq.join_lookup_object(&h, rval, rk_prog, .Group)
		testing.expect_value(t, os, query.Status.Ok)
		defer query.release(&h, lookup_obj)
		n1_grp, ms := query.member(&h, lookup_obj, "1")
		testing.expect_value(t, ms, query.Status.Ok)
		defer query.release(&h, n1_grp)
		testing.expect_value(t, query.length_of(&h, n1_grp), 3)
	}
}

@(test)
analyze_with_vars_oom_sweep :: proc(t: ^testing.T) {
	testkit.deadline(t)

	prog, errs := jq.compile(`{uid: .user_id, uname: $users[.user_id].name, c: $cfg.mode}`, {variables = {"users", "cfg"}})
	testing.expect(t, len(errs) == 0)
	defer jq.destroy_program(prog)

	run_analyze :: proc(raw_p: rawptr, alloc: runtime.Allocator) {
		p := (^jq.Program)(raw_p)
		if plan, ok := jq.analyze_with_vars(p, {"users", "cfg"}, alloc); ok {
			query.destroy_plan(&plan)
		}
	}

	sweep := testkit.sweep_failures(run_analyze, prog)
	testing.expect(t, sweep.runs > 0)
	testing.expect_value(t, sweep.bad, 0)
}

@(test)
jq_join_nan_empty_inf_compound_and_preamble_regressions :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// 1. NaN (`nan`) and `empty` keys NEVER wipe `reduce` accumulators or drop `left_join` rows.
	testing.expect_value(
		t,
		run_join_expr(t, `index_by(.id)`, `[{"id":1},{"id":null},{"id":2}]`),
		`{"n:1":{"id":1},"u:null":{"id":null},"n:2":{"id":2}}`,
	)
	testing.expect_value(
		t,
		run_join_expr(t, `[{"id":1},{"id":nan},{"id":2}] | index_by(.id)`, `null`),
		`{"n:1":{"id":1},"n:2":{"id":2}}`,
	)
	testing.expect_value(
		t,
		run_join_expr(t, `[{"id":1},{"id":nan}] | index_by(.id)`, `null`),
		`{"n:1":{"id":1}}`,
	)
	testing.expect_value(
		t,
		run_join_expr(t, `[{"id":1},{"skip":true},{"id":2}] | index_by(if .skip then empty else .id end)`, `null`),
		`{"n:1":{"id":1},"n:2":{"id":2}}`,
	)
	testing.expect_value(
		t,
		run_join_expr(t, `[{"id":1},{"id":nan},{"id":1.0},{"skip":true}] | group_by_key(if .skip then empty else .id end)`, `null`),
		`{"n:1":[{"id":1},{"id":1}]}`,
	)
	testing.expect_value(
		t,
		run_join_expr(
			t,
			`([{"k":1},{"k":nan},{"k":2},{"skip":true}]) as $l | ([{"k":1},{"k":nan},{"skip":true}]) as $r | ($l | left_join($r; (if .skip then empty else .k end); (if .skip then empty else .k end))) | length`,
			`null`,
		),
		`4`,
	)
	testing.expect_value(
		t,
		run_join_expr(
			t,
			`([{"oid":1,"k":1},{"oid":2,"k":nan},{"oid":3,"skip":true},{"oid":4,"k":9}]) as $l | ([{"k":1},{"k":nan},{"skip":true}]) as $r | {semi: ($l | semi_join($r; (if .skip then empty else .k end); (if .skip then empty else .k end)) | map(.oid)), anti: ($l | anti_join($r; (if .skip then empty else .k end); (if .skip then empty else .k end)) | map(.oid))}`,
			`null`,
		),
		`{"semi":[1],"anti":[2,3,4]}`,
	)

	// 2. `+Inf`, `-Inf`, `null`, and sorted compound object keys.
	testing.expect_value(
		t,
		run_join_expr(
			t,
			`([{"k":infinite,"tag":"pos"},{"k":(-infinite),"tag":"neg"},{"k":null,"tag":"null"}] | index_by(.k)) as $idx | [lookup($idx; infinite).tag, lookup($idx; (-infinite)).tag, lookup($idx; null).tag, lookup($idx; nan)]`,
			`null`,
		),
		`["pos","neg","null",null]`,
	)
	testing.expect_value(
		t,
		run_join_expr(
			t,
			`([{"k":{"b":2,"a":1},"v":"hit"}] | hash_join([{"k":{"a":1,"b":2},"v":"r"}]; .k; .k)) | length`,
			`null`,
		),
		`1`,
	)

	// 3. `lookup($idx; null)` / `Infinity` / `-Infinity` against `join_lookup_object` (`canonical_index_key`).
	{
		kprog, _ := jq.compile(`.k`)
		defer jq.destroy_program(kprog)
		qprog, errs := jq.compile_with_joins(`[lookup($idx; null).tag, lookup($idx; nan), lookup($idx; infinite).tag, lookup($idx; (-infinite)).tag]`, {variables = {"idx"}})
		testing.expectf(t, len(errs) == 0, "compile_with_joins errors: %v", errs)
		defer jq.destroy_program(qprog)

		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer query.heap_destroy(&h)

		rows := query.make_array(&h, 3) or_else query.NULL
		r1, _ := read_value(&h, `{"k":null,"tag":"is-null"}`)
		r2, _ := query.make_object(&h, 2)
		_ = query.object_put(&h, &r2, query.text_borrowed("k"), query.double_value(transmute(f64)u64(0x7FF0000000000000)))
		_ = query.object_put(&h, &r2, query.text_borrowed("tag"), query.text_borrowed("is-pinf"))
		r3, _ := query.make_object(&h, 2)
		_ = query.object_put(&h, &r3, query.text_borrowed("k"), query.double_value(transmute(f64)u64(0xFFF0000000000000)))
		_ = query.object_put(&h, &r3, query.text_borrowed("tag"), query.text_borrowed("is-ninf"))
		_ = query.append_owned(&h, &rows, r1)
		_ = query.append_owned(&h, &rows, r2)
		_ = query.append_owned(&h, &rows, r3)
		defer query.release(&h, rows)

		idx_obj, ls := jq.join_lookup_object(&h, rows, kprog, .Last)
		testing.expect_value(t, ls, query.Status.Ok)

		vals := [3]query.Value{query.NULL, query.NULL, idx_obj}
		defer query.release(&h, vals[2])

		run: jq.Run
		jq.run_init(&run, qprog, &h, vals[:])
		outs := Outputs{h = &h}
		end := jq.run_value(&run, query.NULL, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		jq.run_destroy(&run)
		testing.expect_value(t, len(outs.vals), 1)
		if len(outs.vals) == 1 {
			testing.expect_value(t, show(&h, outs.vals[0]), `["is-null",null,"is-pinf","is-ninf"]`)
		}
		for v in outs.vals {
			query.release(&h, v)
		}
		delete(outs.vals)
	}

	// 4. `find_preamble_end` ignores `import1` / `moduleA` identifiers and handles `#...\<newline>` continuations.
	{
		p_id, e1 := jq.compile_with_joins("def import1: 7; import1")
		testing.expectf(t, len(e1) == 0, "import1 errors: %v", e1)
		if p_id != nil {
			jq.destroy_program(p_id)
		}

		p_mod, e2 := jq.compile_with_joins("def moduleA: 9; moduleA")
		testing.expectf(t, len(e2) == 0, "moduleA errors: %v", e2)
		if p_mod != nil {
			jq.destroy_program(p_mod)
		}
		p_cont, e3 := jq.compile_with_joins("# header \\\nstill comment with fake ; here\nmodule {};\ndef moduleA: . + 1; moduleA")
		testing.expectf(t, len(e3) == 0, "comment continuation errors: %v", e3)
		if p_cont != nil {
			jq.destroy_program(p_cont)
		}
	}

	// 5. `--stream` preserves `needs_facts` on reachable aux sources.
	{
		p_stream, e_stream := jq.compile(`{fact: .@comment, u: $users.name}`, {variables = {"users"}})
		testing.expect_value(t, len(e_stream), 0)
		defer jq.destroy_program(p_stream)

		plan, ok := jq.analyze_with_vars(p_stream, {"users", "unused"}, context.allocator, {stream = true})
		testing.expect(t, ok)
		defer query.destroy_plan(&plan)
		testing.expect(t, plan.sources[.Main].facts)
		ud, uok := query.aux_demand_for(&plan, "users")
		testing.expect(t, uok && ud.mode == .Whole && ud.facts)
		un, unok := query.aux_demand_for(&plan, "unused")
		testing.expect(t, unok && un.mode == .None && !un.facts)
	}
}
