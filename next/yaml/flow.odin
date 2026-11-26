package yaml

import "stury:lib/core/tape"

// YAML flow collections (`[...]`, `{...}`, single-pair mappings inside flow sequences) with an explicit heap frame
// stack so arbitrarily deep flow structures do not consume native stack.

@(private)
flow_space :: #force_inline proc(p: ^Parser, n: int, after_value: bool) -> bool {
	skip_ws(p)
	if c := at(p, p.pos); !is_break(c) && c != '#' {
		return true
	}
	return flow_lines(p, n, after_value)
}

@(private)
flow_lines :: proc(p: ^Parser, n: int, after_value: bool) -> bool #no_bounds_check {
	same_line := after_value
	for {
		skip_ws(p)
		if at_eof(p) {
			return true
		}
		b := p.src[p.pos]
		if is_break(b) {
			consume_break(p)
			same_line = false
			line, m, w := blank_lines_end(p, p.pos)
			p.ls = line
			if w < u64(len(p.src)) {
				if m == line && marker_at(p, m) != 0 {
					return fault(p, m, .Bad_Char, .Marker_In_Scalar)
				}
				if p.src[w] != '#' && int(m - line) <= n {
					return fault(p, w, .Bad_Char, .Bad_Indent)
				}
			}
			p.pos = w
			continue
		}
		if b == '#' && comment_here(p) {
			c := read_comment(p) or_return
			if same_line {
				emit_raw(p, tape.Token{c.lo, c.n, .Plain, .Comment_Inline, tape.HASH_COMMENT}) or_return
			} else {
				push_comment(p, c) or_return
			}
			continue
		}
		return true
	}
}

@(private)
flow_is_key :: proc "contextless" (p: ^Parser, block: bool) -> bool #no_bounds_check {
	if !closer_then_colon(p) {
		return false
	}
	i := p.pos
	depth := 0
	prev := u8('[')
	for i < u64(len(p.src)) && i - p.pos <= KEY_MAX && !is_break(p.src[i]) {
		b := p.src[i]
		switch b {
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
			if depth == 0 {
				i += 1
				if i - p.pos > KEY_MAX {
					return false
				}
				for i < u64(len(p.src)) && is_white(p.src[i]) {
					i += 1
				}
				if at(p, i) != ':' {
					return false
				}
				return !block || is_space_at(p, i + 1)
			}
		case '"', '\'':
			if prev == '[' || prev == '{' || prev == ',' || prev == ':' || prev == '?' {
				i += 1
				for i < u64(len(p.src)) && !is_break(p.src[i]) && p.src[i] != b {
					if b == '"' && p.src[i] == '\\' {
						i += 1
					}
					i += 1
				}
				if i >= u64(len(p.src)) || is_break(p.src[i]) {
					return false
				}
			}
		}
		if !is_white(b) {
			prev = b
		}
		i += 1
	}
	return false
}

@(private)
closer_then_colon :: proc "contextless" (p: ^Parser) -> bool #no_bounds_check {
	n := u64(len(p.src))
	i := p.pos
	for i < n {
		if i - p.pos > KEY_MAX {
			return false
		}
		base := i &~ 63
		brk, colon: u64
		if i == p.pos {
			m := masks_at(p, i)
			brk, colon = m.brk | m.end, m.colon
		} else {
			brk, colon = breaks_and_colons(p.src, base)
		}
		live := ~u64(0) << (i - base)
		stop := brk & live
		for colons := colon & live & before_first(stop); colons != 0; colons &= colons - 1 {
			j := base + lane(colons)
			for j > p.pos && is_white(p.src[j - 1]) {
				j -= 1
			}
			if j > p.pos && (p.src[j - 1] == ']' || p.src[j - 1] == '}') {
				return true
			}
		}
		if stop != 0 {
			return false
		}
		i = base + 64
	}
	return false
}

@(private)
Flow :: struct {
	lo:          u64,
	seq:         bool,
	after_value: bool,
	explicit:    bool,
	then:        Flow_Step,
}

@(private)
Flow_Step :: enum u8 {
	Entry,
	Entry_Done,
	Pair_Key,
	Pair_Value,
	Map_Key,
}

@(private)
Flow_Then :: enum u8 {
	Line,
	Key_Line,
	Key,
	Known_Key,
}

@(private)
parse_flow :: proc(p: ^Parser, n: int, role: tape.Role, then: Flow_Then) -> bool {
	flow_open(p, role) or_return
	p.flow_n, p.flow_step, p.flow_then = n, .Entry, then
	read_flow(p) or_return
	return flow_done(p)
}

