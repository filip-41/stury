package json_tests

import "core:testing"
import "../../scan/walk"

// `resolve_under` clamps every cap: depth to the ceiling, the digit cap to the u32 range and the scale cap to the i32
// range. A zero field takes its default.
@(test)
test_resolve_clamps_every_cap :: proc(t: ^testing.T) {
	got := walk.resolve_under(walk.Limits{max_depth = max(u64), max_scalar_digits = max(u64), max_scalar_scale = max(u64)}, walk.DEPTH_CEILING)
	testing.expect_value(t, got.max_depth, walk.DEPTH_CEILING)
	testing.expect_value(t, got.max_scalar_digits, u64(max(u32)))
	testing.expect_value(t, got.max_scalar_scale, u64(max(i32)))
	testing.expect_value(t, walk.resolve_under(walk.Limits{}, walk.DEPTH_CEILING), walk.Limits{walk.MAX_DEPTH, walk.MAX_SCALAR_DIGITS, walk.MAX_SCALAR_SCALE})
	// One past each representable cap is clamped to it, and the cap itself is kept.
	testing.expect_value(t, walk.resolve_under(walk.Limits{max_scalar_digits = u64(max(u32)) + 1}, walk.DEPTH_CEILING).max_scalar_digits, u64(max(u32)))
	testing.expect_value(t, walk.resolve_under(walk.Limits{max_scalar_scale = u64(max(i32))}, walk.DEPTH_CEILING).max_scalar_scale, u64(max(i32)))
}
