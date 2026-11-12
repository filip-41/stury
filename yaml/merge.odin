package yaml

// Merge keys under `Options.merge_keys`. A `<<` member's key and value tokens are held while the walk reads them, and
// at its mapping's close the members of each mapping the value names are sent, after the host's own, those whose key
// the host or an earlier source holds left out. A `<<` whose value is not a mapping or a list of mappings is sent as
// an ordinary member.

import core "../core"

// Whether key token `t` starts a merge: a plain `<<` of a mapping, outside a value being held.
@(private)
merge_starts :: #force_inline proc "contextless" (p: ^Parser, t: core.Token) -> bool {
	return p.merge_keys && p.sink != nil && !p.holding && t.n == 2 && t.kind == .Plain && p.src[t.lo] == '<' && p.src[t.lo + 1] == '<' && style_of(t.spelling) == .Plain
}

// Starts holding the `<<` key `t` and the value after it for the innermost mapping.
@(private)
merge_hold :: proc(p: ^Parser, t: core.Token) {
	f := &p.frames[len(p.frames) - 1]
	f.merge_lo = u32(len(p.merges))
	append(&p.merges, t)
	p.holding = true
	p.hold_depth = 0
}

// Holds token `t` of a `<<` value. The value ends with its scalar or its container's `End`.
@(private)
merge_take :: proc(p: ^Parser, t: core.Token) {
	append(&p.merges, t)
	if t.role > .Key {
		return
	}
	switch t.kind {
	case .Array, .Object:
		p.hold_depth += 1
		return
	case .End:
		p.hold_depth -= 1
	case .Null, .False, .True, .Number, .Bytes, .String, .Plain:
	}
	if p.hold_depth == 0 {
		p.holding = false
		p.frames[len(p.frames) - 1].merge_hi = u32(len(p.merges))
	}
}

// Sends the members the `<<` of mapping frame `f` adds, before the mapping's `End`.
@(private)
merge_apply :: proc(p: ^Parser, f: Key_Frame) -> bool {
	defer resize(&p.merges, int(f.merge_lo))
	held := p.merges[f.merge_lo:f.merge_hi]
	value := past_facts(held, 1)
	sources := 0
	switch {
	case value < len(held) && held[value].kind == .Object:
		sources = 1
	case value < len(held) && held[value].kind == .Array:
		for i := past_facts(held, value + 1); i < len(held) && held[i].kind != .End; i = past_facts(held, subtree_end(held, i)) {
			if held[i].kind != .Object {
				sources = 0
				break
			}
			sources += 1
		}
	}
	if sources == 0 {
		for t in held {
			call_sink(p, t) or_return
		}
		return true
	}
	if held[value].kind == .Object {
		return merge_members(p, held, value)
	}
	for i := past_facts(held, value + 1); i < len(held) && held[i].kind != .End; i = past_facts(held, subtree_end(held, i)) {
		merge_members(p, held, i) or_return
	}
	return true
}

// Sends the members of the held mapping at `open` whose key the host mapping does not hold yet.
@(private)
merge_members :: proc(p: ^Parser, held: []core.Token, open: int) -> bool {
	i := open + 1
	for i < len(held) && held[i].kind != .End {
		lo := i
		for held[i].role != .Key {
			i += 1
		}
		key := i
		end := subtree_end(held, past_facts(held, key + 1))
		if !key_enter(p, held[key]) {
			for t in held[lo:end] {
				call_sink(p, t) or_return
			}
		}
		i = end
	}
	return true
}

// The first token at `i` or after that is no fact.
@(private)
past_facts :: proc "contextless" (held: []core.Token, i: int) -> int {
	i := i
	for i < len(held) && held[i].role > .Key {
		i += 1
	}
	return i
}

// The token after the node that starts at `i`.
@(private)
subtree_end :: proc "contextless" (held: []core.Token, i: int) -> int {
	if held[i].kind != .Array && held[i].kind != .Object {
		return i + 1
	}
	depth := 0
	for k in i ..< len(held) {
		t := held[k]
		if t.role > .Key {
			continue
		}
		if t.kind == .Array || t.kind == .Object {
			depth += 1
		} else if t.kind == .End {
			depth -= 1
			if depth == 0 {
				return k + 1
			}
		}
	}
	return len(held)
}
