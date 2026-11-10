package jq

// Arithmetic and comparison.

import "core:math"
import "core:strings"
import core_pkg "../../../core"

// Whether `compare`'s result `c` on two values holds the comparison `op` between them.
compared :: proc(op: Op, c: int) -> bool {
	#partial switch op {
	case .Eq:
		return c == 0
	case .Ne:
		return c != 0
	case .Lt:
		return c < 0
	case .Le:
		return c <= 0
	case .Gt:
		return c > 0
	}
	return c >= 0
}

// The error of the comparisons since `too_deep` was cleared, if one met nesting past MAX_DEPTH, as jq's do.
compare_failed :: proc(ip: ^Interp, eq: bool) -> Signal {
	if !too_deep {
		return .Go
	}
	return fail(ip, "Equality check too deep" if eq else "Comparison too deep")
}

// With `owned`, `+` and `*` change `a` in place where `a` is or holds a container the set names (modify.odin).
binary_op :: proc(ip: ^Interp, op: Op, a, b: Value, owned: ^Owned = nil) -> (Value, Signal) {
	if x, is_number := built_f64(a); is_number {
		if y, both := built_f64(b); both {
			#partial switch op {
			case .Add:
				return x + y, .Go
			case .Sub:
				return x - y, .Go
			case .Mul:
				return x * y, .Go
			case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
				// Two numbers compare by their doubles unless both keep digits (core's `compare`).
				_, a_computed := a.(f64)
				_, b_computed := b.(f64)
				if a_computed || b_computed {
					return compared(op, double_order(x, y)), .Go
				}
			}
		}
	}
	return other_binary_op(ip, op, a, b, owned)
}

// The order of two doubles as core's `compare` orders numbers: nan below every number, itself included.
@(private = "file")
double_order :: #force_inline proc(x, y: f64) -> int {
	switch {
	case math.is_nan(x):
		return -1
	case math.is_nan(y):
		return 1
	}
	return -1 if x < y else (1 if x > y else 0)
}

// `binary_op` of operands that are not both doubles, or of an operator other than `+`, `-` and `*`.
@(private = "file")
other_binary_op :: #force_no_inline proc(ip: ^Interp, op: Op, a, b: Value, owned: ^Owned) -> (Value, Signal) {
	if x, is_number := operand_f64(a); is_number {
		if y, both := operand_f64(b); both {
			#partial switch op {
			case .Add:
				return num(x + y), .Go
			case .Sub:
				return num(x - y), .Go
			case .Mul:
				return num(x * y), .Go
			case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
				// Rounding keeps order, so unequal doubles order their numbers, and only equal ones need the digits.
				if x != y {
					return compared(op, double_order(x, y)), .Go
				}
			}
		}
	}
	#partial switch op {
	case .Eq, .Ne, .Lt, .Le, .Gt, .Ge:
		too_deep = false
		c := compare(a, b, eq = op == .Eq || op == .Ne)
		if sig := compare_failed(ip, op == .Eq || op == .Ne); sig != .Go {
			return nil, sig
		}
		return compared(op, c), .Go
	case .Add:
		return add(ip, a, b, owned)
	case .Sub:
		return subtract(ip, a, b)
	case .Mul:
		return multiply(ip, a, b, owned)
	case .Div:
		return divide(ip, a, b)
	case .Mod:
		return modulo(ip, a, b)
	}
	return nil, fail(ip, "unknown operator")
}

// The double of a number that is no node of a document.
@(private = "file")
built_f64 :: #force_inline proc(v: Value) -> (f64, bool) {
	#partial switch n in v {
	case f64:
		return n, true
	case ^Number_Text:
		return n.double, true
	}
	return 0, false
}

// The double of a built number or of a number node in its format's plain spelling, read by the document's reader.
@(private = "file")
operand_f64 :: #force_inline proc(v: Value) -> (f64, bool) {
	#partial switch n in v {
	case f64:
		return n, true
	case ^Number_Text:
		return n.double, true
	case Ref:
		node := n.doc.nodes[n.node]
		if node.kind == .Number && node.spelling & core_pkg.NUMBER_KIND_MASK == 0 {
			x, _ := core_pkg.number(n.doc, n.node)
			return number_f64(x, string(core_pkg.span(n.doc, n.node))), true
		}
	}
	return 0, false
}

@(private = "file")
cannot :: proc(ip: ^Interp, a, b: Value, what: string) -> (Value, Signal) {
	return nil, fail(ip, "%s (%s) and %s (%s) cannot be %s", type_name(a), brief(ip, a), type_name(b), brief(ip, b), what)
}

// The sum carries no comments, as any value computed does.
add :: proc(ip: ^Interp, a, b: Value, owned: ^Owned = nil) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Null:
		return plain(b), .Go
	case kb == .Null, kb == ka && (kb == .Array || kb == .Object) && is_empty(b):
		return plain(a), .Go // jq appends b's members to a itself, so a path expression keeps a's path
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		return num(x.f + y.f), .Go
	case ka == .String && kb == .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		if owned != nil {
			return append_owned(ip, x, y, owned), .Go
		}
		return strings.concatenate({x, y}), .Go
	case ka == .Array && kb == .Array:
		r: ^Array
		if owned != nil {
			r = owned_copy(a, owned).(^Array)
		} else {
			r = new_array(length_of(a) + length_of(b))
			append_elements(r, a)
		}
		append_elements(r, b)
		return r, .Go
	case ka == .Object && kb == .Object:
		r := (owned_copy(a, owned) if owned != nil else own(a)).(^Object)
		it := iterate(b)
		for k, m in next_member(&it) {
			object_put(r, k, m)
		}
		return r, .Go
	}
	return cannot(ip, a, b, "added")
}

