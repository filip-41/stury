package lex

import "base:intrinsics"

// .Dom: the rest of one escaped string value, decoded onto the end of the sink's value bytes while the walk
// checks it, so no second pass reads its escapes again (`emit_dom_string`'s counted route, which a sink without
// room for the decode still takes). The clean bytes between escapes are copied when the next escape or the
// closing quote is reached. The post-escape probe copies the few right after an escape as it steps over them.
// The call is out of line and given a pointer to the spare bytes alone, so a string without a backslash pays
// nothing for it.
@(private = "file")
Dom_Fuse :: struct {
	dst:  [^]u8,
	out:  int,
	// The source offset of the first byte not yet copied.
	from: u64,
}

// Copy the clean bytes `[from, to)`.
@(private = "file")
dom_fuse_flush :: #force_inline proc(f: ^Dom_Fuse, src: []byte, to: u64) {
	n := int(to - f.from)
	if n > 0 {
		d := f.dst[f.out:]
		p := raw_data(src[f.from:])
		// A run is mostly a few bytes between escapes, where a copy call costs more than the bytes: two
		// loads and two stores that overlap cover 1-3, 4-7 and 8-15 bytes.
		switch {
		case n >= 16:
			intrinsics.mem_copy_non_overlapping(d, p, n)
		case n >= 8:
			a := intrinsics.unaligned_load((^u64)(p))
			b := intrinsics.unaligned_load((^u64)(p[n - 8:]))
			intrinsics.unaligned_store((^u64)(d), a)
			intrinsics.unaligned_store((^u64)(d[n - 8:]), b)
		case n >= 4:
			a := intrinsics.unaligned_load((^u32)(p))
			b := intrinsics.unaligned_load((^u32)(p[n - 4:]))
			intrinsics.unaligned_store((^u32)(d), a)
			intrinsics.unaligned_store((^u32)(d[n - 4:]), b)
		case:
			a, b, c := p[0], p[n >> 1], p[n - 1]
			d[0], d[n >> 1], d[n - 1] = a, b, c
		}
		f.out += n
	}
}

// Write the scalar `cp` as UTF-8. A surrogate half never arrives: `escape_unit` refuses a lone one.
@(private = "file")
dom_fuse_put :: #force_inline proc(f: ^Dom_Fuse, cp: u32) {
	p := f.dst[f.out:]
	switch {
	case cp < 0x80:
		p[0] = u8(cp)
		f.out += 1
	case cp < 0x800:
		p[0] = 0xC0 | u8(cp >> 6)
		p[1] = 0x80 | u8(cp & 0x3F)
		f.out += 2
	case cp < 0x10000:
		p[0] = 0xE0 | u8(cp >> 12)
		p[1] = 0x80 | u8(cp >> 6 & 0x3F)
		p[2] = 0x80 | u8(cp & 0x3F)
		f.out += 3
	case:
		p[0] = 0xF0 | u8(cp >> 18)
		p[1] = 0x80 | u8(cp >> 12 & 0x3F)
		p[2] = 0x80 | u8(cp >> 6 & 0x3F)
		p[3] = 0x80 | u8(cp & 0x3F)
		f.out += 4
	}
}

