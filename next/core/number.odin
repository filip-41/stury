package core

import spell "./spell"

// The number types and bounds a reader answers with, from `core/spell`, which holds the decoders and their tables.

// A number token's value, decoded from its span when it is read. The walk stores no number, so a document holds the
// token's bytes and the spelling facts the walk recorded.
//
// `Int` is an integer that fits `i64`, stored in two's complement in `bits`. `Uint` is a positive integer that fits
// `u64` and not `i64`. `Float` is a binary64 in `bits`, correctly rounded to nearest even. `Wide` is a number that no
// `i64`, `u64` or `f64` holds, for which the caller reads the span.
Number_Kind :: spell.Number_Kind
Number :: spell.Number

// Limits on a number handed to a decoder. A number with more authored mantissa digits than `MAX_NUMBER_DIGITS`, or
// with an exponent or scale beyond ±`MAX_NUMBER_SCALE`, is `Wide` and its span is not decoded.
MAX_NUMBER_DIGITS :: spell.MAX_NUMBER_DIGITS
MAX_NUMBER_SCALE :: spell.MAX_NUMBER_SCALE
