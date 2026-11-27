package cbor

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

@(private)
ascii_16 :: #force_inline proc "contextless" (src: []u8, q, n: u64) -> bool {
	return spell.ascii_16(src, q, n)
}

@(private)
text_scan :: #force_inline proc "contextless" (src: []u8, q, n: u64, tolerate: bool) -> (bad: int, lax: bool) {
	return spell.text_scan(src, q, n, tolerate)
}

@(private)
text_fault :: #force_inline proc "contextless" (src: []u8, q, n: u64, tolerate: bool) -> (bad: int, lax: bool) {
	return spell.text_fault(src, q, n, tolerate)
}
