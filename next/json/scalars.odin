package json

import "base:intrinsics"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The end and spelling of the number at `p`, which starts with `-` or a digit, or the fault and the byte it is at. The
// spelling is 0 unless `SPELLED`.
@(private)
number :: #force_inline proc "contextless" (p, end: [^]u8, $SPELLED: bool) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) #no_bounds_check {
	q = p
	if q[0] == '-' {
		q = q[1:]
		if q >= end {
			return end, 0, .Truncated
		}
	}
	int_at := q
	if q[0] == '0' {
		q = q[1:]
		if q < end && q[0] - '0' < 10 {
			return q, 0, .Bad_Number
		}
	} else {
		r := spell.digit_end(q, end)
		if r == q {
			return q, 0, .Bad_Number
		}
		q = r
	}
	int_digits := u64(intrinsics.ptr_sub(q, int_at))
	if q >= end {
		return q, digit_spelling(int_digits, 0, SPELLED), .None
	}
	frac_digits: u64
	c := q[0]
	if c == '.' {
		r := spell.digit_end(q[1:], end)
		if r == q[1:] {
			q, kind = bad_or_truncated(r, end)
			return q, 0, kind
		}
		frac_digits = u64(intrinsics.ptr_sub(r, q[1:]))
		q = r
		if q >= end {
			return q, digit_spelling(int_digits, frac_digits, SPELLED), .None
		}
		c = q[0]
	}
	if c | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := spell.digit_end(q, end)
		if r == q {
			q, kind = bad_or_truncated(r, end)
			return q, 0, kind
		}
		return r, digit_spelling(int_digits, frac_digits, SPELLED) | (tape.NUMBER_EXP when SPELLED else 0), .None
	}
	return q, digit_spelling(int_digits, frac_digits, SPELLED), .None
}

// A plain decimal's spelling, 0 unless `SPELLED`.
@(private)
digit_spelling :: #force_inline proc "contextless" (int_digits, frac_digits: u64, $SPELLED: bool) -> u16 {
	when SPELLED {
		return tape.number_spelling(0, int_digits, frac_digits)
	} else {
		return 0
	}
}

@(private)
bad_or_truncated :: #force_inline proc "contextless" (q, end: [^]u8) -> ([^]u8, tape.Fault_Kind) {
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Number
}

@(private)
TRUE_WORD :: u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24
@(private)
NULL_WORD :: u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24
@(private)
FALS_WORD :: u32('f') | u32('a') << 8 | u32('l') << 16 | u32('s') << 24

// One past the literal at `p`, whose first byte is `t`, `f` or `n`, and its kind; nil for no literal.
@(private)
literal :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: tape.Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) < 5 {
		if intrinsics.ptr_sub(end, p) == 4 {
			switch u32(intrinsics.unaligned_load((^u32le)(p))) {
			case TRUE_WORD:
				return p[4:], .True
			case NULL_WORD:
				return p[4:], .Null
			}
		}
		return nil, .Null
	}
	w := u32(intrinsics.unaligned_load((^u32le)(p)))
	n := (u64(w == TRUE_WORD) | u64(w == NULL_WORD)) << 2 | (u64(w == FALS_WORD) & u64(p[4] == 'e')) * 5
	if n == 0 {
		return nil, .Null
	}
	c := p[0]
	return p[n:], .True if c == 't' else (.False if c == 'f' else .Null)
}

// The fault of a literal that `literal` refused, at the first byte that breaks its word.
@(private, cold)
literal_fault :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: tape.Fault_Kind) #no_bounds_check {
	word := "true" if p[0] == 't' else ("false" if p[0] == 'f' else "null")
	for i in 0 ..< len(word) {
		q = p[i:]
		if q >= end {
			return end, .Truncated
		}
		if q[0] != word[i] {
			return q, .Bad_Char
		}
	}
	return p[len(word):], .Bad_Char
}
