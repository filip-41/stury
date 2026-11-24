package cbor

import "base:intrinsics"
import "stury:lib/base/spell"
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

@(private, rodata)
BASE64_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

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
		g := u32(group[0]) << 16 | u32(group[1]) << 8 | u32(group[2])
		r.scratch[0], r.scratch[1] = BASE64_ALPHABET[g >> 18], BASE64_ALPHABET[g >> 12 & 63]
		r.scratch[2] = BASE64_ALPHABET[g >> 6 & 63] if k > 1 else '='
		r.scratch[3] = BASE64_ALPHABET[g & 63] if k > 2 else '='
		return r.scratch[:4], true
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
		base := raw_data(r.src)
		end := base[r.end:]
		q := r.pos
		for q < r.end {
			if r.src[q] < 0x80 {
				q += 1
				continue
			}
			next, kind := spell.utf8_char(base[q:], end)
			if kind != .None {
				break
			}
			q = u64(intrinsics.ptr_sub(next, base))
		}
		if q > r.pos {
			piece := r.src[r.pos:q]
			r.pos = q
			return piece, true
		}
		r.pos = u64(intrinsics.ptr_sub(spell.utf8_subpart(base[q:], end), base))
		r.scratch[0], r.scratch[1], r.scratch[2] = spell.REPLACEMENT[0], spell.REPLACEMENT[1], spell.REPLACEMENT[2]
		return r.scratch[:3], true
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
	w := 0
	for piece in text_next(&r) {
		if w + len(piece) > len(buf) {
			return "", false
		}
		w += copy(buf[w:], piece)
	}
	return string(buf[:w]), true
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
same_text :: proc "contextless" (src: []u8, t: tape.Token, other: []u8, o: tape.Token) -> bool #no_bounds_check {
	if !tape.text_decodes(t) && !tape.text_decodes(o) {
		return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
	}
	a, b := text_run(src, t), text_run(other, o)
	x, x_ok := text_next(&a)
	y, y_ok := text_next(&b)
	for x_ok && y_ok {
		k := min(len(x), len(y))
		if string(x[:k]) != string(y[:k]) {
			return false
		}
		x, y = x[k:], y[k:]
		if len(x) == 0 {
			x, x_ok = text_next(&a)
		}
		if len(y) == 0 {
			y, y_ok = text_next(&b)
		}
	}
	return !x_ok && !y_ok
}

// `tape.text_hash` of the text scalar `t` of `src` reads as.
@(private)
key_hash :: proc "contextless" (src: []u8, t: tape.Token) -> u32 {
	if !tape.text_decodes(t) {
		return tape.text_hash(src[t.lo:][:t.n])
	}
	r := text_run(src, t)
	x := tape.text_hasher()
	for piece in text_next(&r) {
		for b in piece {
			tape.text_hash_byte(&x, b)
		}
	}
	return tape.text_hasher_end(&x)
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
