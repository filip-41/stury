package lex

import "base:intrinsics"

// Value class of each first byte: `VC_OBJECT` `{`, `VC_ARRAY` `[`, `VC_STRING` `"`, `VC_LITERAL` t/f/n,
// `VC_NUMBER` `-`/digits, else `VC_NONE`.
@(rodata)
VCLASS : [256]u8 = {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0,
	5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 4, 0,
	0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
}

// Shared by the lexer, the walk cursor and the index skip, so one table
// answers each class question and the walks cannot drift.
@(rodata)
CHAR_FLAGS : [256]u8 = {
	0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 8, 8, 0,
	10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 0, 0, 0, 0, 0, 0,
	0, 4, 4, 4, 4, 12, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 16, 0, 16, 0, 0,
	0, 4, 4, 4, 4, 12, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 16, 0, 16, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
}

// Per-byte classifiers as flag tests: one table load covers the whitespace,
// alpha and number-char loops. `is_digit` is the one-byte `F_DIGIT` test. Only `digit_run`
// compares the range `'0'..'9'` directly.
F_WS :: u8(0x01)
F_DIGIT :: u8(0x02)
F_ALPHA :: u8(0x04)
F_NUMCHAR :: u8(0x08)
F_BRACKET :: u8(0x10)

// The bytes a string span stops on, one bit per check level: `SPAN_STOP_VALUES`
// is quote, backslash, control and >= 0x80, and `SPAN_STOP_LOCATE` the same less
// the control bytes. Exactly the stop rule `span_tail` writes as compares.
@(rodata)
SPAN_STOP : [256]u8 = {
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
	0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
	3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
}
SPAN_STOP_VALUES :: u8(0x01)
SPAN_STOP_LOCATE :: u8(0x02)


TRUE_U32 :: u32(0x65757274) // "true" little-endian
NULL_U32 :: u32(0x6c6c756e) // "null" little-endian
FALS_U32 :: u32(0x736c6166) // "fals" little-endian

// Four bytes at `p`, little-endian. Caller guarantees p + 4 <= len(src).
load32_le :: #force_inline proc(src: []byte, p: u64) -> u32 {
	#no_bounds_check {
		return u32(intrinsics.unaligned_load((^u32le)(&src[p])))
	}
}

is_digit :: #force_inline proc(c: byte) -> bool {
	return CHAR_FLAGS[c] & F_DIGIT != 0
}

// Four-char unrolled number-char consume (Structural extents): caller guarantees p+4 <= n. Returns 0..4.
numchar4 :: #force_inline proc(src: []byte, p: u64) -> u64 {
	when SCAN_FORCE_SLOW {
		return 0 // force-route build: no batched number-char runs
	}
	#no_bounds_check #unroll for k in 0 ..< 4 {
		if CHAR_FLAGS[src[p + u64(k)]] & F_NUMCHAR == 0 {
			return u64(k)
		}
	}
	return 4
}
