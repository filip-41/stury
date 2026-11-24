#+build darwin, linux, freebsd, openbsd, netbsd
package cbor_tests

import "core:fmt"
import "core:testing"
import "stury:cbor"
import "stury:lib/core/tape"
import "stury:testkit"

// Reads the nested text five ways, a verdict, a document, the first element at each level, a scan of two paths and a
// typed read, and `testkit.deep_read`'s ways, which take the records of the innermost array.
read_nested :: proc(read: int, text: []u8) -> bool {
	opts := cbor.Options{budget = {depth = 200_000}}
	if read >= 5 {
		at := make([]tape.Step, len(text) - 2, context.temp_allocator)
		for &step in at {
			step = tape.Index(0)
		}
		return testkit.deep_read(read - 5, cbor.reads(.Cbor), cbor.as(.Cbor), text, opts, {{tape.Descend{}, tape.Index(0)}}, .Elements, at)
	}
	switch read {
	case 0:
		return cbor.validate(text, opts = opts) == nil
	case 1:
		doc, err := cbor.build(text, opts = opts)
		tape.destroy(&doc)
		return err == nil
	case 2:
		answer, err := cbor.find(text, {tape.Index(0)}, opts = opts)
		return err == nil && answer.outcome == .Found
	case 3:
		d, _ := tape.demand_of({{tape.Index(0)}, {tape.Index(0), tape.Index(0)}})
		r, err := cbor.scan(text, &d, opts = opts)
		tape.destroy(&r)
		tape.destroy(&d)
		return err == nil
	case:
		v: testkit.Value
		err := cbor.unmarshal(text, &v, opts = opts)
		testkit.value_free(v)
		return err == nil
	}
}

// Runs each read on a thread of `stack` bytes over `depth` nested arrays of one element and a 0 in the last.
expect_nested_reads_on_thread :: proc(t: ^testing.T, stack: uint, depth: int) {
	text := make([]u8, depth + 1, context.temp_allocator)
	for i in 0 ..< depth {
		text[i] = 0x81
	}
	testkit.expect_reads_on_thread(t, stack, 5 + testkit.DEEP_READS, text, fmt.tprintf("depth %d", depth), read_nested)
}

// Each read runs on a thread with the stack it states, over an item nesting past the frame's levels.
@(test)
reads_run_in_the_stack_they_state :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	expect_nested_reads_on_thread(t, cbor.READ_STACK + testkit.THREAD_START, 4 * cbor.WALK_LEVELS)
}

// A thread of one MiB reads an item of 100,000 levels, which the levels past the frame take from the allocator and not
// from the stack. The makefile runs it at every optimization level, as a frame's size depends on it.
@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	expect_nested_reads_on_thread(t, 1 << 20, 100_000)
}
