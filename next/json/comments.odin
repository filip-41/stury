package json

import "base:intrinsics"
import "core:simd"
import core "../core"
import kernel "../core/kernel"

// This file reads the comments of the specs that have them. A `//` comment runs to the line's end, which is not part
// of the comment, and a `/* */` comment may be anywhere whitespace may be. A comment is a `Plain` fact token whose
// span includes its delimiters and whose `spelling` holds its marker lengths, 2 and 0 for `//`, 2 and 2 for `/* */`.
// Its role follows `core.Role`'s rule. A state that meets a `/` where it wants a token tail-calls a state here, which
// reads the whole run of whitespace and comments
// up to the next token before it emits any of them, since the token after the run decides each comment's role. A walk
// without hooks reads the run and emits nothing.

// Marks the lanes of `v` that `comment` must judge one at a time: a byte past 0x7F, which its UTF-8 reader judges, a
// control byte, which its control test judges in a spec without `.Es5`, a line end, which ends a `//` comment in
// JSON5, and a `*`, which may close a `/* */` comment. `v - 0x20 > 0x5f` is true for a control byte and a byte past
// 0x7F.
@(private)
comment_stops :: #force_inline proc "contextless" (v: #simd[16]u8, $S: Spec, $star: bool) -> #simd[16]u8 {
	V :: #simd[16]u8
	when .Es5 in FEATURES[S] {
		m := simd.lanes_gt(v, V(0x7f))
		when !star {
			m = simd.bit_or(m, simd.bit_or(simd.lanes_eq(v, V('\n')), simd.lanes_eq(v, V('\r'))))
		}
	} else {
		m := simd.lanes_gt(v - 0x20, V(0x5f))
	}
	when star {
		m = simd.bit_or(m, simd.lanes_eq(v, V('*')))
	}
	return m
}

// Returns the first byte from `q` that `comment` must judge one at a time, scanning 16 bytes at a step while 16 lie
// before `end`. When none is found, returns `q` advanced by the 16-byte steps.
@(private)
comment_scan :: #force_inline proc "contextless" (q, end: [^]u8, $S: Spec, $star: bool) -> [^]u8 #no_bounds_check {
	q := q
	for intrinsics.ptr_sub(end, q) >= 16 {
		k := kernel.first_lane(comment_stops(intrinsics.unaligned_load((^#simd[16]u8)(q)), S, star))
		if k != 16 {
			return q[k:]
		}
		q = q[16:]
	}
	return q
}

// Reads the comment at `p`, which is at a `/`. Returns one past its last byte, or the fault. A comment's bytes are
// judged as a string's raw bytes are: UTF-8, and no control byte but a tab, and in a `/* */` comment also CR and LF,
// else `Bad_Char` at that byte. JSON5 accepts any control byte, as its grammar does, and ends a `//` comment at
// U+2028 and U+2029 too. A `/` that opens no comment, the text's last byte among them, faults `Bad_Char` at the `/`,
// and a `/*` the text ends inside faults `Truncated`.
@(private)
comment :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	ES5 :: .Es5 in FEATURES[S]
	if intrinsics.ptr_sub(end, p) < 2 {
		return p, .Bad_Char
	}
	q = p[2:]
	switch p[1] {
	case '/':
		for {
			q = comment_scan(q, end, S, false)
			if q >= end || line_end(q, end, S) {
				return q, .None
			}
			if !ES5 && q[0] < 0x20 && q[0] != '\t' {
				return q, .Bad_Char
			}
			if q[0] < 0x80 {
				q = q[1:]
			} else if q, kind = kernel.utf8_char(q, end); kind != .None {
				return
			}
		}
	case '*':
		for {
			q = comment_scan(q, end, S, true)
			if q >= end {
				return end, .Truncated
			}
			if q[0] == '*' && intrinsics.ptr_sub(end, q) > 1 && q[1] == '/' {
				return q[2:], .None
			}
			if !ES5 && q[0] < 0x20 && q[0] != '\t' && q[0] != '\n' && q[0] != '\r' {
				return q, .Bad_Char
			}
			if q[0] < 0x80 {
				q = q[1:]
			} else if q, kind = kernel.utf8_char(q, end); kind != .None {
				return
			}
		}
	}
	return p, .Bad_Char
}

// Whether `p`, before `end`, opens a run that `comment_run` reads and JSON's whitespace readers do not: a comment, or
// in JSON5 its other whitespace. A state that tests a byte after reading whitespace needs an exact answer, unlike
// `gap_lead` below.
@(private)
gap :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> bool {
	when .Es5 in FEATURES[S] {
		// JSON5's whitespace other than JSON's starts with 0x0B, 0x0C, or a lead byte of 0xC2 or more, so any other
		// byte opens a run only as a comment's `/`. `ws5_len` reads the rest.
		c := p[0]
		return c == '/' || (c - 0x0b <= 1 || c >= 0xc2) && ws5_len(p, end) > 0
	} else {
		return p[0] == '/'
	}
}

// Whether `p` may open a run that `comment_run` reads: a comment, or in JSON5 its other whitespace. In JSON5 a byte of
// 0xC2 or more may be the lead byte of that whitespace, so this tests the byte's class and not `ws5_len`. A byte that
// opens no run is passed on to the states that refuse it.
@(private)
gap_lead :: #force_inline proc "contextless" (p: [^]u8, $S: Spec) -> bool {
	when .Es5 in FEATURES[S] {
		c := p[0]
		return c == '/' || c >= 0xc2 || c - 0x0b <= 1
	} else {
		return p[0] == '/'
	}
}

// `gap_lead` for a byte that `indent_fast` has just read, which is past `' '`. Only a comment's `/` or a byte of 0xC2
// or more can open a run, so the 0x0B and 0x0C test is left out.
@(private)
gap_after_ws :: #force_inline proc "contextless" (p: [^]u8, $S: Spec) -> bool {
	when .Es5 in FEATURES[S] {
		return p[0] == '/' || p[0] >= 0xc2
	} else {
		return p[0] == '/'
	}
}

