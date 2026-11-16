package spell

import "base:intrinsics"
import "core:math"

// A hex digit's value, or 0xFF for any other byte.
@(rodata)
HEX_NIBBLE: [256]u8 = {
	0 ..< '0' = 0xFF, ':' ..< 'A' = 0xFF, 'G' ..< 'a' = 0xFF, 'g' ..= 0xFF = 0xFF,
	'0' = 0, '1' = 1, '2' = 2, '3' = 3, '4' = 4, '5' = 5, '6' = 6, '7' = 7, '8' = 8, '9' = 9,
	'A' = 10, 'B' = 11, 'C' = 12, 'D' = 13, 'E' = 14, 'F' = 15,
	'a' = 10, 'b' = 11, 'c' = 12, 'd' = 13, 'e' = 14, 'f' = 15,
}

// Returns the four hex digits at `h` as a 16-bit value, and whether all four are hex digits. Four bytes must be
// readable at `h`.
hex4 :: #force_inline proc "contextless" (h: [^]u8) -> (unit: u32, ok: bool) {
	#no_bounds_check {
		a := HEX_NIBBLE[h[0]]
		b := HEX_NIBBLE[h[1]]
		c := HEX_NIBBLE[h[2]]
		d := HEX_NIBBLE[h[3]]
		return u32(a) << 12 | u32(b) << 8 | u32(c) << 4 | u32(d), (a | b | c | d) & 0xf0 == 0
	}
}

// The low `N` hex digits of `v`, most significant first, uppercase when `upper` is set.
hex_text :: #force_inline proc "contextless" (v: u64, $N: int, $upper: bool) -> (digits: [N]u8) #no_bounds_check {
	alphabet := "0123456789ABCDEF" if upper else "0123456789abcdef"
	for k in 0 ..< N {
		digits[k] = alphabet[v >> (4 * u64(N - 1 - k)) & 15]
	}
	return
}

// Decodes `0x` and hex digits with an optional sign. Past `u64` it returns the nearest `Float`, or `Wide` past
// binary64. A malformed span is `Wide`.
number_hex :: proc(src: []u8, lo, hi: u64) -> Number {
	top, shift, neg, ok := hex_significand(src, lo, hi)
	if !ok {
		return {0, .Wide}
	}
	if shift == 0 {
		if num, is_int := integer_number(top, neg); is_int {
			return num
		}
	}
	v := math.ldexp(f64(top), shift)
	if math.is_inf(v) {
		return {0, .Wide}
	}
	return {transmute(u64)(-v if neg else v), .Float}
}

// The f32 nearest hex `src[lo:hi]`, rounded once, and false if the span is not hex. Past `max(f32)` it is infinite.
number_hex_f32 :: proc(src: []u8, lo, hi: u64) -> (f32, bool) {
	top, shift, neg, ok := hex_significand(src, lo, hi)
	if !ok {
		return 0, false
	}
	// `f32(top)` scaled by a power of two is exact in binary64 until it is past `max(f32)`.
	v := f32(math.ldexp(f64(f32(top)), shift))
	return -v if neg else v, true
}

// Hex `src[lo:hi]` as `top << shift`. Past `u64`, `top` keeps its leading 64 bits and sets its lowest bit when a
// dropped bit is set, so one conversion to binary64 or f32 rounds it correctly.
@(private)
hex_significand :: proc(src: []u8, lo, hi: u64) -> (top: u64, shift: int, neg: bool, ok: bool) {
	p := lo
	if p < hi && (src[p] == '+' || src[p] == '-') {
		neg = src[p] == '-'
		p += 1
	}
	if hi - p < 3 || src[p] != '0' || src[p + 1] | 0x20 != 'x' {
		return
	}
	p += 2
	if hi - p > MAX_NUMBER_DIGITS {
		return
	}
	sticky := false
	for ; p < hi; p += 1 {
		d := u64(HEX_NIBBLE[src[p]])
		if d > 15 {
			return
		}
		if top <= max(u64) >> 4 {
			top = top << 4 | d
			continue
		}
		// `top` is at least 2^60, so it takes `room` more bits, at most 3.
		room := uint(intrinsics.count_leading_zeros(top))
		sticky ||= d & (1 << (4 - room) - 1) != 0
		top = top << room | d >> (4 - room)
		shift += 4 - int(room)
	}
	return top | u64(sticky), shift, neg, true
}
