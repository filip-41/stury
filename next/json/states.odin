package json

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
		if kind != NO_FAULT {
			return fault(w, hs, q, kind)
		}
		if too_wide(p, q) {
			return fault(w, hs, p, .Too_Wide)
		}
		if emit(w, on, &hs, .Number, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Literal:
		q, e := literal(p, end)
		if q == nil {
			r, kind := literal_fault(p, end)
			return fault(w, hs, r, kind, .Literal if kind == .Bad_Char else .None)
		}
		if emit(w, on, &hs, e, .Value, p, q, 0) == .Stop {
			return stopped(w, hs, q)
		}
		return #must_tail st_after(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	case .Map:
		if d >> 1 >= MAX_DEPTH {
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
		if d >> 1 >= MAX_DEPTH {
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
		return fault(w, hs, p, .Bad_Char)
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
	r, colon_kind := colon(q, end)
	if colon_kind != NO_FAULT {
		return fault(w, hs, r, colon_kind)
	}
	return #must_tail st_value(r, end, d, ind, w, hs.a, hs.b, hs.c, on)
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
	q, esc, kind := string_long(w.tier, p, end)
	if kind != NO_FAULT {
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
	q, esc, kind := string_long(w.tier, p, end)
	if kind != NO_FAULT {
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
	q, kind := colon(p, end)
	if kind != NO_FAULT {
		return fault(w, hs, q, kind)
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
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
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
		return ended(w, hs, p)
	}
	q := indent_fast(p, end, &ind, .Close)
	if q == nil {
		return #must_tail st_after_ws(p, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ',' {
		r := indent_fast(q[1:], end, &ind, .Member)
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
		return #must_tail st_member_ws(q[1:], end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q[0] == ']' | u8(d & 1) << 5 {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
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
	if kind != NO_FAULT {
		return fault(w, hs, q, kind)
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
	if d >> 1 >= MAX_DEPTH {
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
