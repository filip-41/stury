package tape

// A token is one piece of a text as a format's walk reads it: a value, a key, a fact or the end of a container. Walks
// hand tokens to hooks in text order, and a document stores them as its nodes.

// The type of a token.
Kind :: enum u8 {
	Null,
	False,
	True,
	Number,
	Bytes,
	String,
	Plain,
	Array, // in dsv also the document, and a record with no header
	Object, // in dsv also a record with a header
	End, // closes the innermost container; never stored in a document
}

// A token's place in its container. Group facts with other roles.
Role :: enum u8 {
	Value,
	Key,
	Comment, // before the value that follows it
	Comment_Inline, // on the line where the value before it ends
	Comment_Foot, // after the last value or in an empty container, on that container
	Tag,
	Anchor,
	Alias,
	Instruction,
	Doctype,
	Directive,
	Attribute,
	Partial, // a container a path read kept only part of; no walk emits it
}

// A token from a walk, also stored as a document node.
Token :: struct {
	lo:       u64,
	// Byte length. In a document a container's is its subtree's node count instead, so its next sibling is `i + n`.
	n:        u32,
	kind:     Kind,
	role:     Role,
	// The format's detail. In a document a container's is its child count instead, saturated at `MAX_CHILDREN`.
	spelling: u16,
}

Node :: Token

// An index into `Document.nodes`. A build refuses a text whose node count would reach `NO_NODE`.
Node_Index :: distinct u32

ROOT :: Node_Index(0)
NO_NODE :: Node_Index(max(u32))

MAX_CHILDREN :: u16(0xFFFF)

// A container's true child count, where `spelling` saturated.
Child_Count :: struct {
	node:  Node_Index,
	count: u32,
}

SPELLING_DECODE :: u16(1)
SPELLING_QUOTED :: u16(2)
SPELLING_LAX :: u16(4)

NUMBER_EXP :: u16(1 << 14) // in a number's spelling, the number has an exponent

// The spelling of a number token. Bits 0 to 3 hold the format's number kind (0 for its plain decimal), bits 4 to 8 the
// integer digits and bits 9 to 13 the fraction digits, each count saturated at 31.
number_spelling :: #force_inline proc "contextless" (kind: u16, int_digits, frac_digits: u64) -> u16 {
	return kind | u16(min(int_digits, 31)) << 4 | u16(min(frac_digits, 31)) << 9
}
