package regex_tests

import "core:strings"
import "core:testing"
import "stury:testkit"

Way :: struct {
	linear, whether: bool,
}

// Over invalid UTF-8 a search steps over the bytes a lead byte claims, so a candidate inside them is not a start, at
// any distance from the search's start, whether the backtracker or the automaton answers. A search that reads bounds
// goes to the automaton only with the visited set off.
@(test)
test_head_skip_steps_over_the_bytes_a_lead_byte_claims :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for gap in ([?]int{0, 1, 5, 7, 8, 9, 40, 200}) {
		filler := strings.repeat("a", gap, context.temp_allocator)
		claimed := strings.concatenate({filler, "\xE2xy"}, context.temp_allocator)
		then := strings.concatenate({claimed, "x"}, context.temp_allocator)
		clean := strings.concatenate({filler, "x"}, context.temp_allocator)
		for way in ([?]Way{{false, false}, {false, true}, {true, true}}) {
			// A search that reads no bounds gives 0 for a match.
			at_then, at_clean := 0 if way.whether else gap + 3, 0 if way.whether else gap
			found := search(`[xy]`, claimed, way.linear, Mode{}, way.whether)
			testing.expectf(t, found.err == "" && found.lo == -1, "gap %d, %v: %d, not none", gap, way, found.lo)
			found = search(`[xy]`, then, way.linear, Mode{}, way.whether)
			testing.expectf(
				t,
				found.err == "" && found.lo == at_then,
				"gap %d, %v: %d, not %d",
				gap,
				way,
				found.lo,
				at_then,
			)
			found = search(`[xy]`, clean, way.linear, Mode{}, way.whether)
			testing.expectf(
				t,
				found.err == "" && found.lo == at_clean,
				"gap %d, %v: %d, not %d",
				gap,
				way,
				found.lo,
				at_clean,
			)
		}
	}
}
