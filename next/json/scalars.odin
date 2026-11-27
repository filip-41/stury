package json

import "base:intrinsics"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// `tape.number_scan` as the walk of hook `H` reads it: spelled unless `H` reads no hooks or no number's spelling.
@(private)
hook_number :: #force_inline proc "contextless" (p, end: [^]u8, $H: typeid, $C: hook.Capabilities, $S: Spec) -> (q: [^]u8, spelling: u16, kind: tape.Fault_Kind) {
	wide: u64
	q, wide, kind = tape.number_scan(p, end, H != hook.No_Hooks && .Unspelled not_in C, S == .Json5)
	return q, u16(wide), kind
}

@(private)
TRUE_WORD :: u32('t') | u32('r') << 8 | u32('u') << 16 | u32('e') << 24
@(private)
NULL_WORD :: u32('n') | u32('u') << 8 | u32('l') << 16 | u32('l') << 24
@(private)
FALS_WORD :: u32('f') | u32('a') << 8 | u32('l') << 16 | u32('s') << 24

// One past the literal at `p`, whose first byte is `t`, `f` or `n`, and its kind, or nil for no literal.
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
