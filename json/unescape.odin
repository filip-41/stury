package json

import "base:intrinsics"
import "core:unicode/utf8"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"

// JSON's string and key decoder runs when a token needs it. It reads JSON's escapes, JSON5's other escapes and quotes,
// and the tolerated readings of ill-formed UTF-8 and lone surrogate halves. `decoded_escape` serves the copy, the key
// compare and the tolerant reader.

// A decoder over one string token, for the tolerant reader. `pending` holds the rest of the last decoded character. The
// readers below that do not tolerate do not use it.
@(private)
Decoded :: struct {
	src:     []u8,
	p:       u64,
	end:     u64,
	pending: spell.Pending,
}

// Returns a decoder over node `n`'s token span, `n.lo..n.lo+n.n`. A quoted string's span begins past its opening quote
// and ends at its closing quote, an unquoted key's is bare.
@(private)
decoded_init :: proc "contextless" (src: []u8, n: core.Node) -> Decoded {
	return {src = src, p = n.lo, end = n.lo + u64(n.n)}
}

// Returns the next decoded byte, or false past the token's end.
@(private)
decoded_next :: proc "contextless" (d: ^Decoded) -> (b: u8, ok: bool) {
	if b, ok = spell.pending_next(&d.pending); ok {
		return
	}
	if d.p >= d.end {
		return 0, false
	}
	c := d.src[d.p]
	for {
		if c != '\\' {
			break
		}
		spelled, size, next := decoded_escape(d.src, d.p, d.end)
		d.p = next
		if size == 0 {
			if d.p >= d.end {
				return 0, false
			}
			c = d.src[d.p]
			continue
		}
		return spell.pending_give(&d.pending, spelled, size), true
	}
	if c < 0x80 {
		d.p += 1
		return c, true
	}
	base := raw_data(d.src)
	spelled, size, q := spell.utf8_lax_char(base[d.p:], base[d.end:])
	d.p = u64(intrinsics.ptr_sub(q, base))
	return spell.pending_give(&d.pending, spelled, size), true
}

// Decodes the escape at `src[p] == '\\'`. Returns up to four bytes, their count, and the byte after the escape. The
// walk has already accepted the escape. A lone surrogate half reads as U+FFFD.
@(private)
decoded_escape :: #force_inline proc "contextless" (src: []u8, p, end: u64) -> (spelled: [4]u8, size: int, next: u64) {
	#no_bounds_check {
		if p + 1 >= end {
			return spell.REPLACEMENT, 3, end
		}
		e := src[p + 1]
		if b := spell.ESCAPED[e]; b != 0 {
			spelled[0] = b
			return spelled, 1, p + 2
		}
		if e == 'u' {
			return decoded_unicode(src, p, end)
		}
		// JSON5's other escapes, and a byte a backslash spells as itself, in `decoded_escape_other`.
		return decoded_escape_other(src, p, end, e)
	}
}

// `decoded_escape` for a `\u` escape. Out of line, so the block decoder's loop keeps its registers.
@(private)
decoded_unicode :: #force_no_inline proc "contextless" (src: []u8, p, end: u64) -> (spelled: [4]u8, size: int, next: u64) {
	r, n := spell.unicode_escape(raw_data(src)[p:], int(end - p))
	if n == 0 {
		// The walk accepted the escape, so its four digits are hex, and it is a surrogate half no other half pairs
		// with.
		return spell.REPLACEMENT, 3, p + 6
	}
	s, k := utf8.encode_rune(r)
	return s, k, p + u64(n)
}

// `decoded_escape_other` is `decoded_escape` for an escape that is no one-letter JSON escape and no `\u`: JSON5's
// `\x`, `\0`, `\v`, `\'` and line continuations, and the byte a backslash spells as itself. The walk accepted the
// escape, so a `\x` has its two hex digits and a `\0` no digit after it. Out of line, so `decoded_escape` compiles
// none of it.
@(private)
decoded_escape_other :: proc "contextless" (src: []u8, p, end: u64, e: u8) -> (spelled: [4]u8, size: int, next: u64) {
	#no_bounds_check {
		switch e {
		case 'x':
			s, n := utf8.encode_rune(rune(spell.HEX_NIBBLE[src[p + 2]] << 4 | spell.HEX_NIBBLE[src[p + 3]]))
			return s, n, p + 4
		case '0':
			spelled[0] = 0
			return spelled, 1, p + 2
		case 'v':
			spelled[0] = 0x0B
			return spelled, 1, p + 2
		case '\'':
			spelled[0] = '\''
			return spelled, 1, p + 2
		case '\n':
			return spelled, 0, p + 2
		case '\r':
			if p + 2 < end && src[p + 2] == '\n' {
				return spelled, 0, p + 3
			}
			return spelled, 0, p + 2
		}
		if e < 0x80 {
			spelled[0] = e
			return spelled, 1, p + 2
		}
		base := raw_data(src)
		// U+2028 and U+2029 after a backslash are line continuations.
		if line_sep5(base[p + 1:], base[end:]) {
			return spelled, 0, p + 4
		}
		s, n, q := spell.utf8_lax_char(base[p + 1:], base[end:])
		return s, n, u64(intrinsics.ptr_sub(q, base))
	}
}

