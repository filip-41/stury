package jq

import "core:math"
import "stury:lib/query"

// jq's operators over the engine's values: which engine operation each operand type pair takes, and jq's order.

// `a op b` for an arithmetic or comparison operator.
@(private, require_results)
binary_value :: proc(h: ^query.Heap, op: Op, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	#partial switch op {
	case .Add:
		return add_values(h, a, b)
	case .Sub:
		return sub_values(h, a, b)
	case .Mul:
		return mul_values(h, a, b)
	case .Div:
		return div_values(h, a, b)
	case .Mod:
		if query.is_number(a) && query.is_number(b) {
			return query.num_rem(h, a, b, true)
		}
		return query.NULL, query.fail(h, .Types, .Remainder, a, b)
	case .Eq, .Ne:
		same := query.equal(h, a, b) or_return
		return query.bool_value(same == (op == .Eq)), .Ok
	}
	r := query.compare(h, a, b) or_return
	#partial switch op {
	case .Lt:
		return query.bool_value(r < 0), .Ok
	case .Le:
		return query.bool_value(r <= 0), .Ok
	case .Gt:
		return query.bool_value(r > 0), .Ok
	}
	return query.bool_value(r >= 0), .Ok
}

@(private, require_results)
add_values :: proc(h: ^query.Heap, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	if a.kind == .Int && b.kind == .Int {
		return query.num_add(h, a, b)
	}
	ta, tb := query.type_of(a), query.type_of(b)
	switch {
	case ta == .Null || ta == .Absent:
		return query.retain(b), .Ok
	case tb == .Null || tb == .Absent:
		return query.retain(a), .Ok
	case ta == .Number && tb == .Number:
		return query.num_add(h, a, b)
	case ta == .String && tb == .String:
		return query.text_concat(h, a, b)
	case ta == .Bytes && tb == .Bytes:
		return query.bytes_concat(h, a, b)
	case ta == .Array && tb == .Array:
		return query.array_concat(h, a, b)
	case ta == .Object && tb == .Object:
		return query.object_merge(h, a, b, false)
	}
	return query.NULL, query.fail(h, .Types, .Add, a, b)
}

@(private, require_results)
sub_values :: proc(h: ^query.Heap, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	ta, tb := query.type_of(a), query.type_of(b)
	switch {
	case ta == .Number && tb == .Number:
		return query.num_sub(h, a, b)
	case ta == .Array && tb == .Array:
		return query.array_without(h, a, b)
	}
	return query.NULL, query.fail(h, .Types, .Subtract, a, b)
}

@(private, require_results)
mul_values :: proc(h: ^query.Heap, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	ta, tb := query.type_of(a), query.type_of(b)
	switch {
	case ta == .Number && tb == .Number:
		return query.num_mul(h, a, b)
	case ta == .String && tb == .Number:
		return repeat_text(h, a, b)
	case ta == .Number && tb == .String:
		return repeat_text(h, b, a)
	case ta == .Object && tb == .Object:
		return query.object_merge(h, a, b, true)
	}
	return query.NULL, query.fail(h, .Types, .Multiply, a, b)
}

// String `s` repeated `n` times, rounded down: null for a negative count or NaN, empty below 1.
@(private, require_results)
repeat_text :: proc(h: ^query.Heap, s, n: query.Value) -> (res: query.Value, status: query.Status) {
	f := query.as_f64(n)
	if math.is_nan(f) || f < 0 {
		return query.NULL, .Ok
	}
	if f < 1 || len(query.text_of(s)) == 0 {
		return query.text_borrowed(""), .Ok
	}
	if f64(len(query.text_of(s))) * math.floor(f) > f64(max(i32)) {
		return query.NULL, query.fail(h, .Range, .Repeat, s, n, "Repeat string result too long")
	}
	return query.text_repeat(h, s, int(min(f, f64(max(i32)))))
}

@(private, require_results)
div_values :: proc(h: ^query.Heap, a, b: query.Value) -> (res: query.Value, status: query.Status) {
	ta, tb := query.type_of(a), query.type_of(b)
	switch {
	case ta == .Number && tb == .Number:
		return query.num_div(h, a, b)
	case ta == .String && tb == .String:
		return query.text_split(h, a, query.text_of(b))
	}
	return query.NULL, query.fail(h, .Types, .Divide, a, b)
}
