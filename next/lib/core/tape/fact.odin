package tape

// Facts are the parts of a text that describe values without being values: comments, tags, anchors, styles, markup
// names, attributes and declarations. Any document can hold any fact; a write reports the facts its target format
// cannot hold.

// A comment, property or attribute of a node.
Fact :: struct {
	lo:       u64,
	node:     Node_Index,
	n:        u32,
	role:     Role,
	kind:     Kind,
	spelling: u16, // `Plain`: opening marker length in the low byte, closing in the high byte
}

// Data that only describes a value and means nothing on its own is considered a fact
Fact_Kind :: enum u8 {
	Comment,
	Comment_Inline,
	Comment_Foot,
	Tag,
	Anchor,
	Alias,
	Style, // no span: held in the node's spelling
	Name, // no span: the element's shape
	Namespace, // no span: the element's shape
	Content, // no span: the element's shape
	Instruction,
	Doctype,
	Directive,
	Attribute,
}

Facts :: bit_set[Fact_Kind; u16]