// `v`'s elements onto `r`: a block copy from another array, else a member at a time, so `. + .` on a reduce's own
// state reads the array as it grows.
@(private = "file")
append_elements :: #force_inline proc(r: ^Array, v: Value) {
	if x, is_array := v.(^Array); is_array && x != r {
		append(&r.items, ..x.items[:])
		return
	}
	it := iterate(v)
	for _, m in next_member(&it) {
		append(&r.items, m)
	}
}

// Whether `add` takes `a` and `b` rather than fails.
addable :: proc(a, b: Value) -> bool {
	ka, kb := kind(a), kind(b)
	return ka == .Null || kb == .Null || ka == kb && (ka == .Number || ka == .String || ka == .Array || ka == .Object)
}

subtract :: proc(ip: ^Interp, a, b: Value) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		return num(x.f - y.f), .Go
	case ka == .Array && kb == .Array:
		r := new_array()
		too_deep = false
		xs, ys := elements(a), elements(b)
		indexed := worth_indexing(len(ys), len(xs))
		ix: Scalar_Index
		if indexed {
			ix = index_scalars(ys)
		}
		outer: for m in xs {
			if indexed {
				found, scalar := index_has(&ix, m)
				if found {
					continue outer
				}
				if scalar {
					append(&r.items, m)
					continue outer
				}
			}
			for x in ys {
				if equal(m, x) {
					continue outer
				}
			}
			append(&r.items, m)
		}
		return r, compare_failed(ip, true)
	}
	return cannot(ip, a, b, "subtracted")
}

multiply :: proc(ip: ^Interp, a, b: Value, owned: ^Owned = nil) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		return num(x.f * y.f), .Go
	case ka == .String && kb == .Number, ka == .Number && kb == .String:
		s, _ := string_of(a if ka == .String else b)
		n, _ := number_of(b if ka == .String else a)
		if n.f < 0 || math.is_nan(n.f) {
			return nil, .Go
		}
		times := int(min(n.f, f64(max(i32))))
		if len(s) * times >= int(max(i32)) - 8 { // jq's string length limit, an int less its header
			return nil, fail(ip, "Repeat string result too long")
		}
		return strings.repeat(s, times), .Go
	case ka == .Object && kb == .Object:
		if is_empty(b) {
			return plain(a), .Go // a itself, as `+`
		}
		if r := (owned_copy(a, owned) if owned != nil else own(a)).(^Object); merge_into(r, b, owned) {
			return r, .Go
		}
		return nil, fail(ip, "Object merge too deep")
	}
	return cannot(ip, a, b, "multiplied")
}

// `b` merged into `r` itself, objects within objects too. It returns false if they nest deeper than jq merges. Given
// an `owned` set, the objects within `r` are merged into in place, each copied only the first time.
merge_into :: proc(r: ^Object, b: Value, owned: ^Owned = nil, depth := 0) -> bool {
	if depth > MAX_DEPTH {
		return false
	}
	it := iterate(b)
	for k, m in next_member(&it) {
		old, has := object_get(r, k)
		if has && kind(old) == .Object && kind(m) == .Object {
			inner := (owned_copy(old, owned) if owned != nil else own(old)).(^Object)
			if !merge_into(inner, m, owned, depth + 1) {
				return false
			}
			object_put(r, k, inner)
		} else {
			object_put(r, k, m)
		}
	}
	return true
}

divide :: proc(ip: ^Interp, a, b: Value) -> (Value, Signal) {
	ka, kb := kind(a), kind(b)
	switch {
	case ka == .Number && kb == .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		if y.f == 0 {
			return cannot(ip, a, b, "divided because the divisor is zero")
		}
		return num(x.f / y.f), .Go
	case ka == .String && kb == .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		return split_string(x, y), .Go
	}
	return cannot(ip, a, b, "divided")
}

modulo :: proc(ip: ^Interp, a, b: Value) -> (Value, Signal) {
	if kind(a) != .Number || kind(b) != .Number {
		return cannot(ip, a, b, "divided (remainder)")
	}
	x, _ := number_of(a)
	y, _ := number_of(b)
	if math.is_nan(x.f) || math.is_nan(y.f) {
		return num(math.nan_f64()), .Go
	}
	xi, yi := double_to_i64(x.f), double_to_i64(y.f)
	if yi == 0 {
		return cannot(ip, a, b, "divided (remainder) because the divisor is zero")
	}
	if yi == -1 { // jq's guard against min(i64) % -1
		return num(0), .Go
	}
	return num(f64(xi % yi)), .Go
}

// A double cut toward zero to a 64-bit integer: saturated past `[min(i64), max(i64)]`, NaN as 0.
double_to_i64 :: proc(f: f64) -> i64 {
	switch {
	case math.is_nan(f):
		return 0
	case f >= 1 << 63:
		return max(i64)
	case f < -(1 << 63):
		return min(i64)
	}
	return i64(f)
}

split_string :: proc(s, sep: string) -> Value {
	a := new_array()
	if s == "" {
		return a
	}
	if sep == "" {
		for r, i in s {
			_ = r
			n := i + 1
			for n < len(s) && s[n] & 0xc0 == 0x80 {
				n += 1
			}
			append(&a.items, s[i:n])
		}
		return a
	}
	for part in strings.split(s, sep) {
		append(&a.items, part)
	}
	return a
}
