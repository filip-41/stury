package cbor

import "stury:lib/core/tape"

// The text of a scalar token as a format's readers read it: a text string's characters, the chunks of an indefinite
// string joined, a tolerated ill-formed sequence as U+FFFD, an integer key's decimal digits and a byte string key's
// base64, read a piece at a time so that a decode, a compare and a hash need no buffer of their own.

// A reader of the text of a token, a piece at a time.
@(private)
Text_Run :: struct {
	src:      []u8,
	pos, end: u64, // the bytes of the chunk being read
	next:     u64, // with chunks, the head of the next chunk, `last` once every chunk is read
	last:     u64,
	mode:     Text_Mode,
	scratch:  [24]u8,
	given:    bool, // with `.Digits`, the digits were given
}

@(private)
Text_Mode :: enum u8 {
	Bytes,
	Lax, // the bytes, with each maximal subpart of an ill-formed sequence as U+FFFD
	Base64,
	Digits,
}

// The reader of the text of scalar token `t` of `src`, whose text `tape.text_decodes` says is not its bytes.
@(private)
text_run :: proc "contextless" (src: []u8, t: tape.Token) -> (r: Text_Run) {
	r.src = src
	if t.kind == .Number {
		r.mode = .Digits
		digits := integer_text(src[t.lo:t.lo + u64(t.n)], r.scratch[:])
		r.pos = u64(uintptr(raw_data(digits)) - uintptr(&r.scratch[0]))
		r.end = r.pos + u64(len(digits))
		return
	}
	if t.spelling & STR_INDEF != 0 {
		r.next, r.last = t.lo, t.lo + u64(t.n)
	} else {
		r.pos, r.end, r.next, r.last = t.lo, t.lo + u64(t.n), t.lo + u64(t.n), t.lo + u64(t.n)
	}
	if t.kind == .Bytes && t.role == .Key {
		r.mode = .Base64
	} else if t.spelling & tape.SPELLING_LAX != 0 {
		r.mode = .Lax
	}
	return
}

// Moves `r` to its next chunk with bytes left, false once there is none.
@(private)
chunk_next :: proc "contextless" (r: ^Text_Run) -> bool {
	for r.pos == r.end {
		if r.next >= r.last {
			return false
		}
		arg, hl, _ := read_head(r.src, r.next, r.src[r.next] & 31)
		r.pos, r.end = r.next + hl, r.next + hl + arg
		r.next = r.end
	}
	return true
}

// The next piece of the text `r` reads, false once it has given all of it.
@(private)
text_next :: proc "contextless" (r: ^Text_Run) -> ([]u8, bool) #no_bounds_check {
	switch r.mode {
	case .Digits:
		if r.given {
			return nil, false
		}
		r.given = true
		return r.scratch[r.pos:r.end], true
	case .Base64:
		group: [3]u8
		k := 0
		for k < 3 && chunk_next(r) {
			group[k] = r.src[r.pos]
			r.pos += 1
			k += 1
		}
		if k == 0 {
			return nil, false
		}
		return tape.base64_encode_group(group, k, r.scratch[:]), true
	case .Bytes:
		if !chunk_next(r) {
			return nil, false
		}
		piece := r.src[r.pos:r.end]
		r.pos = r.end
		return piece, true
	case .Lax:
		if !chunk_next(r) {
			return nil, false
		}
		return tape.lax_utf8_piece(r.src, &r.pos, r.end, r.scratch[:]), true
	}
	return nil, false
}

// The text of scalar node `t` whose text is not its bytes, decoded into `buf`, false when `buf` is too short. A
// number's is its value in decimal, as `number_text` gives it.
@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, _: ^tape.Format_Ext) -> (s: string, ok: bool) {
	if t.kind == .Number {
		return number_text(src, t, buf)
	}
	r := text_run(src, t)
	return tape.stream_text_decoded(&r, buf, text_next)
}

// The bytes that always hold the decode of scalar `t`: a number's decimal text, a byte string key's base64, a
// tolerated text's three bytes per byte read as U+FFFD, and else its span, which its chunks' heads only add to.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int {
	switch {
	case t.kind == .Number:
		return number_room(src, t)
	case t.kind == .Bytes && t.role == .Key:
		return (int(t.n) + 2) / 3 * 4
	case t.spelling & tape.SPELLING_LAX != 0:
		return 3 * int(t.n)
	}
	return int(t.n)
}

// Whether scalar `t` of `src` and scalar `o` of `other` read as the same text, whatever their kinds.
@(private)
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool {
	return tape.stream_same_text(src, t, other, o, text_run, text_next)
}

// `tape.text_hash` of the text scalar `t` of `src` reads as.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	return tape.stream_key_hash(src, t, text_run, text_next)
}

// The reader of the payload of the byte string item that starts `span`, in chunks or not.
@(private)
string_run :: proc "contextless" (span: []u8) -> Text_Run {
	if span[0] & 31 == 31 {
		return {src = span, pos = 1, end = 1, next = 1, last = u64(len(span)) - 1}
	}
	_, arg, hl := head_of(span)
	return {src = span, pos = hl, end = hl + arg, next = hl + arg, last = hl + arg}
}
