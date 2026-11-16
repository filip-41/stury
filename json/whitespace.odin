package json

import "base:intrinsics"
import "core:simd"
import kernel "../core/kernel"
import core "../core"

// Reads whitespace, a `:`, and whitespace, and returns where the member's value starts. Returns `end` and
// `Truncated` when the text ends first, or the byte that is no colon and `Bad_Char`.
@(private)
colon :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) {
	q = kernel.skip_ws(p, end)
	if q >= end {
		return end, .Truncated
	}
	if q[0] != ':' {
		return q, .Bad_Char
	}
	return kernel.skip_ws(q[1:], end), .None
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
// `indent_lead` starts its load at `LEAD_MAX - k` to mask the first `k` bytes.
@(private)
LEAD_MAX :: 32
@(private, rodata)
LEAD_MASK := [2 * LEAD_MAX]u8{0 ..< LEAD_MAX = 0xff}

// `ind` holds the last indent's first byte in bits 0 to 7, its byte count in bits 8 to 31, and the step per level in
// bits 32 and up. A prediction is that indent byte repeated, which is always whitespace, so a wrong one only misses.
// `INDENT_START` predicts spaces.
@(private)
INDENT_START :: u64(' ')

// Returns the byte after the whitespace at `p` when that is no whitespace, one space, or an LF or a CRLF and the indent
// `at` predicts. Returns nil for any other run, which `skip_indent` then reads.
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
		// A single space before the token, as a compact document writes after a comma or a pretty printer after a
		// colon, is whitespace. Only a line end moves the indent.
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

// `skip_indent` is `skip_ws` that also predicts and records the indent after a line end, an LF or a CRLF. A missed
// prediction counts the indent `n`, and `at` `.Open` sets the step to `n` minus the last indent. Returns the first byte past the
// whitespace.
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

// Returns the token after the indent `at` predicts at `line`, the first byte of a line, or nil when the indent is
// not that one. The caller guarantees that `LEAD_MAX` bytes at `line` are in the text.
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

// Whether the `k` bytes at `p` are all `b`. The caller guarantees `k < LEAD_MAX` and that `LEAD_MAX` bytes at `p` are
// in the text.
@(private)
indent_lead :: #force_inline proc "contextless" (p: [^]u8, k: u64, b: u8) -> bool #no_bounds_check {
	m := ([^]u8)(&LEAD_MASK[LEAD_MAX - k])
	x := simd.bit_and(simd.bit_xor(kernel.load16(p), V(b)), kernel.load16(m))
	y := simd.bit_and(simd.bit_xor(kernel.load16(p[16:]), V(b)), kernel.load16(m[16:]))
	return kernel.all_zero(simd.bit_or(x, y))
}
