package jq

// jq's order and equality of values, and the sorted views of an object they compare by.

import "core:math"
import "core:slice"
import "core:strings"
import core_pkg "../../../core"

// The members from which compare() and -S sort keys and values together: a key lookup in a document object scans
// every member, so past this many one walk over both sorted lists beats a lookup per key. Below it, a
// key-only sort and a few lookups are cheaper than sorting pairs.
WIDE_OBJECT :: 64

// Whether `v` has at least WIDE_OBJECT members. A document object's rows are counted, a repeated key's too, since
// length_of would scan them for repeats on every comparison.
is_wide :: proc(v: Value) -> bool {
	#partial switch x in v {
	case ^Object:
		return len(x.keys) >= WIDE_OBJECT
	case Ref:
		return core_pkg.length(x.doc, x.node) >= WIDE_OBJECT
	}
	return false
}

// One member of an object, as `sorted_members` lists it.
Member :: struct {
	key: string,
	val: Value,
}

// An object's members sorted by their keys' codepoints, each key once (a repeated key has its last value), so
// a comparison or a sorted reprint is one walk and not a key lookup per member.
sorted_members :: proc(v: Value) -> []Member {
	it := iterate(v)
	ms := make([dynamic]Member, 0, it.n)
	for k, m in next_member(&it) {
		append(&ms, Member{k, m})
	}
	slice.sort_by(ms[:], proc(a, b: Member) -> bool {return a.key < b.key})
	return ms[:]
}

// jq's order of two objects from their sorted members: the key sets, then the values in key order.
compare_members :: proc(a, b: []Member, depth: int, eq: bool) -> int {
	for i in 0 ..< min(len(a), len(b)) {
		if c := text_order(a[i].key, b[i].key); c != 0 {
			return c
		}
	}
	if len(a) != len(b) {
		return -1 if len(a) < len(b) else 1
	}
	for m, i in a {
		if c := compare(m.val, b[i].val, depth + 1, eq); c != 0 {
			return c
		}
	}
	return 0
}

// A number literal as a decimal: 0.(head ++ tail) × 10^point, without leading or trailing zeros.
// `head` and `tail` slice the literal on either side of its `.`, so no buffer is allocated.
@(private = "file")
Decimal :: struct {
	neg:        bool,
	head, tail: string, // both "" for zero
	point:      int,
}

// `lit` as a decimal in decNumber's range, which jq keeps a literal inside: past an adjusted exponent of 999999999 the
// number keeps no literal (false), and below -1147483646 it is a zero.
@(private = "file")
decimal_of :: proc(lit: string) -> (d: Decimal, ok: bool) {
	s := lit
	if len(s) > 0 && (s[0] == '-' || s[0] == '+') {
		d.neg, s = s[0] == '-', s[1:]
	}
	exp := 0
	if i := strings.index_any(s, "eE"); i >= 0 {
		exp = literal_exponent(s[i + 1:])
		s = s[:i]
	}
	int_s, frac_s := s, ""
	if dot := strings.index_byte(s, '.'); dot >= 0 {
		int_s, frac_s = s[:dot], s[dot + 1:]
	}
	head := strings.trim_left(int_s, "0")
	tail := frac_s
	lead := len(int_s) - len(head)
	if head == "" {
		trimmed := strings.trim_left(tail, "0")
		lead += len(tail) - len(trimmed)
		head = strings.trim_right(trimmed, "0")
		tail = ""
	} else {
		tail = strings.trim_right(tail, "0")
		if tail == "" {
			head = strings.trim_right(head, "0")
		}
	}
	d.point = len(int_s) + exp - lead
	switch {
	case head == "":
	case d.point - 1 > 999999999:
		return d, false
	case d.point - 1 < -1147483646:
		head, tail = "", ""
	}
	d.head, d.tail = head, tail
	d.neg = d.neg && head != ""
	return d, true
}

// The exponent field of a literal, the text after its `e`: it saturates at 2^31 however many digits it has, where a
// plain parse would wrap.
@(private = "file")
literal_exponent :: proc(field: string) -> int {
	i := 0
	neg := len(field) > 0 && field[0] == '-'
	if len(field) > 0 && (field[0] == '-' || field[0] == '+') {
		i = 1
	}
	e := 0
	for ; i < len(field) && '0' <= field[i] && field[i] <= '9'; i += 1 {
		e = min(e * 10 + int(field[i] - '0'), 1 << 31)
	}
	return -e if neg else e
}

// The order of two decimals (`-1` to `1`), as jq compares two literals: `1.0` equals `1`, and `-1e-400` is below `0`
// though it is `-0.0` as a double.
@(private = "file")
compare_decimals :: proc(x, y: Decimal) -> int {
	if x.neg != y.neg {
		return -1 if x.neg else 1
	}
	mag: int
	switch {
	case x.head == "" || y.head == "":
		mag = int(x.head != "") - int(y.head != "")
	case x.point != y.point:
		mag = -1 if x.point < y.point else 1
	case x.tail == "" && y.tail == "":
		mag = strings.compare(x.head, y.head)
	case:
		nx, ny := len(x.head) + len(x.tail), len(y.head) + len(y.tail)
		for i in 0 ..< min(nx, ny) {
			cx := x.head[i] if i < len(x.head) else x.tail[i - len(x.head)]
			cy := y.head[i] if i < len(y.head) else y.tail[i - len(y.head)]
			if cx != cy {
				mag = -1 if cx < cy else 1
				break
			}
		}
		if mag == 0 {
			mag = -1 if nx < ny else (1 if nx > ny else 0)
		}
	}
	return -mag if x.neg else mag
}

