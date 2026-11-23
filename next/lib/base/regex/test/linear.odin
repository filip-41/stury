package regex_tests

import "core:math/rand"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

@(test)
test_ecma_search_is_linear :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Without the visited set each of these resumes exponentially or quadratically many alternatives. With it, on four
	// times the text the search resumes under six times as many.
	Case :: struct {
		pattern, tail: string,
		flags:         Mode,
	}
	cases := [?]Case {
		{`(a*)*b`, "c", {ecma = true}},
		{`(a|a)*b`, "c", {ecma = true}},
		{`^(a+)+$`, "!", {ecma = true}},
		{`(a|aa)+$`, "!", {ecma = true}},
		{`a*a*a*a*a*b`, "", {ecma = true}},
		{`(?=(a|aa)*b)c`, "c", {ecma = true}}, // a look-ahead is tried at every start
		{`(?=a*b)c`, "c", {ecma = true}},
		{`(?!(a|aa)*c)b`, "b", {ecma = true}},
		{`^(a|a)*b`, "xb", {}}, // a jq program of choices in a loop
		{`(a|aa)+$`, "!", {}},
	}
	for c in cases {
		small := search(
			c.pattern,
			strings.concatenate({strings.repeat("a", 2_000, context.temp_allocator), c.tail}, context.temp_allocator),
			flags = c.flags,
		)
		large := search(
			c.pattern,
			strings.concatenate({strings.repeat("a", 8_000, context.temp_allocator), c.tail}, context.temp_allocator),
			flags = c.flags,
		)
		testing.expectf(t, small.err == "" && large.err == "", "%q: %s %s", c.pattern, small.err, large.err)
		testing.expectf(
			t,
			large.spent < 6 * max(small.spent, 100),
			"%q: %d resumed on 2000 letters, %d on 8000",
			c.pattern,
			small.spent,
			large.spent,
		)
	}
}

@(test)
test_ecma_search_is_capped_by_memory :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.repeat("x", 1 << 20, context.temp_allocator)
	testing.expect_value(t, search(`(?:a|b){1000}`, text).err, "fail to memory allocation")
}

// With and without the visited set the search finds the same match and groups, on texts over `a`, `b` and `c` of up
// to ten letters.
@(test)
test_ecma_visited_set_keeps_the_matches :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 1)
	for _ in 0 ..< 8000 {
		b := strings.builder_make(context.temp_allocator)
		generate(&b, 2)
		text := make([]byte, rand.int_max(11), context.temp_allocator)
		letters := "aaabbc"
		for &c in text {
			c = letters[rand.int_max(6)]
		}
		pattern := strings.to_string(b)
		with, without := search(pattern, string(text)), search(pattern, string(text), linear = false)
		with.spent, with.automaton, without.spent = 0, false, 0
		testing.expectf(
			t,
			with == without,
			"%q on %q: %v with the set, %v without",
			pattern,
			string(text),
			with,
			without,
		)
	}
}

// A search from past the end of the text finds nothing, with the automaton and without it.
@(test)
test_ecma_search_from_past_the_end :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	allocator := growing(&arena)
	scratch := scratch_of(context.allocator)
	defer regex.scratch_destroy(&scratch)
	for pattern in ([?]string{`a*`, `$`, `(?=a)|`}) {
		re, err := compile(pattern, {ecma = true}, allocator, context.allocator)
		testing.expect(t, err == "")
		for start in ([?]int{3, 5}) {
			found, search_err := regex.search(&re, "ab", start, nil, &scratch)
			testing.expectf(
				t,
				!found && search_err == {},
				"%q from %d on \"ab\": %v %s",
				pattern,
				start,
				found,
				search_err.message,
			)
		}
	}
}
