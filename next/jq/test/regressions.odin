#+feature dynamic-literals
package jq_tests

import "base:intrinsics"
import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(private = "file")
eval_expr :: proc(t: ^testing.T, src, input_json: string, hooks: ^jq.Hooks = nil, steps := 0, mem_limit := u64(0), loc := #caller_location) -> (out: string, end: jq.Run_End, err_kind: query.Error_Kind) {
	r := eval_jq(t, src, {
		input_json = input_json,
		hooks      = hooks,
		steps      = steps,
		mem_limit  = mem_limit,
		append_err = true,
	}, loc = loc)
	return r.out, r.end, r.err_kind
}

@(test)
run_reuse_after_halt_error_does_not_leak :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	prog, errors := jq.compile(`if . == 1 then "boom" | halt_error(7) else . + 10 end`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(errors), 0)

	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator())
	defer query.heap_destroy(&h)
	run: jq.Run
	jq.run_init(&run, prog, &h, nil)

	outs := Outputs{h = &h}
	testing.expect_value(t, jq.run_value(&run, query.int_value(1), collect, &outs), jq.Run_End.Halted)
	hs := jq.run_halt(&run)
	testing.expect(t, hs.halted)
	testing.expect_value(t, hs.code, 7)
	testing.expect_value(t, query.text_of(hs.value), "boom")

	// Second run on the same Run must release prior halt.value and reset halt state.
	testing.expect_value(t, jq.run_value(&run, query.int_value(2), collect, &outs), jq.Run_End.Done)
	testing.expect(t, !jq.run_halt(&run).halted)
	testing.expect_value(t, len(outs.vals), 1)
	testing.expect_value(t, outs.vals[0].i, i64(12))
	query.release(&h, outs.vals[0])
	jq.run_destroy(&run)
	testing.expect_value(t, query.heap_live(&h), u64(0))
}

@(test)
budget_and_memory_errors_are_uncatchable :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Step budget in generator (range), try/catch, ?, and // must NOT catch budget failure.
	_, end1, k1 := eval_expr(t, `try ([range(100000)]) catch "caught"`, "null", steps = 200)
	testing.expect_value(t, end1, jq.Run_End.Failed)
	testing.expect_value(t, k1, query.Error_Kind.Budget)

	_, end2, k2 := eval_expr(t, `([range(100000)]?) // "fallback"`, "null", steps = 200)
	testing.expect_value(t, end2, jq.Run_End.Failed)
	testing.expect_value(t, k2, query.Error_Kind.Budget)

	// Step budget in native_map and v_add loops.
	big_arr := strings.concatenate({"[", strings.repeat("1,", 500), "1]"})
	_, end3, k3 := eval_expr(t, `try (map(. + 1)) catch "caught"`, big_arr, steps = 100)
	testing.expect_value(t, end3, jq.Run_End.Failed)
	testing.expect_value(t, k3, query.Error_Kind.Budget)

	// Memory budget is uncatchable by try/catch and enforced in fromjson.
	_, end4, k4 := eval_expr(t, `try ("a" * .) catch "caught"`, "1000000", mem_limit = 8192)
	testing.expect_value(t, end4, jq.Run_End.Failed)
	testing.expect_value(t, k4, query.Error_Kind.Memory)

	deep_json := strings.concatenate({`"`, strings.repeat("[", 400), strings.repeat("]", 400), `"`})
	_, end5, k5 := eval_expr(t, `try fromjson catch "caught"`, deep_json, mem_limit = 4096)
	testing.expect_value(t, end5, jq.Run_End.Failed)
	testing.expect_value(t, k5, query.Error_Kind.Memory)
}

