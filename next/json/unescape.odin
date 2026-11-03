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
	q, kind := kernel.utf8_char(base[d.p:], base[d.end:])
	if kind == .None {
		size := int(intrinsics.ptr_sub(q, base[d.p:]))
		spelled: [4]u8
		copy(spelled[:], d.src[d.p:d.p + u64(size)])
		d.p += u64(size)
		return spell.pending_give(&d.pending, spelled, size), true
	}
	// An ill-formed sequence reads as U+FFFD over its maximal subpart, the step `utf8_lax` makes.
	q2, _, _ := utf8_lax(base[d.p:], base[d.end:], {.Invalid_Utf8})
	d.p += u64(intrinsics.ptr_sub(q2, base[d.p:]))
	return spell.pending_give(&d.pending, replacement(), 3), true
}

// Decodes the escape at `src[p] == '\\'`. Returns up to four bytes, their count, and the byte after the escape. The
// walk has already accepted the escape. A lone surrogate half reads as U+FFFD.
@(private)
decoded_escape :: #force_inline proc "contextless" (src: []u8, p, end: u64) -> (spelled: [4]u8, size: int, next: u64) {
	#no_bounds_check {
		if p + 1 >= end {
			return replacement(), 3, end
		}
		e := src[p + 1]
		if ent := ESC_WORD[e]; ent != 0 {
			spelled[0] = u8(ent)
			return spelled, 1, p + 2
		}
		if e == 'u' {
			if p + 6 > end {
				spelled[0] = 'u'
				return spelled, 1, p + 2
			}
			unit, ok := spell.hex4(raw_data(src)[p + 2:])
			if !ok {
				spelled[0] = 'u'
				return spelled, 1, p + 2
			}
			next = p + 6
			// One range test covers both halves: a high half pairs with the low `\u` right after it, and a low half
			// with no high half before it reads as U+FFFD.
			if unit - 0xD800 < 0x800 {
				if unit >= 0xDC00 || next + 6 > end || src[next] != '\\' || src[next + 1] != 'u' {
					return replacement(), 3, next
				}
				low, low_ok := spell.hex4(raw_data(src)[next + 2:])
				if !low_ok || low - 0xDC00 >= 0x400 {
					return replacement(), 3, next
				}
				unit = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
				next += 6
			}
			// A code unit outside the surrogate range already is the rune's value.
			s, n := utf8.encode_rune(rune(unit))
			return s, n, next
		}
		// JSON5's other escapes, and a byte a backslash spells as itself, in `decoded_escape_other`.
		return decoded_escape_other(src, p, end, e)
	}
}

// `decoded_escape_other` is `decoded_escape` for an escape that is no one-letter JSON escape and no `\u`: JSON5's
// `\x`, `\0`, `\v`, `\'` and line continuations, and the byte a backslash spells as itself. Out of line, so
// `decoded_escape` compiles none of it.
@(private)
decoded_escape_other :: proc "contextless" (src: []u8, p, end: u64, e: u8) -> (spelled: [4]u8, size: int, next: u64) {
	#no_bounds_check {
		switch e {
		case 'x':
			if p + 4 > end {
				break
			}
			hi, lo := spell.HEX_NIBBLE[src[p + 2]], spell.HEX_NIBBLE[src[p + 3]]
			if hi > 15 || lo > 15 {
				break
			}
			s, n := utf8.encode_rune(rune(hi << 4 | lo))
			return s, n, p + 4
		case '0':
			if p + 2 < end && src[p + 2] - '0' < 10 {
				break
			}
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
		q, kind := kernel.utf8_char(base[p + 1:], base[end:])
		if kind != .None {
			q, _, _ = utf8_lax(base[p + 1:], base[end:], {.Invalid_Utf8})
			return replacement(), 3, p + 1 + u64(intrinsics.ptr_sub(q, base[p + 1:]))
		}
		n := int(intrinsics.ptr_sub(q, base[p + 1:]))
		if n == 3 && e == 0xE2 && src[p + 2] == 0x80 && src[p + 3] | 1 == 0xA9 {
			return spelled, 0, p + 4
		}
		copy(spelled[:], src[p + 1:p + 1 + u64(n)])
		return spelled, n, p + 1 + u64(n)
	}
}

@(private)
replacement :: #force_inline proc "contextless" () -> [4]u8 {
	return {0xEF, 0xBF, 0xBD, 0}
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
	return decode_plain(doc, n, buf)
}

