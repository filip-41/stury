package yaml

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Comment, document marker, line advancement, and directive scanning helpers.

@(private)
marker_at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> u8 #no_bounds_check {
	if i + 3 <= u64(len(p.src)) {
		b := p.src[i]
		if (b == '-' || b == '.') && p.src[i + 1] == b && p.src[i + 2] == b && is_space_at(p, i + 3) {
			return b
		}
	}
	return 0
}

@(private)
read_comment :: proc "contextless" (p: ^Parser) -> (c: Comment, ok: bool) #no_bounds_check {
	lo := p.pos
	i := line_end(p, lo + 1) or_return
	p.pos = i
	return Comment{lo, u32(i - lo), u32(lo - p.ls)}, true
}

@(private)
comment_here :: #force_inline proc "contextless" (p: ^Parser) -> bool #no_bounds_check {
	return p.pos < u64(len(p.src)) && p.src[p.pos] == '#' && (p.pos == p.ls || is_white(p.src[p.pos - 1]))
}

@(private)
finish_line :: proc(p: ^Parser, inline: bool) -> bool {
	skip_ws(p)
	if at_eol(p) {
		return true
	}
	if !comment_here(p) {
		return fault(p, p.pos, .Bad_Char, .Expected_Line_End)
	}
	c := read_comment(p) or_return
	if inline {
		return emit_raw(p, tape.Token{c.lo, c.n, .Plain, .Comment_Inline, tape.HASH_COMMENT})
	}
	return push_comment(p, c)
}

@(private)
peek_next :: proc(p: ^Parser) -> bool #no_bounds_check {
	if p.nl_valid && p.nl.pos == p.pos {
		return true
	}
	n := u64(len(p.src))
	for {
		if p.pos >= n {
			p.nl = Line{kind = .Eof, pos = p.pos}
			break
		}
		if p.pos != p.ls {
			skip_ws(p)
			if p.pos >= n {
				continue
			}
			if is_break(p.src[p.pos]) {
				consume_break(p)
				continue
			}
			if comment_here(p) {
				c := read_comment(p) or_return
				push_comment(p, c) or_return
				continue
			}
			p.nl = Line{kind = .Content, ind = col_of(p.ls, p.pos), pos = p.pos}
			break
		}
		i := skip_spaces(p, p.pos)
		j := i
		for j < n && is_white(p.src[j]) {
			j += 1
		}
		if j >= n {
			p.pos = j
			continue
		}
		if is_break(p.src[j]) {
			p.pos = j
			consume_break(p)
			continue
		}
		if p.src[j] == '#' {
			p.pos = j
			c := read_comment(p) or_return
			push_comment(p, c) or_return
			continue
		}
		p.pos = j
		line := Line{kind = .Content, ind = int(i - p.ls), pos = j, tab = j > i}
		if i == p.ls && marker_at(p, i) != 0 {
			line.kind = .Marker
		}
		p.nl = line
		break
	}
	p.nl_valid = true
	return true
}

@(private)
at_seq_entry :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	return at(p, p.pos) == '-' && indicator_at(p, p.pos)
}

@(private)
read_directive :: proc(p: ^Parser) -> bool #no_bounds_check {
	start := p.pos
	i := start + 1
	for i < u64(len(p.src)) && !is_space_at(p, i) {
		i += 1
	}
	name := string(p.src[start + 1:i])
	p.pos = i
	skip_ws(p)
	switch name {
	case "YAML":
		if p.has_yaml {
			return fault(p, start, .Bad_Char, .Duplicate_Directive)
		}
		p.has_yaml = true
		lo := p.pos
		d1 := 0
		for at(p, p.pos) >= '0' && at(p, p.pos) <= '9' {
			p.pos += 1
			d1 += 1
		}
		if d1 == 0 || at(p, p.pos) != '.' {
			return fault(p, lo, .Bad_Char, .Bad_Directive)
		}
		p.pos += 1
		d2 := 0
		for at(p, p.pos) >= '0' && at(p, p.pos) <= '9' {
			p.pos += 1
			d2 += 1
		}
		if d2 == 0 || !is_space_at(p, p.pos) {
			return fault(p, lo, .Bad_Char, .Bad_Directive)
		}
		if d1 != 1 || p.src[lo] != '1' {
			return fault(p, lo, .Bad_Char, .Bad_Version)
		}
	case "TAG":
		lo := p.pos
		if at(p, p.pos) != '!' {
			return fault(p, lo, .Bad_Char, .Bad_Directive)
		}
		p.pos += 1
		for is_word(at(p, p.pos)) {
			p.pos += 1
		}
		if at(p, p.pos) == '!' {
			p.pos += 1
		} else if p.pos != lo + 1 {
			return fault(p, lo, .Bad_Char, .Bad_Directive)
		}
		handle := string(p.src[lo:p.pos])
		if !is_white(at(p, p.pos)) {
			return fault(p, p.pos, .Bad_Char, .Bad_Directive)
		}
		skip_ws(p)
		plo := p.pos
		for !is_space_at(p, p.pos) {
			if !uri_char_at(p, p.pos) {
				return fault(p, p.pos, .Bad_Char, .Bad_Directive)
			}
			p.pos += 3 if at(p, p.pos) == '%' else 1
		}
		if p.pos == plo {
			return fault(p, plo, .Bad_Char, .Bad_Directive)
		}
		if handle_declared(p, lo, lo + u64(len(handle))) {
			return fault(p, lo, .Bad_Char, .Duplicate_Directive)
		}
		if _, err := append(&p.handles, Tag_Handle{handle, string(p.src[plo:p.pos])}); err != nil {
			return oom_fault(p, lo)
		}
	case:
		for !at_eol(p) && !comment_here(p) {
			p.pos = step(p, p.pos) or_return
		}
	}
	hi := p.pos
	for hi > start && (p.src[hi - 1] == ' ' || p.src[hi - 1] == '\t') {
		hi -= 1
	}
	emit_now(p, tape.Token{start, u32(hi - start), .Plain, .Directive, 0}) or_return
	p.directives = true
	return finish_line(p, false)
}

@(private)
is_word :: #force_inline proc "contextless" (b: u8) -> bool {
	return b >= '0' && b <= '9' || b >= 'a' && b <= 'z' || b >= 'A' && b <= 'Z' || b == '-'
}

@(private)
uri_char_at :: proc "contextless" (p: ^Parser, i: u64) -> bool {
	b := at(p, i)
	if b == '%' {
		return spell.HEX_NIBBLE[at(p, i + 1)] | spell.HEX_NIBBLE[at(p, i + 2)] < 16
	}
	if is_word(b) {
		return true
	}
	switch b {
	case '#', ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '_', '.', '!', '~', '*', '\'', '(', ')', '[', ']':
		return true
	}
	return false
}
