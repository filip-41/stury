package scan

// JSON string unescape and key comparison.

import "base:intrinsics"
import "core:mem"
import "core:simd"
import "core:unicode/utf8"
import lex "lex"

// The decoders write the inner bytes of a JSON string token into `dst` and return the count written, or -1
// for a malformed escape. `dst` must be as long as the text: no escape decodes to more than it writes.

// The byte-at-a-time copy loop, entered at any position and write cursor so the bulk copy can resume it.
@(private = "file")
dom_unescape_tail :: #force_inline proc(dst: []u8, src: []byte, start, end: u64, at: int) -> int {
	// Locals, never address-taken, so they stay in registers.
	p := start
	out := at
	for p < end {
		c := src[p]
		if c != '\\' {
			dst[out] = c
			out += 1
			p += 1
			continue
		}
		wrote, next, ok := decode_escape_unit(src, p, end, dst[out:])
		if !ok {
			return -1
		}
		out += wrote
		p = next
	}
	return out
}

// The whole token by the byte-at-a-time loop: what `dom_unescape_copy` is checked against.
dom_unescape_scalar :: proc(dst: []u8, src: []byte, lo, hi: u64) -> int {
	// `lo` and `hi` bound the token including both quotes.
	return dom_unescape_tail(dst, src, lo + 1, hi - 1, 0)
}

@(private, rodata)
DOM_LANE_BSLASH: #simd[16]u8 = {0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c,0x5c}

// Bytes moved per chunk, and the store's width: the store is a typed deref of a 16-byte vector.
@(private = "file")
DOM_COPY_CHUNK :: 16

// The text length from which an escaped string takes the bulk copy. Short escape-dense values lose on it.
// Gated once per string, not per clean run.
@(private = "file")
DOM_COPY_MIN_SPELL :: 256

// The clean head the walk already located is copied in one `memcpy` only from this length. Below it the
// chunk loop's own stores are cheaper.
@(private = "file")
DOM_COPY_MIN_HEAD :: 64

// The bulk copy for a token whose text is at least `DOM_COPY_MIN_SPELL`: a 16-byte chunk loop, the
// store inline per chunk (a copy call per clean run costs more than it saves).
//
// The 16-byte store happens only when the chunk holds no backslash, because the destination has no padding
// (`.Dom` reserves the exact decoded length). Loads satisfy `p + CHUNK <= end`. `dom_unescape_tail`
// finishes the residue.
//
// `first_esc` is the offset of the token's first backslash from `lo`, or 0 when the caller has none.
// `[lo+1, lo+first_esc)` is backslash-free whether the latch is exact or saturated.
@(private = "file")
dom_unescape_copy :: proc(dst: []u8, src: []byte, lo, hi, first_esc: u64) -> int {
	end := hi - 1
	p := lo + 1
	out := 0
	#no_bounds_check {
		// The clean head, in one call. Taken only when the byte at the offset is a backslash (an exact
		// count is self-verifying) or the count is the saturation value (unverifiable without the search
		// this avoids). A wrong count would otherwise copy an escape as clean bytes. The `end - p` clamp
		// bounds the read by the token whatever the caller-supplied count says.
		if first_esc >= DOM_COPY_MIN_HEAD + 1 {
			at := lo + min(first_esc, end - p)
			if first_esc == u64(FIRST_ESC_SATURATED) || src[at] == '\\' {
				head := int(min(first_esc - 1, end - p))
				// `copy` lowers to a memmove libc call. `mem.copy_non_overlapping` reaches `llvm.memcpy`,
				// which relies on the caller proving that `dst` and `src` do not overlap.
				mem.copy_non_overlapping(
					raw_data(dst),
					raw_data(src[p:p + u64(head)]),
					head,
				)
				out = head
				p += u64(head)
			}
		}
		for p + DOM_COPY_CHUNK <= end {
			v := lex.load16(src, p)
			bs := transmute(u16)simd.extract_msbs(simd.lanes_eq(v, DOM_LANE_BSLASH))
			if bs == 0 {
				// `core:simd` has no `store` proc. The typed deref is the store.
				(^#simd[DOM_COPY_CHUNK]u8)(&dst[out])^ = v
				p += DOM_COPY_CHUNK
				out += DOM_COPY_CHUNK
				continue
			}
			d := u64(intrinsics.count_trailing_zeros(u32(bs)))
			// Only the chunk's leading `d < CHUNK` clean bytes. The rest is escape text.
			for k in 0 ..< int(d) {
				dst[out + k] = src[p + u64(k)]
			}
			p += d
			out += int(d)
			// The escape unit, then any `\u` immediately after it, without a chunk scan that would find
			// a backslash at lane 0. `p + 6 <= end` keeps the fold inside the token.
			for {
				wrote, next, ok := decode_escape_unit(src, p, end, dst[out:])
				if !ok {
					return -1
				}
				out += wrote
				p = next
				if !(p + 6 <= end && src[p] == '\\' && src[p+1] == 'u') {
					break
				}
			}
		}
	}
	return dom_unescape_tail(dst, src, p, end, out)
}

