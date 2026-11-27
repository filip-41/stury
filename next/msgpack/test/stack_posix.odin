#+build darwin, linux, freebsd, openbsd, netbsd
package msgpack_tests

import "core:fmt"
import "core:testing"
import "stury:lib/core/tape"
import "stury:msgpack"
import "stury:testkit"

// Small-stack POSIX thread tests proving zero native recursion across 100,000 nested containers
// inside a 1 MiB stack (`validate`, `build`, `find`, `scan`, `unmarshal`, and `deep_read`).

read_nested :: proc(read: int, text: []u8) -> bool {
	opts := msgpack.Options{budget = {depth = 200_000}}
	if read < testkit.DEEP_CORE_READS {
		at: []tape.Step
		if read == 6 {
			at = make([]tape.Step, len(text) - 2, context.temp_allocator)
			for &step in at {
				step = tape.Index(0)
			}
		}
		return testkit.deep_core_read(
			read, msgpack.reads(.Compact), msgpack.as(.Compact), text, opts,
			{tape.Index(0)}, {{tape.Index(0)}, {tape.Index(0), tape.Index(0)}},
			{{tape.Descend{}, tape.Index(0)}}, .Elements, at,
		)
	}
	v: testkit.Value
	err := msgpack.unmarshal(text, &v, opts = opts)
	testkit.value_free(v)
	return err == nil
}

expect_nested_reads_on_thread :: proc(t: ^testing.T, stack: uint, depth: int) {
	text := make([]u8, depth + 1, context.temp_allocator)
	for i in 0 ..< depth {
		text[i] = 0x91 // fixarray of 1 element
	}
	testkit.expect_reads_on_thread(t, stack, testkit.DEEP_CORE_READS + 1, text, fmt.tprintf("depth %d", depth), read_nested)
}

@(test)
reads_run_in_the_stack_they_state :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	expect_nested_reads_on_thread(t, msgpack.READ_STACK + testkit.THREAD_START, 4 * msgpack.WALK_LEVELS)
}

@(test)
reads_nest_100000_levels_in_one_mib :: proc(t: ^testing.T) {
	testkit.deadline(t)
	defer free_all(context.temp_allocator)
	expect_nested_reads_on_thread(t, 1 << 20, 100_000)
}
