package yaml

import "stury:lib/core/hook"
import "stury:lib/core/tape"

// YAML properties: tags, anchors, and alias replay.

@(private)
Prop :: struct {
	lo: u64,
	n:  u32,
}

@(private)
Props :: struct {
	tag:    Prop,
	anchor: Prop,
	first:  tape.Role,
}

@(private)
props_empty :: #force_inline proc "contextless" (pr: ^Props) -> bool {
	return pr.tag.n == 0 && pr.anchor.n == 0
}

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

@(private)
read_name :: proc "contextless" (p: ^Parser) -> bool #no_bounds_check {
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

@(private)
read_tag :: proc "contextless" (p: ^Parser, flow: bool) -> bool #no_bounds_check {
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
	target := string(p.src[lo:hi])
	for h in p.handles {
		if h.handle == target {
			return true
		}
	}
	return false
}

@(private)
emit_props :: proc(p: ^Parser, pr: ^Props) -> bool {
	if pr.anchor.n != 0 {
		emit(p, tape.Token{pr.anchor.lo, pr.anchor.n, .Plain, .Anchor, tape.fact_spelling(1, 0)}) or_return
	}
	if pr.tag.n != 0 {
		emit(p, tape.Token{pr.tag.lo, pr.tag.n, .Plain, .Tag, 0}) or_return
	}
	return true
}

@(private)
ANCHORS_SCANNED :: 32

@(private)
find_anchor :: proc(p: ^Parser, name: string) -> (int, bool) {
	if len(p.anchors) <= ANCHORS_SCANNED {
		for k := len(p.anchors) - 1; k >= 0; k -= 1 {
			if anchor_name(p, p.anchors[k]) == name {
				return k, true
			}
		}
		return -1, true
	}
	for ; p.indexed < len(p.anchors); p.indexed += 1 {
		key := anchor_name(p, p.anchors[p.indexed])
		p.names[key] = p.indexed
		if (p.names[key] or_else -1) != p.indexed {
			return -1, false
		}
	}
	return p.names[name] or_else -1, true
}

@(private)
parse_alias :: proc(p: ^Parser, role: tape.Role) -> bool {
	lo := p.pos
	read_name(p) or_return
	name := p.src[lo + 1:p.pos]
	found, lookup_ok := find_anchor(p, string(name))
	if !lookup_ok {
		return oom_fault(p, lo)
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
		p.fail = hook.walk_result(lo, hook.WALK_EXPANSION)
		return false
	}
	if a.rel_depth > 0 {
		if p.tdepth + a.rel_depth > p.max_depth {
			return depth_fault(p, lo)
		}
		if len(p.open) > 0 && p.tdepth + a.rel_depth > p.open[len(p.open) - 1].peak {
			p.open[len(p.open) - 1].peak = p.tdepth + a.rel_depth
		}
	}
	emit(p, tape.Token{lo, u32(p.pos - lo), .Plain, .Alias, tape.fact_spelling(1, 0)}) or_return
	if !p.needs_log {
		return true
	}
	patched := false
	p.replaying = true
	defer p.replaying = false
	for k in a.log_lo ..< a.log_hi {
		t := p.log[k]
		if !patched && t.role <= .Key {
			t.role = role
			if t.kind <= .True {
				if role == .Key {
					t.spelling |= tape.SPELLING_DECODE
				} else {
					t.spelling &~= tape.SPELLING_DECODE
				}
			}
			patched = true
		}
		emit(p, t) or_return
	}
	return true
}
