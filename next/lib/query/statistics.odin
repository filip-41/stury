package query

import "core:math"

// Statistics over arrays of numbers, which every language's aggregates reach: the sum, the mean, the population
// variance and deviation, quantiles, and how often each value occurs. Integers stay exact wherever the answer is one.

// The elements of array `v`, built, each a number: another value is a `.Types` error of `.Aggregate` naming it.
@(require_results)
numbers_in :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	if type_of(v) != .Array {
		return NULL, fail(h, .Types, .Iterate, v)
	}
	xs := built(h, v) or_return
	for x in items_of(xs) {
		if !is_number(x) {
			release(h, xs)
			return NULL, fail(h, .Types, .Aggregate, x)
		}
	}
	return xs, .Ok
}

// The sum of the numbers of array `v`; null for none.
@(require_results)
sum :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	xs := numbers_in(h, v) or_return
	defer release(h, xs)
	return sum_of(h, items_of(xs))
}

// The mean of the numbers of array `v`, an integer when it is one; null for none.
@(require_results)
mean :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	xs := numbers_in(h, v) or_return
	defer release(h, xs)
	return mean_of(h, items_of(xs))
}

// The population variance of the numbers of array `v`, over their count; null for none.
@(require_results)
variance :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	xs := numbers_in(h, v) or_return
	defer release(h, xs)
	items := items_of(xs)
	if len(items) == 0 {
		return NULL, .Ok
	}
	m := mean_of(h, items) or_return
	defer release(h, m)
	acc := int_value(0)
	for x in items {
		d := num_sub(h, x, m) or_return
		sq, s := num_mul(h, d, d)
		release(h, d)
		if s == .Ok {
			next: Value
			next, s = num_add(h, acc, sq)
			release(h, sq)
			release(h, acc)
			acc = next
		}
		if s != .Ok {
			release(h, acc)
			return NULL, s
		}
	}
	defer release(h, acc)
	return num_div(h, acc, int_value(i64(len(items))))
}

// The population standard deviation of the numbers of array `v`, a double; null for none.
@(require_results)
deviation :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	r := variance(h, v) or_return
	if r.kind == .Null {
		return r, .Ok
	}
	defer release(h, r)
	return double_value(math.sqrt(as_f64(r))), .Ok
}

// The value at `p`, from 0 to 1, of the numbers of array `v` in order, interpolated linearly between neighbours
// (Hyndman and Fan's type 7); null for none. Another `p` is a `.Range` error of `.Aggregate`.
@(require_results)
quantile :: proc(h: ^Heap, v: Value, p: Value) -> (res: Value, status: Status) {
	if !is_number(p) || !(as_f64(p) >= 0 && as_f64(p) <= 1) {
		return NULL, fail(h, .Range, .Aggregate, p, detail = "quantile")
	}
	xs := numbers_in(h, v) or_return
	defer release(h, xs)
	n := len(items_of(xs))
	if n == 0 {
		return NULL, .Ok
	}
	sorted := sort_by(h, xs) or_return
	defer release(h, sorted)
	items := items_of(sorted)
	at := f64(n - 1) * as_f64(p)
	lo, hi := int(math.floor(at)), int(math.ceil(at))
	if lo == hi {
		return number_of(h, items[lo])
	}
	gap := num_sub(h, items[hi], items[lo]) or_return
	part, s := num_mul(h, gap, double_value(at - f64(lo)))
	release(h, gap)
	if s != .Ok {
		return NULL, s
	}
	defer release(h, part)
	return num_add(h, items[lo], part)
}

// The median of the numbers of array `v`: its quantile at one half.
@(require_results)
median :: proc(h: ^Heap, v: Value) -> (res: Value, status: Status) {
	return quantile(h, v, double_value(0.5))
}

// `[{value, count}]` of the elements of array `v`: each distinct one by `coll` and how often it occurs, the largest
// count first, equal counts in the order of their values.
@(require_results)
frequency :: proc(h: ^Heap, v: Value, coll := JSON_ORDER) -> (res: Value, status: Status) {
	runs := runs_by(h, v, ABSENT, .Group, coll) or_return
	defer release(h, runs)
	groups := items_of(runs)
	out := make_array(h, len(groups)) or_return
	counts := make([]Value, len(groups), h.allocator)
	defer delete(counts, h.allocator)
	for g, i in groups {
		counts[i] = int_value(i64(length_of(h, g)))
		row, s := make_object(h, 2)
		if s == .Ok {
			s = object_put(h, &row, text_borrowed("value"), retain(items_of(g)[0]))
		}
		if s == .Ok {
			s = object_put(h, &row, text_borrowed("count"), counts[i])
		}
		if s == .Ok {
			s = append_owned(h, &out, row)
		}
		if s != .Ok {
			release(h, out)
			return NULL, s
		}
	}
	if s := sort_values(h, items_of(out), counts, coll, descending = true); s != .Ok {
		release(h, out)
		return NULL, s
	}
	return out, .Ok
}

@(private)
sum_of :: proc(h: ^Heap, xs: []Value) -> (res: Value, status: Status) {
	if len(xs) == 0 {
		return NULL, .Ok
	}
	acc := number_of(h, xs[0]) or_return
	for x in xs[1:] {
		next, s := num_add(h, acc, x)
		release(h, acc)
		if s != .Ok {
			return NULL, s
		}
		acc = next
	}
	return acc, .Ok
}

@(private)
mean_of :: proc(h: ^Heap, xs: []Value) -> (res: Value, status: Status) {
	if len(xs) == 0 {
		return NULL, .Ok
	}
	total := sum_of(h, xs) or_return
	defer release(h, total)
	return num_div(h, total, int_value(i64(len(xs))))
}
