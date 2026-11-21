package json

import "base:intrinsics"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The walk's states, one procedure per place in the grammar. Each takes the cursor `p`, `end` one past the text, `d`
// the depth shifted left once with the open container's kind in bit 0 (1 for an object), `ind` the predicted indent
// (whitespace.odin), `w` the rest of the walk, `s0`, `s1` and `s2` the hook's registers, `m` the open object's gap slot
// and `G` whether the walk matches gaps (members.odin).

// The state at the start of a value, past white space.
@(private, enable_target_feature = STATE_FEATURES)
st_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	// Branches on the first byte's class, so `true`, `false` and `null` share a branch.
	#partial switch VALUE_CLASS[p[0]] {
	case .String:
		q, escaped, stop := string_short(p, end, '"')
		if q == nil {
			if escaped {
				w.resume = stop
				return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			// A byte past ASCII or a control byte, which `st_string` would only find again.
			if stop != nil {
				return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			return #must_tail st_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if emit_string(w, on, &hs, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	case .Number:
		q, spelling, kind := number(p, end, H != tape.No_Hooks, S)
		if kind != .None {
			when S == .Json5 {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
			return stopped(w, hs, q)
		}
		when G {
			if d & 1 != 0 {
				return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
		}
		return #must_tail st_after_number(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	case .Literal:
		q, k := literal(p, end)
		if q == nil {
			return #must_tail st_bad_literal(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if emit(w, on, &hs, k, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	case .Map:
		if d >> 1 >= w.depth {
			return #must_tail st_deepen(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		w.stack[d >> 1] = level(d, m)
		if emit(w, on, &hs, .Object, .Value, p, p[1:], 0) == .Stop {
			return stopped(w, hs, p[1:])
		}
		when G {
			child := gap_child(w, m, G)
			if child == 0 {
				return #must_tail st_open_new_row(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			return #must_tail st_open(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, child, G, on)
		} else {
			return #must_tail st_open(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
	case .Array:
		if d >> 1 >= w.depth {
			return #must_tail st_deepen(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		w.stack[d >> 1] = level(d, m)
		if emit(w, on, &hs, .Array, .Value, p, p[1:], 0) == .Stop {
			return stopped(w, hs, p[1:])
		}
		return #must_tail st_open(p[1:], end, (d | 1) + 1, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	when S == .Json5 {
		switch p[0] {
		case '\'':
			return #must_tail st_string5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		case '+', '.', 'I', 'N':
			return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
	}
	when S != .Json {
		return #must_tail st_spec_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return #must_tail st_bad_value(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at an object's key, past white space, which reads on through the colon to the value.
@(private, enable_target_feature = STATE_FEATURES)
st_key :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	if p[0] != '"' {
		when S == .Json5 {
			return #must_tail st_key_ident(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		} else when S != .Json {
			return #must_tail st_spec_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return fault(w, hs, p, .Bad_Char)
	}
	q, escaped, stop := string_probe(p, end)
	if q == nil {
		if escaped {
			w.resume = stop
			return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit_string(w, on, &hs, .Key, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	if r := colon_fast(q, end); r != nil {
		when G {
			if gap_learn(w, m, p, q, r) {
				return #must_tail st_stop_gaps(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The start of a member's value when the colon after the key at `p` is flush against it or a pretty printer's `": "`,
// `" : "` or `" :"`; nil when `st_colon` must read the colon.
@(private)
colon_fast :: #force_inline proc "contextless" (q, end: [^]u8) -> [^]u8 {
	if intrinsics.ptr_sub(end, q) > 2 && q[0] == ':' {
		if q[1] > ' ' {
			return q[1:]
		}
		if q[1] == ' ' && q[2] > ' ' {
			return q[2:]
		}
	}
	if intrinsics.ptr_sub(end, q) > 3 && q[0] == ' ' && q[1] == ':' {
		if q[2] > ' ' {
			return q[2:]
		}
		if q[2] == ' ' && q[3] > ' ' {
			return q[3:]
		}
	}
	return nil
}

// The state at a value string that `string_short` refused, with no backslash in its first 32 bytes. `string_lean` is
// inlined, so a plain ASCII string makes no call.
@(private, enable_target_feature = STATE_FEATURES)
st_string :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, escape := string_lean(p, end, '"')
	if q == nil {
		if escape != nil {
			w.resume = escape
			return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Value, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a value string whose first escape is at `w.resume`.
@(private, enable_target_feature = STATE_FEATURES)
st_string_escaped :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q := string_escaped(w.resume, end)
	if q == nil {
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Value, p, q, tape.SPELLING_DECODE) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a value string past ASCII, or one the faster readers refused.
@(private, enable_target_feature = STATE_FEATURES)
st_string_long :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, spelling, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Value, p, q, spelling) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a key `string_probe` refused, longer than `PROBE_MAX` or past printable ASCII.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, escape := string_lean(p, end, '"')
	if q == nil {
		if escape != nil {
			w.resume = escape
			return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Key, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The state at a key whose first escape is at `w.resume`.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string_escaped :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, at := key_escaped_head(w.resume, end)
	if q == nil {
		q = string_escaped(at, end)
	}
	if q == nil {
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Key, p, q, tape.SPELLING_DECODE) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The state at a key past ASCII, or one the faster readers refused.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string_long :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, spelling, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .Key, p, q, spelling) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The state right after a key.
@(private, enable_target_feature = STATE_FEATURES)
st_colon :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	if intrinsics.ptr_sub(end, p) > 2 && p[0] == ':' && p[1] == ' ' && p[2] > ' ' {
		return #must_tail st_value(p[2:], end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	q, kind := colon(p, end)
	if kind != .None {
		when S != .Json {
			if kind == .Bad_Char {
				return #must_tail st_spec_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
		}
		return fault(w, hs, q, kind)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state right after an open bracket.
@(private, enable_target_feature = STATE_FEATURES)
st_open :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	when G {
		if d & 1 != 0 {
			if r, key, nl := gap_match(w, p, end, m); r != nil {
				if emit_key(w, on, &hs, key) == .Stop {
					return stopped(w, hs, r)
				}
				if nl {
					// The members are a step deeper, as `indent_predicted` would have found at a line break.
					ind += (ind >> 32) << 8
				}
				#partial switch VALUE_CLASS[r[0]] {
				case .String:
					return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
				case .Number:
					return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
				case .Literal:
					return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
				}
				return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
			}
			w.gap_lo = at(w, p)
		}
	}
	q := indent_fast(p, end, &ind, .Open)
	if q == nil {
		return #must_tail st_open_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == '[' {
		return #must_tail st_open_run(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The stack entry of a container opened in container `d`, whose gap slot is `m`.
@(private)
level :: #force_inline proc "contextless" (d, m: u64) -> u32 {
	return u32(']' | (d & 1) << 5 | m << 8)
}

@(private)
emit_key :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, key: tape.Token) -> tape.Action {
	a: tape.Action
	hs^, a = on(w.hooks, hs^, key)
	return a
}

// The state that leaves gap matching for a walk whose keys do not repeat, entering the states without gaps through a
// frame with no locals, as `-sanitize:address` loses its stack state across a `preserve/none` call from one with them.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_stop_gaps :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	return enter_no_gaps(p, end, d, ind, w, s0, s1, s2, m, on)
}

// The call into the states without gaps for `st_stop_gaps`.
@(private, cold)
enter_no_gaps :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	return st_value(p, end, d, ind, w, s0, s1, s2, m, false, on)
}

// The state at an object's open bracket whose parent slot has no row yet.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_open_new_row :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	row := gap_new_row(&w.gaps, m)
	return #must_tail st_open(p, end, d, ind, w, s0, s1, s2, row * GAP_MEMBERS, G, on)
}

// The state at an open bracket past the levels the walk holds.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_deepen :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	if k := deepen(w); k != 0 {
		return too_deep(w, {s0, s1, s2}, p, k)
	}
	return #must_tail st_value(p, end, d, ind, w, s0, s1, s2, m, G, on)
}

@(private, cold, enable_target_feature = STATE_FEATURES)
st_deepen_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	if k := deepen(w); k != 0 {
		return too_deep(w, {s0, s1, s2}, p, k)
	}
	return #must_tail st_open_run(p, end, d, ind, w, s0, s1, s2, m, G, on)
}

// The state at an array's first element when it is an array, which reads the run of open brackets.
@(private, enable_target_feature = STATE_FEATURES)
st_open_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	p, d := p, d
	stack, depth := w.stack, w.depth
	for {
		if d >> 1 >= depth {
			return #must_tail st_deepen_run(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		stack[d >> 1] = level(0, m)
		d += 2
		p = p[1:]
		if emit(w, on, &hs, .Array, .Value, p[-1:], p, 0) == .Stop {
			return stopped(w, hs, p)
		}
		if p >= end || p[0] != '[' {
			break
		}
	}
	return #must_tail st_open(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// `st_open` where white space follows the open bracket.
@(private, enable_target_feature = STATE_FEATURES)
st_open_ws :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	q := skip_indent(p, end, &ind, .Open)
	if q < end && q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state right after a value, which reads a comma and the next member, the container's close, or the root's end.
@(private, enable_target_feature = STATE_FEATURES)
st_after :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	if d < 2 {
		return done(w, hs, p)
	}
	when G {
		if d & 1 != 0 {
			if r, key, _ := gap_match(w, p, end, m); r != nil {
				if emit_key(w, on, &hs, key) == .Stop {
					return stopped(w, hs, r)
				}
				#partial switch VALUE_CLASS[r[0]] {
				case .String:
					return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
				case .Number:
					return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
				case .Literal:
					return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
				}
				return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
			}
			w.gap_lo = at(w, p)
		}
	}
	q := indent_fast(p, end, &ind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, &ind, .Member)
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if d & 1 != 0 {
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return fault(w, hs, q, .Bad_Char)
}

// `st_after` once no gap matches, which reads a comma and the next member, the container's close, or the root's end.
@(private, enable_target_feature = STATE_FEATURES)
st_after_unmatched :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	q := indent_fast(p, end, &ind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, &ind, .Member)
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if d & 1 != 0 {
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return fault(w, hs, q, .Bad_Char)
}

// The state at a string value whose member's gap matched, which matches the gap after it too.
@(private, enable_target_feature = STATE_FEATURES)
st_hit_string :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	#assert(G)
	hs := tape.Hook_Regs{s0, s1, s2}
	q, escaped, stop := string_short(p, end, '"')
	if q == nil {
		if escaped {
			w.resume = stop
			return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if stop != nil {
			return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit_string(w, on, &hs, .Value, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	r, key, _ := gap_match(w, q, end, m)
	if r == nil {
		w.gap_lo = at(w, q)
		return #must_tail st_after_unmatched(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit_key(w, on, &hs, key) == .Stop {
		return stopped(w, hs, r)
	}
	#partial switch VALUE_CLASS[r[0]] {
	case .String:
		return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	case .Number:
		return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	case .Literal:
		return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The state at a number value whose member's gap matched, which matches the gap after it too.
@(private, enable_target_feature = STATE_FEATURES)
st_hit_number :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	#assert(G)
	hs := tape.Hook_Regs{s0, s1, s2}
	q, spelling, kind := number(p, end, H != tape.No_Hooks, S)
	if kind != .None {
		when S == .Json5 {
			return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
		return stopped(w, hs, q)
	}
	r, key, _ := gap_match(w, q, end, m)
	if r == nil {
		w.gap_lo = at(w, q)
		return #must_tail st_after_unmatched(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit_key(w, on, &hs, key) == .Stop {
		return stopped(w, hs, r)
	}
	#partial switch VALUE_CLASS[r[0]] {
	case .String:
		return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	case .Number:
		return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	case .Literal:
		return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// The state at a literal value whose member's gap matched, which matches the gap after it too.
@(private, enable_target_feature = STATE_FEATURES)
st_hit_literal :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	#assert(G)
	hs := tape.Hook_Regs{s0, s1, s2}
	q, k := literal(p, end)
	if q == nil {
		return #must_tail st_bad_literal(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit(w, on, &hs, k, .Value, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	r, key, _ := gap_match(w, q, end, m)
	if r == nil {
		w.gap_lo = at(w, q)
		return #must_tail st_after_unmatched(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if emit_key(w, on, &hs, key) == .Stop {
		return stopped(w, hs, r)
	}
	#partial switch VALUE_CLASS[r[0]] {
	case .String:
		return #must_tail st_hit_string(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	case .Number:
		return #must_tail st_hit_number(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	case .Literal:
		return #must_tail st_hit_literal(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, gap_next(m, G), G, on)
}

// `st_after` where white space follows the value.
@(private, enable_target_feature = STATE_FEATURES)
st_after_ws :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	q := skip_indent(p, end, &ind, .Close)
	if q >= end {
		return fault(w, hs, end, .Truncated)
	}
	if q[0] == ',' {
		return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return fault(w, hs, q, .Bad_Char)
}

// The state right after a comma, at white space or the text's end.
@(private, enable_target_feature = STATE_FEATURES)
st_member_ws :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	q := skip_indent(p, end, &ind, .Member)
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at the close bracket of container `d`, which reads the run of closes after it too.
@(private, enable_target_feature = STATE_FEATURES)
st_close :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	p := p
	// The depth is carried apart from the kind bit, so the next close does not wait on the stack's load.
	depth := d >> 1
	stack := w.stack
	for {
		if emit(w, on, &hs, .End, .Value, p, p[1:], 0) == .Stop {
			return stopped(w, hs, p[1:])
		}
		depth -= 1
		p = p[1:]
		if depth == 0 || p >= end || u32(p[0]) != stack[depth] & 0xFF {
			break
		}
	}
	top := stack[depth]
	return #must_tail st_after(p, end, depth << 1 | u64(top >> 5 & 1), ind, w, hs.a, hs.b, hs.c, u64(top >> 8), G, on)
}

// The state right after a number in an array, or without gap matching in an object. Runs of numbers in an array go on
// in `st_number_run`, and runs of flush members with number values in `st_member_run`.
@(private, enable_target_feature = STATE_FEATURES)
st_after_number :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	if d < 2 {
		return done(w, hs, p)
	}
	q := indent_fast(p, end, &ind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, &ind, .Member)
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if d & 1 != 0 {
			when !G {
				// The run pays when a member follows its comma flush. An indented member reads faster through `st_key`.
				if r == q[1:] {
					return #must_tail st_member_run(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
				}
			}
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if r[0] == '-' || r[0] - '0' < 10 {
			return #must_tail st_number_run(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	when S != .Json {
		return #must_tail st_spec_after(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return fault(w, hs, q, .Bad_Char)
}

// The state at a number after a comma in an array, which reads numbers while each is followed by a comma and, after at
// most one space, another number.
@(private, enable_target_feature = STATE_FEATURES)
st_number_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	p := p
	q: [^]u8
	for {
		spelling: u16
		kind: tape.Fault_Kind
		q, spelling, kind = number(p, end, H != tape.No_Hooks, S)
		if kind != .None {
			when S == .Json5 {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
			return stopped(w, hs, q)
		}
		if intrinsics.ptr_sub(end, q) <= 2 || q[0] != ',' {
			when H == tape.No_Hooks || H == build.Builder {
				if intrinsics.ptr_sub(end, q) > 2 && q[2] == '[' && q[0] == ']' && q[1] == ',' {
					return #must_tail st_number_blocks(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
				}
			}
			break
		}
		r := q[1:]
		if r[0] == ' ' {
			r = r[1:]
		}
		if r[0] != '-' && r[0] - '0' >= 10 {
			break
		}
		p = r
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a key flush after a comma, which reads members while each is flush against the last and has a number
// value. A walk with gaps matches them in `st_after` instead.
@(private, enable_target_feature = STATE_FEATURES)
st_member_run :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	#assert(!G)
	hs := tape.Hook_Regs{s0, s1, s2}
	ind := ind
	p := p
	for {
		if p >= end || p[0] != '"' {
			return #must_tail st_key(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		q, escaped, stop := string_probe(p, end)
		if q == nil {
			if escaped {
				w.resume = stop
				return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if emit_string(w, on, &hs, .Key, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		r := colon_fast(q, end)
		if r == nil {
			return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		if r[0] != '-' && r[0] - '0' >= 10 {
			return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		n, spelling, kind := number(r, end, H != tape.No_Hooks, S)
		if kind != .None {
			when S == .Json5 {
				return #must_tail st_number5(r, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
			}
			return fault(w, hs, n, kind)
		}
		if too_wide(r, n) {
			return fault(w, hs, r, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, r, n, spelling) == .Stop {
			return stopped(w, hs, n)
		}
		if intrinsics.ptr_sub(end, n) <= 2 || n[0] != ',' {
			return #must_tail st_after_number(n, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		next := indent_fast(n[1:], end, &ind, .Member)
		if next == nil {
			return #must_tail st_member_ws(n[1:], end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
		}
		p = next
	}
}

@(private, cold, enable_target_feature = STATE_FEATURES)
st_bad_literal :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	q, kind := literal_fault(p, end)
	return fault(w, tape.Hook_Regs{s0, s1, s2}, q, kind)
}

@(private, cold, enable_target_feature = STATE_FEATURES)
st_bad_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	return fault(w, tape.Hook_Regs{s0, s1, s2}, p, .Bad_Char)
}

@(private)
Byte_Class :: enum u8 {
	Bad,
	String,
	Number,
	Literal,
	Map,
	Array,
}

@(private, rodata)
VALUE_CLASS := [256]Byte_Class {
	'"' = .String,
	'-' = .Number,
	'0' ..= '9' = .Number,
	't' = .Literal,
	'f' = .Literal,
	'n' = .Literal,
	'{' = .Map,
	'[' = .Array,
}
