package jq

// jq's order and equality of values: the library's (`core.compare`), at jq's depth, with the depth fault in the
// interpreter's thread state.

import core_pkg "../../../core"

Member :: core_pkg.Member
is_wide :: core_pkg.is_wide
sorted_members :: core_pkg.sorted_members
sorted_keys :: core_pkg.sorted_keys
text_order :: core_pkg.text_order
same :: core_pkg.same

// How deep jq nests values it parses, prints, compares, checks for containment or merges.
MAX_DEPTH :: 10000

// Set when a comparison met values nested deeper than MAX_DEPTH, which jq reports as an error.
@(thread_local)
too_deep: bool

// jq's jv_cmp, or with `eq` its jv_equal. A cell of a delimited text is a string, not read as a number or a boolean.
compare :: #force_inline proc(a, b: Value, depth := 0, eq := false) -> int {
	return core_pkg.compare(a, b, depth, eq, &too_deep, MAX_DEPTH, read_plain = false)
}

compare_members :: #force_inline proc(a, b: []Member, depth: int, eq: bool) -> int {
	return core_pkg.compare_members(a, b, depth, eq, &too_deep, MAX_DEPTH, read_plain = false)
}

equal :: proc(a, b: Value) -> bool {
	return compare(a, b, eq = true) == 0
}
