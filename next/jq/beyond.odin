package jq

import "stury:lib/query"

// stury's builtins beyond jq 1.8.2, each a name bound to an engine operation. Their forms with a filter argument are
// in `PRELUDE`.

// avg, variance, stddev, median, quantile, frequency.
@(private)
v_statistic :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	switch b.name {
	case "avg":
		return query.mean(m.h, x)
	case "variance":
		return query.variance(m.h, x)
	case "stddev":
		return query.deviation(m.h, x)
	case "median":
		return query.median(m.h, x)
	case "quantile":
		return query.quantile(m.h, x, args[0])
	}
	return query.frequency(m.h, x)
}

// union, intersect, except.
@(private)
v_set :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	op := query.Set_Op.Union
	switch b.name {
	case "intersect":
		op = .Intersect
	case "except":
		op = .Except
	}
	return query.set_of(m.h, x, args[0], op)
}

// fill_forward, melt, pivot.
@(private)
v_reshape :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	switch b.name {
	case "fill_forward":
		return query.fill_forward(m.h, x)
	case "pivot":
		return query.pivot(m.h, x, args[0], args[1], args[2])
	}
	if len(args) == 1 {
		return query.melt(m.h, x, args[0], query.text_borrowed("variable"), query.text_borrowed("value"))
	}
	return query.melt(m.h, x, args[0], args[1], args[2])
}
