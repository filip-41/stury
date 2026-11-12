package yaml

// Writer into the caller's buffer. A write past the buffer's end sets `over` and is dropped.
@(private)
Decoded :: struct {
	buf:  []u8,
	n:    int,
	over: bool,
}

@(private)
put :: #force_inline proc "contextless" (o: ^Decoded, b: u8) {
	if o.n < len(o.buf) {
		o.buf[o.n] = b
		o.n += 1
	} else {
		o.over = true
	}
}

@(private)
put_rune :: proc "contextless" (o: ^Decoded, cp: u32) {
	switch {
	case cp < 0x80:
		put(o, u8(cp))
	case cp < 0x800:
		put(o, u8(0xc0 | cp >> 6))
		put(o, u8(0x80 | cp & 0x3f))
	case cp < 0x10000:
		put(o, u8(0xe0 | cp >> 12))
		put(o, u8(0x80 | cp >> 6 & 0x3f))
		put(o, u8(0x80 | cp & 0x3f))
	case:
		put(o, u8(0xf0 | cp >> 18))
		put(o, u8(0x80 | cp >> 12 & 0x3f))
		put(o, u8(0x80 | cp >> 6 & 0x3f))
		put(o, u8(0x80 | cp & 0x3f))
	}
}

// Decodes the text of a scalar from its source bytes `span` and the token's `spelling` into `buf`. The result borrows
// `buf`. `ok` is false when `buf` is too short.
@(private)
decode :: proc "contextless" (span: []u8, spelling: u16, buf: []u8) -> (s: string, ok: bool) {
	o := Decoded{buf = buf}
	switch style_of(spelling) {
	case .Plain:
		fold_flow(&o, span, .Plain)
	case .Single:
		fold_flow(&o, span[1:len(span) - 1], .Single)
	case .Double:
		fold_flow(&o, span[1:len(span) - 1], .Double)
	case .Block:
		decode_block(&o, span, spelling)
	}
	return string(buf[:o.n]), !o.over
}

@(private)
hex_value :: #force_inline proc "contextless" (b: u8) -> u32 {
	return u32(b - '0') if b <= '9' else u32((b | 0x20) - 'a' + 10)
}

// Decodes a plain, single-quoted or double-quoted scalar's body. Line breaks fold: one between two lines is a space,
// and each empty line adds a line feed. White space around a break is dropped, except an escape's.
@(private)
fold_flow :: proc "contextless" (o: ^Decoded, s: []u8, style: Style) {
	keep := 0
	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\n' || c == '\r':
			o.n = keep
			empties := 0
			i = skip_break(s, i)
			for {
				for i < len(s) && is_white(s[i]) {
					i += 1
				}
				if i < len(s) && is_break(s[i]) {
					i = skip_break(s, i)
					empties += 1
					continue
				}
				break
			}
			if empties == 0 {
				put(o, ' ')
			}
			for _ in 0 ..< empties {
				put(o, '\n')
			}
			keep = o.n
		case style == .Double && c == '\\':
			i += 1
			e := s[i]
			if e == '\n' || e == '\r' {
				i = skip_break(s, i)
				empties := 0
				for {
					for i < len(s) && is_white(s[i]) {
						i += 1
					}
					if i < len(s) && is_break(s[i]) {
						i = skip_break(s, i)
						empties += 1
						continue
					}
					break
				}
				for _ in 0 ..< empties {
					put(o, '\n')
				}
				keep = o.n
				continue
			}
			i += 1
			switch e {
			case '0': put(o, 0)
			case 'a': put(o, 7)
			case 'b': put(o, 8)
			case 't', '\t': put(o, '\t')
			case 'n': put(o, '\n')
			case 'v': put(o, 11)
			case 'f': put(o, 12)
			case 'r': put(o, '\r')
			case 'e': put(o, 27)
			case ' ': put(o, ' ')
			case '"': put(o, '"')
			case '/': put(o, '/')
			case '\\': put(o, '\\')
			case 'N': put_rune(o, 0x85)
			case '_': put_rune(o, 0xa0)
			case 'L': put_rune(o, 0x2028)
			case 'P': put_rune(o, 0x2029)
			case 'x', 'u', 'U':
				digits := 2 if e == 'x' else 4 if e == 'u' else 8
				cp := u32(0)
				for _ in 0 ..< digits {
					cp = cp << 4 | hex_value(s[i])
					i += 1
				}
				put_rune(o, cp)
			}
			keep = o.n
		case style == .Single && c == '\'':
			put(o, '\'')
			i += 2
			keep = o.n
		case:
			put(o, c)
			i += 1
			if !is_white(c) {
				keep = o.n
			}
		}
	}
}

@(private)
skip_break :: #force_inline proc "contextless" (s: []u8, i: int) -> int {
	if s[i] == '\r' && i + 1 < len(s) && s[i + 1] == '\n' {
		return i + 2
	}
	return i + 1
}

// Decodes a block scalar from its header through its last line. A literal scalar keeps its lines, and a folded one
// joins the lines that are not more indented with a space.
@(private)
decode_block :: proc "contextless" (o: ^Decoded, s: []u8, spelling: u16) {
	folded := s[0] == '>'
	keep, strip := false, false
	i := 1
	for i < len(s) && !is_break(s[i]) && !is_white(s[i]) {
		switch s[i] {
		case '+': keep = true
		case '-': strip = true
		}
		i += 1
	}
	for i < len(s) && !is_break(s[i]) {
		i += 1
	}
	if i >= len(s) {
		return
	}
	i = skip_break(s, i)
	ci := int(spelling >> INDENT_SHIFT) if spelling & STYLE_EXPLICIT != 0 else -1
	if ci < 0 {
		ci = max(int)
		j := i
		for j < len(s) {
			m := j
			for m < len(s) && s[m] == ' ' {
				m += 1
			}
			if m < len(s) && !is_break(s[m]) {
				ci = m - j
				break
			}
			for m < len(s) && !is_break(s[m]) {
				m += 1
			}
			j = skip_break(s, m) if m < len(s) else m
		}
	}
	// The start of the last line that holds text, or -1.
	last := -1
	for pass in 0 ..< 2 {
		first, prev_spaced := true, false
		empties := 0
		j := i
		for j < len(s) {
			m := j
			for m < len(s) && s[m] == ' ' {
				m += 1
			}
			e := m
			for e < len(s) && !is_break(s[e]) {
				e += 1
			}
			empty := m == e && m - j <= ci
			if pass == 0 {
				if !empty {
					last = j
				}
			} else if empty {
				if last >= 0 && j < last {
					empties += 1
				} else if keep {
					put(o, '\n')
				}
			} else {
				lo := min(j + ci, e)
				spaced := lo < e && is_white(s[lo])
				if first {
					for _ in 0 ..< empties {
						put(o, '\n')
					}
				} else if !folded || prev_spaced || spaced {
					for _ in 0 ..< empties + 1 {
						put(o, '\n')
					}
				} else if empties == 0 {
					put(o, ' ')
				} else {
					for _ in 0 ..< empties {
						put(o, '\n')
					}
				}
				for b in s[lo:e] {
					put(o, b)
				}
				first, prev_spaced, empties = false, spaced, 0
				if j == last && !strip {
					put(o, '\n')
				}
			}
			j = skip_break(s, e) if e < len(s) else e
		}
	}
}
