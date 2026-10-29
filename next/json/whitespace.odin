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
