package lex

// Walk-time escape validation and decoded-length accounting (strict string leaf).

import core_pkg "../../../core"

// One escape unit at the backslash `s.pos`, checked and stepped over. A surrogate pair is one unit, and a
// lone surrogate half of either kind is refused (`surrogate_pair`). With `$decode`, `cp^` is what it
// decodes to: a one-byte escape's byte, or a `\u` escape's scalar. Without it nothing is written: a walk
// that keeps no decoded count compiles the checking walk alone.
escape_unit :: #force_inline proc(s: ^Scanner, cp: ^u32, $decode: bool) -> Maybe(Error) {
	s.pos += 1
	if s.pos >= u64(len(s.src)) {
		return Error{offset = u64(len(s.src)), kind = .Truncated}
	}
	e := s.src[s.pos]
	if dec := core_pkg.ESC_BYTE[e]; dec != 0 {
		s.pos += 1
		when decode {
			cp^ = u32(dec)
		}
		return nil
	}
	if e == 'u' {
		s.pos += 1
		unit: u32
		read := false
		when !SCAN_FORCE_SLOW {
			if s.pos + 4 <= u64(len(s.src)) {
				#no_bounds_check {
					n0 := core_pkg.HEX_NIBBLE[s.src[s.pos]]
					n1 := core_pkg.HEX_NIBBLE[s.src[s.pos + 1]]
					n2 := core_pkg.HEX_NIBBLE[s.src[s.pos + 2]]
					n3 := core_pkg.HEX_NIBBLE[s.src[s.pos + 3]]
					if (n0 | n1 | n2 | n3) & 0xF0 != 0 {
						if n0 == 0xFF {
							return Error{offset = s.pos, kind = .Bad_Escape}
						}
						if n1 == 0xFF {
							return Error{offset = s.pos + 1, kind = .Bad_Escape}
						}
						if n2 == 0xFF {
							return Error{offset = s.pos + 2, kind = .Bad_Escape}
						}
						return Error{offset = s.pos + 3, kind = .Bad_Escape}
					}
					s.pos += 4
					unit = u32(n0) << 12 | u32(n1) << 8 | u32(n2) << 4 | u32(n3)
					read = true
				}
			}
		}
		if !read {
			for _ in 0 ..< 4 {
				if s.pos >= u64(len(s.src)) {
					return Error{offset = u64(len(s.src)), kind = .Truncated}
				}
				n := core_pkg.HEX_NIBBLE[s.src[s.pos]]
				if n == 0xFF {
					return Error{offset = s.pos, kind = .Bad_Escape}
				}
				unit = unit << 4 | u32(n)
				s.pos += 1
			}
		}
		// Both surrogate halves in one compare: `[0xD800, 0xE000)`.
		if unit - 0xD800 < 0x800 {
			when decode {
				// The scalar needs the low half's digits, so the pair is read inline and only the refusal
				// is out of line: nothing the walk keeps is live across a call.
				low: u32
				paired := false
				if unit < 0xDC00 && s.pos + 6 <= u64(len(s.src)) {
					#no_bounds_check {
						hex_ok: bool
						low, hex_ok = hex4(s.src, s.pos + 2)
						paired = s.src[s.pos] == '\\' && s.src[s.pos + 1] == 'u' && hex_ok && low - 0xDC00 < 0x400
					}
				}
				if !paired {
					return lone_surrogate(s.src, s.pos, unit)
				}
				unit = 0x10000 + (unit - 0xD800) << 10 + (low - 0xDC00)
			} else {
				if _, err := surrogate_pair(s.src, s.pos, unit); err != nil {
					return err
				}
			}
			s.pos += 6
		}
		when decode {
			cp^ = unit
		}
		return nil
	}
	return Error{offset = s.pos, kind = .Bad_Escape}
}

// The scalar of the surrogate half `unit`, written by the six bytes before `pos`, paired with the low half
// written at `pos`. A high half no low one follows, or a low half alone, is `.Bad_Escape` at its backslash.
// An input that ends inside the low half's text is `.Truncated`. Out of line, since only a surrogate
// escape reaches it, and by value, so the scanner the walk keeps in registers is not handed to a call.
@(private = "file")
surrogate_pair :: #force_no_inline proc(src: []byte, pos: u64, unit: u32) -> (scalar: u32, err: Maybe(Error)) {
	at := pos - 6
	if unit >= 0xDC00 {
		return 0, Error{offset = at, kind = .Bad_Escape}
	}
	n := u64(len(src))
	low: u32
	// The escape and four hex digits in `[DC00, DFFF]`, byte by byte, so an input cut inside them is told apart.
	for i in u64(0) ..< 6 {
		if pos + i >= n {
			return 0, Error{offset = n, kind = .Truncated}
		}
		c := src[pos + i]
		h := core_pkg.HEX_NIBBLE[c]
		ok: bool
		switch i {
		case 0: ok = c == '\\'
		case 1: ok = c == 'u'
		case 2: ok = h == 0xD
		case 3: ok = h >= 0xC && h <= 0xF
		case:   ok = h != 0xFF
		}
		if !ok {
			return 0, Error{offset = at, kind = .Bad_Escape}
		}
		low = low << 4 | u32(h)
	}
	// The low ten bits are the last two and a half hex digits. The bytes before them fold in above.
	return 0x10000 + (unit - 0xD800) << 10 + (low & 0x3FF), nil
}

// The refusal `surrogate_pair` reaches for a half `unit` that pairs with nothing, as the one result a walk
// returns. Only the decoding walk calls it, and only for a lone half: it reads a pair inline.
@(private = "file")
lone_surrogate :: #force_no_inline proc(src: []byte, pos: u64, unit: u32) -> Maybe(Error) {
	_, err := surrogate_pair(src, pos, unit)
	return err
}

// The decoded bytes of an escape unit that decodes to `cp` (`escape_unit`): the scalar's UTF-8 length.
escape_decoded :: #force_inline proc(cp: u32) -> u64 {
	if cp < 0x80 {
		return 1
	} else if cp < 0x800 {
		return 2
	} else if cp < 0x10000 {
		return 3
	}
	return 4
}
