package jsonpath_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import "stury:json"
import "stury:jsonpath"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

@(private = "file")
has_path :: proc(s: ^query.Source_Demand, want_steps: []tape.Step, want_grain := tape.Grain.Whole) -> bool {
	for p in s.paths {
		if p.grain == want_grain && query.steps_equal(p.steps, want_steps) {
			return true
		}
	}
	return false
}

@(test)
plan_demands_and_hints :: proc(t: ^testing.T) {
	testkit.deadline(t)

	// 1. Static single path -> Partial demand + Hint 2 Projection (Single).
	{
		prog, err := jsonpath.compile(`$.a.b[0].c`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		s := &prog.plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("a"), tape.Name("b"), tape.Index(0), tape.Name("c")}, .Whole))
		testing.expect_value(t, prog.plan.hints.projection.shape, query.Projection_Shape.Single)
		testing.expect_value(t, len(prog.plan.hints.projection.fields), 1)
	}

	// 2. Multi-selector static projection -> Partial + Hint 2 Projection (Stream).
	{
		prog, err := jsonpath.compile(`$.user['id', 'name']`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		s := &prog.plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("user"), tape.Name("id")}, .Whole))
		testing.expect(t, has_path(s, {tape.Name("user"), tape.Name("name")}, .Whole))
		testing.expect_value(t, prog.plan.hints.projection.shape, query.Projection_Shape.Stream)
		testing.expect_value(t, len(prog.plan.hints.projection.fields), 2)
	}

	// 3. Filter demand + Hint 1 (Per-Element Split): `$.items[?@.status >= 500].id`.
	{
		prog, err := jsonpath.compile(`$.items[?@.status >= 500].id`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		s := &prog.plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("status")}, .Exists))
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("id")}, .Whole))

		sp := &prog.plan.hints.split
		testing.expect_value(t, sp.kind, query.Split_Kind.Stream)
		testing.expect(t, query.steps_equal(sp.prefix, {tape.Name("items")}))
		testing.expect(t, sp.has_each)
		testing.expect_value(t, sp.each_demand.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(&sp.each_demand, {tape.Name("status")}, .Exists))
		testing.expect(t, has_path(&sp.each_demand, {tape.Name("id")}, .Whole))
	}

	// 4. Wildcard Hint 1 (Per-Element Split): `$[*].id` and `$.items[*].name`.
	{
		prog, err := jsonpath.compile(`$[*].id`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		sp := &prog.plan.hints.split
		testing.expect_value(t, sp.kind, query.Split_Kind.Stream)
		testing.expect_value(t, len(sp.prefix), 0)
		testing.expect(t, sp.has_each)
		testing.expect(t, has_path(&sp.each_demand, {tape.Name("id")}, .Whole))
	}

	// 5. Filter referencing root `$` contributes to root demand and disables Per-Element Split.
	{
		prog, err := jsonpath.compile(`$.items[?@.price <= $.max_price].name`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		s := &prog.plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("price")}, .Whole))
		testing.expect(t, has_path(s, {tape.Name("items"), tape.All{}, tape.Name("name")}, .Whole))
		testing.expect(t, has_path(s, {tape.Name("max_price")}, .Whole))
		testing.expect_value(t, prog.plan.hints.split.kind, query.Split_Kind.None)
	}

	// 6. Terminal element filters (`$.items[?@.status == "err"]`, `$[?400 <= @.code]`):
	// Represented as `hints.split` (`Per_Element_Split`), NOT root-level `hints.conditional` (`Conditional_Whole`
	// in `lib/query/plan.odin` is rooted at `.`, whereas JSONPath `[?pred]` always filters container elements).
	{
		prog, err := jsonpath.compile(`$.items[?@.status == "err"]`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		sp := &prog.plan.hints.split
		testing.expect_value(t, sp.kind, query.Split_Kind.Stream)
		testing.expect(t, query.steps_equal(sp.prefix, {tape.Name("items")}))
		testing.expect(t, sp.has_each)
		testing.expect_value(t, sp.each_demand.mode, query.Demand_Mode.Whole)
		testing.expect(t, !prog.plan.hints.conditional.active)

		txt := jsonpath.explain_plan(&prog.plan)
		defer delete(txt)
		testing.expect(t, strings.contains(txt, "hint split (stream):"))
		testing.expect(t, !strings.contains(txt, "hint conditional_whole:"))
	}
	{
		prog, err := jsonpath.compile(`$[?400 <= @.code]`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)

		sp := &prog.plan.hints.split
		testing.expect_value(t, sp.kind, query.Split_Kind.Stream)
		testing.expect_value(t, len(sp.prefix), 0)
		testing.expect(t, sp.has_each)
		testing.expect(t, !prog.plan.hints.conditional.active)
	}

	// 7. Root `$` and `$..id` demand Whole; `$.sub..id` narrows to Partial (`$.sub` whole)!
	{
		prog, err := jsonpath.compile(`$`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)
		testing.expect_value(t, prog.plan.sources[.Main].mode, query.Demand_Mode.Whole)
	}
	{
		prog, err := jsonpath.compile(`$..id`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)
		testing.expect_value(t, prog.plan.sources[.Main].mode, query.Demand_Mode.Whole)
	}
	{
		prog, err := jsonpath.compile(`$.sub..id`)
		testing.expect_value(t, err.kind, jsonpath.Error_Kind.None)
		defer jsonpath.destroy_program(prog)
		s := &prog.plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		testing.expect(t, has_path(s, {tape.Name("sub")}, .Whole))
	}
}

