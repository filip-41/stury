package tape_test

import "core:testing"
import "stury:lib/core/tape"

// Layout sizes, which change only on purpose.
@(test)
layout_sizes :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(tape.Token), 16)
	testing.expect_value(t, size_of(tape.Fact), 24)
	testing.expect_value(t, size_of(tape.Table), 28)
	when size_of(uintptr) == 8 {
		testing.expect_value(t, size_of(tape.Document), 128)
	}
}
