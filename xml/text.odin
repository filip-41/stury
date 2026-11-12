package xml

import "base:intrinsics"
import "core:simd"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"

// The runs of characters the states read between markup: character data, an attribute value, a CDATA section, a
// comment and a processing instruction. A run is read to the byte that ends it, judging every character: the `Char`
// production, UTF-8, references, and the rule each kind of run has for its ending bytes. `run_span` reads 64-byte blocks and
// returns nil when it cannot vouch for the run. `exact` then reads it byte by byte and returns the fault.

// What a run is, which fixes the bytes that end it and the bytes it refuses.
@(private)
Mode :: enum u8 {
	Text, // character data: ends at `<`, takes references, refuses `]]>`
	Attr, // an attribute value: ends at its quote, takes references, refuses `<`
	Cdata, // a CDATA section: ends at `]]>`
	Comment, // a comment: ends at `-->`, refuses `--`
	Pi, // a processing instruction: ends at `?>`
}

@(private)
Run :: struct {
	// Where the run ends: the `<` of Text, the quote of Attr, the first byte of the closing `]]>`, `-->` or `?>`.
	q:      [^]u8,
	// Whether the run holds a byte that decoding changes: a reference, or a CR, a tab or an LF in an attribute value.
	decode: bool,
	kind:   core.Fault_Kind,
	detail: Detail,
	// One past the index of the entity whose reference at `q` the walk descends into, 0 for none.
	entity: u32,
}

#assert(size_of(Run) == 16)

// Returns the length of the reference at `p`, where `p[0]` is `&`, or 0 with the fault. Only the five predefined entities
// and character references naming a `Char` are legal without a DTD.
@(private)
reference :: #force_inline proc "contextless" (p, end: [^]u8) -> (n: int, kind: core.Fault_Kind, detail: Detail) #no_bounds_check {
	room := intrinsics.ptr_sub(end, p)
	if room >= 6 {
		switch p[1] {
		case 'a':
			if p[2] == 'm' && p[3] == 'p' && p[4] == ';' {
				return 5, .None, .None
			}
			if p[2] == 'p' && p[3] == 'o' && p[4] == 's' && p[5] == ';' {
				return 6, .None, .None
			}
		case 'l':
			if p[2] == 't' && p[3] == ';' {
				return 4, .None, .None
			}
		case 'g':
			if p[2] == 't' && p[3] == ';' {
				return 4, .None, .None
			}
		case 'q':
			if p[2] == 'u' && p[3] == 'o' && p[4] == 't' && p[5] == ';' {
				return 6, .None, .None
			}
		}
	}
	return reference_slow(p, end)
}

@(private, cold)
reference_slow :: #force_no_inline proc "contextless" (p, end: [^]u8) -> (n: int, kind: core.Fault_Kind, detail: Detail) #no_bounds_check {
	room := intrinsics.ptr_sub(end, p)
	if room < 2 {
		return 0, .Truncated, .None
	}
	if p[1] == '#' {
		q := p[2:]
		base := u32(10)
		if q < end && q[0] == 'x' {
			base = 16
			q = q[1:]
		}
		digits := q
		cp: u32
		for q < end {
			d := hex_digit(q[0])
			if d >= base {
				break
			}
			cp = min(cp * base + d, 0x11_0000)
			q = q[1:]
		}
		if q >= end {
			return 0, .Truncated, .None
		}
		if q == digits || q[0] != ';' {
			return 0, .Bad_Char, .Reference
		}
		if !char_legal(cp) {
			return 0, .Bad_Char, .Char_Reference
		}
		return intrinsics.ptr_sub(q, p) + 1, .None, .None
	}
	q, fault := name_end(p[1:], end)
	switch fault {
	case .Truncated:
		return 0, .Truncated, .None
	case .Not_Name, .Bad_Utf8:
		return 0, .Bad_Char, .Reference
	case .None:
	}
	if q >= end {
		return 0, .Truncated, .None
	}
	if q[0] != ';' {
		return 0, .Bad_Char, .Reference
	}
	return 0, .Bad_Char, .Undeclared_Entity
}

@(private)
hex_digit :: #force_inline proc "contextless" (c: u8) -> u32 {
	switch {
	case '0' <= c && c <= '9':
		return u32(c - '0')
	case 'a' <= c | 0x20 && c | 0x20 <= 'f':
		return u32(c | 0x20 - 'a' + 10)
	}
	return 16
}

