package number

// JSON number lexing: the strict and the skip leaf, and the digit-run fold.

import "base:intrinsics"
import lex "../lex"

@(rodata)
DIGIT8_POW10: [9]u64 = {
	1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000,
}

// High bit set in the first lane that is not an ASCII digit. A borrow or a
// carry moves toward higher bytes, so later lanes may be spurious. The first
// set lane is the first non-digit. `m == 0` means eight digits.
//
// A lane below '0' borrows into bit 7, one in ':' ..= 0xB9 carries into it, and one from 0xBA up keeps it
// through the subtraction. A digit lane with no borrow or carry from below sets neither. Only a non-digit
// lane below sends one up, so the first set lane needs no third term for the high bytes.
digit8_gap :: #force_inline proc(w: u64) -> u64 {
	return ((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
}

// End of the digit run at `p`. The 8-byte load runs only while eight bytes remain. The tail, and
// the whole run under `lex.SCAN_FORCE_SLOW`, is scalar.
//
// When `$fold`, the same words fold the run into `mant`, continuing what it holds. The fold has
// no cap: past 19 digits `mant` wraps and the caller's digit count says so. A k-digit head is
// `digits8_value` of the word shifted up by `64 - 8k` bits. The shift is taken in two steps so
// `k == 0` shifts the whole word out and folds nothing, with no branch on `k`.
digit_run :: #force_inline proc(src: []byte, p: u64, mant: ^u64, $fold: bool) -> u64 {
	n := u64(len(src))
	q := p
	when !lex.SCAN_FORCE_SLOW {
		#no_bounds_check {
			for q + 8 <= n {
				w := load8_le(src, q)
				m := digit8_gap(w)
				if m != 0 {
					// The gap's lowest set bit is lane k's bit 7, so `~tz & 0x38` is `56 - 8k`.
					tz := intrinsics.count_trailing_zeros(m)
					k := tz >> 3
					when fold {
						mant^ = mant^ * DIGIT8_POW10[k] + digits8_value((w << (~tz & 0x38)) << 8)
					}
					return q + k
				}
				when fold {
					mant^ = mant^ * DIGIT8_POW10[8] + digits8_value(w)
				}
				q += 8
			}
		}
	}
	#no_bounds_check {
		for q < n {
			d := src[q]
			if d < '0' || d > '9' {
				break
			}
			when fold {
				mant^ = mant^ * 10 + u64(d - '0')
			}
			q += 1
		}
	}
	return q
}

// A required element is missing: truncation if the input simply ended (more bytes could still
// complete the token), otherwise the stopping byte is the fault.
@(private = "file")
bad_or_truncated :: #force_inline proc(s: ^Scanner) -> Maybe(Error) {
	n := u64(len(s.src))
	if s.pos >= n {
		return Error{offset = n, kind = .Truncated}
	}
	return Error{offset = s.pos, kind = .Bad_Number}
}

// Strict RFC 8259 number extent, recording the token's facts as it goes. Malformed numbers are
// Bad_Number. Over-cap scalars are Limit_Digits/Limit_Scale at the token. Under `.Shape` the integer and
// fraction runs fold into one `mant`, exact when they total at most 19 digits, kept with the token's other
// facts in `Shape_Run.num`. A `.Nodes` or `.Dom` row keeps the two runs' digit counts and no value
// (`emit_number`). An over-cap integer run is Limit_Digits at `start` before '.' / 'e' / EOF are examined.
// A leading zero is Bad_Number at the second digit.
parse_number_q :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	start: u64,
	$Q: bit_set[Walk_Kind],
) -> Maybe(Error) {
	#no_bounds_check {
		src := s.src
		n := u64(len(src))
		p := s.pos
		// The shape walk decodes the value from the folded digits (`Shape_Number`).
		FOLD :: .Shape in Q
		// `s.pos` is the walk's dispatch byte for this number, which `peek` proved is in `src`.
		if src[p] == '-' {
			p += 1
			if p >= n {
				return Error{offset = n, kind = .Truncated}
			}
		}
		int_at := p
		mant: u64
		if src[p] == '0' {
			// A leading zero is the whole integer part.
			p += 1
			if p < n && lex.is_digit(src[p]) {
				return Error{offset = p, kind = .Bad_Number}
			}
		} else {
			p = digit_run(src, p, &mant, FOLD)
			if p == int_at {
				return Error{offset = p, kind = .Bad_Number}
			}
		}
		int_digits := p - int_at
		if int_digits > s.limits.max_scalar_digits {
			return Error{offset = start, kind = .Limit_Digits}
		}
		// `c | 0x20 == 'e'` holds for 'e' and 'E' and no other byte.
		c: byte = src[p] if p < n else 0
		if c != '.' && c | 0x20 != 'e' {
			s.pos = p
			when .Shape in Q {
				q.shape.num = {mant, int_digits, 0, 0}
			}
			emit_number(q, Q, start, p, number_digits_pack(int_digits, 0))
			return nil
		}
		frac_at := p
		frac_digits: u64
		has_frac := c == '.'
		if has_frac {
			p += 1
			frac_at = p
			p = digit_run(src, p, &mant, FOLD)
			frac_digits = p - frac_at
			if frac_digits == 0 {
				s.pos = p
				return bad_or_truncated(s)
			}
			// The digit budget spans int + frac digits, checked before the exponent.
			if int_digits + frac_digits > s.limits.max_scalar_digits {
				s.pos = p
				return Error{offset = start, kind = .Limit_Digits}
			}
			c = src[p] if p < n else 0
		}
		// The scale cap needs both the fraction digits and the exponent.
		exp: i128
		has_exp := c | 0x20 == 'e'
		if has_exp {
			p += 1
			exp_neg := false
			if p < n && (src[p] == '+' || src[p] == '-') {
				exp_neg = src[p] == '-'
				p += 1
			}
			exp_start := p
			// The exponent magnitude is clamped one past the scale cap, which is all the cap asks,
			// so i128 cannot overflow however many digits arrive.
			exp_mag: i128
			sat := i128(s.limits.max_scalar_scale) + 1
			for p < n && lex.is_digit(src[p]) {
				if exp_mag <= sat {
					exp_mag = exp_mag * 10 + i128(src[p] - '0')
				}
				if exp_mag > sat {
					exp_mag = sat
				}
				p += 1
			}
			s.pos = p
			if p == exp_start {
				return bad_or_truncated(s)
			}
			cap_scale := i128(s.limits.max_scalar_scale)
			if exp_mag > cap_scale {
				return Error{offset = start, kind = .Limit_Scale}
			}
			exp = exp_neg ? -exp_mag : exp_mag
			scale := i128(frac_digits) - exp
			if scale > cap_scale || scale < -cap_scale {
				return Error{offset = start, kind = .Limit_Scale}
			}
		} else if frac_digits > s.limits.max_scalar_scale {
			// No exponent: the scale is the fraction's digit count.
			s.pos = p
			return Error{offset = start, kind = .Limit_Scale}
		}
		s.pos = p
		when .Shape in Q {
			q.shape.num = {mant, int_digits, frac_digits, i64(exp)}
		}
		emit_number(q, Q, start, p, number_digits_pack(int_digits, frac_digits))
		return nil
	}
}

