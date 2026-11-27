package yaml

import "stury:lib/core/tape"

// YAML block collection parser (`-` sequences, `k: v` mappings, `?` explicit keys, `:` empty keys) with iterative
// state transitions (`read_blocks`), zero native recursion across nesting levels.

@(private)
Entry :: enum u8 {
	Next,
	Staged_Key,
	Flow_Key,
	Explicit,
	Empty_Key,
}

@(private)
enter :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	p.depth += 1
	if p.depth > p.max_depth {
		return depth_fault(p, p.pos)
	}
	return true
}

@(private)
leave :: #force_inline proc "contextless" (p: ^Parser) {
	p.depth -= 1
}

@(private)
Next :: enum u8 {
	After,
	Seq_Entry,
	Map_Entry,
	Flow,
}

@(private)
Block :: struct {
	ind:      int,
	key_idx:  int,
	lead:     Props,
	object:   bool,
	mode:     Entry,
	key_done: bool,
	inline:   Comment,
}

@(private)
parse_node :: proc(p: ^Parser, n: int, compact, seq_same: bool, role: tape.Role) -> bool #no_bounds_check {
	after := p.pos
	skip_ws(p)
	start := p.pos
	p.sep_tab = false
	for i := after; i < start; i += 1 {
		p.sep_tab ||= p.src[i] == '\t'
	}
	props: Props
	parse_props(p, &props, false) or_return
	if at_eol(p) || comment_here(p) {
		if comment_here(p) {
			c := read_comment(p) or_return
			push_comment(p, c) or_return
		}
		peek_next(p) or_return
		l := p.nl
		if l.kind == .Content && (l.ind > n || seq_same && l.ind == n && at_seq_entry(p)) {
			return parse_block_at(p, l.ind, n, role, &props, seq_same)
		}
		emit_props(p, &props) or_return
		return emit(p, empty_plain_token(after, role))
	}
	return parse_same_line(p, n, col_of(p.ls, start), start, compact, role, &props)
}

@(private)
parse_same_line :: proc(p: ^Parser, n, ind: int, lo: u64, compact: bool, role: tape.Role, props: ^Props) -> bool {
	switch c := at(p, p.pos); c {
	case '|', '>':
		return parse_block_scalar(p, n, role, props)
	case '-', '?', ':':
		if indicator_at(p, p.pos) && (c != ':' || props_empty(props)) {
			if !compact || c != ':' && !props_empty(props) {
				return fault(p, p.pos, .Bad_Char, .Block_In_Line)
			}
			if p.sep_tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			if c == '-' {
				return open_seq(p, ind, role, &Props{})
			}
			return open_map(p, ind, lo, role, &Props{}, &Props{}, .Explicit if c == '?' else .Empty_Key, 0)
		}
	}
	return parse_inline_entry(p, n, ind, lo, compact, role, &Props{}, props)
}

// Reads the node on the content line at the cursor, indented `ind`, iteratively across multi-line property chains.
@(private)
parse_block_at :: proc(p: ^Parser, ind_in, n: int, role: tape.Role, outer: ^Props, seq_same: bool) -> bool {
	ind := ind_in
	for {
		lo := p.pos
		p.sep_tab = false
		if c := at(p, p.pos); (c == '-' || c == '?' || c == ':') && indicator_at(p, p.pos) {
			if p.nl.tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			if c == '-' {
				return open_seq(p, ind, role, outer)
			}
			return open_map(p, ind, lo, role, outer, &Props{}, .Explicit if c == '?' else .Empty_Key, 0)
		}
		inner: Props
		parse_props(p, &inner, false) or_return
		if !props_empty(&inner) && (at_eol(p) || comment_here(p)) {
			props_merge(p, outer, &inner) or_return
			if comment_here(p) {
				c := read_comment(p) or_return
				push_comment(p, c) or_return
			}
			peek_next(p) or_return
			l := p.nl
			if l.kind == .Content && (l.ind > n || seq_same && l.ind == n && at_seq_entry(p)) {
				ind = l.ind
				continue
			}
			emit_props(p, outer) or_return
			return emit(p, empty_plain_token(p.last_end, role))
		}
		if c := at(p, p.pos); c == '|' || c == '>' {
			props_merge(p, outer, &inner) or_return
			return parse_block_scalar(p, n, role, outer)
		}
		return parse_inline_entry(p, n, ind, lo, true, role, outer, &inner)
	}
}

@(private)
parse_block_scalar :: proc(p: ^Parser, n: int, role: tape.Role, props: ^Props) -> bool {
	start := p.pos
	spelling := scan_block(p, n) or_return
	emit_props(p, props) or_return
	return emit(p, tape.Token{start, u32(p.pos - start), .String, role, spelling})
}

