package tape

// A format is one text format stury reads and writes, with one `Format` per spec. Its caps say what its parser
// produces and its writer emits beyond plain values.

// A list of format capabilities. Reading facts is never gated.
Cap :: enum u8 {
	Comments,
	Attributes,
	Namespaces,
	Instructions,
	Css,
	Tags,
	Styles,
	Anchors,
	Tabular,
	Binary,
	Spine,
	Dtd,
}

// Same bit layout as `stury_caps_t`.
Caps :: bit_set[Cap; u32]

// The facts each cap lets a writer emit.
@(rodata)
CAP_FACTS := [Cap]Facts {
	.Comments     = {.Comment, .Comment_Inline, .Comment_Foot},
	.Attributes   = {.Attribute},
	.Namespaces   = {.Namespace},
	.Instructions = {.Instruction},
	.Css          = {},
	.Tags         = {.Tag},
	.Styles       = {.Style},
	.Anchors      = {.Anchor, .Alias},
	.Tabular      = {},
	.Binary       = {},
	.Spine        = {},
	.Dtd          = {.Doctype},
}

// Facts only their own format writes, never counted as dropped.
FORMAT_OWN :: Facts{.Name, .Content, .Directive}

// Facts a write counts as dropped when the target cannot emit them.
CARRIED :: ~FORMAT_OWN

// A format's stable id, stored in saved documents. Unique across the linked formats.
Format_Id :: distinct u16

// One spec of a format (e.g. JSON, JSONC and JSON5 are three), in rodata.
Format :: struct {
	name: string,
	id:   Format_Id,
	spec: u8,
	caps: Caps,
}
