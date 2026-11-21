package tape

import "stury:lib/base/spell"

// A format is one text format stury reads, with one `Format` per spec. Its facts say which fact kinds it holds beyond
// plain values, its caps what else it can do, and its readers turn a node into an Odin value.

// A format capability other than a fact it holds.
Cap :: enum u8 {
	Css,
	Tabular,
	Binary,
	Spine,
}

// Same bit layout as `stury_caps_t`.
Caps :: bit_set[Cap; u32]

// Facts only their own format writes, never counted as dropped.
FORMAT_OWN :: Facts{.Name, .Content, .Directive}

// Facts a write counts as dropped when the target cannot emit them.
CARRIED :: ~FORMAT_OWN

// The stable id of one spec of a format, stored in saved documents. Unique across the linked formats.
Format_Id :: distinct u16

// One spec of a format (e.g. JSON, JSONC and JSON5 are three), in rodata.
Format :: struct {
	name:  string,
	id:    Format_Id,
	facts:  Facts, // the fact kinds it holds
	caps:   Caps,
	// The bytes of a scalar token's authored span before and after the token's own, as a string's quotes.
	bounds: proc "contextless" (src: []u8, t: Token) -> (head, tail: u8),
	// The text of a string node whose spelling has `SPELLING_DECODE`, decoded into `buf`, false when `buf` is shorter
	// than the node's span.
	decode: proc "contextless" (src: []u8, t: Node, buf: []u8) -> (s: string, ok: bool),
	// The value of a number node.
	number: proc "contextless" (src: []u8, t: Node) -> spell.Number,
}
