package regex_tests

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

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