@(test)
destructuring_folds_shorthand_getpath_and_updates :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Single-pattern key resolves in outer scope.
	out, end, _ := eval_expr(t, `1 as $x | {"1": 2} as {($x|tostring): $x} | $x`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "2")

	// Generating keys inside ?// and reduce and foreach.
	out, end, _ = eval_expr(t, `[({"a":1,"b":2}) as {("a","b"): $x} ?// $y | [$x, $y]]`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[[1,null],[2,null]]`)

	out, end, _ = eval_expr(t, `reduce ({"a":1,"b":2}) as {("a","b"): $x} (0; . + $x)`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "3")

	// ?// alternatives in reduce and foreach.
	out, end, _ = eval_expr(t, `reduce ([7], 8) as [$a] ?// $a ([]; . + [$a])`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "[7,8]")

	out, end, _ = eval_expr(t, `[foreach ([7], 8) as [$a] ?// $a (0; . + $a)]`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "[7,15]")

	// path(foreach ... (init; upd; extract)) raises invalid path error.
	out, end, _ = eval_expr(t, `try path(foreach 1 as $x (0; . + 1; .)) catch .`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `"Invalid path expression with result 1"`)

	out, end, _ = eval_expr(t, `try path(foreach [1] as $x ({"a":1}; .; .a)) catch .`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `"Invalid path expression near attempt to access element \"a\" of {\"a\":1}"`)

	// Object shorthand with generating interpolation evaluates once per key (2 objects, not 4).
	out, end, _ = eval_expr(t, `[{"a\(1,2)"}]`, `{"a1":10,"a2":20}`)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[{"a1":10},{"a2":20}]`)

	// Overlapping |= paths with empty RHS do not see NULL.
	out, end, _ = eval_expr(t, `(.a, .a[0]) |= if type == "array" then empty else . + 1 end`, `{"a":[1,2]}`)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `{}`)

	// getpath($p) with .Node path array from input document.
	out, end, _ = eval_expr(t, `.p as $p | path(.d | getpath($p)), (.d | getpath($p) |= . + 1)`, `{"p":["a",1],"d":{"a":[10,20]}}`)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "[\"d\",\"a\",1]\n{\"a\":[10,21]}")

	// Number classification on big integers (.Big and .Node).
	huge := strings.concatenate({"1", strings.repeat("0", 400)})
	out, end, _ = eval_expr(t, `[isinfinite, isnan, isnormal], ((. + 1) | [isinfinite, isnan, isnormal])`, huge)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "[false,false,true]\n[false,false,true]")

	// Native simple updates (depth 0, 1, 2; =, +=, |=, //=, empty).
	out, end, _ = eval_expr(t, `reduce range(5) as $i ({}; .["k" + ($i|tostring)] += $i) | .k3 |= empty | .k2 //= 99 | .sub.v = 7`, "null")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `{"k0":0,"k1":1,"k2":2,"k4":4,"sub":{"v":7}}`)
}

@(test)
hooks_modules_data_seq_toarray_removed_and_partial_css :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// input_line_number hook.
	line_fn :: proc(data: rawptr) -> i64 { return 42 }
	hooks := jq.Hooks{input_line_number = line_fn, parse_json = parse_json_hook}
	out, end, _ := eval_expr(t, `input_line_number`, "null", &hooks)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "42")

	// toarray/0 is removed.
	_, errs := jq.compile(`toarray`)
	testing.expect(t, len(errs) > 0)

	// import "data" as $d with multi-value JSON sequence.
	files := Memory_Files {
		"/m/seq.json" = "1\n2 {\"a\":3}\n",
	}
	mods := jq.Modules {
		loader = {data = &files, read = read_memory, parse_json = parse_json_hook},
		search = {"/m"},
	}
	testing.expect_value(t, eval(t, `import "seq" as $s; $s`, mods), `[1,2,{"a":3}]`)

	// css on partial XML document taints heap and aborts uncatchably (not caught by try) with 0 outputs.
	prog, perrs := jq.compile(`[try css("li") catch "err"]`)
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(perrs), 0)
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator())
	defer query.heap_destroy(&h)
	src := transmute([]u8)strings.clone(`<ul><li>a</li><li>b</li></ul>`, runtime.heap_allocator())
	doc, derr := xml.build(src, .Xml, {}, runtime.heap_allocator())
	testing.expect(t, derr == nil)
	doc.flags += {.Owns_Src}
	part := new(tape.Partial, runtime.heap_allocator())
	doc.partial = part
	inp, is := query.document_value(&h, doc, true)
	testing.expect_value(t, is, query.Status.Ok)
	run: jq.Run
	css_hooks := jq.Hooks{markup = xml_markup}
	jq.run_init(&run, prog, &h, nil, &css_hooks)
	outs := Outputs{h = &h}
	rend := jq.run_value(&run, inp, collect, &outs)
	testing.expect_value(t, rend, jq.Run_End.Tainted)
	testing.expect(t, h.tainted)
	testing.expect_value(t, len(outs.vals), 0)
	jq.run_destroy(&run)
	testing.expect_value(t, query.heap_live(&h), u64(0))
}

