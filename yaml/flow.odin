package yaml

import core "../core"

// Moves over white space, line breaks and comments inside a flow collection. A line after a break must be indented
// past `n` unless it is blank or a comment. A comment on the line where a value ended is its inline comment when
// `after_value` is set.
@(private)
flow_space :: #force_inline proc(p: ^Parser, n: int, after_value: bool) -> bool {
	skip_ws(p)
	if c := at(p, p.pos); !is_break(c) && c != '#' {
		return true
	}
	return flow_lines(p, n, after_value)
}

@(private)
flow_lines :: proc(p: ^Parser, n: int, after_value: bool) -> bool {
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
			m := p.pos
			for m < u64(len(p.src)) && p.src[m] == ' ' {
				m += 1
			}
			w := m
			for w < u64(len(p.src)) && is_white(p.src[w]) {
				w += 1
			}
			if w < u64(len(p.src)) && !is_break(p.src[w]) {
				if m == p.pos && marker_at(p, m) != 0 {
					return fault(p, m, .Bad_Char, .Marker_In_Scalar)
				}
				if p.src[w] != '#' && int(m - p.pos) <= n {
					return fault(p, w, .Bad_Char, .Bad_Indent)
				}
			}
			p.pos = w
			continue
		}
		if b == '#' && comment_here(p) {
			c := read_comment(p) or_return
			if same_line {
				emit_raw(p, core.Token{c.lo, c.n, .Plain, .Comment_Inline, core.comment_spelling(1, 0)}) or_return
			} else {
				append(&p.pending, c)
			}
			continue
		}
		return true
	}
}

