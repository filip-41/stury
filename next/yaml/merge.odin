package yaml

import "stury:lib/core/tape"

// Merge keys (`<<`) under `.Yaml_Merge`: holds one or more `<<` keys and their values while the mapping reads,
// then at mapping close emits members from any source mapping(s) whose keys are absent from the host and earlier sources.

@(private)
Merge_Run :: struct {
	lo, hi: u32,
}

@(private)
merge_starts :: #force_inline proc "contextless" (p: ^Parser, t: tape.Token) -> bool #no_bounds_check {
	return p.merge_keys && p.sink_data != nil && !p.holding && !p.replaying && t.n == 2 && (t.kind == .Plain || t.kind == .String) && style_of(t.spelling) == .Plain && p.src[t.lo] == '<' && p.src[t.lo + 1] == '<'
}

@(private)
merge_hold :: proc(p: ^Parser, t: tape.Token) -> bool {
	if p.pend_anch >= 0 {
		// Anchoring the bare key token `&k <<: ...` completes `&k` on `<<` itself before entering value-hold mode.
		if p.needs_log {
			if _, err := append(&p.log, t); err != nil {
				return oom_fault(p, t.lo)
			}
		}
		complete_anchor(p, p.pend_anch)
		p.pend_anch = -1
	}
	f := &p.keys.frames[len(p.keys.frames) - 1]
	run_lo := u32(len(p.merges))
	if _, err := append(&p.merge_runs, Merge_Run{lo = run_lo, hi = run_lo}); err != nil {
		return oom_fault(p, t.lo)
	}
	f.runs_hi = u32(len(p.merge_runs))
	if _, err := append(&p.merges, t); err != nil {
		return oom_fault(p, t.lo)
	}
	p.holding = true
	p.hold_depth = 0
	p.hold_open_n = len(p.open)
	p.hold_anch_lo = len(p.anchors)
	p.hold_log_lo = len(p.log)
	return true
}

@(private)
merge_take :: proc(p: ^Parser, t: tape.Token) -> bool {
	if _, err := append(&p.merges, t); err != nil {
		return oom_fault(p, t.lo)
	}
	if t.role > .Key {
		return true
	}
	switch t.kind {
	case .Array, .Object:
		p.hold_depth += 1
		return true
	case .End:
		p.hold_depth -= 1
	case .Null, .False, .True, .Number, .Bytes, .String, .Plain:
	}
	if p.hold_depth == 0 {
		p.holding = false
		p.merge_runs[len(p.merge_runs) - 1].hi = u32(len(p.merges))
		if p.hold_open_n > 0 && len(p.log) > p.hold_log_lo {
			rotate_held_anchor_log(p)
		}
	}
	return true
}

// Moves any inner-anchor log entries created during `<<:` value parsing before the outermost enclosing open anchor's
// log slice so outer anchored mappings stay free of raw `<<:` tokens while inner anchors remain valid for replay.
@(private = "file")
rotate_held_anchor_log :: proc(p: ^Parser) #no_bounds_check {
	outer_idx := p.open[0].anchor
	A := p.anchors[outer_idx].log_lo
	B := p.hold_log_lo
	C := len(p.log)
	if A >= B || B >= C {
		return
	}
	reverse_tokens(p.log[A:B])
	reverse_tokens(p.log[B:C])
	reverse_tokens(p.log[A:C])
	shift_up := C - B
	shift_dn := B - A
	for k in outer_idx ..< p.hold_anch_lo {
		a := &p.anchors[k]
		if a.open || a.log_hi > A {
			a.log_lo += shift_up
			if !a.open {
				a.log_hi += shift_up
			}
		}
	}
	for k in p.hold_anch_lo ..< len(p.anchors) {
		a := &p.anchors[k]
		a.log_lo -= shift_dn
		if !a.open {
			a.log_hi -= shift_dn
		}
	}
}

@(private = "file")
reverse_tokens :: proc "contextless" (s: []tape.Token) #no_bounds_check {
	i, j := 0, len(s) - 1
	for i < j {
		s[i], s[j] = s[j], s[i]
		i += 1
		j -= 1
	}
}

@(private)
emit_merged :: #force_inline proc(p: ^Parser, t: tape.Token) -> bool {
	if p.needs_log && (t.role <= .Key || t.role == .Tag || t.role == .Alias) && len(p.open) > 0 {
		if _, err := append(&p.log, t); err != nil {
			return oom_fault(p, t.lo)
		}
	}
	return sink_give(p, t)
}

@(private)
merge_apply :: proc(p: ^Parser, f: Key_Frame) -> bool {
	runs := p.merge_runs[f.runs_lo:f.runs_hi]
	base_lo := runs[0].lo
	defer {
		resize(&p.merges, int(base_lo))
		resize(&p.merge_runs, int(f.runs_lo))
	}
	for run in runs {
		held := p.merges[run.lo:run.hi]
		if len(held) == 0 {
			continue
		}
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
			// Record literal non-merge `<<` key so a subsequent valid `<<:` won't overwrite it, then emit held tokens.
			if _, ok := key_enter(&p.keys, held[0], p.src); !ok {
				return oom_fault(p, held[0].lo)
			}
			for t in held {
				emit_merged(p, t) or_return
			}
			continue
		}
		if held[value].kind == .Object {
			merge_members(p, held, value) or_return
		} else {
			for i := past_facts(held, value + 1); i < len(held) && held[i].kind != .End; i = past_facts(held, subtree_end(held, i)) {
				merge_members(p, held, i) or_return
			}
		}
	}
	return true
}

@(private)
merge_members :: proc(p: ^Parser, held: []tape.Token, open: int) -> bool #no_bounds_check {
	i := open + 1
	for i < len(held) && held[i].kind != .End {
		if held[i].role == .Comment_Foot {
			i += 1
			continue
		}
		lo := i
		for i < len(held) && held[i].kind != .End && held[i].role != .Key {
			i += 1
		}
		if i >= len(held) || held[i].kind == .End {
			break
		}
		key := i
		val_start := past_facts(held, subtree_end(held, key))
		end := subtree_end(held, val_start)
		for end < len(held) && held[end].role == .Comment_Inline {
			end += 1
		}
		repeated, ok := key_enter(&p.keys, held[key], p.src)
		if !ok {
			return oom_fault(p, held[key].lo)
		}
		if !repeated {
			for t in held[lo:end] {
				emit_merged(p, t) or_return
			}
		}
		i = end
	}
	return true
}

@(private)
past_facts :: proc "contextless" (held: []tape.Token, i: int) -> int {
	k := i
	for k < len(held) && held[k].role > .Key {
		k += 1
	}
	return k
}

@(private)
subtree_end :: proc "contextless" (held: []tape.Token, i: int) -> int {
	if i >= len(held) {
		return len(held)
	}
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
