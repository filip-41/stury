package jq_tests

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

// Two mandatory soundness proofs for the query contract:
// 1. Every passing corpus case + generated multi-path filters run under `jq.analyze` + `json.scan`
//    produces byte-identical outputs to forced whole `json.build` with ZERO `.Tainted` guard hits.
// 2. Chaos-demand: running tricky filters (including `try`/`?`/`//`/`?//`, `select`, `limit`, `keys`,
//    `length`, `debug`, `stderr`, `halt`, fact reads) against deliberately under-kept partial documents
//    ALWAYS either aborts uncatchably with `.Tainted` (0 outputs, 0 side-effect hook calls) OR produces
//    identical output to whole — never a third thing.

@(private = "file")
Run_Snapshot :: struct {
	end:       jq.Run_End,
	outs:      []string,
	err_msg:   string,
	debugs:    int,
	stderrs:   int,
	tainted:   bool,
}

@(private = "file")
Hook_Log :: struct {
	debugs:  int,
	stderrs: int,
}

@(private = "file")
count_debug :: proc(data: rawptr, _: query.Value, _: ^query.Heap) {
	(^Hook_Log)(data).debugs += 1
}

@(private = "file")
count_stderr :: proc(data: rawptr, _: query.Value, _: ^query.Heap) {
	(^Hook_Log)(data).stderrs += 1
}

@(private = "file")
run_on_doc :: proc(prog: ^jq.Program, doc: tape.Document, owned: bool, use_null: bool, allocator := context.allocator) -> Run_Snapshot {
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator())
	defer query.heap_destroy(&h)

	inp := query.NULL
	if !use_null {
		s: query.Status
		inp, s = query.document_value(&h, doc, owned)
		if s != .Ok {
			return {end = .Failed, tainted = h.tainted}
		}
	}

	log: Hook_Log
	hooks := jq.Hooks{
		data       = &log,
		debug      = count_debug,
		stderr     = count_stderr,
		now        = fixed_now,
		markup     = xml_markup,
		parse_json = parse_json_hook,
	}
	run: jq.Run
	jq.run_init(&run, prog, &h, nil, &hooks, steps = 500_000)
	defer jq.run_destroy(&run)

	outs := Outputs{h = &h}
	defer delete(outs.vals)
	end := jq.run_value(&run, inp, collect, &outs)

	strs := make([]string, len(outs.vals), allocator)
	for v, i in outs.vals {
		strs[i] = show(&h, v)
		query.release(&h, v)
	}
	err_msg := ""
	if end == .Failed {
		e := query.take_error(&h)
		err_msg = jq.error_message(&h, &e, allocator)
		query.destroy_error(&h, &e)
	}
	return {
		end     = end,
		outs    = strs,
		err_msg = err_msg,
		debugs  = log.debugs,
		stderrs = log.stderrs,
		tainted = h.tainted,
	}
}

@(private = "file")
snapshots_match :: proc(a, b: Run_Snapshot) -> bool {
	if a.end != b.end || len(a.outs) != len(b.outs) || a.debugs != b.debugs || a.stderrs != b.stderrs {
		return false
	}
	if a.end == .Failed && a.err_msg != b.err_msg {
		return false
	}
	for i in 0 ..< len(a.outs) {
		if a.outs[i] != b.outs[i] {
			return false
		}
	}
	return true
}