@(private = "file")
Snapshot :: struct {
	end:     jsonpath.Run_End,
	col:     Collected,
	tainted: bool,
}

@(private = "file")
destroy_snapshot :: proc(s: ^Snapshot) {
	destroy_collected(&s.col)
}

@(private = "file")
run_doc_snapshot :: proc(prog: ^jsonpath.Program, doc: tape.Document, want_paths: bool) -> Snapshot {
	h: query.Heap
	query.heap_init(&h, context.allocator)
	defer query.heap_destroy(&h)

	root, st := query.document_value(&h, doc, true)
	if st != .Ok {
		return {end = .Failed, tainted = h.tainted}
	}
	defer query.release(&h, root)

	col := Collected{
		h     = &h,
		vals  = make([dynamic]string, context.allocator),
		paths = make([dynamic]string, context.allocator),
		alloc = context.allocator,
	}
	end := jsonpath.eval(prog, &h, root, collect_cb, &col, {want_paths = want_paths})
	col.h = nil
	return {
		end     = end,
		col     = col,
		tainted = h.tainted,
	}
}

@(private = "file")
snapshots_equal :: proc(a, b: Snapshot) -> bool {
	if a.end != b.end || len(a.col.vals) != len(b.col.vals) || len(a.col.paths) != len(b.col.paths) {
		return false
	}
	for i in 0 ..< len(a.col.vals) {
		if a.col.vals[i] != b.col.vals[i] || a.col.paths[i] != b.col.paths[i] {
			return false
		}
	}
	return true
}

