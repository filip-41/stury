package yaml

import core "../core"

// A scalar token's `spelling`: bit 0 (`core.SPELLING_DECODE`) says the text needs `text`, bit 2 (`core.SPELLING_LAX`) that
// a double-quoted scalar holds a `\L` or `\P`, which decode to three bytes from two. Bits 3 and 4 are the style, bit 5
// says a block scalar's indentation indicator is explicit, and bits 8 to 15 hold that indentation.
@(private)
STYLE_SHIFT :: 3
@(private)
STYLE_MASK :: u16(3) << STYLE_SHIFT
@(private)
STYLE_EXPLICIT :: u16(1) << 5
@(private)
INDENT_SHIFT :: 8

// Whether the collection node `n` is written in brackets. A block collection starts at a `-`, a `?`, a `:` or a scalar,
// and a block mapping that starts with a bracketed key is refused by a document.
@(private)
is_flow :: #force_inline proc "contextless" (doc: ^core.Document, n: core.Node) -> bool {
	return doc.src[n.lo] == '[' || doc.src[n.lo] == '{'
}

@(private)
Style :: enum u8 {
	Plain,
	Single,
	Double,
	Block,
}

@(private)
style_of :: #force_inline proc "contextless" (spelling: u16) -> Style {
	return Style((spelling & STYLE_MASK) >> STYLE_SHIFT)
}

@(private)
style_bits :: #force_inline proc "contextless" (s: Style) -> u16 {
	return u16(s) << STYLE_SHIFT
}

// The longest an implicit key may be, in bytes.
@(private)
KEY_MAX :: 1024

// Whether the scalar may start with the byte at the cursor. A `?`, `:` or `-` starts one only before a character a
// plain scalar may hold.
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

// Reads a plain scalar at the cursor, which `plain_first` has judged. In `multiline` it continues over following lines
// that are indented past `n`. Returns whether it spans lines. The cursor is left at its end.
@(private)
scan_plain :: proc "contextless" (p: ^Parser, n: int, flow, multiline: bool) -> (lines: bool, ok: bool) {
	i, last, eol := scan_plain_line(p, step(p, p.pos) or_return, flow) or_return
	for eol && multiline && i < u64(len(p.src)) {
		k := break_end(p, i)
		line := k
		w := k
		ind := 0
		found := false
		for {
			m := skip_spaces(p, line)
			ind = int(m - line)
			w = m
			for w < u64(len(p.src)) && is_white(p.src[w]) {
				w += 1
			}
			if w >= u64(len(p.src)) {
				break
			}
			if is_break(p.src[w]) {
				line = break_end(p, w)
				continue
			}
			found = true
			break
		}
		if !found || ind <= n || ind == 0 && marker_at(p, line) != 0 {
			break
		}
		c := p.src[w]
		if c == '#' || flow && is_flow_indicator(c) || c == ':' && (is_space_at(p, w + 1) || flow && is_flow_indicator(at(p, w + 1))) {
			break
		}
		p.ls = line
		i, last, eol = scan_plain_line(p, w, flow) or_return
		lines = true
	}
	p.pos = last
	return lines, true
}

// Reads a double-quoted scalar at the cursor, judging its escapes and the indentation of its lines past `n`. Returns
// the token's `spelling`.
@(private)
scan_double :: proc "contextless" (p: ^Parser, n: int) -> (spelling: u16, ok: bool) {
	start := p.pos
	i := start + 1
	lax := false
	for {
		if i >= u64(len(p.src)) {
			return 0, fault(p, start, .Truncated, .Open_String)
		}
		b := p.src[i]
		switch {
		case b == '"':
			p.pos = i + 1
			return core.SPELLING_DECODE | style_bits(.Double) | (core.SPELLING_LAX if lax else 0), true
		case b == '\\':
			c := at(p, i + 1)
			switch c {
			case '0', 'a', 'b', 't', '\t', 'n', 'v', 'f', 'r', 'e', ' ', '"', '/', '\\', 'N', '_':
				i += 2
			case 'L', 'P':
				lax = true
				i += 2
			case 'x', 'u', 'U':
				digits := u64(2 if c == 'x' else 4 if c == 'u' else 8)
				cp := u32(0)
				for k in u64(0) ..< digits {
					d := at(p, i + 2 + k)
					if !is_hex(d) {
						return 0, fault(p, i, .Bad_Escape)
					}
					cp = cp << 4 | u32(d - '0' if d <= '9' else (d | 0x20) - 'a' + 10)
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
			i = fold_to_next_line(p, i, n) or_return
		case:
			i = past_quoted(p, i) or_return
		}
	}
}

// Moves from the line break at `i` to the first character of the next line that is not blank, judging the document
// markers and the indentation, and starts that line.
@(private)
fold_to_next_line :: proc "contextless" (p: ^Parser, i: u64, n: int) -> (u64, bool) {
	line := break_end(p, i)
	for {
		m := skip_spaces(p, line)
		w := m
		for w < u64(len(p.src)) && is_white(p.src[w]) {
			w += 1
		}
		if w >= u64(len(p.src)) {
			return w, fault(p, i, .Truncated, .Open_String)
		}
		if is_break(p.src[w]) {
			line = break_end(p, w)
			continue
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
}

// Reads a single-quoted scalar at the cursor. Returns the token's `spelling`.
@(private)
scan_single :: proc "contextless" (p: ^Parser, n: int) -> (spelling: u16, ok: bool) {
	start := p.pos
	i := start + 1
	for {
		if i >= u64(len(p.src)) {
			return 0, fault(p, start, .Truncated, .Open_String)
		}
		b := p.src[i]
		switch {
		case b == '\'':
			if at(p, i + 1) == '\'' {
				i += 2
				continue
			}
			p.pos = i + 1
			return core.SPELLING_DECODE | style_bits(.Single), true
		case is_break(b):
			i = fold_to_next_line(p, i, n) or_return
		case:
			i = past_quoted(p, i) or_return
		}
	}
}

// Whether the line whose first non-space byte is at `m` holds only white space and begins with a tab.
@(private)
tab_only_line :: proc "contextless" (p: ^Parser, m: u64) -> bool {
	if p.src[m] != '\t' {
		return false
	}
	j := m
	for j < u64(len(p.src)) && is_white(p.src[j]) {
		j += 1
	}
	return j >= u64(len(p.src)) || is_break(p.src[j])
}

// Reads a block scalar at the cursor, whose `|` or `>` starts the token. `n` is the indentation of the node the
// scalar belongs to. The cursor is left at the start of the line after the scalar.
@(private)
scan_block :: proc(p: ^Parser, n: int) -> (spelling: u16, ok: bool) {
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
		append(&p.pending, c)
	}
	header_end := p.pos
	spelling = core.SPELLING_DECODE | style_bits(.Block)
	if at_eof(p) {
		return spelling, true
	}
	header_ls := p.ls
	consume_break(p)
	ci := -1
	if explicit != 0 {
		ci = max(n, -1) + explicit
		if ci > 255 {
			return 0, fault(p, start, .Too_Wide, .Bad_Indent)
		}
		spelling |= STYLE_EXPLICIT | u16(ci) << INDENT_SHIFT
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
