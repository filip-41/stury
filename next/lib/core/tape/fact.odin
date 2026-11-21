package tape

// Facts are the parts of a text that describe values without being values: comments, tags, anchors, styles, markup
// names, attributes and declarations. Any document can hold any fact; a write reports the facts its target format
// cannot hold.

// A comment, property or attribute of a node.
Fact :: struct {
	lo:       u64,
	node:     Node_Index,
	n:        u32,
	kind:     Fact_Kind,
	spelling: u16, // a comment's: opening marker length in the low byte, closing in the high byte
}

// Data that only describes a value and means nothing on its own is considered a fact. The kinds with a span come
// first, in the order of their roles.
Fact_Kind :: enum u8 {
	Comment,
	Comment_Inline,
	Comment_Foot,
	Tag,
	Anchor,
	Alias,
	Instruction,
	Doctype,
	Directive,
	Attribute,
	Style, // no span: held in the node's spelling
	Name, // no span: the element's shape
	Namespace, // no span: the element's shape
	Content, // no span: the element's shape
}

// The fact kind of a token whose role is a fact's.
fact_kind :: #force_inline proc "contextless" (role: Role) -> Fact_Kind {
	return Fact_Kind(u8(role) - u8(Role.Comment))
}

#assert(u8(Role.Comment_Foot) - u8(Role.Comment) == u8(Fact_Kind.Comment_Foot))
#assert(u8(Role.Alias) - u8(Role.Comment) == u8(Fact_Kind.Alias))
#assert(u8(Role.Attribute) - u8(Role.Comment) == u8(Fact_Kind.Attribute))

Facts :: bit_set[Fact_Kind; u16]

// The comment facts, for a format that holds comments.
COMMENTS :: Facts{.Comment, .Comment_Inline, .Comment_Foot}
