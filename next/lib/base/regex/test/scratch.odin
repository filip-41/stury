package regex_tests

import "core:mem/virtual"
import "core:testing"
import regex "stury:lib/base/regex"
import "stury:testkit"

// A search takes no caps, the match's own two, or two for every group, and a Scratch from `scratch_make`, which one
// search may use after another. A zero Scratch and caps of another length are refused with an `ensure`, which names
// `scratch_make` and the groups.
@(test)
test_search_takes_the_caps_it_documents :: proc(t: ^testing.T) {
	testkit.deadline(t)
	arena: virtual.Arena
	allocator := growing(&arena)
	re, message := compile(`(a)(?<n>b)?c`, {ecma = true}, allocator, allocator, spans = true)
	testing.expect_value(t, message, "")
	scratch := scratch_of(allocator)
	defer regex.scratch_destroy(&scratch)
	for _ in 0 ..< 2 {
		found, err := regex.search(&re, "xabc", 0, nil, &scratch)
		testing.expect_value(t, err, regex.Error{})
		testing.expect(t, found)
		own: [2]int
		found, err = regex.search(&re, "xabc", 0, own[:], &scratch)
		testing.expect(t, found && err == {})
		testing.expect_value(t, own, [2]int{1, 4})
		every: [6]int
		found, err = regex.search(&re, "xabc", 0, every[:], &scratch)
		testing.expect(t, found && err == {})
		testing.expect_value(t, every, [6]int{1, 4, 1, 2, 2, 3})
	}
}
