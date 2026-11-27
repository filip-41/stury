package regex_tests

import "core:math/rand"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

@(test)
test_ecma_counted_search_is_bounded :: proc(t: ^testing.T) {
	testkit.deadline(t)
	// Nested counted repeats multiply the pairs a search visits. A search that reads groups, or one under a look-ahead,
	// gives up with the memory error within a bound linear in the program and the text. Each search uses its whole work
	// budget, so few patterns are run: the lazy and wider spellings of the first reach the same budget in the same
	// code.
	letters := strings.repeat("a", 3_000, context.temp_allocator)
	text := strings.concatenate({letters, "cbx"}, context.temp_allocator)
	for pattern in ([?]string{`((a{1,100}){1,100}){1,100}b`, `(?=(?:a{1,200}){1,200})x`}) {
		for whether in ([?]bool{false, true}) {
			if whether && pattern[1] != '?' {
				continue
			}
			f := search(pattern, text, whether = whether)
			testing.expectf(
				t,
				(f.kind == .Steps && f.err == "search work limit over" ||
					f.kind == .Memory && f.err == "fail to memory allocation") &&
				f.spent <= 1 << 26,
				"%q: %q after %d",
				pattern,
				f.err,
				f.spent,
			)
		}
	}
	testing.expect_value(
		t,
		search(`^(a{1,1000}){1,1000}b`, strings.concatenate({letters[:500], "b"}, context.temp_allocator)).hi,
		501,
	)
}

// A search that reads no bounds decides the counted repeats that the backtracker's budget or memory leaves undecided.
@(test)
test_ecma_counted_whether_is_decided :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, piece: string,
		times:          int,
		tail:           string,
		found:          bool,
	}
	cases := [?]Case {
		{`((a{1,100}){1,100}){1,100}b`, "a", 3_000, "cbx", false},
		{`((a{1,100}){1,100}){1,100}b`, "a", 3_000, "b", true},
		{`(?:a|b){1000}`, "x", 1 << 20, "", false},
		{`(?:a|b){1000}`, "ab", 1 << 19, "", true},
	}
	for c in cases {
		text := strings.concatenate(
			{strings.repeat(c.piece, c.times, context.temp_allocator), c.tail},
			context.temp_allocator,
		)
		f := search(c.pattern, text, whether = true)
		testing.expectf(
			t,
			f.err == "" && (f.hi >= 0) == c.found,
			"%q on %d of %q: %q, %v",
			c.pattern,
			c.times,
			c.piece,
			f.err,
			f.hi >= 0,
		)
	}
}

// A counted repeat too long to write out runs as a counter loop, and finds the match and groups that the same repeat
// written out finds. A body grows past the bound with alternatives of characters that no text holds, which change no
// match, and a repeat around a counter loop grows the same way. The counter loop's search gives the same answers
// without the visited set.
@(test)
test_ecma_counter_loops_keep_the_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	fill := strings.builder_make(context.temp_allocator)
	for k in 0 ..< 700 {
		strings.write_string(&fill, "|")
		strings.write_rune(&fill, 0xE000 + rune(k))
	}
	counts := [?]string{"{4}", "{1,4}", "{0,4}", "{0,4}?", "{4,}", "{4,}?", "{4}?", "{2,5}", "{3,6}?"}
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 2)
	for i in 0 ..< 2000 {
		g := strings.builder_make(context.temp_allocator)
		if i % 2 == 0 {
			generate_plain(&g, 2)
		} else {
			generate(&g, 1)
		}
		inner, outer := counts[rand.int_max(len(counts))], counts[rand.int_max(len(counts))]
		written, looped: string
		if i % 3 == 0 {
			written = strings.concatenate(
				{"(?:(?:", strings.to_string(g), ")", inner, ")", outer},
				context.temp_allocator,
			)
			looped = strings.concatenate(
				{
					"(?:(?:",
					strings.to_string(g),
					strings.to_string(fill),
					")",
					inner,
					strings.to_string(fill),
					")",
					outer,
				},
				context.temp_allocator,
			)
		} else {
			written = strings.concatenate({"(?:", strings.to_string(g), ")", inner}, context.temp_allocator)
			looped = strings.concatenate(
				{"(?:", strings.to_string(g), strings.to_string(fill), ")", inner},
				context.temp_allocator,
			)
		}
		text := make([]byte, rand.int_max(11), context.temp_allocator)
		letters := "aaabbc"
		for &c in text {
			c = letters[rand.int_max(6)]
		}
		want, got := search(written, string(text)), search(looped, string(text))
		want.spent, want.automaton, got.spent = 0, false, 0
		testing.expectf(
			t,
			got == want,
			"%q%s on %q: %v as a counter loop, %v written out",
			strings.to_string(g),
			inner,
			string(text),
			got,
			want,
		)
		if i % 4 == 0 {
			plain := search(looped, string(text), linear = false)
			plain.spent = 0
			testing.expectf(
				t,
				plain.err != "" || plain == got,
				"%q%s on %q: %v without the visited set, %v with it",
				strings.to_string(g),
				inner,
				string(text),
				plain,
				got,
			)
		}
	}
}

// Nested counted repeats compile to a program the size of their bodies, a count too large for the text to hold
// (`{0,2000000000}`) compiles within 4 MiB, and a search whose visited set would pass the memory bound is refused
// before it allocates the set.
@(test)
test_ecma_nested_counts_are_bounded :: proc(t: ^testing.T) {
	testkit.deadline(t)
	Case :: struct {
		pattern, text: string,
		found:         bool,
		refused:       bool,
	}
	text := strings.concatenate({strings.repeat("ab", 2_000, context.temp_allocator), "c"}, context.temp_allocator)
	cases := [?]Case {
		{`^(?:(?:ab){1,100}){1,100}d`, text, false, false},
		{`(?:(?:ab){1,100}){1,100}c`, text, true, false},
		{`((((a|b){1,100}){1,100}){1,100}){1,100}c`, text, false, true},
		{`((((a|b){1,100}){1,100}){1,100}){1,100}c`, "abc", true, false},
		{`(?:ab){0,2000000000}c`, text, true, false},
		{`((?:ab){0,2000000000}){0,2000000000}c`, "ababc", true, false},
		{`^(?:(?:ab){2000,})c`, text, true, false},
		{`^(?:(?:ab){2001,})c`, text, false, false},
	}
	for c in cases {
		program: mem.Tracking_Allocator
		arena: virtual.Arena
		mem.tracking_allocator_init(&program, growing(&arena))
		defer mem.tracking_allocator_destroy(&program)
		re, err := compile(c.pattern, {ecma = true}, mem.tracking_allocator(&program), context.allocator)
		testing.expectf(
			t,
			err == "" && program.peak_memory_allocated < 4 << 20,
			"%q: %s, %d bytes",
			c.pattern,
			err,
			program.peak_memory_allocated,
		)
		scratch := scratch_of(context.allocator)
		defer regex.scratch_destroy(&scratch)
		caps: [2]int
		found, search_err := regex.search(&re, c.text, 0, caps[:], &scratch)
		if c.refused {
			testing.expectf(
				t,
				search_err.message == "fail to memory allocation" && cap(scratch.held.seen) == 0,
				"%q: %v %q",
				c.pattern,
				found,
				search_err,
			)
		} else {
			testing.expectf(t, search_err == {} && found == c.found, "%q: %v %q", c.pattern, found, search_err)
		}
	}
}
