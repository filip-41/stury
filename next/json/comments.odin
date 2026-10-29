package json

import "base:intrinsics"
import core "../core"

// Comments, in the specs that have them: `//` up to the line's end, which is not part of it, and `/* */`, wherever
// whitespace may stand. A comment is a fact token: `Plain`, its span the comment with its delimiters, `spelling` 1
// for `/* */`, and its role `core.Role`'s rule gives it. A state that meets a `/` where it wants a token hands over to
// a state here, which reads the whole run of whitespace and comments up to the next token before it emits any of it,
// since what follows the run decides the role of each comment in it. A walk without hooks reads the run and emits
// nothing.

// The comment at `p`, which stands on a `/`: one past its last byte, or the fault. A comment's bytes are judged as a
// string's raw bytes are: UTF-8, and no control byte but a tab, and in a `/* */` comment CR and LF, else `Bad_Char` at
// that byte. A `/` that opens no comment, the text's last byte among them, is `Bad_Char` at the `/`, and a `/*` the
// text ends inside is `Truncated`.
@(private)
comment :: proc "contextless" (p, end: [^]u8) -> (q: [^]u8, kind: core.Fault_Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) < 2 {
		return p, .Bad_Char
	}
	q = p[2:]
	switch p[1] {
	case '/':
		for q < end && q[0] != '\n' && q[0] != '\r' {
			if q[0] < 0x20 && q[0] != '\t' {
				return q, .Bad_Char
			}
			if q[0] < 0x80 {
				q = q[1:]
			} else if q, kind = utf8_char(q, end); kind != .None {
				return
			}
		}
		return q, .None
	case '*':
		for {
			if q >= end {
				return end, .Truncated
			}
			if q[0] == '*' && intrinsics.ptr_sub(end, q) > 1 && q[1] == '/' {
				return q[2:], .None
			}
			if q[0] < 0x20 && q[0] != '\t' && q[0] != '\n' && q[0] != '\r' {
				return q, .Bad_Char
			}
			if q[0] < 0x80 {
				q = q[1:]
			} else if q, kind = utf8_char(q, end); kind != .None {
				return
			}
		}
	}
	return p, .Bad_Char
}

// The whitespace and comments from `p`, and one comma among them when `comma`: where the next token stands, whether
// a comma was crossed, or the fault.
@(private)
comment_run :: proc "contextless" (p, end: [^]u8, comma: bool) -> (q: [^]u8, crossed: bool, kind: core.Fault_Kind) {
	q = p
	for {
		q = skip_ws(q, end)
		if q >= end {
			return
		}
		if q[0] == '/' {
			if q, kind = comment(q, end); kind != .None {
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

// Emits the comments of the run from `p` to `q`, which `comment_run` read whole: with `inline`, those that start on
// the run's first line as `Comment_Inline`, and the rest as `rest`. With `rest` `Value` the rest stay unread, the next
// document's. Returns one past the last comment emitted, or `p`, and whether a hook stopped the walk there, or the
// comment that is `Too_Wide`.
@(private)
emit_comments :: proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, p, q: [^]u8, inline: bool, rest: core.Role) -> (r: [^]u8, stop: bool, kind: core.Fault_Kind) #no_bounds_check {
	r = p
	x := p
	next_line := !inline
	for x < q {
		if x[0] != '/' {
			next_line ||= x[0] == '\n' || x[0] == '\r'
			x = x[1:]
			continue
		}
		e, _ := comment(x, q)
		role := rest if next_line else .Comment_Inline
		if role == .Value {
			return
		}
		if too_wide(x, e) {
			return x, false, .Too_Wide
		}
		if emit(w, on, hs, .Plain, role, x, e, u16(x[1] == '*')) == .Stop {
			return e, true, .None
		}
		for c in x[:intrinsics.ptr_sub(e, x)] {
			next_line ||= c == '\n' || c == '\r'
		}
		x, r = e, e
	}
	return
}

// `p` stands on a comment where a value must start: the run up to the value, each comment the value's, or before an
// array's close (an empty array, or a trailing comma) that array's foot, then the value.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_value :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, _, kind := comment_run(p, end, false)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	when H != No_Hooks {
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

// `p` stands on a comment where an object's key must start: the run up to the key, each comment the member's, or
// before the object's close that object's foot, then the key.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_key :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, _, kind := comment_run(p, end, false)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	when H != No_Hooks {
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

// `p` stands on a comment between a key and its colon: the run up to the colon, each comment the member's value's,
// then the colon.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_colon :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, _, kind := comment_run(p, end, false)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	when H != No_Hooks {
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

// `p` stands right after a value, and a comment follows it before the next token, or after its comma: the run up to
// that token, then the token. A comment on the value's line is its inline comment. Past that line, a comment is the
// next value's when a comma and a value follow, else the foot of the value before it. After a document's root the run
// crosses no comma: the comments past the root's line are its foot when the text ends after them or a 0x1E follows
// them, else the next document's, left unread.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_after :: #force_no_inline proc "contextless" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2: u64, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	hs := core.Hook_Regs{s0, s1, s2}
	q, crossed, kind := comment_run(p, end, d >= 2)
	if kind != .None {
		return fault(w, hs, q, kind)
	}
	close := ']' | u8(d & 1) << 5
	r := p
	when H != No_Hooks {
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
