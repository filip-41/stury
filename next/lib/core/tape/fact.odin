package tape

// Facts are the parts of a text that describe values without being values: comments, tags, anchors, styles,
// element names, attributes and declarations. Any document can hold any fact kind, and `Format.facts` says which a
// format holds.

// A comment, property or attribute of a node.
Fact :: struct {
	lo:       u64,
	node:     Node_Index,
	n:        u32,
	spelling: u16, // a comment's: opening marker length in the low byte, closing in the high byte
	kind:     Fact_Kind,
}

// The kinds of fact, which describe a value and mean nothing on their own. The kinds with a span come first, in the
// order of their `Role`s.
Fact_Kind :: enum u8 {
	Comment,
	Comment_Inline,
	Comment_Foot,
	Tag,
	Anchor,
	Alias,
	Instruction,
	Instruction_Foot,
	Doctype,
	Directive,
	Attribute,
	Style, // no span: a container's `CONTAINER_STYLE`, a scalar's in its format's own spelling bits
	Name, // no span: the element's shape
	Namespace, // no span: the element's shape
	Content, // no span: the element's shape
	// On no document: a write's report that a key some records of a table lack was written as an empty cell in them.
	Absent,
}

// The `spelling` of a fact whose span starts with `lead` bytes of markup before its body and ends with `tail` bytes
// after it, as a comment's `<!--` and `-->`.
fact_spelling :: #force_inline proc "contextless" (lead, tail: u8) -> u16 {
	return u16(lead) | u16(tail) << 8
}

// The bytes a fact's span starts with before its body, as `fact_spelling` holds them.
fact_lead :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling & 0xFF)
}

// The bytes a fact's span ends with after its body, as `fact_spelling` holds them.
fact_tail :: #force_inline proc "contextless" (spelling: u16) -> u64 {
	return u64(spelling >> 8)
}

// The longest lead an attribute fact's spelling holds. A fact whose value starts further in has this lead, and its
// format finds the value from the name.
ATTRIBUTE_LEAD_MAX :: 255

// The spelling of an attribute fact whose value starts `lead` bytes past its name's first byte, saturated at
// `ATTRIBUTE_LEAD_MAX`, with the closing quote as the tail when the value is `quoted`. Bits 9 to 15 are the format's.
@(require_results)
attribute_spelling :: #force_inline proc "contextless" (lead: int, quoted: bool) -> u16 {
	return fact_spelling(u8(min(lead, ATTRIBUTE_LEAD_MAX)), 1 if quoted else 0)
}

// The facts of node `at` of `doc`, in source order.
facts_of :: proc "contextless" (doc: ^Document, at: Node_Index) -> []Fact #no_bounds_check {
	lo, hi := 0, len(doc.facts)
	for lo < hi {
		mid := lo + (hi - lo) >> 1
		if doc.facts[mid].node < at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	hi = lo
	for hi < len(doc.facts) && doc.facts[hi].node == at {
		hi += 1
	}
	return doc.facts[lo:hi]
}

// The fact kind of a token whose role is a fact's.
fact_kind :: #force_inline proc "contextless" (role: Role) -> Fact_Kind {
	return Fact_Kind(u8(role) - u8(Role.Comment))
}

#assert(u8(Role.Comment_Foot) - u8(Role.Comment) == u8(Fact_Kind.Comment_Foot))
#assert(u8(Role.Alias) - u8(Role.Comment) == u8(Fact_Kind.Alias))
#assert(u8(Role.Instruction_Foot) - u8(Role.Comment) == u8(Fact_Kind.Instruction_Foot))
#assert(u8(Role.Attribute) - u8(Role.Comment) == u8(Fact_Kind.Attribute))

Facts :: bit_set[Fact_Kind; u32]

// The comment facts, for a format that holds comments.
COMMENTS :: Facts{.Comment, .Comment_Inline, .Comment_Foot}

// The spelling of a comment fact that one `#` opens and its line end closes.
HASH_COMMENT :: u16(1)
