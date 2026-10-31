package json

import "base:intrinsics"
import core "../core"

// Reads the number at `p`, which starts with `-` or a digit. Returns one past it and its `spelling`, or the fault's
// kind and the byte it is at. With `$shape` false the spelling is 0 and the digit counts are not counted, for a walk
// with no hook.
@(private)
number_run :: #force_inline proc "contextless" (p, end: [^]u8, $shape: bool) -> (q: [^]u8, spelling: u16, kind: core.Fault_Kind) #no_bounds_check {
	q = p
	if q[0] == '-' {
		q = q[1:]
		if q >= end {
			return end, 0, .Truncated
		}
	}
	when shape {
		int_at := q
	}
	if q[0] == '0' {
		q = q[1:]
		if q < end && q[0] - '0' < 10 {
			return q, 0, .Bad_Number
		}
	} else {
		r := core.digit_end(q, end, nil, false)
		if r == q {
			return q, 0, .Bad_Number
		}
		q = r
	}
	when shape {
		int_digits := u64(intrinsics.ptr_sub(q, int_at))
		frac_digits: u64
	}
	if q >= end {
		when shape {
			return q, number_spelling(.Json, int_digits, frac_digits), .None
		}
		return q, 0, .None
	}
	c := q[0]
	if c == '.' {
		r := core.digit_end(q[1:], end, nil, false)
		if r == q[1:] {
			q2, k2 := bad_or_truncated(r, end)
			return q2, 0, k2
		}
		when shape {
			frac_digits = u64(intrinsics.ptr_sub(r, q[1:]))
		}
		q = r
		if q >= end {
			when shape {
				return q, number_spelling(.Json, int_digits, frac_digits), .None
			}
			return q, 0, .None
		}
		c = q[0]
	}
	// `c | 0x20 == 'e'` is true for `e` and `E` and no other byte.
	if c | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := core.digit_end(q, end, nil, false)
		if r == q {
			q2, k2 := bad_or_truncated(r, end)
			return q2, 0, k2
		}
		when shape {
			return r, number_spelling_exp(.Json, int_digits, frac_digits), .None
		}
		q = r
	}
	when shape {
		return q, number_spelling(.Json, int_digits, frac_digits), .None
	}
	return q, 0, .None
}

// Calls `number_run` with `$shape` true for a hook and false for `core.No_Hooks`.
@(private)
number_h :: #force_inline proc "contextless" (p, end: [^]u8, $H: typeid) -> (q: [^]u8, spelling: u16, kind: core.Fault_Kind) {
	when H == core.No_Hooks {
		return number_run(p, end, false)
	} else {
		return number_run(p, end, true)
	}
}

@(private)
bad_or_truncated :: #force_inline proc "contextless" (q, end: [^]u8) -> ([^]u8, core.Fault_Kind) {
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Number
}

// The first four bytes of `true`, `null` and `false` as a little-endian `u32`.
@(private)
TRUE_WORD :: u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24
@(private)
NULL_WORD :: u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24
@(private)
FALS_WORD :: u32('f') | u32('a') << 8 | u32('l') << 16 | u32('s') << 24

// Reads the literal at `p`, which starts with `t`, `f` or `n`. Returns one past it and its kind, or nil and `.Null`
// when the bytes are no literal. Tests the three words with no branch on which one it is, since `true` and `false`
// alternate in a column of flags.
@(private)
literal :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) < 5 {
		return literal_short(p, end)
	}
	w := u32(intrinsics.unaligned_load((^u32le)(p)))
	n := (u64(w == TRUE_WORD) | u64(w == NULL_WORD)) << 2 | (u64(w == FALS_WORD) & u64(p[4] == 'e')) * 5
	if n == 0 {
		return nil, .Null
	}
	c := p[0]
	return p[n:], .True if c == 't' else (.False if c == 'f' else .Null)
}

// `literal_short` is `literal` when exactly 4 bytes remain in the text.
@(private)
literal_short :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Kind) #no_bounds_check {
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

// Reads `word` at `p`, which starts with the word's first letter. Returns one past it with `ok` true, or the first
// byte that differs with `ok` false, `end` when the text ends first.
@(private)
word_end :: #force_inline proc "contextless" (p, end: [^]u8, word: string) -> (q: [^]u8, ok: bool) #no_bounds_check {
	for i in 0 ..< len(word) {
		q = p[i:]
		if q >= end {
			return end, false
		}
		if q[0] != word[i] {
			return q, false
		}
	}
	return p[len(word):], true
}

// The fault for a literal `literal` refused. It is the first byte that breaks the word its first letter names, or
// `end` and `Truncated`.
@(private, cold)
literal_fault :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) {
	word := "null"
	if p[0] == 't' {
		word = "true"
	} else if p[0] == 'f' {
		word = "false"
	}
	ok: bool
	q, ok = word_end(p, end, word)
	if ok {
		unreachable()
	}
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Char
}
