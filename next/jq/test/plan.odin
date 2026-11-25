package jq_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
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
