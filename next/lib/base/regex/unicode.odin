#+private
package regex

// Oniguruma's Unicode character types under UTF-8, `\w`, `\d`, `\s`, the POSIX brackets and `\p{...}`, from
// its own tables, and its simple case folding (unicode_tables.odin).

import "core:strings"
import "core:unicode"

// A character type: a property table, or every character outside it.
Prop_Item :: struct {
	table: u16,
	neg:   bool,
}

// Two types derived from a stored one: \w in a class, Oniguruma's POSIX word, which lacks the digits ²³¹ and
// fractions ¼½¾, and the grapheme break class Extend, Grapheme_Extend with the emoji modifiers.
TABLE_CLASS_WORD :: 0xFFFE
TABLE_GCB_EXTEND :: 0xFFFF

in_table :: proc(table: int, r: rune) -> bool {
	switch table {
	case TABLE_CLASS_WORD:
		switch r {
		case 0xB2, 0xB3, 0xB9, 0xBC ..= 0xBE:
			return false
		}
		return in_table(TABLE_WORD, r)
	case TABLE_GCB_EXTEND:
		return r >= 0x1F3FB && r <= 0x1F3FF || in_table(TABLE_GRAPHEME_EXTEND, r)
	}
	ranges := PROPERTY_RANGES[PROPERTY_TABLES[table]:PROPERTY_TABLES[table + 1]]
	if len(ranges) == 0 {
		return false
	}
	// The last range starting at or below r, found without a branch per step. base + n stays within the
	// table. The key is wide enough for any rune to shift into.
	SPAN :: 1 << RANGE_SPAN_BITS - 1
	key := u64(u32(r)) << RANGE_SPAN_BITS | SPAN
	base := 0
	#no_bounds_check for n := len(ranges); n > 1; {
		half := n >> 1
		base = base + half if u64(ranges[base + half]) <= key else base
		n -= half
	}
	e := u64(ranges[base])
	return e <= key && u64(u32(r)) - e >> RANGE_SPAN_BITS <= e & SPAN
}

// \w, which \b reads too.
is_word :: proc(r: rune) -> bool {
	if r < 0x80 {
		return (r | 0x20) >= 'a' && (r | 0x20) <= 'z' || (r >= '0' && r <= '9') || r == '_'
	}
	return in_table(TABLE_WORD, r)
}

// `\p{name}`'s type: a name compared as Oniguruma compares them, without case, spaces, `_` or `-`.
named_prop :: proc(name: string) -> (it: Prop_Item, ok: bool) {
	buf: [64]byte // no property name is longer
	b := strings.builder_from_bytes(buf[:])
	for c in name {
		if c != ' ' && c != '_' && c != '-' {
			strings.write_rune(&b, unicode.to_lower(c))
		}
	}
	if len(name) > len(buf) {
		return
	}
	names, k := PROPERTY_NAMES, 0
	for each in strings.split_iterator(&names, "\x00") {
		if each == strings.to_string(b) {
			return {table = PROPERTY_NAME_TABLES[k]}, true
		}
		k += 1
	}
	return
}

// ECMA's `\p{...}` type for `name`, compared as written: a binary property or a General_Category value, or
// `General_Category=`, `gc=`, `Script=`, `sc=`, `Script_Extensions=` or `scx=` and a value.
ecma_prop :: proc(name: string) -> (it: Prop_Item, ok: bool) {
	kind, value := "", name
	if eq := strings.index_byte(name, '='); eq >= 0 {
		kind, value = name[:eq], name[eq + 1:]
		if kind == "" || value == "" {
			return
		}
		switch kind {
		case "General_Category":
			kind = "gc"
		case "Script":
			kind = "sc"
		case "Script_Extensions":
			kind = "scx"
		}
	}
	names, k := ECMA_NAMES, 0
	for each in strings.split_iterator(&names, "\x00") {
		at := strings.index_byte(each, '=')
		if each[at + 1:] == value && (each[:max(at, 0)] == kind || kind == "" && each[:max(at, 0)] == "gc") {
			return {table = ECMA_NAME_TABLES[k]}, true
		}
		k += 1
	}
	return
}

// A group name ECMA takes: an identifier, of ID_Start, `$` and `_`, then ID_Continue, `$`, ZWNJ and ZWJ.
ecma_identifier :: proc(name: string) -> bool {
	start, _ := ecma_prop("ID_Start")
	part, _ := ecma_prop("ID_Continue")
	for r, i in name {
		known := in_table(int(start.table if i == 0 else part.table), r)
		if r != '$' && r != '_' && !known && (i == 0 || r != 0x200C && r != 0x200D) {
			return false
		}
	}
	return true
}