@(test)
perf_paths_negative_zero_c1_and_partial_doc_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// `int_to_text` + `object_put` + `native_update` fast paths across zero, negatives, int64 bounds, COW aliasing, and errors.
	out_ts, end_ts, _ := eval_expr(t, `[0, -1, 42, -9223372036854775808, 9223372036854775807] | map(tostring)`, "null")
	testing.expect_value(t, end_ts, jq.Run_End.Done)
	testing.expect_value(t, out_ts, `["0","-1","42","-9223372036854775808","9223372036854775807"]`)

	out_c1, end_c1, _ := eval_expr(t, `(reduce range(40) as $i ({}; .[$i|tostring] = $i) | length), ({a:1} as $o | [$o, ($o | .a = 2 | .b = 3)])`, "null")
	testing.expect_value(t, end_c1, jq.Run_End.Done)
	testing.expect_value(t, out_c1, "40\n[{\"a\":1},{\"a\":2,\"b\":3}]")

	out_kerr, end_kerr, _ := eval_expr(t, `try ({} | .[123] = 1) catch "badkey"`, "null")
	testing.expect_value(t, end_kerr, jq.Run_End.Done)
	testing.expect_value(t, out_kerr, `"badkey"`)

	// `.Node` negative-zero and float arithmetic must not collapse `.Float` nodes into `.Int`, while integer comparisons work fast.
	out_nz, end_nz, _ := eval_expr(t, `[(atan2(0; .z * 1) > 3), (atan2(0; .z + .z) > 3), (.z == 0), (.f + 0), (.f == 1), (.n == 500), (.n + 1)]`, `{"z": -0.0, "f": 1.0, "n": 500}`)
	testing.expect_value(t, end_nz, jq.Run_End.Done)
	testing.expect_value(t, out_nz, `[true,true,true,1,true,true,501]`)

	// Partial `json.scan` matches `json.build` exactly on filtered log records (zero taints, zero leaks).
	logs_src := `{"meta":"skip","logs":[{"ts":"t1","status":200,"id":"a","extra":[1,2]},{"ts":"t2","status":500,"id":"b","extra":{"x":9}},{"ts":"t3","status":404,"id":"c"}]}`
	for pair in ([3][2]string{
		{`.logs[] | select(.status == 500) | .id`, `"b"`},
		{`.logs[] | select(.status >= 400) | .id`, "\"b\"\n\"c\""},
		{`.logs[] | select(.status >= 400) | {ts, id}`, "{\"ts\":\"t2\",\"id\":\"b\"}\n{\"ts\":\"t3\",\"id\":\"c\"}"},
	}) {
		qsrc, want := pair[0], pair[1]
		prog, errs := jq.compile(qsrc)
		testing.expect_value(t, len(errs), 0)
		defer jq.destroy_program(prog)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)

		h: query.Heap
		query.heap_init(&h, runtime.heap_allocator())
		defer query.heap_destroy(&h)

		src := transmute([]u8)logs_src
		bdoc, berr := json.build(src, .Json, {}, runtime.heap_allocator())
		testing.expect_value(t, berr, nil)
		sdoc, serr := json.scan(src, &plan.sources[.Main].demand, .Json, {}, {}, runtime.heap_allocator())
		testing.expect_value(t, serr, nil)

		run_doc :: proc(t: ^testing.T, prog: ^jq.Program, h: ^query.Heap, doc: tape.Document) -> string {
			v, st := query.document_value(h, doc, true)
			testing.expect_value(t, st, query.Status.Ok)
			r: jq.Run
			jq.run_init(&r, prog, h, nil)
			defer jq.run_destroy(&r)
			outs := Outputs{h = h}
			end := jq.run_value(&r, v, collect, &outs)
			testing.expect_value(t, end, jq.Run_End.Done)
			testing.expect(t, !h.tainted)
			lines := make([dynamic]string, context.temp_allocator)
			for item in outs.vals {
				append(&lines, show(h, item))
				query.release(h, item)
			}
			return strings.join(lines[:], "\n", context.temp_allocator)
		}
		whole_out := run_doc(t, prog, &h, bdoc)
		scan_out := run_doc(t, prog, &h, sdoc)
		testing.expect_value(t, whole_out, want)
		testing.expect_value(t, scan_out, want)
		testing.expect_value(t, query.heap_live(&h), u64(0))
	}
}

