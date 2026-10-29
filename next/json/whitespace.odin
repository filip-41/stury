package json

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"

// Whitespace, the colon after a key, and whitespace: where the member's value starts.
@(private)
colon :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) {
	q = skip_ws(p, end)
	if q >= end {
		return end, .Truncated
	}
	if q[0] != ':' {
		return q, .Bad_Char
	}
	return skip_ws(q[1:], end), NO_FAULT
}

// JSON whitespace from `p` on: the first byte past it, or `end`. A short run is read byte by byte, a long one 64
// bytes at a time, in line: a call would make every state that skips whitespace save registers.
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

// Where a newline sits among the tokens, which a pretty printer's next indent follows: one step deeper after an
// open bracket, the same after a comma, one step out before a close bracket.
@(private)
Indent_At :: enum {
	Open,
	Member,
	Close,
}

// The widest indent `skip_indent` predicts, and the bytes it compares.
@(private)
LEAD_MAX :: 32
@(private, rodata)
LEAD_MASK := [2 * LEAD_MAX]u8{0 ..< LEAD_MAX = 0xff}

// The next token after the whitespace at `p` when it is none, or a newline and the indent `at` predicts: `ind^`
// holds the last indent in its low half and the step in its high half. Nil for any other run, which `skip_indent`
// then counts. Scalar only, so a state that holds it builds no vector on entry.
@(private)
indent_fast :: #force_inline proc "contextless" (p, end: [^]u8, ind: ^u64, $at: Indent_At) -> [^]u8 #no_bounds_check {
	if p < end && p[0] > ' ' {
		return p
	}
	if intrinsics.ptr_sub(end, p) > LEAD_MAX && p[0] == '\n' {
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
	return nil
}

// `skip_ws` that learns the indent after a newline for `indent_fast`, and after an open bracket the step.
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

// Whether the `k` bytes at `p` are spaces: `k < LEAD_MAX`, and LEAD_MAX bytes at `p` are in the text.
@(private)
spaces_lead :: #force_inline proc "contextless" (p: [^]u8, k: u64) -> bool #no_bounds_check {
	m := ([^]u8)(&LEAD_MASK[LEAD_MAX - k])
	acc: u64
	#unroll for i in 0 ..< LEAD_MAX / 8 {
		acc |= (intrinsics.unaligned_load((^u64)(p[8 * i:])) ~ 0x2020_2020_2020_2020) & intrinsics.unaligned_load((^u64)(m[8 * i:]))
	}
	return acc == 0
}
