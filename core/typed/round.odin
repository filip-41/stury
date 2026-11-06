package typed

// A decimal's single rounding into an f32. Narrowing a binary64 rounds twice, and only a binary64 exactly halfway between
// two floats can come out wrong: the decimal may lie off the halfway point on either side.

import "core:strconv/decimal"

// `x`, the binary64 of decimal `t`, made safe to narrow to an f32 with one more rounding. A decimal on a midpoint stays
// there, and the cast ties it to even.
@(private)
off_halfway :: proc(t: []byte, x: f64) -> f64 {
	bits := transmute(u64)x & (1 << 63 - 1)
	e := i64(bits >> 52) - 1023
	drop := 29 + u64(max(0, -126 - e))
	if drop > 53 {
		return x
	}
	m := (bits & (1 << 52 - 1)) | 1 << 52
	if m & (1 << drop - 1) != 1 << (drop - 1) {
		return x
	}
	// `x` lies `half` from either neighbour. The upper neighbour of the widest finite float is infinity's place, 2^128
	// or 2^16, which narrowing then refuses as out of range.
	half := transmute(f64)(u64(e + i64(drop) - 53 + 1023) << 52)
	// The exact decimal of `x`: its 53-bit significand, scaled by its binary exponent.
	d: decimal.Decimal
	decimal.assign(&d, m)
	decimal.shift(&d, int(e - 52))
	cmp := decimal_cmp(t, d.digits[:d.count], i64(d.decimal_point))
	if cmp == 0 {
		return x
	}
	ax := abs(x) + (half if cmp > 0 else -half)
	return -ax if x < 0 else ax
}

// The sign of |`t`| - 0.`digits` * 10^`point`, for a decimal `t` with any sign and point, and digits with no
// leading zero. Exact at any length: the token's digits are compared once its decimal point is placed.
@(private)
decimal_cmp :: proc(t: []byte, digits: []byte, point: i64) -> int {
	i := int(t[0] == '-' || t[0] == '+')
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
