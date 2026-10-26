package core

// A path procedure's answer, shared by every format: a span of the format's source, the container the answer
// is about, and how the path landed. A format with a tape keeps its own row type beside these fields.

Answer_Outcome :: enum u8 {
	Found, // the path resolved (`lo`/`hi` bound the value)
	Missing, // the path does not land
	Type_Mismatch, // a step was applied to the wrong container kind
}

// No container: a root value or a miss owed by the whole document.
NO_OWNER :: max(u64)

// One path query's answer for a format with no tape. `lo` and `hi` bound the value's span in the source a read
// scanned; a miss bounds nothing (`lo == hi == 0`). `owner` is the container whose span holds the answer
// (`NO_OWNER` when none does); `query` indexes the caller's paths, 0 where a format answers one.
Answer :: struct {
	lo, hi:  u64,
	owner:   u64,
	query:   u32,
	outcome: Answer_Outcome,
}

// The five fields pad to one 32-byte row.
#assert(size_of(Answer) == 32)

// Whether the next answer is past its path's `limit` (0: no limit) and so is dropped, counting it toward that
// limit first. A `Found` counts, and a `per_element` path counts every answer, a miss or mismatch too, as jq's
// `limit` counts the outputs of an `Any` path rather than its matches. `count` is the path's running count of
// counted answers: one per path, in the caller's storage. A counted answer past the limit leaves `count` alone.
answer_cut :: #force_inline proc(limit: int, count: ^int, outcome: Answer_Outcome, per_element: bool) -> bool {
	if limit <= 0 || !(outcome == .Found || per_element) {
		return false
	}
	if count^ >= limit {
		return true
	}
	count^ += 1
	return false
}
