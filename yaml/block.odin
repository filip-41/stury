package yaml

import core "../core"

// How a mapping entry begins.
@(private)
Entry :: enum u8 {
	Next, // read from the text
	Staged_Key, // the key is held in the stage
	Flow_Key, // the key is a flow collection at the cursor
	Explicit, // `?`
	Empty_Key, // `:` with no key
}

// Ends the walk at a pause, with no fault, at the place the walk resumes from.
@(private)
paused :: proc "contextless" (p: ^Parser) -> bool {
	p.fail = core.fault_at(p.pos, .None, PAUSED)
	return false
}

@(private)
enter :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	p.depth += 1
	if p.depth > p.max_depth {
		return fault(p, p.pos, .Too_Deep)
	}
	return true
}

@(private)
leave :: #force_inline proc "contextless" (p: ^Parser) {
	p.depth -= 1
}

// What the walk does next. A node read whole leaves `After`, and a block collection that opens leaves the state of its
// first entry.
@(private)
Next :: enum u8 {
	After, // a node has been sent: the innermost open block collection takes its next entry or closes
	Seq_Entry, // the cursor is at the `-` of an entry of the innermost block sequence
	Map_Entry, // the cursor is at an entry of the innermost block mapping, which its frame's `mode` says how to read
	Flow, // a flow collection is open: `read_flow` reads it, and `Parser.flow_then` says what follows its close
}

// A block collection the walk has open, indented `ind`. `mode`, `lead` and `key_idx` say how its next entry begins, as
// `open_map` was given them for the first. `key_done` is set while the value of an explicit key may follow.
@(private)
Block :: struct {
	ind:      int,
	key_idx:  int,
	lead:     Props,
	object:   bool,
	mode:     Entry,
	key_done: bool,
}

// Reads the node that follows an indicator (`-`, `?`, `:`, `---`) or starts a document. `n` is the indentation of the
// collection the indicator belongs to. A block collection may start on the indicator's line when `compact` is set,
// and a sequence may stand at `n` when `seq_same` is set. The cursor is left at the end of the node's last line, or
// at the content line after it when the node is a block collection or empty.
@(private)
parse_node :: proc(p: ^Parser, n: int, compact, seq_same: bool, role: core.Role) -> bool {
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
			append(&p.pending, c)
		}
		peek_next(p) or_return
		l := p.nl
		if l.kind == .Content && (l.ind > n || seq_same && l.ind == n && at_seq_entry(p)) {
			return parse_block_at(p, l.ind, n, role, &props, seq_same)
		}
		emit_props(p, &props) or_return
		return emit(p, plain_token(p, after, 0, role))
	}
	return parse_same_line(p, n, col_of(p.ls, start), start, compact, role, &props)
}

// Reads a node whose content starts on the line of its indicator, after the properties `props`.
@(private)
parse_same_line :: proc(p: ^Parser, n, ind: int, lo: u64, compact: bool, role: core.Role, props: ^Props) -> bool {
	switch at(p, p.pos) {
	case '|', '>':
		return parse_block_scalar(p, n, role, props)
	case '-':
		if indicator_at(p, p.pos) {
			if !compact || !props_empty(props) {
				return fault(p, p.pos, .Bad_Char, .Block_In_Line)
			}
			if p.sep_tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			return open_seq(p, ind, role, &Props{})
		}
	case '?':
		if indicator_at(p, p.pos) {
			if !compact || !props_empty(props) {
				return fault(p, p.pos, .Bad_Char, .Block_In_Line)
			}
			if p.sep_tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			return open_map(p, ind, lo, role, &Props{}, &Props{}, .Explicit, 0)
		}
	case ':':
		if indicator_at(p, p.pos) && props_empty(props) {
			if !compact {
				return fault(p, p.pos, .Bad_Char, .Block_In_Line)
			}
			if p.sep_tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			return open_map(p, ind, lo, role, &Props{}, &Props{}, .Empty_Key, 0)
		}
	}
	return parse_inline_entry(p, n, ind, lo, compact, role, &Props{}, props)
}