// Whether `cp` is a `Char`: tab, LF, CR, U+0020 to U+D7FF, U+E000 to U+FFFD, and U+10000 to U+10FFFF.
@(private)
char_legal :: #force_inline proc "contextless" (cp: u32) -> bool {
	return cp == 0x9 || cp == 0xa || cp == 0xd || 0x20 <= cp && cp <= 0xd7ff || 0xe000 <= cp && cp <= 0xfffd || 0x1_0000 <= cp && cp <= 0x10_ffff
}

// Whether the character at `p`, where `p[0]` is 0xEF, is U+FFFE or U+FFFF, the two noncharacters `Char` leaves out
// that UTF-8 allows. Bytes past `end` are not read.
@(private)
non_char :: #force_inline proc "contextless" (p, end: [^]u8) -> bool #no_bounds_check {
	return intrinsics.ptr_sub(end, p) >= 3 && p[1] == 0xbf && p[2] >= 0xbe
}

// The mask of the lanes of 16 bytes that end or interrupt a run of `mode`: its ending bytes, the bytes it steps over
// with a check, and the control bytes it refuses. Tab and LF are no stop in text, CDATA, comments and instructions,
// and CR is a stop in the first two so `exact` and `run_span` can mark the run for decoding.
@(private)
stops16 :: #force_inline proc "contextless" (v: #simd[16]u8, $M: Mode, $quote: u8) -> #simd[16]u8 {
	V :: #simd[16]u8
	ctl := simd.lanes_lt(v, V(0x20))
	when M == .Text {
		ctl = simd.bit_and_not(ctl, simd.bit_or(simd.lanes_eq(v, V(9)), simd.lanes_eq(v, V(10))))
		special := simd.bit_or(simd.bit_or(simd.lanes_eq(v, V('<')), simd.lanes_eq(v, V('&'))), simd.lanes_eq(v, V(']')))
	} else when M == .Attr {
		special := simd.bit_or(simd.bit_or(simd.lanes_eq(v, V(quote)), simd.lanes_eq(v, V('<'))), simd.lanes_eq(v, V('&')))
	} else when M == .Cdata {
		ctl = simd.bit_and_not(ctl, simd.bit_or(simd.lanes_eq(v, V(9)), simd.lanes_eq(v, V(10))))
		special := simd.lanes_eq(v, V(']'))
	} else when M == .Comment {
		ctl = simd.bit_and_not(ctl, simd.bit_or(simd.bit_or(simd.lanes_eq(v, V(9)), simd.lanes_eq(v, V(10))), simd.lanes_eq(v, V(13))))
		special := simd.lanes_eq(v, V('-'))
	} else {
		ctl = simd.bit_and_not(ctl, simd.bit_or(simd.bit_or(simd.lanes_eq(v, V(9)), simd.lanes_eq(v, V(10))), simd.lanes_eq(v, V(13))))
		special := simd.lanes_eq(v, V('?'))
	}
	return simd.bit_or(ctl, special)
}

@(private)
stops_block :: #force_inline proc "contextless" (b: kernel.Block, $M: Mode, $quote: u8) -> kernel.Block {
	return {stops16(b[0], M, quote), stops16(b[1], M, quote), stops16(b[2], M, quote), stops16(b[3], M, quote)}
}

// Reads the run of `mode` that starts at `p`, with this CPU's block reader and then `exact` when that cannot vouch.
@(private)
run :: #force_inline proc "contextless" (w: ^Walk($H), p, end: [^]u8, $M: Mode, $quote: u8) -> Run {
	q: [^]u8
	decode: bool
	when ODIN_ARCH == .amd64 {
		switch w.tier {
		case .V4:
			q, decode = span_v4(p, end, M, quote)
		case .V3:
			q, decode = span_v3(p, end, M, quote)
		case .V2:
			q, decode = span_v2(p, end, M, quote)
		}
	} else {
		q, decode = span_base(p, end, M, quote)
	}
	if q == nil {
		return exact(p, end, M, quote, w.dtd)
	}
	return {q, decode, .None, .None, 0}
}

