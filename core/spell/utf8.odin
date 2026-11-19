package spell

import "core:unicode/utf8"

// The kinds of fault a walk raises, shared by every format. Each member's comment names the formats that raise it
// and the byte `at` names.
Fault_Kind :: enum u8 {
	None, // no fault
	Truncated, // json, dsv: the input ended inside a construct, at `len(src)`, or dsv's quoted cell never closed, at its opening quote
	Bad_Char, // json, dsv: the first byte that cannot extend the construct or the text, or that is not UTF-8
	Bad_Escape, // json: at the escape's letter or its first bad digit, at the backslash for a lone surrogate half or a JSON5 identifier escape of no identifier character, dsv (TSV): at the backslash
	Bad_Number, // json: at the byte that breaks the number
	Too_Deep, // json: at the bracket past the depth limit
	Too_Wide, // json, dsv: the first byte of a token longer than `Token.n` holds, records: of a record past `max_bytes`
	No_Memory, // json (depth stack past `MAX_DEPTH`), dsv (header's keys, a reader's batch), records (window, pieces): a scratch allocation failed, no byte
	Bad_Option, // json, dsv, records: a spec, option or framing the format does not take, or a handle with no format, found before any byte is read
	Bad_Width, // dsv: a record wider than the first, at the delimiter that starts its extra cell, or narrower, at its line end
	Duplicate_Key, // json, dsv: a build, a read or a scan under `.Refuse` met a key that repeats one of its object's, at the second key's first byte. No walk raises it: the library makes it from the refusal
}

// The length of the UTF-8 sequence lead byte `c` begins: 1 to 4, or 0 for a byte that begins none.
utf8_length :: proc "contextless" (c: byte) -> int {
	switch c {
	case 0x00 ..= 0x7f:
		return 1
	case 0xc2 ..= 0xdf:
		return 2
	case 0xe0 ..= 0xef:
		return 3
	case 0xf0 ..= 0xf4:
		return 4
	}
	return 0
}

// U+FFFD in UTF-8, the character a tolerated ill-formed sequence or lone surrogate half reads as.
REPLACEMENT :: [4]u8{0xEF, 0xBF, 0xBD, 0}

// Steps over the UTF-8 character whose lead is at `p`, where `p < end` and `*p >= 0x80`. Returns one past the
// character with `.None`, or `p` with `.Bad_Char` for a malformed sequence. A sequence the text cuts short returns
// `end` with `.Truncated` when every byte present could still continue it, else `p` with `.Bad_Char`.
utf8_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: Fault_Kind) {
	c := p[0]
	if c < 0xc2 || c > 0xf4 {
		return p, .Bad_Char
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
			return p, .Bad_Char
		}
	}
	return p[need:], .None
}

// Returns the end of the maximal subpart of an ill-formed sequence at `p`: the longest prefix that could still start
// a well-formed sequence, at least one byte. The caller has already received `.Bad_Char` from `utf8_char`.
utf8_subpart :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	n := 1
	for n < 3 && p[n:] < end {
		if _, k := utf8_char(p, p[n + 1:]); k != .Truncated {
			break
		}
		n += 1
	}
	return p[n:]
}

// Reads the character whose lead is at `p`, where `p < end` and `*p >= 0x80`, as a decoder that tolerates ill-formed
// UTF-8 reads it. Returns its bytes, their count and one past it, or U+FFFD over the maximal subpart of a sequence that
// is ill-formed or that `end` cuts short.
utf8_lax_char :: #force_inline proc "contextless" (p, end: [^]u8) -> (spelled: [4]u8, size: int, q: [^]u8) {
	kind: Fault_Kind
	q, kind = utf8_char(p, end)
	if kind != .None {
		return REPLACEMENT, 3, utf8_subpart(p, end)
	}
	size = int(uintptr(q) - uintptr(p))
	#unroll for i in 0 ..< 4 {
		if i < size {
			spelled[i] = p[i]
		}
	}
	return spelled, size, q
}

// Returns the index of the first byte of the character that holds byte `i` of `s`, or 0 when none starts at or before
// it.
char_start :: #force_inline proc "contextless" (s: string, i: int) -> int {
	i := i
	for i > 0 && s[i] & 0xC0 == 0x80 {
		i -= 1
	}
	return i
}

// Writes the code point `r` as UTF-8 at the start of `buf`, which holds room for it. Returns its length. A surrogate or
// a value past U+10FFFF writes U+FFFD.
rune_text :: #force_inline proc "contextless" (buf: []u8, r: rune) -> int {
	s, n := utf8.encode_rune(r)
	copy(buf, s[:n])
	return n
}
