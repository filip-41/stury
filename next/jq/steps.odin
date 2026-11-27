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

// Whether tracked path `p` ends in a fact step (which must be the last step of any path).
@(private)
path_ends_in_fact :: proc(h: ^query.Heap, p: query.Value) -> bool {
	if p.kind != .Array {
		return false
	}
	items := query.items_of(p)
	if len(items) == 0 {
		return false
	}
	_, _, is_fact := query.fact_step(h, items[len(items) - 1])
	return is_fact
}

// `_fact_step(name)`: builds the fact path step `{"fact": ...}` for `.@(expr)`.
@(private)
v_fact_step :: proc(m: ^Machine, _: ^Builtin, _: query.Value, args: []query.Value) -> (query.Value, query.Status) {
	if !query.is_text(args[0]) {
		out := make([dynamic]u8, m.h.allocator)
		defer delete(out)
		append(&out, "a fact name is a string, not ")
		typed(m.h, &out, args[0])
		return query.NULL, raise_owned_text(m, string(out[:]))
	}
	name := query.text_of(args[0])
	kind, known := query.fact_named(name)
	if !known {
		return query.NULL, query.fail_unknown_fact(m.h, name)
	}
	return query.fact_key(m.h, kind)
}

// `_attribute_step(name)`: builds the attribute path step `{"fact": "attribute", "name": name}` for `.&[expr]`.
@(private)
v_attribute_step :: proc(m: ^Machine, _: ^Builtin, _: query.Value, args: []query.Value) -> (query.Value, query.Status) {
	if !query.is_text(args[0]) {
		out := make([dynamic]u8, m.h.allocator)
		defer delete(out)
		append(&out, "an attribute name is a string, not ")
		typed(m.h, &out, args[0])
		return query.NULL, raise_owned_text(m, string(out[:]))
	}
	return query.attribute_key(m.h, query.text_of(args[0]))
}
