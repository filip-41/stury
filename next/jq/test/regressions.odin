#+feature dynamic-literals
package jq_tests

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "stury:jq"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"
import "stury:xml"

@(private = "file")
eval_expr :: proc(t: ^testing.T, src, input_json: string, hooks: ^jq.Hooks = nil, steps := 0, mem_limit := u64(0), loc := #caller_location) -> (out: string, end: jq.Run_End, err_kind: query.Error_Kind) {
	prog, errors := jq.compile(src)
	defer jq.destroy_program(prog)
	if !testing.expectf(t, len(errors) == 0, "compile %q failed: %v", src, errors, loc = loc) {
		return "", .Failed, .None
	}
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator(), mem_limit)
	defer query.heap_destroy(&h)
	inp, ok := read_value(&h, input_json)
	if !testing.expectf(t, ok, "bad input %q", input_json, loc = loc) {
		return "", .Failed, .None
	}
	default_hooks := jq.Hooks{parse_json = parse_json_hook, markup = xml_markup}
	use_hooks := hooks if hooks != nil else &default_hooks
	run: jq.Run
	jq.run_init(&run, prog, &h, nil, use_hooks, steps)
	outs := Outputs{h = &h}
	end = jq.run_value(&run, inp, collect, &outs)
	shown := make([dynamic]string)
	for v in outs.vals {
		append(&shown, show(&h, v))
		query.release(&h, v)
	}
	if end == .Failed {
		e := query.take_error(&h)
		err_kind = e.kind
		append(&shown, strings.concatenate({"error: ", jq.error_message(&h, &e)}))
		query.destroy_error(&h, &e)
	}
	jq.run_destroy(&run)
	testing.expect_value(t, query.heap_live(&h), u64(0), loc = loc)
	return strings.join(shown[:], "\n"), end, err_kind
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

	// css on partial XML document taints heap and emits empty without raising a catchable error.
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
	testing.expect_value(t, rend, jq.Run_End.Done)
	testing.expect(t, h.tainted)
	testing.expect_value(t, len(outs.vals), 1)
	testing.expect_value(t, show(&h, outs.vals[0]), "[]")
	query.release(&h, outs.vals[0])
	jq.run_destroy(&run)
	testing.expect_value(t, query.heap_live(&h), u64(0))
}

@(test)
math_exact_powers_and_libm_ulp_bounds :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	testing.expect(t, suite_arena(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)

	// `log10` and `log2` are exact on exact powers.
	out10, end10, _ := eval_expr(t, `[1, 10, 100, 1000, 1e6, 1e15, 1e22] | map(log10)`, "null")
	testing.expect_value(t, end10, jq.Run_End.Done)
	testing.expect_value(t, out10, `[0,1,2,3,6,15,22]`)

	out2, end2, _ := eval_expr(t, `[range(-20; 53)] | all(. as $k | pow(2; $k) | log2 == $k)`, "null")
	testing.expect_value(t, end2, jq.Run_End.Done)
	testing.expect_value(t, out2, `true`)

	// The five libm-backed builtins stay within 1 ulp of reference values.
	prog := `[
		((1 | sin) - 0.8414709848078965 | fabs <= 2.220446049250313e-16),
		((1 | cos) - 0.5403023058681398 | fabs <= 2.220446049250313e-16),
		((1 | tan) - 1.5574077246549023 | fabs <= 4.440892098500626e-16),
		((1 | exp) - 2.718281828459045  | fabs <= 4.440892098500626e-16),
		(pow(2; 0.5) - 1.4142135623730951 | fabs <= 2.220446049250313e-16)
	] | all`
	out_ulp, end_ulp, _ := eval_expr(t, prog, "null")
	testing.expect_value(t, end_ulp, jq.Run_End.Done)
	testing.expect_value(t, out_ulp, `true`)
}
