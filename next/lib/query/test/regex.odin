package query_test

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/query"
import "stury:testkit"

@(test)
a_pattern_compiles_once_per_dialect_and_flags :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	cache: query.Regex_Cache
	defer query.regex_cache_destroy(&cache)
	pattern := query.text_borrowed("a(?<n>b)")
	first, s1 := query.regex_compile(&x.h, &cache, pattern, .Oniguruma, {})
	again, s2 := query.regex_compile(&x.h, &cache, pattern, .Oniguruma, {})
	folded, s3 := query.regex_compile(&x.h, &cache, pattern, .Oniguruma, {fold = true})
	testing.expect(t, s1 == .Ok && s2 == .Ok && s3 == .Ok)
	testing.expect(t, first == again)
	testing.expect(t, first != folded)
	testing.expect_value(t, query.regex_groups(first), 1)
	testing.expect_value(t, query.regex_group_name(first, 1), "n")
}

@(test)
a_search_gives_byte_bounds_per_group :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	cache: query.Regex_Cache
	defer query.regex_cache_destroy(&cache)
	re, status := query.regex_compile(&x.h, &cache, query.text_borrowed("(é)(x)?"), .Oniguruma, {})
	testing.expect(t, status == .Ok)
	found: [6]int
	hit, s := query.regex_search(&x.h, &cache, re, "aé", 0, found[:])
	testing.expect(t, hit && s == .Ok)
	testing.expect_value(t, found, [6]int{1, 3, 1, 3, -1, -1})
	hit, _ = query.regex_search(&x.h, &cache, re, "aé", 3, found[:])
	testing.expect(t, !hit)
}

@(test)
a_pattern_that_does_not_compile_fails_with_the_matchers_words :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	cache: query.Regex_Cache
	defer query.regex_cache_destroy(&cache)
	_, status := query.regex_compile(&x.h, &cache, query.text_borrowed("("), .Oniguruma, {})
	testing.expect(t, status == .Error)
	e := query.take_error(&x.h)
	testing.expect_value(t, e.kind, query.Error_Kind.Pattern)
	testing.expect_value(t, e.detail, "end pattern with unmatched parenthesis")
	query.destroy_error(&x.h, &e)
}

@(test)
compiled_patterns_count_against_the_memory_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	cache: query.Regex_Cache
	defer query.regex_cache_destroy(&cache)
	_, status := query.regex_compile(&x.h, &cache, query.text_borrowed("(a|b)+c"), .Oniguruma, {})
	testing.expect(t, status == .Ok)
	testing.expect(t, x.h.used > 0)
	query.regex_cache_destroy(&cache)
	testing.expect_value(t, x.h.used, 0)
	x.h.limit = 1 << 10
	_, status = query.regex_compile(&x.h, &cache, query.text_borrowed("(a|b)+c"), .Oniguruma, {})
	testing.expect(t, status == .Error)
	testing.expect_value(t, x.h.err.kind, query.Error_Kind.Memory)
	query.clear_error(&x.h)
}

@(test)
a_code_walk_turns_bytes_into_code_points_and_back :: proc(t: ^testing.T) {
	testkit.deadline(t)
	s := "aé€b"
	w: query.Code_Walk
	testing.expect_value(t, query.code_points_before(&w, s, 3), 2)
	testing.expect_value(t, query.code_points_before(&w, s, 6), 3)
	testing.expect_value(t, query.code_points_before(&w, s, 1), 1)
	testing.expect_value(t, query.code_point_start(&w, s, 2), 3)
	testing.expect_value(t, query.code_point_start(&w, s, 9), len(s))
}

@(test)
regex_search_respects_step_budget :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	cache: query.Regex_Cache
	defer query.regex_cache_destroy(&cache)
	re, status := query.regex_compile(&x.h, &cache, query.text_borrowed(`^(a|a)*\1$`), .Oniguruma, {})
	testing.expect(t, status == .Ok)
	found: [4]int
	hit, s := query.regex_search(&x.h, &cache, re, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab", 0, found[:], steps = 100)
	testing.expect(t, !hit && s == .Error)
	e := query.take_error(&x.h)
	testing.expect_value(t, e.kind, query.Error_Kind.Budget)
	testing.expect_value(t, e.budget, tape.Budget_Kind.Steps)
	query.destroy_error(&x.h, &e)
}
