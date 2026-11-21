package tape

// A format is one text format stury reads and writes, with one `Format` per spec. Its facts say what its writer emits
// beyond plain values, and its caps what else it can do.

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
	facts: Facts, // the facts its writer emits, every fact being readable
	caps:  Caps,
}
