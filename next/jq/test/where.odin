package jq_tests

import "base:runtime"
import "core:mem/virtual"
import "core:testing"
import "stury:cbor"
import "stury:jq"
import "stury:json"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

@(private = "file")
eval_where :: proc(
	t: ^testing.T,
	expr: string,
	doc: ^tape.Document,
	filename := "",
	hooks_override: ^jq.Hooks = nil,
	loc := #caller_location,
) -> (out: string, end: jq.Run_End, tainted: bool) {
	File_Data :: struct {
		name: string,
	}
	fdata := File_Data{name = filename}
	hooks := jq.Hooks{
		data       = &fdata,
		parse_json = parse_json_hook,
	}
	if filename != "" {
		hooks.input_filename = proc(data: rawptr, h: ^query.Heap) -> (query.Value, query.Status) {
			return query.text_value(h, (^File_Data)(data).name)
		}
	}
	use_hooks := hooks_override if hooks_override != nil else &hooks
	r := eval_jq(t, expr, {doc = doc, hooks = use_hooks}, loc = loc)
	return r.out, r.end, r.tainted
}

@(test)
where_builtin_json_scalars_pipes_and_constructed :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("{\n  \"items\": [\n    {\"id\": 1, \"p\": 10, \"s\": \"{\\\"a\\\": 5}\"},\n    {\"id\": 2, \"p\": 20, \"s\": \"{\\\"a\\\": 6}\"}\n  ],\n  \"b\": true,\n  \"f\": false,\n  \"n\": null,\n  \"e\": \"x\\ny\"\n}\n")
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	// 1. Direct node lookup (with and without filename).
	out, end, _ := eval_where(t, `.items[1].p | where`, &doc, "i.json")
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `{"file":"i.json","line":4,"column":20}`)

	out, end, _ = eval_where(t, `.items[1].p | where`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `{"line":4,"column":20}`)

	// 2. Objects, arrays, booleans, null, and escaped strings all preserve origin.
	out, end, _ = eval_where(t, `[(. | where), (.items | where), (.b | where), (.f | where), (.n | where), (.e | where)]`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[{"line":1,"column":1},{"line":2,"column":12},{"line":6,"column":8},{"line":7,"column":8},{"line":8,"column":8},{"line":9,"column":8}]`)

	// 3. Piped computed values inherit the nearest enclosing document-origin `.` along pipes!
	out, end, _ = eval_where(t, `.items[] | .p * 2 | where | .line`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, "3\n4")

	// 4. Prelude `map` preserves per-element origin!
	out, end, _ = eval_where(t, `.items | map(.p * 2 | where.line)`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[3,4]`)

	// 5. `fromjson` synthetic doc inherits outer `.s` string origin!
	out, end, _ = eval_where(t, `.items[0] | .s | fromjson | where | .column`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `29`)

	// 6. Constructed values with no input document return `null`.
	out, end, _ = eval_where(t, `where`, nil)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `null`)

	out, end, _ = eval_where(t, `{a: 1, b: [2, 3]} | where`, nil)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `null`)

	// 7. Root scalar document (`true`, `null`, escaped string).
	for tc in ([?][2]string{{`true`, `{"line":1,"column":1}`}, {`null`, `{"line":1,"column":1}`}, {`"a\nb"`, `{"line":1,"column":1}`}}) {
		sdoc, serr := json.build(transmute([]u8)tc[0], .Json, {}, alloc)
		testing.expect(t, serr == nil)
		sout, send, _ := eval_where(t, `where`, &sdoc)
		testing.expect_value(t, send, jq.Run_End.Done)
		testing.expect_value(t, sout, tc[1])
		tape.destroy_document(&sdoc)
	}
}

