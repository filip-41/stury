package json

import "base:intrinsics"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// The walk predicts each line's indent from the last one, as pretty printers indent a member one step deeper than its
// container. `ind` holds the step in its high 32 bits, the current indent in bits 8 to 31 and the indent byte, a space
// or a tab, in its low byte.

// The start of the value after a key's colon, with white space allowed around the colon, or the fault.
@(private)
colon :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: tape.Fault_Kind) {
	q = kernel.skip_ws(p, end)
	if q >= end {
		return end, .Truncated
	}
	if q[0] != ':' {
		return q, .Bad_Char
	}
	return kernel.skip_ws(q[1:], end), .None
}

// The place a line's indent is predicted at.
@(private)
Indent_At :: enum {
	Open, // after an open bracket, one step deeper
	Member, // between members, the same
	Close, // before a close, one step shallower
}

// The deepest indent the prediction compares.
@(private)
LEAD_MAX :: 32
@(private, rodata)
LEAD_MASK := [2 * LEAD_MAX]u8{0 ..< LEAD_MAX = 0xff}

@(private)
INDENT_START :: u64(' ')

// The first byte past the white space at `p` when it is none, one space, or a line break with the predicted indent; nil
// otherwise, for `skip_indent`.
@(private)
indent_fast :: #force_inline proc "contextless" (p, end: [^]u8, ind: ^u64, $at: Indent_At) -> [^]u8 #no_bounds_check {
	if p < end {
		c := p[0]
		if c > ' ' {
			return p
		}
		if intrinsics.ptr_sub(end, p) > LEAD_MAX && c == '\n' {
			if q := indent_predicted(p[1:], ind, at); q != nil {
				return q
			}
		}
		if c == ' ' && intrinsics.ptr_sub(end, p) > 1 && p[1] > ' ' {
			return p[1:]
		}
		if c == '\r' && intrinsics.ptr_sub(end, p) > LEAD_MAX + 1 && p[1] == '\n' {
			if q := indent_predicted(p[2:], ind, at); q != nil {
				return q
			}
		}
	}
	return nil
}

// The first byte past the white space at `p`, learning the indent of the line it ends on.
@(private)
skip_indent :: #force_inline proc "contextless" (p, end: [^]u8, ind: ^u64, $at: Indent_At) -> [^]u8 #no_bounds_check {
	line: [^]u8
	room := intrinsics.ptr_sub(end, p)
	if room > LEAD_MAX && p[0] == '\n' {
		line = p[1:]
	} else if room > LEAD_MAX + 1 && p[0] == '\r' && p[1] == '\n' {
		line = p[2:]
	}
	if line != nil {
		if q := indent_predicted(line, ind, at); q != nil {
			return q
		}
	}
	q := kernel.skip_ws(p, end)
	if line != nil {
		n := u64(intrinsics.ptr_sub(q, line))
		step := ind^ >> 32
		when at == .Open {
			step = n - ind^ >> 8 & 0xff_ffff
		}
		lead := ind^ & 0xff if n == 0 else u64(line[0])
		ind^ = (step & 0xffff_ffff) << 32 | (n & 0xff_ffff) << 8 | lead
	}
	return q
}

// The first byte of `line` past the predicted indent when the line has exactly that indent, else nil.
@(private)
indent_predicted :: #force_inline proc "contextless" (line: [^]u8, ind: ^u64, $at: Indent_At) -> [^]u8 #no_bounds_check {
	k := ind^ >> 8 & 0xff_ffff
	when at == .Open {
		k += ind^ >> 32
	} else when at == .Close {
		k -= ind^ >> 32 // wraps past LEAD_MAX when the indent is under a step, so the run is counted
	}
	if k < LEAD_MAX && indent_lead(line, k, u8(ind^)) && line[k] > ' ' {
		when at != .Member {
			ind^ = ind^ &~ 0xffff_ff00 | k << 8
		}
		return line[k:]
	}
	return nil
}

// Whether the first `k` bytes at `p` are all `b`.
@(private)
indent_lead :: #force_inline proc "contextless" (p: [^]u8, k: u64, b: u8) -> bool #no_bounds_check {
	m := ([^]u8)(&LEAD_MASK[LEAD_MAX - k])
	x := simd.bit_and(simd.bit_xor(kernel.load16(p), V(b)), kernel.load16(m))
	y := simd.bit_and(simd.bit_xor(kernel.load16(p[16:]), V(b)), kernel.load16(m[16:]))
	return kernel.all_zero(simd.bit_or(x, y))
}
