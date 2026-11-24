package cbor

import "stury:lib/core/tape"

// The bits of the spelling of a CBOR token beyond the ones `tape` gives every format: the head of a string, the style
// of a container, the kind of a number and the value of a simple value.

// In a string's spelling, bits 11 to 14 hold the length of its head, and `STR_INDEF` marks a span that is the chunks of
// an indefinite string, whose head is its initial byte and whose break follows the span.
@(private)
HEAD_SHIFT :: 11

@(private)
STR_INDEF :: u16(1 << 15)

#assert(u16(0xF) << HEAD_SHIFT & (tape.SPELLING_CREDIT | tape.SPELLING_CREDIT_EXACT | STR_INDEF) == 0)

// The spelling of a string token of head length `hl`.
@(private)
head_spelling :: #force_inline proc "contextless" (hl: u64) -> u16 {
	return u16(hl) << HEAD_SHIFT
}

// The length of the head of string token `t`.
@(private)
head_of_spelling :: #force_inline proc "contextless" (spelling: u16) -> u8 {
	return u8(spelling >> HEAD_SHIFT & 0xF)
}

// In a container's spelling, an indefinite length, which ends at a break.
@(private)
STYLE_INDEFINITE :: u16(1 << 13)

#assert(STYLE_INDEFINITE & tape.CONTAINER_STYLE == STYLE_INDEFINITE)

// The `End` token of the container that ends at `end`, which an indefinite one spans its break byte of.
@(private)
end_token :: #force_inline proc "contextless" (end: u64, indefinite: bool) -> tape.Token {
	if indefinite {
		return {lo = end - 1, n = 1, kind = .End, spelling = STYLE_INDEFINITE}
	}
	return {lo = end, kind = .End}
}

// A number token's number kind, which `node_number` reads it by: an integer, a float, a bignum of tag 2 or 3, a decimal
// fraction of tag 4 and a bigfloat of tag 5. The span of a folded number is its tag's content.
@(private)
NUMBER_INT :: u16(1)

@(private)
NUMBER_FLOAT :: u16(2)

@(private)
NUMBER_BIG :: u16(3)

@(private)
NUMBER_BIG_NEGATIVE :: u16(4)

@(private)
NUMBER_DECIMAL :: u16(5)

@(private)
NUMBER_BIGFLOAT :: u16(6)

// The spelling of a simple value that is no boolean and no null, a `Null` token: the value plus one, shifted past bit
// 0.
@(private)
simple_spelling :: #force_inline proc "contextless" (v: u8) -> u16 {
	return (u16(v) + 1) << 1
}

#assert(STR_INDEF & (tape.SPELLING_CREDIT | tape.SPELLING_DECODE | tape.SPELLING_LAX) == 0)
