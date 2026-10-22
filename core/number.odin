package core

// What a number's binary64 projection is relative to its authored value. One result per token,
// whoever reads it: a row, a span, or a decode.
Exactness :: enum u8 {
	// No binary64 value: not a number, out of range (`1e400`), a malformed span. The value is 0.
	None,
	// The authored value is nonzero and the result is +-0 (`1e-400`).
	Underflowed,
	// The correctly rounded value. The span is the number.
	Inexact,
	// The authored value bit for bit: `0`, `-0`, `2.5`, `1e2`.
	Exact,
}

// A binary64 projection and its exactness. Two words, so a reader returns it in registers.
Number :: struct {
	value:     f64,
	exactness: Exactness,
}

Number_Spelling_Flag :: enum u8 {
	Negative,     // token began '-'
	Has_Exponent, // authored 'e'/'E'
	Has_Fraction, // authored '.'
}

// These co-occur (`-1.5e2` has all three), so a token carries them as a flag set.
Number_Spelling :: bit_set[Number_Spelling_Flag; u8]

#assert(size_of(Number) == 16)
