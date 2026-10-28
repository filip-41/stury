package walk

import core_pkg "../../../core"

// What a JSON value is: core's `Kind`, one enum for every carrier (`.Nodes` rows, path answers, demand spans).
Kind :: core_pkg.Kind

// A handle to one value of a document, the index of its row: core's `Node`.
Node :: core_pkg.Node
NO_NODE :: core_pkg.NO_NODE

// The escape latch's ceiling: an offset equal to it is only a lower bound.
FIRST_ESC_SATURATED :: u16(0xFFFF)

// Whether this value token's source text carried an escape. Meaningful only for
// `.String` rows. False on every other kind.
str_escaped :: proc(r: Row) -> bool {
	return .Str_Escaped in r.flags
}

// Where the first backslash in a string value's source text sits, as a byte offset
// from the row's `lo` (the opening quote), and whether it is known.
//
// The offset includes the quote, so the clean head is `src[lo+1:lo+off]`, not
// `lo+1+off`, which would copy the backslash. `known` is false for an escape-free
// string and for every non-`.String` row.
//
// The latch holds `min(off, FIRST_ESC_SATURATED)`: an offset equal to the cap is a
// lower bound. The clean-head range stays valid either way, but a decoder must then
// look for the backslash at or past `lo+off`.
first_escape_offset :: proc(r: Row) -> (offset: u64, known: bool) {
	if r.kind != .String || !(.Str_Escaped in r.flags) {
		return 0, false
	}
	return u64(r.first_esc), true
}

// A number token's digit counts as its row holds them in `first_esc`, which a number has no use for: the
// integer run's in the low byte, the fraction run's in the high one, each capped at 255. The walk counts both
// to check the digit cap, so a reader learns where the runs end without looking for the `.` and the `e`.
number_digits_pack :: #force_inline proc(int_digits, frac_digits: u64) -> u16 {
	return u16(min(int_digits, 255)) | u16(min(frac_digits, 255)) << 8
}

// "No key" in the walk's u64 latch (`Query_Ctx.node_key_lo`). `emit_node`'s
// u32 cast turns it into `NO_KEY`, which the assertion pins.
NO_KEY_LATCH :: u64(0xFFFF_FFFF_FFFF_FFFF)
#assert(NO_KEY_LATCH & 0xFFFF_FFFF == u64(NO_KEY))

// "No row", in the width a row index is stored in: `Open_Frame.row` holds it when
// `edge_push` dropped the row on a failed grow. It is never a real row index.
NO_ROW :: u32(0xFFFF_FFFF)
