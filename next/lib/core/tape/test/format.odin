package tape_test

import "core:testing"
import "stury:lib/core/tape"

// The caps emit exactly the carried facts.
@(test)
caps_carry_every_carried_fact :: proc(t: ^testing.T) {
	emitted: tape.Facts
	for facts in tape.CAP_FACTS {
		emitted += facts
	}
	testing.expect_value(t, emitted, tape.CARRIED)
}
