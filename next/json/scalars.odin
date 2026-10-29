package json

import "base:intrinsics"
import core "../core"

// The number at `p`, which starts with `-` or a digit: one past it, or the fault's kind and the byte it is at.
@(private)
number :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	q = p
	if q[0] == '-' {
		q = q[1:]
		if q >= end {
			return end, .Truncated
		}
	}
	if q[0] == '0' {
		q = q[1:]
		if q < end && q[0] - '0' < 10 {
			return q, .Bad_Number
		}
	} else {
		r := digit_run(q, end)
		if r == q {
			return q, .Bad_Number
		}
		q = r
	}
	if q >= end {
		return
	}
	c := q[0]
	if c == '.' {
		r := digit_run(q[1:], end)
		if r == q[1:] {
			return bad_or_truncated(r, end)
		}
		q = r
		if q >= end {
			return
		}
		c = q[0]
	}
	// `c | 0x20 == 'e'` holds for `e` and `E` and no other byte.
	if c | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := digit_run(q, end)
		if r == q {
			return bad_or_truncated(r, end)
		}
		q = r
	}
	return
}

@(private)
bad_or_truncated :: #force_inline proc "contextless" (q, end: [^]u8) -> ([^]u8, core.Fault_Kind) {
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Number
}

// The end of the run of digits at `p`, eight bytes a word while eight remain.
@(private)
digit_run :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for intrinsics.ptr_sub(end, q) >= 8 {
		w := intrinsics.unaligned_load((^u64le)(q))
		// Bit 7 of each byte that is not a digit: below '0' borrows, above '9' carries past 0x7F.
		gap := u64((w - 0x3030_3030_3030_3030) | (w + 0x4646_4646_4646_4646)) & 0x8080_8080_8080_8080
		if gap != 0 {
			return q[intrinsics.count_trailing_zeros(gap) >> 3:]
		}
		q = q[8:]
	}
	for q < end && q[0] - '0' < 10 {
		q = q[1:]
	}
	return q
}

// The literal at `p`, which starts with `t`, `f` or `n`: one past it and its kind, or nil when it is not one. No
// branch on which word it is, since `true` and `false` alternate at random in a column of flags.
@(private)
literal :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Kind) #no_bounds_check {
	TRUE :: u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24
	NULL :: u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24
	FALS :: u32('f') | u32('a') << 8 | u32('l') << 16 | u32('s') << 24
	if intrinsics.ptr_sub(end, p) < 5 {
		return literal_short(p, end)
	}
	w := u32(intrinsics.unaligned_load((^u32le)(p)))
	n := (u64(w == TRUE) | u64(w == NULL)) << 2 | (u64(w == FALS) & u64(p[4] == 'e')) * 5
	if n == 0 {
		return nil, .Null
	}
	c := p[0]
	return p[n:], .True if c == 't' else (.False if c == 'f' else .Null)
}

// `literal` within the last four bytes of the text.
@(private)
literal_short :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) == 4 {
		switch u32(intrinsics.unaligned_load((^u32le)(p))) {
		case u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24:
			return p[4:], .True
		case u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24:
			return p[4:], .Null
		}
	}
	return nil, .Null
}

// A literal `literal` refused: the first byte that breaks the word its first letter names, or `Truncated`.
@(private, cold)
literal_fault :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) {
	word := "null"
	if p[0] == 't' {
		word = "true"
	} else if p[0] == 'f' {
		word = "false"
	}
	for i in 0 ..< len(word) {
		q = p[i:]
		if q >= end {
			return end, .Truncated
		}
		if q[0] != word[i] {
			return q, .Bad_Char
		}
	}
	unreachable()
}