// Whether the flow collection at the cursor lies on one line and is followed by a `:` that makes it an implicit key.
@(private)
flow_is_key :: proc "contextless" (p: ^Parser, block: bool) -> bool {
	if !closer_then_colon(p) {
		return false
	}
	i := p.pos
	depth := 0
	prev := u8('[')
	for i < u64(len(p.src)) && !is_break(p.src[i]) {
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

// Whether a `:` may follow a `]` or `}` past white space on the cursor's line, which a flow collection that is a key
// needs. A line longer than a key may be answers true, as the colon of a long key's line may lie past the bound.
@(private)
closer_then_colon :: proc "contextless" (p: ^Parser) -> bool #no_bounds_check {
	n := u64(len(p.src))
	i := p.pos
	for i < n {
		if i - p.pos > KEY_MAX {
			return true
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

// A flow collection the walk has open, from its bracket at `lo`. `after_value` is set once an entry and its `,` have
// been read, and `then` and `explicit` say how the entry that holds the collection open inside it goes on when that
// one closes.
@(private)
Flow :: struct {
	lo:          u64,
	seq:         bool,
	after_value: bool,
	explicit:    bool, // the entry is a mapping entry that began with `?`
	then:        Flow_Step,
}

// What the flow walk does next, in the innermost collection open. A step that reads a node which is a collection opens
// it and leaves `Entry`, with the step to take once it closes in the frame of the collection that holds it.
@(private)
Flow_Step :: enum u8 {
	Entry, // the cursor is where the collection's next entry or its closing bracket may stand
	Entry_Done, // an entry has been read: a `,` or the closing bracket follows
	Pair_Key, // the key of a single pair, a collection, has been read
	Pair_Value, // the value of a single pair has been read: the one-entry mapping closes
	Map_Key, // the key of a mapping entry, a collection, has been read
}

// What the block walk does once the outermost flow collection closes.
@(private)
Flow_Then :: enum u8 {
	Line, // the collection is a node: its line ends
	Key, // the collection is the key of the innermost block mapping: its `:` and value follow
	Known_Key, // a key that `flow_is_key` found a `:` after, which the value follows
}

// Reads the flow collection at the cursor, read at indentation `n`, and what follows it, which `then` says. The
// collections inside it are frames of `p.flows`, not calls, so the native stack does not grow with their nesting.
@(private)
parse_flow :: proc(p: ^Parser, n: int, role: core.Role, then: Flow_Then) -> bool {
	flow_open(p, role) or_return
	p.flow_n, p.flow_step, p.flow_then = n, .Entry, then
	read_flow(p) or_return
	return flow_done(p)
}

// Reads the open flow collections from step `p.flow_step` until the outermost closes, or up to a pause, which leaves
// the block walk in state `.Flow`. A pause comes only before an entry or a close.
@(private)
read_flow :: proc(p: ^Parser) -> bool {
	n := p.flow_n
	step := p.flow_step
	for {
		top := len(p.flows) - 1
		f := p.flows[top]
		close := u8(']') if f.seq else '}'
		switch step {
		case .Entry:
			if p.pause {
				p.flow_step, p.next = step, .Flow
				return paused(p)
			}
			flow_space(p, n, f.after_value) or_return
			if at_eof(p) {
				return fault(p, f.lo, .Truncated, .Open_Collection)
			}
			c := p.src[p.pos]
			if c == close {
				flush_foot(p, 0) or_return
				emit(p, core.Token{p.pos, 1, .End, .Value, 0}) or_return
				p.pos += 1
				pop(&p.flows)
				leave(p)
				if top == 0 {
					return true
				}
				step = p.flows[top - 1].then
				continue
			}
			if c == ',' || c == ']' || c == '}' {
				return fault(p, p.pos, .Bad_Char, .Expected_Value)
			}
			if f.seq {
				step = flow_seq_entry(p, n) or_return
			} else {
				step = flow_map_entry(p, n) or_return
			}
		case .Entry_Done:
			flow_space(p, n, true) or_return
			c := at(p, p.pos)
			if c == ',' {
				p.pos += 1
				p.flows[top].after_value = true
			} else if c != close {
				return fault(p, p.pos, .Bad_Char, .Expected_Comma)
			}
			step = .Entry
		case .Pair_Key:
			flow_space(p, n, true) or_return
			step = flow_pair_end(p, n, true) or_return
		case .Pair_Value:
			step = flow_pair_close(p) or_return
		case .Map_Key:
			step = flow_map_value(p, n, f.explicit, true) or_return
		}
	}
}

// Reads what follows the outermost flow collection once it closed.
@(private)
flow_done :: proc(p: ^Parser) -> bool {
	switch p.flow_then {
	case .Line:
		return finish_line(p, true)
	case .Key:
		return key_colon(p, p.flow_n)
	case .Known_Key:
		skip_ws(p)
		return map_value(p, p.flow_n)
	}
	return true
}

// Opens the flow collection at the cursor as a frame of `p.flows`.
@(private)
flow_open :: proc(p: ^Parser, role: core.Role) -> bool {
	enter(p) or_return
	lo := p.pos
	seq := p.src[lo] == '['
	emit(p, core.Token{lo, 0, .Array if seq else .Object, role, 0}) or_return
	if _, e := append(&p.flows, Flow{lo = lo, seq = seq}); e != nil {
		return fault(p, lo, .No_Memory)
	}
	p.pos += 1
	return true
}

// Opens the flow collection at the cursor inside the innermost one, which takes step `then` when it closes.
@(private)
flow_nest :: proc(p: ^Parser, role: core.Role, then: Flow_Step) -> bool {
	p.flows[len(p.flows) - 1].then = then
	return flow_open(p, role)
}

// Whether a `:` at the cursor is a value indicator after a key. After a quoted scalar or a flow collection the value
// may follow it closely.
@(private)
flow_colon :: #force_inline proc "contextless" (p: ^Parser, json_like: bool) -> bool {
	return at(p, p.pos) == ':' && (json_like || is_space_at(p, p.pos + 1) || is_flow_indicator(at(p, p.pos + 1)))
}

// Reads the value after a key in a flow collection: a `:` and a node, or nothing for an empty value. A value that is a
// collection is opened, and `nested` is set: the innermost collection then takes step `then` when it closes.
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
	return false, emit(p, core.Token{p.pos, 0, .Plain, .Value, 0})
}

// Reads an entry of a flow mapping: a key and an optional value.
@(private)
flow_map_entry :: proc(p: ^Parser, n: int) -> (step: Flow_Step, ok: bool) {
	json_like := false
	explicit := at(p, p.pos) == '?' && is_space_at(p, p.pos + 1)
	if explicit {
		p.pos += 1
		flow_space(p, n, false) or_return
	}
	c := at(p, p.pos)
	if flow_colon(p, false) || explicit && (c == ',' || c == '}') {
		emit(p, core.Token{p.pos, 0, .Plain, .Key, 0}) or_return
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

// Reads what follows the key of a flow mapping's entry: its value, or an empty one after an explicit key with no `:`.
@(private)
flow_map_value :: proc(p: ^Parser, n: int, explicit, json_like: bool) -> (step: Flow_Step, ok: bool) {
	flow_space(p, n, true) or_return
	if explicit && at(p, p.pos) != ':' {
		return .Entry_Done, emit(p, core.Token{p.pos, 0, .Plain, .Value, 0})
	}
	nested := flow_value(p, n, json_like, .Entry_Done) or_return
	return .Entry if nested else .Entry_Done, true
}

// Reads an entry of a flow sequence: a node, or a single pair as a one-entry mapping.
@(private)
flow_seq_entry :: proc(p: ^Parser, n: int) -> (step: Flow_Step, ok: bool) {
	lo := p.pos
	if at(p, p.pos) == '?' && is_space_at(p, p.pos + 1) {
		p.pos += 1
		flow_space(p, n, false) or_return
		emit(p, core.Token{lo, 0, .Object, .Value, 0}) or_return
		json_like := false
		c := at(p, p.pos)
		if flow_colon(p, false) || c == ',' || c == ']' {
			emit(p, core.Token{p.pos, 0, .Plain, .Key, 0}) or_return
		} else {
			nested: bool
			json_like, nested = parse_flow_node(p, n, .Key, .Pair_Key) or_return
			if nested {
				return .Entry, true
			}
		}
		flow_space(p, n, true) or_return
		return flow_pair_end(p, n, json_like)
	}
	if flow_colon(p, false) {
		emit(p, core.Token{lo, 0, .Object, .Value, 0}) or_return
		emit(p, core.Token{p.pos, 0, .Plain, .Key, 0}) or_return
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
			emit(p, core.Token{lo, 0, .Object, .Value, 0}) or_return
			emit_props(p, &props) or_return
			return .Entry, flow_nest(p, .Key, .Pair_Key)
		}
		emit_props(p, &props) or_return
		return .Entry, flow_nest(p, .Value, .Entry_Done)
	}
	if !props_empty(&props) && (c == ',' || c == ']' || flow_colon(p, false)) {
		if flow_colon(p, false) {
			emit(p, core.Token{lo, 0, .Object, .Value, 0}) or_return
			emit_props(p, &props) or_return
			emit(p, core.Token{p.pos, 0, .Plain, .Key, 0}) or_return
			return flow_pair_end(p, n, false)
		}
		emit_props(p, &props) or_return
		return .Entry_Done, emit(p, core.Token{p.pos, 0, .Plain, .Value, 0})
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
		emit(p, core.Token{lo, 0, .Object, .Value, 0}) or_return
		flush_stage(p, key_idx) or_return
		return flow_pair_end(p, n, json_like)
	}
	return .Entry_Done, flush_stage(p, -1)
}

// Reads the value of a single pair, then closes its one-entry mapping when the value is not a collection left open.
@(private)
flow_pair_end :: proc(p: ^Parser, n: int, json_like: bool) -> (step: Flow_Step, ok: bool) {
	nested := flow_value(p, n, json_like, .Pair_Value) or_return
	if nested {
		return .Entry, true
	}
	return flow_pair_close(p)
}

// Sends the close of a single pair's one-entry mapping.
@(private)
flow_pair_close :: proc(p: ^Parser) -> (step: Flow_Step, ok: bool) {
	return .Entry_Done, emit(p, core.Token{p.last_end, 0, .End, .Value, 0})
}

// Reads a node of a flow collection: properties, then an alias, a collection or a scalar, or nothing for an empty
// node. Returns whether the node was a quoted scalar or a collection, which a `:` may follow closely. A collection is
// opened inside the innermost one, which takes step `then` when it closes, and `nested` is set.
@(private)
parse_flow_node :: proc(p: ^Parser, n: int, role: core.Role, then: Flow_Step) -> (json_like: bool, nested: bool, ok: bool) {
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
		return false, false, emit(p, core.Token{p.pos, 0, .Plain, role, 0})
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
