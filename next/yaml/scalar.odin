package yaml

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// YAML scalar lexers: plain, single-quoted, double-quoted, and block (`|`, `>`).
// Quoted scalars compute zero-copy `SPELLING_DECODE` / `SPELLING_ASCII` precisely so single-line strings without escapes
// or folded breaks need no decoding.

// Reads exactly `digits` hexadecimal characters from `s[at:]`, returning the codepoint and `true` iff all digits are valid.
@(private)
yaml_hex_run :: proc "contextless" (s: []u8, at, digits: int) -> (cp: u32, ok: bool) #no_bounds_check {
	if at < 0 || digits < 0 || at + digits > len(s) {
		return 0, false
	}
	for k in 0 ..< digits {
		d := spell.HEX_NIBBLE[s[at + k]]
		if d > 15 {
			return 0, false
		}
		cp = (cp << 4) | u32(d)
	}
	return cp, true
}

// Maximum byte length of an implicit YAML key.
@(private)
KEY_MAX :: 1024

@(private)
plain_first :: proc "contextless" (p: ^Parser, flow: bool) -> bool {
	b := at(p, p.pos)
	switch b {
	case '-', '?', ':':
		nx := at(p, p.pos + 1)
		return !is_space_at(p, p.pos + 1) && !(flow && is_flow_indicator(nx))
	case ',', '[', ']', '{', '}', '#', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`':
		return false
	}
	return true
}

@(private)
scan_plain :: proc "contextless" (p: ^Parser, n: int, flow, multiline: bool) -> (lines, ascii, ok: bool) #no_bounds_check {
	ascii = p.src[p.pos] < 0x80
	i, last, eol, line_ascii := scan_plain_line(p, step(p, p.pos) or_return, flow) or_return
	ascii &&= line_ascii
	for eol && multiline && i < u64(len(p.src)) {
		line, m, w := blank_lines_end(p, break_end(p, i))
		ind := int(m - line)
		if w >= u64(len(p.src)) || ind <= n || ind == 0 && marker_at(p, line) != 0 {
			break
		}
		c := p.src[w]
		if c == '#' || flow && is_flow_indicator(c) || c == ':' && (is_space_at(p, w + 1) || flow && is_flow_indicator(at(p, w + 1))) {
			break
		}
		p.ls = line
		i, last, eol, line_ascii = scan_plain_line(p, w, flow) or_return
		ascii &&= line_ascii
		lines = true
	}
	p.pos = last
	return lines, ascii, true
}

@(private)
blank_lines_end :: proc "contextless" (p: ^Parser, line: u64) -> (start, m, w: u64) #no_bounds_check {
	start = line
	for {
		m = skip_spaces(p, start)
		w = m
		for w < u64(len(p.src)) && is_white(p.src[w]) {
			w += 1
		}
		if w < u64(len(p.src)) && is_break(p.src[w]) {
			start = break_end(p, w)
			continue
		}
		return
	}
}

@(private)
scan_double :: proc "contextless" (p: ^Parser, n: int) -> (spelling: u16, ok: bool) #no_bounds_check {
	start := p.pos
	i := start + 1
	needs_decode := false
	lax := false
	ascii := true
	for {
		if i >= u64(len(p.src)) {
			return 0, fault(p, start, .Truncated, .Open_String)
		}
		b := p.src[i]
		switch {
		case b == '"':
			p.pos = i + 1
			sp := tape.SPELLING_QUOTED | style_bits(.Double)
			if needs_decode {
				sp |= tape.SPELLING_DECODE
				if lax {
					sp |= tape.SPELLING_LAX
				}
			} else if ascii {
				sp |= tape.SPELLING_ASCII
			}
			return sp, true
		case b == '\\':
			needs_decode = true
			c := at(p, i + 1)
			switch c {
			case '0', 'a', 'b', 't', '\t', 'n', 'v', 'f', 'r', 'e', ' ', '"', '/', '\\', 'N', '_':
				i += 2
			case 'L', 'P':
				lax = true
				i += 2
			case 'x', 'u', 'U':
				digits := u64(2 if c == 'x' else 4 if c == 'u' else 8)
				cp, hex := yaml_hex_run(p.src, int(i) + 2, int(digits))
				if !hex {
					return 0, fault(p, i, .Bad_Escape)
				}
				if cp > 0x10ffff || cp >= 0xd800 && cp <= 0xdfff {
					return 0, fault(p, i, .Bad_Escape, .Bad_Codepoint)
				}
				i += 2 + digits
			case '\n', '\r':
				i += 1
				i = fold_to_next_line(p, i, n) or_return
			case:
				return 0, fault(p, i, .Bad_Escape)
			}
		case is_break(b):
			needs_decode = true
			i = fold_to_next_line(p, i, n) or_return
		case:
			next, pq_ascii := past_quoted(p, i) or_return
			ascii &&= pq_ascii
			i = next
		}
	}
}

@(private)
fold_to_next_line :: proc "contextless" (p: ^Parser, i: u64, n: int) -> (u64, bool) #no_bounds_check {
	line, m, w := blank_lines_end(p, break_end(p, i))
	if w >= u64(len(p.src)) {
		return w, fault(p, i, .Truncated, .Open_String)
	}
	if line == m && marker_at(p, line) != 0 {
		return w, fault(p, line, .Bad_Char, .Marker_In_Scalar)
	}
	if int(m - line) <= n {
		return w, fault(p, w, .Bad_Char, .Bad_Indent)
	}
	p.ls = line
	return w, true
}

@(private)
scan_single :: proc "contextless" (p: ^Parser, n: int) -> (spelling: u16, ok: bool) #no_bounds_check {
	start := p.pos
	i := start + 1
	needs_decode := false
	ascii := true
	for {
		if i >= u64(len(p.src)) {
			return 0, fault(p, start, .Truncated, .Open_String)
		}
		b := p.src[i]
		switch {
		case b == '\'':
			if at(p, i + 1) == '\'' {
				needs_decode = true
				i += 2
				continue
			}
			p.pos = i + 1
			sp := tape.SPELLING_QUOTED | style_bits(.Single)
			if needs_decode {
				sp |= tape.SPELLING_DECODE
			} else if ascii {
				sp |= tape.SPELLING_ASCII
			}
			return sp, true
		case is_break(b):
			needs_decode = true
			i = fold_to_next_line(p, i, n) or_return
		case:
			next, pq_ascii := past_quoted(p, i) or_return
			ascii &&= pq_ascii
			i = next
		}
	}
}

@(private)
tab_only_line :: proc "contextless" (p: ^Parser, m: u64) -> bool #no_bounds_check {
	if p.src[m] != '\t' {
		return false
	}
	j := m
	for j < u64(len(p.src)) && is_white(p.src[j]) {
		j += 1
	}
	return j >= u64(len(p.src)) || is_break(p.src[j])
}

@(private)
scan_block :: proc(p: ^Parser, n: int) -> (spelling: u16, ok: bool) #no_bounds_check {
	start := p.pos
	i := start + 1
	keep, strip := false, false
	explicit := 0
	for _ in 0 ..< 2 {
		c := at(p, i)
		if c == '+' || c == '-' {
			if keep || strip {
				return 0, fault(p, i, .Bad_Char, .Bad_Block_Header)
			}
			keep, strip = c == '+', c == '-'
			i += 1
		} else if c >= '1' && c <= '9' {
			if explicit != 0 {
				return 0, fault(p, i, .Bad_Char, .Bad_Block_Header)
			}
			explicit = int(c - '0')
			i += 1
		} else if c == '0' {
			return 0, fault(p, i, .Bad_Char, .Bad_Block_Header)
		}
	}
	p.pos = i
	if !is_space_at(p, i) {
		return 0, fault(p, i, .Bad_Char, .Bad_Block_Header)
	}
	skip_ws(p)
	if !at_eol(p) {
		if !comment_here(p) {
			return 0, fault(p, p.pos, .Bad_Char, .Bad_Block_Header)
		}
		c := read_comment(p) or_return
		push_comment(p, c) or_return
	}
	header_end := p.pos
	spelling = tape.SPELLING_DECODE | style_bits(.Block)
	if at_eof(p) {
		return spelling, true
	}
	header_ls := p.ls
	consume_break(p)
	ci := -1
	if explicit != 0 {
		ci = max(n, 0) + explicit
		if ci > MAX_BLOCK_INDENT {
			return 0, fault(p, start, .Too_Wide, .Bad_Indent)
		}
		spelling |= block_indent_bits(ci)
	}
	content_end, trail_end := header_end, header_end
	lead_blank := 0
	line := p.pos
	for {
		m := skip_spaces(p, line)
		ind := int(m - line)
		eof := m >= u64(len(p.src))
		if eof || is_break(p.src[m]) {
			after := m if eof else break_end(p, m)
			if ci >= 0 && ind > ci {
				content_end = after
			} else if ci < 0 {
				lead_blank = max(lead_blank, ind)
			}
			trail_end = after
			if eof {
				break
			}
			line = after
			continue
		}
		if ci < 0 {
			if ind <= n {
				if tab_only_line(p, m) {
					return 0, fault(p, m, .Bad_Char, .Tab_Indent)
				}
				break
			}
			ci = ind
			if lead_blank > ci {
				return 0, fault(p, line, .Bad_Char, .Bad_Indent)
			}
		}
		if ind < ci || ind == 0 && marker_at(p, line) != 0 {
			if tab_only_line(p, m) {
				return 0, fault(p, m, .Bad_Char, .Tab_Indent)
			}
			break
		}
		j := line_end(p, m) or_return
		line = break_end(p, j)
		content_end, trail_end = line, line
	}
	end := trail_end if keep else content_end
	p.pos, p.ls = end, header_ls if end == header_end else end
	return spelling, true
}