// JSON's `Spelling.text`, exported so a caller that knows the format calls it without the table. A scalar with
// `SPELLING_DECODE` clear returns its span. A node that needs decoding is written into `buf`, and the call returns false
// when `buf` is too short. A container returns false, as `core.text` does. `doc.view` and `doc.nodes[i]` are its arguments
// for node `i` of a document.
text :: #force_inline proc(doc: ^core.Token_View, n: core.Node, buf: []u8) -> (s: string, ok: bool) {
	// A container's `n` is a node count and its `spelling` a child count, not a span and a decode bit.
	if n.kind > .Plain {
		return "", false
	}
	if n.spelling & core.SPELLING_DECODE == 0 {
		return string(doc.src[n.lo:n.lo + u64(n.n)]), true
	}
	if n.spelling & core.SPELLING_LAX != 0 {
		return spell.decode_text(buf, decoded_init(doc.src, n), decoded_next)
	}
	// A token under 256 bytes is decoded byte by byte, a longer one by blocks.
	if n.n < 256 {
		return decode_scalar(doc, n, buf)
	}
	return decode_block(doc, n, buf)
}

// Decodes a short token byte by byte with one 32-bit store per escape. `text` picks it for a token under
// 256 bytes, where finding escapes in 64-byte blocks does more work than the byte walk.
@(private)
decode_scalar :: proc(doc: ^core.Token_View, n: core.Node, buf: []u8) -> (string, bool) {
	// A JSON escape decodes to no more bytes than it spells, so a buffer as long as the token holds every result.
	if int(n.n) > len(buf) {
		return "", false
	}
	return string(buf[:decode_bytes(buf, 0, doc.src, n.lo, n.lo + u64(n.n))]), true
}

// Decodes `src[p:end]` into `dst` from `w` byte by byte, with one 32-bit store per escape. Returns the end of the
// bytes written.
@(private)
decode_bytes :: #force_inline proc(dst: []u8, w: int, src: []u8, p, end: u64) -> int {
	out := raw_data(dst)
	p, w := p, w
	#no_bounds_check for p < end {
		c := src[p]
		if c != '\\' {
			out[w] = c
			w += 1
			p += 1
			continue
		}
		spelled, size, next := decoded_escape(src, p, end)
		put_word(dst, w, spelled, size)
		w += size
		p = next
	}
	return w
}

// Decodes a long token. Loads each 64-byte block once, stores a block with no escape whole, and walks a block with
// escapes by its backslash mask, copying the run before each escape and decoding the escape in place. A block is not
// reloaded after an escape.
@(private)
decode_block :: proc(doc: ^core.Token_View, n: core.Node, buf: []u8) -> (string, bool) {
	if int(n.n) > len(buf) {
		return "", false
	}
	dst := buf
	src := raw_data(doc.src)
	out := raw_data(dst)
	limit := u64(len(doc.src))
	lo := n.lo
	end := lo + u64(n.n)
	p := lo
	w := 0
	for p < end {
		if p + 64 <= limit {
			b := kernel.load(src[p:])
			m := kernel.pack(kernel.eq(b, '\\'))
			rem := end - p
			if m == 0 {
				if rem < 64 {
					copy_run(dst, w, src, int(p), int(rem))
					w += int(rem)
					p = end
					continue
				}
				store_block(out, w, b)
				p += 64
				w += 64
				continue
			}
			base := p
			cur := u64(0)
			wo := w
			crossed := false
			for m != 0 {
				k := u64(intrinsics.count_trailing_zeros(m))
				if k >= rem {
					break
				}
				if k > cur {
					copy_run(dst, wo, src, int(base + cur), int(k - cur))
					wo += int(k - cur)
				}
				spelled, size, next := decoded_escape(doc.src, base + k, end)
				put_word(dst, wo, spelled, size)
				wo += size
				if next - base >= 64 {
					// The escape's bytes run past this block, so the next read starts after the escape.
					cur = next - base
					crossed = true
					break
				}
				cur = next - base
				m &= max(u64) << cur
			}
			if crossed {
				p = base + cur
				w = wo
				continue
			}
			take := min(u64(64), rem)
			if cur < take {
				copy_run(dst, wo, src, int(base + cur), int(take - cur))
				wo += int(take - cur)
			}
			p = base + take
			w = wo
			continue
		}
		// The bytes before the text's end, fewer than 64, are read one at a time.
		w = decode_bytes(dst, w, doc.src, p, end)
		break
	}
	return string(dst[:w]), true
}