// The selected decoder, so every call site names one proc. `first_esc` is as in `dom_unescape_copy`. A
// token the bulk copy declines takes `dom_unescape_scalar`.
dom_unescape_into :: #force_inline proc(dst: []u8, src: []byte, lo, hi: u64, first_esc: u64 = 0) -> int {
	// An addition because `hi - lo - 2` underflows on a span too short to be a token. `SCAN_FORCE_SLOW`
	// compiles the bulk route out.
	when !SCAN_FORCE_SLOW {
		if hi >= lo + 2 + u64(DOM_COPY_MIN_SPELL) {
			return dom_unescape_copy(dst, src, lo, hi, first_esc)
		}
	}
	return dom_unescape_scalar(dst, src, lo, hi)
}

// Four hex digits at `p`, or not. `end` is the first byte past the token's content.
@(private = "file")
hex4_at :: #force_inline proc(src: []byte, p, end: u64) -> (v: u32, ok: bool) {
	if p > end || end - p < 4 {
		return 0, false
	}
	return lex.hex4(src, p)
}

// One escape at `src[p] == '\\'`, written into `unit`. Both copy loops and `name_equals` call it. `end` is
// exclusive, and neither the unit nor a surrogate pair's lookahead reads past it. A malformed or truncated
// escape, or a lone surrogate half, is `ok = false`.
decode_escape_unit :: #force_inline proc(src: []byte, p, end: u64, unit: []u8) -> (n: int, next: u64, ok: bool) {
	if p + 1 >= end {
		return 0, p, false
	}
	e := src[p + 1]
	if dec := lex.ESC_BYTE[e]; dec != 0 {
		unit[0] = dec
		return 1, p + 2, true
	}
	if e != 'u' {
		return 0, p, false
	}
	cp, hex_ok := hex4_at(src, p + 2, end)
	if !hex_ok {
		return 0, p, false
	}
	next = p + 6
	if cp - 0xD800 < 0x800 {
		if cp >= 0xDC00 || next + 6 > end || src[next] != '\\' || src[next + 1] != 'u' {
			return 0, p, false
		}
		lo, lo_ok := hex4_at(src, next + 2, end)
		if !lo_ok || lo - 0xDC00 >= 0x400 {
			return 0, p, false
		}
		cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
		next += 6
	}
	if cp < 0x80 {
		unit[0] = u8(cp)
		return 1, next, true
	}
	spelled, size := utf8.encode_rune(rune(cp))
	return copy(unit, spelled[:size]), next, true
}

// One object key against one step name, by decoded text. [lo,hi) includes the key's quotes and was bounded
// by the walk's string leaf, so this compares bytes already accepted and never checks grammar. Escapes
// decode one unit at a time into a four-byte window, so no key-sized buffer exists. Under `.Structural`
// a malformed escape reaches this compare and simply fails to match.
name_equals :: proc(src: []byte, lo, hi: u64, name: string) -> bool {
	if hi < lo + 2 || src[lo] != '"' || src[hi - 1] != '"' {
		return false
	}
	end := hi - 1
	p := lo + 1
	at := 0
	// An escape writes more bytes than it decodes to, so a shorter text cannot be the name, and one of its
	// length is the name only when it holds no escape.
	if spelled := end - p; spelled <= u64(len(name)) {
		if spelled < u64(len(name)) {
			return false
		}
		text := src[p:end]
		#no_bounds_check for i in 0 ..< len(text) {
			if text[i] != name[i] || text[i] == '\\' {
				return false
			}
		}
		return true
	}
	for p < end {
		if at >= len(name) {
			return false
		}
		c := src[p]
		if c != '\\' {
			if name[at] != c {
				return false
			}
			p += 1
			at += 1
			continue
		}
		unit: [4]byte
		n, next, ok := decode_escape_unit(src, p, end, unit[:])
		if !ok || at + n > len(name) {
			return false
		}
		for i in 0 ..< n {
			if name[at + i] != unit[i] {
				return false
			}
		}
		p = next
		at += n
	}
	return at == len(name)
}
