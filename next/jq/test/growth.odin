package jq_tests

import "base:runtime"
import "core:testing"
import "stury:jq"
import "stury:lib/query"
import "stury:testkit"

// Programs whose cost grew with the square of their size: each runs in the time and memory a linear one takes.
@(rodata)
GROWTH_RUNS := [?][2]string {
	{"[range(60000) | {key: tostring, value: .}] | from_entries | length", "60000"},
	{"[range(60000) | {(tostring): .}] | add | length", "60000"},
	{"reduce range(100000) as $i ({}; .[$i % 10 | tostring] += [$i]) | map(length) | add", "100000"},
	{"reduce range(100000) as $i ({}; .a[$i % 10 | tostring] |= . + [$i]) | .a | map(length) | add", "100000"},
}

GROWTH_MEMORY :: 64 << 20

@(test)
objects_and_updates_grow_linearly :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for c in GROWTH_RUNS {
		prog, errors := jq.compile(c[0])
		defer jq.destroy_program(prog)
		testing.expect_value(t, len(errors), 0)
		h: query.Heap
		query.heap_init(&h, runtime.heap_allocator(), GROWTH_MEMORY)
		defer query.heap_destroy(&h)
		run: jq.Run
		jq.run_init(&run, prog, &h, nil)
		outs := Outputs{h = &h}
		end := jq.run_value(&run, query.NULL, collect, &outs)
		jq.run_destroy(&run)
		testing.expect_value(t, end, jq.Run_End.Done)
		if len(outs.vals) == 1 {
			got := show(&h, outs.vals[0])
			testing.expect_value(t, got, c[1])
			delete(got)
		}
		for v in outs.vals {
			query.release(&h, v)
		}
		delete(outs.vals)
		testing.expect_value(t, query.heap_live(&h), 0)
	}
}

// Every path to a level of a value 10,000 deep is an array of its own, so `[paths]` is as large as its answer: the
// budget refuses it with the memory error and every block is given back.
@(test)
paths_of_a_deep_value_stay_in_the_memory_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	prog, errors := jq.compile("reduce range(10000) as $i (null; [.]) | [paths] | .[0] | length")
	defer jq.destroy_program(prog)
	testing.expect_value(t, len(errors), 0)
	h: query.Heap
	query.heap_init(&h, runtime.heap_allocator(), GROWTH_MEMORY, depth = 1 << 20)
	defer query.heap_destroy(&h)
	run: jq.Run
	jq.run_init(&run, prog, &h, nil)
	outs := Outputs{h = &h}
	end := jq.run_value(&run, query.NULL, collect, &outs)
	testing.expect_value(t, end, jq.Run_End.Failed)
	testing.expect_value(t, len(outs.vals), 0)
	query.clear_error(&h)
	jq.run_destroy(&run)
	delete(outs.vals)
	testing.expect_value(t, query.heap_live(&h), 0)
}
