package core_tests

import "core:testing"
import core "../"

// `resolve` clamps every cap: a depth to the ceiling, the digit cap to what a u32 counts and the scale cap to what
// an i32 holds, and a zero field takes its default.
@(test)
test_resolve_clamps_every_cap :: proc(t: ^testing.T) {
	got := core.resolve(core.Limits{max_depth = max(u64), max_scalar_digits = max(u64), max_scalar_scale = max(u64)})
	testing.expect_value(t, got.max_depth, core.DEPTH_CEILING)
	testing.expect_value(t, got.max_scalar_digits, u64(max(u32)))
	testing.expect_value(t, got.max_scalar_scale, u64(max(i32)))
	testing.expect_value(t, core.resolve(core.Limits{}), core.Limits{core.MAX_DEPTH, core.MAX_SCALAR_DIGITS, core.MAX_SCALAR_SCALE})
	// One past each representable cap is held to it, and the cap itself is kept.
	testing.expect_value(t, core.resolve(core.Limits{max_scalar_digits = u64(max(u32)) + 1}).max_scalar_digits, u64(max(u32)))
	testing.expect_value(t, core.resolve(core.Limits{max_scalar_scale = u64(max(i32))}).max_scalar_scale, u64(max(i32)))
}