@(test)
corpus_under_real_demand_has_zero_taints :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	mods := corpus_modules()
	checked, partials, taints, mismatches := 0, 0, 0, 0

	for suite in SUITES {
		for c in read_suite(suite) {
			if c.fail != .None || strings.has_prefix(c.input, "<") {
				continue
			}
			prog, errs := jq.compile(c.prog, {modules = mods})
			if len(errs) > 0 {
				jq.destroy_program(prog)
				continue
			}
			plan := jq.analyze(prog)

			// Only JSON inputs where the analyzer actually picked `.Partial` or `.None` exercise the scan seam.
			mode := plan.sources[.Main].mode
			if mode == .Whole {
				jq.destroy_plan(&plan)
				jq.destroy_program(prog)
				continue
			}

			src := transmute([]u8)strings.clone(c.input)
			whole_doc, werr := json.build(src, .Json, {}, runtime.heap_allocator())
			if werr != nil {
				jq.destroy_plan(&plan)
				jq.destroy_program(prog)
				continue
			}

			whole_res := run_on_doc(prog, whole_doc, true, false)

			scan_res: Run_Snapshot
			if mode == .None {
				// Input is validated, not built.
				verr := json.validate(src, .Json, {}, runtime.heap_allocator())
				testing.expect(t, verr == nil)
				scan_res = run_on_doc(prog, {}, false, true)
			} else {
				partials += 1
				pdoc, perr := json.scan(src, &plan.sources[.Main].demand, .Json, {}, {}, runtime.heap_allocator())
				if perr != nil {
					testing.expectf(t, false, "%s:%d %s: scan failed: %v", c.file, c.line, c.prog, perr)
					mismatches += 1
					jq.destroy_plan(&plan)
					jq.destroy_program(prog)
					continue
				}
				scan_res = run_on_doc(prog, pdoc, true, false)
			}

			checked += 1
			if scan_res.end == .Tainted || scan_res.tainted {
				taints += 1
				if taints <= 10 {
					fmt.eprintfln("TAINT %s:%d prog=%s input=%s", c.file, c.line, c.prog, c.input)
				}
			} else if !snapshots_match(whole_res, scan_res) {
				mismatches += 1
				if mismatches <= 10 {
					fmt.eprintfln("MISMATCH %s:%d prog=%s input=%s\n  whole: %v\n  scan:  %v", c.file, c.line, c.prog, c.input, whole_res, scan_res)
				}
			}

			jq.destroy_plan(&plan)
			jq.destroy_program(prog)
		}
	}

	// Extra targeted partial-demand expressions over rich nested inputs.
	extra_inputs := [?]string{
		`{"id":7,"status":"ok","meta":{"tags":["a","b","c"],"nested":{"deep":99,"drop":[1,2,3]}},"items":[{"id":1,"ok":false,"val":10,"extra":{"big":[1,2,3]}},{"id":2,"ok":true,"val":20,"extra":"skip"},{"id":3,"ok":true,"val":30}]}`,
		`{"id":0,"status":"err","items":[],"meta":{}}`,
		`[10, 20, 30, 40, 50]`,
		`{"a": 1, "b": {"c": [1, 2, 3]}}`,
		`null`,
	}
	extra_progs := [?]string{
		`.id`,
		`{id, s: .status}`,
		`.items[] | .id`,
		`[.items[] | .val] | add`,
		`first(.items[].id)`,
		`limit(2; .items[].val)`,
		`first(.items[] | select(.ok) | .id)`,
		`reduce .items[] as $x (0; . + $x.val)`,
		`. as $r | $r.id + ($r.items | length)`,
		`(.meta | keys), (.items | length), has("status"), (.meta.nested | type)`,
		`.items[1:3] | map(.id)`,
		`.items[0:2] | length`,
		`try .items[0].id catch "bad"`,
		`.meta.tags[0:2]`,
		`def f: .id; .items | map(f)`,
		`getpath(["meta", "nested", "deep"])`,
		`isempty(.items[] | select(.ok))`,
		`.items[0:100]`,
		// Review regression cases: Label scope hops, ?// key scopes, first()+fanout/slice/has, recursion args, stop_early, try/reduce facts, DAG O(1).
		`. as $r | (.id, (label $out | $r.status))`,
		`def outer(y): def g(x): label $out | x; g(.id); outer(.status)`,
		`. as $x | (def f: $x.id; .status, (label $out | f))`,
		`.status as $outer | .meta as [$v] ?// {($outer): $v} | $v`,
		`. as [$v] ?// {status: $k1, ($k1): $v} | $v`,
		`first(.items[]) | .[]?`,
		`first(.items[]) | .[0:2]?`,
		`first(.items[]) | has(0)?`,
		`has(0)?`,
		`. as $r | def rec(x): if .id > 0 then ({"id": 0} | rec(x | .meta)) else (x | .tags) end; rec($r)`,
		`reduce range(35) as $i ([0]; [., .]) | length`,
	}
	for prog_src in extra_progs {
		prog, errs := jq.compile(prog_src)
		testing.expectf(t, len(errs) == 0, "compile %q", prog_src)
		plan := jq.analyze(prog)
		for inp_src in extra_inputs {
			src := transmute([]u8)strings.clone(inp_src)
			wdoc, werr := json.build(src, .Json, {}, runtime.heap_allocator())
			testing.expect(t, werr == nil)
			whole_res := run_on_doc(prog, wdoc, true, false)

			// Test BOTH `stop_early = false` AND `stop_early = true` on partial demands!
			for stop_early in ([?]bool{false, true}) {
				scan_res: Run_Snapshot
				if plan.sources[.Main].mode == .None {
					scan_res = run_on_doc(prog, {}, false, true)
				} else if plan.sources[.Main].mode == .Whole {
					wdoc2, _ := json.build(src, .Json, {}, runtime.heap_allocator())
					scan_res = run_on_doc(prog, wdoc2, true, false)
				} else {
					pdoc, perr := json.scan(src, &plan.sources[.Main].demand, .Json, {stop_early = stop_early}, {}, runtime.heap_allocator())
					testing.expect(t, perr == nil)
					scan_res = run_on_doc(prog, pdoc, true, false)
					partials += 1
				}
				checked += 1
				if scan_res.end == .Tainted || scan_res.tainted {
					taints += 1
					fmt.eprintfln("EXTRA TAINT stop_early=%v prog=%s input=%s", stop_early, prog_src, inp_src)
				} else if !snapshots_match(whole_res, scan_res) {
					mismatches += 1
					fmt.eprintfln("EXTRA MISMATCH stop_early=%v prog=%s input=%s\n  whole: %v\n  scan:  %v", stop_early, prog_src, inp_src, whole_res, scan_res)
				}
			}
		}
		jq.destroy_plan(&plan)
		jq.destroy_program(prog)
	}

	testing.expect(t, checked > 150)
	testing.expect(t, partials > 100)
	testing.expect_value(t, taints, 0)
	testing.expect_value(t, mismatches, 0)
}

