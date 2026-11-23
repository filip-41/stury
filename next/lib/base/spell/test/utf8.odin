package spell_tests

import "core:testing"
import "stury:lib/base/spell"
import "stury:testkit"

// The widths a lead byte gives, and the walks back to a character's first byte and forward past its continuations.
@(test)
test_utf8_walks :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for b in 0 ..< 256 {
		want := 1
		switch {
		case b >= 0xF0 && b < 0xF8:
			want = 4
		case b >= 0xE0 && b < 0xF0:
			want = 3
		case b >= 0xC0 && b < 0xE0:
			want = 2
		}
		testing.expect_value(t, spell.lead_width(u8(b)), want)
		testing.expect_value(t, spell.is_continuation(u8(b)), b >= 0x80 && b < 0xC0)
	}
	s := "a€😀b" // 1, 3, 4, 1 bytes
	for i in 0 ..< len(s) {
		first := i
		for first > 0 && !(s[first] < 0x80 || s[first] >= 0xC0) {
			first -= 1
		}
		testing.expect_value(t, spell.char_start(s, i), first)
		past := i
		for past < len(s) && s[past] >= 0x80 && s[past] < 0xC0 {
			past += 1
		}
		testing.expect_value(t, spell.skip_continuations(s, i), past)
	}
	testing.expect_value(t, spell.skip_continuations(s, len(s)), len(s))
}
