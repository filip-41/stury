package walk

// The default cap on nesting, and the depth the walk's fixed frame array holds: one 24-byte `Open_Frame`
// per open container, 24 KiB of stack whatever the document says. A `max_depth` above it walks on frames
// that spill to `context.allocator` once the input passes this depth.
MAX_DEPTH :: 1024

// The largest `max_depth` a caller may ask for (`resolve_under` clamps a larger one to it). Its spilled frames are
// 24 bytes a level, 24 MiB at the ceiling, allocated only for input that nests past MAX_DEPTH.
DEPTH_CEILING :: 1 << 20

// Default scalar caps. The Strict walk refuses an over-cap scalar at the token, before any coefficient
// exists. The skip route never validates them.
MAX_SCALAR_DIGITS :: 256 // authored mantissa digits, well past binary64's 17

MAX_SCALAR_SCALE :: 4096 // |exponent| and |scale| (~13x binary64's 308)

// The three scalar and nesting caps. A zero field takes its default (`MAX_DEPTH`, `MAX_SCALAR_DIGITS`,
// `MAX_SCALAR_SCALE`). `resolve_under` clamps all three, so the enforced cap is never larger than asked nor
// than the walk can carry. Each has one enforcement point: `max_depth` is the walk's push check, and the scalar
// pair bind the Strict number token.
Limits :: struct {
	max_depth:         u64, // 0 => MAX_DEPTH (clamped to DEPTH_CEILING)
	max_scalar_digits: u64, // 0 => MAX_SCALAR_DIGITS (clamped to MAX_SCALAR_DIGITS_REPRESENTABLE)
	max_scalar_scale:  u64, // 0 => MAX_SCALAR_SCALE (clamped to MAX_SCALAR_SCALE_REPRESENTABLE)
}

// Zero fields take their default. Resolved once per entry point, so the walk reads a plain cap and
// never re-tests for "unset". A cap raised past what the walk can carry is clamped to that, and `max_depth` to
// `ceiling`: MAX_DEPTH for a walk on the fixed frames, which a constant tells the compiler, so a checked push
// needs no second test of its frame index.
resolve_under :: #force_inline proc(limits: Limits, $ceiling: u64) -> Limits {
	o := limits
	if o.max_depth == 0 {
		o.max_depth = MAX_DEPTH
	}
	if o.max_depth > ceiling {
		o.max_depth = ceiling
	}
	if o.max_scalar_digits == 0 {
		o.max_scalar_digits = MAX_SCALAR_DIGITS
	}
	if o.max_scalar_scale == 0 {
		o.max_scalar_scale = MAX_SCALAR_SCALE
	}
	if o.max_scalar_digits > MAX_SCALAR_DIGITS_REPRESENTABLE {
		o.max_scalar_digits = MAX_SCALAR_DIGITS_REPRESENTABLE
	}
	if o.max_scalar_scale > MAX_SCALAR_SCALE_REPRESENTABLE {
		o.max_scalar_scale = MAX_SCALAR_SCALE_REPRESENTABLE
	}
	return o
}

// The largest scalar caps: a digit count in a u32 and a scale in an i32. `resolve_under`
// clamps to these.
MAX_SCALAR_DIGITS_REPRESENTABLE :: u64(max(u32))

MAX_SCALAR_SCALE_REPRESENTABLE :: u64(max(i32))
