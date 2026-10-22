package number

// The cold decode: a token's significand and exponent folded from its span, then Eisel-Lemire
// (strconv's `fast_float_compute_float`) with fast_float's `m`/`m+1` bracket.

import "core:strconv"

// Significant digits kept in `m`: 19 fit a u64 and decide every input of 19 or fewer digits.
EL_MAX_DIGITS :: 19

// What `el_decode` did with one token.
//
// `.Decided`: `v` is the correctly rounded binary64, a signed zero below the binary64 range.
// `.Refused`: the magnitude overflows binary64. The caller must not ask strconv or read an
// infinity out of `v`. `.Undecided`: the caller tries strconv.
@(private)
El_Decode :: enum u8 {
	Decided,
	Refused,
	Undecided,
}

// Decode the token at `src[lo:hi]` from its span alone: the lexer's runs, folded into a significand of
// at most 19 digits and a decimal exponent the way the walk folds them (`dom_acc_wide` past 19 digits),
// then `el_settle`. `.Undecided` means the token is not one this routine checks and the caller keeps
// strconv. `.Refused` means the magnitude overflows and strconv must not be asked. `lexed` is the span's
// `lex_number_value` when the caller has it (`whole`), else the span is lexed here. `nonzero` is false only
// for a whole span whose significand digits are all zero, an authored zero rather than an underflow.
el_decode :: proc(src: []byte, lo, hi: u64, lexed := Number_Lex{}) -> (v: f64, res: El_Decode, nonzero: bool) {
	n := lexed if lexed.whole else lex_number_value(src, lo, hi)
	if !n.whole {
		return 0, .Undecided, true
	}
	neg := .Negative in n.spelling
	el := EL_Facts{m = n.mant, e = n.exp - i64(n.frac_digits)}
	if !DOM_MAYBE_EXACT(n.int_digits + n.frac_digits) {
		dom_acc_wide(src, n.int_at, n.int_digits, n.frac_at, n.frac_digits, n.exp, &el)
	}
	if el.m == 0 {
		// `0`, `-0`, `0.0`, `0e5`.
		return -0.0 if neg else 0.0, .Decided, false
	}
	v, res = el_settle(el.m, el.e, el.nz, neg)
	return v, res, true
}

// `m * 10^q` for a nonzero significand of at most 19 digits, correctly rounded, or `.Refused` on overflow.
//
// `nz` says a nonzero digit was dropped past `m`, and a token is never decided by its truncated prefix,
// which can flip the rounding: the true value lies in `[m*10^q, (m+1)*10^q)`, and rounding is monotone,
// so equal endpoints settle it (fast_float's bracket). Endpoints that round apart need real precision:
// `.Undecided`.
el_settle :: proc(m: u64, q: i64, nz, neg: bool) -> (f64, El_Decode) {
	b := #force_inline strconv.fast_float_compute_float(f64, int(q), m)
	if nz && b != #force_inline strconv.fast_float_compute_float(f64, int(q), m + 1) {
		return 0, .Undecided
	}
	if b == F64_INF_BITS {
		return 0, .Refused
	}
	return transmute(f64)(b | u64(neg) << 63), .Decided
}

// Reached from `dom_number_value_cold` for any token the walk's inline arms do not settle, and strconv
// decides only the `.Undecided` remainder. `lexed` and `nonzero` as in `el_decode`.
dom_number_el :: proc(src: []byte, lo, hi: u64, lexed := Number_Lex{}) -> (v: f64, ok: bool, nonzero: bool) {
	// `.Refused` is an overflow that strconv would refuse too, so it is not asked. Its value is never read.
	res: El_Decode
	if v, res, nonzero = el_decode(src, lo, hi, lexed); res != .Undecided {
		return v, res == .Decided, nonzero
	}
	v, ok = strconv.parse_f64(string(src[lo:hi]))
	return v, ok, nonzero
}