@(test)
where_partial_scan_cbor_and_custom_hook :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	alloc := runtime.heap_allocator()

	// 1. `jq.analyze` gives `.Exists` grain for `.a.b | where`, and partial-doc scan works without tainting!
	{
		prog, errs := jq.compile(`.a.b | where`)
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(errs), 0)
		plan := jq.analyze(prog)
		defer jq.destroy_plan(&plan)
		s := &plan.sources[.Main]
		testing.expect_value(t, s.mode, query.Demand_Mode.Partial)
		found_exists := false
		for dp in s.paths {
			if dp.grain == .Exists && query.steps_equal(dp.steps, {tape.Name("a"), tape.Name("b")}) {
				found_exists = true
			}
		}
		testing.expect(t, found_exists)

		// Note `.a.b` is a container object, kept only at `.Exists` grain (partial container)!
		src := transmute([]u8)string("{\n  \"skip\": [1, 2, 3],\n  \"a\": {\n    \"b\": {\"deep\": 99}\n  }\n}\n")
		pdoc, perr := json.scan(src, &s.demand, .Json, {}, {}, alloc)
		testing.expect(t, perr == nil)
		defer tape.destroy_document(&pdoc)

		out, end, tainted := eval_where(t, `.a.b | where`, &pdoc, "partial.json")
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect(t, !tainted)
		testing.expect_value(t, out, `{"file":"partial.json","line":4,"column":10}`)
	}

	// 2. CBOR binary offsets return `{"file": ..., "offset": N}` (or `{"offset": N}`).
	{
		cbor_bytes := []u8{0xA2, 0x61, 0x61, 0x01, 0x61, 0x62, 0x82, 0x01, 0x02}
		cdoc, cerr := cbor.build(cbor_bytes, .Cbor, {}, alloc)
		testing.expect(t, cerr == nil)
		defer tape.destroy_document(&cdoc)

		out, end, _ := eval_where(t, `.b[] | where`, &cdoc, "c.cbor")
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, "{\"file\":\"c.cbor\",\"offset\":7}\n{\"file\":\"c.cbor\",\"offset\":8}")

		out2, end2, _ := eval_where(t, `.b[0] | where`, &cdoc)
		testing.expect_value(t, end2, jq.Run_End.Done)
		testing.expect_value(t, out2, `{"offset":7}`)
	}

	// 3. Custom `Hooks.where` overrides resolution cleanly.
	{
		doc, err := json.build(transmute([]u8)string(`{"x": 1}`), .Json, {}, alloc)
		testing.expect(t, err == nil)
		defer tape.destroy_document(&doc)

		custom := jq.Hooks{
			place = proc(data: rawptr, v: query.Value, h: ^query.Heap) -> (string, tape.Place, bool) {
				return "custom.json", {byte = 42, line = 9, col = 3, ok = true}, true
			},
		}
		out, end, _ := eval_where(t, `.x | where`, &doc, "", &custom)
		testing.expect_value(t, end, jq.Run_End.Done)
		testing.expect_value(t, out, `{"file":"custom.json","line":9,"column":3}`)
	}
}

// H2: Origin propagation across `sort_by`/`min_by`/`max_by`, `|=` updates, `reduce`/`foreach`, and O(1) tail recursion.
@(test)
where_origin_by_update_fold_and_tail_recursion :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	alloc := runtime.heap_allocator()
	src := transmute([]u8)string("{\n  \"items\": [\n    {\"id\": 1, \"p\": 30},\n    {\"id\": 2, \"p\": 10},\n    {\"id\": 3, \"p\": 20}\n  ]\n}\n")
	doc, err := json.build(src, .Json, {}, alloc)
	testing.expect(t, err == nil)
	defer tape.destroy_document(&doc)

	// 1. `sort_by`, `min_by`, `max_by`, `group_by` with computed expression before `where`.
	out, end, _ := eval_where(t, `.items | sort_by(-(.p * 2 | where.line)) | map(.id)`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[3,2,1]`)

	out, end, _ = eval_where(t, `.items | max_by(.p * 2 | where.line) | .id`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `3`)

	// 2. `|=` update (both single-path native and multi-path `update.odin` with native & non-native RHS).
	out, end, _ = eval_where(t, `.items[1] |= (.p * 2 | where.line) | .items[1]`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `4`)

	out, end, _ = eval_where(t, `.items[] |= (.p * 2 | where.line) | .items`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[3,4,5]`)

	out, end, _ = eval_where(t, `.items[] |= (.p * 2 | (where.line, empty)) | .items`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[3,4,5]`)

	// 3. `reduce` and `foreach` with doc-origin accumulator state (native & non-native update).
	out, end, _ = eval_where(t, `reduce (1, 2) as $i (.items[1]; if $i == 1 then . else (.p * 2 | where.line) end)`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `4`)

	out, end, _ = eval_where(t, `reduce (1, 2) as $i (.items[2]; if $i == 1 then . else (.p * 2 | (where.line, empty)) end)`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `5`)

	out, end, _ = eval_where(t, `[foreach (1, 2) as $i (.items[0]; .; .p * $i | where.line)]`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `[3,3]`)

	// 4. Deep tail recursion (50,000 steps) with `where` in the program stays O(1) via `Origin_Frame` coalescing!
	out, end, _ = eval_where(t, `. as $root | def spin($n): if $n == 0 then where.line else $root.items[2] | spin($n - 1) end; spin(50000)`, &doc)
	testing.expect_value(t, end, jq.Run_End.Done)
	testing.expect_value(t, out, `5`)
}
