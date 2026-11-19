package jq

// jq's order and equality of values: the library's (`core.compare`), at jq's depth, with the depth fault in the
// interpreter's thread state.

import core_pkg "../core"

// How deep jq nests values it parses, prints, compares, checks for containment or merges.
MAX_DEPTH :: 10000

// jq's jv_cmp, or with `eq` its jv_equal. A cell of a delimited text is a string, not read as a number or a boolean.
// A comparison that meets values nested deeper than MAX_DEPTH sets `too_deep^`, which jq reports as an error.
@(private)
compare :: #force_inline proc(too_deep: ^bool, a, b: core_pkg.Value, depth := 0, eq := false) -> int {
	return core_pkg.compare(a, b, depth, eq, too_deep, MAX_DEPTH)
}

@(private)
compare_members :: #force_inline proc(too_deep: ^bool, a, b: []core_pkg.Member, depth: int, eq: bool) -> int {
	return core_pkg.compare_members(a, b, depth, eq, too_deep, MAX_DEPTH)
}

@(private)
equal :: proc(too_deep: ^bool, a, b: core_pkg.Value) -> bool {
	return compare(too_deep, a, b, eq = true) == 0
}
