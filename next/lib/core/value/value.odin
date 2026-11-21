package value

import "core:math/big"
import "stury:lib/core/tape"

// Values are the data queries and builders work on, whether read from a document or built by a query. The package is
// apart from `tape`, so a program that only reads a text links no big integers.

// A document node or a value built in memory. An integer is `i64` when it fits, else a `^big.Int` from
// `integer_value`.
Value :: union {
	bool,
	i64,
	^big.Int,
	f64,
	Number_View,
	string,
	Bytes,
	^Array,
	^Object,
	Node_Ref,
}

// The canonical `Value` of `n`: an `i64` when it fits, else `n` itself.
@(require_results)
integer_value :: proc(n: ^big.Int) -> (Value, big.Error) {
	small, err := big.get_i64(n)
	if err == nil {
		return small, nil
	}
	if err == .Integer_Overflow || err == .Integer_Underflow {
		return n, nil
	}
	return nil, err
}

Bytes :: distinct []u8

Node_Ref :: struct {
	doc:  ^tape.Document,
	node: tape.Node_Index,
}

// A number's unparsed digits, kept so output preserves its spelling.
Number_View :: struct {
	text: [^]u8,
	len:  u32,
	mark: u32, // `NUMBER_HELD`: the parsed f64 sits in the 8 bytes before `text`
}

NUMBER_HELD :: max(u32)

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