@(private)
parse_inline_entry :: proc(p: ^Parser, n, ind: int, lo: u64, map_ok: bool, role: tape.Role, outer, inner: ^Props) -> bool {
	c := at(p, p.pos)
	if c == '[' || c == '{' {
		if map_ok && flow_is_key(p, true) {
			if p.nl.tab && lo == p.nl.pos || p.sep_tab {
				return fault(p, lo, .Bad_Char, .Tab_Indent)
			}
			return open_map(p, ind, lo, role, outer, inner, .Flow_Key, 0)
		}
		props_merge(p, outer, inner) or_return
		emit_props(p, outer) or_return
		return parse_flow(p, n, role, .Key_Line if role == .Key else .Line)
	}
	if c == '*' && !props_empty(inner) {
		return fault(p, p.pos, .Bad_Char, .Alias_Property)
	}
	if map_ok && c == ':' && indicator_at(p, p.pos) && !props_empty(inner) {
		return open_map(p, ind, lo, role, outer, inner, .Empty_Key, 0)
	}
	merged := outer^
	if !map_ok {
		if c == '*' && !props_empty(outer) {
			return fault(p, p.pos, .Bad_Char, .Alias_Property)
		}
		props_merge(p, &merged, inner) or_return
		emit_props(p, &merged) or_return
		parse_scalar_node(p, n, role, false, true) or_return
		return finish_line(p, role != .Key)
	}
	line_ls := p.ls
	clear(&p.stage)
	p.staging = true
	emit_props(p, inner) or_return
	key_idx := len(p.stage)
	node_lo := p.pos
	lines := parse_scalar_node(p, n, .Value, false, true) or_return
	skip_ws(p)
	if at(p, p.pos) == ':' && indicator_at(p, p.pos) {
		if lines || p.ls != line_ls {
			return fault(p, node_lo, .Bad_Char, .Multiline_Key)
		}
		if p.nl.tab && lo == p.nl.pos || p.sep_tab {
			return fault(p, lo, .Bad_Char, .Tab_Indent)
		}
		if p.pos - node_lo > KEY_MAX {
			return fault(p, node_lo, .Bad_Char, .Key_Too_Long)
		}
		return open_map(p, ind, lo, role, outer, inner, .Staged_Key, key_idx)
	}
	p.staging = false
	if c == '*' && !props_empty(outer) {
		return fault(p, node_lo, .Bad_Char, .Alias_Property)
	}
	props_merge(p, &merged, inner) or_return
	emit_props(p, outer) or_return
	flush_stage(p, -1, role) or_return
	return finish_line(p, role != .Key)
}

@(private)
parse_scalar_node :: proc(p: ^Parser, n: int, role: tape.Role, flow, multiline: bool) -> (lines: bool, ok: bool) #no_bounds_check {
	start, line := p.pos, p.ls
	switch at(p, start) {
	case '*':
		parse_alias(p, role) or_return
		return false, true
	case '"':
		spelling := scan_double(p, n) or_return
		return p.ls != line, emit(p, tape.Token{start + 1, u32(p.pos - start - 2), .String, role, spelling})
	case '\'':
		spelling := scan_single(p, n) or_return
		return p.ls != line, emit(p, tape.Token{start + 1, u32(p.pos - start - 2), .String, role, spelling})
	}
	if flow && start >= u64(len(p.src)) {
		return false, emit(p, empty_plain_token(start, role))
	}
	if !plain_first(p, flow) {
		return false, fault(p, start, .Bad_Char, .Bad_Start)
	}
	multi, ascii := scan_plain(p, n, flow, multiline) or_return
	sp := style_bits(.Plain)
	if multi {
		sp |= tape.SPELLING_DECODE
	} else if ascii {
		sp |= tape.SPELLING_ASCII
	}
	return multi, emit(p, tape.Token{start, u32(p.pos - start), .Plain, role, sp})
}

@(private)
empty_plain_token :: #force_inline proc "contextless" (lo: u64, role: tape.Role) -> tape.Token {
	return {lo, 0, .Plain, role, style_bits(.Plain) | tape.SPELLING_ASCII}
}

@(private)
open_block :: #force_inline proc(p: ^Parser, open: tape.Token, inline: ^Comment) -> bool {
	if p.staging || len(p.pending) == 0 {
		return emit(p, open)
	}
	return open_commented(p, open, inline)
}