// Decodes a short token byte by byte with one 32-bit store per escape. `decode_plain` picks it for a token under
// 256 bytes, where finding escapes in 64-byte blocks does more work than the byte walk.
@(private)
decode_scalar :: proc(doc: ^core.Token_View, n: core.Node, buf: []u8) -> (string, bool) {
	// A JSON escape decodes to no more bytes than it spells, so a buffer as long as the token holds every result.
	if int(n.n) > len(buf) {
		return "", false
	}
	dst := buf
	src := doc.src
	out := raw_data(dst)
	lo := n.lo
	end := lo + u64(n.n)
	p := lo
	w := 0
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
	return string(dst[:w]), true
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
		for p < end && src[p] != '\\' {
			out[w] = src[p]
			w += 1
			p += 1
		}
		if p >= end {
			break
		}
		spelled, size, next := decoded_escape(doc.src, p, end)
		put_word(dst, w, spelled, size)
		w += size
		p = next
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

// Decodes a token under 256 bytes with `decode_scalar` and a longer one with `decode_block`.
@(private)
decode_plain :: #force_inline proc(doc: ^core.Token_View, n: core.Node, buf: []u8) -> (string, bool) {
	if n.n < 256 {
		return decode_scalar(doc, n, buf)
	}
	return decode_block(doc, n, buf)
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

// JSON's `Spelling.resolve` returns the node's kind, which is its value's kind.
@(private)
spelling_resolve :: proc(doc: ^core.Document, i: core.Node_Index) -> core.Kind {
	return doc.nodes[i].kind
}

// JSON's `Spelling.number`, exported beside `text`. A token that is no number is `.Wide`, as `core.number` answers. A pure
// integer of at most 19 digits folds here from the recorded shape with no grammar search. Every other token, and a negative below `i64`, is passed to `number_slow`.
number :: #force_inline proc(doc: ^core.Token_View, n: core.Node) -> core.Number {
	// Any kind but `.Number` is no number and returns `.Wide`.
	if n.kind == .Number {
		sp := n.spelling
		// The walk's `spelling` holds the kind and the two digit counts. Each arm reads the fields it uses.
		if sp & core.NUMBER_KIND_MASK <= u16(Number_Spelling.Decimal) {
			lo, hi := n.lo, n.lo + u64(n.n)
			int_digits := int((sp >> core.NUMBER_INT_SHIFT) & 0x1f)
			if sp & (core.NUMBER_FRAC_MASK | core.NUMBER_EXP) == 0 {
				if int_digits <= 19 {
					if num, ok := spell.number_int(doc.src, lo, hi, int_digits); ok {
						return num
					}
				}
			} else {
				frac_digits := int((sp >> core.NUMBER_FRAC_SHIFT) & 0x1f)
				if sp & core.NUMBER_EXP != 0 {
					return spell.number_exponent(doc.src, lo, hi, int_digits, frac_digits)
				}
				// A set `core.NUMBER_FRAC_MASK` without `core.NUMBER_EXP` is a fraction of at least one digit.
				// `number_fraction`'s first arm checks the point byte at `hi - frac_digits - 1` and folds both
				// runs to their recorded lengths, without testing that the bytes are digits, since the walk
				// recorded them from this span. A saturated count records 31, so `int_digits + frac_digits`
				// exceeds 19 and `number_slow` reads the token.
				if int_digits + frac_digits <= 19 {
					return spell.number_fraction(doc.src, lo, hi, int_digits, frac_digits)
				}
			}
		}
		return number_slow(doc, n)
	}
	return {0, .Wide}
}

// Decodes the number shapes that are not a plain integer: decimal, hex, infinity and NaN.
@(private, cold)
number_slow :: #force_no_inline proc(doc: ^core.Token_View, n: core.Node) -> core.Number {
	lo, hi := n.lo, n.lo + u64(n.n)
	switch number_spelling_of(n.spelling) {
	case .Json, .Decimal:
		return spell.number_decimal(doc.src, lo, hi)
	case .Hex:
		return spell.number_hex(doc.src, lo, hi)
	case .Infinity:
		// JSON5's `Infinity`, signed by a `-` before it, and its `NaN`, a quiet one with a zero sign.
		return {spell.F64_INF_BITS | u64(lo < hi && doc.src[lo] == '-') << 63, .Float}
	case .Nan:
		return {0x7ff8_0000_0000_0000, .Float}
	}
	return {0, .Wide}
}
