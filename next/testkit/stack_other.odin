#+build windows
package testkit

import "core:testing"

Stack_Read :: #type proc(read: int, text: []u8) -> bool

// Non-POSIX fallback: runs each `read` directly on the calling thread.
expect_reads_on_thread :: proc(t: ^testing.T, stack: uint, reads: int, text: []u8, what: string, run: Stack_Read, loc := #caller_location) {
	for read in 0 ..< reads {
		testing.expectf(t, run(read, text), "read %d %s", read, what, loc = loc)
	}
}
