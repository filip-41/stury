package json

import "base:intrinsics"
import core "../core"

// The registers every state takes: `p` the cursor, `end` one past the text, `d` the depth shifted left once with
// the open container's kind in bit 0 (1 for an object), `ind` the predicted indent (whitespace.odin), `w` the rest,
// and the hook's registers.

// `p` stands where a value must start, past whitespace.
@(private, enable_target_feature = STATE_FEATURES)
st_value :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	// By class, so `true` and `false` take one branch.
	switch VALUE_CLASS[p[0]] {
	case .String:
		q, escaped := string_short(p, end)
		if q == nil {
			// A string with an escape goes past the reader of plain ASCII.
			if escaped {
				w.resume = p[1:]
				return #must_tail st_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
			}
			return #must_tail st_string(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if emit(w, on, &hs, .String, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Number:
		q, kind := number(p, end)
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
		if emit(w, on, &hs, .Number, .Value, p, q, 0) == .Stop {
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
			// JSON5's own starts, a comment run, a close after a trailing comma, or the fault: all of it out of
			// line, so this state carries none of it.
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

// `p` stands where an object's key must start, past whitespace: the key, its colon, and the value after it.
@(private, enable_target_feature = STATE_FEATURES)
st_key :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	if p >= end {
		return fault(w, hs, end, .Truncated)
	}
	if p[0] != '"' {
		when .Es5 in FEATURES[S] {
			// A comment run, the object's close after a trailing comma, JSON5's own key, or the fault: all of it
			// out of line, so this state carries none of it.
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
	q, escaped := string_probe(p, end)
	if q == nil {
		if escaped {
			w.resume = p[1:]
			return #must_tail st_key_string_escaped(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_key_string(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	switch emit(w, on, &hs, .String, .Key, p, q, 0) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	// A colon flush against its value, or a pretty printer's `": "`.
	if intrinsics.ptr_sub(end, q) > 2 && q[0] == ':' {
		if q[1] > ' ' {
			return #must_tail st_value(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		if q[1] == ' ' && q[2] > ' ' {
			return #must_tail st_value(q[2:], end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
	}
	// A pretty printer that puts a space before the colon as well: `" : "` and `" :"`.
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

// The value string at `p` that `string_short` did not vouch for: longer than 32 bytes, not ASCII, or faulty, with no
// backslash in its first 32 bytes.
// `string_lean` is inlined, so a plain ASCII string pays for no call.
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
	if emit(w, on, &hs, .String, .Value, p, q, 0) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// The value string at `p` read plain up to the block at `w.resume`, which holds its first backslash. A state of its
// own, so the masks' registers are saved only for a string with an escape.
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
	if emit(w, on, &hs, .String, .Value, p, q, 1) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_string_escaped` for a key.
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
	switch emit(w, on, &hs, .String, .Key, p, q, 1) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// The value string at `p` that `string_lean` did not vouch for.
@(private, enable_target_feature = STATE_FEATURES)
st_string_long :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, esc, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	if emit(w, on, &hs, .String, .Value, p, q, u16(esc)) == .Stop {
		return stopped(w, hs, q)
	}
	return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_string` for a key.
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
	switch emit(w, on, &hs, .String, .Key, p, q, 0) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `st_string_long` for a key.
@(private, enable_target_feature = STATE_FEATURES)
st_key_string_long :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, esc, kind := string_long(w, p, end)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	if too_wide(p, q) {
		return fault(w, hs, p, .Too_Wide)
	}
	switch emit(w, on, &hs, .String, .Key, p, q, u16(esc)) {
	case .Next:
	case .Skip:
		return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Stop:
		return stopped(w, hs, q)
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` stands right after a key read out of `st_key`: whitespace, the colon, whitespace, then the member's value.
@(private, enable_target_feature = STATE_FEATURES)
st_colon :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	// A pretty printer's `": "`.
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

// `p` stands right after an open bracket, `d` already the new container's.
@(private, enable_target_feature = STATE_FEATURES)
st_open :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	q := indent_fast(p, end, &ind, .Open)
	if q == nil {
		return #must_tail st_open_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	// `]` + 0x20 is `}`.
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

// `p` stands on an open bracket right after another: the run of `[` is pushed in this one state.
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

// `st_open` where whitespace follows the bracket: kept out of the hot states, whose entry would build its vectors.
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

// `p` stands right after a value: a comma and the next member, the container's close, or the end of the document.
@(private, enable_target_feature = STATE_FEATURES)
st_after :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	if d < 2 {
		// The root's inline and foot comments are its walk's, read only where a hook takes them: `validate` passes
		// over them as it checks what follows the document.
		when .Comments in FEATURES[S] && H != No_Hooks {
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
		// A comment after the comma may be on the value's line, which only a state that knows where the value
		// ended can tell. The comment starts where the indent's reader left off.
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

// `st_after` where whitespace follows the value.
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

// `p` stands right after a comma, on whitespace or the end.
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

// `p` stands on the close bracket of the container `d`: it and the run of closes after it, one state for the run.
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

// `p` stands right after the close that ends a walk passing over a skipped value. A state of its own, so the close
// loop does not carry the result's position from byte to byte.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_pass_end :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	return ended(w, {s0, s1, s2}, p)
}

// `p` stands on a literal that `literal` refused: where it breaks. Kept out of `st_value`, whose entry would save
// registers for the call.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_bad_literal :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, kind := literal_fault(p, end)
	return fault(w, hs, q, kind, .Literal if kind == .Bad_Char else .None)
}

// `p` stands right after the open bracket of a container whose hook asked to skip it, `d` the container's: the walk
// without hooks reads up to its close, and this walk goes on after it.
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

// `p` stands right after a key whose hook asked to skip its member's value: the colon, then the value read by the
// walk without hooks, then this walk goes on after it.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_skip_member :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, kind := colon(p, end)
	detail := Detail.Colon if kind == .Bad_Char else Detail.None
	// The comments around the colon are the skipped value's, passed over here so the value's first byte decides
	// whether it is pushed.
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
	// A scalar is read as a document's root, where the walk ends after one value. A container is pushed here, as
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

// `st_after` for a number: an array element that is also a number is read from the comma on by `st_number_run`, so
// a run of numeric elements never hands over to a value state. A state of its own, kept out of `st_after` so the
// states every document takes keep their size and placement. The separator rules are `st_after`'s, so a change
// there belongs here too.
@(private, enable_target_feature = STATE_FEATURES)
st_after_number :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	if d < 2 {
		when .Comments in FEATURES[S] && H != No_Hooks {
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

// `p` stands on the first byte of an array element, the comma and the one space or indent after it already read:
// a run of number elements stays in this state, so the comma's successor is tested here and no state boundary stands
// between one element and the next.
@(private, enable_target_feature = STATE_FEATURES)
st_number_run :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	p := p
	q: [^]u8
	for {
		kind: core.Fault_Kind
		q, kind = number(p, end)
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
		if emit(w, on, &hs, .Number, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		// `q[1]` and `q[2]` are read only where three bytes remain, so a run that ends at the text's last element
		// hands the separator to `st_after`.
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

// `p` stands on an object's next key, the comma and the one space or indent after it already read: while the value
// that follows is a number, the member's key, colon, value and separator stay in this state, so no key or value
// state stands between two members. Anything else hands the rest of the walk back to the states that read it.
@(private, enable_target_feature = STATE_FEATURES)
st_member_run :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	ind := ind
	p := p
	for {
		// A key this state does not read whole, or at all, is `st_key`'s: it checks the opening quote and reads the
		// same bytes, and faults alike.
		if p >= end || p[0] != '"' {
			return #must_tail st_key(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		q, _ := string_probe(p, end)
		if q == nil {
			return #must_tail st_key(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		switch emit(w, on, &hs, .String, .Key, p, q, 0) {
		case .Next:
		case .Skip:
			return #must_tail st_skip_member(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
		case .Stop:
			return stopped(w, hs, q)
		}
		// The value after the colon, when the colon is flush against it, `": "`, `" : "` or `" :"`.
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
		n, kind := number(r, end)
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
		if emit(w, on, &hs, .Number, .Value, r, n, 0) == .Stop {
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

// What the first byte of a value starts.
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