// Query Contract Proof 1: Real demand (`json.scan` with `prog.plan.sources[.Main].demand`) vs forced whole (`json.build`)
// produces 100% identical outputs AND normalized paths with ZERO `.Tainted` guard hits!
@(test)
real_demand_matches_whole_with_zero_taints :: proc(t: ^testing.T) {
	testkit.deadline(t)

	inputs := [?]string{
		`{"id":7,"limit":25,"status":"ok","meta":{"tags":["a","b","c"],"nested":{"deep":99,"drop":[1,2,3]}},"items":[{"id":1,"ok":false,"val":10,"tags":["x"],"extra":{"big":[1,2,3]}},{"id":2,"ok":true,"val":20,"tags":["y","z"],"extra":"skip"},{"id":3,"ok":true,"val":30,"tags":[]},{"id":4,"ok":null,"val":25,"a":[1,2],"b":[1,2]}]}`,
		`{"id":0,"limit":5,"items":[],"meta":{}}`,
		`[10, 20, 30, 40, 50]`,
		`{"items":"not-an-array","meta":42}`,
		`null`,
	}

	queries := [?]string{
		`$.id`,
		`$.meta.nested.deep`,
		`$['id', 'status']`,
		`$.items[*].id`,
		`$.items[0, -1].id`,
		`$.items[1:3].val`,
		`$.items[::-1].id`,
		`$.items[0:2:0].id`,
		`$.items[?@.ok].id`,
		`$.items[?!@.ok].id`,
		`$.items[?@.val >= 20].id`,
		`$.items[?@.val <= $.limit].id`,
		`$.items[?@.a == @.b].id`,
		`$.items[?@.a <= @.b].id`,
		`$.items[?length(@.tags) > 0].id`,
		`$.items[?count(@.tags[*]) == 2].id`,
		`$.items[?value(@.tags[*]) == "x"].id`,
		`$.items[?match(@.extra, "sk.*")].id`,
		`$.items[?search(@.extra, "ki")].id`,
		`$.items[?@.ok == true]`,
		`$.meta..deep`,
		`$..id`,
		`$[1:4]`,
		`$[-2]`,
		`$`,
	}

	checked, partials, taints, mismatches := 0, 0, 0, 0
	for qsrc in queries {
		prog, cerr := jsonpath.compile(qsrc)
		testing.expectf(t, cerr.kind == .None, "compile %q failed: %s", qsrc, cerr.message)
		defer jsonpath.destroy_program(prog)

		for isrc in inputs {
			raw := transmute([]u8)isrc
			for want_paths in ([?]bool{false, true}) {
				wdoc, werr := json.build(raw, .Json)
				testing.expect(t, werr == nil)
				whole := run_doc_snapshot(prog, wdoc, want_paths)
				defer destroy_snapshot(&whole)

				mode := prog.plan.sources[.Main].mode
				for stop_early in ([?]bool{false, true}) {
					scan_snap: Snapshot
					if mode == .None {
						// Validate only; empty doc (`ABSENT` root) must never taint for a `.None` demand!
						verr := json.validate(raw, .Json)
						testing.expect(t, verr == nil)
						empty_d, _ := tape.demand_of(nil)
						pdoc, perr := json.scan(raw, &empty_d, .Json, {stop_early = stop_early})
						tape.destroy_demand(&empty_d)
						testing.expect(t, perr == nil)
						scan_snap = run_doc_snapshot(prog, pdoc, want_paths)
					} else if mode == .Whole {
						wdoc2, _ := json.build(raw, .Json)
						scan_snap = run_doc_snapshot(prog, wdoc2, want_paths)
					} else {
						partials += 1
						pdoc, perr := json.scan(raw, &prog.plan.sources[.Main].demand, .Json, {stop_early = stop_early})
						testing.expect(t, perr == nil)
						scan_snap = run_doc_snapshot(prog, pdoc, want_paths)
					}
					defer destroy_snapshot(&scan_snap)

					checked += 1
					if scan_snap.end == .Tainted || scan_snap.tainted {
						taints += 1
						if taints <= 10 {
							fmt.eprintfln("TAINT q=%s want_paths=%v stop_early=%v input=%s", qsrc, want_paths, stop_early, isrc)
						}
					} else if !snapshots_equal(whole, scan_snap) {
						mismatches += 1
						if mismatches <= 10 {
							fmt.eprintfln("MISMATCH q=%s want_paths=%v stop_early=%v\n  whole: %v\n  scan:  %v", qsrc, want_paths, stop_early, whole, scan_snap)
						}
					}
				}
			}
		}
	}

	testing.expect(t, checked > 300)
	testing.expect(t, partials > 200)
	testing.expect_value(t, taints, 0)
	testing.expect_value(t, mismatches, 0)
}