when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	span_v2 :: #force_no_inline proc "contextless" (p, end: [^]u8, $M: Mode, $quote: u8) -> ([^]u8, bool) {
		return run_span(.V2, p, end, M, quote)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	span_v3 :: #force_no_inline proc "contextless" (p, end: [^]u8, $M: Mode, $quote: u8) -> ([^]u8, bool) {
		return run_span(.V3, p, end, M, quote)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	span_v4 :: #force_no_inline proc "contextless" (p, end: [^]u8, $M: Mode, $quote: u8) -> ([^]u8, bool) {
		return run_span(.V4, p, end, M, quote)
	}
} else {
	@(private)
	span_base :: #force_no_inline proc "contextless" (p, end: [^]u8, $M: Mode, $quote: u8) -> ([^]u8, bool) {
		return run_span(.Base, p, end, M, quote)
	}
}

// Reads a run 64 bytes at a time while every byte is one the run takes. Returns where it ends and whether it holds a
// byte decoding changes, or nil when a byte needs `exact`: a refused byte, ill-formed UTF-8, U+FFFE or U+FFFF, a
// reference that is not legal, or the text's end. UTF-8 state carries between blocks, and the stops of a block are
// stepped over in its mask, so a block is loaded once.
@(private)
run_span :: #force_inline proc "contextless" ($T: kernel.Tier, p, end: [^]u8, $M: Mode, $quote: u8) -> (q: [^]u8, decode: bool) #no_bounds_check {
	bs := p
	skip: u64
	u: kernel.Utf8_State
	// Whether the last block had a byte past 0x7F. An ASCII block after one closes the UTF-8 state.
	high: bool
	for {
		live := u64(intrinsics.ptr_sub(end, bs))
		b: kernel.Block
		if live >= 64 {
			b = kernel.load(bs)
		} else if live > 0 {
			// Zeros past `live` are ASCII to the UTF-8 state and control stops, so `k >= live` ends the run.
			b = kernel.load_padded(T, bs[:live], 0)
		} else {
			return nil, false
		}
		ascii := kernel.is_ascii(b)
		if !ascii {
			if ef := kernel.pack(kernel.eq(b, 0xef)); ef != 0 {
				for m := ef; m != 0; m &= m - 1 {
					if non_char(bs[intrinsics.count_trailing_zeros(m):], end) {
						return nil, false
					}
				}
			}
		}
		sv := stops_block(b, M, quote)
		if skip == 0 && !kernel.any_lane(sv) {
			kernel.utf8_next(T, b, ascii, &u, &high)
			bs = bs[64:]
			continue
		}
		stop := kernel.pack(sv) & (max(u64) << skip)
		skip = 0
		for stop != 0 {
			k := intrinsics.count_trailing_zeros(stop)
			if k >= live {
				return nil, false
			}
			c := bs[k]
			n := u64(1)
			ends := false
			when M == .Text {
				switch c {
				case '<':
					ends = true
				case '&':
					r, kind, _ := reference(bs[k:], end)
					if kind != .None {
						return nil, false
					}
					decode = true
					n = u64(r)
				case ']':
					if k + 2 >= live {
						return nil, false
					}
					if bs[k + 1] == ']' && bs[k + 2] == '>' {
						return nil, false
					}
				case '\r':
					decode = true
				case:
					return nil, false
				}
			} else when M == .Attr {
				switch c {
				case quote:
					ends = true
				case '&':
					r, kind, _ := reference(bs[k:], end)
					if kind != .None {
						return nil, false
					}
					n = u64(r)
					decode = true
				case '\t', '\n', '\r':
					decode = true
				case:
					return nil, false
				}
			} else when M == .Cdata {
				switch c {
				case ']':
					if k + 2 >= live {
						return nil, false
					}
					ends = bs[k + 1] == ']' && bs[k + 2] == '>'
				case '\r':
					decode = true
				case:
					return nil, false
				}
			} else when M == .Comment {
				if c != '-' {
					return nil, false
				}
				if k + 2 >= live {
					return nil, false
				}
				if bs[k + 1] == '-' {
					if bs[k + 2] != '>' {
						return nil, false
					}
					ends = true
				}
			} else {
				if c != '?' || k + 1 >= live {
					return nil, false
				}
				ends = bs[k + 1] == '>'
			}
			if ends {
				// The run ends in this block, so only the vectors up to its end are read.
				if !ascii {
					kernel.utf8_head(T, b, &u, k)
				} else if high {
					kernel.utf8_ascii_block(T, &u)
				}
				if !kernel.utf8_clean(T, u) {
					return nil, false
				}
				return bs[k:], decode
			}
			k += n
			if k >= 64 {
				skip = k - 64
				break
			}
			stop &= max(u64) << k
		}
		kernel.utf8_next(T, b, ascii, &u, &high)
		bs = bs[64:]
	}
}

