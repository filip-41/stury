package number

import "base:intrinsics"

dom_state_flags :: #force_inline proc(st: Exactness) -> Row_Flags {
	switch st {
	case .Exact:
		return {.Decoded, .Exact}
	case .Inexact:
		return {.Decoded, .Inexact}
	case .Underflowed:
		return {.Decoded, .Underflowed, .Inexact}
	case .None:
		return {.Refused}
	}
	// Unreachable: the switch is exhaustive, Odin still wants the epilogue.
	return {}
}

// The exactness a decode's flags carry (`dom_number_value`): the reverse of `dom_state_flags`, and total
// (flags with no state bit answer `.None`).
dom_flag_state :: #force_inline proc(f: Row_Flags) -> Exactness {
	if .Underflowed in f {
		return .Underflowed
	}
	if .Inexact in f {
		return .Inexact
	}
	if .Exact in f {
		return .Exact
	}
	return .None
}

// `DOM_MANT_MAX5[e] = ceil(2^53 / 5^e)`: the positive side of `dom_exact_scale`, asked by
// comparison instead of a `u128` product. For integers `o, e >= 0`,
// `o * 5^e < 2^53  <=>  o < ceil(2^53 / 5^e)`, an identity over the integers.
// A test re-checks it against the product, exhaustively. The tight ends pin the table: `C[0] = 2^53` and `C[22] = 4`, so at `e = 22` only odd parts 1 and 3
// survive (`dom_exact_scale(3, 22)` is true, `(5, 22)` false).
@(rodata)
DOM_MANT_MAX5: [23]u64 = {
	9007199254740992, 1801439850948199, 360287970189640, 72057594037928,
	14411518807586, 2882303761518, 576460752304, 115292150461, 23058430093,
	4611686019, 922337204, 184467441, 36893489, 7378698, 1475740, 295148,
	59030, 11806, 2362, 473, 95, 19, 4,
}

// What `el_settle` decides a token from: a significand `m` of at most 19 digits, its decimal exponent `e`,
// and whether a nonzero digit was dropped past it (`nz`).
EL_Facts :: struct {
	m:  u64,
	e:  i64,
	nz: bool,
}

// The wide accumulator: `el_decode`'s three facts for a token whose significand does not fit the
// 19 digits `mant` holds.
//
// It is not the walk's fold with a bigger cap: `digit_run` folds the fraction run from its first
// digit, while `el_decode` skips the fraction's leading zeros without spending budget. They
// differ when the budget runs out inside a fraction that opens with zeros: for
// `0.0000000000000000000123` the fold's first 19 digits leave `mant == 0`, `el_decode`'s are
// `123`.
//
// Bounds are `el_decode`'s: `q < 2^31` is the caller's guard, `m` stays under 10^19 so
// `m * 10^k + v` cannot wrap, and `m == 0` means every significant digit was zero, answered by
// the caller as an authored zero.
dom_acc_wide :: #force_inline proc(
	src: []byte,
	int_at: u64,
	int_digits: u64,
	frac_at: u64,
	frac_digits: u64,
	exp: i64,
	out: ^EL_Facts,
) {
	#no_bounds_check {
		sig_int := int_digits
		if src[int_at] == '0' {
			// The lone leading zero costs no budget slot and adds nothing to `frac_kept`.
			sig_int = 0
		}
		fold_int := min(sig_int, u64(EL_MAX_DIGITS))
		m := fold_run(0, src, int_at, fold_int)
		room := u64(EL_MAX_DIGITS) - fold_int
		// Integer digits past the cap, each a power of ten.
		dropped_int := i64(sig_int - fold_int)
		nz := digits_nonzero(src, int_at + fold_int, sig_int - fold_int)
		// The fraction's leading zeros are skipped only when the integer part was the lone '0',
		// which is the whole reach of `el_decode`'s prefix: on `1.0000000000000000000001` every
		// fraction zero spends budget, `m` becomes `10^18` and the last digit sets the bracket.
		// Skipping those zeros too would fold `11` and answer a different number.
		lz := u64(0)
		if sig_int == 0 {
			for lz < frac_digits && src[frac_at + lz] == '0' {
				lz += 1
			}
		}
		frac_kept := i64(lz)
		fold_frac := min(frac_digits - lz, room)
		// `m` holds at most 19 - fold_frac digits here, so this cannot wrap.
		m = fold_run(m, src, frac_at + lz, fold_frac)
		frac_kept += i64(fold_frac)
		// The rest of the fraction is past the cap: it can only move the bracket.
		nz = nz || digits_nonzero(src, frac_at + lz + fold_frac, frac_digits - lz - fold_frac)
		out^ = EL_Facts{m = m, e = dropped_int - frac_kept + exp, nz = nz}
	}
}