@(test)
cancel_flag_aborts_uncatchably_and_preserves_steps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// 1. Pre-set cancel flag immediately aborts infinite `repeat(.)` and cannot be caught by `try`, `?`, or `//`.
	for src in ([3]string{`repeat(.)`, `try (repeat(.)) catch "caught"`, `(repeat(.)?) // "fallback"`}) {
		prog, errs := jq.compile(src)
		testing.expect_value(t, len(errs), 0)
		defer jq.destroy_program(prog)

		h: query.Heap
		query.heap_init(&h, runtime.heap_allocator())
		defer query.heap_destroy(&h)

		flag: u32 = 1
		run: jq.Run
		jq.run_init(&run, prog, &h, nil, jq.Run_Options{cancel = &flag})

		outs := Outputs{h = &h}
		defer delete(outs.vals)
		end := jq.run_value(&run, query.int_value(1), collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Failed)
		testing.expect(t, jq.run_cancelled(&run))
		testing.expect_value(t, len(outs.vals), 0)
		e := query.take_error(&h)
		testing.expect_value(t, e.kind, query.Error_Kind.Budget)
		testing.expect_value(t, jq.error_message(&h, &e), "Cancelled")
		query.destroy_error(&h, &e)
		jq.run_destroy(&run)
		testing.expect_value(t, query.heap_live(&h), u64(0))
	}

	// 2. Flipping cancel flag mid-run stops `try (repeat(.)) catch "caught"` uncatchably within a chunk.
	{
		prog, errs := jq.compile(`try (repeat(.)) catch "caught"`)
		testing.expect_value(t, len(errs), 0)
		defer jq.destroy_program(prog)

		h: query.Heap
		query.heap_init(&h, runtime.heap_allocator())
		defer query.heap_destroy(&h)

		Mid_Ctx :: struct {
			flag:  ^u32,
			count: int,
		}
		on_out :: proc(data: rawptr, v: query.Value, hp: ^query.Heap) -> bool {
			c := (^Mid_Ctx)(data)
			query.release(hp, v)
			c.count += 1
			if c.count == 3 {
				intrinsics.atomic_store_explicit(c.flag, 1, .Relaxed)
			}
			return true
		}

		flag: u32 = 0
		ctx := Mid_Ctx{flag = &flag}
		run: jq.Run
		jq.run_init(&run, prog, &h, nil, jq.Run_Options{cancel = &flag})

		end := jq.run_value(&run, query.int_value(7), on_out, &ctx)
		testing.expect_value(t, end, jq.Run_End.Failed)
		testing.expect(t, jq.run_cancelled(&run))
		testing.expect(t, ctx.count >= 3 && ctx.count <= 300)
		e := query.take_error(&h)
		testing.expect_value(t, e.kind, query.Error_Kind.Budget)
		query.destroy_error(&h, &e)
		jq.run_destroy(&run)
		testing.expect_value(t, query.heap_live(&h), u64(0))
	}

	// 3. Unset cancel flag (`0`) allows multi-chunk completion AND still honors explicit step budgets.
	{
		prog, errs := jq.compile(`[range(600)] | length`)
		testing.expect_value(t, len(errs), 0)
		defer jq.destroy_program(prog)

		h: query.Heap
		query.heap_init(&h, runtime.heap_allocator())
		defer query.heap_destroy(&h)

		flag: u32 = 0
		run: jq.Run
		jq.run_init(&run, prog, &h, nil, jq.Run_Options{cancel = &flag})
		outs := Outputs{h = &h}
		end := jq.run_value(&run, query.NULL, collect, &outs)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect(t, !jq.run_cancelled(&run))
		testing.expect_value(t, len(outs.vals), 1)
		testing.expect_value(t, outs.vals[0].i, i64(600))
		query.release(&h, outs.vals[0])
		delete(outs.vals)
		jq.run_destroy(&run)

		// With explicit step budget of 300 (crossing a 256-step chunk) and unset cancel flag -> fails as budget, not cancelled.
		run2: jq.Run
		jq.run_init(&run2, prog, &h, nil, jq.Run_Options{steps = 300, cancel = &flag})
		outs2 := Outputs{h = &h}
		end2 := jq.run_value(&run2, query.NULL, collect, &outs2)
		testing.expect_value(t, end2, jq.Run_End.Failed)
		testing.expect(t, !jq.run_cancelled(&run2))
		e2 := query.take_error(&h)
		testing.expect_value(t, e2.kind, query.Error_Kind.Budget)
		testing.expect_value(t, jq.error_message(&h, &e2), "Budget exceeded")
		query.destroy_error(&h, &e2)
		for v in outs2.vals {
			query.release(&h, v)
		}
		delete(outs2.vals)
		jq.run_destroy(&run2)
		testing.expect_value(t, query.heap_live(&h), u64(0))
	}
}