@(private)
read_flow :: proc(p: ^Parser) -> bool #no_bounds_check {
	n := p.flow_n
	step_kind := p.flow_step
	for {
		top := len(p.flows) - 1
		f := p.flows[top]
		close := u8(']') if f.seq else '}'
		switch step_kind {
		case .Entry:
			flow_space(p, n, f.after_value) or_return
			if at_eof(p) {
				return fault(p, f.lo, .Truncated, .Open_Collection)
			}
			c := p.src[p.pos]
			if c == close {
				flush_foot(p, 0) or_return
				emit(p, tape.Token{p.pos, 1, .End, .Value, STYLE_FLOW}) or_return
				p.pos += 1
				pop(&p.flows)
				leave(p)
				if top == 0 {
					return true
				}
				step_kind = p.flows[top - 1].then
				continue
			}
			if c == ',' || c == ']' || c == '}' {
				return fault(p, p.pos, .Bad_Char, .Expected_Value)
			}
			if f.seq {
				step_kind = flow_seq_entry(p, n) or_return
			} else {
				step_kind = flow_map_entry(p, n) or_return
			}
		case .Entry_Done:
			flow_space(p, n, true) or_return
			if at_eof(p) {
				return fault(p, f.lo, .Truncated, .Open_Collection)
			}
			c := p.src[p.pos]
			if c == ',' {
				p.pos += 1
				p.flows[top].after_value = true
			} else if c != close {
				return fault(p, p.pos, .Bad_Char, .Expected_Comma)
			}
			step_kind = .Entry
		case .Pair_Key:
			flow_space(p, n, false) or_return
			step_kind = flow_pair_end(p, n, true) or_return
		case .Pair_Value:
			step_kind = flow_pair_close(p) or_return
		case .Map_Key:
			step_kind = flow_map_value(p, n, f.explicit, true) or_return
		}
	}
}

@(private)
flow_done :: proc(p: ^Parser) -> bool {
	switch p.flow_then {
	case .Line:
		return finish_line(p, true)
	case .Key_Line:
		return finish_line(p, false)
	case .Key:
		return key_colon(p, p.flow_n)
	case .Known_Key:
		skip_ws(p)
		return map_value(p, p.flow_n)
	}
	return true
}

@(private)
flow_open :: proc(p: ^Parser, role: tape.Role) -> bool #no_bounds_check {
	enter(p) or_return
	lo := p.pos
	seq := p.src[lo] == '['
	emit(p, tape.Token{lo, 0, .Array if seq else .Object, role, STYLE_FLOW}) or_return
	if _, e := append(&p.flows, Flow{lo = lo, seq = seq}); e != nil {
		return oom_fault(p, lo)
	}
	p.pos += 1
	return true
}

@(private)
flow_nest :: proc(p: ^Parser, role: tape.Role, then: Flow_Step) -> bool {
	p.flows[len(p.flows) - 1].then = then
	return flow_open(p, role)
}

@(private)
flow_colon :: #force_inline proc "contextless" (p: ^Parser, json_like: bool) -> bool {
	return at(p, p.pos) == ':' && (json_like || is_space_at(p, p.pos + 1) || is_flow_indicator(at(p, p.pos + 1)))
}

@(private)
flow_value :: proc(p: ^Parser, n: int, json_like: bool, then: Flow_Step) -> (nested: bool, ok: bool) {
	if flow_colon(p, json_like) {
		p.pos += 1
		flow_space(p, n, false) or_return
		if c := at(p, p.pos); !(c == ',' || c == ']' || c == '}') {
			_, nested, ok = parse_flow_node(p, n, .Value, then)
			return
		}
	}
	return false, emit(p, empty_plain_token(p.pos, .Value))
}

@(private)
flow_map_entry :: proc(p: ^Parser, n: int) -> (next_step: Flow_Step, ok: bool) {
	json_like := false
	explicit := at(p, p.pos) == '?' && is_space_at(p, p.pos + 1)
	if explicit {
		p.pos += 1
		flow_space(p, n, false) or_return
	}
	c := at(p, p.pos)
	if flow_colon(p, false) || explicit && (c == ',' || c == '}') {
		emit(p, empty_plain_token(p.pos, .Key)) or_return
	} else {
		p.flows[len(p.flows) - 1].explicit = explicit
		nested: bool
		json_like, nested = parse_flow_node(p, n, .Key, .Map_Key) or_return
		if nested {
			return .Entry, true
		}
	}
	return flow_map_value(p, n, explicit, json_like)
}

@(private)
flow_map_value :: proc(p: ^Parser, n: int, explicit, json_like: bool) -> (next_step: Flow_Step, ok: bool) {
	flow_space(p, n, false) or_return
	if explicit && at(p, p.pos) != ':' {
		return .Entry_Done, emit(p, empty_plain_token(p.pos, .Value))
	}
	nested := flow_value(p, n, json_like, .Entry_Done) or_return
	return .Entry if nested else .Entry_Done, true
}

