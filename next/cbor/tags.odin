package cbor

import "stury:lib/base/spell"
import "stury:lib/core/hook"

// The content of a tag: the numbers tags 2 to 5 fold into one number, and the content tags 0, 1 and 24 hold.

// The offset `tag_content_fault` gives for a content that fits its tag.
@(private)
NO_FAULT :: max(u64)

// A number folded from a tag: where it ends, its spelling, or the fault.
@(private)
Folded :: struct {
	end:      u64,
	spelling: u16,
	fault:    hook.Walk_Result,
}

// Reads the content of tag 2 to 5 at `i`, a byte string or a pair of an exponent and a mantissa.
@(private)
folded :: proc "contextless" (src: []u8, i: u64, tag: u64, strict: bool) -> (r: Folded) {
	switch tag {
	case 2, 3:
		if src[i] >> 5 != 2 {
			r.fault = fault(i, .Bad_Char, .Bad_Tag_Content)
			return
		}
		s := string_item(src, i, 2, false)
		if s.fault != 0 {
			r.fault = s.fault
			return
		}
		if strict && (s.spelling & STR_INDEF != 0 || s.n <= 8 || src[s.lo] == 0) {
			r.fault = fault(i, .Bad_Char, .Not_Preferred)
			return
		}
		r.end, r.spelling = s.end, NUMBER_BIG_NEGATIVE if tag == 3 else NUMBER_BIG
	case:
		r.end, r.fault = decimal_item(src, i, strict)
		r.spelling = NUMBER_BIGFLOAT if tag == 5 else NUMBER_DECIMAL
	}
	return
}

// Reads the array of an exponent and a mantissa at `i` for tags 4 and 5.
@(private)
decimal_item :: proc "contextless" (src: []u8, i: u64, strict: bool) -> (end: u64, f: hook.Walk_Result) {
	n := u64(len(src))
	b := src[i]
	if b >> 5 != 4 || b & 31 > 27 && b & 31 != 31 {
		return 0, fault(i, .Bad_Char, .Bad_Tag_Content)
	}
	pos := i + 1
	indefinite := b & 31 == 31
	if !indefinite {
		arg, hl, ok := read_head(src, i, b & 31)
		if !ok {
			return 0, fault(n, .Truncated)
		}
		if arg != 2 {
			return 0, fault(i, .Bad_Char, .Bad_Tag_Content)
		}
		pos = i + hl
	} else if strict {
		return 0, fault(i, .Bad_Char, .Not_Preferred)
	}
	for part in 0 ..< 2 {
		if pos >= n {
			return 0, fault(n, .Truncated)
		}
		c := src[pos]
		mj := c >> 5
		switch {
		case mj <= 1 && c & 31 <= 27:
			arg, hl, ok := read_head(src, pos, c & 31)
			if !ok {
				return 0, fault(n, .Truncated)
			}
			if strict && !shortest(c & 31, arg) {
				return 0, fault(pos, .Bad_Char, .Not_Preferred)
			}
			pos += hl
		case mj == 6 && part == 1 && c & 31 <= 27:
			tag, hl, ok := read_head(src, pos, c & 31)
			if !ok {
				return 0, fault(n, .Truncated)
			}
			if tag != 2 && tag != 3 {
				return 0, fault(pos, .Bad_Char, .Bad_Tag_Content)
			}
			if pos + hl >= n {
				return 0, fault(n, .Truncated)
			}
			big := folded(src, pos + hl, tag, strict)
			if big.fault != 0 {
				return 0, big.fault
			}
			pos = big.end
		case:
			return 0, fault(pos, .Bad_Char, .Bad_Tag_Content)
		}
	}
	if indefinite {
		if pos >= n {
			return 0, fault(n, .Truncated)
		}
		if src[pos] != 0xff {
			return 0, fault(pos, .Bad_Char, .Bad_Tag_Content)
		}
		pos += 1
	}
	return pos, 0
}