// The escape at the backslash `s.pos`, decoded. A two-byte escape and a `\u` escape outside the surrogates
// take one route with no branch on which they are: both answers are computed and selected, and the UTF-8
// goes out as one 4-byte store whose length is selected too, so mixed escapes cost no mispredictions. The
// store's spare bytes stay inside `dst`, which holds the source's rest, and decoded bytes never outrun
// source ones: `out` is at most `s.pos - lo - 1` and `s.pos + 6 <= len`. Anything else (a surrogate, a bad
// operand, the end of input near) takes `escape_unit`, which answers it as the walk does.
@(private = "file")
dom_fuse_escape :: #force_inline proc(f: ^Dom_Fuse, s: ^Scanner) -> Maybe(Error) {
	p := s.pos
	#no_bounds_check if p + 6 <= u64(len(s.src)) {
		src := s.src
		b := u32(ESC_BYTE[src[p + 1]])
		n0 := u32(HEX_NIBBLE[src[p + 2]])
		n1 := u32(HEX_NIBBLE[src[p + 3]])
		n2 := u32(HEX_NIBBLE[src[p + 4]])
		n3 := u32(HEX_NIBBLE[src[p + 5]])
		unit := n0 << 12 | n1 << 8 | n2 << 4 | n3
		u_ok := u32(src[p + 1] == 'u') & u32((n0 | n1 | n2 | n3) & 0xF0 == 0) & u32(unit - 0xD800 >= 0x800)
		if b | u_ok != 0 {
			cp := b != 0 ? b : unit
			adv := b != 0 ? u64(2) : u64(6)
			two := (0xC0 | cp >> 6) | (0x80 | cp & 0x3F) << 8
			three := (0xE0 | cp >> 12) | (0x80 | cp >> 6 & 0x3F) << 8 | (0x80 | cp & 0x3F) << 16
			// Masks, not selects: a select over these is lowered as a branch on the width.
			ge80, ge800 := u32(cp >= 0x80), u32(cp >= 0x800)
			word := cp & (ge80 - 1) | two & (0 - (ge80 ~ ge800)) | three & (0 - ge800)
			intrinsics.unaligned_store((^u32le)(&f.dst[f.out]), u32le(word))
			f.out += 1 + int(ge80 + ge800)
			s.pos = p + adv
			return nil
		}
	}
	cp: u32
	if err := escape_unit(s, &cp, true); err != nil {
		return err
	}
	dom_fuse_put(f, cp)
	return nil
}

// The string at `lo`, whose first backslash is `bs`, decoded to its closing quote into `dst`, which holds the
// source's remaining length (`src[lo:]`), the most it can decode to. The answer is the offset past the quote
// with `.None`, or a fault, and the decoded length. The sink is handed over as a pointer to its spare bytes and
// nothing else: a call that is handed the query context, or a pointer into it, makes the walk reload what it
// keeps there.
dom_string_fused :: #force_no_inline proc(src: []byte, dst: [^]u8, lo, bs: u64) -> (end: Error, n: int) {
	f: Dom_Fuse
	f.dst = dst
	f.from = lo + 1
	dom_fuse_flush(&f, src, bs)
	s := Scanner{src = src, pos = bs}
	for {
		// `s.pos` is at a backslash.
		if err := dom_fuse_escape(&f, &s); err != nil {
			return err.(Error), 0
		}
		// Post-escape run, as `string_q`: the next backslash, the closing quote, or a few clean bytes come
		// right after an escape, so take them inline. Three consecutive clean bytes mean a long gap.
		run := 0
		probe: for _ in 0 ..< PROBE_HEAD {
			if s.pos >= u64(len(src)) {
				return Error{offset = u64(len(src)), kind = .Truncated}, 0
			}
			d := src[s.pos]
			switch {
			case d == '"':
				f.from = s.pos
				return dom_fuse_close(&f, src, s.pos)
			case d == '\\':
				if err := dom_fuse_escape(&f, &s); err != nil {
					return err.(Error), 0
				}
				run = 0
			case d < 0x20:
				return Error{offset = s.pos, kind = .Bad_Char}, 0
			case d < 0x80:
				f.dst[f.out] = d
				f.out += 1
				s.pos += 1
				run += 1
				if run == 3 {
					break probe
				}
			case:
				// Wire UTF-8 binds at every level.
				start := s.pos
				if err := utf8_step_checked(&s); err != nil {
					return err.(Error), 0
				}
				f.from = start
				dom_fuse_flush(&f, src, s.pos)
				run += 1
				if run == 3 {
					break probe
				}
			}
		}
		f.from = s.pos
		// The span to the next quote, backslash, control or high byte.
		for {
			at := span_advance(&s, .Values, true)
			if at < 0 {
				return Error{offset = u64(len(src)), kind = .Truncated}, 0
			}
			c := u8(at)
			if c == '"' {
				return dom_fuse_close(&f, src, s.pos)
			}
			if c == '\\' {
				dom_fuse_flush(&f, src, s.pos)
				break
			}
			if c < 0x20 {
				return Error{offset = s.pos, kind = .Bad_Char}, 0
			}
			if c < 0x80 {
				s.pos += 1
			} else if err := utf8_step_checked(&s); err != nil {
				return err.(Error), 0
			}
		}
	}
}

// The closing quote at `quote`: the tail is copied.
@(private = "file")
dom_fuse_close :: #force_inline proc(f: ^Dom_Fuse, src: []byte, quote: u64) -> (Error, int) {
	dom_fuse_flush(f, src, quote)
	return Error{offset = quote + 1}, f.out
}
