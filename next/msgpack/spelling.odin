package msgpack

import "stury:lib/core/tape"

// Token spelling layout for MessagePack tokens beyond the shared bits in `tape`.

// In a string, binary, or ext value token's spelling, bits 11..13 hold its header length (1..6 bytes).
// Bit 14 marks an `ext` payload (`STR_EXT`), and bit 15 marks a MessagePack Timestamp `ext -1` (`STR_TIMESTAMP`).
@(private)
HEAD_SHIFT :: 11
@(private)
HEAD_MASK :: u16(7)
@(private)
STR_EXT :: u16(1 << 14)
@(private)
STR_TIMESTAMP :: u16(1 << 15)

#assert((HEAD_MASK << HEAD_SHIFT) & (tape.SPELLING_CREDIT | tape.SPELLING_CREDIT_EXACT | tape.SPELLING_DECODE | tape.SPELLING_LAX | STR_EXT | STR_TIMESTAMP) == 0)
#assert(STR_EXT & STR_TIMESTAMP == 0)
#assert((STR_EXT | STR_TIMESTAMP) & (tape.SPELLING_CREDIT | tape.SPELLING_CREDIT_EXACT | tape.SPELLING_DECODE | tape.SPELLING_LAX) == 0)

// The spelling of a string/bin/ext token with head length `hl`.
@(private)
head_spelling :: #force_inline proc "contextless" (hl: u64) -> u16 {
	return u16(hl & 7) << HEAD_SHIFT
}

// The length of the header before the token's payload.
@(private)
head_of_spelling :: #force_inline proc "contextless" (spelling: u16) -> u8 {
	return u8(spelling >> HEAD_SHIFT & HEAD_MASK)
}

// The `End` token of a MessagePack container ending at `end` (all MessagePack containers have definite length).
@(private)
end_token :: #force_inline proc "contextless" (end: u64) -> tape.Token {
	return {lo = end, kind = .End}
}

// A number token's number kind in bits 0..3 (`tape.NUMBER_KIND`).
@(private)
NUMBER_INT :: u16(1)
@(private)
NUMBER_FLOAT :: u16(2)