// How deep jq nests values it parses, prints, compares, checks for containment or merges.
MAX_DEPTH :: 10000

// Set when a comparison met values nested deeper than MAX_DEPTH, which jq reports as an error.
@(thread_local)
too_deep: bool

// jq's jv_cmp, or with `eq` its jv_equal, which takes a value as equal to itself without reading it: so `. == .`
// holds however deep the value is. jq's order: null < false < true < numbers < strings < arrays < objects. Arrays
// element-wise, objects by their sorted key sets and then their values in key order.
compare :: proc(a, b: Value, depth := 0, eq := false) -> int {
	if depth > MAX_DEPTH {
		too_deep = true
		return 0
	}
	if eq && same(a, b) {
		return 0
	}
	ka, kb := kind(a), kind(b)
	if ka != kb {
		return -1 if ka < kb else 1
	}
	switch ka {
	case .Null, .False, .True:
		return 0
	case .Number:
		x, _ := number_of(a)
		y, _ := number_of(b)
		// jq orders nan below every number, itself included.
		if math.is_nan(x.f) {
			return -1
		}
		if math.is_nan(y.f) {
			return 1
		}
		if x.f == y.f && x.lit != y.lit && x.lit != "" && y.lit != "" {
			// jq compares two literals as decimals, unless one is past decNumber's range and so a plain double.
			dx, x_ok := decimal_of(x.lit)
			dy, y_ok := decimal_of(y.lit)
			if x_ok && y_ok {
				return compare_decimals(dx, dy)
			}
		}
		return -1 if x.f < y.f else (1 if x.f > y.f else 0)
	case .String:
		x, _ := string_of(a)
		y, _ := string_of(b)
		return text_order(x, y)
	case .Array:
		if x, a_arr := a.(^Array); a_arr {
			if y, b_arr := b.(^Array); b_arr {
				return compare_items(x.items[:], y.items[:], depth, eq)
			}
		}
		_, a_path := a.(Path)
		_, b_path := b.(Path)
		if a_path || b_path {
			return compare_path_members(a, b, depth, eq)
		}
		na, nb := length_of(a), length_of(b)
		ia, ib := iterate(a), iterate(b)
		for _ in 0 ..< min(na, nb) {
			_, x, _ := next_member(&ia)
			_, y, _ := next_member(&ib)
			if c := compare(x, y, depth + 1, eq); c != 0 {
				return c
			}
		}
		return -1 if na < nb else (1 if na > nb else 0)
	case .Object:
		if is_wide(a) && is_wide(b) {
			return compare_members(sorted_members(a), sorted_members(b), depth, eq)
		}
		ka, kb := sorted_keys(a), sorted_keys(b)
		for i in 0 ..< min(len(ka), len(kb)) {
			if c := text_order(ka[i], kb[i]); c != 0 {
				return c
			}
		}
		if len(ka) != len(kb) {
			return -1 if len(ka) < len(kb) else 1
		}
		for k in ka {
			x, _ := object_get(a, k)
			y, _ := object_get(b, k)
			if c := compare(x, y, depth + 1, eq); c != 0 {
				return c
			}
		}
	}
	return 0
}

// Two strings' byte order. Odin's own orders an empty string with no buffer (a program's `""`) apart
// from an empty one with a buffer (an input's).
text_order :: proc(a, b: string) -> int {
	if len(a) == 0 || len(b) == 0 {
		return int(len(a) > 0) - int(len(b) > 0)
	}
	return strings.compare(a, b)
}

// `compare` of two arrays' members, then of their lengths.
compare_items :: proc(xs, ys: []Value, depth: int, eq: bool) -> int {
	for i in 0 ..< min(len(xs), len(ys)) {
		if c := compare(xs[i], ys[i], depth + 1, eq); c != 0 {
			return c
		}
	}
	return -1 if len(xs) < len(ys) else (1 if len(xs) > len(ys) else 0)
}

equal :: proc(a, b: Value) -> bool {
	return compare(a, b, eq = true) == 0
}

// Whether `a` and `b` are one container or one document node, not two alike.
same :: proc(a, b: Value) -> bool {
	#partial switch x in a {
	case ^Array:
		y, ok := b.(^Array)
		return ok && x == y
	case Path:
		y, ok := b.(Path)
		return ok && x == y
	case ^Object:
		y, ok := b.(^Object)
		return ok && x == y
	case Ref:
		y, ok := b.(Ref)
		return ok && x == y
	case ^Commented:
		y, ok := b.(^Commented)
		return ok && x == y
	}
	return false
}