@(private)
flow_seq_entry :: proc(p: ^Parser, n: int) -> (next_step: Flow_Step, ok: bool) {
	lo := p.pos
	if at(p, p.pos) == '?' && is_space_at(p, p.pos + 1) {
		p.pos += 1
		flow_space(p, n, false) or_return
		emit(p, tape.Token{lo, 0, .Object, .Value, 0}) or_return
		json_like := false
		c := at(p, p.pos)
		if flow_colon(p, false) || c == ',' || c == ']' {
			emit(p, empty_plain_token(p.pos, .Key)) or_return
		} else {
			nested: bool
			json_like, nested = parse_flow_node(p, n, .Key, .Pair_Key) or_return
			if nested {
				return .Entry, true
			}
		}
		flow_space(p, n, false) or_return
		return flow_pair_end(p, n, json_like)
	}
	if flow_colon(p, false) {
		emit(p, tape.Token{lo, 0, .Object, .Value, 0}) or_return
		emit(p, empty_plain_token(p.pos, .Key)) or_return
		return flow_pair_end(p, n, false)
	}
	props: Props
	parse_props(p, &props, true) or_return
	if !props_empty(&props) {
		flow_space(p, n, false) or_return
	}
	c := at(p, p.pos)
	if c == '*' && !props_empty(&props) {
		return .Entry, fault(p, p.pos, .Bad_Char, .Alias_Property)
	}
	if c == '[' || c == '{' {
		if flow_is_key(p, false) {
			emit(p, tape.Token{lo, 0, .Object, .Value, 0}) or_return
			emit_props(p, &props) or_return
			return .Entry, flow_nest(p, .Key, .Pair_Key)
		}
		emit_props(p, &props) or_return
		return .Entry, flow_nest(p, .Value, .Entry_Done)
	}
	if !props_empty(&props) && (c == ',' || c == ']' || flow_colon(p, false)) {
		if flow_colon(p, false) {
			emit(p, tape.Token{lo, 0, .Object, .Value, 0}) or_return
			emit_props(p, &props) or_return
			emit(p, empty_plain_token(p.pos, .Key)) or_return
			return flow_pair_end(p, n, false)
		}
		emit_props(p, &props) or_return
		return .Entry_Done, emit(p, empty_plain_token(p.pos, .Value))
	}
	line := p.ls
	clear(&p.stage)
	p.staging = true
	emit_props(p, &props) or_return
	key_idx := len(p.stage)
	node_lo := p.pos
	lines := parse_scalar_node(p, n, .Value, true, true) or_return
	json_like := c == '"' || c == '\''
	skip_ws(p)
	if flow_colon(p, json_like) {
		if lines || p.ls != line {
			return .Entry, fault(p, node_lo, .Bad_Char, .Multiline_Key)
		}
		if p.pos - node_lo > KEY_MAX {
			return .Entry, fault(p, node_lo, .Bad_Char, .Key_Too_Long)
		}
		p.staging = false
		emit(p, tape.Token{lo, 0, .Object, .Value, 0}) or_return
		flush_stage(p, key_idx) or_return
		return flow_pair_end(p, n, json_like)
	}
	return .Entry_Done, flush_stage(p, -1)
}

@(private)
flow_pair_end :: proc(p: ^Parser, n: int, json_like: bool) -> (next_step: Flow_Step, ok: bool) {
	nested := flow_value(p, n, json_like, .Pair_Value) or_return
	if nested {
		return .Entry, true
	}
	return flow_pair_close(p)
}

@(private)
flow_pair_close :: proc(p: ^Parser) -> (next_step: Flow_Step, ok: bool) {
	return .Entry_Done, emit(p, tape.Token{p.last_end, 0, .End, .Value, 0})
}

@(private)
parse_flow_node :: proc(p: ^Parser, n: int, role: tape.Role, then: Flow_Step) -> (json_like: bool, nested: bool, ok: bool) {
	props: Props
	parse_props(p, &props, true) or_return
	if !props_empty(&props) {
		flow_space(p, n, false) or_return
	}
	c := at(p, p.pos)
	if c == '*' && !props_empty(&props) {
		return false, false, fault(p, p.pos, .Bad_Char, .Alias_Property)
	}
	if !props_empty(&props) && (c == ',' || c == ']' || c == '}' || flow_colon(p, false)) {
		emit_props(p, &props) or_return
		return false, false, emit(p, empty_plain_token(p.pos, role))
	}
	emit_props(p, &props) or_return
	switch c {
	case '[', '{':
		return true, true, flow_nest(p, role, then)
	case '"', '\'':
		_ = parse_scalar_node(p, n, role, true, true) or_return
		return true, false, true
	}
	_ = parse_scalar_node(p, n, role, true, true) or_return
	return false, false, true
}