@(test)
chaos_demand_never_gives_wrong_answer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// Rich JSONC input with comments, nested objects, arrays, and numbers.
	input_src := `// head comment
{
  // a comment
  "a": {"x": 1, "y": [10, 20, 30]},
  "b": [{"k": "v1", "n": 1}, {"k": "v2", "n": 2}, {"k": "v3", "n": 3}],
  "c": "hello",
  "d": 42
}`
	src := transmute([]u8)strings.clone(input_src)

	// Deliberately under-kept / wrong-grain / no-facts chaos demands.
	Chaos_Spec :: struct {
		paths:  [][]tape.Step,
		grains: []tape.Grain,
		limits: []int,
		facts:  bool,
	}
	chaos_specs := [?]Chaos_Spec{
		// 1. Completely empty demand (keeps no root at all).
		{paths = {}},
		// 2. Root at `.Exists` only (stub object).
		{paths = {{}}, grains = {.Exists}},
		// 3. Root at `.Keys` only (keys kept, child containers are stubs!).
		{paths = {{}}, grains = {.Keys}},
		// 4. Only `.c` kept whole (missing `.a`, `.b`, `.d`).
		{paths = {{tape.Name("c")}}, grains = {.Whole}},
		// 5. `.a` kept at `.Exists`, `.b` kept at `.Keys` (array count only, no elements).
		{paths = {{tape.Name("a")}, {tape.Name("b")}}, grains = {.Exists, .Keys}},
		// 6. `.a.x` kept whole, `.b[0].k` kept whole (missing `.a.y`, `.b[1]`, `.b[0].n`).
		{paths = {{tape.Name("a"), tape.Name("x")}, {tape.Name("b"), tape.Index(0), tape.Name("k")}}, grains = {.Whole, .Whole}},
		// 7. `.b[].k` with limit 1 (truncates `.b` after element 0).
		{paths = {{tape.Name("b"), tape.All{}, tape.Name("k")}}, grains = {.Whole}, limits = {1}},
		// 8. `.a` whole WITHOUT facts (tests fact-read taint!).
		{paths = {{tape.Name("a")}}, grains = {.Whole}, facts = false},
		// 9. `.a` whole WITH facts, missing `.b`.
		{paths = {{tape.Name("a")}}, grains = {.Whole}, facts = true},
		// 10. Wrong key `.zzz` only.
		{paths = {{tape.Name("zzz")}}, grains = {.Whole}},
	}

	// Tricky programs designed to try to escape or hide taint through every jq mechanism.
	progs := [?]string{
		`.`,
		`[.]`,
		`{wrapped: .a}`,
		`.a`,
		`.a.x`,
		`.a.y[1]`,
		`.b[].k`,
		`.b[].n`,
		`first(.b[].k)`,
		`limit(2; .b[].k)`,
		`select(.d == 42)`,
		`select(.missing == null)`,
		`try .d catch "caught"`,
		`try (.a.y[0] + 1) catch "caught"`,
		`try (.b | length) catch "caught"`,
		`.d?`,
		`.a.y[0]? // "fallback"`,
		`.d // "fallback"`,
		`(.d // 99) + 1`,
		`try (.a == {"x":1,"y":[10,20,30]}) catch false`,
		`keys`,
		`length`,
		`.a | keys`,
		`.a | length`,
		`.b | length`,
		`has("d")`,
		`has("c")`,
		`has("missing")`,
		`(.d | debug)`,
		`(.d | stderr)`,
		`(.d | halt_error(3))`,
		`(.a | halt)`,
		`.@comment`,
		`.a.@comment`,
		`try .a.@comment catch "caught"`,
		`.a.@comment // "none"`,
		`[.b[] as {$k, $n} ?// {$k} | $k]`,
		`[try (.b[] | .n) catch 0]`,
		`reduce .b[] as $x (0; . + $x.n)`,
		`.b[0:2]`,
		`.b[0:10]`,
		`del(.c)`,
		`.d |= . + 1`,
	}

	taint_count := 0
	match_count := 0
	for prog_src in progs {
		prog, errs := jq.compile(prog_src)
		testing.expectf(t, len(errs) == 0, "compile %q", prog_src)

		wdoc, werr := json.build(src, .Jsonc, {}, runtime.heap_allocator())
		testing.expect(t, werr == nil)
		whole_res := run_on_doc(prog, wdoc, true, false)

		for spec, si in chaos_specs {
			d, derr := tape.demand_of(spec.paths, spec.grains, spec.limits, spec.facts, runtime.heap_allocator())
			testing.expect(t, derr == nil)
			pdoc, perr := json.scan(src, &d, .Jsonc, {}, {}, runtime.heap_allocator())
			tape.destroy_demand(&d)
			testing.expect(t, perr == nil)

			res := run_on_doc(prog, pdoc, true, false)
			if res.end == .Tainted {
				taint_count += 1
				// Uncatchable taint invariant: any output emitted before hitting an unloaded node must be an exact
				// prefix of whole's outputs (never a wrong/partial value), and no extra side-effect hooks may fire.
				testing.expectf(t, len(res.outs) <= len(whole_res.outs), "chaos[%d] %q emitted %d outputs > whole %d before Tainted", si, prog_src, len(res.outs), len(whole_res.outs))
				for k in 0 ..< min(len(res.outs), len(whole_res.outs)) {
					testing.expectf(t, res.outs[k] == whole_res.outs[k], "chaos[%d] %q emitted wrong output[%d]: got %s, whole %s", si, prog_src, k, res.outs[k], whole_res.outs[k])
				}
				testing.expectf(t, res.debugs <= whole_res.debugs && res.stderrs <= whole_res.stderrs, "chaos[%d] %q fired spurious hooks (%d/%d vs %d/%d) before Tainted", si, prog_src, res.debugs, res.stderrs, whole_res.debugs, whole_res.stderrs)
			} else {
				match_count += 1
				if !snapshots_match(whole_res, res) {
					testing.expectf(t, false, "CHAOS VIOLATION spec=%d prog=%q:\n  whole: %v\n  chaos: %v", si, prog_src, whole_res, res)
				}
			}
		}
		jq.destroy_program(prog)
	}

	// Ensure chaos actually triggered both tainted aborts and exact matches.
	testing.expect(t, taint_count > 100)
	testing.expect(t, match_count > 50)
}