@(private)
open_commented :: proc(p: ^Parser, open: tape.Token, inline: ^Comment) -> bool #no_bounds_check {
	head := 0
	if p.depth != 1 {
		x := p.pending[0].lo
		for x > p.start && (p.src[x - 1] == ' ' || p.src[x - 1] == '\t') {
			x -= 1
		}
		if x != p.start && p.src[x - 1] != '\n' && p.src[x - 1] != '\r' {
			inline^ = p.pending[0]
			ordered_remove(&p.pending, 0)
		}
	} else {
		head = root_head(p, open.lo)
	}
	flush_pending(p, head) or_return
	return emit_raw(p, open)
}

@(private)
root_head :: proc(p: ^Parser, next_in: u64) -> int #no_bounds_check {
	next_at := next_in
	for i := len(p.pending) - 1; i >= 0; i -= 1 {
		c := p.pending[i]
		breaks := 0
		for b in p.src[c.lo + u64(c.n):next_at] {
			breaks += int(b == '\n')
		}
		if breaks > 1 {
			return i + 1
		}
		next_at = c.lo
	}
	return 0
}

@(private)
open_seq :: proc(p: ^Parser, ind: int, role: tape.Role, outer: ^Props) -> bool {
	enter(p) or_return
	emit_props(p, outer) or_return
	inline: Comment
	open_block(p, tape.Token{p.pos, 0, .Array, role, 0}, &inline) or_return
	if _, err := append(&p.blocks, Block{ind = ind, inline = inline}); err != nil {
		return oom_fault(p, p.pos)
	}
	p.next = .Seq_Entry
	return true
}

@(private)
open_map :: proc(p: ^Parser, ind: int, lo: u64, role: tape.Role, outer, inner: ^Props, first: Entry, key_idx: int) -> bool {
	enter(p) or_return
	p.staging = false
	emit_props(p, outer) or_return
	inline: Comment
	open_block(p, tape.Token{lo, 0, .Object, role, 0}, &inline) or_return
	if _, err := append(&p.blocks, Block{ind = ind, key_idx = key_idx, lead = inner^, object = true, mode = first, inline = inline}); err != nil {
		return oom_fault(p, lo)
	}
	p.next = .Map_Entry
	return true
}

@(private)
read_blocks :: proc(p: ^Parser) -> bool {
	for {
		switch p.next {
		case .Seq_Entry:
			p.next = .After
			p.pos += 1
			parse_node(p, p.blocks[len(p.blocks) - 1].ind, true, false, .Value) or_return
		case .Map_Entry:
			p.next = .After
			map_entry(p) or_return
		case .Flow:
			p.next = .After
			read_flow(p) or_return
			flow_done(p) or_return
		case .After:
			if len(p.blocks) == 0 {
				return true
			}
			after_entry(p) or_return
		}
	}
}

@(private)
map_entry :: proc(p: ^Parser) -> bool {
	f := &p.blocks[len(p.blocks) - 1]
	ind, mode, lead, key_idx := f.ind, f.mode, f.lead, f.key_idx
	f.mode, f.lead = .Next, {}
	if mode == .Next {
		switch at(p, p.pos) {
		case '?':
			mode = .Explicit if indicator_at(p, p.pos) else .Next
		case ':':
			mode = .Empty_Key if indicator_at(p, p.pos) else .Next
		}
	}
	switch mode {
	case .Staged_Key:
		flush_stage(p, key_idx) or_return
	case .Flow_Key:
		emit_props(p, &lead) or_return
		return parse_flow(p, ind, .Key, .Known_Key)
	case .Empty_Key:
		emit_props(p, &lead) or_return
		emit(p, empty_plain_token(p.pos, .Key)) or_return
	case .Explicit:
		p.pos += 1
		f.key_done = true
		return parse_node(p, ind, true, true, .Key)
	case .Next:
		key: Props
		parse_props(p, &key, false) or_return
		if at(p, p.pos) == '*' && !props_empty(&key) {
			return fault(p, p.pos, .Bad_Char, .Alias_Property)
		}
		emit_props(p, &key) or_return
		if c := at(p, p.pos); c == '[' || c == '{' {
			return parse_flow(p, ind, .Key, .Key)
		}
		start := p.pos
		if at_eol(p) || comment_here(p) || at(p, p.pos) == ':' && indicator_at(p, p.pos) {
			emit(p, empty_plain_token(start, .Key)) or_return
		} else {
			line := p.ls
			parse_scalar_node(p, ind, .Key, false, false) or_return
			if p.ls != line {
				return fault(p, start, .Bad_Char, .Multiline_Key)
			}
			if p.pos - start > KEY_MAX {
				return fault(p, start, .Bad_Char, .Key_Too_Long)
			}
		}
		return key_colon(p, ind)
	}
	return map_value(p, ind)
}

