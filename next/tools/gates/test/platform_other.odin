#+build windows
package gates_tests

import "core:testing"

ONE_MIB :: uint(1 << 20)

run_on_1mib_stack :: proc(t: ^testing.T, count: int, text: []u8, what: string, run: Gate_Read, loc := #caller_location) {
	for i in 0 ..< count {
		testing.expectf(t, run(i, text), "read %d %s", i, what, loc = loc)
	}
}

max_rss_bytes :: proc() -> u64 {
	return 0
}
