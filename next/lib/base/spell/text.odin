package spell

import "base:intrinsics"
import "stury:lib/base/kernel"

// Why a text failed to parse. Exceeded budget limits and failed allocations are not faults.
Fault_Kind :: enum u8 {
	None,
	Truncated, // the text ends inside a construct, or a quoted cell never closes
	Bad_Char, // a byte that cannot continue the text, or invalid UTF-8
	Bad_Escape, // an undefined escape, or a lone surrogate half
	Bad_Number, // the byte that breaks a number
	Too_Wide, // a token wider than 32 bits, or a record past its size limit
	Bad_Width, // a record wider or narrower than the first
	Duplicate_Key, // a repeated key under a refusing duplicate policy
	Refused, // a value a typed read's type does not take, which its detail names
}

// Scans one UTF-8 character or maximal ill-formed subpart starting at `p`, where `p < end` and `p[0] >= 0x80`.
// Returns one past the character with `.None`, `end` with `.Truncated` when the text ends inside a valid prefix, or
// one past the maximal subpart with `.Bad_Char`.
@(private = "file", require_results)
utf8_scan_one :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: Fault_Kind) {
	c := p[0]
	if c < 0xc2 || c > 0xf4 {
		return p[1:], .Bad_Char
	}
	need := 2 if c < 0xe0 else 3 if c < 0xf0 else 4
	for i in 1 ..< need {
		if p[i:] >= end {
			return end, .Truncated
		}
		b := p[i]
		bad := b & 0xc0 != 0x80
		if i == 1 {
			bad ||= c == 0xe0 && b < 0xa0 || c == 0xed && b > 0x9f || c == 0xf0 && b < 0x90 || c == 0xf4 && b > 0x8f
		}
		if bad {
			return p[i:], .Bad_Char
		}
	}
	return p[need:], .None
}

// One past the UTF-8 character whose lead is at `p`, where `p < end` and `p[0] >= 0x80`, or `p` with `.Bad_Char` for a
// malformed sequence. A sequence the text cuts short gives `end` with `.Truncated` when every byte present could still
// continue it.
@(require_results)
utf8_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: Fault_Kind) {
	q, kind = utf8_scan_one(p, end)
	if kind == .Bad_Char {
		return p, .Bad_Char
	}
	return
}

// One past the maximal subpart of the ill-formed UTF-8 sequence at `p`, where `p < end`: its longest start that some
// well-formed sequence starts with, or its first byte when none does. A well-formed sequence at `p` returns one past
// the character. A decoder that replaces each ill-formed subpart with U+FFFD reads ill-formed text as Unicode's
// "substitution of maximal subparts" does.
@(require_results)
utf8_subpart :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q, _ := utf8_scan_one(p, end)
	return q
}

// The UTF-8 of U+FFFD, the replacement character.
REPLACEMENT :: [3]u8{0xEF, 0xBF, 0xBD}

// Copies the UTF-8 character whose lead `p[0]` is past ASCII to `out`, or writes U+FFFD there for the maximal subpart
// of an ill-formed sequence, and returns the bytes written, at most 4, and one past the bytes read. Caller guarantees
// `p < end` and `out` has room for at least `max(3, char_len)` writable bytes (4 bytes, or 3 bytes per remaining input
// byte).
@(require_results)
utf8_lax :: #force_inline proc "contextless" (p, end, out: [^]u8) -> (n: int, q: [^]u8) {
	kind: Fault_Kind
	if q, kind = utf8_scan_one(p, end); kind != .None {
		out[0], out[1], out[2] = REPLACEMENT[0], REPLACEMENT[1], REPLACEMENT[2]
		return 3, q
	}
	n = intrinsics.ptr_sub(q, p)
	out[0] = p[0]
	out[1] = p[1]
	if n >= 3 {
		out[2] = p[2]
		if n == 4 {
			out[3] = p[3]
		}
	}
	return
}

