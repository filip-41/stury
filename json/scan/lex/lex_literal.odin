package lex

// One escape unit's extent, unchecked: the backslash and the byte it escapes,
// and for `\u` up to four more bytes. A quote or backslash among those four
// ends the unit early, so a malformed `\u` cannot carry the string past a
// quote: the backslash escapes one byte, which is the boundary rule stage 1
// classifies by.
skip_escape :: #force_inline proc(s: ^Scanner) -> Maybe(Error) {
	n := u64(len(s.src))
	s.pos += 1 // the backslash
	if s.pos >= n {
		return Error{offset = n, kind = .Truncated}
	}
	if s.src[s.pos] != 'u' {
		if s.src[s.pos] < 0x80 {
			s.pos += 1
			return nil
		}
		return utf8_step_checked(s)
	}
	s.pos += 1 // the u
	end := s.pos + 4
	// Fast path: four ASCII bytes with no quote or backslash, the shape of
	// every well-formed unit, are valid UTF-8 by inspection and advance whole.
	when !SCAN_FORCE_SLOW {
		if end <= n {
			w := load32_le(s.src, s.pos)
			if w & 0x80808080 == 0 && !has_byte32(w, '"') && !has_byte32(w, '\\') {
				s.pos = end
				return nil
			}
		}
	}
	for s.pos < end && s.pos < n {
		c := s.src[s.pos]
		if c == '"' || c == '\\' {
			break
		}
		if c < 0x80 {
			s.pos += 1
			continue
		}
		if err := utf8_step_checked(s); err != nil {
			return err
		}
	}
	return nil
}

// Whether any of the four bytes of `w` is `b`.
@(private = "file")
has_byte32 :: #force_inline proc(w: u32, b: u8) -> bool {
	x := w ~ (u32(b) * 0x01010101)
	return (x - 0x01010101) & ~x & 0x80808080 != 0
}

// 4, 5, or 0. A hit is `true` / `false` / `null` at `p`. `SCAN_FORCE_SLOW`
// and a short tail are 0 so the caller walks bytes.
@(private = "file")
literal_word :: #force_inline proc(src: []byte, p: u64) -> u64 {
	n := u64(len(src))
	when SCAN_FORCE_SLOW {
		return 0
	}
	if p + 5 > n {
		return 0
	}
	// No branch on which word: `true` and `false` alternate at random in a column of flags.
	#no_bounds_check {
		w := load32_le(src, p)
		four := u64(w == TRUE_U32) | u64(w == NULL_U32)
		five := u64(w == FALS_U32) & u64(src[p + 4] == 'e')
		return four << 2 | five * 5
	}
}

parse_literal_q :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	lo: u64,
	$Q: bit_set[Walk_Kind],
) -> Maybe(Error) {
	if k := literal_word(s.src, s.pos); k != 0 {
		s.pos += k
	} else {
		word := "null"
		if s.src[s.pos] == 't' {
			word = "true"
		} else if s.src[s.pos] == 'f' {
			word = "false"
		}
		for i := 0; i < len(word); i += 1 {
			if s.pos >= u64(len(s.src)) {
				return Error{offset = u64(len(s.src)), kind = .Truncated}
			}
			if s.src[s.pos] != word[i] {
				return Error{offset = s.pos, kind = KIND_LITERAL}
			}
			s.pos += 1
		}
	}
	emit_literal(s, q, lo, Q)
	return nil
}

// Literal shape only: an alpha run where t/f/n starts one. Contents are not
// checked. The row reports the extent and the shape named by the first byte.
skip_alpha_q :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	lo: u64,
	$Q: bit_set[Walk_Kind],
) -> Maybe(Error) {
	// A matched word still falls through: `truetrue` is a longer alpha run.
	if k := literal_word(s.src, s.pos); k != 0 {
		s.pos += k
	}
	for s.pos < u64(len(s.src)) && CHAR_FLAGS[s.src[s.pos]] & F_ALPHA != 0 {
		s.pos += 1
	}
	emit_literal(s, q, lo, Q)
	return nil
}