// Judges the content at `i` of a tag the walk reads as a fact before its content. Returns the offset of the first byte
// that breaks the tag's meaning, or `NO_FAULT`: tag 0 holds a date-time text, tag 1 an integer or a float and tag 24 a
// byte string.
@(private)
tag_content_fault :: #force_inline proc "contextless" (src: []u8, i: u64, tag: u64) -> u64 {
	b := src[i]
	switch tag {
	case 0:
		return date_fault(src, i)
	case 1:
		if b >> 5 > 1 && b != 0xf9 && b != 0xfa && b != 0xfb {
			return i
		}
	case 24:
		if b >> 5 != 2 {
			return i
		}
	}
	return NO_FAULT
}

// `tag_content_fault` for tag 0, which holds a date-time text.
@(private)
date_fault :: #force_no_inline proc "contextless" (src: []u8, i: u64) -> u64 {
	b := src[i]
	if b >> 5 != 3 {
		return i
	}
	if b & 31 == 31 {
		return date_chunks_fault(src, i)
	}
	// A reserved head, or a text that runs past the bytes, is the item reader's to refuse.
	if b & 31 > 27 {
		return NO_FAULT
	}
	arg, hl, ok := read_head(src, i, b & 31)
	if ok && arg <= u64(len(src)) - i - hl {
		if !spell.is_date_time(string(src[i + hl:i + hl + arg])) {
			return i
		}
	}
	return NO_FAULT
}

// What `date_chunks_fault` keeps of the text of a date in chunks: its first bytes, and its last. A date-time text of
// more than `DATE_HEAD + DATE_TAIL` bytes holds a fraction, whose digits between them need no byte kept.
@(private)
DATE_HEAD :: 32
@(private)
DATE_TAIL :: 8

// `tag_content_fault` for tag 0 over the indefinite text at `i`: the chunks joined are judged as a definite text is,
// whatever their length. A chunk the item reader refuses, or a text that runs past the bytes, gives no fault here.
@(private)
date_chunks_fault :: proc "contextless" (src: []u8, i: u64) -> u64 {
	head: [DATE_HEAD]u8 = ---
	tail: [DATE_TAIL]u8 = ---
	n := 0 // the bytes joined
	between := true // the bytes past the head and before the tail are all digits
	pos := i + 1
	for pos < u64(len(src)) && src[pos] != 0xff {
		cai := src[pos] & 31
		if src[pos] >> 5 != 3 || cai > 27 {
			return NO_FAULT
		}
		arg, hl, ok := read_head(src, pos, cai)
		if !ok || arg > u64(len(src)) - pos - hl {
			return NO_FAULT
		}
		for b in src[pos + hl:][:arg] {
			if n < DATE_HEAD {
				head[n] = b
			} else {
				// The byte that leaves the tail is one of the bytes between.
				if n >= DATE_HEAD + DATE_TAIL {
					out := tail[n % DATE_TAIL]
					between &&= out >= '0' && out <= '9'
				}
				tail[n % DATE_TAIL] = b
			}
			n += 1
		}
		pos += hl + arg
	}
	if pos >= u64(len(src)) {
		return NO_FAULT
	}
	// A text of no more than head and tail is judged as it is, a longer one by its head and tail, whose middle is digits.
	joined: [DATE_HEAD + DATE_TAIL]u8 = ---
	m := min(n, DATE_HEAD)
	copy(joined[:], head[:m])
	if n > DATE_HEAD {
		kept := min(n - DATE_HEAD, DATE_TAIL)
		for k in 0 ..< kept {
			joined[m + k] = tail[(n - kept + k) % DATE_TAIL]
		}
		m += kept
	}
	if !between {
		return i
	}
	if !spell.is_date_time(string(joined[:m])) {
		return i
	}
	return NO_FAULT
}

// Whether the chunks of the date text at `q` run past the window before the break that ends them, so that the tag is
// read in a later window. A chunk the item reader refuses is judged now.
@(private)
date_chunks_open :: proc "contextless" (src: []u8, q: u64) -> bool {
	n := u64(len(src))
	pos := q + 1
	for pos < n && src[pos] != 0xff {
		cai := src[pos] & 31
		if src[pos] >> 5 != 3 || cai > 27 {
			return false
		}
		arg, hl, ok := read_head(src, pos, cai)
		if !ok {
			return true
		}
		if arg > n - pos - hl {
			return true
		}
		pos += hl + arg
	}
	return pos >= n
}