// The length of the UTF-8 byte order mark that starts `src`, 0 for none.
@(require_results)
bom_length :: #force_inline proc "contextless" (src: []u8) -> int {
	return 3 if len(src) >= 3 && src[0] == 0xEF && src[1] == 0xBB && src[2] == 0xBF else 0
}

// The end of the run of decimal digits at `p`. Caller guarantees `p <= end` with `[p, end)` readable.
@(require_results)
digit_end :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q := p
	for intrinsics.ptr_sub(end, q) >= 8 {
		w := kernel.load8(q)
		m := non_digit_bytes(w)
		if m != 0 {
			return q[intrinsics.count_trailing_zeros(m) >> 3:]
		}
		q = q[8:]
	}
	for q < end && q[0] - '0' < 10 {
		q = q[1:]
	}
	return q
}

// The end of the run of hex digits at `p`. Caller guarantees `p <= end` with `[p, end)` readable.
@(require_results)
hex_digit_end :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q := p
	for q < end && HEX_NIBBLE[q[0]] != 0xff {
		q = q[1:]
	}
	return q
}

// Whether byte `b` continues a UTF-8 character, which a character's lead byte does not.
@(require_results)
is_continuation :: #force_inline proc "contextless" (b: byte) -> bool {
	return b & 0xC0 == 0x80
}

// The bytes a walk by character steps over from `b` by its UTF-8 bit-prefix: `0xC0..0xDF` give 2, `0xE0..0xEF` give 3,
// `0xF0..0xF7` give 4, and every other byte (`0x00..0xBF`, `0xF8..0xFF`) gives 1.
@(require_results)
lead_width :: #force_inline proc "contextless" (b: byte) -> int {
	switch {
	case b < 0xC0:
		return 1
	case b < 0xE0:
		return 2
	case b < 0xF0:
		return 3
	case b < 0xF8:
		return 4
	}
	return 1
}

// The index of the first byte of the character that holds byte `i` of `s`, 0 when `i <= 0` or none starts at or before
// it, and `len(s)` when `i >= len(s)`.
@(require_results)
char_start :: #force_inline proc "contextless" (s: string, i: int) -> int {
	if i <= 0 {
		return 0
	}
	if i >= len(s) {
		return len(s)
	}
	i := i
	for i > 0 && is_continuation(s[i]) {
		i -= 1
	}
	return i
}

// The index of the first byte at or after `max(i, 0)` that is not a continuation byte, or `len(s)`.
@(require_results)
skip_continuations :: #force_inline proc "contextless" (s: string, i: int) -> int {
	j := max(i, 0)
	if j >= len(s) {
		return len(s)
	}
	for j < len(s) && is_continuation(s[j]) {
		j += 1
	}
	return j
}

// Longest string scanned by `ascii_16` via unaligned 16-byte loads before deferring to the kernel's block validator.
ASCII_RUN_MAX :: 128

// Whether the `n` bytes at `src[q:]` are ASCII using 16-byte loads: one masked load for `n <= 16` (requiring 16
// readable bytes from `q`), else overlapping loads up to `ASCII_RUN_MAX`. False is no fault: caller runs `text_scan`.
@(require_results)
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

// Judges the `n` bytes of text at `src[q:]` as UTF-8, returning the offset of the first ill-formed byte or -1, and
// whether a tolerated ill-formed sequence was crossed.
@(require_results)
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
		r, kind := utf8_char(p[j:], end)
		if kind != .None {
			if !tolerate {
				return j, false
			}
			lax = true
			r = utf8_subpart(p[j:], end)
		}
		j = int(intrinsics.ptr_sub(r, p))
	}
	return -1, lax
}

// `text_scan` preceded by the inline `ascii_16` fast path.
@(require_results)
text_fault :: #force_inline proc "contextless" (src: []u8, q, n: u64, tolerate: bool) -> (bad: int, lax: bool) {
	if ascii_16(src, q, n) {
		return -1, false
	}
	return text_scan(src, q, n, tolerate)
}
