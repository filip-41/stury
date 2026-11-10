package core

import spell "./spell"

// Aliases for the number types in `core/spell`, which the readers return.
Number_Kind :: spell.Number_Kind
Number :: spell.Number

// The kind the unquoted text `src[lo:hi]` reads as when its format gives it none: `.True` or `.False` for those spellings
// when `bools`, `.Number` for an RFC 8259 number when `numbers` (with whether it is a plain integer), else `.String`.
plain_kind :: proc (src: []u8, lo, hi: u64, bools, numbers: bool) -> (kind: Kind, integer: bool) {
	text := string(src[lo:hi])
	switch {
	case bools && text == "true":
		return .True, false
	case bools && text == "false":
		return .False, false
	case numbers:
		if _, plain, strict, ok := spell.number_loose(src, lo, hi); ok && strict {
			return .Number, plain
		}
	}
	return .String, false
}
