package json

import "base:intrinsics"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// The states of the specs past RFC 8259, which the strict states pass a byte they refuse, and the comments of those
// specs. A `//` comment runs to the line's end, which is not part of it, and a `/* */` comment may be wherever white
// space may. A comment is a `Plain` fact token whose span holds its markers and whose spelling holds their lengths.
// The states read a whole run of white space and comments up to the next token before they emit any, because that
// token decides each comment's role.
//
// A comment ends any gap being learned, because a gap's match would skip the comment's token.

// The spellings of a comment: the opening marker's length in the low byte and the closing marker's in the high.
@(private)
LINE_COMMENT :: u16(2)
@(private)
BLOCK_COMMENT :: u16(2) | u16(2) << 8

// The `Walk.gap_lo` that learns no gap.
@(private)
GAP_UNLEARNABLE :: max(u64)

// The lanes of `v` a comment's reader judges one at a time: a byte past 0x7F, a control byte, and in a `/* */` comment
// a `*`, which may close it.
@(private)
comment_stops :: #force_inline proc "contextless" (v: V, $star: bool) -> V {
	m := kernel.control_or_high16(v, false)
	when star {
		m = simd.bit_or(m, simd.lanes_eq(v, V('*')))
	}
	return m
}

// The first byte from `q` that a comment's reader judges one at a time, read 16 bytes a step while 16 remain. When
// none is found, `q` after those steps.
@(private)
comment_scan :: #force_inline proc "contextless" (q, end: [^]u8, $star: bool) -> [^]u8 #no_bounds_check {
	q := q
	for intrinsics.ptr_sub(end, q) >= 16 {
		k := kernel.first_lane16(comment_stops(kernel.load16(q), star))
		if k != 16 {
			return q[k:]
		}
		q = q[16:]
	}
	return q
}

// One past the comment that starts at `p`, whether it holds a line end, or the fault. A comment's bytes are judged
// as a string's, except that a tab is allowed and a `/* */` comment may hold CR and LF. JSON5 ends a `//` comment at
// U+2028 and U+2029 too. A `/` that opens no comment faults `Bad_Char`, and an unterminated `/*` faults `Truncated`.
@(private)
skip_comment :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> (q: [^]u8, nl: bool, kind: tape.Fault_Kind) #no_bounds_check {
	if intrinsics.ptr_sub(end, p) < 2 {
		return p, false, .Bad_Char
	}
	switch p[1] {
	case '/':
		return comment_body(p[2:], end, false, S)
	case '*':
		return comment_body(p[2:], end, true, S)
	}
	return p, false, .Bad_Char
}

// The end of a comment's text from `p`, one past `*/` when `star` and its line end otherwise, whether a `/* */`
// comment holds a line end, or the fault.
@(private)
comment_body :: #force_inline proc "contextless" (p, end: [^]u8, $star: bool, $S: Spec) -> (q: [^]u8, nl: bool, kind: tape.Fault_Kind) #no_bounds_check {
	q = p
	for {
		q = comment_scan(q, end, star)
		when star {
			if q >= end {
				return end, nl, .Truncated
			}
			if q[0] == '*' && intrinsics.ptr_sub(end, q) > 1 && q[1] == '/' {
				return q[2:], nl, .None
			}
			nl ||= line_end(q, end, S)
		} else {
			if q >= end || line_end(q, end, S) {
				return q, false, .None
			}
		}
		if q[0] < 0x20 && q[0] != '\t' && !(star && (q[0] == '\n' || q[0] == '\r')) {
			return q, false, .Bad_Char
		}
		if q[0] < 0x80 {
			q = q[1:]
		} else if q, kind = spell.utf8_char(q, end); kind != .None {
			return
		}
	}
}

// Whether `p` is at a line's end: LF or CR, and in JSON5 U+2028 or U+2029.
@(private)
line_end :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> bool {
	when S == .Json5 {
		return p[0] == '\n' || p[0] == '\r' || line_sep5(p, end)
	} else {
		return p[0] == '\n' || p[0] == '\r'
	}
}

// Whether the byte at `p`, before `end`, opens a run of comments or of white space JSON lacks.
@(private)
opens_run :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> bool {
	when S == .Json5 {
		// JSON5's white space past JSON's starts with 0x0B, 0x0C or a byte of 0xC2 or more.
		c := p[0]
		return c == '/' || (c - 0x0b <= 1 || c >= 0xc2) && ws5_len(p, end) > 0
	} else {
		return p[0] == '/'
	}
}

