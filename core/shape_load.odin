package core

// The read halves of a writer's scalar leaves: the value of a field of the op's width, widened to the
// 64-bit type every format spells. A writer calls them per value.

import "core:strconv"

// A signed integer of `size` bytes.
shape_int_load :: proc(data: rawptr, size: u8) -> i64 {
	switch size {
	case 1:
		return i64((^i8)(data)^)
	case 2:
		return i64((^i16)(data)^)
	case 4:
		return i64((^i32)(data)^)
	}
	return (^i64)(data)^
}

// An unsigned integer, or a boolean or a union tag, of `size` bytes.
shape_uint_load :: proc(data: rawptr, size: u8) -> u64 {
	switch size {
	case 1:
		return u64((^u8)(data)^)
	case 2:
		return u64((^u16)(data)^)
	case 4:
		return u64((^u32)(data)^)
	}
	return (^u64)(data)^
}

// The float of `size` bytes as the binary64 whose shortest round-trip digits are the field's own. An f16 or
// f32 widens exactly, but its widened value's shortest digits are a binary64's (`f32(0.1)` is
// 0.10000000149011612), so a narrow float goes through its shortest digits at its own width. Those have at
// most 9 significant digits, so the nearest binary64 writes them back unchanged.
shape_float_load :: proc(data: rawptr, size: u8) -> f64 {
	switch size {
	case 2:
		return narrow_float(f64((^f16)(data)^), 16)
	case 4:
		return narrow_float(f64((^f32)(data)^), 32)
	}
	return (^f64)(data)^
}

@(private)
narrow_float :: proc(x: f64, bit_size: int) -> f64 {
	// Zero keeps its sign, and a non-finite value (every exponent bit set) is the caller's to refuse.
	if x == 0 || transmute(u64)x >> 52 & 0x7ff == 0x7ff {
		return x
	}
	buf: [32]u8
	shortest, ok := strconv.parse_f64(strconv.write_float(buf[:], x, 'e', -1, bit_size))
	assert(ok, "strconv's own spelling of a finite float parses")
	return shortest
}
