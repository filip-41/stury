package msgpack

import "base:intrinsics"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// MessagePack numeric readers: integers (`0x00..0x7f`, `0xe0..0xff`, `0xcc..0xcf`, `0xd0..0xd3`),
// IEEE 754 binary32/64 floats (`0xca`, `0xcb`), and ext type numbers (`-128..127`) for `.Tag` facts.

// The value of number node `t` of `src`. A `.Tag` fact's number is its signed `i8` ext type.
@(private)
number_value :: proc "contextless" (src: []u8, t: tape.Node) -> spell.Number {
	span := src[t.lo:t.lo + u64(t.n)]
	if t.role == .Tag {
		ext_type := i64(i8(span[len(span) - 1]))
		return {u64(ext_type), .Int}
	}
	if t.spelling & tape.NUMBER_KIND == NUMBER_FLOAT {
		return {float_bits(span), .Float}
	}
	return integer_value(span)
}

// Fast-path `number_value` for typed reads: reads fixints and `float64` inline and falls back for wider heads.
@(private)
number_in_place :: #force_inline proc "contextless" (src: []u8, t: tape.Node) -> spell.Number #no_bounds_check {
	if t.role != .Tag {
		b := src[t.lo]
		if t.spelling & tape.NUMBER_KIND == NUMBER_INT {
			if b < 0x80 {
				return {u64(b), .Int}
			}
			if b >= 0xe0 {
				return {u64(i64(i8(b))), .Int}
			}
		} else if b == 0xcb {
			return {u64(intrinsics.unaligned_load((^u64be)(raw_data(src)[t.lo + 1:]))), .Float}
		}
	}
	return number_value(src, t)
}

// The number kind spelling for a token starting at `lo`.
@(private)
respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	_ = hi
	b := src[lo]
	return NUMBER_FLOAT if b == 0xca || b == 0xcb else NUMBER_INT
}

// Decodes a MessagePack integer token span into a `spell.Number`.
@(private)
integer_value :: proc "contextless" (span: []u8) -> spell.Number #no_bounds_check {
	b := span[0]
	if b < 0x80 {
		return {u64(b), .Int}
	}
	if b >= 0xe0 {
		return {u64(i64(i8(b))), .Int}
	}
	switch b {
	case 0xcc:
		return {u64(span[1]), .Int}
	case 0xcd:
		return {u64(intrinsics.unaligned_load((^u16be)(raw_data(span)[1:]))), .Int}
	case 0xce:
		return {u64(intrinsics.unaligned_load((^u32be)(raw_data(span)[1:]))), .Int}
	case 0xcf:
		u := u64(intrinsics.unaligned_load((^u64be)(raw_data(span)[1:])))
		return {u, .Int if u <= u64(max(i64)) else .Uint}
	case 0xd0:
		return {u64(i64(i8(span[1]))), .Int}
	case 0xd1:
		return {u64(i64(i16(intrinsics.unaligned_load((^u16be)(raw_data(span)[1:]))))), .Int}
	case 0xd2:
		return {u64(i64(i32(intrinsics.unaligned_load((^u32be)(raw_data(span)[1:]))))), .Int}
	case 0xd3:
		return {u64(i64(intrinsics.unaligned_load((^u64be)(raw_data(span)[1:])))), .Int}
	}
	return {0, .Int}
}

// Decodes the binary64 bit pattern of a `float32` (`0xca`, 5 bytes) or `float64` (`0xcb`, 9 bytes).
@(private)
float_bits :: proc "contextless" (span: []u8) -> u64 #no_bounds_check {
	if len(span) == 5 {
		u := u32(intrinsics.unaligned_load((^u32be)(raw_data(span)[1:])))
		return transmute(u64)f64(transmute(f32)u)
	}
	return u64(intrinsics.unaligned_load((^u64be)(raw_data(span)[1:])))
}
