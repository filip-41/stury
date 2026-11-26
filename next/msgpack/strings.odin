package msgpack

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// UTF-8 validation helpers for MessagePack strings (`fixstr`, `str 8/16/32`).

// Longest string scanned by `ascii_16` via unaligned 16-byte loads before deferring to the kernel.
@(private)
ASCII_RUN_MAX :: 128

// Returns true if the `n` bytes at `src[q:]` are ASCII using 16-byte loads.
@(private)
ascii_16 :: #force_inline proc "contextless" (src: []u8, q, n: u64) -> bool #no_bounds_check {
	if n > 16 {
		if n > ASCII_RUN_MAX {
			return false
		}
		p := raw_data(src)[q:]
		v := kernel.load16(p) | kernel.load16(p[n - 16:])
		for k := u64(16); k + 16 < n; k += 16 {
			v |= kernel.load16(p[k:])
		}
		return kernel.is_ascii16(v)
	}
	if q + 16 > u64(len(src)) {
		return false
	}
	v := kernel.load16(raw_data(src)[q:])
	return kernel.is_ascii16(v & kernel.live16(int(n)))
}

// Validates UTF-8 in `src[q:q + n]`, returning the offset of the first ill-formed byte or -1, and whether
// a tolerated ill-formed sequence was crossed.
@(private)
text_scan :: #force_no_inline proc "contextless" (src: []u8, q, n: u64, tolerate: bool) -> (bad: int, lax: bool) #no_bounds_check {
	text := src[q:q + n]
	if kernel.utf8_valid(text) {
		return -1, false
	}
	p := raw_data(text)
	end := p[len(text):]
	j := 0
	for j < len(text) {
		if text[j] < 0x80 {
			j += 1
			continue
		}
		r, kind := spell.utf8_char(p[j:], end)
		if kind != .None {
			if !tolerate {
				return j, false
			}
			lax = true
			r = spell.utf8_subpart(p[j:], end)
		}
		j = int(intrinsics.ptr_sub(r, p))
	}
	return -1, lax
}

// Fast-path `text_scan` preceded by `ascii_16`.
@(private)
text_fault :: #force_inline proc "contextless" (src: []u8, q, n: u64, tolerate: bool) -> (bad: int, lax: bool) {
	if ascii_16(src, q, n) {
		return -1, false
	}
	return text_scan(src, q, n, tolerate)
}