// Reads the node on the content line at the cursor, indented `ind`, with the properties `outer` the lines before it
// gave.
@(private)
parse_block_at :: proc(p: ^Parser, ind, n: int, role: core.Role, outer: ^Props, seq_same: bool) -> bool {
	lo := p.pos
	p.sep_tab = false
	switch at(p, p.pos) {
	case '-':
		if indicator_at(p, p.pos) {
			if p.nl.tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			return open_seq(p, ind, role, outer)
		}
	case '?':
		if indicator_at(p, p.pos) {
			if p.nl.tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			return open_map(p, ind, lo, role, outer, &Props{}, .Explicit, 0)
		}
	case ':':
		if indicator_at(p, p.pos) {
			if p.nl.tab {
				return fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			return open_map(p, ind, lo, role, outer, &Props{}, .Empty_Key, 0)
		}
	}
	inner: Props
	parse_props(p, &inner, false) or_return
	if !props_empty(&inner) && (at_eol(p) || comment_here(p)) {
		props_merge(p, outer, &inner) or_return
		if comment_here(p) {
			c := read_comment(p) or_return
			append(&p.pending, c)
		}
		peek_next(p) or_return
		l := p.nl
		if l.kind == .Content && (l.ind > n || seq_same && l.ind == n && at_seq_entry(p)) {
			return parse_block_at(p, l.ind, n, role, outer, seq_same)
		}
		emit_props(p, outer) or_return
		return emit(p, plain_token(p, p.last_end, 0, role))
	}
	if c := at(p, p.pos); c == '|' || c == '>' {
		props_merge(p, outer, &inner) or_return
		return parse_block_scalar(p, n, role, outer)
	}
	return parse_inline_entry(p, n, ind, lo, true, role, outer, &inner)
}

@(private)
parse_block_scalar :: proc(p: ^Parser, n: int, role: core.Role, props: ^Props) -> bool {
	start := p.pos
	spelling := scan_block(p, n) or_return
	emit_props(p, props) or_return
	return emit(p, core.Token{start, u32(p.pos - start), .String, role, spelling})
}

// Reads an alias, a flow collection or a scalar that may be the key of a block mapping when `map_ok` is set, in which
// case the mapping starts here at indentation `ind`. `outer` are the properties of the lines before and `inner` those
// on this line.
@(private)
parse_inline_entry :: proc(p: ^Parser, n, ind: int, lo: u64, map_ok: bool, role: core.Role, outer, inner: ^Props) -> bool {
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
		return parse_flow(p, n, role, .Line)
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
		return finish_line(p, true)
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
	return finish_line(p, true)
}

// Reads an alias or a scalar at the cursor, a plain one over lines when `multiline` is set. Returns whether the
// scalar spans lines.
@(private)
parse_scalar_node :: proc(p: ^Parser, n: int, role: core.Role, flow, multiline: bool) -> (lines: bool, ok: bool) {
	start, line := p.pos, p.ls
	switch at(p, start) {
	case '*':
		parse_alias(p, role) or_return
		return false, true
	case '"':
		spelling := scan_double(p, n) or_return
		return p.ls != line, emit(p, core.Token{start, u32(p.pos - start), .String, role, spelling})
	case '\'':
		spelling := scan_single(p, n) or_return
		return p.ls != line, emit(p, core.Token{start, u32(p.pos - start), .String, role, spelling})
	}
	if !plain_first(p, flow) {
		return false, fault(p, start, .Bad_Char, .Bad_Start)
	}
	multi := scan_plain(p, n, flow, multiline) or_return
	spelling := core.SPELLING_DECODE if multi else u16(0)
	return multi, emit(p, plain_token(p, start, u32(p.pos - start), role, p.src[start], spelling))
}


// Opens a block sequence whose first `-` is at the cursor, indented `ind`.
@(private)
open_seq :: proc(p: ^Parser, ind: int, role: core.Role, outer: ^Props) -> bool {
	enter(p) or_return
	emit_props(p, outer) or_return
	emit(p, core.Token{p.pos, 0, .Array, role, 0}) or_return
	append(&p.blocks, Block{ind = ind})
	p.next = .Seq_Entry
	return true
}

// Opens a block mapping indented `ind` that starts at `lo`. `first` says how its first entry begins: `Staged_Key` has
// the key held in the stage from `key_idx`, `Flow_Key` has it at the cursor after the properties `inner`.
@(private)
open_map :: proc(p: ^Parser, ind: int, lo: u64, role: core.Role, outer, inner: ^Props, first: Entry, key_idx: int) -> bool {
	enter(p) or_return
	p.staging = false
	emit_props(p, outer) or_return
	emit(p, core.Token{lo, 0, .Object, role, 0}) or_return
	append(&p.blocks, Block{ind = ind, key_idx = key_idx, lead = inner^, object = true, mode = first})
	p.next = .Map_Entry
	return true
}

// Reads from the state `p.next` until every block collection open has closed, or up to a pause. A pause comes only
// past a node, where everything the walk holds is in `p`.
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
			if p.pause {
				return paused(p)
			}
			if len(p.blocks) == 0 {
				return true
			}
			after_entry(p) or_return
		}
	}
}

