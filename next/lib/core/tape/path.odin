package tape

// A path is a chain of steps from a value to the values it reaches, and a read follows it through a text or a document.

// A member by its decoded key.
Name :: distinct string

// An element by position, negative from the end.
Index :: distinct int

// Every member or element, or with a `limit` the first `limit` of them in text order. Under `.Last` a member is final
// only at its object's close, so a limit cuts the members of an object under `.First` only. A limit on a whole path's
// answers, as jq's `first(f)` reads, is the path's in `demand_of`.
All :: struct {
	limit: i32, // 0 for no limit
}

// The elements from `lo` up to `hi`, either negative from the end, `hi` nil for every one past `lo`, and with a
// `limit` the first `limit` of them. Its numbers are 32 bits, as a kept child's index is, which keeps a step small.
Slice :: struct {
	lo:    i32,
	hi:    Maybe(i32),
	limit: i32, // 0 for no limit
}

#assert(size_of(Slice) == 16)

Step :: union #no_nil {
	Name,
	Index,
	All,
	Slice,
}

// How much of the value at a path's end a read keeps. A scalar is kept whole under every grain.
Grain :: enum u8 {
	Whole,
	Keys, // an object's members, each container value an unread node, or an array's length
	Kind, // the value's type, which tells its truthiness
	Exists, // only whether the value exists
}

// How a read takes the members of one object that share a key. `.Default` is the format's own, `Format.dups`, which is
// `.Last` for JSON. A path read takes one member under `.Last` and `.First`, and every one in document order under
// `.Group`, as a repeated markup name reads. A build keeps every member under `.All` and `.Group`, one under `.Last`
// and `.First`, and fails at the second key under `.Refuse`. A path read takes `.All` and `.Refuse` as `.Last`.
Duplicates :: enum u8 {
	Default,
	Last,
	First,
	All,
	Refuse,
	Group,
}

// The options of a path read. Under `.Last` an answer through a key is known only at the close of the object holding
// it, so a read that should stop at the first matching key uses `.First`.
Read_Options :: struct {
	dups:       Duplicates,
	stop_early: bool, // once the answer is known the walk ends, and the text past it is not validated
}

// The value a path reached in a text with no document, or why none was reached.
Span_Answer :: struct {
	lo, hi:    u64, // the value's authored span, zero for a `.Missing`
	kind:      Kind,
	outcome:   Presence, // `.Found`, `.Wrong_Kind` for the value a step could not enter, or `.Missing`
	spelling:  u16,
	head:      u8, // the bytes of the authored span before the value's own, as a string's opening quote
	tail:      u8, // the bytes of the authored span after the value's own
	tolerated: bool, // the text the read judged broke a rule its tolerances let it break
}

#assert(size_of(Span_Answer) == 24)

// The node of a scalar answer, which the format's readers take with the text it is in.
answer_node :: proc "contextless" (a: Span_Answer) -> Node {
	return {lo = a.lo + u64(a.head), n = u32(a.hi - a.lo - u64(a.head) - u64(a.tail)), kind = a.kind, role = .Value, spelling = a.spelling}
}
