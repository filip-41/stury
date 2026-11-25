package query

// Binary search of a sorted array.

// Where `x` is in sorted array `v` under collation `coll`: its index when an element equals it, else minus one
// minus the index where it would go. The probe is the middle of the half-open range still open, rounded down, so the
// element found among equal ones is the same whatever the caller.
search_sorted :: proc(h: ^Heap, v: Value, x: Value, coll := JSON_ORDER) -> (res: i64, status: Status) {
	if type_of(v) != .Array {
		return 0, fail(h, .Types, .Search, v)
	}
	lo, hi := 0, length_of(h, v)
	for lo < hi {
		mid := (lo + hi) / 2
		e := element(h, v, mid) or_return
		order, s := compare(h, e, x, coll)
		release(h, e)
		if s != .Ok {
			return 0, s
		}
		switch {
		case order == 0:
			return i64(mid), .Ok
		case order < 0:
			lo = mid + 1
		case:
			hi = mid
		}
	}
	return i64(-1 - lo), .Ok
}
