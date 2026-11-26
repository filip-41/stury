#+build darwin, linux, freebsd, openbsd, netbsd
package gates_tests

import "core:sys/posix"
import "core:testing"
import "stury:testkit"

ONE_MIB :: uint(1 << 20)

run_on_1mib_stack :: proc(t: ^testing.T, count: int, text: []u8, what: string, run: Gate_Read, loc := #caller_location) {
	testkit.expect_reads_on_thread(t, ONE_MIB, count, text, what, run, loc = loc)
}

// Returns the process peak resident set size in bytes via POSIX `getrusage`, or 0 on failure.
max_rss_bytes :: proc() -> u64 {
	ru: posix.rusage
	if posix.getrusage(.SELF, &ru) != .OK {
		return 0
	}
	if ru.ru_maxrss <= 0 {
		return 0
	}
	when ODIN_OS == .Darwin {
		return u64(ru.ru_maxrss)
	} else {
		return u64(ru.ru_maxrss) * 1024
	}
}