// The first byte of the next token past the white space and comments from `p`, and with `comma` one comma among
// them, and whether that comma was crossed. On a fault, the fault and its byte.
@(private)
comment_run :: #force_inline proc "contextless" (p, end: [^]u8, comma: bool, $S: Spec) -> (q: [^]u8, crossed: bool, kind: tape.Fault_Kind) {
	q = p
	for {
		q = kernel.skip_ws(q, end)
		if q >= end {
			return
		}
		when S == .Json5 {
			if n := ws5_len(q, end); n > 0 {
				q = q[n:]
				continue
			}
		}
		if q[0] == '/' {
			if q, _, kind = skip_comment(q, end, S); kind != .None {
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

// Emits the comments of the run from `p` to `q`. With `inline` a comment on the run's first line is `Comment_Inline`
// and the rest have role `rest`. Returns one past the last comment emitted, whether the hook stopped the walk, and the
// start of a `Too_Wide` comment or nil.
@(private)
emit_comments :: proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, p, q: [^]u8, inline: bool, rest: tape.Role) -> (r: [^]u8, stop: bool, wide: [^]u8) #no_bounds_check {
	r = p
	x := p
	next_line := !inline
	for x < q {
		if x[0] != '/' {
			next_line ||= line_end(x, q, S)
			x = x[1:]
			continue
		}
		e, nl, _ := skip_comment(x, q, S)
		if too_wide(x, e) {
			return x, false, x
		}
		stop = emit(w, on, hs, .Plain, rest if next_line else .Comment_Inline, x, e, BLOCK_COMMENT if x[1] == '*' else LINE_COMMENT) == .Stop
		next_line ||= nl
		x, r = e, e
		if stop {
			return
		}
	}
	return
}

// The start of the JSON white space that ends at `p`, and the byte before it, 0 at the text's start.
@(private)
ws_before :: #force_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8) -> (q: [^]u8, prev: u8) #no_bounds_check {
	q = p
	for q > w.base && kernel.is_ws(q[-1]) {
		q = q[-1:]
	}
	if q == w.base {
		return q, 0
	}
	return q, q[-1]
}

// The end of the value before the comma that the JSON white space ending at `p` follows, nil when no comma does.
@(private)
value_before_comma :: #force_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8) -> [^]u8 {
	c, prev := ws_before(w, p)
	if prev != ',' {
		return nil
	}
	v, _ := ws_before(w, c[-1:])
	return v
}

// The state at a byte `st_value` refused, in a spec past RFC 8259: a run of comments or an array's close after a
// trailing comma. Any other byte faults.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_spec_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	if opens_run(p, end, S) {
		// A run after an array's comma starts after the value before the comma, whose line it may share.
		if v := value_before_comma(w, p); v != nil {
			w.resume = p
			return #must_tail st_comments_member(v, end, d, ind, w, s0, s1, s2, m, G, on)
		}
		return #must_tail st_comments_value(p, end, d, ind, w, s0, s1, s2, m, G, on)
	}
	// An array's close where a value must start follows a comma, or comments after the open bracket.
	if p[0] == ']' && d & 1 == 0 && d >= 2 {
		return #must_tail st_close(p, end, d, ind, w, s0, s1, s2, m, G, on)
	}
	return #must_tail st_bad_value(p, end, d, ind, w, s0, s1, s2, m, G, on)
}

// The state at a byte `st_key` refused, in a spec past RFC 8259: a run of comments, the object's close after a trailing
// comma, or one of JSON5's own keys. Any other byte faults.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_spec_key :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	if opens_run(p, end, S) {
		if v := value_before_comma(w, p); v != nil {
			w.resume = p
			return #must_tail st_comments_member(v, end, d, ind, w, s0, s1, s2, m, G, on)
		}
		return #must_tail st_comments_key(p, end, d, ind, w, s0, s1, s2, m, G, on)
	}
	if p[0] == '}' {
		return #must_tail st_close(p, end, d, ind, w, s0, s1, s2, m, G, on)
	}
	when S == .Json5 {
		return #must_tail st_key5(p, end, d, ind, w, s0, s1, s2, m, G, on)
	} else {
		return fault(w, tape.Hook_Regs{s0, s1, s2}, p, .Bad_Char)
	}
}

// The state at the byte past white space that `st_colon` refused after a key, in a spec past RFC 8259: a run of
// comments before the colon. Any other byte faults.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_spec_colon :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	if opens_run(p, end, S) {
		return #must_tail st_comments_colon(p, end, d, ind, w, s0, s1, s2, m, G, on)
	}
	return fault(w, tape.Hook_Regs{s0, s1, s2}, p, .Bad_Char)
}

// The state after the value ending at `p` whose next byte past JSON white space the states after a value refused, in a
// spec past RFC 8259: a run of comments. Any other byte faults.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_spec_after :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	q := kernel.skip_ws(p, end)
	if opens_run(q, end, S) {
		w.resume = q
		return #must_tail st_comments_after(p, end, d, ind, w, s0, s1, s2, m, G, on)
	}
	return fault(w, tape.Hook_Regs{s0, s1, s2}, q, .Bad_Char)
}

