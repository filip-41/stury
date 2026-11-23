package regex_tests

import "core:math/rand"
import "core:strings"
import "core:testing"
import "stury:testkit"

// A search over text that is not valid UTF-8 gives the same answer with or without caps, with or without the automata,
// and the same span from the backtracker and from the automaton that finds spans.
@(test)
test_invalid_utf8_gives_one_answer_by_every_path :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 7)
	patterns := [?]string {
		`[xy]`,
		`x`,
		`xy`,
		`[a-c]+d`,
		`é|a`,
		`[^a]b`,
		`\d+`,
		`(?<=a)b`,
		`a|b`,
		`\p{L}`,
		`x*y`,
		`[xyé]z`,
		`(a|x)(y|b)`,
		`[\x80-\xff]a`,
		`.x`,
		`\Ax`,
		`y$`,
		`\bx`,
	}
	pieces := [?]string{
		"a",
		"b",
		"x",
		"y",
		"d",
		"z",
		"1",
		"é",
		"😀",
		"\xE2",
		"\xE2\x82",
		"\xF0\x9F",
		"\x80",
		"\xff",
		"\xC3",
	}
	for pattern in patterns {
		for mode in ([?]Mode{{}, {ecma = true}}) {
			for _ in 0 ..< testkit.rounds(300) {
				b := strings.builder_make(context.temp_allocator)
				for _ in 0 ..< rand.int_max(24) {
					strings.write_string(&b, pieces[rand.int_max(len(pieces))])
				}
				text := strings.to_string(b)
				// A long clean stretch makes the kernel's scan the one that looks.
				if rand.int_max(3) == 0 {
					text = strings.concatenate(
						{strings.repeat("a", 130, context.temp_allocator), text},
						context.temp_allocator,
					)
				}
				plain := search(pattern, text, false, mode, true)
				bounds := search(pattern, text, false, mode)
				automaton := search(pattern, text, true, mode, true)
				spans := search(pattern, text, true, mode)
				if plain.err != "" || bounds.err != "" || automaton.err != "" || spans.err != "" {
					continue
				}
				found := bounds.lo >= 0
				testing.expectf(
					t,
					(plain.lo >= 0) == found,
					"%q %v on %q: whether %v, bounds %v",
					pattern,
					mode,
					text,
					plain.lo >= 0,
					found,
				)
				testing.expectf(
					t,
					(automaton.lo >= 0) == found,
					"%q %v on %q: automaton %v, backtracker %v",
					pattern,
					mode,
					text,
					automaton.lo >= 0,
					found,
				)
				testing.expectf(
					t,
					spans.lo == bounds.lo && spans.hi == bounds.hi,
					"%q %v on %q: spans %d..%d, backtracker %d..%d",
					pattern,
					mode,
					text,
					spans.lo,
					spans.hi,
					bounds.lo,
					bounds.hi,
				)
			}
		}
	}
}
