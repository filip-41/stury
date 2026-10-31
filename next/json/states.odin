package json

import "base:intrinsics"
import core "../core"

// Every state takes these arguments. `p` is the cursor, `end` one past the text, `d` the depth shifted left once with
// the open container's kind in bit 0 (1 for an object), `ind` the predicted indent (whitespace.odin), `w` the rest of
// the walk, and `s0`, `s1` and `s2` the hook's three registers.

// `p` is where a value must start, past whitespace.
@(private, enable_target_feature = STATE_FEATURES)
st_value :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	// Branches on the first byte's class, so `true` and `false` share a branch.
	switch VALUE_CLASS[p[0]] {
	case .String:
		q, escaped, stop := string_short(p, end)
		if q == nil {
			// A string with an escape is read by `st_string_escaped`, past the plain ASCII reader.
			if escaped {
				w.resume = stop
				return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
			return #must_tail st_string(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if emit_string(w, on, &hs, .String, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Number:
		q, spelling, kind := number_h(p, end, H)
		when .Es5 in FEATURES[S] {
			if kind != .None || q < end && q[0] | 0x20 == 'x' {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		if kind != .None {
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after_number(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Literal:
		q, e := literal(p, end)
		if q == nil {
			return #must_tail st_bad_literal(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if emit(w, on, &hs, e, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Map:
		if d >> 1 >= w.depth {
			return fault(w, hs, p, .Too_Deep)
		}
		w.stack[d >> 1] = u8(d & 1)
		switch emit(w, on, &hs, .Map, .Value, p, p[1:], 0) {
		case .Next:
		case .Skip:
			return #must_tail st_skip(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, on)
		case .Stop:
			return stopped(w, hs, p[1:])
		}
		return #must_tail st_open(p[1:], end, (d | 1) + 2, ind, w, hs.a, hs.b, hs.c, on)
	case .Array:
		if d >> 1 >= w.depth {
			return fault(w, hs, p, .Too_Deep)
		}
		w.stack[d >> 1] = u8(d & 1)
		switch emit(w, on, &hs, .Array, .Value, p, p[1:], 0) {
		case .Next:
		case .Skip:
			return #must_tail st_skip(p[1:], end, (d | 1) + 1, ind, w, hs.a, hs.b, hs.c, on)
		case .Stop:
			return stopped(w, hs, p[1:])
		}
		return #must_tail st_open(p[1:], end, (d | 1) + 1, ind, w, hs.a, hs.b, hs.c, on)
	case .Bad:
		when .Es5 in FEATURES[S] {
			// JSON5's own starts, a comment run, a close after a trailing comma, or the fault, all out of line, so this
			// state compiles none of it.
			return #must_tail st_value5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		} else {
			when .Comments in FEATURES[S] {
				if gap(p, end, S) {
					return #must_tail st_comments_value(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
				}
			}
			// An array's close where a value must start follows a comma, or an open bracket and comments.
			when .Trailing_Commas in FEATURES[S] {
				if p[0] == ']' && d & 1 == 0 && d >= 2 {
					return #must_tail st_close(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
				}
			}
		}
	}
	return fault(w, hs, p, .Bad_Char)
}

// `p` is where an object's key must start, past whitespace. Reads the key, its colon and the value after it.
@(private, enable_target_feature = STATE_FEATURES)
st_key :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	if p[0] != '"' {
		when .Es5 in FEATURES[S] {
			// A comment run, the object's close after a trailing comma, JSON5's own key, or the fault, all out of line,
			// so this state compiles none of it.
			return #must_tail st_key5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		} else {
			when .Comments in FEATURES[S] {
				if gap(p, end, S) {
					return #must_tail st_comments_key(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
				}
			}
			// An object's close where a key must start follows a comma, or an open bracket and comments.
			when .Trailing_Commas in FEATURES[S] {
				if p[0] == '}' {
					return #must_tail st_close(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
				}
			}
			return fault(w, hs, p, .Bad_Char, .Identifier)
		}
	}
	q, escaped, stop := string_probe(p, end)
	if q == nil {
		if escaped {
			w.resume = stop
			return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	switch emit_string(w, on, &hs, .String, .Key, p, q, 0) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	// Reads a colon flush against its value, or a pretty printer's `": "`, without entering `st_colon`.
	if intrinsics.ptr_sub(end, q) > 2 && q[0] == ':' {
		if q[1] > ' ' {
			return #must_tail st_value(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if q[1] == ' ' && q[2] > ' ' {
			return #must_tail st_value(q[2:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
	}
	// Reads a pretty printer's space before the colon as well: `" : "` and `" :"`.
	if intrinsics.ptr_sub(end, q) > 3 && q[0] == ' ' && q[1] == ':' {
		if q[2] > ' ' {
			return #must_tail st_value(q[2:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if q[2] == ' ' && q[3] > ' ' {
			return #must_tail st_value(q[3:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// Reads the value string at `p` that `string_short` did not vouch for, which is longer than 32 bytes, not ASCII, or
// faulty, with no backslash in its first 32 bytes. `string_lean` is inlined, so a plain ASCII string makes no call.
@(private, enable_target_feature = STATE_FEATURES)
st_string :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, escape := string_lean(p, end)
	if q == nil {
		if escape != nil {
			w.resume = escape
			return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .String, .Value, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// Reads the value string at `p` from the block at `w.resume`, which holds its first backslash. A separate state, so
// the mask registers are saved only for a string with an escape.
@(private, enable_target_feature = STATE_FEATURES)
st_string_escaped :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q := string_escaped(w.resume, end)
	if q == nil {
		return #must_tail st_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .String, .Value, p, q, 1) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_key_string_escaped` reads a key the way `st_string_escaped` reads a value.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string_escaped :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q := string_escaped(w.resume, end)
	if q == nil {
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	switch emit_string(w, on, &hs, .String, .Key, p, q, 1) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// Reads the value string at `p` that `string_lean` did not vouch for.
@(private, enable_target_feature = STATE_FEATURES)
st_string_long :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, esc, lax, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit_string(w, on, &hs, .String, .Value, p, q, string_spelling(esc, lax)) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_key_string` reads a key the way `st_string` reads a value.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, escape := string_lean(p, end)
	if q == nil {
		if escape != nil {
			w.resume = escape
			return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_key_string_long(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	switch emit_string(w, on, &hs, .String, .Key, p, q, 0) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_key_string_long` reads a key the way `st_string_long` reads a value.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string_long :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, esc, lax, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	switch emit_string(w, on, &hs, .String, .Key, p, q, string_spelling(esc, lax)) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is right after a key read by `st_key`. Reads whitespace, the colon, whitespace, then the member's value.
@(private, enable_target_feature = STATE_FEATURES)
st_colon :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	// Reads a pretty printer's `": "` without entering `colon`.
	if intrinsics.ptr_sub(end, p) > 2 && p[0] == ':' && p[1] == ' ' && p[2] > ' ' {
		return #must_tail st_value(p[2:], end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	q, kind := colon(p, end)
	if kind != .None {
		when .Comments in FEATURES[S] {
			if kind == .Bad_Char && gap(q, end, S) {
				return #must_tail st_comments_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		return fault(w, hs, q, kind, .Colon if kind == .Bad_Char else .None)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is right after an open bracket, and `d` is already the new container's.
@(private, enable_target_feature = STATE_FEATURES)
st_open :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	q := indent_fast(p, end, &ind, .Open)
	if q == nil {
		return #must_tail st_open_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	// `']' | 0x20` is `'}'`, so bit 0 of `d` selects the close bracket.
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == '[' {
		return #must_tail st_open_run(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is at an open bracket right after another. Pushes the whole run of `[` in this state.
@(private, enable_target_feature = STATE_FEATURES)
st_open_run :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	p, d := p, d
	for {
		if d >> 1 >= w.depth {
			return fault(w, hs, p, .Too_Deep)
		}
		w.stack[d >> 1] = u8(d & 1)
		d = (d | 1) + 1
		p = p[1:]
		switch emit(w, on, &hs, .Array, .Value, p[-1:], p, 0) {
		case .Next:
		case .Skip:
			return #must_tail st_skip(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		case .Stop:
			return stopped(w, hs, p)
		}
		if p >= end || p[0] != '[' {
			break
		}
	}
	return #must_tail st_open(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_open_ws` is `st_open` where whitespace follows the bracket. It is kept out of the hot states, whose entry would
// build its vectors.
@(private, enable_target_feature = STATE_FEATURES)
st_open_ws :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	q := skip_indent(p, end, &ind, .Open)
	if q < end && q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is right after a value. Reads a comma and the next member, the container's close, or the document's end.
@(private, enable_target_feature = STATE_FEATURES)
st_after :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	if d < 2 {
		// The root's inline and foot comments belong to its walk and are read only where a hook reads them. `validate`
		// passes over them while it checks what follows the document.
		when .Comments in FEATURES[S] && H != core.No_Hooks {
			if x := skip_ws(p, end); x < end && gap(x, end, S) {
				w.resume, w.crossed = x, false
				return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		return ended(w, hs, p)
	}
	q := indent_fast(p, end, &ind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, &ind, .Member)
		// A comment after the comma may be on the value's line, which only a state that knows where the value ended can
		// tell. The comment starts where `indent_fast` left off.
		when .Comments in FEATURES[S] {
			if r != nil && gap_after_ws(r, S) {
				w.resume, w.crossed = r, true
				return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
			if r == nil {
				return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if d & 1 != 0 {
			return #must_tail st_key(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	when .Comments in FEATURES[S] {
		if gap_after_ws(q, S) {
			w.resume, w.crossed = q, false
			return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
	}
	return fault(w, hs, q, .Bad_Char)
}

// `st_after_ws` is `st_after` where whitespace follows the value.
@(private, enable_target_feature = STATE_FEATURES)
st_after_ws :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	q := skip_indent(p, end, &ind, .Close)
	if q >= end {
		return fault(w, hs, end, .Truncated)
	}
	if q[0] == ',' {
		when .Comments in FEATURES[S] {
			if r := skip_ws(q[1:], end); r < end && gap_lead(r, S) {
				w.resume, w.crossed = r, true
				return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	when .Comments in FEATURES[S] {
		if gap_lead(q, S) {
			w.resume, w.crossed = q, false
			return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
	}
	return fault(w, hs, q, .Bad_Char)
}

// `p` is right after a comma, at whitespace or the text's end.
@(private, enable_target_feature = STATE_FEATURES)
st_member_ws :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	q := skip_indent(p, end, &ind, .Member)
	if d & 1 != 0 {
		return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is at the close bracket of container `d`. Reads it and the run of closes after it in this state.
@(private, enable_target_feature = STATE_FEATURES)
st_close :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
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
		if depth == 0 || p >= end || p[0] != ']' | stack[depth] << 5 {
			break
		}
	}
	k := stack[depth]
	if k & PASS_END != 0 {
		return #must_tail st_pass_end(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return #must_tail st_after(p, end, depth << 1 | u64(k), ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is right after the close that ends a walk passing over a skipped value. A separate state, so the close loop
// does not carry the result's position from byte to byte.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_pass_end :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	return ended(w, {s0, s1, s2}, p)
}

// `p` is at a literal that `literal` refused, where it breaks. Kept out of `st_value`, whose entry would save
// registers for the call.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_bad_literal :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, kind := literal_fault(p, end)
	return fault(w, hs, q, kind, .Literal if kind == .Bad_Char else .None)
}

// `p` is right after the open bracket of a container whose hook returned `Skip`, and `d` is the container's. The walk
// without hooks reads up to its close, and this walk continues after it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_skip :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	parent := d >> 1 - 1
	w.stack[parent] |= PASS_END
	r := pass_over(w, p, end, d, ind, true)
	if r & 0xff != 0 {
		w.regs^ = hs
		return r
	}
	w.stack[parent] &~= PASS_END
	return #must_tail st_after(w.base[r >> 16:], end, parent << 1 | u64(w.stack[parent]), ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is right after a key whose hook returned `Skip` for its member's value. Reads the colon, then the value with the
// walk without hooks, and continues after it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_skip_member :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, kind := colon(p, end)
	detail := Detail.Colon if kind == .Bad_Char else Detail.None
	// The comments around the colon belong to the skipped value and are passed over here, so the value's first byte
	// decides whether it is pushed.
	when .Comments in FEATURES[S] {
		if kind == .Bad_Char && gap(q, end, S) {
			detail = .None
			q, _, kind = comment_run(q, end, false, S)
			if kind == .None {
				q, kind = colon(q, end)
				if kind == .Bad_Char {
					detail = .Colon
				}
			}
		}
		if kind == .None && q < end && gap(q, end, S) {
			q, _, kind = comment_run(q, end, false, S)
		}
	}
	if kind != .None {
		return fault(w, hs, q, kind, detail)
	}
	// A scalar is read as a document's root, where the walk ends after one value. A container is pushed here as
	// `st_value` pushes it, with this object's slot marked, so the walk ends at its close.
	if q >= end || (q[0] != '{' && q[0] != '[') {
		r := pass_over(w, q, end, 0, ind, false)
		if r & 0xff != 0 {
			w.regs^ = hs
			return r
		}
		return #must_tail st_after(w.base[r >> 16:], end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if d >> 1 >= w.depth {
		return fault(w, hs, q, .Too_Deep)
	}
	w.stack[d >> 1] = u8(d & 1) | PASS_END
	r := pass_over(w, q[1:], end, (d | 1) + (2 if q[0] == '{' else 1), ind, true)
	if r & 0xff != 0 {
		w.regs^ = hs
		return r
	}
	w.stack[d >> 1] = u8(d & 1)
	return #must_tail st_after(w.base[r >> 16:], end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_after_number` is `st_after` for a number. When the next array element is also a number, `st_number_run` reads it
// from the comma on, so a run of numeric elements does not enter a value state. A separate state, kept out of
// `st_after` so the states every document uses keep their size and placement. The separator rules are `st_after`'s,
// and a change there belongs here too.
@(private, enable_target_feature = STATE_FEATURES)
st_after_number :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	if d < 2 {
		when .Comments in FEATURES[S] && H != core.No_Hooks {
			if x := skip_ws(p, end); x < end && gap(x, end, S) {
				w.resume, w.crossed = x, false
				return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		return ended(w, hs, p)
	}
	q := indent_fast(p, end, &ind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, &ind, .Member)
		when .Comments in FEATURES[S] {
			if r != nil && gap_after_ws(r, S) {
				w.resume, w.crossed = r, true
				return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
			if r == nil {
				return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		if r == nil {
			return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if d & 1 != 0 {
			return #must_tail st_member_run(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if r[0] == '-' || r[0] - '0' < 10 {
			return #must_tail st_number_run(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	when .Comments in FEATURES[S] {
		if gap_after_ws(q, S) {
			w.resume, w.crossed = q, false
			return #must_tail st_comments_after(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
	}
	return fault(w, hs, q, .Bad_Char)
}

// `p` is at the first byte of an array element, with the comma and the space or indent after it already read. A
// run of number elements stays in this state, so the byte after each comma is tested here and no state boundary lies
// between two elements.
@(private, enable_target_feature = STATE_FEATURES)
st_number_run :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	p := p
	q: [^]u8
	spelling: u16
	kind: core.Fault_Kind
	for {
		q, spelling, kind = number_h(p, end, H)
		when .Es5 in FEATURES[S] {
			if kind != .None || q < end && q[0] | 0x20 == 'x' {
				return #must_tail st_number5(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		if kind != .None {
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, p, q, spelling) == .Stop {
			return stopped(w, hs, q)
		}
		// `q[1]` and `q[2]` are read only where three bytes remain, so a run that ends at the text's last element passes
		// the separator to `st_after`.
		if intrinsics.ptr_sub(end, q) <= 2 || q[0] != ',' {
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
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is at an object's next key, with the comma and the space or indent after it already read. While the value
// that follows is a number, the key, colon, value and separator stay in this state, so no key or value state lies
// between two members. Anything else passes the rest of the walk to the states that read it.
@(private, enable_target_feature = STATE_FEATURES)
st_member_run :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	p := p
	for {
		// A key this state does not read at all is passed to `st_key`, which checks the opening quote, the other key
		// starts and the fault.
		if p >= end || p[0] != '"' {
			return #must_tail st_key(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		// A key this state does not read whole is passed where a failed `string_probe` sends `st_key`, so no byte is
		// read twice.
		q, escaped, stop := string_probe(p, end)
		if q == nil {
			if escaped {
				w.resume = stop
				return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
			return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		switch emit_string(w, on, &hs, .String, .Key, p, q, 0) {
		case .Next:
		case .Skip:
			return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
		case .Stop:
			return stopped(w, hs, q)
		}
		// Finds the value after the colon when the colon is flush against it, or is `": "`, `" : "` or `" :"`.
		r: [^]u8
		if intrinsics.ptr_sub(end, q) > 2 && q[0] == ':' {
			if q[1] > ' ' {
				r = q[1:]
			} else if q[1] == ' ' && q[2] > ' ' {
				r = q[2:]
			}
		}
		if r == nil && intrinsics.ptr_sub(end, q) > 3 && q[0] == ' ' && q[1] == ':' {
			if q[2] > ' ' {
				r = q[2:]
			} else if q[2] == ' ' && q[3] > ' ' {
				r = q[3:]
			}
		}
		if r == nil {
			return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if r[0] != '-' && r[0] - '0' >= 10 {
			return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		n, spelling, kind := number_h(r, end, H)
		when .Es5 in FEATURES[S] {
			if kind != .None || n < end && n[0] | 0x20 == 'x' {
				return #must_tail st_number5(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		if kind != .None {
			return fault(w, hs, n, kind)
		}
		if too_wide(r, n) {
			return fault(w, hs, r, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, r, n, spelling) == .Stop {
			return stopped(w, hs, n)
		}
		// `n[1]` and `n[2]` are read only where three bytes remain, as in `st_number_run`.
		if intrinsics.ptr_sub(end, n) <= 2 || n[0] != ',' {
			return #must_tail st_after_number(n, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		next := indent_fast(n[1:], end, &ind, .Member)
		when .Comments in FEATURES[S] {
			if next == nil || gap_after_ws(next, S) {
				return #must_tail st_after_number(n, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
		}
		if next == nil {
			return #must_tail st_member_ws(n[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		p = next
	}
}

// The class of a value's first byte, which `st_value` branches on.
@(private)
Value_Class :: enum u8 {
	Bad,
	String,
	Number,
	Literal,
	Map,
	Array,
}

@(private, rodata)
VALUE_CLASS := [256]Value_Class {
	'"' = .String,
	'-' = .Number,
	'0' ..= '9' = .Number,
	't' = .Literal,
	'f' = .Literal,
	'n' = .Literal,
	'{' = .Map,
	'[' = .Array,
}
