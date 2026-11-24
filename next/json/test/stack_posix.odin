#+build darwin, linux, freebsd, openbsd, netbsd
package json_tests

import "core:fmt"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads the nested text four ways, a verdict, a document, the value at the last index of each level and a scan, and
// `testkit.deep_read`'s ways, which take the records of the innermost container.
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := json.Options{budget = {depth = 200_000}}
	if read >= 4 {
		objects := text[1] == '{'
		at := make([]tape.Step, ((len(text) + 1) / 6 if objects else (len(text) - 3) / 2) - 1, context.temp_allocator)
		for &step, k in at {
			step = tape.Name("a") if objects && k > 0 else tape.Index(0)
		}
		paths := [][]tape.Step{{tape.Descend{}, tape.Index(0)}, {tape.Descend{}, tape.Name("a")}}
		return testkit.deep_read(read - 4, json.reads(.Json), json.as(.Json), text, opts, paths, .Members if objects else .Elements, at)
	}
	switch read {
	case 0:
		return json.validate(text, opts = opts) == nil
	case 1:
		doc, err := json.build(text, opts = opts)
		tape.destroy(&doc)
		return err == nil
	case 2:
		answer, err := json.find(text, {tape.Index(-2)}, opts = opts)
		return err == nil && answer.outcome == .Found
	case:
		d, _ := tape.demand_of({{tape.Index(-2)}, {tape.All{}}})
		r, err := json.scan(text, &d, opts = opts)
		ok := err == nil && answered(&r) == 3
		tape.destroy(&r)
		tape.destroy(&d)
		return ok
	}
}

// Runs each read on a thread of `stack` bytes over a text nesting `depth` levels, in arrays and in objects, and a value
// in it read again.
expect_nested_reads_on_thread :: proc(t: ^testing.T, stack: uint, depth: int) {
	for objects in ([]bool{false, true}) {
		text := transmute([]u8)nested_in_root(depth, objects)
		testkit.expect_reads_on_thread(t, stack, 4 + testkit.DEEP_READS, text, fmt.tprintf("objects %v depth %d", objects, depth), read_nested)
	}
}

// Each read runs on a thread with the stack it states, over a text nesting past the frame and a value read again.
@(test)
reads_run_in_the_stack_they_state :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_nested_reads_on_thread(t, json.READ_STACK + testkit.THREAD_START, 4 * json.WALK_LEVELS)
}

// A thread of one MiB reads a text of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack. The makefile runs it at every optimization level, as a frame's size depends on it.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	expect_nested_reads_on_thread(t, 1 << 20, 100_000)
}
