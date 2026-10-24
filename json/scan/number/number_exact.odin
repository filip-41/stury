package number

import "base:intrinsics"
import "core:math/bits"

// `DOM_INV5[k]` is the modular inverse of `5^k` mod 2^64 and `DOM_DIV5_MAX[k] = floor((2^64-1) / 5^k)`,
// for `dom_exact_scale`'s divisibility test.
@(rodata)
DOM_INV5 := [23]u64 {
	0x1,
	0xcccccccccccccccd,
	0x8f5c28f5c28f5c29,
	0x1cac083126e978d5,
	0xd288ce703afb7e91,
	0x5d4e8fb00bcbe61d,
	0x790fb65668c26139,
	0xe5032477ae8d46a5,
	0xc767074b22e90e21,
	0x8e47ce423a2e9c6d,
	0x4fa7f60d3ed61f49,
	0xfee64690c913975,
	0x3662e0e1cf503eb1,
	0xa47a2cf9f6433fbd,
	0x54186f653140a659,
	0x7738164770402145,
	0xe4a4d1417cd9a041,
	0xc75429d9e5c5200d,
	0xc1773b91fac10669,
	0x26b172506559ce15,
	0xd489e3a9addec2d1,
	0x90e860bb892c8d5d,
	0x502e79bf1b6f4f79,
}

@(rodata)
DOM_DIV5_MAX := [23]u64 {
	0xffffffffffffffff,
	0x3333333333333333,
	0xa3d70a3d70a3d70,
	0x20c49ba5e353f7c,
	0x68db8bac710cb2,
	0x14f8b588e368f0,
	0x431bde82d7b63,
	0xd6bf94d5e57a,
	0x2af31dc46118,
	0x89705f4136b,
	0x1b7cdfd9d7b,
	0x57f5ff85e5,
	0x119799812d,
	0x384b84d09,
	0xb424dc35,
	0x24075f3d,
	0x734aca5,
	0x170ef54,
	0x49c977,
	0xec1e4,
	0x2f394,
	0x971d,
	0x1e39,
}

// 2^53: an integer is exactly a binary64 when its odd part is below this (`dom_exact_scale`).
DOM_EXACT_MANT :: u64(1) << 53

// Whether `mant * 10^e` is exactly a binary64, not merely correctly rounded, for any `mant`. The Clinger
// window (`mant <= 2^53`, `|e| <= 22`) guarantees correct rounding, but `9007199254740991e1` is inside it
// and its value needs 54 significand bits: calling it exact would break the never-truncate
// law. Past 2^53 an integer can still be exact: `9007199254740994` is `4503599627370497 * 2`.
//
// So this asks representability from the odd part `o` of `mant = 2^t * o`:
//
//	e >= 0: value = o * 5^e * 2^(t+e)  -- representable iff o*5^e < 2^53
//	e < 0:  value = (o / 5^k) * 2^(t-k), k = -e -- representable iff 5^k divides o and that odd
//	                                              quotient is below 2^53
//
// The positive half compares `o` against `DOM_MANT_MAX5`. The negative half asks whether `5^k`
// divides `mant` (equivalently `o`, since `5^k` is odd) without a division: with the modular
// inverse of `5^k`, `mant * DOM_INV5[k] <= DOM_DIV5_MAX[k]` (wrapping multiply) holds exactly
// when `5^k` divides `mant`, and the product is then the quotient. Past `|e| = 22` the tables stop:
// `5^23 > 2^53`, so `e > 22` is never exact, and `e < -22` is under-claimed `false`.
dom_exact_scale :: #force_inline proc(mant: u64, e: i64) -> bool {
	if mant == 0 {
		return true
	}
	if e >= 0 {
		if e > 22 {
			return false
		}
		o := mant >> (u64(bits.trailing_zeros(mant)) & 63)
		#no_bounds_check thresh := DOM_MANT_MAX5[e]
		return o < thresh
	}
	k := -e
	if k > 22 {
		return false
	}
	#no_bounds_check q := mant * DOM_INV5[k]
	// Divisibility is rare, so the quotient's test is a branch rather than work every token pays.
	#no_bounds_check if intrinsics.expect(q <= DOM_DIV5_MAX[k], false) {
		return q >> (u64(bits.trailing_zeros(q)) & 63) < DOM_EXACT_MANT
	}
	return false
}
