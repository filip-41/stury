package tape

// A path is a chain of steps from a value to the values it reaches, and a read follows it through a text or a document.

// A member by its decoded key.
Name :: distinct string

// An element by position, negative from the end.
Index :: distinct int

// Every member or element.
All :: struct {}

Step :: union #no_nil {
	Name,
	Index,
	All,
}

// Which member a path read takes of the members of one object that share a key. `Default` is the format's own, `Last`
// for JSON. A path read takes one member, so keeping every member or refusing a repeat is a build's policy.
Duplicates :: enum u8 {
	Default,
	Last,
	First,
}

// The options of a path read. Under `.Last` an answer through a key is known only at the close of the object holding
// it, so a read that should stop at the first matching key asks for `.First`.
Read_Options :: struct {
	dups:       Duplicates,
	stop_early: bool, // once the answer is known the walk ends, and the text past it is not judged
}

// The value a path reached in a text with no document, or why none was reached.
Span_Answer :: struct {
	lo, hi:   u64, // the value's authored span, zero for a `.Missing`
	kind:     Kind,
	outcome:  Presence, // `.Found`, `.Wrong_Kind` for the value a step could not enter, or `.Missing`
	spelling: u16,
	head:     u8, // the bytes of the authored span before the value's own, as a string's opening quote
	tail:     u8, // the bytes of the authored span after the value's own
}

#assert(size_of(Span_Answer) == 24)

// The node of a scalar answer, which the format's readers take with the text it is in.
answer_node :: proc "contextless" (a: Span_Answer) -> Node {
	return {lo = a.lo + u64(a.head), n = u32(a.hi - a.lo - u64(a.head) - u64(a.tail)), kind = a.kind, role = .Value, spelling = a.spelling}
}