// The end of the integer at `v` that `parse_number_q` accepts with no fraction or exponent, a digit 1-9 and
// at most 15 more within `max_digits`. It is not `ok` for any other token, a refusal included, which is
// `parse_number_q`'s to judge. It checks a number nothing reads without the digit loop.
plain_int_end :: #force_inline proc(src: []byte, v, max_digits: u64) -> (end: u64, ok: bool) #no_bounds_check {
	// Seventeen bytes, so the byte after sixteen digits is in `src` too.
	if v + 17 > u64(len(src)) || src[v] - '1' >= 9 {
		return
	}
	when ODIN_ARCH == .amd64 {
		// One 16-byte window: x86 has the movemask, and keeps no three 64-bit constants in registers here.
		// NEON keeps the words, since its lane count waits on a vector-to-scalar move.
		nine: #simd[16]u8 = 9
		zeros: #simd[16]u8 = '0'
		k := lex.first_stop_lane(intrinsics.simd_lanes_gt(lex.load16(src, v) - zeros, nine))
		if k == 16 {
			return
		}
		end = v + k
		stop := src[end]
		return end, (k <= max_digits) & (stop != '.') & (stop | 0x20 != 'e')
	}
	m0 := digit8_gap(load8_le(src, v))
	if m0 != 0 {
		end = v + u64(intrinsics.count_trailing_zeros(m0)) >> 3
	} else {
		m1 := digit8_gap(load8_le(src, v + 8))
		if m1 == 0 {
			return
		}
		end = v + 8 + u64(intrinsics.count_trailing_zeros(m1)) >> 3
	}
	t := src[end]
	return end, (end - v <= max_digits) & (t != '.') & (t | 0x20 != 'e')
}

// Number extent only: the maximal run of number chars, grammar unchecked.
skip_number_q :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	lo: u64,
	$Q: bit_set[Walk_Kind],
) -> Maybe(Error) {
	// Nothing is parsed, so the digit count stays zero, meaning "not checked". The extent is known, so a
	// `.Nodes` row is still emitted under `.Structural`.
	// `numchar4`, then an eight-digit load when four number chars were consumed and eight bytes
	// remain. Mixed tails stay on `numchar4`.
	for s.pos + 4 <= u64(len(s.src)) {
		k := lex.numchar4(s.src, s.pos)
		s.pos += k
		if k < 4 {
			break
		}
		for s.pos + 8 <= u64(len(s.src)) {
			if digit8_gap(load8_le(s.src, s.pos)) != 0 {
				break
			}
			s.pos += 8
			if s.pos + 4 > u64(len(s.src)) {
				k = 0
				break
			}
			k = lex.numchar4(s.src, s.pos)
			s.pos += k
			if k < 4 {
				break
			}
		}
		if k < 4 {
			break
		}
		if s.pos + 8 <= u64(len(s.src)) {
			k = lex.numchar4(s.src, s.pos)
			s.pos += k
			if k < 4 {
				break
			}
		} else {
			break
		}
	}
	for s.pos < u64(len(s.src)) && lex.CHAR_FLAGS[s.src[s.pos]] & lex.F_NUMCHAR != 0 {
		s.pos += 1
	}
	// No digit was read, so none is counted.
	emit_number(q, Q, lo, s.pos, 0)
	return nil
}