// Query Contract Proof 2: Chaos-demand — deliberately under-kept partial documents MUST either abort
// uncatchably with `.Tainted` (with any pre-taint outputs being an exact prefix of whole) OR match whole 100%!
@(test)
chaos_demand_never_gives_wrong_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)

	input_src := `{
		"a": {"x": 1, "y": [10, 20, 30]},
		"b": [{"k": "v1", "n": 1, "sub": {"p": 1}}, {"k": "v2", "n": 2, "sub": {"p": 2}}, {"k": "v3", "n": 3}],
		"c": "hello",
		"d": 42
	}`
	raw := transmute([]u8)input_src

	Chaos_Spec :: struct {
		paths:  [][]tape.Step,
		grains: []tape.Grain,
		limits: []int,
	}
	chaos_specs := [?]Chaos_Spec{
		{paths = {}},
		{paths = {{}}, grains = {.Exists}},
		{paths = {{}}, grains = {.Keys}},
		{paths = {{tape.Name("c")}}, grains = {.Whole}},
		{paths = {{tape.Name("a")}, {tape.Name("d")}}, grains = {.Whole, .Whole}},
		{paths = {{tape.Name("a")}, {tape.Name("b")}}, grains = {.Exists, .Keys}},
		{paths = {{tape.Name("a"), tape.Name("x")}, {tape.Name("b"), tape.Index(0), tape.Name("k")}}, grains = {.Whole, .Whole}},
		{paths = {{tape.Name("b"), tape.All{}, tape.Name("k")}}, grains = {.Whole}, limits = {1}},
		{paths = {{tape.Name("b"), tape.All{}, tape.Name("k")}, {tape.Name("b"), tape.All{}, tape.Name("n")}}, grains = {.Whole, .Whole}},
		{paths = {{tape.Name("zzz")}}, grains = {.Whole}},
	}

	queries := [?]string{
		`$`,
		`$.a`,
		`$.a.x`,
		`$.a.y[1]`,
		`$.a.y[-1]`,
		`$.a.y[0:2]`,
		`$.b[*].k`,
		`$.b[*].n`,
		`$.b[?@.n >= 2]`,
		`$.b[?@.n >= 2].k`,
		`$.b[?@.missing == @.sub]`,
		`$.b[?@.sub == @.sub].k`,
		`$.b[?length(@.sub) == 1].k`,
		`$.b[?count(@.sub[*]) == 1].k`,
		`$.b[?match(@.k, "v.*")].n`,
		`$.c`,
		`$.d`,
		`$..p`,
		`$[*]`,
	}

	taint_count, match_count := 0, 0
	for qsrc in queries {
		prog, cerr := jsonpath.compile(qsrc)
		testing.expectf(t, cerr.kind == .None, "compile %q failed", qsrc)
		defer jsonpath.destroy_program(prog)

		wdoc, werr := json.build(raw, .Json)
		testing.expect(t, werr == nil)
		whole := run_doc_snapshot(prog, wdoc, true)
		defer destroy_snapshot(&whole)

		for spec, si in chaos_specs {
			d, derr := tape.demand_of(spec.paths, spec.grains, spec.limits, false)
			testing.expect(t, derr == nil)
			pdoc, perr := json.scan(raw, &d, .Json)
			tape.destroy_demand(&d)
			testing.expect(t, perr == nil)

			res := run_doc_snapshot(prog, pdoc, true)
			defer destroy_snapshot(&res)

			if res.end == .Tainted {
				taint_count += 1
				testing.expectf(t, len(res.col.vals) <= len(whole.col.vals), "chaos[%d] %q emitted %d > whole %d", si, qsrc, len(res.col.vals), len(whole.col.vals))
				for k in 0 ..< min(len(res.col.vals), len(whole.col.vals)) {
					testing.expectf(t, res.col.vals[k] == whole.col.vals[k] && res.col.paths[k] == whole.col.paths[k],
						"chaos[%d] %q emitted wrong pre-taint output[%d]: got (%s, %s), whole (%s, %s)",
						si, qsrc, k, res.col.vals[k], res.col.paths[k], whole.col.vals[k], whole.col.paths[k])
				}
			} else {
				match_count += 1
				testing.expectf(t, snapshots_equal(whole, res),
					"CHAOS VIOLATION spec=%d q=%q:\n  whole: %v\n  chaos: %v", si, qsrc, whole, res)
			}
		}
	}

	testing.expect(t, taint_count > 50)
	testing.expect(t, match_count > 10)
}