// Whether `p` is at a line's end: LF or CR, and in JSON5 U+2028 or U+2029.
@(private)
line_end :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> bool {
	when .Es5 in FEATURES[S] {
		return p[0] == '\n' || p[0] == '\r' || line_sep5(p, end)
	} else {
		return p[0] == '\n' || p[0] == '\r'
	}
}

// The run between comments is short, so this `skip_ws` steps up to eight bytes here and passes a longer run to
// `ws_long`, out of line. A caller that inlines all of `skip_ws` builds its vectors on entry.
@(private)
ws_short :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	q := p
	for _ in 0 ..< 8 {
		if q >= end || !is_ws(q[0]) {
			return q
		}
		q = q[1:]
	}
	return ws_long(q, end)
}

@(private, cold)
ws_long :: #force_no_inline proc "contextless" (p, end: [^]u8) -> [^]u8 #no_bounds_check {
	return skip_ws(p, end)
}

// Reads whitespace and comments from `p` and, when `comma`, one comma among them. Returns the next token's byte,
// whether a comma was crossed, or the fault.
@(private)
comment_run :: #force_inline proc "contextless" (p, end: [^]u8, comma: bool, $S: Spec) -> (q: [^]u8, crossed: bool, kind: core.Fault_Kind) {
	q = p
	for {
		q = ws_short(q, end)
		if q >= end {
			return
		}
		when .Es5 in FEATURES[S] {
			if n := ws5_len(q, end); n > 0 {
				q = q[n:]
				continue
			}
		}
		if q[0] == '/' {
			if q, kind = comment(q, end, S); kind != .None {
				return
			}
		} else if comma && !crossed && q[0] == ',' {
			crossed = true
			q = q[1:]
		} else {
			return
		}
	}
}

// Emits the comments in the run from `p` to `q`, which `comment_run` has read whole. With `inline`, a comment on the
// run's first line is `Comment_Inline`, and the rest get role `rest`. With `rest` `.Value` the rest stay unread, for
// the next document. Returns one past the last comment emitted, or `p`, whether a hook stopped the walk there, and
// the `Too_Wide` comment or `.None`.
@(private)
emit_comments :: proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, p, q: [^]u8, inline: bool, rest: core.Role) -> (r: [^]u8, stop: bool, kind: core.Fault_Kind) #no_bounds_check {
	r = p
	x := p
	next_line := !inline
	for x < q {
		if x[0] != '/' {
			next_line ||= line_end(x, q, S)
			x = x[1:]
			continue
		}
		e, _ := comment(x, q, S)
		role := rest if next_line else .Comment_Inline
		if role == .Value {
			return
		}
		if too_wide(x, e) {
			return x, false, .Too_Wide
		}
		if emit(w, on, hs, .Plain, role, x, e, u16(2) | (u16(2) if x[1] == '*' else 0) << 8) == .Stop {
			return e, true, .None
		}
		// A `//` comment ends at a line end that is no byte of it, so only a `/* */` body can move to the next line.
		// The role needs only whether the body holds a line end.
		if !next_line && x[1] == '*' {
			for c := x[2:]; c < e; c = c[1:] {
				if line_end(c, e, S) {
					next_line = true
					break
				}
			}
		}
		x, r = e, e
	}
	return
}

