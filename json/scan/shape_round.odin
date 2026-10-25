package scan

// The binary64 rounding kernel: the halfway case a narrowing float would round twice on.

import core_pkg "../../core"
import "core:strconv/decimal"

// The binary64 value `n` of the number token `t`, made safe to narrow to a float of `sig` significant bits and
// least normal exponent `min_exp` with one more rounding. Narrowing rounds twice, and only a binary64 value
// exactly halfway between two such floats can come out wrong: the decimal may lie off the halfway point on
// either side. Such a value is replaced by the neighbour the decimal rounds to, checked on its digits. A
// decimal on the point itself is replaced by the even neighbour: the runtime narrowing cast does not tie to
// even on x86.
shape_off_halfway :: #force_inline proc(t: []byte, n: core_pkg.Number, sig: u64, min_exp: i64) -> f64 {
	bits := transmute(u64)n.value & (1 << 63 - 1)
	e := i64(bits >> 52) - 1023
	// The binary64 significand bits below the target's last one, and more below its normal range.
	drop := 53 - sig + u64(max(0, min_exp - e))
	if drop > 53 {
		return n.value
	}
	m := (bits & (1 << 52 - 1)) | 1 << 52
	// Low `drop` bits exactly the halfway bit: `n` is a target midpoint.
	if m & (1 << drop - 1) != 1 << (drop - 1) {
		return n.value
	}
	// An exact decimal is this midpoint, so the tie is to even. No cast sees the midpoint.
	if n.exactness == .Exact {
		return shape_tie_even(n.value, e, drop)
	}
	return shape_halfway_resolve(t, n.value, e, drop)
}

// `x`, exactly halfway between two floats `2 * half` apart, moved to the one the decimal `t` rounds to. A
// decimal on the halfway point itself goes to the even neighbour. The upper neighbour of the widest finite
// float is infinity's place, 2^128 or 2^16, which narrowing then refuses as out of range.
shape_halfway_resolve :: proc(t: []byte, x: f64, e: i64, drop: u64) -> f64 {
	ax := abs(x)
	half := transmute(f64)(u64(e + i64(drop) - 53 + 1023) << 52)
	// The exact decimal of `x`: its 53-bit significand, scaled by its binary exponent.
	d: decimal.Decimal
	decimal.assign(&d, (transmute(u64)ax & (1 << 52 - 1)) | 1 << 52)
	decimal.shift(&d, int(e - 52))
	switch shape_decimal_cmp(t, d.digits[:d.count], i64(d.decimal_point)) {
	case 1:
		ax += half
	case -1:
		ax -= half
	case:
		return shape_tie_even(x, e, drop)
	}
	return -ax if x < 0 else ax
}

// The even neighbour of midpoint `x`, an exact target float. Bit `drop` of the 53-bit significand is the
// target's least bit. Clear means the lower neighbour is even.
shape_tie_even :: proc(x: f64, e: i64, drop: u64) -> f64 {
	ax := abs(x)
	half := transmute(f64)(u64(e + i64(drop) - 53 + 1023) << 52)
	m := (transmute(u64)ax & (1 << 52 - 1)) | 1 << 52
	if m & (1 << drop) == 0 {
		ax -= half
	} else {
		ax += half
	}
	return -ax if x < 0 else ax
}

// The sign of |`t`| - 0.`digits` * 10^`point`, for a number token `t` and decimal digits with no leading
// zero. Exact at any length: the token's digits are compared once its decimal point is placed.
shape_decimal_cmp :: proc(t: []byte, digits: []byte, point: i64) -> int {
	i := int(t[0] == '-')
	// The token is 0.d1d2... * 10^at, d1 its first nonzero digit.
	at: i64
	// The sign of the first digit that differs from `digits`, padded with zeros.
	cmp := 0
	k := 0
	frac := false
	for ; i < len(t) && t[i] != 'e' && t[i] != 'E'; i += 1 {
		d := t[i]
		if d == '.' {
			frac = true
			continue
		}
		if !frac {
			at += 1
		}
		if k == 0 && d == '0' {
			at -= 1
			continue
		}
		if cmp == 0 {
			cmp = int(d) - int(digits[k] if k < len(digits) else '0')
		}
		k += 1
	}
	if i < len(t) {
		i += 1
		neg := t[i] == '-'
		if t[i] == '-' || t[i] == '+' {
			i += 1
		}
		// Saturated: past the bound, only gigabytes of digits could bring the token back onto `digits`.
		e: i64
		for ; i < len(t); i += 1 {
			e = min(e * 10 + i64(t[i] - '0'), 1 << 32)
		}
		at += -e if neg else e
	}
	for j := k; cmp == 0 && j < len(digits); j += 1 {
		if digits[j] != '0' {
			cmp = -1
		}
	}
	if at != point {
		return 1 if at > point else -1
	}
	return 1 if cmp > 0 else (-1 if cmp < 0 else 0)
}
