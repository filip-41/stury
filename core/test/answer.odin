package core_tests

import "core:testing"
import p ".."

// The answer row a format's path reader writes: its layout, its fields, and the owner sentinel.
@(test)
test_answer_row :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(p.Answer), 32)
	testing.expect(t, offset_of(p.Answer, lo) == 0)
	testing.expect(t, offset_of(p.Answer, hi) == 8)
	testing.expect(t, offset_of(p.Answer, owner) == 16)
	testing.expect(t, offset_of(p.Answer, query) == 24)
	testing.expect(t, offset_of(p.Answer, outcome) == 28)
	a := p.Answer{lo = 3, hi = 9, owner = 11, query = 2, outcome = .Type_Mismatch}
	testing.expect_value(t, a.lo, u64(3))
	testing.expect_value(t, a.hi, u64(9))
	testing.expect_value(t, a.owner, u64(11))
	testing.expect_value(t, a.query, u32(2))
	testing.expect_value(t, a.outcome, p.Answer_Outcome.Type_Mismatch)
	testing.expect_value(t, p.NO_OWNER, max(u64))
	// The outcomes a reader reports, in the order `Path_Outcome` assigns them.
	testing.expect_value(t, u8(p.Answer_Outcome.Found), u8(0))
	testing.expect_value(t, u8(p.Answer_Outcome.Missing), u8(1))
}

// The cut rule: a plain path counts `Found` answers, a `per_element` path counts every answer, and a limit of 0
// cuts nothing.
@(test)
test_answer_cut :: proc(t: ^testing.T) {
	count := 0
	testing.expect(t, !p.answer_cut(1, &count, .Missing, false))
	testing.expect_value(t, count, 0)
	testing.expect(t, !p.answer_cut(1, &count, .Found, false))
	testing.expect_value(t, count, 1)
	testing.expect(t, p.answer_cut(1, &count, .Found, false))
	testing.expect_value(t, count, 1)

	count = 0
	testing.expect(t, !p.answer_cut(2, &count, .Missing, true))
	testing.expect(t, !p.answer_cut(2, &count, .Type_Mismatch, true))
	testing.expect(t, p.answer_cut(2, &count, .Found, true))
	testing.expect_value(t, count, 2)

	count = 0
	testing.expect(t, !p.answer_cut(0, &count, .Found, false))
	testing.expect_value(t, count, 0)
}
