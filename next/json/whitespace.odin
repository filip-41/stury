package json

import "base:intrinsics"
import "core:simd"
import core "../core"
import kernel "../core/kernel"

// Reads whitespace, a `:`, and whitespace, and returns where the member's value starts. Returns `end` and
// `Truncated` when the text ends first, or the byte that is no colon and `Bad_Char`.
@(private)
colon :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) {
	q = skip_ws(p, end)
	if q >= end {
		return end, .Truncated
	}
	if q[0] != ':' {
		return q, .Bad_Char
	}
	return skip_ws(q[1:], end), .None
}

// Returns the first byte at or past `p` that is no space, tab, CR or LF, or `end`. Reads up to four bytes one at a
// time, then 64-byte blocks, then the remaining bytes one at a time. Inlined into the states that skip whitespace,
// which would otherwise save registers for a call.
@(private)
skip_ws :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for _ in 0 ..< 4 {
		if q >= end || !is_ws(q[0]) {
			return q
		}
		q = q[1:]
	}
	for intrinsics.ptr_sub(end, q) >= 64 {
		b := kernel.load(q)
		ws := kernel.pack(kernel.either(kernel.either(kernel.eq(b, ' '), kernel.eq(b, '\n')), kernel.either(kernel.eq(b, '\t'), kernel.eq(b, '\r'))))
		if ws != max(u64) {
			return q[intrinsics.count_trailing_zeros(~ws):]
		}
		q = q[64:]
	}
	for q < end && is_ws(q[0]) {
		q = q[1:]
	}
	return q
}

@(private)
is_ws :: #force_inline proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\n' || c == '\r' || c == '\t'
}

// `Indent_At` names which token follows the whitespace, for `indent_fast`'s indent prediction. `Open` adds the indent
// step, `Member` keeps the indent, and `Close` subtracts the step.
@(private)
Indent_At :: enum {
	Open,
	Member,
	Close,
}

// The widest indent `skip_indent` predicts, 32 bytes. `LEAD_MASK` holds 32 bytes of 0xff then 32 of 0, and
// `spaces_lead` starts its load at `LEAD_MAX - k` to mask the first `k` bytes.
@(private)
LEAD_MAX :: 32
@(private, rodata)
LEAD_MASK := [2 * LEAD_MAX]u8{0 ..< LEAD_MAX = 0xff}

// Returns the byte after the whitespace at `p` when that is no whitespace, one space, or a newline and the indent
// `at` predicts. `ind^` holds the last indent in its low 32 bits and the step in its high 32. Returns nil for any
// other run, which `skip_indent` then counts. Uses no vector registers.
@(private)
indent_fast :: #force_inline proc "contextless" (p, end: [^]u8, ind: ^u64, $at: Indent_At) -> [^]u8 #no_bounds_check {
	if p < end {
		c := p[0]
		if c > ' ' {
			return p
		}
		if intrinsics.ptr_sub(end, p) > LEAD_MAX && c == '\n' {
			line := p[1:]
			cur, step := ind^ & 0xffff_ffff, ind^ >> 32
			k := cur
			when at == .Open {
				k += step
			} else when at == .Close {
				k -= step // wraps past LEAD_MAX when the indent is under a step, so the run is counted
			}
			if k < LEAD_MAX && spaces_lead(line, k) && line[k] > ' ' {
				ind^ = step << 32 | k
				return line[k:]
			}
		}
		// A single space before the token, as a compact document writes after a comma or a pretty printer after a
		// colon, is whitespace. Only a newline moves the indent.
		if c == ' ' && intrinsics.ptr_sub(end, p) > 1 && p[1] > ' ' {
			return p[1:]
		}
	}
	return nil
}

// `skip_indent` is `skip_ws` that also records the indent for `indent_fast`. After a newline, `n` is the indent's byte
// count, and `at` `.Open` sets the step to `n` minus the last indent. Returns the first byte past the whitespace.
@(private)
skip_indent :: #force_inline proc "contextless" (p, end: [^]u8, ind: ^u64, $at: Indent_At) -> [^]u8 #no_bounds_check {
	if q := indent_fast(p, end, ind, at); q != nil {
		return q
	}
	q := skip_ws(p, end)
	if intrinsics.ptr_sub(end, p) > LEAD_MAX && p[0] == '\n' {
		n := u64(intrinsics.ptr_sub(q, p)) - 1
		step := ind^ >> 32
		when at == .Open {
			step = n - ind^ & 0xffff_ffff
		}
		ind^ = (step & 0xffff_ffff) << 32 | n & 0xffff_ffff
	}
	return q
}

// Whether the `k` bytes at `p` are all spaces. The caller guarantees `k < LEAD_MAX` and that `LEAD_MAX` bytes at `p`
// are in the text. Uses `reduce_max` on the xor with `' '` because NEON reduces a max in one cross-lane instruction,
// where an OR folds through scalar shifts.
@(private)
spaces_lead :: #force_inline proc "contextless" (p: [^]u8, k: u64) -> bool #no_bounds_check {
	V :: #simd[16]u8
	m := ([^]u8)(&LEAD_MASK[LEAD_MAX - k])
	a := simd.bit_and(simd.bit_xor(intrinsics.unaligned_load((^V)(p)), V(' ')), intrinsics.unaligned_load((^V)(m)))
	b := simd.bit_and(simd.bit_xor(intrinsics.unaligned_load((^V)(p[16:])), V(' ')), intrinsics.unaligned_load((^V)(m[16:])))
	return simd.reduce_max(simd.bit_or(a, b)) == 0
}
