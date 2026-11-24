package xml

import "stury:lib/core/tape"

// XML's fault details and their messages.

// `Detail` holds XML's detail for a fault kind, in `tape.Fault.detail`. A walk's states choose it where they
// find the fault.
@(private)
Detail :: enum u8 {
	None,
	Name, // `Bad_Char`: a byte where a name must start
	Space, // `Bad_Char`: no whitespace between a name and the attribute after it, or after a target
	Equals, // `Bad_Char`: a byte where an attribute's `=` must be
	Quote, // `Bad_Char`: a byte that is no quote where an attribute value must start
	Attribute_Lt, // `Bad_Char`: a `<` inside an attribute value
	Duplicate_Attribute, // `Bad_Char`: at the name of an attribute the tag already has
	Empty_Tag, // `Bad_Char`: a `/` in a start tag that no `>` follows
	Mismatched_Tag, // `Bad_Char`: an end tag whose name differs from its start tag's
	Close_Tag, // `Bad_Char`: a byte in an end tag after its name that is no whitespace and no `>`
	Markup, // `Bad_Char`: a `<!` that opens no comment or CDATA section where one may stand
	Comment_Dashes, // `Bad_Char`: `--` inside a comment, not as its close
	Cdata_End, // `Bad_Char`: `]]>` in character data
	Control_Char, // `Bad_Char`: a control byte that is no tab, LF or CR
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed UTF-8 sequence
	Non_Char, // `Bad_Char`: U+FFFE or U+FFFF
	Reference, // `Bad_Char`: a `&` that begins no well-formed reference
	Char_Reference, // `Bad_Char`: a character reference to a code point that is no `Char`
	Undeclared_Entity, // `Bad_Char`: a reference to an entity other than the five predefined ones
	Declaration, // `Bad_Char`: a malformed XML declaration
	Reserved_Target, // `Bad_Char`: a processing instruction whose target is `xml`
	Instruction, // `Bad_Char`: a malformed processing instruction
	Encoding, // `Bad_Char`: a text in an encoding other than UTF-8
	Doctype, // `Bad_Char`: a malformed document type declaration
	Prolog, // `Bad_Char`: a byte before the root element that opens no declaration, comment, instruction or element
	Junk_After_Root, // `Bad_Char`: a byte after the root element that is no whitespace, comment or instruction
	Qualified_Name, // `Bad_Char`: a name with a colon that is no prefix and local name, or a prefix of a declaration with one
	Unbound_Prefix, // `Bad_Char`: a prefix that no `xmlns` declaration in scope binds
	Reserved_Prefix, // `Bad_Char`: a declaration of the prefix `xmlns`, of `xml` to another URI, or an element with the prefix `xmlns`
	Reserved_Namespace, // `Bad_Char`: a declaration that binds the `xml` or `xmlns` namespace URI to another prefix or as the default
	Empty_Binding, // `Bad_Char`: a prefix declaration with an empty URI
	Duplicate_Expanded, // `Bad_Char`: an attribute whose namespace and local name the tag already has
	Entity_Respelled, // `Bad_Char`: a replacement text whose markup its literal does not spell, so no byte holds it
	Unread_Entity, // `Bad_Char`: a reference to an external entity, or to an undeclared one in a DTD not read whole
	Recursion, // `Bad_Char`: a reference to an entity inside its own replacement text
	Unparsed_Entity, // `Bad_Char`: a reference to an unparsed entity, one with a notation
	External_Entity, // `Bad_Char`: a reference to an external entity in an attribute value
	Entity_Boundary, // `Bad_Char`: a replacement text that is not content, or a reference whose element it does not close
	Element_Declaration, // `Bad_Char`: a malformed element type declaration
	Attribute_Declaration, // `Bad_Char`: a malformed attribute-list declaration
	Entity_Declaration, // `Bad_Char`: a malformed entity declaration
	Notation_Declaration, // `Bad_Char`: a malformed notation declaration
	Subset, // `Bad_Char`: a byte in the internal subset that begins no declaration, reference or comment
	Parameter_Reference, // `Bad_Char`: a parameter-entity reference inside a declaration or an internal entity's value
}

// XML's fault rules, one per `Detail` value, which every fault a read returns points to.
@(private, rodata)
RULES := tape.Rules {
	"xml",
	{
		{},
		{"name", "Invalid name"},
		{"space", "Missing whitespace"},
		{"equals", "Missing = after attribute name"},
		{"quote", "Attribute value must be quoted"},
		{"attribute_lt", "< in attribute value"},
		{"duplicate_attribute", "Attribute repeated in one tag"},
		{"empty_tag", "/ in a tag without >"},
		{"mismatched_tag", "End tag does not match its start tag"},
		{"close_tag", "Invalid end tag"},
		{"markup", "Invalid markup declaration"},
		{"comment_dashes", "-- inside a comment"},
		{"cdata_end", "]]> in character data"},
		{"control_char", "Control character"},
		{"invalid_utf8", "Invalid UTF-8"},
		{"non_char", "U+FFFE or U+FFFF"},
		{"reference", "Invalid reference"},
		{"char_reference", "Reference to a code point that is not a character"},
		{"undeclared_entity", "Entity is not declared"},
		{"declaration", "Invalid XML declaration"},
		{"reserved_target", "Processing instruction target xml is reserved"},
		{"instruction", "Invalid processing instruction"},
		{"encoding", "Encoding other than UTF-8"},
		{"doctype", "Invalid document type declaration"},
		{"prolog", "Text before the root element"},
		{"junk_after_root", "Text after the root element"},
		{"qualified_name", "Name is no prefix and local name"},
		{"unbound_prefix", "Prefix is not declared"},
		{"reserved_prefix", "Reserved prefix"},
		{"reserved_namespace", "Reserved namespace URI"},
		{"empty_binding", "Prefix bound to an empty URI"},
		{"duplicate_expanded", "Attribute repeated by namespace and local name"},
		{"entity_respelled", "Replacement text spells markup its literal does not"},
		{"unread_entity", "Entity text is not read"},
		{"recursion", "Entity refers to itself"},
		{"unparsed_entity", "Reference to an unparsed entity"},
		{"external_entity", "Reference to an external entity in an attribute value"},
		{"entity_boundary", "Replacement text is not balanced content"},
		{"element_declaration", "Invalid element type declaration"},
		{"attribute_declaration", "Invalid attribute-list declaration"},
		{"entity_declaration", "Invalid entity declaration"},
		{"notation_declaration", "Invalid notation declaration"},
		{"subset", "Invalid internal subset"},
		{"parameter_reference", "Parameter-entity reference inside a declaration"},
	},
}
