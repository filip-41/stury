package value

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Values are the data queries and builders work on, whether read from a document or built by a query. A number read
// from a text keeps its spelling, and `lib/core/value/bigint` turns one past `i64` into a big integer, so a program
// that only reads values links no big integers.

// A document node or a value built in memory.
Value :: union {
	bool,
	i64,
	f64,
	Number,
	string,
	Bytes,
	^Array,
	^Object,
	Node_Ref,
}

Bytes :: distinct []u8

// A node of a document taken as a value with no copy, which a query reads as it needs, so passing a container on
// reads none of it.
Node_Ref :: struct {
	doc:  ^tape.Document,
	node: tape.Node_Index,
}

// A number of a text with its spelling, which it borrows from the text, so output writes it as read. The fields are
// `spell.Number`'s, laid out with the span so that a `Value` stays 32 bytes.
Number :: struct {
	bits: u64, // as `kind` reads them
	text: [^]u8,
	len:  u32,
	kind: spell.Number_Kind,
}

// The `Number` of `n`, spelled `text` in a text that outlives it.
number_of :: #force_inline proc "contextless" (n: spell.Number, text: string) -> Number {
	return {bits = n.bits, text = raw_data(text), len = u32(len(text)), kind = n.kind}
}

// The value of `n`.
number_value :: #force_inline proc "contextless" (n: Number) -> spell.Number {
	return {bits = n.bits, kind = n.kind}
}

// The spelling of `n` in its text.
number_text :: #force_inline proc "contextless" (n: Number) -> string {
	return string(n.text[:n.len])
}

Array :: struct {
	items: [dynamic]Value,
	lent:  bool, // shared with a slice, so copy before changing
}

// An object built in memory. Members are in insertion order, repeats allowed.
Object :: struct {
	slot_keys: [dynamic]string,
	slot_vals: [dynamic]Value,
	index:     map[string]int, // built for wide objects, and only an indexed object has dead slots
	dead:      i32,
	repeats:   bool,
}
