package tape

import "base:intrinsics"
import "stury:lib/base/spell"

// Shared streaming piece-by-piece text helpers for binary formats (CBOR, MessagePack):
// base64 encoding of byte-string keys, tolerated UTF-8 replacement, buffer decode, comparison, and hashing.

@(private = "file", rodata)
BASE64_ALPHABET := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

// Encodes `k` bytes (`1 <= k <= 3`) from `group` into 4 base64 bytes in `dst` and returns `dst[:4]`.
base64_encode_group :: #force_inline proc "contextless" (group: [3]u8, k: int, dst: []u8) -> []u8 #no_bounds_check {
	g := u32(group[0]) << 16 | u32(group[1]) << 8 | u32(group[2])
	dst[0], dst[1] = BASE64_ALPHABET[g >> 18], BASE64_ALPHABET[g >> 12 & 63]
	dst[2] = BASE64_ALPHABET[g >> 6 & 63] if k > 1 else '='
	dst[3] = BASE64_ALPHABET[g & 63] if k > 2 else '='
	return dst[:4]
}

// Returns the next well-formed UTF-8 slice from `src[pos^:end]`, or U+FFFD in `scratch[:3]` for a maximal ill-formed
// subpart, advancing `pos^` past the bytes consumed. Caller guarantees `pos^ < end` and `len(scratch) >= 3`.
lax_utf8_piece :: #force_inline proc "contextless" (src: []u8, pos: ^u64, end: u64, scratch: []u8) -> []u8 #no_bounds_check {
	base := raw_data(src)
	end_p := base[end:]
	q := pos^
	for q < end {
		if src[q] < 0x80 {
			q += 1
			continue
		}
		next, kind := spell.utf8_char(base[q:], end_p)
		if kind != .None {
			break
		}
		q = u64(intrinsics.ptr_sub(next, base))
	}
	if q > pos^ {
		piece := src[pos^:q]
		pos^ = q
		return piece
	}
	pos^ = u64(intrinsics.ptr_sub(spell.utf8_subpart(base[q:], end_p), base))
	scratch[0], scratch[1], scratch[2] = spell.REPLACEMENT[0], spell.REPLACEMENT[1], spell.REPLACEMENT[2]
	return scratch[:3]
}

// Copies every piece produced by `next(r)` into `buf`, returning false when `buf` is too short.
stream_text_decoded :: #force_inline proc "contextless" (r: ^$R, buf: []u8, $next: proc "contextless" (r: ^R) -> ([]u8, bool)) -> (string, bool) {
	w := 0
	for piece in next(r) {
		if w + len(piece) > len(buf) {
			return "", false
		}
		w += copy(buf[w:], piece)
	}
	return string(buf[:w]), true
}

// Compares the decoded text of scalar `t` of `src` and scalar `o` of `other` using piece reader `init`/`next`.
stream_same_text :: #force_inline proc "contextless" (
	src: []u8,
	t: Token,
	other: []u8,
	o: Token,
	$init: proc "contextless" (src: []u8, t: Token) -> $R,
	$next: proc "contextless" (r: ^R) -> ([]u8, bool),
) -> bool #no_bounds_check {
	if !text_decodes(t) && !text_decodes(o) {
		return t.n == o.n && string(src[t.lo:][:t.n]) == string(other[o.lo:][:o.n])
	}
	a, b := init(src, t), init(other, o)
	x, x_ok := next(&a)
	y, y_ok := next(&b)
	for x_ok && y_ok {
		k := min(len(x), len(y))
		if string(x[:k]) != string(y[:k]) {
			return false
		}
		x, y = x[k:], y[k:]
		if len(x) == 0 {
			x, x_ok = next(&a)
		}
		if len(y) == 0 {
			y, y_ok = next(&b)
		}
	}
	return !x_ok && !y_ok
}

// Computes `text_hash` of scalar `t` of `src` using piece reader `init`/`next`.
stream_key_hash :: #force_inline proc "contextless" (
	src: []u8,
	t: Token,
	$init: proc "contextless" (src: []u8, t: Token) -> $R,
	$next: proc "contextless" (r: ^R) -> ([]u8, bool),
) -> u32 {
	if !text_decodes(t) {
		return text_hash(src[t.lo:][:t.n])
	}
	r := init(src, t)
	x := text_hasher()
	for piece in next(&r) {
		for b in piece {
			text_hash_byte(&x, b)
		}
	}
	return text_hasher_end(&x)
}