// Reads the entry of the innermost block mapping at the cursor up to its value, which it starts.
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
		emit(p, plain_token(p, p.pos, 0, .Key)) or_return
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
			emit(p, plain_token(p, start, 0, .Key)) or_return
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

// Reads the `:` after the key of the innermost block mapping, indented `ind`, and the value after it.
@(private)
key_colon :: proc(p: ^Parser, ind: int) -> bool {
	skip_ws(p)
	if !(at(p, p.pos) == ':' && indicator_at(p, p.pos)) {
		return fault(p, p.pos, .Bad_Char, .Expected_Colon)
	}
	return map_value(p, ind)
}

// Moves past the node the innermost block collection's entry ended with: to the collection's next entry, or past its
// end, which it sends.
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
		emit(p, core.Token{p.last_end, 0, .Plain, .Value, 0}) or_return
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
	pop(&p.blocks)
	leave(p)
	flush_foot(p, ind) or_return
	return emit(p, core.Token{p.last_end, 0, .End, .Value, 0})
}

// Whether `b` starts a plain scalar whatever byte follows it.
@(private)
plain_lead :: #force_inline proc "contextless" (b: u8) -> bool {
	// The bytes below 0x80 that cannot, by their value less 64 for the second word.
	LO :: u64(1) << 0x21 - 1 | 1 << 0x21 | 1 << 0x22 | 1 << 0x23 | 1 << 0x25 | 1 << 0x26 | 1 << 0x27 | 1 << 0x2a | 1 << 0x2c | 1 << 0x2d | 1 << 0x3a | 1 << 0x3e | 1 << 0x3f
	HI :: u64(1) << (0x40 - 64) | 1 << (0x5b - 64) | 1 << (0x5d - 64) | 1 << (0x60 - 64) | 1 << (0x7b - 64) | 1 << (0x7c - 64) | 1 << (0x7d - 64) | 1 << (0x7f - 64)
	return b < 0x80 && (HI if b >= 64 else LO) >> (b & 63) & 1 == 0
}

// Reads the entry of the innermost block mapping, indented `ind`, at the cursor, as `map_entry` and the value's
// `parse_node` would, when its key is a plain scalar and its value a quoted scalar or a plain one on the key's line.
// Any other entry is left to `map_entry`, read from its start, or to `map_value`, read from its `:`.
@(private)
map_entry_line :: proc(p: ^Parser, ind: int) -> bool {
	src := p.src
	n := u64(len(src))
	lo := p.pos
	if !plain_lead(src[lo]) {
		p.next = .Map_Entry
		return true
	}
	colon, last, eol := scan_plain_line(p, lo + 1, false) or_return
	if eol || src[colon] != ':' || last - lo > KEY_MAX {
		p.next = .Map_Entry
		return true
	}
	emit(p, plain_token(p, lo, u32(last - lo), .Key, src[lo])) or_return
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
		emit(p, core.Token{v, u32(p.pos - v), .String, .Value, spelling}) or_return
		return finish_line(p, true)
	case:
		if !plain_lead(c) {
			return map_value(p, ind)
		}
	}
	stop, end, at_eol := scan_plain_line(p, v + 1, false) or_return
	if !at_eol && src[stop] == ':' {
		return map_value(p, ind)
	}
	if at_eol && stop < n {
		// A line indented past the mapping may go on with the scalar.
		k := break_end(p, stop)
		m := skip_spaces(p, k)
		if m < n && (int(m - k) > ind && src[m] != '#' || is_white(src[m]) || is_break(src[m])) {
			return map_value(p, ind)
		}
	}
	emit(p, core.Token{v, u32(end - v), .Plain, .Value, 0}) or_return
	p.pos = end
	return finish_line(p, true)
}

// Reads the value after the `:` at the cursor.
@(private)
map_value :: proc(p: ^Parser, ind: int) -> bool {
	p.pos += 1
	return parse_node(p, ind, false, true, .Value)
}
