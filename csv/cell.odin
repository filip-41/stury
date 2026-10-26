package csv

// The scalar cell readers `Document`'s `get_int`/`get_float` share with `unmarshal`, so both judge a cell's
// text the same way. `read_float_value` also says whether the binary64 is the authored value, with the
// verdict JSON's number decoder gives a token.

import "base:intrinsics"
import "core:math"
import "core:strconv"
import core_pkg "../core"

// The exponent magnitude a decimal lexes to is clamped here: one past `i32`, so an authored exponent past
// any binary64 range still reads as out of it while the fold cannot overflow.
@(private)
DECIMAL_EXP_CAP :: i64(max(i32)) + 1

// A decimal cell lexed once: the first 19 significant digits as `mant`, every digit counted in `digits`, and
// the value `mant * 10^(exp - frac_digits)` when `digits` fits the fold. `nonzero` says a digit past the
// fold was not zero, so the fold alone cannot prove the value zero.
@(private)
Decimal_Lex :: struct {
	mant, digits: u64,
	frac_digits:  u64,
	exp:          i64,
	nonzero:      bool,
	ok:           bool,
}

// `[+-]?(digits(.digits?)?|.digits)([eE][+-]?digits)?`: the decimals a float cell may spell. `.5` and `1.`
// are accepted because other writers spell floats that way; a leading `0` past the first is a digit, not a
// refusal.
@(private)
lex_decimal :: proc(text: string) -> (d: Decimal_Lex) {
	i := 0
	if i < len(text) && (text[i] == '-' || text[i] == '+') {
		i += 1
	}
	int_at := i
	for ; i < len(text); i += 1 {
		if text[i] < '0' || text[i] > '9' {
			break
		}
	}
	int_end := i
	// As JSON's decoder reads a span, leading integer zeros are not significand digits; an all-zero run keeps
	// one, the lone `0` RFC 8259 allows.
	int_start := int_at
	for int_start + 1 < int_end && text[int_start] == '0' {
		int_start += 1
	}
	for p := int_start; p < int_end; p += 1 {
		decimal_push(&d, text[p] - '0')
	}
	if i < len(text) && text[i] == '.' {
		i += 1
		frac_at := i
		for ; i < len(text); i += 1 {
			c := text[i] - '0'
			if c > 9 {
				break
			}
			decimal_push(&d, c)
		}
		d.frac_digits = u64(i - frac_at)
	}
	if int_end == int_at && d.frac_digits == 0 {
		return {}
	}
	if i < len(text) && (text[i] == 'e' || text[i] == 'E') {
		i += 1
		neg := false
		if i < len(text) && (text[i] == '-' || text[i] == '+') {
			neg = text[i] == '-'
			i += 1
		}
		exp_at := i
		for ; i < len(text); i += 1 {
			c := text[i] - '0'
			if c > 9 {
				break
			}
			d.exp = min(d.exp * 10 + i64(c), DECIMAL_EXP_CAP)
		}
		if i == exp_at {
			return {}
		}
		if neg {
			d.exp = -d.exp
		}
	}
	d.ok = i == len(text)
	return
}

// Folds one digit value into the first 19 digits, and notes every nonzero digit past them.
@(private)
decimal_push :: #force_inline proc(d: ^Decimal_Lex, c: u8) {
	if d.digits < 19 {
		d.mant = d.mant * 10 + u64(c)
	}
	d.nonzero ||= c != 0
	d.digits += 1
}

// Whether `mant * 10^e` is exactly a binary64, not merely its correctly rounded projection. For `e >= 0`
// the value is `o * 5^e * 2^(t+e)` for the odd part `o` of `mant`, representable iff `o * 5^e < 2^53`; for
// `e < 0` it is `(o / 5^-e) * 2^(t-k)`, representable iff `5^-e` divides `mant` and the quotient's odd part
// is below `2^53`. `5^23` is past `2^53`, so no `|e| > 22` is exact.
@(private)
decimal_exact :: #force_inline proc(mant: u64, e: i64) -> bool {
	if mant == 0 {
		return true
	}
	if e > 22 || e < -22 {
		return false
	}
	k := u64(e if e >= 0 else -e)
	five := u64(1)
	for _ in 0 ..< k {
		five *= 5
	}
	if e >= 0 {
		o := mant >> (u64(intrinsics.count_trailing_zeros(mant)) & 63)
		return u128(o) * u128(five) < (u128(1) << 53)
	}
	if mant % five != 0 {
		return false
	}
	q := mant / five
	return q >> (u64(intrinsics.count_trailing_zeros(q)) & 63) < (u64(1) << 53)
}

// The binary64 a lexed decimal spells, correctly rounded, and the exactness: `.None` for a value past the
// binary64 range (`1e400`), `.Underflowed` for a nonzero value that rounds to zero (`1e-400`), `.Exact`
// only when the binary64 is the authored value, `.Inexact` for every other rounding. A significand past 19
// digits is under-claimed `.Inexact` as JSON's decoder under-claims it.
@(private)
decimal_value :: proc(d: Decimal_Lex, text: string) -> core_pkg.Number {
	v, _ := strconv.parse_f64(text)
	switch {
	case math.is_inf(v):
		return {exactness = .None}
	case v == 0 && d.nonzero:
		// The sign of an underflow is still the authored one.
		return {value = v, exactness = .Underflowed}
	case d.nonzero && d.digits > 19:
		return {value = v, exactness = .Inexact}
	case decimal_exact(d.mant, d.exp - i64(d.frac_digits)):
		return {value = v, exactness = .Exact}
	}
	return {value = v, exactness = .Inexact}
}

// The binary64 a decimal cell spells and its exactness. `.None` for any other text.
@(private)
read_float_value :: proc(text: string) -> core_pkg.Number {
	d := lex_decimal(text)
	if !d.ok {
		return {exactness = .None}
	}
	return decimal_value(d, text)
}

// `[+-]?digits` as a magnitude and a sign. `over` is set past 128 bits. Any other text is `.Wrong_Kind`.
@(private)
read_int :: proc(text: string) -> (mag: u128, over, neg: bool, fault: core_pkg.Shape_Fault) {
	digits := text
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {
		neg = digits[0] == '-'
		digits = digits[1:]
	}
	if len(digits) == 0 {
		return 0, false, false, .Wrong_Kind
	}
	if len(digits) <= 19 {
		// 19 digits stay below 10^19, which fits a u64, so no overflow check is needed.
		small: u64
		for c in transmute([]byte)digits {
			d := c - '0'
			if d > 9 {
				return 0, false, false, .Wrong_Kind
			}
			small = small * 10 + u64(d)
		}
		return u128(small), false, neg, .None
	}
	digits_only: bool
	if mag, over, digits_only = core_pkg.fold_digits(transmute([]byte)digits, 0, u64(len(digits)), u128); !digits_only {
		return 0, false, false, .Wrong_Kind
	}
	return mag, over, neg, .None
}

// `text`, an integer of at most 64 bits, into the `width`-byte `signed` or unsigned integer at `dest`.
@(private)
store_int :: #force_inline proc(text: string, dest: rawptr, width: u8, signed: bool) -> core_pkg.Shape_Fault {
	mag, over, neg := read_int(text) or_return
	if over || mag > u128(max(u64)) {
		return .Out_Of_Range
	}
	return core_pkg.shape_int_store(u64(mag), neg, dest, width, signed)
}
