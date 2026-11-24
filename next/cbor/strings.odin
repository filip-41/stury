package cbor

import "base:intrinsics"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The strings of an item: byte and text strings, whole or in chunks, and the UTF-8 of their text.

// A string item read: where it ends, its span, spelling and fault.
@(private)
Str :: struct {
	end:      u64,
	lo, n:    u64,
	spelling: u16,
	fault:    hook.Walk_Result,
	// Of a read of chunks that ran past the bytes: the head of the chunk it stopped at, and whether the chunks before it
	// took a tolerance, which a read that goes on from there is given.
	resume:   u64,
	lax:      bool,
}

// Reads the byte or text string of `major` at `i`, definite or in chunks, and judges its text. The chunks are read from
// the one at `from`, after `lax` chunks that took a tolerance, as a read in pieces goes on past the chunks it judged.
@(private)
string_item :: proc "contextless" (src: []u8, i: u64, major: u8, tolerate: bool, from: u64 = 0, lax0 := false) -> (s: Str) {
	n := u64(len(src))
	ai := src[i] & 31
	if ai == 31 {
		pos := max(from, i + 1)
		lax := lax0
		for {
			if pos >= n {
				s.fault, s.resume, s.lax = fault(n, .Truncated), pos, lax
				return
			}
			if src[pos] == 0xff {
				break
			}
			cai := src[pos] & 31
			if src[pos] >> 5 != major || cai > 27 {
				s.fault = fault(pos, .Bad_Char, .Bad_Chunk)
				return
			}
			arg, hl, ok := read_head(src, pos, cai)
			if !ok || arg > n - pos - hl {
				s.fault, s.resume, s.lax = fault(n, .Truncated), pos, lax
				return
			}
			if major == 3 {
				bad, tolerated := text_fault(src, pos + hl, arg, tolerate)
				if bad >= 0 {
					s.fault = fault(pos + hl + u64(bad), .Bad_Char, .Invalid_Utf8)
					return
				}
				lax ||= tolerated
			}
			pos += hl + arg
		}
		if pos - (i + 1) > u64(max(u32)) {
			s.fault = fault(i, .Too_Wide)
			return
		}
		s.lo, s.n, s.end = i + 1, pos - i - 1, pos + 1
		s.spelling = tape.SPELLING_DECODE | STR_INDEF | head_spelling(1)
		if lax {
			s.spelling |= tape.SPELLING_LAX
		}
		return
	}
	if ai > 27 {
		s.fault = fault(i, .Bad_Char, .Reserved_Info)
		return
	}
	arg, hl, ok := read_head(src, i, ai)
	if !ok || arg > n - i - hl {
		s.fault = fault(n, .Truncated)
		return
	}
	if arg > u64(max(u32)) {
		s.fault = fault(i, .Too_Wide)
		return
	}
	s.lo, s.n, s.end, s.spelling = i + hl, arg, i + hl + arg, head_spelling(hl)
	if major == 3 {
		bad, lax := text_fault(src, s.lo, arg, tolerate)
		if bad >= 0 {
			s.fault = fault(i + hl + u64(bad), .Bad_Char, .Invalid_Utf8)
		} else if lax {
			s.spelling |= tape.SPELLING_DECODE | tape.SPELLING_LAX
		}
	}
	return
}

// Where the indefinite string of `major` at `i` ends, when it is one chunk of up to 23 bytes that is bytes or ASCII text
// and the chunk and the break lie within the bytes, else 0, for `string_item` to read.
@(private)
one_chunk :: #force_no_inline proc "contextless" (src: []u8, i: u64, major: u8) -> u64 #no_bounds_check {
	head := i + 1
	if head + 25 > u64(len(src)) {
		return 0
	}
	h := src[head]
	arg := u64(h & 31)
	if h >> 5 != major || arg > 23 || src[head + 1 + arg] != 0xff {
		return 0
	}
	if major == 3 && !ascii_16(src, head + 1, arg) {
		return 0
	}
	return head + arg + 2
}

// Whether the `n` bytes at `q` are ASCII by 16-byte loads: one masked load for `n` up to 16, which needs 16 bytes left
// at `q`, else loads that overlap at the end, for `n` up to `ASCII_RUN_MAX`. A false is no fault: `text_fault` then
// judges them.
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

// The longest text `ascii_16` judges in its own loads, past which the kernel's blocks are cheaper than the loop.
@(private)
ASCII_RUN_MAX :: 128

// Judges the `n` bytes of text at `q` as UTF-8. Returns the offset of the first ill-formed byte, or -1, and whether a
// tolerated ill-formed sequence was passed. Only text the kernel refuses is read a sequence at a time, to find the
// fault.
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

// `text_scan` after the ASCII test, which a text of up to `ASCII_RUN_MAX` bytes passes with no call.
@(private)
text_fault :: #force_inline proc "contextless" (src: []u8, q, n: u64, tolerate: bool) -> (bad: int, lax: bool) {
	if ascii_16(src, q, n) {
		return -1, false
	}
	return text_scan(src, q, n, tolerate)
}
