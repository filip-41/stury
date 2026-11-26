package yaml

import "base:runtime"
import "stury:lib/core/tape"

// Faults of a YAML 1.2 text, indexed by `Detail`.
Detail :: enum u8 {
	None,
	Cut_Utf8,                // `Truncated`, where the text ends inside a UTF-8 sequence
	Invalid_Utf8,            // `Bad_Char`, at the lead byte of an ill-formed sequence
	Control_Char,            // `Bad_Char`, a character YAML does not allow in a text
	Expected_Line_End,       // `Bad_Char`, text after a node where the line must end
	Duplicate_Directive,     // `Bad_Char`, a second `%YAML` directive or a handle declared twice
	Bad_Directive,           // `Bad_Char`, a directive that does not follow its grammar
	Bad_Version,             // `Bad_Char`, a `%YAML` major version other than 1
	Expected_Document_Start, // `Bad_Char`, directives without a `---` after them
	Unexpected_Content,      // `Bad_Char`, text after the document's node that is not a marker
	Duplicate_Property,      // `Bad_Char`, two tags or two anchors on one node
	Bad_Tag,                 // `Bad_Char`, a tag that does not follow the grammar
	Undeclared_Handle,       // `Bad_Char`, a tag handle no `%TAG` directive declared
	Bad_Anchor,              // `Bad_Char`, an anchor or alias without a name
	Undefined_Alias,         // `Bad_Char`, an alias to a name no anchor holds
	Alias_Cycle,             // `Bad_Char`, an alias inside the node of its own anchor
	Alias_Limit,             // `Too_Wide`, aliases that expand past `Budget.expansion`
	Open_String,             // `Truncated`, a quoted scalar the text never closes
	Bad_Codepoint,           // `Bad_Escape`, an escape of a surrogate or a value past U+10FFFF
	Marker_In_Scalar,        // `Bad_Char`, a document marker inside a quoted scalar or a flow collection
	Bad_Indent,              // `Bad_Char`, a line indented too little or too much
	Tab_Indent,              // `Bad_Char`, a tab in the indentation of a block
	Bad_Block_Header,        // `Bad_Char`, a block scalar header that does not follow the grammar
	Block_In_Line,           // `Bad_Char`, a block collection that starts on the line of a node that cannot hold one
	Multiline_Key,           // `Bad_Char`, an implicit key that spans lines
	Key_Too_Long,            // `Bad_Char`, an implicit key longer than 1024 bytes
	Bad_Start,               // `Bad_Char`, a character that cannot start a node
	Expected_Colon,          // `Bad_Char`, a mapping key without its `:`
	Expected_Value,          // `Bad_Char`, a flow collection entry that is empty
	Expected_Comma,          // `Bad_Char`, text where a comma or a close was expected
	Open_Collection,         // `Truncated`, a flow collection the text never closes
	Alias_Property,          // `Bad_Char`, a tag or an anchor on an alias
	Extra_Document,          // `Bad_Char`, a second document where a text is read as one
	No_Document,             // `Truncated`, a text with no document where one is wanted
	Complex_Key,             // `Bad_Char`, a key that is a collection, which a document does not hold
	Tag_Mismatch,            // `Bad_Char`, a scalar whose text is not of the core type its tag names
}

// A YAML text's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := tape.Rules {
	"yaml",
	{
		{},
		{"cut_utf8", "Unfinished UTF-8 sequence"},
		{"invalid_utf8", "Invalid UTF-8"},
		{"control_char", "Character YAML does not allow"},
		{"expected_line_end", "Expected the end of the line"},
		{"duplicate_directive", "Directive given twice"},
		{"bad_directive", "Invalid directive"},
		{"bad_version", "Unsupported YAML version"},
		{"expected_document_start", "Expected --- after directives"},
		{"unexpected_content", "Unexpected text after the document"},
		{"duplicate_property", "Two tags or two anchors on one node"},
		{"bad_tag", "Invalid tag"},
		{"undeclared_handle", "Tag handle not declared"},
		{"bad_anchor", "Anchor or alias without a name"},
		{"undefined_alias", "Alias to an anchor that is not defined"},
		{"alias_cycle", "Alias inside its own anchor"},
		{"alias_limit", "Aliases expand past the limit"},
		{"open_string", "Unfinished quoted scalar"},
		{"bad_codepoint", "Escape of a value that is no Unicode scalar"},
		{"marker_in_scalar", "Document marker inside a scalar or collection"},
		{"bad_indent", "Invalid indentation"},
		{"tab_indent", "Tab in indentation"},
		{"bad_block_header", "Invalid block scalar header"},
		{"block_in_line", "Block collection cannot start on this line"},
		{"multiline_key", "Implicit key spans lines"},
		{"key_too_long", "Implicit key is longer than 1024 bytes"},
		{"bad_start", "Character cannot start a node"},
		{"expected_colon", "Expected : after a key"},
		{"expected_value", "Expected a value"},
		{"expected_comma", "Expected a comma or a close"},
		{"open_collection", "Unfinished flow collection"},
		{"alias_property", "Alias with a tag or an anchor"},
		{"extra_document", "More than one document"},
		{"no_document", "No document"},
		{"complex_key", "A collection as a key is not supported"},
		{"tag_mismatch", "Scalar is not of the type its tag names"},
	},
}

// Verdicts internal to the YAML parser and number scanners: low 8 bits carry `tape.Fault_Kind` or `hook.WALK_*`,
// bits `8..15` carry `Detail`, and upper bits hold the byte offset.
@(private)
Verdict :: distinct u64

@(private)
bad :: #force_inline proc "contextless" (at: int, kind: tape.Fault_Kind, detail: Detail) -> Verdict {
	return Verdict(u64(at) << 16 | u64(detail) << 8 | u64(kind))
}

@(private)
verdict_fault :: #force_inline proc "contextless" (v: Verdict) -> (at: u64, kind: tape.Fault_Kind, detail: Detail) {
	return u64(v) >> 16, tape.Fault_Kind(u8(v)), Detail(u8(v >> 8))
}

@(private)
_ :: runtime.Allocator