// Reads the run of comments at `p` up to the next token and emits each as `Comment`, or as `Comment_Foot` when the token
// is the byte `close`, 0 for none. Returns the token's byte, or `done` with the result the state returns.
@(private)
comments_before :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, p, end: [^]u8, close: u8) -> (q: [^]u8, done: bool, result: tape.Walk_Result) {
	w.gap_lo = GAP_UNLEARNABLE
	kind: tape.Fault_Kind
	q, _, kind = comment_run(p, end, false, S)
	if kind != .None {
		return q, true, fault(w, hs^, q, kind)
	}
	when H != tape.No_Hooks {
		foot := close != 0 && q < end && q[0] == close
		r, stop, wide := emit_comments(w, on, hs, p, q, false, .Comment_Foot if foot else .Comment)
		if wide != nil {
			return q, true, fault(w, hs^, wide, .Too_Wide)
		}
		if stop {
			return q, true, stopped(w, hs^, r)
		}
	}
	return q, false, 0
}

// The state at a comment where a value must start. Each comment of the run is a `Comment`, or the array's
// `Comment_Foot` before its close. Then reads the value.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_value :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, done, result := comments_before(w, on, &hs, p, end, ']' if d & 1 == 0 && d >= 2 else 0)
	if done {
		return result
	}
	return #must_tail st_value(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a comment where an object's key must start. Each comment of the run is a `Comment`, or the object's
// `Comment_Foot` before its close. Then reads the key.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_key :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, done, result := comments_before(w, on, &hs, p, end, '}')
	if done {
		return result
	}
	return #must_tail st_key(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state at a comment between a key and its colon. Each comment of the run is a `Comment`. Then reads the colon.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_colon :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, done, result := comments_before(w, on, &hs, p, end, 0)
	if done {
		return result
	}
	return #must_tail st_colon(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// The state right after the value ending at `p`, where a run of comments starts at `w.resume`. Reads the run, and one
// comma in it, then the next token.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_after :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, comma, done, result := comments_after(w, on, &hs, p, end, d, false)
	if done {
		return result
	}
	if comma {
		return #must_tail st_member_ws(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
	}
	return #must_tail st_after_ws(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// `st_comments_after` where the run starts past the comma after the value.
@(private, cold, enable_target_feature = STATE_FEATURES)
st_comments_member :: #force_no_inline proc "preserve/none" (p, end: [^]u8, d, ind: u64, w: ^Walk($S, $H), s0, s1, s2, m: u64, $G: bool, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Walk_Result {
	hs := tape.Hook_Regs{s0, s1, s2}
	q, _, done, result := comments_after(w, on, &hs, p, end, d, true)
	if done {
		return result
	}
	return #must_tail st_member_ws(q, end, d, ind, w, hs.a, hs.b, hs.c, m, G, on)
}

// Reads the run of comments after the value ending at `p` from `w.resume` to the next token, crossing one comma unless
// one lies before the run, `crossed`. A comment on the value's line is its inline comment. Past that line a comment is
// the next member's when a comma and a member follow, else the container's foot. Returns the token's byte and whether a
// comma lies before it, or `done` with the result the state returns.
@(private)
comments_after :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action), hs: ^tape.Hook_Regs, p, end: [^]u8, d: u64, crossed: bool) -> (q: [^]u8, comma, done: bool, result: tape.Walk_Result) {
	w.gap_lo = GAP_UNLEARNABLE
	more: bool
	kind: tape.Fault_Kind
	q, more, kind = comment_run(w.resume, end, !crossed, S)
	if kind != .None {
		return q, false, true, fault(w, hs^, q, kind)
	}
	comma = crossed || more
	when H != tape.No_Hooks {
		close := ']' | u8(d & 1) << 5
		rest := tape.Role.Comment if comma && q < end && q[0] != close else .Comment_Foot
		r, stop, wide := emit_comments(w, on, hs, p, q, true, rest)
		if wide != nil {
			return q, false, true, fault(w, hs^, wide, .Too_Wide)
		}
		if stop {
			return q, false, true, stopped(w, hs^, r)
		}
	}
	return
}

// The fault or nil for what follows the root value that ends at `at`, past the white space up to `q`. Its comments are
// emitted, the root's inline comments on its line and its foot past it.
@(private, cold)
root_tail :: #force_no_inline proc "contextless" (src: []u8, at: u64, q: [^]u8, $S: Spec, h: ^$H, regs: ^tape.Hook_Regs, $on: proc "contextless" (h: ^H, s: tape.Hook_Regs, t: tape.Token) -> (tape.Hook_Regs, tape.Action)) -> tape.Error {
	base := raw_data(src)
	end := base[len(src):]
	r := q
	if opens_run(q, end, S) {
		kind: tape.Fault_Kind
		r, _, kind = comment_run(q, end, false, S)
		if kind != .None {
			return tape.Fault{at = u64(intrinsics.ptr_sub(r, base)), rules = &RULES, kind = kind}
		}
	}
	if r < end {
		return tape.Fault{at = u64(intrinsics.ptr_sub(r, base)), rules = &RULES, kind = .Bad_Char}
	}
	when H != tape.No_Hooks {
		w := Walk(S, H){base = base, hooks = h}
		root_close := base[at:]
		if _, _, wide := emit_comments(&w, on, regs, root_close, end, true, .Comment_Foot); wide != nil {
			return tape.Fault{at = u64(intrinsics.ptr_sub(wide, base)), rules = &RULES, kind = .Too_Wide}
		}
	}
	return nil
}
