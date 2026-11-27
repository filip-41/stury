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

// The error and the steps taken of a search of `text` for `pattern` that is allowed `steps`.
steps_of :: proc(pattern, text: string, flags: Mode, steps: int, whether := false) -> (err: regex.Error, spent: int) {
	arena: virtual.Arena
	allocator := growing(&arena)
	re, compile_err := compile(pattern, flags, allocator, context.allocator)
	ensure(compile_err == "")
	scratch := scratch_of(context.allocator)
	defer regex.scratch_destroy(&scratch)
	caps: [2]int
	_, err = regex.search(&re, text, 0, caps[:0 if whether else 2], &scratch, u64(steps))
	return err, int(scratch.spent)
}

// A search takes the caller's steps as its limit, in place of the engine's own, and says which kind it ran out of.
@(test)
test_regex_search_stops_at_the_callers_steps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.concatenate({strings.repeat("a", 40, context.temp_allocator), "b"}, context.temp_allocator)
	// A back reference keeps the search off the visited set, so it backtracks exponentially.
	for flags in ([?]Mode{{ecma = true}, {}}) {
		engine, _ := steps_of(`^(a|a)*\1$`, text, flags, 0)
		testing.expect_value(t, engine, regex.Error{.Steps, "retry-limit-in-match over"})
		small, spent := steps_of(`^(a|a)*\1$`, text, flags, 1000)
		testing.expect_value(t, small.kind, regex.Error_Kind.Steps)
		testing.expectf(t, spent <= 1001, "%d steps spent of 1000", spent)
		short, _ := steps_of(`^(a|a)*\1$`, text[:12], flags, 100_000)
		testing.expect_value(t, short, regex.Error{})
	}
	// The budget counts the work of all starts together, where the engine's limit counts it at one start.
	letters := strings.repeat("a", 200, context.temp_allocator)
	many, spent := steps_of(`(a)\1(?:b|c)`, letters, {}, 150)
	testing.expectf(t, many.kind == .Steps && spent <= 151, "%v after %d", many, spent)
	whole, total := steps_of(`(a)\1(?:b|c)`, letters, {}, 0)
	testing.expectf(t, whole == {} && total > 150, "%v after %d", whole, total)
	// A branch the linear search pops back to is a step, so a budget of one stops it on a pattern whose every start
	// falls back through its alternatives.
	alternatives := strings.repeat("abcd", 50, context.temp_allocator)
	for flags in ([?]Mode{{ecma = true}, {}}) {
		popped, popped_steps := steps_of(`(a|ab)(c|bcd)(d*)z`, alternatives, flags, 1)
		testing.expectf(t, popped.kind == .Steps && popped_steps <= 2, "%v after %d", popped, popped_steps)
		undone, _ := steps_of(`(a|ab)(c|bcd)(d*)z`, alternatives, flags, 0)
		testing.expect_value(t, undone, regex.Error{})
	}
	// The automaton's set words are steps too, so a counted search that the engine decides can run out.
	counted := strings.concatenate({strings.repeat("a", 3_000, context.temp_allocator), "cbx"}, context.temp_allocator)
	decided, _ := steps_of(`((a{1,100}){1,100}){1,100}b`, counted, {ecma = true}, 0, whether = true)
	testing.expect_value(t, decided, regex.Error{})
	refused, spent_words := steps_of(`((a{1,100}){1,100}){1,100}b`, counted, {ecma = true}, 1000, whether = true)
	testing.expect_value(t, refused.kind, regex.Error_Kind.Steps)
	testing.expect(t, spent_words > 1000)
}

// `.Rep` and `.Linebreak` charge the caller's step budget even when the backtrack stack stays empty.
@(test)
test_empty_stack_rep_and_linebreak_respect_steps :: proc(t: ^testing.T) {
	testkit.deadline(t)
	text := strings.repeat("b", 1000, context.temp_allocator)
	for pattern in ([?]string{`ba{0,2}c`, `b\Rc`}) {
		err, spent := steps_of(pattern, text, {}, 5)
		testing.expect_value(t, err.kind, regex.Error_Kind.Steps)
		testing.expectf(t, spent <= 6, "%q spent %d of 5", pattern, spent)
	}
}
