package msgpack

import "base:intrinsics"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Streaming piece-by-piece decoder of MessagePack scalar text: tolerated UTF-8 replacement (`U+FFFD`),
// binary keys in base64, integer keys in decimal digits, and Timestamp (`ext -1`) payloads in RFC 3339.

@(private)
Text_Mode :: enum u8 {
	Bytes,
	Lax,
	Base64,
	Digits,
	Timestamp,
}

@(private)
Text_Run :: struct {
	src:      []u8,
	pos, end: u64,
	mode:     Text_Mode,
	scratch:  [TIMESTAMP_TEXT_ROOM]u8,
	given:    bool,
}

@(private, rodata)
BASE64_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// Initializes a streaming text reader for token `t` of `src`.
@(private)
text_run :: proc "contextless" (src: []u8, t: tape.Token) -> (r: Text_Run) {
	r.src = src
	if t.kind == .Number {
		r.mode = .Digits
		digits := integer_text(src[t.lo:t.lo + u64(t.n)], r.scratch[:24])
		r.pos = u64(uintptr(raw_data(digits)) - uintptr(&r.scratch[0]))
		r.end = r.pos + u64(len(digits))
		return
	}
	if t.spelling & STR_TIMESTAMP != 0 {
		r.mode = .Timestamp
		ts, _ := timestamp_text(src[t.lo:t.lo + u64(t.n)], r.scratch[:])
		r.pos = 0
		r.end = u64(len(ts))
		return
	}
	r.pos, r.end = t.lo, t.lo + u64(t.n)
	if t.kind == .Bytes && t.role == .Key {
		r.mode = .Base64
	} else if t.spelling & tape.SPELLING_LAX != 0 {
		r.mode = .Lax
	}
	return
}

// Returns the next decoded byte chunk from `r`, or false when exhausted.
@(private)
text_next :: proc "contextless" (r: ^Text_Run) -> ([]u8, bool) #no_bounds_check {
	switch r.mode {
	case .Digits, .Timestamp:
		if r.given {
			return nil, false
		}
		r.given = true
		return r.scratch[r.pos:r.end], true
	case .Base64:
		if r.pos >= r.end {
			return nil, false
		}
		group: [3]u8
		k := 0
		for k < 3 && r.pos < r.end {
			group[k] = r.src[r.pos]
			r.pos += 1
			k += 1
		}
		g := u32(group[0]) << 16 | u32(group[1]) << 8 | u32(group[2])
		r.scratch[0], r.scratch[1] = BASE64_ALPHABET[g >> 18], BASE64_ALPHABET[g >> 12 & 63]
		r.scratch[2] = BASE64_ALPHABET[g >> 6 & 63] if k > 1 else '='
		r.scratch[3] = BASE64_ALPHABET[g & 63] if k > 2 else '='
		return r.scratch[:4], true
	case .Bytes:
		if r.pos >= r.end {
			return nil, false
		}
		piece := r.src[r.pos:r.end]
		r.pos = r.end
		return piece, true
	case .Lax:
		if r.pos >= r.end {
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

// Decodes scalar node `t` into `buf`.
@(private)
text_decoded :: proc "contextless" (src: []u8, t: tape.Node, buf: []u8, _: ^tape.Format_Ext) -> (string, bool) {
	if t.kind == .Number {
		return number_text(src, t, buf)
	}
	if t.spelling & STR_TIMESTAMP != 0 {
		return timestamp_text(src[t.lo:t.lo + u64(t.n)], buf)
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

// Buffer size guaranteed to hold `text_decoded` of scalar `t`.
@(private)
decode_room :: proc "contextless" (src: []u8, t: tape.Node, _: ^tape.Format_Ext) -> int {
	switch {
	case t.kind == .Number:
		return number_room(src, t)
	case t.kind == .Bytes && t.role == .Key:
		return int(min((u64(t.n) + 2) / 3 * 4, u64(max(int))))
	case t.spelling & STR_TIMESTAMP != 0:
		return TIMESTAMP_TEXT_ROOM
	case t.spelling & tape.SPELLING_LAX != 0:
		return int(min(3 * u64(t.n), u64(max(int))))
	}
	return int(min(u64(t.n), u64(max(int))))
}

// Compares the decoded text of scalar `t` of `src` and scalar `o` of `other`.
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

// Computes `tape.text_hash` of the decoded text of key `t` in `src`.
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