// Reads the run of `mode` that starts at `p` one byte at a time. Returns where it ends, or the fault at the first
// byte that breaks it. A reference to an entity is judged by `dtd`, and one whose replacement holds markup ends a
// text run with the entity to descend into.
@(private, cold)
exact :: #force_no_inline proc "contextless" (p, end: [^]u8, $M: Mode, $quote: u8, dtd: ^Dtd) -> Run #no_bounds_check {
	q := p
	decode: bool
	for {
		if q >= end {
			return {end, decode, .Truncated, .None, 0}
		}
		c := q[0]
		if c >= 0x80 {
			r, kind := spell.utf8_char(q, end)
			if kind == .Truncated {
				return {end, decode, .Truncated, .None, 0}
			}
			if kind != .None {
				return {q, decode, .Bad_Char, .Invalid_Utf8, 0}
			}
			if c == 0xef && non_char(q, end) {
				return {q, decode, .Bad_Char, .Non_Char, 0}
			}
			q = r
			continue
		}
		when M == .Text {
			switch c {
			case '<':
				return {q, decode, .None, .None, 0}
			case '&':
				n, kind, detail := reference(q, end)
				if kind == .Bad_Char && detail == .Undeclared_Entity && dtd != nil {
					entity: u32
					n, kind, detail, entity = entity_reference(dtd, q, end, false)
					if entity != 0 {
						return {q, decode, .Bad_Char, .None, entity}
					}
				}
				if kind != .None {
					return {q, decode, kind, detail, 0}
				}
				decode = true
				q = q[n:]
				continue
			case ']':
				if intrinsics.ptr_sub(end, q) >= 3 && q[1] == ']' && q[2] == '>' {
					return {q, decode, .Bad_Char, .Cdata_End, 0}
				}
			case '\r':
				decode = true
			case '\t', '\n':
			case:
				if c < 0x20 {
					return {q, decode, .Bad_Char, .Control_Char, 0}
				}
			}
		} else when M == .Attr {
			switch c {
			case quote:
				return {q, decode, .None, .None, 0}
			case '<':
				return {q, decode, .Bad_Char, .Attribute_Lt, 0}
			case '&':
				n, kind, detail := reference(q, end)
				if kind == .Bad_Char && detail == .Undeclared_Entity && dtd != nil {
					n, kind, detail, _ = entity_reference(dtd, q, end, true)
				}
				if kind != .None {
					return {q, decode, kind, detail, 0}
				}
				decode = true
				q = q[n:]
				continue
			case '\t', '\n', '\r':
				decode = true
			case:
				if c < 0x20 {
					return {q, decode, .Bad_Char, .Control_Char, 0}
				}
			}
		} else when M == .Cdata {
			switch c {
			case ']':
				if intrinsics.ptr_sub(end, q) >= 3 && q[1] == ']' && q[2] == '>' {
					return {q, decode, .None, .None, 0}
				}
			case '\r':
				decode = true
			case '\t', '\n':
			case:
				if c < 0x20 {
					return {q, decode, .Bad_Char, .Control_Char, 0}
				}
			}
		} else when M == .Comment {
			if c == '-' && intrinsics.ptr_sub(end, q) >= 2 && q[1] == '-' {
				if intrinsics.ptr_sub(end, q) < 3 {
					return {end, decode, .Truncated, .None, 0}
				}
				if q[2] == '>' {
					return {q, decode, .None, .None, 0}
				}
				return {q, decode, .Bad_Char, .Comment_Dashes, 0}
			}
			if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
				return {q, decode, .Bad_Char, .Control_Char, 0}
			}
		} else {
			if c == '?' && intrinsics.ptr_sub(end, q) >= 2 && q[1] == '>' {
				return {q, decode, .None, .None, 0}
			}
			if c < 0x20 && c != '\t' && c != '\n' && c != '\r' {
				return {q, decode, .Bad_Char, .Control_Char, 0}
			}
		}
		q = q[1:]
	}
}
