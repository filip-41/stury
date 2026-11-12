package yaml

import core "../core"

// A node's tag and anchor, as the spans where the text wrote them.
@(private)
Prop :: struct {
	lo: u64,
	n:  u32,
}

@(private)
Props :: struct {
	tag:    Prop,
	anchor: Prop,
	first:  core.Role, // the one written first, which `Tag` or `Anchor` names, or `Value` for none
}

@(private)
props_empty :: #force_inline proc "contextless" (pr: ^Props) -> bool {
	return pr.tag.n == 0 && pr.anchor.n == 0
}

// Adds the properties of `from` to `to`, a fault where both hold the same one.
@(private)
props_merge :: proc "contextless" (p: ^Parser, to, from: ^Props) -> bool {
	if from.tag.n != 0 {
		if to.tag.n != 0 {
			return fault(p, from.tag.lo, .Bad_Char, .Duplicate_Property)
		}
		to.tag = from.tag
	}
	if from.anchor.n != 0 {
		if to.anchor.n != 0 {
			return fault(p, from.anchor.lo, .Bad_Char, .Duplicate_Property)
		}
		to.anchor = from.anchor
	}
	if to.first == .Value {
		to.first = from.first
	}
	return true
}

// Reads the tags and anchors at the cursor, each followed by white space. Stops at the first byte that is neither.
@(private)
parse_props :: #force_inline proc(p: ^Parser, pr: ^Props, flow: bool) -> bool {
	if c := at(p, p.pos); c != '!' && c != '&' {
		return true
	}
	return read_props(p, pr, flow)
}

@(private)
read_props :: proc(p: ^Parser, pr: ^Props, flow: bool) -> bool {
	for {
		switch at(p, p.pos) {
		case '!':
			if pr.tag.n != 0 {
				return fault(p, p.pos, .Bad_Char, .Duplicate_Property)
			}
			lo := p.pos
			read_tag(p, flow) or_return
			pr.tag = Prop{lo, u32(p.pos - lo)}
			if pr.first == .Value {
				pr.first = .Tag
			}
		case '&':
			if pr.anchor.n != 0 {
				return fault(p, p.pos, .Bad_Char, .Duplicate_Property)
			}
			lo := p.pos
			read_name(p) or_return
			pr.anchor = Prop{lo, u32(p.pos - lo)}
			if pr.first == .Value {
				pr.first = .Anchor
			}
		case:
			return true
		}
		if !is_space_at(p, p.pos) && !(flow && is_flow_indicator(at(p, p.pos))) {
			return fault(p, p.pos, .Bad_Char, .Bad_Tag)
		}
		skip_ws(p)
	}
}

// Reads `&name` or `*name`: the marker and at least one character that is neither white space nor a flow indicator.
@(private)
read_name :: proc "contextless" (p: ^Parser) -> bool {
	lo := p.pos
	i := lo + 1
	for i < u64(len(p.src)) && !is_space_at(p, i) && !is_flow_indicator(p.src[i]) {
		i = step(p, i) or_return
	}
	if i == lo + 1 {
		return fault(p, lo, .Bad_Char, .Bad_Anchor)
	}
	p.pos = i
	return true
}

// Reads a tag: `!`, `!suffix`, `!!suffix`, `!name!suffix` or `!<uri>`. The suffix is not empty after a handle with
// two `!`, and a named handle is one a `%TAG` directive declared.
@(private)
read_tag :: proc "contextless" (p: ^Parser, flow: bool) -> bool {
	lo := p.pos
	if at(p, lo + 1) == '<' {
		i := lo + 2
		for i < u64(len(p.src)) && p.src[i] != '>' {
			if !uri_char_at(p, i) {
				return fault(p, i, .Bad_Char, .Bad_Tag)
			}
			i += 3 if p.src[i] == '%' else 1
		}
		if i >= u64(len(p.src)) || i == lo + 2 {
			return fault(p, lo, .Bad_Char, .Bad_Tag)
		}
		p.pos = i + 1
		return true
	}
	i := lo + 1
	bang := u64(0)
	for i < u64(len(p.src)) && !is_space_at(p, i) && !(flow && is_flow_indicator(p.src[i])) {
		if p.src[i] == '!' {
			if bang != 0 {
				return fault(p, i, .Bad_Char, .Bad_Tag)
			}
			bang = i
		} else if is_flow_indicator(p.src[i]) || !uri_char_at(p, i) {
			return fault(p, i, .Bad_Char, .Bad_Tag)
		}
		i += 3 if p.src[i] == '%' else 1
	}
	if bang != 0 {
		if i == bang + 1 {
			return fault(p, lo, .Bad_Char, .Bad_Tag)
		}
		for k in lo + 1 ..< bang {
			if !is_word(p.src[k]) {
				return fault(p, k, .Bad_Char, .Bad_Tag)
			}
		}
		if bang > lo + 1 && !handle_declared(p, lo, bang + 1) {
			return fault(p, lo, .Bad_Char, .Undeclared_Handle)
		}
	}
	p.pos = i
	return true
}

@(private)
handle_declared :: proc "contextless" (p: ^Parser, lo, hi: u64) -> bool {
	for h in p.handles {
		if string(p.src[h.lo:h.hi]) == string(p.src[lo:hi]) {
			return true
		}
	}
	return false
}

// Sends the properties as facts before the node they belong to.
@(private)
emit_props :: proc(p: ^Parser, pr: ^Props) -> bool {
	if pr.anchor.n != 0 {
		emit(p, core.Token{pr.anchor.lo, pr.anchor.n, .Plain, .Anchor, core.comment_spelling(1, 0)}) or_return
	}
	if pr.tag.n != 0 {
		emit(p, core.Token{pr.tag.lo, pr.tag.n, .Plain, .Tag, 0}) or_return
	}
	return true
}

// Reads an alias at the cursor and sends it as a fact followed by the tokens of the node it names. The node's first
// token takes `role`.
@(private)
parse_alias :: proc(p: ^Parser, role: core.Role) -> bool {
	lo := p.pos
	read_name(p) or_return
	name := p.src[lo + 1:p.pos]
	found := -1
	for k := len(p.anchors) - 1; k >= 0; k -= 1 {
		a := p.anchors[k]
		if string(p.src[a.name_lo:a.name_lo + u64(a.name_n)]) == string(name) {
			found = k
			break
		}
	}
	if found < 0 {
		return fault(p, lo, .Bad_Char, .Undefined_Alias)
	}
	a := p.anchors[found]
	if a.open {
		return fault(p, lo, .Bad_Char, .Alias_Cycle)
	}
	p.expanded += a.size
	if p.expanded > p.limit {
		return fault(p, lo, .Too_Wide, .Alias_Limit)
	}
	emit(p, core.Token{lo, u32(p.pos - lo), .Plain, .Alias, core.comment_spelling(1, 0)}) or_return
	if p.sink == nil {
		return true
	}
	patched := false
	p.replaying = true
	defer p.replaying = false
	for k in a.log_lo ..< a.log_hi {
		t := p.log[k]
		if !patched && t.role <= .Key {
			t.role = role
			patched = true
		}
		emit(p, t) or_return
	}
	return true
}
