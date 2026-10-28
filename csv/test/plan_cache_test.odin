package csv_tests

import "core:testing"
import core_pkg "../../core"
import csv "../"

Cached_Pair :: struct {
	a: int,
	b: string,
}

Cached_Flag :: struct {
	on:   bool,
	name: string `csv:"label"`,
}

// `core.plan_cache_clear` frees the thread's default plans, and the next call without a plan makes them again, for
// each type the calls use.
@(test)
test_plan_cache_clear_remakes_the_default_plans :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	core_pkg.plan_cache_clear() // nothing cached yet: no harm
	for _ in 0 ..< 3 {
		pairs: []Cached_Pair
		testing.expect(t, csv.unmarshal(transmute([]byte)string("a,b\n1,x\n2,y\n"), &pairs, allocator = context.temp_allocator) == nil)
		testing.expect_value(t, len(pairs), 2)
		testing.expect_value(t, pairs[1], Cached_Pair{2, "y"})

		out, err := csv.marshal([]Cached_Flag{{true, "p"}}, allocator = context.temp_allocator)
		testing.expect_value(t, marshal_kind(err), csv.Marshal_Error_Kind.None)
		testing.expect_value(t, string(out), "on,label\ntrue,p\n")

		core_pkg.plan_cache_clear()
		core_pkg.plan_cache_clear() // an empty cache: no harm
	}
}