// `p` is at a comment where a value must start. Reads the run up to the value, and gives each comment the value's
// role, or the array's `Comment_Foot` before its close (an empty array or a trailing comma). Then reads the value.
@(private, enable_target_feature = STATE_FEATURES)
st_comments_value :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, _, kind := comment_run(p, end, false, S)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	when H != core.No_Hooks {
		foot := q < end && q[0] == ']' && d & 1 == 0 && d >= 2
		r, stop, wide := emit_comments(w, on, &hs, p, q, false, .Comment_Foot if foot else .Comment)
		if wide != .None {
			return fault(w, hs, r, wide)
		}
		if stop {
			return stopped(w, hs, r)
		}
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is at a comment where an object's key must start. Reads the run up to the key, and gives each comment the
// member's role, or the object's `Comment_Foot` before its close. Then reads the key.
@(private, enable_target_feature = STATE_FEATURES)
st_comments_key :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, _, kind := comment_run(p, end, false, S)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	when H != core.No_Hooks {
		foot := q < end && q[0] == '}'
		r, stop, wide := emit_comments(w, on, &hs, p, q, false, .Comment_Foot if foot else .Comment)
		if wide != .None {
			return fault(w, hs, r, wide)
		}
		if stop {
			return stopped(w, hs, r)
		}
	}
	return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is at a comment between a key and its colon. Reads the run up to the colon, gives each comment the member's
// value's role, then reads the colon.
@(private, enable_target_feature = STATE_FEATURES)
st_comments_colon :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, _, kind := comment_run(p, end, false, S)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	when H != core.No_Hooks {
		r, stop, wide := emit_comments(w, on, &hs, p, q, false, .Comment)
		if wide != .None {
			return fault(w, hs, r, wide)
		}
		if stop {
			return stopped(w, hs, r)
		}
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
}

// `p` is right after a value, and a comment follows before the next token or after its comma. Reads the run from
// `w.resume`, where the caller read the run's leading whitespace up to, to that token, then the token. `w.crossed` says
// whether the caller read a comma before the run. A comment on the value's line is its inline comment. Past that line,
// a comment is the next value's when a comma and a value follow, else the foot of the value before it. After a
// document's root no comma is crossed: a comment past the root's line is its foot when the text ends after it or a
// 0x1E follows it, else it belongs to the next document and stays unread.
@(private, enable_target_feature = STATE_FEATURES)
st_comments_after :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	crossed := w.crossed
	q, more, kind := comment_run(w.resume, end, d >= 2 && !crossed, S)
	crossed ||= more
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	close := ']' | u8(d & 1) << 5
	r := p
	when H != core.No_Hooks {
		rest := core.Role.Comment_Foot
		if d < 2 {
			if q < end && q[0] != 0x1e {
				rest = .Value
			}
		} else if crossed && q < end && q[0] != close {
			rest = .Comment
		}
		stop: bool
		wide: core.Fault_Kind
		r, stop, wide = emit_comments(w, on, &hs, p, q, true, rest)
		if wide != .None {
			return fault(w, hs, r, wide)
		}
		if stop {
			return stopped(w, hs, r)
		}
	}
	if d < 2 {
		return ended(w, hs, r)
	}
	if crossed {
		if d & 1 != 0 {
			return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
		}
		return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	if q >= end {
		return fault(w, hs, end, .Truncated)
	}
	if q[0] == close {
		return #must_tail st_close(q, end, d, ind, w, hs.a, hs.b, hs.c, on)
	}
	return fault(w, hs, q, .Bad_Char)
}