// `m` followed by the `n` digits at `src[at:]`, folded eight at a time.
@(private = "file")
fold_run :: #force_inline proc(m: u64, src: []byte, at, n: u64) -> u64 #no_bounds_check {
	m, j := m, u64(0)
	for n - j >= 8 {
		m = m * 10000_0000 + digits8_value(load8_le(src, at + j))
		j += 8
	}
	for j < n {
		m = m * 10 + u64(src[at + j] - '0')
		j += 1
	}
	return m
}

// Whether any of the `n` digits at `src[at:]` is nonzero: digits past the cap only move the bracket.
@(private = "file")
digits_nonzero :: #force_inline proc(src: []byte, at, n: u64) -> bool {
	for k in 0 ..< n {
		if src[at + k] != '0' {
			return true
		}
	}
	return false
}

// The SWAR decimal-digit primitives, shared by `digit_run` and `dom_acc_wide`.
//
// Byte order is load-bearing: `src[p]` must be the low byte so byte 0 is the most significant
// digit. A big-endian target would fold the digits in reverse with self-consistent arithmetic,
// so it refuses to compile.
when ODIN_ENDIAN != .Little {
	#panic("json/scan: digits8_value requires a little-endian target")
}

// Eight bytes at `src[p..]` as one little-endian word. The load is unaligned and requires
// `p + 8 <= hi <= len(src)`.
load8_le :: #force_inline proc(src: []byte, p: u64) -> u64 {
	#no_bounds_check {
		return intrinsics.unaligned_load((^u64)(&src[p]))
	}
}

// Eight ASCII digits held in `w` (byte 0 = most significant) as the integer
// they write, 0 .. 99_999_999.
//
//   w &= 0x0F0F..0F        keep each digit's low nibble, drop the ASCII bias
//   w  = w * 2561 >> 8     every pair of nibbles becomes d_i*10 + d_{i+1}
//   w &= 0x00FF00FF..      keep bytes 0,2,4,6 -- the four pair values
//   w  = w * (1 + 100<<16) >> 16   pairs of pairs become d*100 + d
//   result = q0 * 10000 + q1        the two quads
//
// `2561 == 256*10 + 1` carries the low digit into the high one. The masks are exact because every
// pair is < 100 and every quad < 10000, so neither spills into the next field.
digits8_value :: #force_inline proc(w: u64) -> u64 {
	hi, lo := digits8_quads(w & 0x0F0F_0F0F_0F0F_0F0F)
	return hi * 10000 + lo
}

// `digits8_value` of a word whose lanes are already digit values 0..9, as its two four-digit
// halves (`q0`, `q1`).
digits8_quads :: #force_inline proc(v: u64) -> (hi, lo: u64) {
	v := v
	v = (v * 2561) >> 8
	v &= 0x00FF_00FF_00FF_00FF
	v = (v * (1 + (100 << 16))) >> 16
	return v & 0xFFFF, (v >> 32) & 0xFFFF
}

// Whether the walk's fold of `nd` significand digits is the significand itself. The fold wraps
// past 19 digits, so this says whether `mant` holds it at all. It is evaluated once both runs are
// counted.
//
// Correct only because RFC 8259 forbids leading zeros (`parse_number_q` refuses a second digit
// after a leading `0`): a leading zero would make the count an undercount and let a truncated
// mantissa pass for the significand.
DOM_MAYBE_EXACT :: #force_inline proc(nd: u64) -> bool {
	return nd <= EL_MAX_DIGITS
}
