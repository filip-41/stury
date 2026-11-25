package jq

import "stury:lib/query"

// jq's path steps over the engine's containers: `.name`, `.[k]`, `.[a:b]` and `.[]`, and the paths a path expression
// builds with them.

// The mark of a path register that holds no path: the value a path expression made instead, which jq names in its error.
@(private)
NOT_PATH :: u16(1)

@(private)
not_path_marker :: proc(m: ^Machine, v: query.Value) -> query.Value {
	x := query.retain(v)
	x.mark = NOT_PATH
	return x
}

@(private)
is_path :: #force_inline proc "contextless" (p: query.Value) -> bool {
	return p.mark != NOT_PATH
}

// Path `p` with `key` after it.
@(private)
path_append :: proc(m: ^Machine, p: query.Value, key: query.Value) -> (res: query.Value, status: query.Status) {
	out := query.retain(p)
	if out.kind != .Array {
		query.release(m.h, out)
		out = query.make_array(m.h, 4) or_return
	}
	if s := query.append_owned(m.h, &out, query.retain(key)); s != .Ok {
		query.release(m.h, out)
		return query.NULL, s
	}
	return out, .Ok
}

// Applies step node `n`'s operation to target `t` with key `key` or bounds `from` and `to` (unused by `.[]`): the
// value, or none for a failure of an optional step.
@(private)
apply_step :: proc(m: ^Machine, n: ^Node, t, key, from, to: query.Value) -> (res: query.Value, found: bool, status: query.Status) {
	v: query.Value
	s: query.Status
	#partial switch n.kind {
	case .Field:
		v, s = query.get(m.h, t, n.value)
	case .Index:
		v, s = query.get(m.h, t, key)
	case .Slice:
		v, s = query.slice(m.h, t, from, to)
	}
	if s != .Ok {
		if .Opt in n.flags && !is_fatal_error(m.h) {
			query.clear_error(m.h)
			return query.NULL, false, .Ok
		}
		return query.NULL, false, s
	}
	return v, true, .Ok
}