// Writes an escape's `size` bytes at `w` in `dst`: one 32-bit store when four bytes fit, else one byte at a time.
@(private)
put_word :: #force_inline proc(dst: []u8, w: int, spelled: [4]u8, size: int) {
	#no_bounds_check {
		if w + 4 <= len(dst) {
			intrinsics.unaligned_store((^u32)(&dst[w]), transmute(u32)spelled)
		} else {
			for k in 0 ..< size {
				dst[w + k] = spelled[k]
			}
		}
	}
}

// Stores a 64-byte block as four 16-byte stores.
@(private)
store_block :: #force_inline proc(out: [^]u8, w: int, b: kernel.Block) {
	#unroll for k in 0 ..< 4 {
		intrinsics.unaligned_store((^#simd[16]u8)(out[w + k * 16:]), b[k])
	}
}

// Copies `n` bytes from `src[p:]` to `dst[w:]` with 16-byte stores while they fit, then `copy_up_to` for the tail.
// Its overlapping words stay inside the source and the destination's slack.
@(private)
copy_run :: #force_inline proc(dst: []u8, w: int, src: [^]u8, p, n: int) {
	#no_bounds_check {
		i := 0
		for i + 16 <= n {
			intrinsics.unaligned_store((^#simd[16]u8)(&dst[w + i]), intrinsics.unaligned_load((^#simd[16]u8)(&src[p + i])))
			i += 16
		}
		copy_up_to(dst, w + i, src, p + i, n - i)
	}
}

// Copies `n` bytes from `src[p:]` to `dst[w:]` with `n` below 16: one overlapping word at each end where it fits,
// else single bytes.
@(private)
copy_up_to :: #force_inline proc(dst: []u8, w: int, src: [^]u8, p, n: int) {
	#no_bounds_check {
		switch {
		case n >= 8:
			intrinsics.unaligned_store((^u64)(&dst[w]), intrinsics.unaligned_load((^u64)(&src[p])))
			intrinsics.unaligned_store((^u64)(&dst[w + n - 8]), intrinsics.unaligned_load((^u64)(&src[p + n - 8])))
		case n >= 4:
			intrinsics.unaligned_store((^u32)(&dst[w]), intrinsics.unaligned_load((^u32)(&src[p])))
			intrinsics.unaligned_store((^u32)(&dst[w + n - 4]), intrinsics.unaligned_load((^u32)(&src[p + n - 4])))
		case n >= 2:
			intrinsics.unaligned_store((^u16)(&dst[w]), intrinsics.unaligned_load((^u16)(&src[p])))
			intrinsics.unaligned_store((^u16)(&dst[w + n - 2]), intrinsics.unaligned_load((^u16)(&src[p + n - 2])))
		case n == 1:
			dst[w] = src[p]
		}
	}
}

// `Spelling.key_equals` for a key with `SPELLING_DECODE` set. Compares its decoded bytes against `name` span by span
// between escapes, with no allocation. A key holding a tolerated ill-formed sequence compares through `decoded_next`,
// so it matches what `text` returns.
@(private)
key_equals_decode :: #force_inline proc "contextless" (doc: ^core.Token_View, n: core.Node, name: string) -> bool {
	if n.spelling & core.SPELLING_LAX != 0 {
		return spell.decoded_equals(decoded_init(doc.src, n), decoded_next, name)
	}
	src := doc.src
	end := n.lo + u64(n.n)
	p := n.lo
	at := 0
	// Most keys differ from `name` early, so the read ends at the first byte that differs.
	#no_bounds_check for p < end {
		c := src[p]
		if c != '\\' {
			if at >= len(name) || name[at] != c {
				return false
			}
			p += 1
			at += 1
			continue
		}
		spelled, size, next := decoded_escape(src, p, end)
		if at + size > len(name) {
			return false
		}
		for k in 0 ..< size {
			if name[at + k] != spelled[k] {
				return false
			}
		}
		at += size
		p = next
	}
	return at == len(name)
}
