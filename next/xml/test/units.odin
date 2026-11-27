#+test
// The framing of a text in pieces against the byte machine, through a proc only a test build holds.
package xml_tests

import "core:math/rand"
import "core:testing"
import "stury:testkit"
import "stury:xml"

// The framing of a text in pieces in blocks of 64 bytes gives the units the byte machine gives, over random texts of
// markup bytes cut anywhere: dense and sparse, with and without the quotes and openers a block leaves to the machine.
@(test)
units_frame_in_blocks_as_byte_by_byte :: proc(t: ^testing.T) {
	testkit.deadline(t)
	state: rand.Default_Random_State
	context.random_generator = testkit.seeded(t, &state, 0x0a3)
	alphabet := [?]u8{'<', '>', '/', '!', '?', '"', '\'', 'a', ' ', '-', '[', ']', '=', 'x', '<', '>', 'a', 'a', 'a', 'a'}
	buf: [1200]u8
	for round in 0 ..< testkit.rounds(40_000) {
		n := rand.int_max(len(buf) - 1) + 1
		density := rand.int_max(len(alphabet)) + 1
		for i in 0 ..< n {
			buf[i] = alphabet[rand.int_max(density if round % 3 == 0 else len(alphabet))]
			if round % 5 < 3 && (buf[i] == '!' || buf[i] == '?' || buf[i] == '"' || buf[i] == '\'') {
				buf[i] = 'a' if rand.int_max(4) != 0 else '/'
			}
		}
		if round % 7 == 0 {
			for i := 0; i + 8 < n; i += 8 + rand.int_max(40) {
				copy(buf[i:n], "<a>text</a>")
			}
		}
		cut := rand.int_max(n + 1)
		if !testing.expectf(t, xml.units_agree(buf[:n], cut), "round %d cut %d: %q", round, cut, string(buf[:n])) {
			return
		}
	}
}
