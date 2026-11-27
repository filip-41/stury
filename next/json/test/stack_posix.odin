#+build darwin, linux, freebsd, openbsd, netbsd
package json_tests

import "core:fmt"
import "core:testing"
import "stury:json"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads the nested text five ways, a verdict, a document, the value at the last index of each level, a scan and a typed read, and
// `testkit.deep_read`'s ways, which take the records of the innermost container.
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := json.Options{budget = {depth = 200_000}}
	if read < testkit.DEEP_CORE_READS {
		objects := text[1] == '{'
		at: []tape.Step
		if read == 6 {
			at = make([]tape.Step, ((len(text) + 1) / 6 if objects else (len(text) - 3) / 2) - 1, context.temp_allocator)
			for &step, k in at {
				step = tape.Name("a") if objects && k > 0 else tape.Index(0)
			}
		}
		find_path := [1]tape.Step{tape.Index(-2)}
		scan_paths := [2][]tape.Step{{tape.Index(-2)}, {tape.All{}}}
		deep_paths := [2][]tape.Step{{tape.Descend{}, tape.Index(0)}, {tape.Descend{}, tape.Name("a")}}
		return testkit.deep_core_read(read, json.reads(.Json), json.as(.Json), text, opts, find_path[:], scan_paths[:], deep_paths[:], .Members if objects else .Elements, at)
	}
	v: testkit.Value
	err := json.unmarshal(text, &v, opts = opts)
	testkit.value_free(v)
	return err == nil
}

// Runs each read on a thread of `stack` bytes over a text nesting `depth` levels, in arrays and in objects, and a value
// in it read again.
expect_nested_reads_on_thread :: proc(t: ^testing.T, stack: uint, depth: int) {
	for objects in ([]bool{false, true}) {
		text := transmute([]u8)nested_in_root(depth, objects)
		testkit.expect_reads_on_thread(t, stack, testkit.DEEP_CORE_READS + 1, text, fmt.tprintf("objects %v depth %d", objects, depth), read_nested)
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
