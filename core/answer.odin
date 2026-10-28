package core

// A path procedure's answer, shared by every format: a span of the format's source, the container the answer
// is about, the value's kind, and how the path landed.

// What a value is. A container is the two kinds whose `lo`/`hi` bracket children: a CSV record is an `.Array`
// and its cell a `.String`. Declaration order carries no meaning: nothing indexes by it or orders on it.
Kind :: enum u8 {
	Null,
	False,
	True,
	Number,
	String,
	Array,
	Object,
}

// A handle to one value of a format's document. Distinct, so a count or an offset is never passed where a value
// is meant.
Node :: distinct i32

// "No such value": what every lookup answers on a miss, and `Answer.node` where no document holds the value.
NO_NODE :: Node(-1)

Answer_Outcome :: enum u8 {
	Found, // the path resolved (`lo`/`hi` bound the value)
	Missing, // the path does not land
	Type_Mismatch, // a step was applied to the wrong container kind
}

// No container: a root value or a miss owed by the whole document.
NO_OWNER :: max(u64)

// One path query's answer. `lo` and `hi` bound the value's span in the source a read scanned; a miss bounds
// nothing (`lo == hi == 0`). `owner` is the offset of the container the answer is about: the one holding a
// `.Found` value, the one lacking a `.Missing` member, the one holding the value a `.Type_Mismatch` step could
// not read into (`NO_OWNER` when none does). `query` indexes the caller's paths, 0 where a format answers one.
// `node` is the value in the document the read built or was given, else `NO_NODE`. `kind` is a `.Found`
// value's kind.
Answer :: struct {
	lo, hi:  u64,
	owner:   u64,
	query:   u32,
	node:    Node,
	outcome: Answer_Outcome,
	kind:    Kind,
}

#assert(size_of(Answer) == 40)

// The answer of a path that does not land, owed by no container.
MISSING :: Answer{outcome = .Missing, owner = NO_OWNER, node = NO_NODE}

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

// A `per_element` path's answer where step `rest[0]` does not apply, having `missed` its member or element or
// met a `met`: `.Missing`, jq's null, when no `Any` step is still to come and it missed or met null, else
// `.Type_Mismatch`, jq's error.
per_element_outcome :: proc(rest: []Step, missed: bool, met: Kind) -> Answer_Outcome {
	return .Missing if (missed || met == .Null) && !steps_have_any(rest) else .Type_Mismatch
}

// Whether `steps` holds an `Any` step.
steps_have_any :: proc(steps: []Step) -> bool {
	for st in steps {
		if _, is_any := st.(Any); is_any {
			return true
		}
	}
	return false
}