@(private)
key_colon :: proc(p: ^Parser, ind: int) -> bool {
	skip_ws(p)
	if !(at(p, p.pos) == ':' && indicator_at(p, p.pos)) {
		return fault(p, p.pos, .Bad_Char, .Expected_Colon)
	}
	return map_value(p, ind)
}

@(private)
after_entry :: proc(p: ^Parser) -> bool {
	f := &p.blocks[len(p.blocks) - 1]
	ind := f.ind
	if f.key_done {
		f.key_done = false
		peek_next(p) or_return
		l := p.nl
		if l.kind == .Content && l.ind == ind && at(p, p.pos) == ':' && indicator_at(p, p.pos) {
			p.pos += 1
			return parse_node(p, ind, true, true, .Value)
		}
		emit(p, empty_plain_token(p.last_end, .Value)) or_return
	}
	peek_next(p) or_return
	l := p.nl
	if l.kind == .Content && l.ind == ind && f.object != at_seq_entry(p) {
		if l.tab {
			return fault(p, p.pos, .Bad_Char, .Tab_Indent)
		}
		if f.object {
			return map_entry_line(p, ind)
		}
		p.next = .Seq_Entry
		return true
	}
	if l.kind == .Content && l.ind > ind {
		return fault(p, p.pos, .Bad_Char, .Bad_Indent)
	}
	c := pop(&p.blocks).inline
	leave(p)
	flush_foot(p, ind) or_return
	emit(p, tape.Token{p.last_end, 0, .End, .Value, 0}) or_return
	return c.n == 0 || emit_raw(p, tape.Token{c.lo, c.n, .Plain, .Comment_Inline, tape.HASH_COMMENT})
}

@(private)
plain_lead :: #force_inline proc "contextless" (b: u8) -> bool {
	LO :: u64(1) << 0x21 - 1 | 1 << 0x21 | 1 << 0x22 | 1 << 0x23 | 1 << 0x25 | 1 << 0x26 | 1 << 0x27 | 1 << 0x2a | 1 << 0x2c | 1 << 0x2d | 1 << 0x3a | 1 << 0x3e | 1 << 0x3f
	HI :: u64(1) << (0x40 - 64) | 1 << (0x5b - 64) | 1 << (0x5d - 64) | 1 << (0x60 - 64) | 1 << (0x7b - 64) | 1 << (0x7c - 64) | 1 << (0x7d - 64) | 1 << (0x7f - 64)
	return b < 0x80 && (HI if b >= 64 else LO) >> (b & 63) & 1 == 0
}

@(private)
map_entry_line :: proc(p: ^Parser, ind: int) -> bool #no_bounds_check {
	src := p.src
	n := u64(len(src))
	lo := p.pos
	if !plain_lead(src[lo]) {
		p.next = .Map_Entry
		return true
	}
	colon, last, eol, k_ascii := scan_plain_line(p, lo + 1, false) or_return
	if eol || src[colon] != ':' || last - lo > KEY_MAX {
		p.next = .Map_Entry
		return true
	}
	ksp := style_bits(.Plain) | (tape.SPELLING_ASCII if k_ascii else 0)
	emit(p, tape.Token{lo, u32(last - lo), .Plain, .Key, ksp}) or_return
	v := colon + 1
	for v < n && is_white(src[v]) {
		v += 1
	}
	p.pos = colon
	if v >= n {
		return map_value(p, ind)
	}
	switch c := src[v]; c {
	case '\'', '"':
		p.pos = v
		spelling: u16
		ok: bool
		if c == '\'' {
			spelling, ok = scan_single(p, ind)
		} else {
			spelling, ok = scan_double(p, ind)
		}
		if !ok {
			return false
		}
		emit(p, tape.Token{v + 1, u32(p.pos - v - 2), .String, .Value, spelling}) or_return
		return finish_line(p, true)
	case:
		if !plain_lead(c) {
			return map_value(p, ind)
		}
	}
	stop, end, at_eol_val, v_ascii := scan_plain_line(p, v + 1, false) or_return
	if !at_eol_val && src[stop] == ':' {
		return map_value(p, ind)
	}
	if at_eol_val && stop < n {
		k := break_end(p, stop)
		m := skip_spaces(p, k)
		if m < n && (int(m - k) > ind && src[m] != '#' || is_white(src[m]) || is_break(src[m])) {
			return map_value(p, ind)
		}
	}
	vsp := style_bits(.Plain) | (tape.SPELLING_ASCII if v_ascii else 0)
	emit(p, tape.Token{v, u32(end - v), .Plain, .Value, vsp}) or_return
	p.pos = end
	return finish_line(p, true)
}

@(private)
map_value :: proc(p: ^Parser, ind: int) -> bool {
	p.pos += 1
	return parse_node(p, ind, false, true, .Value)
}
