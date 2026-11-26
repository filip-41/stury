package jq_tests

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

@(private = "file")
analyze_src :: proc(t: ^testing.T, src: string, opts := jq.Analyze_Options{}) -> (^jq.Program, jq.Plan) {
	prog, errs := jq.compile(src)
	testing.expectf(t, len(errs) == 0, "compile %q failed: %v", src, errs)
	return prog, jq.analyze(prog, opts)
}

@(private = "file")
has_path :: proc(s: ^query.Source_Demand, want_steps: []tape.Step, want_grain := tape.Grain.Whole, want_limit := 0) -> bool {
	for p in s.paths {
		if p.grain == want_grain && p.limit == want_limit && query.steps_equal(p.steps, want_steps) {
			return true
		}
	}
	return false
}

@(test)
plan_demand_paths_grains_and_limits :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Constant expression needs nothing from `.`.
	{
		prog, plan := analyze_src(t, `42`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.None)
	}

	// Single field, multi-field object, nested path.
	{
		prog, plan := analyze_src(t, `{a: .user.name, b: .scores[0]}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect_value(t, len(s.paths), 2)
		testing.expect(t, has_path(s, {tape.Name("user"), tape.Name("name")}, .Whole))
		testing.expect(t, has_path(s, {tape.Name("scores"), tape.Index(0)}, .Whole))
	}

	// Grains: `.Exists` for type/not/has, `.Keys` for length/keys.
	{
		prog, plan := analyze_src(t, `(.a | type), (.b | length), (.c | keys), has("d")`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("a")}, .Exists))
		testing.expect(t, has_path(s, {tape.Name("b")}, .Keys))
		testing.expect(t, has_path(s, {tape.Name("c")}, .Keys))
		testing.expect(t, has_path(s, {tape.Name("d")}, .Exists))
	}

	// Lexical variable tracking: `. as $r | $r.x + $r.y` demands only `.x` and `.y`.
	{
		prog, plan := analyze_src(t, `. as $r | $r.x + $r.y`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect_value(t, len(s.paths), 2)
		testing.expect(t, has_path(s, {tape.Name("x")}, .Whole))
		testing.expect(t, has_path(s, {tape.Name("y")}, .Whole))
	}

	// Object destructuring binding: `. as {a: $x, b: [$y]} | $x + $y`.
	{
		prog, plan := analyze_src(t, `. as {a: $x, b: [$y]} | $x + $y`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("a")}, .Whole))
		testing.expect(t, has_path(s, {tape.Name("b"), tape.Index(0)}, .Whole))
	}

	// Limits: `first(.items[].id)` gets limit=1; `first(.items[] | select(.ok) | .id)` does NOT limit.
	{
		prog, plan := analyze_src(t, `first(.items[].id)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{limit = 1}, tape.Name("id")}, .Whole, 1))
	}
	{
		prog, plan := analyze_src(t, `first(.items[] | select(.ok) | .id)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("id")}, .Whole, 0))
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("ok")}, .Exists, 0))
	}

	// `reduce .items[] as $x (0; . + $x.price)` demands only `.items[].price`.
	{
		prog, plan := analyze_src(t, `reduce .items[] as $x (0; . + $x.price)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("price")}, .Whole))
	}

	// User-defined function + memoization.
	{
		prog, plan := analyze_src(t, `def pick_id: .id; .items | map(pick_id)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("id")}, .Whole))
	}

	// Cost rule: `.[]` (all-`All` with no limit) degrades to `.Whole` with `.All_Steps_Only`.
	{
		prog, plan := analyze_src(t, `.[]`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Whole)
		testing.expect_value(t, plan.sources[.Main].reason, query.Whole_Reason.All_Steps_Only)
	}

	// Cost rule: >= 5 shallow leaves past unbounded `[]` degrades to `.Whole` (`.Too_Wide`),
	// whereas 2 fields, nested subtrees under `[]`, or `.Keys` subtree grains stay `.Partial`.
	{
		prog, plan := analyze_src(t, `.logs[] | select(.status == 500) | {id, ts, level, msg}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Whole)
		testing.expect_value(t, plan.sources[.Main].reason, query.Whole_Reason.Too_Wide)
	}
	{
		prog, plan := analyze_src(t, `.logs[] | select(.status == 500) | .id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)
	}
	{
		prog, plan := analyze_src(t, `.statuses[] | {id, text, name: .user.name, count: .retweet_count, lang}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)
	}
	{
		prog, plan := analyze_src(t, `.items[] | {a: (.a | length), b, c, d, e}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Partial)
	}

	// Stream mode forces `.Whole` with `.Stream_Mode`.
	{
		prog, plan := analyze_src(t, `.a`, {stream = true})
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.Whole)
		testing.expect_value(t, plan.sources[.Main].reason, query.Whole_Reason.Stream_Mode)
	}
}

@(test)
plan_sources_serial_hints_and_explain :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// `-n` (`null_input`) with `inputs | .id`: `.Main` is `.None`, `.Inputs` demands `.id`, `Serial.Inputs` set.
	{
		prog, plan := analyze_src(t, `[inputs | .id]`, {null_input = true})
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Main].mode, query.Demand_Mode.None)
		testing.expect_value(t, plan.sources[.Inputs].mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(&plan.sources[.Inputs], {tape.Name("id")}, .Whole))
		testing.expect(t, .Inputs in plan.serial)
	}

	// `-s` (`slurp`) with `map(.price) | add`: `.Slurp` demands `.price` per record.
	{
		prog, plan := analyze_src(t, `map(.price) | add`, {slurp = true})
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.sources[.Slurp].mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(&plan.sources[.Slurp], {tape.Name("price")}, .Whole))
	}

	// Serial flags: Position, Messages, Halts, Recurses.
	{
		prog, plan := analyze_src(t, `def f: if . > 0 then (. - 1 | f) else . end; input_filename, (debug | halt)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect(t, .Position in plan.serial)
		testing.expect(t, .Messages in plan.serial)
		testing.expect(t, .Halts in plan.serial)
	}
	{
		prog, plan := analyze_src(t, `def f: if . > 0 then (. - 1 | f) else . end; f`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect(t, .Recurses in plan.serial)
	}

	// Hint 1: Per_Element_Split (Stream, Collect, Length, Reduce).
	{
		prog, plan := analyze_src(t, `.items[] | .id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Stream)
		testing.expect(t, query.steps_equal(plan.hints.split.prefix, {tape.Name("items")}))
		testing.expect(t, plan.hints.split.has_each)
		testing.expect(t, plan.each_body != nil)
		testing.expect(t, has_path(&plan.hints.split.each_demand, {tape.Name("id")}, .Whole))
	}
	{
		prog, plan := analyze_src(t, `[.items[] | .val] | add`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Collect)
		testing.expect(t, plan.hints.split.has_each)
		testing.expect(t, plan.hints.split.has_tail)
		testing.expect(t, has_path(&plan.hints.split.each_demand, {tape.Name("val")}, .Whole))
	}
	{
		prog, plan := analyze_src(t, `.items | length`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Length)
		testing.expect(t, query.steps_equal(plan.hints.split.prefix, {tape.Name("items")}))
	}
	{
		prog, plan := analyze_src(t, `reduce .items[] as $x (0; . + $x.n)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Reduce)
		testing.expect(t, has_path(&plan.hints.split.each_demand, {tape.Name("n")}, .Whole))
	}

	// Hint 2: Projection_Template (Single, Stream, Array, Object).
	{
		prog, plan := analyze_src(t, `{a: .x, b: .y.z}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.projection.shape, query.Projection_Shape.Object)
		testing.expect_value(t, len(plan.hints.projection.fields), 2)
		testing.expect_value(t, plan.hints.projection.fields[0].key, "a")
		testing.expect(t, query.steps_equal(plan.hints.projection.fields[0].path, {tape.Name("x")}))
		testing.expect_value(t, plan.hints.projection.fields[1].key, "b")
		testing.expect(t, query.steps_equal(plan.hints.projection.fields[1].path, {tape.Name("y"), tape.Name("z")}))
		text := jq.explain_plan(&plan)
		testing.expect(t, strings.contains(text, "source main: partial"))
		testing.expect(t, strings.contains(text, "hint projection (object): a=.x, b=.y.z"))
	}

	// Hint 3: Conditional_Whole (simple compare and general predicate).
	{
		prog, plan := analyze_src(t, `select(.status == "ok")`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect(t, plan.hints.conditional.active)
		testing.expect(t, plan.pred_body != nil)
		testing.expect_value(t, plan.hints.conditional.cmp.op, query.Compare_Op.Eq)
		testing.expect(t, query.steps_equal(plan.hints.conditional.cmp.path, {tape.Name("status")}))
		testing.expect(t, has_path(&plan.hints.conditional.pred_demand, {tape.Name("status")}, .Whole))
		text := jq.explain_plan(&plan)
		testing.expect(t, strings.contains(text, "hint conditional_whole:"))
	}
	{
		prog, plan := analyze_src(t, `select(.qty | tonumber >= 9000)`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect(t, plan.hints.conditional.active)
		testing.expect_value(t, plan.hints.conditional.cmp.op, query.Compare_Op.None)
		testing.expect(t, has_path(&plan.hints.conditional.pred_demand, {tape.Name("qty")}, .Whole))
	}

	// Duplicate object keys bail out of Projection_Template; multi-stage pipes match Per_Element_Split.
	{
		prog, plan := analyze_src(t, `{a: .x[0], a: .y}`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.projection.shape, query.Projection_Shape.None)
	}
	{
		prog, plan := analyze_src(t, `.items[] | select(.ok) | .id`)
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Stream)
		testing.expect(t, plan.hints.split.has_each)
		testing.expect(t, has_path(&plan.hints.split.each_demand, {tape.Name("ok")}, .Exists))
		testing.expect(t, has_path(&plan.hints.split.each_demand, {tape.Name("id")}, .Whole))
	}
}

@(test)
plan_heap_allocator_no_leaks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Runs directly on the test runner's tracking allocator (no arena) so any allocator mismatch or leak fails the test.
	for src in ([?]string{
		`42`,
		`.logs[0].service`,
		`first(.logs[].id)`,
		`[.logs[] | {id, status}]`,
		`select(.status == 500)`,
		`{a: .x, b: .y} | .a`,
	}) {
		prog, errs := jq.compile(src)
		testing.expect(t, len(errs) == 0)
		plan := jq.analyze(prog)
		exp := jq.explain_plan(&plan)
		delete(exp)
		jq.destroy_plan(&plan)
		jq.destroy_program(prog)
	}
}

@(test)
plan_postfix_splits_identity_and_run_count :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. `is_identity` accurately distinguishes `.` from any other program.
	{
		p_id, _ := jq.compile(`.`)
		defer jq.destroy_program(p_id)
		p_lit, _ := jq.compile(`42`)
		defer jq.destroy_program(p_lit)
		p_fld, _ := jq.compile(`.a`)
		defer jq.destroy_program(p_fld)
		testing.expect(t, jq.is_identity(p_id))
		testing.expect(t, !jq.is_identity(p_lit))
		testing.expect(t, !jq.is_identity(p_fld))
		testing.expect(t, !jq.is_identity(nil))
	}

	// 2. Postfix chain Hint 1 splits (`.logs[].msg | ...`, `.[].msg | arrays | .[-1]`, `.logs[][]`).
	{
		p1, pl1 := analyze_src(t, `.logs[].msg | ascii_upcase`, {materialize_each = true})
		defer jq.destroy_program(p1)
		defer jq.destroy_plan(&pl1)
		testing.expect_value(t, pl1.hints.split.kind, query.Split_Kind.Stream)
		testing.expect(t, query.steps_equal(pl1.hints.split.prefix, {tape.Name("logs")}))
		testing.expect(t, pl1.hints.split.has_each)
		testing.expect(t, pl1.each_body != nil)
		testing.expect(t, has_path(&pl1.hints.split.each_demand, {tape.Name("msg")}, .Whole))
	}
	{
		p2, pl2 := analyze_src(t, `.[].msg | arrays | .[-1]`, {materialize_each = true})
		defer jq.destroy_program(p2)
		defer jq.destroy_plan(&pl2)
		testing.expect_value(t, pl2.hints.split.kind, query.Split_Kind.Stream)
		testing.expect_value(t, len(pl2.hints.split.prefix), 0)
		testing.expect(t, pl2.hints.split.has_each)
		testing.expect(t, pl2.each_body != nil)
	}
	{
		p3, pl3 := analyze_src(t, `.logs[][]`, {materialize_each = true})
		defer jq.destroy_program(p3)
		defer jq.destroy_plan(&pl3)
		testing.expect_value(t, pl3.hints.split.kind, query.Split_Kind.Stream)
		testing.expect(t, query.steps_equal(pl3.hints.split.prefix, {tape.Name("logs")}))
		testing.expect(t, pl3.hints.split.has_each)
	}

	// 3. `[.logs[].msg | splits(" +")] | length` emits `.Length` + `each_body` and `run_count` matches `run_value`.
	{
		prog, plan := analyze_src(t, `[.logs[].msg | splits(" +")] | length`, {materialize_each = true})
		defer jq.destroy_program(prog)
		defer jq.destroy_plan(&plan)
		testing.expect_value(t, plan.hints.split.kind, query.Split_Kind.Length)
		testing.expect(t, plan.hints.split.has_each)
		testing.expect(t, query.steps_equal(plan.hints.split.prefix, {tape.Name("logs")}))
		testing.expect(t, plan.each_body != nil)

		each_prog := prog^
		each_prog.body = plan.each_body

		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer query.heap_destroy(&h)

		run_cnt, run_val: jq.Run
		jq.run_init(&run_cnt, &each_prog, &h, nil)
		defer jq.run_destroy(&run_cnt)
		jq.run_init(&run_val, &each_prog, &h, nil)
		defer jq.run_destroy(&run_val)

		inp1, ok1 := read_owned_json(&h, `{"msg":"alpha beta  gamma"}`)
		testing.expect(t, ok1)
		cnt, end1 := jq.run_count(&run_cnt, inp1)
		testing.expect_value(t, end1, jq.Run_End.Done)
		testing.expect_value(t, cnt, u64(3))

		inp2, ok2 := read_owned_json(&h, `{"msg":"alpha beta  gamma"}`)
		testing.expect(t, ok2)
		outs := Outputs{h = &h}
		outs.vals = make([dynamic]query.Value, context.allocator)
		defer {
			for v in outs.vals {
				query.release(&h, v)
			}
			delete(outs.vals)
		}
		end2 := jq.run_value(&run_val, inp2, collect, &outs)
		testing.expect_value(t, end2, jq.Run_End.Done)
		testing.expect_value(t, u64(len(outs.vals)), cnt)
	}
}

@(test)
jq_fast_paths_sub_group_by_and_tally_parity :: proc(t: ^testing.T) {
	testkit.deadline(t)

	eval_oracle :: proc(t: ^testing.T, filter, input_json: string, steps_budget := 0) -> (string, jq.Run_End) {
		prog, errs := jq.compile(filter)
		testing.expectf(t, len(errs) == 0, "compile %q failed: %v", filter, errs)
		defer jq.destroy_program(prog)

		h: query.Heap
		query.heap_init(&h, context.allocator)
		defer query.heap_destroy(&h)

		inp, ok := read_owned_json(&h, input_json)
		testing.expect(t, ok)

		run: jq.Run
		jq.run_init(&run, prog, &h, nil, steps = steps_budget)
		defer jq.run_destroy(&run)

		outs := Outputs{h = &h}
		outs.vals = make([dynamic]query.Value, context.allocator)
		defer {
			for v in outs.vals {
				query.release(&h, v)
			}
			delete(outs.vals)
		}
		end := jq.run_value(&run, inp, collect, &outs)
		if end != .Done {
			return "", end
		}
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		for v, i in outs.vals {
			if i > 0 {
				strings.write_byte(&sb, '\n')
			}
			s := show(&h, v)
			defer delete(s)
			strings.write_string(&sb, s)
		}
		return strings.clone(strings.to_string(sb)), end
	}

	// 1. Differential parity for `eval_sub_fast` (`steps = 0`) vs VM `def sub`/`gsub` (`steps = 1_000_000`).
	sub_cases := [?][2]string {
		{`gsub("zzz"; "x")`, `"hello world"`},
		{`gsub("a"; "_")`, `"abracadabra"`},
		{`sub("a"; "_")`, `"abracadabra"`},
		{`gsub("\\b(?<w>[a-z])"; "\(.w | ascii_upcase)")`, `"auth timeout retrying request 42"`},
		{`gsub("(?<w>x)|(?<w>y)"; "[\(.w)]")`, `"x1y2z"`},
		{`gsub(""; "!")`, `"ab"`},
		{`gsub("(?<c>[a-z])"; "\(.c | ascii_upcase)"; "i")`, `"café résumé"`},
		{`sub("a"; "X"; "g")`, `"banana"`},
		{`gsub("a"; empty)`, `"banana"`},
		{`gsub("a"; "X"; "Q")`, `"banana"`},
		{`gsub("a"; "b")`, `123`},
	}
	for sc in sub_cases {
		fast_out, fast_end := eval_oracle(t, sc[0], sc[1], 0)
		defer delete(fast_out)
		vm_out, vm_end := eval_oracle(t, sc[0], sc[1], 1_000_000)
		defer delete(vm_out)
		testing.expect_value(t, fast_end, vm_end)
		testing.expectf(t, fast_out == vm_out, "%s on %s: fast=%q != vm=%q", sc[0], sc[1], fast_out, vm_out)
	}

	// 2. Differential parity for `group_by_string_keys`: low-cardinality, escaped strings, mixed types, and high-cardinality fallback.
	{
		sb := strings.builder_make()
		defer strings.builder_destroy(&sb)
		strings.write_byte(&sb, '[')
		keys := [?]string{"db", "auth", "", "api", "a\\nb"}
		for i in 0 ..< 90 {
			if i > 0 {
				strings.write_byte(&sb, ',')
			}
			fmt.sbprintf(&sb, "{{\"k\":\"%s\",\"id\":%d}}", keys[i % len(keys)], i)
		}
		strings.write_byte(&sb, ']')
		arr_json := strings.to_string(sb)

		o_fast, e_fast := eval_oracle(t, `group_by(.k) | map([.[0].k, length, .[0].id, .[-1].id])`, arr_json)
		defer delete(o_fast)
		o_ref, e_ref := eval_oracle(t, `_group_by_impl(map([.k])) | map([.[0].k, length, .[0].id, .[-1].id])`, arr_json)
		defer delete(o_ref)
		testing.expect_value(t, e_fast, jq.Run_End.Done)
		testing.expect_value(t, e_ref, jq.Run_End.Done)
		testing.expect_value(t, o_fast, o_ref)

		// Mixed scalar keys + high cardinality (> n/2 distinct keys) fallback parity.
		mb := strings.builder_make()
		defer strings.builder_destroy(&mb)
		strings.write_byte(&mb, '[')
		for i in 0 ..< 80 {
			if i > 0 {
				strings.write_byte(&mb, ',')
			}
			fmt.sbprintf(&mb, "{{\"k\":\"u_%d\",\"i\":%d}}", i, i)
		}
		strings.write_byte(&mb, ']')
		hi_json := strings.to_string(mb)
		hf, he := eval_oracle(t, `group_by(.k) | length`, hi_json)
		defer delete(hf)
		hr, hre := eval_oracle(t, `_group_by_impl(map([.k])) | length`, hi_json)
		defer delete(hr)
		testing.expect_value(t, he, hre)
		testing.expect_value(t, hf, hr)

		xb := strings.builder_make()
		defer strings.builder_destroy(&xb)
		strings.write_byte(&xb, '[')
		for i in 0 ..< 70 {
			if i > 0 {
				strings.write_byte(&xb, ',')
			}
			if i % 5 == 0 {
				fmt.sbprintf(&xb, "{{\"k\":%d}}", i)
			} else {
				fmt.sbprintf(&xb, "{{\"k\":\"s%d\"}}", i % 3)
			}
		}
		strings.write_byte(&xb, ']')
		mix_json := strings.to_string(xb)
		mf, me := eval_oracle(t, `group_by(.k) | map(length)`, mix_json)
		defer delete(mf)
		mr, mre := eval_oracle(t, `_group_by_impl(map([.k])) | map(length)`, mix_json)
		defer delete(mr)
		testing.expect_value(t, me, mre)
		testing.expect_value(t, mf, mr)
	}

	// 3. Differential parity for `tally_container_length`: `[.features[].coords[][]] | length`, optional, scalar errors.
	tally_doc := `{"features":[{"coords":[[[1,2],[3,4]],[[5,6]]]},{"coords":[[[7,8]]]}]}`
	for expr in ([?]string{
		`[.features[].coords[][]] | length`,
		`[.features[].coords[][]?] | length`,
		`[(1, 2, 3) | .[]?] | length`,
		`[(1, empty) | .[]] | length`,
	}) {
		tf, te := eval_oracle(t, expr, tally_doc, 0)
		defer delete(tf)
		tv, tve := eval_oracle(t, expr, tally_doc, 100_000)
		defer delete(tv)
		testing.expect_value(t, te, tve)
		testing.expectf(t, tf == tv, "tally %s: fast=%q != vm=%q", expr, tf, tv)
	}

	// 4. B5: `eval_sub_fast` must not UAF `re` when `rep_node` compiles >= 64 regexes (`mem.dynamic_arena_reset`).
	{
		rb := strings.builder_make()
		defer strings.builder_destroy(&rb)
		strings.write_string(&rb, `if ([`)
		for i in 0 ..< 68 {
			if i > 0 {
				strings.write_byte(&rb, ',')
			}
			fmt.sbprintf(&rb, `("x" | test("p%d"))`, i)
		}
		strings.write_string(&rb, `][67]) then "b" else "c" end`)
		rep := strings.to_string(rb)

		f1 := fmt.aprintf(`gsub("a"; %s)`, rep)
		defer delete(f1)
		o_fast1, e_fast1 := eval_oracle(t, f1, `"aa"`, 0)
		defer delete(o_fast1)
		o_vm1, e_vm1 := eval_oracle(t, f1, `"aa"`, 1_000_000)
		defer delete(o_vm1)
		testing.expect_value(t, e_fast1, jq.Run_End.Done)
		testing.expect_value(t, e_vm1, jq.Run_End.Done)
		testing.expect_value(t, o_fast1, `"cc"`)
		testing.expect_value(t, o_fast1, o_vm1)

		f2 := fmt.aprintf(`gsub("(?<x>a)"; %s)`, rep)
		defer delete(f2)
		o_fast2, e_fast2 := eval_oracle(t, f2, `"aa"`, 0)
		defer delete(o_fast2)
		o_vm2, e_vm2 := eval_oracle(t, f2, `"aa"`, 1_000_000)
		defer delete(o_vm2)
		testing.expect_value(t, e_fast2, jq.Run_End.Done)
		testing.expect_value(t, e_vm2, jq.Run_End.Done)
		testing.expect_value(t, o_fast2, `"cc"`)
		testing.expect_value(t, o_fast2, o_vm2)
	}
}

// Regression (B6): `used_globals_of` and `analyze_with_vars` run iteratively without stack overflow on 20,000+ deep filters.
@(test)
regression_used_globals_iterative_deep_filter :: proc(t: ^testing.T) {
	testkit.deadline(t)

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for _ in 0 ..< 20_000 {
		strings.write_string(&sb, ".a")
	}
	strings.write_string(&sb, " | $g")

	ext := [?]string{"unused", "g"}
	prog, errs := jq.compile(strings.to_string(sb), {variables = ext[:]})
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(errs), 0)

	used := jq.used_globals_of(prog)
	defer delete(used)
	testing.expect(t, len(used) == 4)
	testing.expect(t, !used[0])
	testing.expect(t, !used[1])
	testing.expect(t, !used[2])
	testing.expect(t, used[3])

	cplan, ok := jq.analyze_with_vars(prog, ext[:])
	defer query.destroy_plan(&cplan)
	testing.expect(t, ok)
	testing.expect_value(t, cplan.sources[.Main].mode, query.Demand_Mode.Whole)
}

@(private = "file")
read_owned_json :: proc(h: ^query.Heap, text: string) -> (query.Value, bool) {
	src := transmute([]u8)strings.clone(text)
	doc, err := json.build(src, .Json, {}, context.allocator)
	if err != nil {
		delete(src)
		return query.NULL, false
	}
	doc.flags += {.Owns_Src}
	v, s := query.document_value(h, doc, true)
	return v, s == .Ok
}
