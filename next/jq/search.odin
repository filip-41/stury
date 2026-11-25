package jq

import "stury:lib/query"

// bsearch: the index of the target in the sorted input, or minus one minus where it would go.
@(private)
v_bsearch :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	at := query.search_sorted(m.h, x, args[0]) or_return
	return query.int_value(at), .Ok
}
